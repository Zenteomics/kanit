//! `workz clean`: removes what earlier launches left behind in a working
//! directory. It takes the run lock, so it never races a run. It removes
//! containers labelled with the working directory, and with `--keep N` the
//! launch directories older than the newest N, except a launch that holds
//! the recorded attempt of a rule, whose logs belong to current outputs.
//! With `--previous` it removes the earlier outputs that attempts moved
//! into their `previous/` directories, in every launch.
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
    previous: bool = false,
    dry_run: bool = false,
};

/// What `clean` removed, or would remove with `dry_run`; `kept_for_recovery`
/// counts launches and `previous/` directories kept because they hold the
/// only copy of an output that a killed launch moved aside.
pub const Result = struct { containers: usize = 0, launches: usize = 0, bytes: u64 = 0, kept_for_records: usize = 0, kept_for_recovery: usize = 0, previous: usize = 0, previous_bytes: u64 = 0, failed: usize = 0 };

fn openDir(gpa: Allocator, path: []const u8) !sys.Fd {
    const p = try sys.z(gpa, path);
    defer gpa.free(p);
    return @intCast(try sys.check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0)));
}

/// Removes `name` below the open directory `parent` and everything in it,
/// without following symlinks; returns the bytes of the files removed.
/// With `dry`, only counts.
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
    // A directory kept read-only, such as an output directory moved aside
    // whole, is the user's own: it is made writable to empty it.
    if (!dry) _ = linux.fchmod(fd, 0o700);
    var total: u64 = 0;
    var names: std.ArrayList([:0]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var entries: sys.DirEntries = .{ .fd = fd };
    while (try entries.next()) |e| try names.append(gpa, try gpa.dupeZ(u8, e.name));
    // Entries are collected first: removing while reading would skip some.
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

    // Containers of earlier launches in this working directory.
    if (try container.findPodman(gpa, a, environ.get("PATH") orelse "/usr/bin:/bin")) |podman| {
        const devnull = try sys.openRead(gpa, "/dev/null");
        defer sys.close(devnull);
        // Podman sees the environment a run gives it.
        const envp = try process.Vec.init(a, try state.hostEnv(a, environ, &.{}));
        result.containers = if (opts.dry_run)
            (try container.listLeftovers(gpa, a, podman, root, &envp, devnull)).len
        else
            try container.removeLeftovers(gpa, a, podman, root, &envp, devnull);
    }

    // A killed launch's unfinished attempts may hold the only copy of an
    // output in their previous/, which the next launch moves back: both steps
    // keep them.
    const pending = try records.pendingAttempts(gpa, a, rec, null);
    if (opts.previous) try removePrevious(gpa, a, rec, pending, opts.dry_run, &result, w);

    const keep = opts.keep orelse return result;
    const names = try records.launchNames(gpa, a, rec);
    if (names.len <= keep) return result;
    // Launches that hold the recorded attempt of a rule stay.
    var held: std.StringHashMapUnmanaged(void) = .empty;
    // The plain file, without the journal's corrections: a record that the
    // next launch will drop still keeps its launch until then.
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
        result.bytes += try removeAt(gpa, launches_fd, try a.dupeZ(u8, name), opts.dry_run, 0);
        result.launches += 1;
        try w.print("{s} launch {s}\n", .{ if (opts.dry_run) "would remove" else "removed", name });
    }
    return result;
}

/// Removes the `previous/` directory of every attempt in every launch,
/// with a line for each launch that had any.
fn removePrevious(gpa: Allocator, a: Allocator, rec: []const u8, pending: []const records.Pending, dry: bool, result: *Result, w: *std.Io.Writer) !void {
    for (try records.launchNames(gpa, a, rec)) |launch| {
        const attempts = try std.fs.path.join(a, &.{ rec, "launches", launch, "attempts" });
        var dirs: usize = 0;
        var bytes: u64 = 0;
        for ((try sys.dirNames(gpa, a, attempts)) orelse &.{}) |rule| {
            const rule_dir = try std.fs.path.join(a, &.{ attempts, rule });
            for ((try sys.dirNames(gpa, a, rule_dir)) orelse &.{}) |n| {
                const attempt = try std.fs.path.join(a, &.{ rule_dir, n });
                if (isPending(pending, attempt)) {
                    try w.print("kept {s}/previous: it holds outputs the next launch puts back\n", .{attempt});
                    result.kept_for_recovery += 1;
                    continue;
                }
                const fd = openDir(gpa, attempt) catch continue;
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
        try w.print("{s} previous/ of {d} attempt(s) in launch {s}, {d:.1} MiB\n", .{ if (dry) "would remove" else "removed", dirs, launch, @as(f64, @floatFromInt(bytes)) / 1048576.0 });
    }
}

fn isPending(pending: []const records.Pending, attempt: []const u8) bool {
    for (pending) |p| if (std.mem.eql(u8, p.dir, attempt)) return true;
    return false;
}
