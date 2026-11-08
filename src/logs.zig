//! `kanit logs RULE`: the standard output and error of a rule's attempt,
//! and the diagnostics a failed attempt kept, found without browsing
//! `.workz/launches`. By default the newest attempt
//! in the newest launch that ran the rule, else the attempt recorded in
//! `state.json`. `--follow` streams them until the attempt ends.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const state = @import("state.zig");
const Tracker = @import("tracker.zig").Tracker;
const Allocator = std.mem.Allocator;

pub const Stream = enum { both, stdout, stderr };

pub const Options = struct {
    launch: ?[]const u8 = null,
    attempt: ?u32 = null,
    stream: Stream = .both,
    follow: bool = false,
};

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
        const numbers = (try records.attemptNames(gpa, a, rule_dir)) orelse continue;
        if (numbers.len > 0) return try std.fs.path.join(a, &.{ rule_dir, numbers[numbers.len - 1] });
    }
    if (opts.launch != null) return null;
    var st = try state.load(gpa, rec);
    defer st.deinit();
    const e = st.data.rules.map.get(rule) orelse return null;
    return if (sys.exists(gpa, e.attempt)) try a.dupe(u8, e.attempt) else null;
}

pub fn awaitAttempt(gpa: Allocator, a: Allocator, root: []const u8, rule: []const u8) !?[]const u8 {
    const rec = try records.recordsDir(a, root);
    const launch = (try records.latestLaunch(gpa, a, rec)) orelse return null;
    var tr = try Tracker.init(gpa, launch);
    defer tr.deinit();
    while (records.launchActive(gpa, launch)) {
        _ = try tr.update();
        if (tr.started_ns != 0) {
            const i = tr.index.get(rule) orelse return null;
            const r = tr.rules.items[i];
            if (r.dir.len > 0) return try a.dupe(u8, r.dir);
            if (r.status != .pending and r.status != .waiting) return null;
        }
        const ts: linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
    return null;
}

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
        if (opts.stream == .both) try diagnostics(gpa, a, w, dir);
        return;
    }
    var offsets = [_]u64{ 0, 0 };
    const record = try std.fs.path.join(a, &.{ dir, "record.json" });
    var paths: [2][]const u8 = undefined;
    for (names, 0..) |n, k| paths[k] = try std.fs.path.join(a, &.{ dir, n });
    const launch_dir = std.fs.path.dirname(std.fs.path.dirname(std.fs.path.dirname(dir) orelse dir) orelse dir) orelse dir;
    while (true) {
        const done = sys.exists(gpa, record) or !records.launchActive(gpa, launch_dir);
        for (names, 0..) |_, k| offsets[k] = try copy(gpa, w, paths[k], offsets[k]);
        try w.flush();
        if (done) {
            if (opts.stream == .both) try diagnostics(gpa, a, w, dir);
            return;
        }
        const ts: linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
}

fn diagnostics(gpa: Allocator, a: Allocator, w: *std.Io.Writer, dir: []const u8) !void {
    for (try records.keptDiagnostics(gpa, a, dir)) |p| {
        try w.print("==> {s} <==\n", .{p});
        _ = try copy(gpa, w, p, 0);
    }
}

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
