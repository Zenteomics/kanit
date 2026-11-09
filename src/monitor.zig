//! `watch` and `status`: read-only views of a launch, built from its
//! tracker (`tracker.zig`), its attempt files and the running rules' cgroup
//! counters, and the summary a launch ends with.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const cgroup = @import("cgroup.zig");
const tui = @import("tui.zig");
const log = @import("log.zig");
const term = @import("term.zig");
const model = @import("model.zig");
const units = @import("units.zig");
const fields = @import("fields.zig");
const tracker = @import("tracker.zig");
const summary = @import("summary.zig");
const naming = @import("names.zig");
const logging = @import("log.zig");
const Allocator = std.mem.Allocator;
const Tracker = tracker.Tracker;
const Status = tracker.Status;
const str = fields.str;
const int = fields.int;
const get = fields.get;
const float = fields.float;

fn seconds(ns: i128) f64 {
    return @as(f64, @floatFromInt(@max(ns, 0))) / 1e9;
}

pub fn shownPath(a: Allocator, path: []const u8) []const u8 {
    const here = sys.cwd(a) catch return path;
    const below = here.len > 1 and path.len > here.len + 1 and std.mem.startsWith(u8, path, here) and path[here.len] == '/';
    return if (below) path[here.len + 1 ..] else path;
}

pub fn lastLine(gpa: Allocator, a: Allocator, path: []const u8, max: usize) []const u8 {
    const lines = lastLines(gpa, a, path, 1, max);
    return if (lines.len == 0) "" else lines[0];
}

pub fn lastLines(gpa: Allocator, a: Allocator, path: []const u8, n: usize, max: usize) []const []const u8 {
    const tail = sys.readTail(gpa, path, 4096) catch return &.{};
    defer gpa.free(tail);
    var found: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitBackwardsScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        if (found.items.len == n) break;
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len == 0) continue;
        const out = term.blankControls(a.dupe(u8, sys.utf8Text(a, sys.utf8Prefix(line, max)) catch break) catch break);
        found.append(a, out) catch break;
    }
    std.mem.reverse([]const u8, found.items);
    return found.items;
}

pub fn lastOutput(gpa: Allocator, a: Allocator, dir: []const u8, max: usize) []const u8 {
    if (dir.len == 0) return "";
    const line = lastLine(gpa, a, std.fs.path.join(a, &.{ dir, "stderr.log" }) catch return "", max);
    if (line.len > 0) return line;
    return lastLine(gpa, a, std.fs.path.join(a, &.{ dir, "stdout.log" }) catch return "", max);
}

pub fn findLaunch(gpa: Allocator, a: Allocator, root: []const u8, launch: ?[]const u8) !?[]const u8 {
    const rec = try records.recordsDir(a, root);
    if (launch) |id| {
        const dir = try std.fs.path.join(a, &.{ rec, "launches", id });
        if (sys.exists(gpa, dir)) return dir;
        std.debug.print("kanit: no launch {s} recorded in {s}\n", .{ id, rec });
        return null;
    }
    return (try records.latestLaunch(gpa, a, rec)) orelse {
        std.debug.print("kanit: no launch recorded in {s}; kanit run starts one\n", .{rec});
        return null;
    };
}

pub fn watch(gpa: Allocator, io: std.Io, dir: []const u8, once: bool, interval_ms: u64, style: log.Style) !bool {
    var tr = try Tracker.init(gpa, dir);
    defer tr.deinit();
    var late: tui.Late = .{};
    defer late.deinit();
    late.read(gpa, &tr, dir);
    if (!once and term.isTerminal(0) and term.isTerminal(1)) return tui.run(gpa, &tr, &late, interval_ms, style.color, style.marks);
    const tty = term.isTerminal(1);
    var obuf: [16384]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &obuf);
    while (true) {
        _ = try tr.update();
        late.read(gpa, &tr, dir);
        var alive = tr.finished or records.launchActive(gpa, dir);
        if (!alive) alive = (try tr.update()) and tr.finished;
        if (tty and !once) try out.interface.writeAll("\x1b[H\x1b[2J");
        if (!alive) tr.markUnfinished();
        try tui.snapshot(gpa, &out.interface, &tr, &late.links, if (style.cols > 0) style.cols else 120, style.color, style.marks, sys.realNs());
        try out.interface.flush();
        if (!alive) {
            std.debug.print("kanit: launch {s} did not finish: its engine ended without recording its end\n", .{std.fs.path.basename(dir)});
            return false;
        }
        if (once or tr.finished) return true;
        const ts: linux.timespec = .{ .sec = @intCast(interval_ms / 1000), .nsec = @intCast((interval_ms % 1000) * std.time.ns_per_ms) };
        _ = linux.nanosleep(&ts, null);
    }
}

pub fn history(gpa: Allocator, w: *std.Io.Writer, root: []const u8, n: usize, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try records.recordsDir(a, root);
    const names = try records.launchNames(gpa, a, rec);
    const Row = struct {
        launch: []const u8,
        status: []const u8,
        elapsed_s: ?f64 = null,
        completed: u64 = 0,
        reused: u64 = 0,
        failed: u64 = 0,
        blocked: u64 = 0,
        cancelled: u64 = 0,
        @"error": ?[]const u8 = null,
    };
    var rows: std.ArrayList(Row) = .empty;
    var i = names.len;
    const live = records.running(gpa, rec);
    while (i > 0 and rows.items.len < n) {
        i -= 1;
        const path = try std.fs.path.join(a, &.{ rec, "launches", names[i], "summary.json" });
        const text = sys.readFile(gpa, path, records.launch_record_max) catch {
            try rows.append(a, .{ .launch = names[i], .status = if (live and i == names.len - 1) "running" else "unfinished" });
            continue;
        };
        defer gpa.free(text);
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => std.json.Value{ .null = {} },
        };
        if (v != .object) {
            try rows.append(a, .{ .launch = names[i], .status = "unreadable" });
            continue;
        }
        const counts = if (v.object.get("counts")) |c| c else std.json.Value{ .null = {} };
        const cnt = struct {
            fn of(c: std.json.Value, k: []const u8) u64 {
                return if (c == .object) (if (c.object.get(k)) |x| (if (x == .integer and x.integer > 0) @intCast(x.integer) else 0) else 0) else 0;
            }
        }.of;
        try rows.append(a, .{
            .launch = names[i],
            .status = try a.dupe(u8, str(v, "status") orelse "?"),
            .elapsed_s = float(v, "elapsed_s") orelse 0,
            .completed = cnt(counts, "completed"),
            .reused = cnt(counts, "reused"),
            .failed = cnt(counts, "failed"),
            .blocked = cnt(counts, "blocked"),
            .cancelled = cnt(counts, "cancelled") + cnt(counts, "not_started"),
            .@"error" = if (str(v, "error")) |e| try a.dupe(u8, sys.utf8Prefix(e, 100)) else null,
        });
    }
    if (json) {
        try w.print("{f}\n", .{std.json.fmt(rows.items, .{})});
        return;
    }
    try w.print("{s:<30} {s:<13} {s:>8} {s:>10} {s:>7} {s:>7} {s:>8} {s:>10}\n", .{ "LAUNCH", "STATUS", "ELAPSED", "COMPLETED", "REUSED", "FAILED", "BLOCKED", "CANCELLED" });
    for (rows.items) |r| {
        if (r.elapsed_s == null) {
            try w.print("{s:<30} {s}\n", .{ r.launch, r.status });
            continue;
        }
        try w.print("{s:<30} {s:<13} ", .{ r.launch, r.status });
        try units.right(w, 8, units.duration, .{r.elapsed_s.?});
        try w.print(" {d:>10} {d:>7} {d:>7} {d:>8} {d:>10}", .{ r.completed, r.reused, r.failed, r.blocked, r.cancelled });
        if (r.@"error") |e| try w.print("  {s}", .{e});
        try w.writeAll("\n");
    }
}

pub fn status(gpa: Allocator, io: std.Io, dir: []const u8, human: bool, style: logging.Style) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (human) {
        var buf: [16384]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(io, &buf);
        try summary.write(gpa, &out.interface, dir, style);
        try out.interface.flush();
        return sys.exists(gpa, try std.fs.path.join(a, &.{ dir, "summary.json" })) or records.launchActive(gpa, dir);
    }
    const text = sys.readFile(gpa, try std.fs.path.join(a, &.{ dir, "summary.json" }), records.launch_record_max) catch |err| switch (err) {
        error.FileNotFound => {
            const active = records.launchActive(gpa, dir);
            if (!active) std.debug.print("kanit: launch {s} did not finish: its engine ended without recording its end\n", .{std.fs.path.basename(dir)});
            return try runningJson(gpa, dir, if (active) "running" else "unfinished") and active;
        },
        else => return err,
    };
    defer gpa.free(text);
    _ = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            std.debug.print("kanit: {s}/summary.json is not valid JSON, so the launch's result cannot be shown; its events and attempt records remain\n", .{dir});
            return false;
        },
    };
    try sys.writeAll(1, text);
    return true;
}

fn runningJson(gpa: Allocator, dir: []const u8, status_text: []const u8) !bool {
    var tr = try Tracker.init(gpa, dir);
    defer tr.deinit();
    _ = try tr.update();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Failure = struct { rule: []const u8, status: []const u8, reason: []const u8, stderr: ?[]const u8, diagnostics: []const []const u8 };
    const ChangedOutput = struct { rule: []const u8, path: []const u8 };
    var failures: std.ArrayList(Failure) = .empty;
    for (tr.rules.items) |r| switch (r.status) {
        .failed, .blocked, .cancelled => try failures.append(a, .{
            .rule = r.name,
            .status = @tagName(r.status),
            .reason = r.reason,
            .stderr = if (r.dir.len > 0) try std.fs.path.join(a, &.{ r.dir, "stderr.log" }) else null,
            .diagnostics = if (r.dir.len > 0) try records.keptDiagnostics(gpa, a, r.dir) else &.{},
        }),
        else => {},
    };
    const waiting = tr.count(.waiting) + tr.count(.retrying);
    const pending = tr.count(.pending);
    const doc = .{
        .engine = tr.engine,
        .engine_key = tr.engine_key,
        .launch = std.fs.path.basename(dir),
        .status = status_text,
        .counts = .{
            .completed = tr.count(.completed),
            .reused = tr.count(.reused),
            .failed = tr.count(.failed),
            .blocked = tr.count(.blocked),
            .cancelled = tr.count(.cancelled),
            .not_started = waiting + pending,
            .running = tr.count(.running) + tr.count(.cancelling),
            .waiting = waiting,
            .pending = pending,
        },
        .selected = tr.selected,
        .elapsed_s = if (tr.started_ns > 0) seconds(sys.realNs() - tr.started_ns) else 0,
        .finished = @as(?[]const u8, null),
        .@"error" = @as(?[]const u8, null),
        .engine_cost = @as(?u8, null),
        .launch_dir = dir,
        .failures = failures.items,
        .changed_outputs = @as([]const ChangedOutput, &.{}),
        .previous_bytes = tr.previous_bytes,
    };
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.print("{f}\n", .{std.json.fmt(doc, .{})});
    try sys.writeAll(1, w.written());
    return true;
}
