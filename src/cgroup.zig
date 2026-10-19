//! cgroup v2 control inside the run's delegated systemd scope.
//!
//! The engine moves itself into an `engine` leaf, enables the memory, cpu and
//! pids controllers for the scope, and gives each task attempt and each shared
//! input holder its own child group. Task groups get `memory.max` equal to the
//! request, no swap, whole-group OOM kills, and a CPU quota equal to the
//! requested threads.
const std = @import("std");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

pub const Tree = struct {
    /// Absolute cgroupfs path of the run's scope.
    root: []const u8,
};

pub const SetupError = error{NotDelegated};

/// Claims the delegated cgroup the process runs in.
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
    // Move every process of the scope (the engine and its launcher) into the leaf.
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
    /// On OOM the kernel kills every process of the group together, so a
    /// command never runs on after one of its processes was killed.
    oom_group: bool = false,
};

/// Creates `<root>/<name>` with the given limits and swap disabled.
pub fn create(gpa: Allocator, a: Allocator, tree: Tree, name: []const u8, limits: Limits) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ tree.root, name });
    try sys.mkdir(gpa, path);
    try set(gpa, path, "memory.swap.max", "0");
    if (limits.memory_bytes) |m| {
        var buf: [32]u8 = undefined;
        try set(gpa, path, "memory.max", try std.fmt.bufPrint(&buf, "{d}", .{m}));
    }
    if (limits.oom_group) try set(gpa, path, "memory.oom.group", "1");
    if (limits.threads) |t| {
        var buf: [48]u8 = undefined;
        try set(gpa, path, "cpu.max", try std.fmt.bufPrint(&buf, "{d} 100000", .{@as(u64, t) * 100000}));
    }
    return path;
}

fn set(gpa: Allocator, dir: []const u8, file: []const u8, value: []const u8) !void {
    const p = try std.fs.path.join(gpa, &.{ dir, file });
    defer gpa.free(p);
    try writeText(gpa, p, value);
}

/// Opens the group's `cgroup.procs` for a child to join itself before exec.
pub fn openProcs(gpa: Allocator, path: []const u8) !sys.Fd {
    const p = try std.fs.path.join(gpa, &.{ path, "cgroup.procs" });
    defer gpa.free(p);
    return sys.openWrite(gpa, p, .append);
}

/// Kernel counters of a task group, read after its command exits and before
/// the group is removed.
pub const Counters = struct {
    memory_peak: ?u64 = null,
    memory_current: ?u64 = null,
    oom: u64 = 0,
    oom_kill: u64 = 0,
    memory_max_events: u64 = 0,
    cpu_usage_usec: ?u64 = null,
    anon: ?u64 = null,
    file: ?u64 = null,
    file_mapped: ?u64 = null,
    /// Pressure stall totals in microseconds: time at least one task of the
    /// group ("some") or all of them ("full") waited for the resource.
    cpu_some_us: ?u64 = null,
    memory_some_us: ?u64 = null,
    memory_full_us: ?u64 = null,
    io_some_us: ?u64 = null,
    io_full_us: ?u64 = null,
};

pub fn read(gpa: Allocator, path: []const u8) Counters {
    var c: Counters = .{};
    c.memory_peak = readNumber(gpa, path, "memory.peak");
    c.memory_current = readNumber(gpa, path, "memory.current");
    if (readKeyed(gpa, path, "memory.events")) |kv| {
        defer gpa.free(kv);
        c.oom = field(kv, "oom") orelse 0;
        c.oom_kill = field(kv, "oom_kill") orelse 0;
        c.memory_max_events = field(kv, "max") orelse 0;
    }
    if (readKeyed(gpa, path, "cpu.stat")) |kv| {
        defer gpa.free(kv);
        c.cpu_usage_usec = field(kv, "usage_usec");
    }
    if (readKeyed(gpa, path, "cpu.pressure")) |kv| {
        defer gpa.free(kv);
        c.cpu_some_us = pressureTotal(kv, "some");
    }
    if (readKeyed(gpa, path, "memory.pressure")) |kv| {
        defer gpa.free(kv);
        c.memory_some_us = pressureTotal(kv, "some");
        c.memory_full_us = pressureTotal(kv, "full");
    }
    if (readKeyed(gpa, path, "io.pressure")) |kv| {
        defer gpa.free(kv);
        c.io_some_us = pressureTotal(kv, "some");
        c.io_full_us = pressureTotal(kv, "full");
    }
    if (readKeyed(gpa, path, "memory.stat")) |kv| {
        defer gpa.free(kv);
        c.anon = field(kv, "anon");
        c.file = field(kv, "file");
        c.file_mapped = field(kv, "file_mapped");
    }
    return c;
}

pub fn readNumber(gpa: Allocator, dir: []const u8, file: []const u8) ?u64 {
    const text = readKeyed(gpa, dir, file) orelse return null;
    defer gpa.free(text);
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn readKeyed(gpa: Allocator, dir: []const u8, file: []const u8) ?[]u8 {
    const p = std.fs.path.join(gpa, &.{ dir, file }) catch return null;
    defer gpa.free(p);
    return sys.readFile(gpa, p, 1 << 16) catch null;
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

/// The `total=` field of a pressure line ("some avg10=... total=N").
pub fn pressureTotal(text: []const u8, kind: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, kind)) continue;
        const at = std.mem.indexOf(u8, line, "total=") orelse return null;
        return std.fmt.parseInt(u64, std.mem.trim(u8, line[at + 6 ..], " "), 10) catch null;
    }
    return null;
}

/// CPU time used by the group so far, in microseconds.
pub fn cpuUsage(gpa: Allocator, path: []const u8) ?u64 {
    const kv = readKeyed(gpa, path, "cpu.stat") orelse return null;
    defer gpa.free(kv);
    return field(kv, "usage_usec");
}

/// True while any process remains in the group.
pub fn populated(gpa: Allocator, path: []const u8) bool {
    const kv = readKeyed(gpa, path, "cgroup.events") orelse return false;
    defer gpa.free(kv);
    return (field(kv, "populated") orelse 0) != 0;
}

/// Kills every process in the group.
pub fn kill(gpa: Allocator, path: []const u8) void {
    set(gpa, path, "cgroup.kill", "1") catch {};
}

/// Removes an empty group; error.Busy while processes remain.
pub fn remove(gpa: Allocator, path: []const u8) !void {
    try sys.rmdir(gpa, path);
}
