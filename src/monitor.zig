//! `watch` and `status`: read-only views of a launch, built from its
//! tracker (`tracker.zig`), its attempt files and the running rules' cgroup
//! counters, and the summary a launch ends with.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const cgroup = @import("cgroup.zig");
const tui = @import("tui.zig");
const term = @import("term.zig");
const model = @import("model.zig");
const units = @import("units.zig");
const fields = @import("fields.zig");
const tracker = @import("tracker.zig");
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

/// A cgroup counter in bytes, right-aligned in `width` columns, or `-`.
fn memory(w: *std.Io.Writer, width: usize, n: ?u64) !void {
    const v = n orelse return w.print("{s:>[1]}", .{ "-", width });
    try units.right(w, width, units.size, .{@as(f64, @floatFromInt(v)) / 1048576.0});
}

/// A path as shown to a person: relative to the current directory when it
/// lies below it, else as given.
pub fn shownPath(a: Allocator, path: []const u8) []const u8 {
    const here = sys.cwd(a) catch return path;
    const below = here.len > 1 and path.len > here.len + 1 and std.mem.startsWith(u8, path, here) and path[here.len] == '/';
    return if (below) path[here.len + 1 ..] else path;
}

/// The WORKFLOW argument that names a launch's workflow from here: null for
/// `workflow.toml` in the current directory, the default.
fn workflowArg(gpa: Allocator, a: Allocator, launch_dir: []const u8) !?[]const u8 {
    const text = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }), 1 << 20) catch return null;
    defer gpa.free(text);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch return null;
    const path = str(v, "workflow") orelse return null;
    const shown = shownPath(a, path);
    return if (std.mem.eql(u8, shown, "workflow.toml")) null else shown;
}

/// The last non-empty line of a file, with control characters blanked and
/// cut to `max` bytes; allocated in `a`.
pub fn lastLine(gpa: Allocator, a: Allocator, path: []const u8, max: usize) []const u8 {
    const lines = lastLines(gpa, a, path, 1, max);
    return if (lines.len == 0) "" else lines[0];
}

/// The last `n` non-empty lines of a file, oldest first, with control
/// characters blanked, each cut to `max` bytes without splitting a character
/// and made valid UTF-8; allocated in `a`.
pub fn lastLines(gpa: Allocator, a: Allocator, path: []const u8, n: usize, max: usize) []const []const u8 {
    const tail = sys.readTail(gpa, path, 4096) catch return &.{};
    defer gpa.free(tail);
    var found: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitBackwardsScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        if (found.items.len == n) break;
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len == 0) continue;
        const out = a.dupe(u8, sys.utf8Text(a, sys.utf8Prefix(line, max)) catch break) catch break;
        for (out) |*c| if (c.* < 0x20 or c.* == 0x7f) {
            c.* = ' ';
        };
        found.append(a, out) catch break;
    }
    std.mem.reverse([]const u8, found.items);
    return found.items;
}

/// The latest output line of an attempt: its standard error, else its
/// standard output.
pub fn lastOutput(gpa: Allocator, a: Allocator, dir: []const u8, max: usize) []const u8 {
    if (dir.len == 0) return "";
    const line = lastLine(gpa, a, std.fs.path.join(a, &.{ dir, "stderr.log" }) catch return "", max);
    if (line.len > 0) return line;
    return lastLine(gpa, a, std.fs.path.join(a, &.{ dir, "stdout.log" }) catch return "", max);
}

/// The plain text view: header, running tasks with live counters, failures.
/// `alive` is false for a launch whose engine ended without recording its
/// end: nothing of it runs any longer.
pub fn render(gpa: Allocator, w: *std.Io.Writer, t: *const Tracker, now_ns: i128, alive: bool) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try w.print("launch {s}  ", .{t.launch});
    if (t.finished) {
        try w.print("{s}", .{t.final_status});
        if (t.final_error.len > 0) try w.print(": {s}", .{t.final_error});
    } else if (!alive) {
        try w.writeAll("unfinished: its engine ended without recording its end");
    } else {
        // Without a readable event the start is unknown, not the epoch.
        if (t.started_ns == 0) try w.writeAll("running, started at an unknown time") else {
            try w.writeAll("running for ");
            try units.duration(w, seconds(now_ns - t.started_ns));
        }
    }
    if (t.unreadable_lines > 0) try w.print("\n{d} {s} of events.jsonl could not be read and {s} left out", .{ t.unreadable_lines, if (t.unreadable_lines == 1) "line" else "lines", if (t.unreadable_lines == 1) "is" else "are" });
    try w.print("\n{d} selected:", .{t.selected});
    for (std.enums.values(Status)) |s| {
        const k = t.count(s);
        if (k > 0) try w.print(" {d} {s},", .{ k, s.label() });
    }
    try w.print(" {d} done\n", .{t.count(.completed) + t.count(.reused)});
    for (t.shared.items) |s| try w.print("shared {s}: {s}\n", .{ s.name, s.state });

    // An ended launch has nothing running; its summary is `workz status`.
    if (!t.finished and alive) {
        try w.writeAll("\nRUNNING                                      ATT   ELAPSED   MEM NOW  MEM PEAK  LAST OUTPUT\n");
        var shown: usize = 0;
        for (t.rules.items) |r| {
            if (!r.status.active()) continue;
            shown += 1;
            try w.print("{f} {d:>3}  ", .{ units.field(r.name, 44), r.attempt });
            try units.right(w, 8, units.duration, .{seconds(now_ns - r.started_ns)});
            try w.writeAll("  ");
            try memory(w, 8, if (r.cg) |cg| cgroup.readNumber(gpa, cg, "memory.current") else null);
            try w.writeAll("  ");
            try memory(w, 8, if (r.cg) |cg| cgroup.readNumber(gpa, cg, "memory.peak") else null);
            try w.print("  {s}\n", .{lastOutput(gpa, a, r.dir, 60)});
        }
        if (shown == 0) try w.writeAll("(none)\n");
    }

    var failures: usize = 0;
    for (t.rules.items) |r| {
        if (r.status != .failed) continue;
        if (failures == 0) try w.writeAll("\nFAILED\n");
        failures += 1;
        if (failures > 10) continue;
        try w.print("{s}: {s}", .{ r.name, r.reason });
        if (r.dir.len > 0) try w.print("  ({s}/stderr.log)", .{shownPath(a, r.dir)});
        try w.writeAll("\n");
    }
    if (failures > 10) try w.print("... and {d} more\n", .{failures - 10});
    var blocked: std.ArrayList([]const u8) = .empty;
    for (t.rules.items) |r| if (r.status == .blocked) try blocked.append(a, r.name);
    if (blocked.items.len > 0) {
        try w.writeAll("\nBLOCKED\n");
        try writeNames(w, blocked.items, 10);
        try w.writeAll("\n");
    }
}

/// Up to `most` of `names`, joined by commas, and how many more there are.
fn writeNames(w: *std.Io.Writer, names: []const []const u8, most: usize) !void {
    for (names[0..@min(names.len, most)], 0..) |n, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", n });
    if (names.len > most) try w.print(" and {d} more", .{names.len - most});
}

/// The launch to show: the one named `launch` by ID, else the newest. Null,
/// with the reason printed, when there is none.
pub fn findLaunch(gpa: Allocator, a: Allocator, root: []const u8, launch: ?[]const u8) !?[]const u8 {
    const rec = try records.recordsDir(a, root);
    if (launch) |id| {
        const dir = try std.fs.path.join(a, &.{ rec, "launches", id });
        if (sys.exists(gpa, dir)) return dir;
        std.debug.print("workz: no launch {s} recorded in {s}\n", .{ id, rec });
        return null;
    }
    return (try records.latestLaunch(gpa, a, rec)) orelse {
        std.debug.print("workz: no launch recorded in {s}; workz run starts one\n", .{rec});
        return null;
    };
}

/// Shows the launch in `dir`: interactively when both standard input and
/// output are terminals and `once` is not set; otherwise as text, refreshed
/// every `interval_ms` until the launch finishes, or once.
pub fn watch(gpa: Allocator, io: std.Io, dir: []const u8, once: bool, interval_ms: u64, color: bool) !bool {
    var tr = try Tracker.init(gpa, dir);
    defer tr.deinit();
    if (!once and term.isTerminal(0) and term.isTerminal(1)) return tui.run(gpa, &tr, interval_ms, color);
    const tty = term.isTerminal(1);
    var obuf: [16384]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &obuf);
    while (true) {
        _ = try tr.update();
        // A launch whose engine died never records its end; one that ended
        // between the two reads has recorded it.
        var alive = tr.finished or records.launchActive(gpa, dir);
        if (!alive) alive = (try tr.update()) and tr.finished;
        if (tty and !once) try out.interface.writeAll("\x1b[H\x1b[2J");
        try render(gpa, &out.interface, &tr, sys.realNs(), alive);
        try out.interface.flush();
        if (!alive) {
            std.debug.print("workz: launch {s} did not finish: its engine ended without recording its end\n", .{std.fs.path.basename(dir)});
            return false;
        }
        if (once or tr.finished) return true;
        const ts: linux.timespec = .{ .sec = @intCast(interval_ms / 1000), .nsec = @intCast((interval_ms % 1000) * std.time.ns_per_ms) };
        _ = linux.nanosleep(&ts, null);
    }
}

/// One line per launch, newest first, for the last `n`: start, status,
/// elapsed time, counts and the error of a failed launch.
pub fn history(gpa: Allocator, w: *std.Io.Writer, root: []const u8, n: usize) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try records.recordsDir(a, root);
    const names = try records.launchNames(gpa, a, rec);
    try w.writeAll("LAUNCH                          STATUS         ELAPSED  DONE  FAILED  CANCELLED\n");
    var shown: usize = 0;
    var i = names.len;
    const live = records.running(gpa, rec);
    while (i > 0 and shown < n) : (shown += 1) {
        i -= 1;
        const path = try std.fs.path.join(a, &.{ rec, "launches", names[i], "summary.json" });
        const text = sys.readFile(gpa, path, 1 << 20) catch {
            // No summary: the newest launch while a run holds the lock runs;
            // any other ended without recording its end, as a killed engine.
            try w.print("{s:<31} {s}\n", .{ names[i], if (live and i == names.len - 1) "running" else "unfinished" });
            continue;
        };
        defer gpa.free(text);
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => std.json.Value{ .null = {} },
        };
        // A damaged summary keeps its row, so the list still shows every launch.
        if (v != .object) {
            try w.print("{s:<31} {s}\n", .{ names[i], "unreadable" });
            continue;
        }
        const counts = if (v.object.get("counts")) |c| c else std.json.Value{ .null = {} };
        const cnt = struct {
            fn of(c: std.json.Value, k: []const u8) u64 {
                return if (c == .object) (if (c.object.get(k)) |x| (if (x == .integer and x.integer > 0) @intCast(x.integer) else 0) else 0) else 0;
            }
        }.of;
        const done = cnt(counts, "completed") + cnt(counts, "reused");
        const bad = cnt(counts, "failed") + cnt(counts, "blocked");
        const other = cnt(counts, "cancelled") + cnt(counts, "not_started");
        const elapsed = float(v, "elapsed_s") orelse 0;
        try w.print("{s:<31} {s:<13} ", .{ names[i], str(v, "status") orelse "?" });
        try units.right(w, 8, units.duration, .{elapsed});
        try w.print(" {d:>5} {d:>7} {d:>10}", .{ done, bad, other });
        if (str(v, "error")) |e| try w.print("  {s}", .{sys.utf8Prefix(e, 100)});
        try w.writeAll("\n");
    }
}

/// Writes a readable summary of an ended launch from its records: how it
/// ended and how long it took, the counts, its slowest rules or its
/// failures, where its records are, and what to run next.
pub fn writeSummary(gpa: Allocator, a: Allocator, w: *std.Io.Writer, launch_dir: []const u8, color: bool) !void {
    const s: term.Style = .{ .on = color };
    const text = try sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "summary.json" }), 1 << 20);
    defer gpa.free(text);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always });
    const outcome = str(v, "status") orelse "?";
    const elapsed = float(v, "elapsed_s") orelse 0;
    const counts = if (v == .object) v.object.get("counts") else null;
    const count = struct {
        fn of(c: ?std.json.Value, k: []const u8) u64 {
            const o = c orelse return 0;
            return if (int(o, k)) |n| @intCast(n) else 0;
        }
    }.of;
    const completed = count(counts, "completed");
    const reused = count(counts, "reused");
    const failed = count(counts, "failed");
    const blocked = count(counts, "blocked");
    const cancelled = count(counts, "cancelled");
    const not_started = count(counts, "not_started");
    const selected = if (int(v, "selected")) |n| @as(u64, @intCast(n)) else 0;
    // The label column holds the outcome badge and one space after it.
    const col = @max(outcome.len + 3, 10);
    const label = struct {
        fn put(wr: *std.Io.Writer, st: term.Style, width: usize, name: []const u8) !void {
            try wr.print(" {s}{s}{s}", .{ st.dim(), name, st.reset() });
            try wr.splatByteAll(' ', width -| name.len);
        }
    }.put;

    const badge = if (std.mem.eql(u8, outcome, "completed")) "\x1b[42;30;1m" else if (std.mem.eql(u8, outcome, "interrupted") or std.mem.eql(u8, outcome, "stopped")) "\x1b[45;30;1m" else "\x1b[41;97;1m";
    if (color) {
        try w.print(" {s} {s} \x1b[0m", .{ badge, outcome });
        try w.splatByteAll(' ', col - (outcome.len + 2));
    } else try label(w, s, col, outcome);
    var dur: [32]u8 = undefined;
    var dw: std.Io.Writer = .fixed(&dur);
    units.duration(&dw, elapsed) catch {};
    const took = dw.buffered();
    if (std.mem.eql(u8, outcome, "refused")) {
        try w.print("{s}\n", .{str(v, "error") orelse ""});
    } else if (std.mem.eql(u8, outcome, "completed")) {
        try units.count(w, selected, "rule", "rules");
        try w.print(" in {s}: {d} ran, {d} reused", .{ took, completed, reused });
        if (cancelled > 0) try w.print(", {d} cancelled", .{cancelled});
        try w.writeAll("\n");
    } else {
        try w.print("after {s}: {d} completed, {d} reused", .{ took, completed, reused });
        if (failed > 0) try w.print(", {s}{d} failed{s}", .{ s.red(), failed, s.reset() });
        if (blocked > 0) try w.print(", {d} blocked", .{blocked});
        if (cancelled > 0) try w.print(", {d} cancelled", .{cancelled});
        if (not_started > 0) try w.print(", {d} not started", .{not_started});
        try w.writeAll("\n");
        if (str(v, "error")) |e| {
            try label(w, s, col, "error");
            try w.print("{s}{s}{s}\n", .{ s.red(), e, s.reset() });
        }
    }

    // The last attempt of each rule, from the attempt records.
    const rows = model.attempts(gpa, a, launch_dir, null) catch &.{};
    var last: std.ArrayList(model.Attempt) = .empty;
    for (rows, 0..) |r, i| {
        if (i + 1 < rows.len and std.mem.eql(u8, rows[i + 1].rule, r.rule)) continue;
        try last.append(a, r);
    }
    // Up to five failures, their reasons aligned after the longest name.
    const max_failures = 5;
    var failures: usize = 0;
    var name_w: usize = 0;
    for (last.items) |r| if (!std.mem.eql(u8, r.status, "completed")) {
        if (failures < max_failures) name_w = @max(name_w, @min(r.rule.len, 40));
        failures += 1;
    };
    var shown: usize = 0;
    for (last.items) |r| {
        if (std.mem.eql(u8, r.status, "completed")) continue;
        if (shown == max_failures) break;
        try label(w, s, col, if (shown == 0) "failures" else "");
        try w.print("{s}{s}{s}", .{ s.bold(), r.rule, s.reset() });
        try w.splatByteAll(' ', name_w -| r.rule.len + 2);
        try w.print("{s}{s}{s}\n", .{ s.red(), r.reason, s.reset() });
        // The attempt's last error line, unless the reason already holds it.
        const said = if (r.dir.len == 0) "" else lastLine(gpa, a, try std.fs.path.join(a, &.{ r.dir, "stderr.log" }), 160);
        if (said.len > 0 and std.mem.indexOf(u8, r.reason, said) == null) {
            try label(w, s, col, "");
            try w.splatByteAll(' ', name_w + 2);
            try w.print("{s}| {s}{s}\n", .{ s.dim(), said, s.reset() });
        }
        // The last line of each diagnostics file it kept, after its name.
        for (r.diagnostics) |d| {
            const line = lastLine(gpa, a, try std.fs.path.join(a, &.{ r.dir, "diagnostics", d }), 160);
            if (line.len == 0 or std.mem.indexOf(u8, r.reason, line) != null) continue;
            try label(w, s, col, "");
            try w.splatByteAll(' ', name_w + 2);
            try w.print("{s}| {s}: {s}{s}\n", .{ s.dim(), d, line, s.reset() });
        }
        shown += 1;
    }
    if (failures > shown) {
        try label(w, s, col, "");
        try w.print("and {d} more; workz report lists every attempt\n", .{failures - shown});
    }
    // A blocked rule never ran, so it has no attempt: the summary names it.
    var blocked_names: std.ArrayList([]const u8) = .empty;
    if (get(v, "failures")) |fs| if (fs == .array) for (fs.array.items) |f| {
        if (std.mem.eql(u8, str(f, "status") orelse "", "blocked")) if (str(f, "rule")) |name| try blocked_names.append(a, name);
    };
    if (blocked_names.items.len > 0) {
        try label(w, s, col, "blocked");
        try writeNames(w, blocked_names.items, 8);
        try w.writeAll("\n");
    }
    if (shown == 0 and last.items.len > 0) {
        std.mem.sort(model.Attempt, last.items, {}, struct {
            fn gt(_: void, x: model.Attempt, y: model.Attempt) bool {
                return x.wall_s > y.wall_s;
            }
        }.gt);
        try label(w, s, col, "slowest");
        for (last.items[0..@min(last.items.len, 3)], 0..) |r, i| {
            try w.print("{s}{s} ", .{ if (i == 0) "" else ", ", r.rule });
            try units.duration(w, r.wall_s);
        }
        try w.writeAll("\n");
    }
    // The launch's own page sits among its records; a launch without one
    // shows its directory.
    const page = try std.fs.path.join(a, &.{ launch_dir, "report.html" });
    const has_page = sys.exists(gpa, page);
    try label(w, s, col, if (has_page) "page" else "records");
    try w.print("{s}\n", .{shownPath(a, if (has_page) page else launch_dir)});
    // Earlier outputs this launch replaced stay on disk until removed.
    if (int(v, "previous_bytes")) |b| if (b > 0 and try keepsPrevious(gpa, a, launch_dir)) {
        try label(w, s, col, "previous");
        try units.size(w, @as(f64, @floatFromInt(b)) / 1048576.0);
        try w.print(" of replaced outputs kept; {s}workz clean --previous{s} removes them\n", .{ s.cyan(), s.reset() });
    };
    try label(w, s, col, "next");
    if (std.mem.eql(u8, outcome, "completed")) {
        try w.print("{s}workz report --bottlenecks{s}   what limited this launch\n", .{ s.cyan(), s.reset() });
        if (!has_page) {
            try label(w, s, col, "");
            try w.print("{s}workz report --format html -o report.html{s}   the launch as one page\n", .{ s.cyan(), s.reset() });
        }
    } else if (std.mem.eql(u8, outcome, "refused")) {
        // Outputs changed outside workz: the command that reruns their rules.
        var rules: std.ArrayList([]const u8) = .empty;
        if (get(v, "changed_outputs")) |cs| if (cs == .array) for (cs.array.items) |c| {
            const rule = str(c, "rule") orelse continue;
            for (rules.items) |r| {
                if (std.mem.eql(u8, r, rule)) break;
            } else try rules.append(a, rule);
        };
        if (rules.items.len > 0) {
            try w.print("{s}workz run", .{s.cyan()});
            if (try workflowArg(gpa, a, launch_dir)) |wf| try w.print(" {s}", .{wf});
            for (rules.items) |r| try w.print(" --rerun-rule {s}", .{r});
            try w.print("{s}   run {s} again; the changed bytes go to previous/\n", .{ s.reset(), if (rules.items.len == 1) "it" else "them" });
        } else try w.writeAll("fix the cause above and run the same command again\n");
    } else {
        for (last.items) |r| if (!std.mem.eql(u8, r.status, "completed")) {
            try w.print("{s}workz logs {s}{s}   the output of the failed attempt\n", .{ s.cyan(), r.rule, s.reset() });
            try label(w, s, col, "");
            break;
        };
        try w.writeAll("run the same command again: rules that completed are reused\n");
    }
}

/// Prints the summary of the launch in `dir`: with `human`, the readable
/// summary, else its `summary.json` as written. While the launch runs, it
/// prints the plain view, or with JSON the launch so far in the summary's
/// shape, with status `running`.
pub fn status(gpa: Allocator, io: std.Io, dir: []const u8, human: bool, color: bool) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const summary = sys.readFile(gpa, try std.fs.path.join(a, &.{ dir, "summary.json" }), 1 << 20) catch |err| switch (err) {
        error.FileNotFound => {
            // The view says itself when the launch did not finish.
            if (human) return try watch(gpa, io, dir, true, 1000, color);
            const active = records.launchActive(gpa, dir);
            if (!active) std.debug.print("workz: launch {s} did not finish: its engine ended without recording its end\n", .{std.fs.path.basename(dir)});
            return try runningJson(gpa, dir, if (active) "running" else "unfinished") and active;
        },
        else => return err,
    };
    defer gpa.free(summary);
    // A script reads this as the summary: it must be one, not a fragment.
    _ = std.json.parseFromSliceLeaky(std.json.Value, a, summary, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            std.debug.print("workz: {s}/summary.json is not valid JSON, so the launch's result cannot be shown; its events and attempt records remain\n", .{dir});
            return false;
        },
    };
    if (human) {
        var buf: [16384]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(io, &buf);
        try writeSummary(gpa, a, &out.interface, dir, color);
        try out.interface.flush();
        return true;
    }
    try sys.writeAll(1, summary);
    return true;
}

/// A launch without a summary, running or unfinished, as JSON with the
/// summary's keys and `status_text` as its status, so a script reads one
/// shape: what has not ended is null, and the counts add the rules running,
/// waiting once ready and pending; `not_started` counts the last two.
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

/// Whether some attempt of the launch still keeps earlier outputs in its
/// `previous/` directory.
fn keepsPrevious(gpa: Allocator, a: Allocator, launch_dir: []const u8) !bool {
    const attempts = try std.fs.path.join(a, &.{ launch_dir, "attempts" });
    for ((try sys.dirNames(gpa, a, attempts)) orelse &.{}) |rule| {
        const rule_dir = try std.fs.path.join(a, &.{ attempts, rule });
        for ((try sys.dirNames(gpa, a, rule_dir)) orelse &.{}) |n|
            if (sys.exists(gpa, try std.fs.path.join(a, &.{ rule_dir, n, "previous" }))) return true;
    }
    return false;
}
