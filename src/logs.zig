//! `kanit logs RULE`: the standard output and error of a rule's attempt,
//! and the diagnostics a failed attempt kept, found without browsing
//! `.workz/launches`. By default the newest attempt
//! in the newest launch that ran the rule, else the attempt recorded in
//! `state.json`; without a rule, the failed attempts of the newest launch.
//! Each stream opens with a line naming the rule, the attempt, how it ended
//! and the stream's size. `--follow` streams them until the attempt ends,
//! and `-n N` starts at the last N lines.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const state = @import("state.zig");
const Tracker = @import("tracker.zig").Tracker;
const fields = @import("fields.zig");
const units = @import("units.zig");
const Allocator = std.mem.Allocator;

pub const Stream = enum { both, stdout, stderr };

pub const Options = struct {
    launch: ?[]const u8 = null,
    attempt: ?u32 = null,
    stream: Stream = .both,
    follow: bool = false,
    lines: ?usize = null,
};

pub const Heading = struct {
    word: []const u8,
    color: bool = false,
    always: bool = false,
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

fn ending(gpa: Allocator, a: Allocator, dir: []const u8) []const u8 {
    const text = sys.readFile(gpa, std.fs.path.join(a, &.{ dir, "record.json" }) catch return "running", 1 << 20) catch return "running";
    defer gpa.free(text);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch return "unreadable record";
    const status = a.dupe(u8, fields.str(v, "status") orelse "?") catch return "?";
    const reason = fields.str(v, "reason") orelse "";
    for ([_][]const u8{ "timed out", "out of memory" }) |kind| if (std.mem.startsWith(u8, reason, kind))
        return std.fmt.allocPrint(a, "{s}, {s}", .{ status, kind }) catch status;
    if (fields.int(v, "exit_code")) |c| if (c != 0) return std.fmt.allocPrint(a, "{s}, exit {d}", .{ status, c }) catch status;
    if (fields.int(v, "signal")) |n| return std.fmt.allocPrint(a, "{s}, signal {d}", .{ status, n }) catch status;
    return status;
}

fn heading(gpa: Allocator, a: Allocator, w: *std.Io.Writer, h: Heading, what: []const u8, dir: []const u8, path: []const u8) !void {
    const size: ?u64 = if (sys.stat(gpa, path) catch null) |id| id.size else null;
    const number = std.fs.path.basename(dir);
    const attempt = std.fmt.parseInt(u32, number, 10) catch 0;
    try w.print("{s}{s}  {s}  attempt {d}  {s}  ", .{ if (h.color) "\x1b[1m" else "", what, h.word, attempt, ending(gpa, a, dir) });
    if (size) |n| {
        if (n == 0) try w.writeAll("(empty)") else try units.bytes(w, n);
    } else try w.writeAll("(none)");
    try w.print("{s}\n", .{if (h.color) "\x1b[0m" else ""});
}

pub fn show(gpa: Allocator, a: Allocator, w: *std.Io.Writer, dir: []const u8, opts: Options, h: Heading) !void {
    const names: []const []const u8 = switch (opts.stream) {
        .both => &.{ "stdout.log", "stderr.log" },
        .stdout => &.{"stdout.log"},
        .stderr => &.{"stderr.log"},
    };
    if (!opts.follow) {
        for (names) |n| {
            const path = try std.fs.path.join(a, &.{ dir, n });
            if (opts.stream == .both or h.always) try heading(gpa, a, w, h, n[0..6], dir, path);
            _ = try copy(gpa, w, path, try start(gpa, path, opts.lines));
        }
        if (opts.stream == .both) try diagnostics(gpa, a, w, dir, h);
        return;
    }
    var offsets = [_]u64{ 0, 0 };
    const record = try std.fs.path.join(a, &.{ dir, "record.json" });
    var paths: [2][]const u8 = undefined;
    for (names, 0..) |n, k| {
        paths[k] = try std.fs.path.join(a, &.{ dir, n });
        offsets[k] = try start(gpa, paths[k], opts.lines);
    }
    const launch_dir = std.fs.path.dirname(std.fs.path.dirname(std.fs.path.dirname(dir) orelse dir) orelse dir) orelse dir;
    while (true) {
        const done = sys.exists(gpa, record) or !records.launchActive(gpa, launch_dir);
        for (names, 0..) |_, k| offsets[k] = try copy(gpa, w, paths[k], offsets[k]);
        try w.flush();
        if (done) {
            if (opts.stream == .both) try diagnostics(gpa, a, w, dir, h);
            return;
        }
        const ts: linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
}

fn diagnostics(gpa: Allocator, a: Allocator, w: *std.Io.Writer, dir: []const u8, h: Heading) !void {
    const base = try std.fs.path.join(a, &.{ dir, "diagnostics" });
    for (try records.keptDiagnostics(gpa, a, dir)) |p| {
        const name = if (std.mem.startsWith(u8, p, base) and p.len > base.len + 1) p[base.len + 1 ..] else p;
        try heading(gpa, a, w, h, try std.fmt.allocPrint(a, "diagnostics {s}", .{name}), dir, p);
        _ = try copy(gpa, w, p, 0);
    }
}

fn start(gpa: Allocator, path: []const u8, lines: ?usize) !u64 {
    const n = lines orelse return 0;
    const fd = sys.openRead(gpa, path) catch return 0;
    defer sys.close(fd);
    const size = (try sys.statFd(fd)).size;
    var end = size;
    var seen: usize = 0;
    var buf: [65536]u8 = undefined;
    if (end > 0) {
        var last: [1]u8 = undefined;
        if ((try sys.check(linux.pread(fd, &last, 1, @intCast(end - 1)))) == 1 and last[0] == '\n') end -= 1;
    }
    var at = end;
    while (at > 0) {
        const len: usize = @intCast(@min(at, buf.len));
        at -= len;
        const got = try sys.check(linux.pread(fd, &buf, len, @intCast(at)));
        var k = got;
        while (k > 0) {
            k -= 1;
            if (buf[k] != '\n') continue;
            seen += 1;
            if (seen == n) return at + k + 1;
        }
    }
    return 0;
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
