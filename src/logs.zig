//! `workz logs RULE`: the standard output and error of a rule's attempt,
//! found without browsing `.workz/launches`. By default the newest attempt
//! in the newest launch that ran the rule, else the attempt recorded in
//! `state.json`. `--follow` streams them until the attempt ends.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const state = @import("state.zig");
const Allocator = std.mem.Allocator;

pub const Stream = enum { both, stdout, stderr };

pub const Options = struct {
    launch: ?[]const u8 = null,
    attempt: ?u32 = null,
    stream: Stream = .both,
    follow: bool = false,
};

/// The attempt directory to show, or null when the rule never ran.
pub fn find(gpa: Allocator, a: Allocator, root: []const u8, rule: []const u8, opts: Options) !?[]const u8 {
    const rec = try records.recordsDir(a, root);
    const launches = if (opts.launch) |id| try a.dupe([]const u8, &.{id}) else try records.launchNames(gpa, a, rec);
    var i = launches.len;
    while (i > 0) {
        i -= 1;
        const rule_dir = try std.fs.path.join(a, &.{ rec, "launches", launches[i], "attempts", rule });
        if (!sys.exists(gpa, rule_dir)) continue;
        if (opts.attempt) |n| {
            const dir = try std.fmt.allocPrint(a, "{s}/{d:0>3}", .{ rule_dir, n });
            return if (sys.exists(gpa, dir)) dir else null;
        }
        // Attempt directories are numbered 001, 002, ...: the last that exists.
        var n: u32 = 1;
        var last: ?[]const u8 = null;
        while (n < 1000) : (n += 1) {
            const dir = try std.fmt.allocPrint(a, "{s}/{d:0>3}", .{ rule_dir, n });
            if (!sys.exists(gpa, dir)) break;
            last = dir;
        }
        if (last) |d| return d;
    }
    if (opts.launch != null) return null;
    var st = try state.load(gpa, rec);
    defer st.deinit();
    const e = st.data.rules.map.get(rule) orelse return null;
    return if (sys.exists(gpa, e.attempt)) try a.dupe(u8, e.attempt) else null;
}

/// Writes the attempt's logs. With `follow`, keeps writing what is appended
/// until the attempt's record exists, then writes the rest and returns.
pub fn show(gpa: Allocator, a: Allocator, w: *std.Io.Writer, dir: []const u8, opts: Options) !void {
    const names: []const []const u8 = switch (opts.stream) {
        .both => &.{ "stdout.log", "stderr.log" },
        .stdout => &.{"stdout.log"},
        .stderr => &.{"stderr.log"},
    };
    if (!opts.follow) {
        for (names) |n| {
            if (opts.stream == .both) try w.print("==> {s}/{s} <==\n", .{ dir, n });
            _ = try copy(gpa, w, try std.fs.path.join(a, &.{ dir, n }), 0);
        }
        return;
    }
    // Following both streams interleaves them as they grow.
    var offsets = [_]u64{ 0, 0 };
    const record = try std.fs.path.join(a, &.{ dir, "record.json" });
    while (true) {
        const done = sys.exists(gpa, record);
        for (names, 0..) |n, k| offsets[k] = try copy(gpa, w, try std.fs.path.join(a, &.{ dir, n }), offsets[k]);
        try w.flush();
        if (done) return;
        const ts: linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
}

/// Writes `path` from `offset` on; returns the new end offset.
fn copy(gpa: Allocator, w: *std.Io.Writer, path: []const u8, offset: u64) !u64 {
    const fd = sys.openRead(gpa, path) catch |err| switch (err) {
        error.FileNotFound => return offset,
        else => return err,
    };
    defer sys.close(fd);
    var at = offset;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try sys.check(linux.pread(fd, &buf, buf.len, @intCast(at)));
        if (n == 0) return at;
        try w.writeAll(buf[0..n]);
        at += n;
    }
}
