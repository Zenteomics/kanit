//! The summary of a launch, live or ended: its outcome and counts, a matrix
//! of samples by steps or a list of steps, the rules that failed with their
//! reasons, the rules those failures blocked, the slowest rules, where the
//! records are, and the commands to type next. `kanit run` prints it when a
//! launch ends and keeps it at the end of `launch.log`; `kanit status` prints
//! it for any launch. It reads the launch's records only: the event stream
//! (`tracker.zig`), the workflow snapshot for step and sample names and the
//! graph, and `summary.json` once the launch has ended. Labels sit in the
//! status-word column of the run log, so the summary lines up with it.
const std = @import("std");
const sys = @import("sys.zig");
const records = @import("records.zig");
const fields = @import("fields.zig");
const units = @import("units.zig");
const names = @import("names.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const tracker = @import("tracker.zig");
const logging = @import("log.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Status = tracker.Status;
const str = fields.str;
const int = fields.int;
const get = fields.get;

const label_column = 10;
const word_width = logging.label_width;
const failures_max = 5;
const blocked_max = 8;
const steps_max = 20;
const matrix_rows_max = 50;

const Cell = enum(u8) { empty, waiting, running, done, reused, not_run, failed };

fn cellOf(s: Status) Cell {
    return switch (s) {
        .pending, .waiting => .waiting,
        .running, .cancelling, .retrying => .running,
        .completed => .done,
        .reused => .reused,
        .failed => .failed,
        .blocked, .cancelled => .not_run,
    };
}

fn worse(x: Cell, y: Cell) Cell {
    const rank = struct {
        fn of(c: Cell) u8 {
            return switch (c) {
                .empty => 0,
                .reused => 1,
                .done => 2,
                .waiting => 3,
                .running => 4,
                .not_run => 5,
                .failed => 6,
            };
        }
    }.of;
    return if (rank(y) > rank(x)) y else x;
}

const ToolVersion = struct { tool: []const u8, command: []const u8, container: ?[]const u8 };

const Snapshot = struct {
    names: names.Names,
    parents: []const []const usize,
    tools: []const ToolVersion,
};

fn snapshot(gpa: Allocator, a: Allocator, launch_dir: []const u8, need_graph: bool) ?Snapshot {
    const info = sys.readFile(gpa, std.fs.path.join(a, &.{ launch_dir, "launch.json" }) catch return null, 1 << 20) catch return null;
    defer gpa.free(info);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, info, .{ .allocate = .alloc_always }) catch return null;
    const workdir = str(v, "workdir") orelse return null;
    var problem: workflow.Problem = .{};
    defer if (problem.message.len > 0) gpa.free(problem.message);
    var wf = workflow.loadRecorded(gpa, std.fs.path.join(a, &.{ launch_dir, "workflow" }) catch return null, workdir, &problem) catch return null;
    defer wf.deinit();
    const n = names.Names.init(a, wf.rules) catch return null;
    var parents: []const []const usize = &.{};
    if (need_graph) if (graph.build(gpa, &wf, &problem)) |g| {
        var gg = g;
        defer gg.deinit();
        const copy = a.alloc([]const usize, wf.rules.len) catch return null;
        for (copy, gg.parents) |*dst, src| dst.* = a.dupe(usize, src) catch return null;
        parents = copy;
    } else |_| {};
    var tools: std.ArrayList(ToolVersion) = .empty;
    for (wf.rules, n.tool) |r, tool| {
        if (tool.len == 0) continue;
        const command = r.version orelse continue;
        for (tools.items) |t| {
            if (std.mem.eql(u8, t.tool, tool)) break;
        } else tools.append(a, .{ .tool = tool, .command = a.dupe(u8, command) catch return null, .container = if (r.container) |c| a.dupe(u8, c) catch return null else null }) catch return null;
    }
    return .{ .names = n, .parents = parents, .tools = tools.items };
}

pub fn workflowArg(gpa: Allocator, a: Allocator, launch_dir: []const u8) ?[]const u8 {
    const text = sys.readFile(gpa, std.fs.path.join(a, &.{ launch_dir, "launch.json" }) catch return null, 1 << 20) catch return null;
    defer gpa.free(text);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch return null;
    const path = str(v, "workflow") orelse return null;
    const shown = shownPath(a, path);
    return if (std.mem.eql(u8, shown, "workflow.toml")) null else shown;
}

fn shownPath(a: Allocator, path: []const u8) []const u8 {
    const here = sys.cwd(a) catch return path;
    const below = here.len > 1 and path.len > here.len + 1 and std.mem.startsWith(u8, path, here) and path[here.len] == '/';
    return if (below) path[here.len + 1 ..] else path;
}

fn label(w: *Writer, s: logging.Style, name: []const u8) !void {
    try w.splatByteAll(' ', label_column);
    try w.print("{s}{s}{s}", .{ if (s.color) "\x1b[2m" else "", name, if (s.color) "\x1b[0m" else "" });
    try w.splatByteAll(' ', word_width + 2 -| names.columns(name));
}

/// Writes a name in a column of `width`, cut with the `more` mark when it
/// is longer.
fn nameCell(w: *Writer, s: logging.Style, text: []const u8, width: usize) !void {
    if (names.columns(text) <= width or width == 0) return pad(w, text, width);
    const head = logging.cut(text, width - 1);
    try w.print("{s}{s}", .{ head, s.marks.more });
    try w.splatByteAll(' ', width - 1 - names.columns(head));
}

/// The width of a column of names: the longest, held to `most` on a
/// terminal, where longer names are cut.
fn nameWidth(s: logging.Style, longest: usize, most: usize) usize {
    return if (s.cols > 0) @min(longest, most) else longest;
}

fn pad(w: *Writer, text: []const u8, width: usize) !void {
    try w.writeAll(text);
    try w.splatByteAll(' ', width -| names.columns(text));
}

fn on(s: logging.Style, code: []const u8) []const u8 {
    return if (s.color) code else "";
}

fn off(s: logging.Style) []const u8 {
    return if (s.color) "\x1b[0m" else "";
}

const Row = struct {
    step: []const u8,
    sample: []const u8,
    word: []const u8,
    status: Status,
    reason: []const u8,
    wall_s: f64,
    index: ?usize,
};

pub fn write(gpa: Allocator, w: *Writer, launch_dir: []const u8, style: logging.Style) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tr = try tracker.Tracker.init(gpa, launch_dir);
    defer tr.deinit();
    _ = try tr.update();
    const live = !tr.finished and records.launchActive(gpa, launch_dir);
    if (!tr.finished and !live) tr.markUnfinished();
    const summary_text = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "summary.json" }), records.launch_record_max) catch null;
    defer if (summary_text) |t| gpa.free(t);
    const sum: ?std.json.Value = if (summary_text) |t| std.json.parseFromSliceLeaky(std.json.Value, a, t, .{ .allocate = .alloc_always }) catch null else null;

    var blocked_n: usize = 0;
    for (tr.rules.items) |r| blocked_n += @intFromBool(r.status == .blocked);
    const snap = snapshot(gpa, a, launch_dir, blocked_n > 0);

    const rows = try a.alloc(Row, tr.rules.items.len);
    for (tr.rules.items, rows) |r, *row| {
        const idx: ?usize = if (snap) |sn| sn.names.find(r.name) else null;
        const wall: f64 = r.wall_s orelse if (r.started_ns > 0 and r.finished_ns > r.started_ns) @as(f64, @floatFromInt(r.finished_ns - r.started_ns)) / 1e9 else 0;
        row.* = .{
            .step = if (idx) |k| snap.?.names.step[k] else r.name,
            .sample = if (idx) |k| snap.?.names.sample[k] else "",
            .word = if (idx) |k| snap.?.names.word[k] else r.name,
            .status = r.status,
            .reason = r.reason,
            .wall_s = wall,
            .index = idx,
        };
    }
    var widths: names.Widths = .{ .step = 0, .sample = 0 };
    for (rows) |r| if (r.status == .failed or r.status == .blocked) {
        widths.step = @max(widths.step, names.columns(r.step));
        widths.sample = @max(widths.sample, names.columns(r.sample));
    };
    widths.step = nameWidth(style, widths.step, names.step_max);
    widths.sample = nameWidth(style, widths.sample, names.sample_max);

    var count: [@typeInfo(Status).@"enum".fields.len]usize = @splat(0);
    for (rows) |r| count[@intFromEnum(r.status)] += 1;
    const c = struct {
        fn of(k: []const usize, s: Status) usize {
            return k[@intFromEnum(s)];
        }
    }.of;
    const done = c(&count, .completed) + c(&count, .reused);
    const running = c(&count, .running) + c(&count, .cancelling) + c(&count, .retrying);
    const waiting = c(&count, .pending) + c(&count, .waiting);

    const outcome: []const u8 = if (live) "running" else if (sum) |v| (str(v, "status") orelse "?") else tr.final_status;
    const elapsed: f64 = if (sum) |v| (fields.float(v, "elapsed_s") orelse 0) else if (tr.started_ns > 0) @as(f64, @floatFromInt((if (live) sys.realNs() else tr.last_ns) - tr.started_ns)) / 1e9 else 0;

    // --- Outcome ---
    try w.splatByteAll(' ', label_column);
    if (style.color) {
        const badge = if (std.mem.eql(u8, outcome, "completed")) "\x1b[42;30;1m" else if (std.mem.eql(u8, outcome, "running")) "\x1b[46;30;1m" else if (std.mem.eql(u8, outcome, "interrupted") or std.mem.eql(u8, outcome, "stopped")) "\x1b[45;30;1m" else "\x1b[41;97;1m";
        try w.print("{s}{s}\x1b[0m", .{ badge, outcome });
    } else try w.writeAll(outcome);
    try w.splatByteAll(' ', word_width + 2 -| outcome.len);
    if (std.mem.eql(u8, outcome, "refused")) {
        try w.print("{s}\n", .{if (sum) |v| str(v, "error") orelse "" else ""});
    } else {
        try logging.thousands(w, done);
        try w.writeAll(" of ");
        try logging.thousands(w, rows.len);
        try w.print(" {s} done {s} ", .{ if (rows.len == 1) "rule" else "rules", if (live) "after" else "in" });
        try units.duration(w, elapsed);
        var first = true;
        const parts = [_]struct { n: usize, what: []const u8, code: []const u8 }{
            .{ .n = c(&count, .reused), .what = "reused", .code = "" },
            .{ .n = running, .what = "running", .code = "\x1b[36m" },
            .{ .n = c(&count, .failed), .what = "failed", .code = "\x1b[31;1m" },
            .{ .n = c(&count, .blocked), .what = "blocked", .code = "" },
            .{ .n = c(&count, .cancelled), .what = "stopped", .code = "" },
            .{ .n = waiting, .what = if (live) "waiting" else "not started", .code = "" },
        };
        for (parts) |p| if (p.n > 0) {
            try w.writeAll(if (first) ": " else ", ");
            first = false;
            try w.writeAll(on(style, p.code));
            try logging.thousands(w, p.n);
            try w.print(" {s}{s}", .{ p.what, if (p.code.len > 0) off(style) else "" });
        };
        try w.writeAll("\n");
    }
    if (sum) |v| if (str(v, "error")) |e| if (!std.mem.eql(u8, outcome, "refused")) {
        try label(w, style, "error");
        try w.print("{s}{s}{s}\n", .{ on(style, "\x1b[31m"), e, off(style) });
    };

    // --- Shape ---
    if (snap) |sn| try shape(a, w, style, sn.names, rows, live);

    // --- Failures ---
    var shown: usize = 0;
    var failed_total: usize = 0;
    var first_failed: ?Row = null;
    for (rows) |r| {
        if (r.status != .failed) continue;
        failed_total += 1;
        if (first_failed == null) first_failed = r;
        if (shown == failures_max) continue;
        try label(w, style, if (shown == 0) "failed" else "");
        try nameCell(w, style, r.step, widths.step);
        try w.writeAll("  ");
        if (widths.sample > 0) {
            try nameCell(w, style, r.sample, widths.sample);
            try w.writeAll("  ");
        }
        const used = label_column + word_width + 2 + widths.step + 2 + if (widths.sample > 0) widths.sample + 2 else 0;
        const room = if (style.cols > used + 4) style.cols - used - 4 else 0;
        const reason = if (style.cols == 0) r.reason else logging.cut(r.reason, room);
        try w.print("{s}{s}{s}{s}\n", .{ on(style, "\x1b[31m"), reason, if (reason.len < r.reason.len) "..." else "", off(style) });
        shown += 1;
    }
    if (failed_total > shown) {
        try label(w, style, "");
        try w.print("and {d} more; kanit report lists every attempt\n", .{failed_total - shown});
    }

    // --- Blocked ---
    var blocked_shown: usize = 0;
    for (rows) |r| {
        if (r.status != .blocked) continue;
        if (blocked_shown == blocked_max) break;
        try label(w, style, if (blocked_shown == 0) "blocked" else "");
        try nameCell(w, style, r.step, widths.step);
        try w.writeAll("  ");
        if (widths.sample > 0) {
            try nameCell(w, style, r.sample, widths.sample);
            try w.writeAll("  ");
        }
        if (cause(&tr, snap, r)) |root| try w.print("after {s} {s}\n", .{ root.word, root.what }) else try w.writeAll("after a rule it needs did not complete\n");
        blocked_shown += 1;
    }
    if (blocked_n > blocked_shown) {
        try label(w, style, "");
        try w.print("and {d} more\n", .{blocked_n - blocked_shown});
    }

    // --- Slowest ---
    if (!live) {
        var top: [3]?Row = .{ null, null, null };
        for (rows) |r| {
            if (r.status != .completed or r.wall_s <= 0) continue;
            var k: usize = 0;
            while (k < top.len) : (k += 1) if (top[k] == null or r.wall_s > top[k].?.wall_s) break;
            if (k == top.len) continue;
            var j = top.len - 1;
            while (j > k) : (j -= 1) top[j] = top[j - 1];
            top[k] = r;
        }
        if (top[0] != null and c(&count, .completed) > 1) {
            var flow: Flow = .{ .w = w, .style = style, .name = "slowest" };
            for (top) |t| if (t) |r| {
                var buf: [256]u8 = undefined;
                var bw: Writer = .fixed(&buf);
                bw.print("{s} ", .{r.word}) catch {};
                units.duration(&bw, r.wall_s) catch {};
                try flow.item(bw.buffered());
            };
            try flow.end();
        }
    }

    // --- Tools ---
    if (snap) |sn| if (sn.tools.len > 0) try toolsLine(gpa, a, w, style, launch_dir, sn.tools);

    // --- Records ---
    const rec = std.fs.path.dirname(std.fs.path.dirname(launch_dir) orelse launch_dir) orelse launch_dir;
    const latest = try std.fs.path.join(a, &.{ rec, "latest" });
    const target = sys.readlink(a, latest) catch "";
    const is_latest = std.mem.endsWith(u8, target, std.fs.path.basename(launch_dir));
    try label(w, style, "records");
    try w.print("{s}/", .{shownPath(a, if (is_latest) latest else launch_dir)});
    if (sys.exists(gpa, try std.fs.path.join(a, &.{ launch_dir, "launch.log" }))) try w.writeAll("   log launch.log");
    if (sys.exists(gpa, try std.fs.path.join(a, &.{ launch_dir, "report.html" }))) try w.writeAll("   page report.html");
    try w.writeAll("\n");
    if (sum) |v| if (int(v, "previous_bytes")) |b| if (b > 0 and try keepsPrevious(gpa, a, launch_dir)) {
        try label(w, style, "previous");
        try units.bytes(w, @intCast(b));
        try w.print(" of replaced outputs kept; {s}kanit clean --previous{s} removes them\n", .{ on(style, "\x1b[36m"), off(style) });
    };

    // --- Next ---
    const wf_arg = workflowArg(gpa, a, launch_dir);
    var hints: std.ArrayList([2][]const u8) = .empty;
    if (live) {
        try hints.append(a, .{ "kanit watch", "follow the launch" });
        if (first_failed) |r| try hints.append(a, .{ try std.fmt.allocPrint(a, "kanit logs {s}", .{r.word}), "the output of the failed attempt" });
    } else if (std.mem.eql(u8, outcome, "completed")) {
        try hints.append(a, .{ "kanit report --bottlenecks", "what limited this launch" });
    } else if (std.mem.eql(u8, outcome, "refused")) {
        var reruns: std.ArrayList(u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        if (sum) |v| if (get(v, "changed_outputs")) |cs| if (cs == .array) for (cs.array.items) |item| {
            const rule = str(item, "rule") orelse continue;
            if ((try seen.getOrPut(a, rule)).found_existing) continue;
            try reruns.print(a, " --rerun-rule {s}", .{if (snap) |sn| (if (sn.names.find(rule)) |k| sn.names.word[k] else rule) else rule});
        };
        if (reruns.items.len > 0) {
            try hints.append(a, .{ try std.fmt.allocPrint(a, "kanit run{s}{s}{s}", .{ if (wf_arg != null) " " else "", wf_arg orelse "", reruns.items }), if (seen.count() == 1) "run it again; the changed bytes go to previous/" else "run them again; the changed bytes go to previous/" });
        } else try hints.append(a, .{ "", "fix the cause above and run the same command again" });
    } else {
        if (first_failed) |r| try hints.append(a, .{ try std.fmt.allocPrint(a, "kanit logs {s}", .{r.word}), "the output of the failed attempt" });
        const again = try std.fmt.allocPrint(a, "kanit run{s}{s}", .{ if (wf_arg != null) " " else "", wf_arg orelse "" });
        try hints.append(a, .{ again, if (done == 0) "run again" else if (done == 1) "run again; 1 rule is reused" else try std.fmt.allocPrint(a, "run again; {d} rules are reused", .{done}) });
    }
    var cmd_w: usize = 0;
    for (hints.items) |h| cmd_w = @max(cmd_w, h[0].len);
    for (hints.items, 0..) |h, k| {
        try label(w, style, if (k == 0) "next" else "");
        if (h[0].len == 0) {
            try w.print("{s}\n", .{h[1]});
            continue;
        }
        try w.print("{s}{s}{s}", .{ on(style, "\x1b[36m"), h[0], off(style) });
        try w.splatByteAll(' ', cmd_w - h[0].len + 3);
        try w.print("{s}\n", .{h[1]});
    }
}

const Root = struct { word: []const u8, what: []const u8 };

fn cause(tr: *const tracker.Tracker, snap: ?Snapshot, r: Row) ?Root {
    const sn = snap orelse return null;
    if (sn.parents.len == 0) return null;
    var at = r.index orelse return null;
    var hops: usize = 0;
    while (hops < 10_000) : (hops += 1) {
        var next: ?usize = null;
        for (sn.parents[at]) |p| {
            const ti = tr.index.get(sn.names.rule[p]) orelse continue;
            switch (tr.rules.items[ti].status) {
                .failed => return .{ .word = sn.names.word[p], .what = "failed" },
                .cancelled => return .{ .word = sn.names.word[p], .what = "was stopped" },
                .pending, .waiting => return .{ .word = sn.names.word[p], .what = "did not start" },
                .blocked => if (next == null) {
                    next = p;
                },
                else => {},
            }
        }
        at = next orelse return null;
    }
    return null;
}

fn shape(a: Allocator, w: *Writer, style: logging.Style, n: names.Names, rows: []const Row, live: bool) !void {
    const nsteps = n.steps.len;
    const step_rules = try a.alloc(u32, nsteps);
    @memset(step_rules, 0);
    const step_done = try a.alloc(u32, nsteps);
    @memset(step_done, 0);
    const step_failed = try a.alloc(u32, nsteps);
    @memset(step_failed, 0);
    const step_blocked = try a.alloc(u32, nsteps);
    @memset(step_blocked, 0);
    const step_stopped = try a.alloc(u32, nsteps);
    @memset(step_stopped, 0);
    const step_running = try a.alloc(u32, nsteps);
    @memset(step_running, 0);
    const step_slowest = try a.alloc(?Row, nsteps);
    @memset(step_slowest, null);
    const step_ran = try a.alloc(u32, nsteps);
    @memset(step_ran, 0);
    const sample_seen = try a.alloc(bool, n.samples.len);
    @memset(sample_seen, false);
    var unsampled = false;
    for (rows) |r| {
        const k = r.index orelse continue;
        const st = n.step_of[k];
        step_rules[st] += 1;
        switch (r.status) {
            .completed, .reused => step_done[st] += 1,
            .failed => step_failed[st] += 1,
            .blocked => step_blocked[st] += 1,
            .cancelled => step_stopped[st] += 1,
            .running, .cancelling, .retrying => step_running[st] += 1,
            else => {},
        }
        if (r.status == .completed) step_ran[st] += 1;
        if (r.status == .completed and (step_slowest[st] == null or r.wall_s > step_slowest[st].?.wall_s)) step_slowest[st] = r;
        if (n.sample_of[k]) |sm| sample_seen[sm] = true else unsampled = true;
    }
    var steps: std.ArrayList(u32) = .empty;
    for (step_rules, 0..) |count, k| if (count > 0) try steps.append(a, @intCast(k));
    var samples: std.ArrayList(u32) = .empty;
    for (sample_seen, 0..) |seen, k| if (seen) try samples.append(a, @intCast(k));
    if (steps.items.len < 2 and samples.items.len < 2) return;
    if (steps.items.len >= rows.len and samples.items.len == 0) return;

    var name_w: usize = word_width;
    for (samples.items) |sm| name_w = @max(name_w, @min(names.columns(n.samples[sm]), names.sample_max));
    var total: usize = label_column + name_w + 2;
    for (steps.items) |st| total += names.columns(n.steps[st].name) + 2;
    const width = if (style.cols > 0) style.cols - 1 else 120;
    if (samples.items.len >= 2 and samples.items.len <= matrix_rows_max and total <= width) {
        const sample_index = try a.alloc(?usize, n.samples.len);
        @memset(sample_index, null);
        for (samples.items, 0..) |sm, row| sample_index[sm] = row;
        const step_index = try a.alloc(?usize, nsteps);
        @memset(step_index, null);
        for (steps.items, 0..) |st, col| step_index[st] = col;
        const height = samples.items.len + @intFromBool(unsampled);
        const cells = try a.alloc(Cell, height * steps.items.len);
        @memset(cells, .empty);
        var present = [_]bool{false} ** @typeInfo(Cell).@"enum".fields.len;
        for (rows) |r| {
            const k = r.index orelse continue;
            const col = step_index[n.step_of[k]] orelse continue;
            const row = if (n.sample_of[k]) |sm| sample_index[sm] orelse continue else samples.items.len;
            const cell = &cells[row * steps.items.len + col];
            cell.* = worse(cell.*, cellOf(r.status));
        }
        for (cells) |cell| present[@intFromEnum(cell)] = true;
        try w.splatByteAll(' ', label_column);
        try w.print("{s}", .{on(style, "\x1b[2m")});
        try pad(w, "samples", name_w + 2);
        for (steps.items, 0..) |st, col| {
            if (col + 1 < steps.items.len) try pad(w, n.steps[st].name, names.columns(n.steps[st].name) + 2) else try w.writeAll(n.steps[st].name);
        }
        try w.print("{s}\n", .{off(style)});
        for (0..height) |row| {
            var last: usize = 0;
            for (0..steps.items.len) |col| {
                if (cells[row * steps.items.len + col] != .empty and cells[row * steps.items.len + col] != .waiting) last = col + 1;
            }
            try w.splatByteAll(' ', label_column);
            const name = if (row < samples.items.len) n.samples[samples.items[row]] else "all";
            if (last == 0) {
                try w.print("{s}\n", .{name});
                continue;
            }
            try pad(w, name, name_w + 2);
            for (steps.items[0..last], 0..) |st, col| {
                const cell = cells[row * steps.items.len + col];
                try mark(w, style, cell);
                if (col + 1 < last) try w.splatByteAll(' ', names.columns(n.steps[st].name) + 1);
            }
            try w.writeAll("\n");
        }
        try w.splatByteAll(' ', label_column + name_w + 2);
        var first = true;
        present[@intFromEnum(Cell.done)] = present[@intFromEnum(Cell.done)] or present[@intFromEnum(Cell.reused)];
        const legend = [_]struct { cell: Cell, text: []const u8 }{
            .{ .cell = .done, .text = "done" },
            .{ .cell = .running, .text = "running" },
            .{ .cell = .failed, .text = "failed" },
            .{ .cell = .not_run, .text = "blocked or stopped" },
        };
        for (legend) |l| if (present[@intFromEnum(l.cell)]) {
            if (!first) try w.writeAll("   ");
            first = false;
            try mark(w, style, l.cell);
            try w.print(" {s}", .{l.text});
        };
        try w.writeAll("\n");
        return;
    }
    var all_done = true;
    var rules_n: usize = 0;
    for (steps.items) |st| {
        all_done = all_done and step_done[st] == step_rules[st];
        rules_n += step_rules[st];
    }
    if (all_done and steps.items.len > 8) {
        try label(w, style, "steps");
        try w.print("{s} all {d} steps done, ", .{ style.marks.ok, steps.items.len });
        try logging.thousands(w, rules_n);
        try w.writeAll(" rules\n");
        return;
    }
    var step_w: usize = 0;
    var tool_w: usize = 0;
    for (steps.items) |st| {
        step_w = @max(step_w, names.columns(n.steps[st].name));
        tool_w = @max(tool_w, names.columns(n.steps[st].tool orelse ""));
    }
    step_w = nameWidth(style, step_w, names.step_max);
    tool_w = nameWidth(style, tool_w, names.tool_max);
    for (steps.items, 0..) |st, k| {
        if (k == steps_max) {
            try label(w, style, "");
            try w.print("and {d} more steps\n", .{steps.items.len - k});
            break;
        }
        try label(w, style, if (k == 0) "steps" else "");
        if (tool_w > 0) {
            try nameCell(w, style, n.steps[st].tool orelse "", tool_w);
            try w.writeAll("  ");
        }
        try nameCell(w, style, n.steps[st].name, step_w);
        try w.writeAll("  ");
        var buf: [128]u8 = undefined;
        var bw: Writer = .fixed(&buf);
        if (step_failed[st] > 0) {
            try bw.print("{s} ", .{style.marks.fail});
        } else if (step_done[st] == step_rules[st]) try bw.print("{s} ", .{style.marks.ok}) else try bw.writeAll("  ");
        try bw.print("{d} of {d} done", .{ step_done[st], step_rules[st] });
        if (step_running[st] > 0) try bw.print(", {d} running", .{step_running[st]});
        if (step_failed[st] > 0) try bw.print(", {d} failed", .{step_failed[st]});
        if (step_blocked[st] > 0) try bw.print(", {d} blocked", .{step_blocked[st]});
        if (step_stopped[st] > 0) try bw.print(", {d} stopped", .{step_stopped[st]});
        const slowest: ?Row = if (!live and step_ran[st] > 1) step_slowest[st] else null;
        const at = label_column + word_width + 2 + (if (tool_w > 0) tool_w + 2 else 0) + step_w + 2 + 32;
        if (slowest) |r| {
            var sb: [256]u8 = undefined;
            var sw: Writer = .fixed(&sb);
            sw.print("slowest {s} ", .{if (r.sample.len > 0) r.sample else r.word}) catch {};
            units.duration(&sw, r.wall_s) catch {};
            if (style.cols == 0 or at + names.columns(sw.buffered()) < style.cols) {
                try pad(w, bw.buffered(), 32);
                try w.writeAll(sw.buffered());
            } else try w.writeAll(bw.buffered());
        } else try w.writeAll(bw.buffered());
        try w.writeAll("\n");
    }
}

fn toolsLine(gpa: Allocator, a: Allocator, w: *Writer, style: logging.Style, launch_dir: []const u8, tools: []const ToolVersion) !void {
    const text = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "versions.json" }), 1 << 20) catch return;
    defer gpa.free(text);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch return;
    const list = get(v, "commands") orelse return;
    if (list != .array) return;
    var flow: Flow = .{ .w = w, .style = style, .name = "tools" };
    for (tools) |t| {
        const version = for (list.array.items) |e| {
            if (!std.mem.eql(u8, str(e, "command") orelse "", t.command)) continue;
            const container = str(e, "container");
            if ((container == null) != (t.container == null)) continue;
            if (container) |cx| if (!std.mem.eql(u8, cx, t.container.?)) continue;
            if (int(e, "exit_code") != 0) break "";
            var it = std.mem.tokenizeAny(u8, str(e, "output") orelse "", "\r\n");
            break logging.versionText(t.tool, std.mem.trim(u8, it.next() orelse "", " \t"));
        } else "";
        if (version.len == 0) continue;
        try flow.item(try std.fmt.allocPrint(a, "{s} {s}", .{ t.tool, version }));
    }
    try flow.end();
}

/// Items after a label, three spaces apart, going on under the label when
/// the next item would pass the width.
const Flow = struct {
    w: *Writer,
    style: logging.Style,
    name: []const u8,
    at: usize = 0,

    fn item(f: *Flow, text: []const u8) !void {
        const width = if (f.style.cols > 0) f.style.cols - 1 else 120;
        const start = label_column + word_width + 2;
        const room = width -| start;
        const shown = if (names.columns(text) > room and room > 1) logging.cut(text, room - 1) else text;
        const more = shown.len < text.len;
        const n = names.columns(shown) + @intFromBool(more);
        if (f.at == 0) {
            try label(f.w, f.style, f.name);
            f.at = start;
        } else if (f.at + 3 + n > width) {
            try f.w.writeAll("\n");
            try label(f.w, f.style, "");
            f.at = start;
        } else {
            try f.w.writeAll("   ");
            f.at += 3;
        }
        try f.w.print("{s}{s}", .{ shown, if (more) f.style.marks.more else "" });
        f.at += n;
    }

    fn end(f: *Flow) !void {
        if (f.at > 0) try f.w.writeAll("\n");
    }
};

fn mark(w: *Writer, style: logging.Style, cell: Cell) !void {
    const m = style.marks;
    switch (cell) {
        .empty => try w.writeAll(" "),
        .done => try w.print("{s}{s}{s}", .{ on(style, "\x1b[32m"), m.ok, off(style) }),
        .reused => try w.print("{s}{s}{s}", .{ on(style, "\x1b[2;32m"), m.ok, off(style) }),
        .running => try w.print("{s}~{s}", .{ on(style, "\x1b[36m"), off(style) }),
        .waiting => try w.writeAll(" "),
        .not_run => try w.print("{s}{s}{s}", .{ on(style, "\x1b[2m"), m.none, off(style) }),
        .failed => try w.print("{s}{s}{s}", .{ on(style, "\x1b[31;1m"), m.fail, off(style) }),
    }
}

fn keepsPrevious(gpa: Allocator, a: Allocator, launch_dir: []const u8) !bool {
    const attempts = try std.fs.path.join(a, &.{ launch_dir, "attempts" });
    for ((try sys.dirNames(gpa, a, attempts)) orelse &.{}) |rule| {
        const rule_dir = try std.fs.path.join(a, &.{ attempts, rule });
        for ((try sys.dirNames(gpa, a, rule_dir)) orelse &.{}) |n|
            if (sys.exists(gpa, try std.fs.path.join(a, &.{ rule_dir, n, "previous" }))) return true;
    }
    return false;
}
