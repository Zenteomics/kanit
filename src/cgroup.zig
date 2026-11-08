//! cgroup v2 control inside the run's delegated systemd scope.
//!
//! The engine moves itself into an `engine` leaf, enables the memory, cpu and
//! pids controllers for the scope, and gives each task attempt and each shared
//! input holder its own child group. Task groups get `memory.max` equal to the
//! request, no swap, whole-group OOM kills, and a CPU quota equal to the
//! requested threads. The engine holds each group's directory open while the
//! group lives and reaches its files relative to it, which saves a path walk
//! per file on every attempt.
const std = @import("std");
const sys = @import("sys.zig");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const Tree = struct {
    root: []const u8,
};

pub const SetupError = error{NotDelegated};

pub fn setup(gpa: Allocator, a: Allocator) !Tree {
    const self_cg = try sys.readFile(gpa, "/proc/self/cgroup", 1 << 16);
    defer gpa.free(self_cg);
    var it = std.mem.splitScalar(u8, self_cg, '\n');
    const rel = while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) break line[3..];
    } else return error.NotDelegated;
    const root = try std.fmt.allocPrint(a, "/sys/fs/cgroup{s}", .{rel});
    const engine = try std.fs.path.join(gpa, &.{ root, "engine" });
    defer gpa.free(engine);
    sys.mkdir(gpa, engine) catch return error.NotDelegated;
    const procs_path = try std.fs.path.join(gpa, &.{ root, "cgroup.procs" });
    defer gpa.free(procs_path);
    const procs = try sys.readFile(gpa, procs_path, 1 << 20);
    defer gpa.free(procs);
    const dest = try std.fs.path.join(gpa, &.{ engine, "cgroup.procs" });
    defer gpa.free(dest);
    var pit = std.mem.tokenizeScalar(u8, procs, '\n');
    while (pit.next()) |pid| writeText(gpa, dest, pid) catch |err| switch (err) {
        error.NoProcess => {},
        else => return error.NotDelegated,
    };
    const ctl = try std.fs.path.join(gpa, &.{ root, "cgroup.subtree_control" });
    defer gpa.free(ctl);
    writeText(gpa, ctl, "+memory +cpu +pids") catch return error.NotDelegated;
    return .{ .root = root };
}

fn writeText(gpa: Allocator, path: []const u8, text: []const u8) !void {
    const fd = try sys.openWrite(gpa, path, .append);
    defer sys.close(fd);
    try sys.writeAll(fd, text);
}

pub const Limits = struct {
    memory_bytes: ?u64 = null,
    threads: ?u32 = null,
    oom_group: bool = false,
};

pub const Group = struct {
    path: []const u8,
    dir: sys.Fd,

    pub fn openProcs(g: Group) !sys.Fd {
        return @intCast(try sys.check(linux.openat(g.dir, "cgroup.procs", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0)));
    }

    pub fn counters(g: Group) Counters {
        var buf: [1 << 16]u8 = undefined;
        var c: Counters = .{};
        c.memory_peak = number(readAt(g.dir, "memory.peak", &buf));
        c.memory_current = number(readAt(g.dir, "memory.current", &buf));
        if (readAt(g.dir, "memory.events", &buf)) |kv| {
            c.oom = field(kv, "oom") orelse 0;
            c.oom_kill = field(kv, "oom_kill") orelse 0;
            c.memory_max_events = field(kv, "max") orelse 0;
        }
        if (readAt(g.dir, "cpu.stat", &buf)) |kv| c.cpu_usage_usec = field(kv, "usage_usec");
        if (readAt(g.dir, "cpu.pressure", &buf)) |kv| c.cpu_some_us = pressureTotal(kv, "some");
        if (readAt(g.dir, "memory.pressure", &buf)) |kv| {
            c.memory_some_us = pressureTotal(kv, "some");
            c.memory_full_us = pressureTotal(kv, "full");
        }
        if (readAt(g.dir, "io.pressure", &buf)) |kv| {
            c.io_some_us = pressureTotal(kv, "some");
            c.io_full_us = pressureTotal(kv, "full");
        }
        if (readAt(g.dir, "memory.stat", &buf)) |kv| c.file = field(kv, "file");
        return c;
    }

    pub fn stat(g: Group, name: []const u8) ?u64 {
        var buf: [1 << 16]u8 = undefined;
        return field(readAt(g.dir, "memory.stat", &buf) orelse return null, name);
    }

    pub fn populated(g: Group) bool {
        var buf: [256]u8 = undefined;
        return (field(readAt(g.dir, "cgroup.events", &buf) orelse return true, "populated") orelse 0) != 0;
    }

    pub fn kill(g: Group) void {
        setAt(g.dir, "cgroup.kill", "1") catch {};
    }
};

pub fn open(gpa: Allocator, path: []const u8) !Group {
    return .{ .path = path, .dir = try sys.openDir(gpa, path) };
}

pub fn create(gpa: Allocator, a: Allocator, tree: Tree, name: []const u8, limits: Limits) !Group {
    const path = try std.fs.path.join(a, &.{ tree.root, name });
    try sys.mkdir(gpa, path);
    errdefer removePath(gpa, path) catch {};
    const g = try open(gpa, path);
    errdefer sys.close(g.dir);
    if (limits.memory_bytes) |m| {
        var buf: [32]u8 = undefined;
        try setAt(g.dir, "memory.max", try std.fmt.bufPrint(&buf, "{d}", .{m}));
    }
    if (limits.oom_group) try setAt(g.dir, "memory.oom.group", "1");
    if (limits.threads) |t| {
        var buf: [48]u8 = undefined;
        try setAt(g.dir, "cpu.max", try std.fmt.bufPrint(&buf, "{d} 100000", .{@as(u64, t) * 100000}));
    }
    return g;
}

pub fn remove(gpa: Allocator, g: Group) !void {
    defer sys.close(g.dir);
    removePath(gpa, g.path) catch |err| {
        g.kill();
        return err;
    };
}

fn setAt(dir: sys.Fd, name: [*:0]const u8, value: []const u8) !void {
    const fd: sys.Fd = @intCast(try sys.check(linux.openat(dir, name, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0)));
    defer sys.close(fd);
    try sys.writeAll(fd, value);
}

fn readAt(dir: sys.Fd, name: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd: sys.Fd = @intCast(sys.check(linux.openat(dir, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0)) catch return null);
    defer sys.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const k = sys.read(fd, buf[n..]) catch return null;
        if (k == 0) return buf[0..n];
        n += k;
    }
    return null;
}

fn number(text: ?[]const u8) ?u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, text orelse return null, " \n"), 10) catch null;
}

pub const Counters = struct {
    memory_peak: ?u64 = null,
    memory_current: ?u64 = null,
    oom: u64 = 0,
    oom_kill: u64 = 0,
    memory_max_events: u64 = 0,
    cpu_usage_usec: ?u64 = null,
    file: ?u64 = null,
    anon_peak: ?u64 = null,
    cpu_some_us: ?u64 = null,
    memory_some_us: ?u64 = null,
    memory_full_us: ?u64 = null,
    io_some_us: ?u64 = null,
    io_full_us: ?u64 = null,
};

pub fn read(gpa: Allocator, path: []const u8) Counters {
    const g = open(gpa, path) catch return .{};
    defer sys.close(g.dir);
    return g.counters();
}

pub fn readNumber(gpa: Allocator, path: []const u8, file: [*:0]const u8) ?u64 {
    const dir = sys.openDir(gpa, path) catch return null;
    defer sys.close(dir);
    var buf: [64]u8 = undefined;
    return number(readAt(dir, file, &buf));
}

pub fn cpuUsage(gpa: Allocator, path: []const u8) ?u64 {
    const dir = sys.openDir(gpa, path) catch return null;
    defer sys.close(dir);
    var buf: [1024]u8 = undefined;
    return field(readAt(dir, "cpu.stat", &buf) orelse return null, "usage_usec");
}

fn field(text: []const u8, name: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const k = parts.next() orelse continue;
        if (!std.mem.eql(u8, k, name)) continue;
        return std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch null;
    }
    return null;
}

pub fn pressureTotal(text: []const u8, kind: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, kind)) continue;
        const at = std.mem.indexOf(u8, line, "total=") orelse return null;
        return std.fmt.parseInt(u64, std.mem.trim(u8, line[at + 6 ..], " "), 10) catch null;
    }
    return null;
}

pub fn removePath(gpa: Allocator, path: []const u8) !void {
    sys.rmdir(gpa, path) catch |err| switch (err) {
        error.Busy => {
            try removeChildren(gpa, path, 0);
            try sys.rmdir(gpa, path);
        },
        else => return err,
    };
}

fn removeChildren(gpa: Allocator, path: []const u8, depth: usize) !void {
    if (depth > 16) return error.Busy;
    const fd = try sys.openDir(gpa, path);
    defer sys.close(fd);
    var entries: sys.DirEntries = .{ .fd = fd };
    while (try entries.next()) |e| {
        if (e.kind != 4) continue;
        const child = try std.fs.path.join(gpa, &.{ path, e.name });
        defer gpa.free(child);
        try removeChildren(gpa, child, depth + 1);
        try sys.rmdir(gpa, child);
    }
}
