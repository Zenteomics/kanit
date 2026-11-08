//! `kanit clean`: removes what earlier launches left behind in a working
//! directory. It takes the run lock, so it never races a run. It removes
//! containers labelled with the working directory, and with `--keep N` the
//! launch directories older than the newest N, except a launch that holds
//! the recorded attempt of a rule, whose logs belong to current outputs.
//! With `--previous` it removes the earlier outputs that attempts moved
//! into their `previous/` directories, in every launch.
const std = @import("std");
const units = @import("units.zig");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const state = @import("state.zig");
const container = @import("container.zig");
const process = @import("process.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    keep: ?usize = null,
    previous: bool = false,
    dry_run: bool = false,
};

pub const Result = struct { containers: usize = 0, launches: usize = 0, bytes: u64 = 0, kept_for_records: usize = 0, kept_for_recovery: usize = 0, previous: usize = 0, previous_bytes: u64 = 0, failed: usize = 0 };

fn openDir(gpa: Allocator, path: []const u8) !sys.Fd {
    const p = try sys.z(gpa, path);
    defer gpa.free(p);
    return @intCast(try sys.check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0)));
}

pub fn removeAt(gpa: Allocator, parent: sys.Fd, name: [:0]const u8, dry: bool, depth: usize) !u64 {
    if (depth > 64) return error.DirectoryTooDeep;
    var st: linux.Statx = undefined;
    _ = try sys.check(linux.statx(parent, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true }, &st));
    if (st.mode & 0o170000 != 0o040000) {
        if (!dry) _ = try sys.check(linux.unlinkat(parent, name, 0));
        return st.size;
    }
    const fd: sys.Fd = @intCast(try sys.check(linux.openat(parent, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0)));
    defer sys.close(fd);
    if (!dry) _ = linux.fchmod(fd, 0o700);
    var total: u64 = 0;
    var names: std.ArrayList([:0]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var entries: sys.DirEntries = .{ .fd = fd };
    while (try entries.next()) |e| try names.append(gpa, try gpa.dupeZ(u8, e.name));
    for (names.items) |entry| total += try removeAt(gpa, fd, entry, dry, depth + 1);
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

    if (try container.findPodman(gpa, a, environ.get("PATH") orelse "/usr/bin:/bin")) |podman| {
        const devnull = try sys.openRead(gpa, "/dev/null");
        defer sys.close(devnull);
        const envp = try process.Vec.init(a, try state.hostEnv(a, environ, &.{}));
        result.containers = if (opts.dry_run)
            (try container.listLeftovers(gpa, a, podman, root, &envp, devnull)).len
        else
            try container.removeLeftovers(gpa, a, podman, root, &envp, devnull);
    }

    const pending = try records.pendingAttempts(gpa, a, rec, null);
    if (opts.previous) try removePrevious(gpa, a, rec, pending, opts.dry_run, &result, w);

    const keep = opts.keep orelse return result;
    const names = try records.launchNames(gpa, a, rec);
    if (names.len <= keep) return result;
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
        const recovers = for (pending) |p| {
            if (std.mem.eql(u8, p.launch, name)) break true;
        } else false;
        if (recovers) {
            result.kept_for_recovery += 1;
            continue;
        }
        result.bytes += removeAt(gpa, launches_fd, try a.dupeZ(u8, name), opts.dry_run, 0) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try w.print("cannot remove launch {s}: {s}\n", .{ name, sys.errorText(err) });
                result.failed += 1;
                continue;
            },
        };
        result.launches += 1;
        try w.print("{s} launch {s}\n", .{ if (opts.dry_run) "would remove" else "removed", name });
    }
    return result;
}

fn openBelow(parent: sys.Fd, name: [:0]const u8) ?sys.Fd {
    const rc = linux.openat(parent, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn namesIn(a: Allocator, fd: sys.Fd) ![]const [:0]const u8 {
    var names: std.ArrayList([:0]const u8) = .empty;
    var entries: sys.DirEntries = .{ .fd = fd };
    while (try entries.next()) |e| if (e.name[0] != '.') try names.append(a, try a.dupeZ(u8, e.name));
    return names.items;
}

fn removePrevious(gpa: Allocator, a: Allocator, rec: []const u8, pending: []const records.Pending, dry: bool, result: *Result, w: *std.Io.Writer) !void {
    const launches_fd = openDir(gpa, try std.fs.path.join(a, &.{ rec, "launches" })) catch return;
    defer sys.close(launches_fd);
    for (try records.launchNames(gpa, a, rec)) |launch| {
        const launch_fd = openBelow(launches_fd, try a.dupeZ(u8, launch)) orelse continue;
        defer sys.close(launch_fd);
        const attempts_fd = openBelow(launch_fd, "attempts") orelse continue;
        defer sys.close(attempts_fd);
        const attempts = try std.fs.path.join(a, &.{ rec, "launches", launch, "attempts" });
        var dirs: usize = 0;
        var bytes: u64 = 0;
        for (try namesIn(a, attempts_fd)) |rule| {
            const rule_fd = openBelow(attempts_fd, rule) orelse continue;
            defer sys.close(rule_fd);
            const rule_dir = try std.fs.path.join(a, &.{ attempts, rule });
            for (try namesIn(a, rule_fd)) |n| {
                const attempt = try std.fs.path.join(a, &.{ rule_dir, n });
                if (isPending(pending, attempt)) {
                    try w.print("kept {s}/previous: it holds outputs the next launch puts back\n", .{attempt});
                    result.kept_for_recovery += 1;
                    continue;
                }
                const fd = openBelow(rule_fd, n) orelse continue;
                defer sys.close(fd);
                bytes += removeAt(gpa, fd, "previous", dry, 0) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    error.OutOfMemory => return err,
                    else => {
                        try w.print("cannot remove {s}/{s}/previous: {s}\n", .{ rule_dir, n, sys.errorText(err) });
                        result.failed += 1;
                        continue;
                    },
                };
                dirs += 1;
            }
        }
        if (dirs == 0) continue;
        result.previous += dirs;
        result.previous_bytes += bytes;
        try w.print("{s} previous/ of {d} {s} in launch {s}, ", .{ if (dry) "would remove" else "removed", dirs, if (dirs == 1) "attempt" else "attempts", launch });
        try units.size(w, @as(f64, @floatFromInt(bytes)) / 1048576.0);
        try w.writeAll("\n");
    }
}

fn isPending(pending: []const records.Pending, attempt: []const u8) bool {
    for (pending) |p| if (std.mem.eql(u8, p.dir, attempt)) return true;
    return false;
}
