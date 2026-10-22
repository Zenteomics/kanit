//! `workz report --format html`: one self-contained page for a launch, from
//! its records: summary, timeline of every attempt, use of the budget over
//! time, the bottleneck report, the attempt table and the failures with the
//! end of their standard error. No scripts and no remote assets.
const std = @import("std");
const sys = @import("sys.zig");
const report = @import("report.zig");
const monitor = @import("monitor.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Writes `s` with HTML special characters escaped.
pub fn escape(w: *std.Io.Writer, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(rep);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

const Sample = struct { t: f64, threads: f64, cpu: ?f64, mem_mib: ?f64, reserved_mib: f64 };

fn num(v: ?Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn str(v: Value, key: []const u8) []const u8 {
    const x = get(v, key) orelse return "";
    return if (x == .string) x.string else "";
}

fn color(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "completed")) return "#3a7d44";
    if (std.mem.eql(u8, status, "cancelled")) return "#8c6bb1";
    return "#c0392b";
}

const style =
    \\body{font:14px/1.4 system-ui,sans-serif;margin:24px;color:#222}
    \\h1{font-size:20px}h2{font-size:16px;margin-top:28px}
    \\table{border-collapse:collapse;font-size:12px}td,th{padding:2px 8px;border-bottom:1px solid #ddd;text-align:right}
    \\td:first-child,th:first-child{text-align:left}pre{background:#f6f6f6;padding:8px;overflow:auto;font-size:12px}
    \\.facts td,td:nth-child(3),td:nth-child(10){text-align:left}svg{background:#fafafa}details{margin:4px 0}
;

pub fn write(gpa: Allocator, a: Allocator, w: *std.Io.Writer, launch_dir: []const u8) !void {
    const rows = try report.attempts(gpa, a, launch_dir);
    const summary: ?Value = blk: {
        const bytes = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "summary.json" }), 1 << 20) catch break :blk null;
        defer gpa.free(bytes);
        break :blk std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch null;
    };

    // Launch start, budget and samples from the event stream.
    var t0: i128 = 0;
    var max_threads: f64 = 0;
    var max_memory: f64 = 0;
    var samples: std.ArrayList(Sample) = .empty;
    {
        const text = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "events.jsonl" }), 1 << 30) catch "";
        defer if (text.len > 0) gpa.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }) catch continue;
            const ev = str(v, "event");
            const at = monitor.parseTime(str(v, "time")) orelse continue;
            if (t0 == 0) t0 = at;
            if (std.mem.eql(u8, ev, "launch_started")) {
                t0 = at;
                max_threads = num(get(v, "max_threads")) orelse 0;
                max_memory = num(get(v, "max_memory_mib")) orelse 0;
            } else if (std.mem.eql(u8, ev, "sample")) {
                try samples.append(a, .{
                    .t = @as(f64, @floatFromInt(at - t0)) / 1e9,
                    .threads = num(get(v, "threads_reserved")) orelse 0,
                    .cpu = num(get(v, "cpu_cores_used")),
                    .mem_mib = if (num(get(v, "memory_current"))) |m| m / 1048576.0 else null,
                    .reserved_mib = num(get(v, "memory_reserved_mib")) orelse 0,
                });
            }
        }
    }

    const elapsed: f64 = if (summary) |s| num(get(s, "elapsed_s")) orelse 0 else 0;
    var span: f64 = elapsed;
    for (rows) |r| if (r.started_ns > 0) {
        span = @max(span, @as(f64, @floatFromInt(r.started_ns - t0)) / 1e9 + r.wall_s);
    };
    span = @max(span, 0.001);

    try w.writeAll("<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>workz launch ");
    try escape(w, std.fs.path.basename(launch_dir));
    try w.print("</title><style>{s}</style></head><body>\n<h1>workz launch ", .{style});
    try escape(w, std.fs.path.basename(launch_dir));
    try w.writeAll("</h1>\n<table class=\"facts\">");
    if (summary) |s| {
        try w.writeAll("<tr><td>status</td><td>");
        try escape(w, str(s, "status"));
        if (str(s, "error").len > 0) {
            try w.writeAll(": ");
            try escape(w, str(s, "error"));
        }
        try w.print("</td></tr><tr><td>elapsed</td><td>{d:.1} s</td></tr>", .{elapsed});
        if (get(s, "counts")) |c| if (c == .object) {
            try w.writeAll("<tr><td>rules</td><td>");
            var it = c.object.iterator();
            var first = true;
            while (it.next()) |e| if ((num(e.value_ptr.*) orelse 0) > 0) {
                try w.print("{s}{d:.0} {s}", .{ if (first) "" else ", ", num(e.value_ptr.*).?, e.key_ptr.* });
                first = false;
            };
            try w.writeAll("</td></tr>");
        };
        if (get(s, "engine_cost")) |c| try w.print("<tr><td>engine</td><td>{d:.2} s CPU, {d:.1} MiB peak</td></tr>", .{ num(get(c, "cpu_s")) orelse 0, num(get(c, "max_rss_mib")) orelse 0 });
    } else try w.writeAll("<tr><td>status</td><td>running or interrupted (no summary)</td></tr>");
    try w.print("<tr><td>budget</td><td>{d:.0} threads, {d:.0} MiB</td></tr><tr><td>attempts</td><td>{d}</td></tr></table>\n", .{ max_threads, max_memory, rows.len });

    try writeTimeline(a, w, rows, t0, span);
    try writeUse(w, samples.items, max_threads, max_memory, span);

    try w.writeAll("<h2>What limited the launch</h2>\n<pre>");
    var bottlenecks: std.Io.Writer.Allocating = .init(a);
    report.writeBottlenecks(gpa, a, &bottlenecks.writer, launch_dir) catch {};
    try escape(w, bottlenecks.written());
    try w.writeAll("</pre>\n");

    try writeFailures(gpa, a, w, rows);

    try w.writeAll("<h2>Attempts</h2>\n<table><tr><th>rule</th><th>attempt</th><th>status</th><th>wall s</th><th>CPU s</th><th>threads</th><th>request MiB</th><th>peak MiB</th><th>waited s</th><th>waited for</th></tr>\n");
    for (rows) |r| {
        try w.writeAll("<tr><td>");
        try escape(w, r.rule);
        try w.print("</td><td>{d}</td><td>", .{r.attempt});
        try escape(w, r.status);
        try w.print("</td><td>{d:.2}</td><td>{d:.2}</td><td>{d:.0}</td><td>{d:.0}</td><td>", .{ r.wall_s, r.cpu_s, r.threads, r.request_mib });
        if (r.peak_mib) |p| try w.print("{d:.0}", .{p}) else try w.writeAll("-");
        try w.print("</td><td>{d:.2}</td><td>", .{r.waited_s});
        try escape(w, r.wait_reason);
        try w.writeAll("</td></tr>\n");
    }
    try w.writeAll("</table>\n</body></html>\n");
}

/// One bar per attempt in start order: waiting before it in a light shade,
/// running in the colour of its outcome.
fn writeTimeline(a: Allocator, w: *std.Io.Writer, rows: []const report.Attempt, t0: i128, span: f64) !void {
    const sorted = try a.dupe(report.Attempt, rows);
    std.mem.sort(report.Attempt, sorted, {}, struct {
        fn lt(_: void, x: report.Attempt, y: report.Attempt) bool {
            return x.started_ns < y.started_ns;
        }
    }.lt);
    const width: f64 = 1000;
    const row_h: f64 = if (sorted.len > 150) 3 else 8;
    const height = @as(f64, @floatFromInt(sorted.len)) * row_h + 24;
    try w.print("<h2>Timeline</h2>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.0}\" height=\"{d:.0}\">\n", .{ width + 10, height });
    for (sorted, 0..) |r, i| {
        if (r.started_ns == 0) continue;
        const start = @as(f64, @floatFromInt(r.started_ns - t0)) / 1e9;
        const y = @as(f64, @floatFromInt(i)) * row_h;
        const x0 = @max(start - r.waited_s, 0) / span * width;
        const x1 = start / span * width;
        const x2 = (start + r.wall_s) / span * width;
        if (x1 > x0) try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" fill=\"#e5d9a8\"/>", .{ x0, y, x1 - x0, row_h - 0.5 });
        try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" fill=\"{s}\"><title>", .{ x1, y, @max(x2 - x1, 0.5), row_h - 0.5, color(r.status) });
        try escape(w, r.rule);
        try w.print(" #{d}: ", .{r.attempt});
        try escape(w, r.status);
        try w.print(", ran {d:.1} s after waiting {d:.1} s</title></rect>\n", .{ r.wall_s, r.waited_s });
    }
    // Ticks at a round step giving at most ten of them.
    const steps = [_]f64{ 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 86400 };
    const step = for (steps) |s| {
        if (span / s <= 10) break s;
    } else 86400;
    var tick: f64 = 0;
    while (tick <= span) : (tick += step) {
        const x = tick / span * width;
        try w.print("<line x1=\"{d:.1}\" y1=\"0\" x2=\"{d:.1}\" y2=\"{d:.0}\" stroke=\"#ccc\" stroke-width=\"0.5\"/><text x=\"{d:.1}\" y=\"{d:.0}\" font-size=\"11\">{d} s</text>", .{ x, x, height - 18, x + 2, height - 6, @round(tick * 10) / 10 });
    }
    try w.writeAll("</svg>\n<p><span style=\"color:#c9b35a\">&#9632;</span> waiting to start &nbsp; <span style=\"color:#3a7d44\">&#9632;</span> completed &nbsp; <span style=\"color:#c0392b\">&#9632;</span> failed &nbsp; <span style=\"color:#8c6bb1\">&#9632;</span> cancelled; hover a bar for its rule</p>\n");
}

/// Threads reserved and CPU cores in use, then memory reserved and in use,
/// from the run samples.
fn writeUse(w: *std.Io.Writer, samples: []const Sample, max_threads: f64, max_memory: f64, span: f64) !void {
    try w.writeAll("<h2>Use of the budget</h2>\n");
    if (samples.len < 2) return w.writeAll("<p>Too few run samples to draw (one every 5 s).</p>\n");
    const width: f64 = 1000;
    const height: f64 = 120;
    const charts = [_]struct { title: []const u8, max: f64 }{ .{ .title = "threads reserved (grey) and CPU cores used (blue)", .max = max_threads }, .{ .title = "memory reserved (grey) and in use (blue), MiB", .max = max_memory } };
    for (charts, 0..) |c, ci| {
        const top = @max(c.max, 1);
        try w.print("<p>{s}, of {d:.0}</p><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d:.0}\" height=\"{d:.0}\">", .{ c.title, c.max, width + 10, height });
        for ([_]bool{ false, true }) |used| {
            try w.print("<polyline fill=\"none\" stroke=\"{s}\" stroke-width=\"1.5\" points=\"", .{if (used) "#2c6fbb" else "#999"});
            for (samples) |s| {
                const v: ?f64 = if (ci == 0) (if (used) s.cpu else s.threads) else (if (used) s.mem_mib else s.reserved_mib);
                const y = v orelse continue;
                try w.print("{d:.1},{d:.1} ", .{ s.t / span * width, height - @min(y / top, 1) * (height - 4) });
            }
            try w.writeAll("\"/>");
        }
        try w.writeAll("</svg>\n");
    }
}

fn writeFailures(gpa: Allocator, a: Allocator, w: *std.Io.Writer, rows: []const report.Attempt) !void {
    var n: usize = 0;
    for (rows) |r| if (!std.mem.eql(u8, r.status, "completed")) {
        n += 1;
    };
    try w.print("<h2>Failures ({d})</h2>\n", .{n});
    for (rows) |r| {
        if (std.mem.eql(u8, r.status, "completed")) continue;
        try w.writeAll("<details><summary>");
        try escape(w, r.rule);
        try w.print(" #{d}: ", .{r.attempt});
        try escape(w, r.reason);
        try w.writeAll("</summary><pre>");
        const tail = sys.readTail(gpa, try std.fs.path.join(a, &.{ r.dir, "stderr.log" }), 8192) catch null;
        if (tail) |t| {
            defer gpa.free(t);
            // The last forty lines.
            var start = t.len;
            var lines: usize = 0;
            while (start > 0 and lines < 41) : (start -= 1) {
                if (t[start - 1] == '\n') lines += 1;
            }
            try escape(w, t[start..]);
        } else try w.writeAll("(no standard error)");
        try w.writeAll("</pre></details>\n");
    }
}
