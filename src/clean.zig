//! `workz clean`: removes what earlier launches left behind in a working
//! directory. It takes the run lock, so it never races a run. It removes
//! containers labelled with the working directory, and with `--keep N` the
//! launch directories older than the newest N, except a launch that holds
//! the recorded attempt of a rule, whose logs belong to current outputs.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const state = @import("state.zig");
const container = @import("container.zig");
const process = @import("process.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    keep: ?usize = null,
    dry_run: bool = false,
};

pub const Result = struct { containers: usize = 0, launches: usize = 0, bytes: u64 = 0, kept_for_records: usize = 0 };

/// Launch directory names, oldest first (names sort by time).
pub fn launchNames(gpa: Allocator, a: Allocator, rec: []const u8) ![]const []const u8 {
    const dir = try std.fs.path.join(a, &.{ rec, "launches" });
    var names: std.ArrayList([]const u8) = .empty;
    const fd = openDir(gpa, dir) catch |err| switch (err) {
        error.FileNotFound => return names.items,
        else => return err,
    };
    defer sys.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = try sys.check(linux.getdents64(fd, &buf, buf.len));
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[off + 19 .. off + reclen], 0);
            off += reclen;
            if (name[0] == '.') continue;
            try names.append(a, try a.dupe(u8, name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return names.items;
}

fn openDir(gpa: Allocator, path: []const u8) !sys.Fd {
    const p = try sys.z(gpa, path);
    defer gpa.free(p);
    return @intCast(try sys.check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0)));
}

/// Removes `name` below the open directory `parent` and everything in it,
/// without following symlinks; returns the bytes of the files removed.
/// With `dry`, only counts.
pub fn removeAt(parent: sys.Fd, name: [:0]const u8, dry: bool, depth: usize) !u64 {
    if (depth > 64) return error.DirectoryTooDeep;
    var st: linux.Statx = undefined;
    _ = try sys.check(linux.statx(parent, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true }, &st));
    if (st.mode & 0o170000 != 0o040000) {
        if (!dry) _ = try sys.check(linux.unlinkat(parent, name, 0));
        return st.size;
    }
    const fd: sys.Fd = @intCast(try sys.check(linux.openat(parent, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0)));
    defer sys.close(fd);
    var total: u64 = 0;
    var buf: [16384]u8 align(8) = undefined;
    var names: std.ArrayList([:0]u8) = .empty;
    defer {
        for (names.items) |n| std.heap.page_allocator.free(n);
        names.deinit(std.heap.page_allocator);
    }
    while (true) {
        const n = try sys.check(linux.getdents64(fd, &buf, buf.len));
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const entry = std.mem.sliceTo(buf[off + 19 .. off + reclen], 0);
            off += reclen;
            if (std.mem.eql(u8, entry, ".") or std.mem.eql(u8, entry, "..")) continue;
            try names.append(std.heap.page_allocator, try std.heap.page_allocator.dupeZ(u8, entry));
        }
    }
    // Entries are collected first: removing while reading would skip some.
    for (names.items) |entry| total += try removeAt(fd, entry, dry, depth + 1);
    if (!dry) _ = try sys.check(linux.unlinkat(parent, name, linux.AT.REMOVEDIR));
    return total;
}

pub fn run(gpa: Allocator, a: Allocator, root: []const u8, opts: Options, environ: *const std.process.Environ.Map, w: *std.Io.Writer) !Result {
    var result: Result = .{};
    const rec = try records.recordsDir(a, root);
    if (!sys.exists(gpa, rec)) return result;
    const lock = records.lock(gpa, rec) catch |err| switch (err) {
        error.Busy => return error.Busy,
        else => return err,
    };
    defer sys.close(lock);

    // Containers of earlier launches in this working directory.
    if (try container.findPodman(gpa, a, environ.get("PATH") orelse "/usr/bin:/bin")) |podman| {
        const devnull = try sys.openRead(gpa, "/dev/null");
        defer sys.close(devnull);
        var env_list: std.ArrayList([]const u8) = .empty;
        var it = environ.iterator();
        while (it.next()) |e| try env_list.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
        const envp = try process.Vec.init(a, env_list.items);
        if (opts.dry_run) {
            var status: u32 = 0;
            const label = try std.fmt.allocPrint(a, "label=workz.workdir={s}", .{root});
            const out = process.capture(gpa, a, &.{ podman, "ps", "--all", "--quiet", "--filter", label }, &envp, devnull, &status) catch "";
            var ids = std.mem.tokenizeAny(u8, out, " \n");
            while (ids.next()) |_| result.containers += 1;
        } else result.containers = try container.removeLeftovers(gpa, a, podman, root, &envp, devnull);
    }

    const keep = opts.keep orelse return result;
    const names = try launchNames(gpa, a, rec);
    if (names.len <= keep) return result;
    // Launches that hold the recorded attempt of a rule stay.
    var held: std.StringHashMapUnmanaged(void) = .empty;
    var st = try state.load(gpa, rec);
    defer st.deinit();
    const prefix = try std.fs.path.join(a, &.{ rec, "launches" });
    for (st.data.rules.map.values()) |e| {
        if (!std.mem.startsWith(u8, e.attempt, prefix)) continue;
        var parts = std.mem.tokenizeScalar(u8, e.attempt[prefix.len..], '/');
        if (parts.next()) |id| try held.put(a, id, {});
    }
    const launches_fd = try openDir(gpa, prefix);
    defer sys.close(launches_fd);
    for (names[0 .. names.len - keep]) |name| {
        if (held.contains(name)) {
            result.kept_for_records += 1;
            continue;
        }
        result.bytes += try removeAt(launches_fd, try a.dupeZ(u8, name), opts.dry_run, 0);
        result.launches += 1;
        try w.print("{s} launch {s}\n", .{ if (opts.dry_run) "would remove" else "removed", name });
    }
    return result;
}
