//! `workz report --format html`: one self-contained page for a launch, from
//! its records: summary cards, a timeline of every attempt with the critical
//! path marked, use of the budget over time, what limited the launch, the
//! requests per kind of rule, the failures with the end of their standard
//! error, and the attempt table. Light and dark color schemes follow the
//! reader's setting, and the page prints. No scripts and no remote assets.
const std = @import("std");
const sys = @import("sys.zig");
const report = @import("report.zig");
const monitor = @import("monitor.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const eql = std.mem.eql;

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

fn readJson(gpa: Allocator, a: Allocator, path: []const u8) ?Value {
    const bytes = sys.readFile(gpa, path, 1 << 20) catch return null;
    defer gpa.free(bytes);
    return std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch null;
}

/// The color family of a status: completed and reused are `ok`, cancelled
/// and interrupted `cancel`, a launch without a summary `run`, the rest `fail`.
fn tone(status: []const u8) []const u8 {
    if (eql(u8, status, "completed") or eql(u8, status, "reused")) return "ok";
    if (eql(u8, status, "cancelled") or eql(u8, status, "interrupted")) return "cancel";
    if (eql(u8, status, "running")) return "run";
    return "fail";
}

/// A duration: `48.2 s`, `3m 07s` or `2h 05m`.
fn duration(w: *std.Io.Writer, s: f64) !void {
    if (s < 60) return w.print("{d:.1} s", .{s});
    const whole: u64 = @intFromFloat(@round(s));
    if (whole < 3600) return w.print("{d}m {d:0>2}s", .{ whole / 60, whole % 60 });
    return w.print("{d}h {d:0>2}m", .{ whole / 3600, whole % 3600 / 60 });
}

/// A size given in MiB: `512 MiB`, `1.5 GiB`, `120 GiB`.
fn size(w: *std.Io.Writer, mib: f64) !void {
    if (mib >= 1024 * 1024) return w.print("{d:.1} TiB", .{mib / (1024 * 1024)});
    if (mib >= 100 * 1024) return w.print("{d:.0} GiB", .{mib / 1024});
    if (mib >= 1024) return w.print("{d:.1} GiB", .{mib / 1024});
    if (mib >= 10) return w.print("{d:.0} MiB", .{mib});
    return w.print("{d:.1} MiB", .{mib});
}

/// A round step for axis ticks, giving at most `most` of them over `span`.
fn tickStep(span: f64, most: f64) f64 {
    const steps = [_]f64{ 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 86400 };
    for (steps) |s| if (span / s <= most) return s;
    return 86400;
}
/// An axis tick label: `0`, `0.5s`, `30s`, `2m`, `2m30s`, `1h`, `1h30m`; ticks
/// less than a second apart keep a decimal.
/// An axis tick label: `0`, `0.5s`, `30s`, `2m`, `2m30s`, `1h`, `1h30m`.
fn tickLabel(buf: []u8, s: f64, step: f64) []const u8 {
    const r = if (s == 0)
        std.fmt.bufPrint(buf, "0", .{})
    else if (step < 1)
        std.fmt.bufPrint(buf, "{d:.1}s", .{s})
    else blk: {
        const v: u64 = @intFromFloat(@round(s));
        break :blk if (v < 60)
            std.fmt.bufPrint(buf, "{d}s", .{v})
        else if (v < 3600 and v % 60 == 0)
            std.fmt.bufPrint(buf, "{d}m", .{v / 60})
        else if (v < 3600)
            std.fmt.bufPrint(buf, "{d}m{d}s", .{ v / 60, v % 60 })
        else if (v % 3600 == 0)
            std.fmt.bufPrint(buf, "{d}h", .{v / 3600})
        else
            std.fmt.bufPrint(buf, "{d}h{d}m", .{ v / 3600, v % 3600 / 60 });
    };
    return r catch "";
}

/// `name` cut to `max` characters by dropping its middle.
fn middle(a: Allocator, name: []const u8, max: usize) []const u8 {
    if (name.len <= max or max < 5) return name;
    const keep = max - 3;
    const head = (keep + 1) / 2;
    return std.fmt.allocPrint(a, "{s}...{s}", .{ name[0..head], name[name.len - (keep - head) ..] }) catch name;
}

const style =
    \\:root{color-scheme:light dark;--bg:#f6f8fa;--panel:#fff;--ink:#1f2328;--muted:#59636e;--line:#d1d9e0;--grid:#eef1f4;
    \\--zebra:#f6f8fa;--ok:#1a7f37;--ok-soft:#dafbe1;--fail:#cf222e;--fail-soft:#ffebe9;--cancel:#8250df;--cancel-soft:#fbefff;
    \\--run:#0969da;--run-soft:#ddf4ff;--wait:#bf8700;--res:#8c959f;
    \\--mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
    \\--sans:system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans",Helvetica,Arial,sans-serif}
    \\@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--panel:#151b23;--ink:#e6edf3;--muted:#9198a1;--line:#3d444d;
    \\--grid:#212830;--zebra:#11161d;--ok:#3fb950;--ok-soft:#12261e;--fail:#f85149;--fail-soft:#2d1214;--cancel:#ab7df8;
    \\--cancel-soft:#231833;--run:#4493f8;--run-soft:#0c2d6b;--wait:#d29922;--res:#656c76}}
    \\*{box-sizing:border-box}
    \\body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 var(--sans)}
    \\main{max-width:1180px;margin:0 auto;padding:32px 24px 40px}
    \\.eyebrow{font-size:12px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
    \\h1{font-size:28px;line-height:1.25;margin:6px 0;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
    \\h2{font-size:17px;margin:0 0 4px}h3{font-size:14px;margin:22px 0 8px}
    \\.meta{color:var(--muted);margin:0}code{font-family:var(--mono);font-size:.92em}
    \\.error{margin:12px 0 0;padding:10px 14px;border-radius:8px;background:var(--fail-soft);color:var(--fail)}
    \\.badge,.chip{display:inline-block;font-weight:600;border-radius:999px;white-space:nowrap}
    \\.badge{font-size:12px;padding:4px 11px;letter-spacing:.02em}.chip{font-size:11.5px;padding:1px 8px}
    \\.c-ok{background:var(--ok-soft);color:var(--ok)}.c-fail{background:var(--fail-soft);color:var(--fail)}
    \\.c-cancel{background:var(--cancel-soft);color:var(--cancel)}.c-run{background:var(--run-soft);color:var(--run)}
    \\nav{display:flex;gap:6px;flex-wrap:wrap;margin:18px 0 22px}
    \\nav a{color:var(--muted);text-decoration:none;font-size:13px;padding:3px 11px;border:1px solid var(--line);border-radius:999px;background:var(--panel)}
    \\nav a:hover{color:var(--ink);border-color:var(--muted)}
    \\.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:20px}
    \\.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
    \\.card .k{font-size:11.5px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
    \\.card .v{font-size:24px;font-weight:650;margin-top:2px;font-variant-numeric:tabular-nums;white-space:nowrap}
    \\.card .s{font-size:12.5px;color:var(--muted)}
    \\.stack{display:flex;height:6px;border-radius:3px;overflow:hidden;background:var(--grid);margin-top:10px}
    \\.stack i{display:block}.s-ok{background:var(--ok)}.s-fail{background:var(--fail)}.s-cancel{background:var(--cancel)}
    \\section{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:20px 22px;margin-bottom:20px}
    \\.lead{color:var(--muted);margin:0 0 14px;font-size:13px}.muted{color:var(--muted)}
    \\svg{display:block;width:100%;height:auto;font-family:var(--mono)}
    \\svg text{fill:var(--muted);font-size:11px}svg text.crit{fill:var(--ink);font-weight:700}
    \\.grid{stroke:var(--grid);stroke-width:1}.axis{stroke:var(--line);stroke-width:1}.zebra{fill:var(--zebra)}
    \\.st-ok{fill:var(--ok)}.st-fail{fill:var(--fail)}.st-cancel{fill:var(--cancel)}.st-run{fill:var(--run)}
    \\.wait{fill:var(--wait);opacity:.45}rect.crit{stroke:var(--ink);stroke-width:1.5}
    \\.area-res{fill:var(--res);opacity:.3}.line-res{fill:none;stroke:var(--res);stroke-width:1.5}
    \\.area-use{fill:var(--run);opacity:.16}.line-use{fill:none;stroke:var(--run);stroke-width:2;stroke-linejoin:round}
    \\.budget{stroke:var(--muted);stroke-width:1;stroke-dasharray:4 4}
    \\.legend{display:flex;flex-wrap:wrap;gap:4px 18px;list-style:none;padding:0;margin:12px 0 0;font-size:12.5px;color:var(--muted)}
    \\.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}
    \\.sw-ok{background:var(--ok)}.sw-fail{background:var(--fail)}.sw-cancel{background:var(--cancel)}
    \\.sw-wait{background:var(--wait);opacity:.45}.sw-crit{border:1.5px solid var(--ink)}
    \\.sw-res{background:var(--res);opacity:.5}.sw-use{background:var(--run)}
    \\.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:24px}.charts h3{margin-top:4px}
    \\table{border-collapse:collapse;width:100%;font-size:13px;font-variant-numeric:tabular-nums}
    \\th{font-size:11px;font-weight:600;letter-spacing:.05em;text-transform:uppercase;color:var(--muted);text-align:left;
    \\padding:8px 10px;border-bottom:1px solid var(--line);white-space:nowrap;background:var(--panel)}
    \\td{padding:6px 10px;border-bottom:1px solid var(--grid);vertical-align:middle}
    \\.n{text-align:right;white-space:nowrap}tbody tr:hover td{background:var(--zebra)}td.name{font-family:var(--mono);font-size:12.5px}
    \\.wide{overflow-x:auto}.scroll{max-height:70vh;overflow:auto;border:1px solid var(--line);border-radius:8px}
    \\.scroll thead th{position:sticky;top:0;z-index:1}
    \\.bar{position:relative;height:10px;min-width:150px;background:var(--grid);border-radius:5px;overflow:hidden}
    \\.bar i{position:absolute;left:0;top:0;bottom:0;border-radius:5px}
    \\.b-req{background:var(--res);opacity:.55}.b-peak{background:var(--run)}.b-wait{background:var(--wait)}
    \\.b-ok{background:var(--ok)}.b-fail{background:var(--fail)}.b-cancel{background:var(--cancel)}.b-run{background:var(--run)}
    \\th.grp{text-align:center;border-bottom:1px solid var(--line);padding-bottom:4px}
    \\.failure{border:1px solid var(--line);border-left:4px solid var(--fail);border-radius:8px;margin:10px 0;overflow:hidden}
    \\.failure summary{cursor:pointer;padding:10px 14px}.failure .reason{color:var(--fail)}
    \\pre{margin:0;padding:12px 14px;background:var(--zebra);font:12px/1.5 var(--mono);overflow:auto;max-height:420px;white-space:pre-wrap;word-break:break-word}
    \\.failure pre{border-top:1px solid var(--line)}
    \\details.full>summary{cursor:pointer;color:var(--muted);margin-top:18px}
    \\details.full pre{border:1px solid var(--line);border-radius:8px;margin-top:8px;white-space:pre;max-height:none}
    \\footer{color:var(--muted);font-size:12px;text-align:center;margin-top:24px}
    \\@media print{:root{color-scheme:light}body{background:#fff}main{max-width:none;padding:0}nav{display:none}
    \\section,.card,.failure{break-inside:avoid}.scroll{max-height:none;overflow:visible;border:0}pre{max-height:none}}
;

/// What the page shows about the launch, read once from its records.
const Launch = struct {
    rows: []const report.Attempt,
    summary: ?Value,
    status: []const u8,
    t0: i128 = 0,
    span: f64,
    elapsed: f64,
    max_threads: f64 = 0,
    max_memory: f64 = 0,
    samples: []const Sample,
    path: []const []const u8,
    /// The highest attempt number of each rule, to mark only the attempt
    /// on the critical path.
    last: std.StringHashMapUnmanaged(i64),

    fn onPath(self: *const Launch, r: report.Attempt) bool {
        if ((self.last.get(r.rule) orelse 0) != r.attempt) return false;
        for (self.path) |n| if (eql(u8, n, r.rule)) return true;
        return false;
    }

    fn at(self: *const Launch, ns: i128) f64 {
        return @as(f64, @floatFromInt(ns - self.t0)) / 1e9;
    }
};

pub fn write(gpa: Allocator, a: Allocator, w: *std.Io.Writer, launch_dir: []const u8) !void {
    const rows = try report.attempts(gpa, a, launch_dir);
    const summary = readJson(gpa, a, try std.fs.path.join(a, &.{ launch_dir, "summary.json" }));
    const info = readJson(gpa, a, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }));

    // Launch start, budget and samples from the event stream.
    var l: Launch = .{
        .rows = rows,
        .summary = summary,
        .status = if (summary) |s| str(s, "status") else "running",
        .span = 0,
        .elapsed = if (summary) |s| num(get(s, "elapsed_s")) orelse 0 else 0,
        .samples = &.{},
        .path = &.{},
        .last = .empty,
    };
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
            if (l.t0 == 0) l.t0 = at;
            if (eql(u8, ev, "launch_started")) {
                l.t0 = at;
                l.max_threads = num(get(v, "max_threads")) orelse 0;
                l.max_memory = num(get(v, "max_memory_mib")) orelse 0;
            } else if (eql(u8, ev, "sample")) {
                try samples.append(a, .{
                    .t = @as(f64, @floatFromInt(at - l.t0)) / 1e9,
                    .threads = num(get(v, "threads_reserved")) orelse 0,
                    .cpu = num(get(v, "cpu_cores_used")),
                    .mem_mib = if (num(get(v, "memory_current"))) |m| m / 1048576.0 else null,
                    .reserved_mib = num(get(v, "memory_reserved_mib")) orelse 0,
                });
            }
        }
    }
    l.samples = samples.items;
    l.span = l.elapsed;
    for (rows) |r| {
        if (r.started_ns > 0) l.span = @max(l.span, l.at(r.started_ns) + r.wall_s);
        const gop = try l.last.getOrPut(a, r.rule);
        if (!gop.found_existing or r.attempt > gop.value_ptr.*) gop.value_ptr.* = r.attempt;
    }
    l.span = @max(l.span, 0.001);
    l.path = try report.criticalPathNames(gpa, a, launch_dir, rows);

    const id = std.fs.path.basename(launch_dir);
    const workdir = if (info) |v| std.fs.path.basename(str(v, "workdir")) else "";
    const name = if (workdir.len > 0) workdir else "launch";
    const engine_text = if (summary) |s| str(s, "engine") else if (info) |v| str(v, "engine") else "";
    const engine = if (std.mem.indexOf(u8, engine_text, " sha256:")) |i| engine_text[0..i] else engine_text;

    try w.writeAll("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try escape(w, name);
    try w.writeAll(" - workz launch ");
    try escape(w, id);
    try w.print("</title>\n<style>\n{s}</style></head><body><main>\n", .{style});

    // Header: what ran, how it ended, when.
    try w.writeAll("<header><div class=\"eyebrow\">workz launch report</div>\n<h1>");
    try escape(w, name);
    try w.print(" <span class=\"badge c-{s}\">", .{tone(l.status)});
    try escape(w, if (summary == null) "running or ended without a summary" else l.status);
    try w.writeAll("</span></h1>\n<p class=\"meta\">launch <code>");
    try escape(w, id);
    try w.writeAll("</code>");
    if (info) |v| {
        const started = str(v, "started");
        if (started.len >= 19) {
            try w.writeAll(" &middot; started ");
            try escape(w, started[0..10]);
            try w.writeAll(" ");
            try escape(w, started[11..19]);
            try w.writeAll(" UTC");
        }
    }
    if (engine.len > 0) {
        try w.writeAll(" &middot; ");
        try escape(w, engine);
    }
    try w.writeAll("</p>\n");
    if (summary) |s| if (str(s, "error").len > 0) {
        try w.writeAll("<p class=\"error\">");
        try escape(w, str(s, "error"));
        try w.writeAll("</p>\n");
    };
    try w.writeAll("</header>\n");

    var failures: usize = 0;
    for (rows) |r| failures += @intFromBool(!eql(u8, r.status, "completed"));
    try w.writeAll("<nav><a href=\"#timeline\">Timeline</a><a href=\"#budget\">Budget</a><a href=\"#limits\">What limited it</a><a href=\"#kinds\">Requests</a>");
    try w.print("<a href=\"#failures\">Failures ({d})</a><a href=\"#attempts\">Attempts ({d})</a></nav>\n", .{ failures, rows.len });

    try writeCards(w, &l);
    try writeTimeline(a, w, &l);
    try writeBudget(w, &l);
    try writeLimits(gpa, a, w, &l, launch_dir);
    try writeKinds(a, w, rows);
    try writeFailures(gpa, a, w, rows, failures);
    try writeAttempts(w, &l);

    try w.writeAll("<footer>Written by ");
    try escape(w, if (engine.len > 0) engine else "workz");
    try w.writeAll(" from the records in <code>.workz/launches/");
    try escape(w, id);
    try w.writeAll("</code>. The page has no scripts and loads nothing from elsewhere.</footer>\n</main></body></html>\n");
}

/// The launch at a glance: elapsed time, rules, attempts, CPU and memory
/// use against the budget, and the engine's own cost.
fn writeCards(w: *std.Io.Writer, l: *const Launch) !void {
    const s = l.summary;
    const counts: ?Value = if (s) |v| get(v, "counts") else null;
    const count = struct {
        fn of(c: ?Value, k: []const u8) f64 {
            return if (c) |v| num(get(v, k)) orelse 0 else 0;
        }
    }.of;
    const completed = count(counts, "completed");
    const reused = count(counts, "reused");
    const failed = count(counts, "failed");
    const blocked = count(counts, "blocked");
    const cancelled = count(counts, "cancelled") + count(counts, "not_started");
    const selected: f64 = if (s) |v| num(get(v, "selected")) orelse 0 else 0;

    try w.writeAll("<div class=\"cards\">\n<div class=\"card\"><div class=\"k\">Elapsed</div><div class=\"v\">");
    try duration(w, l.elapsed);
    if (l.path.len > 0) try w.print("</div><div class=\"s\">{d} {s} on the critical path</div></div>\n", .{ l.path.len, if (l.path.len == 1) "rule" else "rules" }) else try w.writeAll("</div></div>\n");

    try w.print("<div class=\"card\"><div class=\"k\">Rules done</div><div class=\"v\">{d:.0} / {d:.0}</div><div class=\"s\">{d:.0} ran, {d:.0} reused", .{ completed + reused, selected, completed, reused });
    if (failed + blocked > 0) try w.print(", {d:.0} failed or blocked", .{failed + blocked});
    if (cancelled > 0) try w.print(", {d:.0} not run", .{cancelled});
    try w.writeAll("</div><div class=\"stack\">");
    const total = @max(selected, 1);
    for ([_]struct { n: f64, c: []const u8 }{ .{ .n = completed + reused, .c = "ok" }, .{ .n = failed + blocked, .c = "fail" }, .{ .n = cancelled, .c = "cancel" } }) |part| {
        if (part.n > 0) try w.print("<i class=\"s-{s}\" style=\"width:{d:.2}%\"></i>", .{ part.c, part.n / total * 100 });
    }
    try w.writeAll("</div></div>\n");

    var retries: usize = 0;
    for (l.rows) |r| retries += @intFromBool(r.attempt > 1);
    try w.print("<div class=\"card\"><div class=\"k\">Attempts</div><div class=\"v\">{d}</div><div class=\"s\">", .{l.rows.len});
    if (retries == 0) try w.writeAll("no retries") else try w.print("{d} {s}", .{ retries, if (retries == 1) "retry" else "retries" });
    try w.writeAll("</div></div>\n");

    var threads: f64 = 0;
    var cpu: f64 = 0;
    var cpu_n: f64 = 0;
    var peak: f64 = 0;
    for (l.samples) |x| {
        threads += x.threads;
        if (x.cpu) |c| {
            cpu += c;
            cpu_n += 1;
        }
        if (x.mem_mib) |m| peak = @max(peak, m);
    }
    const n: f64 = @floatFromInt(l.samples.len);
    try w.writeAll("<div class=\"card\"><div class=\"k\">CPU</div>");
    if (cpu_n > 0) {
        try w.print("<div class=\"v\">{d:.1} cores</div><div class=\"s\">in use on average; {d:.1} of {d:.0} threads reserved</div></div>\n", .{ cpu / cpu_n, threads / n, l.max_threads });
    } else try w.print("<div class=\"v\">{d:.0} threads</div><div class=\"s\">in the budget; too short for run samples</div></div>\n", .{l.max_threads});
    try w.writeAll("<div class=\"card\"><div class=\"k\">Memory</div>");
    if (peak > 0) {
        try w.writeAll("<div class=\"v\">");
        try size(w, peak);
        try w.writeAll("</div><div class=\"s\">peak in use, of a ");
        try size(w, l.max_memory);
        try w.writeAll(" budget</div></div>\n");
    } else {
        try w.writeAll("<div class=\"v\">");
        try size(w, l.max_memory);
        try w.writeAll("</div><div class=\"s\">in the budget; too short for run samples</div></div>\n");
    }
    if (s) |v| if (get(v, "engine_cost")) |c| {
        try w.print("<div class=\"card\"><div class=\"k\">Engine</div><div class=\"v\">{d:.2} s</div><div class=\"s\">CPU time; {d:.1} MiB peak</div></div>\n", .{ num(get(c, "cpu_s")) orelse 0, num(get(c, "max_rss_mib")) orelse 0 });
    };
    try w.writeAll("</div>\n");
}

/// One row per attempt in start order, labelled with its rule: the wait
/// before it as a thin bar, its run in the color of its outcome, and the
/// attempts on the critical path outlined.
fn writeTimeline(a: Allocator, w: *std.Io.Writer, l: *const Launch) !void {
    var list: std.ArrayList(report.Attempt) = .empty;
    for (l.rows) |r| if (r.started_ns > 0) try list.append(a, r);
    std.mem.sort(report.Attempt, list.items, {}, struct {
        fn lt(_: void, x: report.Attempt, y: report.Attempt) bool {
            return x.started_ns < y.started_ns;
        }
    }.lt);
    try w.writeAll("<section id=\"timeline\"><h2>Timeline</h2>\n<p class=\"lead\">Every attempt in the order it started: the time it waited for resources, then its run.</p>\n");
    if (list.items.len == 0) return w.writeAll("<p class=\"muted\">No attempt started.</p></section>\n");

    const n = list.items.len;
    const row_h: f64 = if (n <= 60) 18 else if (n <= 150) 12 else if (n <= 400) 6 else 3;
    const labels = row_h >= 12;
    const width: f64 = 1100;
    const label_w: f64 = if (labels) 200 else 16;
    const x0 = label_w;
    const plot_w = width - label_w - 14;
    const top: f64 = 26;
    const height = top + @as(f64, @floatFromInt(n)) * row_h + 8;
    try w.print("<svg viewBox=\"0 0 {d:.0} {d:.0}\" role=\"img\" aria-label=\"Timeline of {d} attempts\">\n", .{ width, height, n });

    // Zebra rows, then the time axis with grid lines, under the bars.
    if (labels) for (0..n) |i| if (i % 2 == 1) {
        try w.print("<rect class=\"zebra\" x=\"0\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.1}\"/>", .{ top + @as(f64, @floatFromInt(i)) * row_h, width, row_h });
    };
    const step = tickStep(l.span, 10);
    var tick: f64 = 0;
    var buf: [32]u8 = undefined;
    while (tick <= l.span + step * 0.001) : (tick += step) {
        const x = x0 + tick / l.span * plot_w;
        try w.print("<line class=\"grid\" x1=\"{d:.1}\" y1=\"20\" x2=\"{d:.1}\" y2=\"{d:.1}\"/><text x=\"{d:.1}\" y=\"14\" text-anchor=\"middle\">{s}</text>", .{ x, x, height - 6, x, tickLabel(&buf, tick, step) });
    }
    try w.writeAll("\n");

    for (list.items, 0..) |r, i| {
        const y = top + @as(f64, @floatFromInt(i)) * row_h;
        const crit = l.onPath(r);
        const start = l.at(r.started_ns);
        const wait_from = x0 + @max(start - r.waited_s, 0) / l.span * plot_w;
        const run_from = x0 + start / l.span * plot_w;
        const run_to = x0 + @min(start + r.wall_s, l.span) / l.span * plot_w;
        if (labels) {
            const label = if (r.attempt > 1) try std.fmt.allocPrint(a, "{s} #{d}", .{ middle(a, r.rule, 23), r.attempt }) else middle(a, r.rule, 27);
            try w.print("<text x=\"{d:.0}\" y=\"{d:.1}\" text-anchor=\"end\"{s}>", .{ label_w - 10, y + row_h * 0.68, if (crit) " class=\"crit\"" else "" });
            try escape(w, label);
            try w.writeAll("</text>");
        }
        if (run_from - wait_from >= 0.5) try w.print("<rect class=\"wait\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"1\"/>", .{ wait_from, y + row_h * 0.38, run_from - wait_from, row_h * 0.24 });
        const pad: f64 = if (row_h >= 12) 3 else if (row_h >= 6) 1 else 0;
        try w.print("<rect class=\"st-{s}{s}\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"{d:.0}\"><title>", .{ tone(r.status), if (crit) " crit" else "", run_from, y + pad, @max(run_to - run_from, 1), row_h - 2 * pad, @min(pad, 2) });
        try escape(w, r.rule);
        try w.print(", attempt {d}: ", .{r.attempt});
        try escape(w, r.status);
        try w.writeAll("; started at ");
        try duration(w, start);
        try w.writeAll(", waited ");
        try duration(w, r.waited_s);
        try w.writeAll(", ran ");
        try duration(w, r.wall_s);
        try w.writeAll("</title></rect>\n");
    }
    try w.writeAll("</svg>\n<ul class=\"legend\"><li><i class=\"sw-wait\"></i>waiting for resources</li><li><i class=\"sw-ok\"></i>completed</li><li><i class=\"sw-fail\"></i>failed</li><li><i class=\"sw-cancel\"></i>cancelled</li><li><i class=\"sw-crit\"></i>critical path</li><li>hover a bar for its times</li></ul>\n</section>\n");
}

/// Threads reserved and CPU cores in use, then memory reserved and in use,
/// from the run samples, against the budget.
fn writeBudget(w: *std.Io.Writer, l: *const Launch) !void {
    try w.writeAll("<section id=\"budget\"><h2>Use of the budget</h2>\n<p class=\"lead\">What the scheduler reserved for running rules, and what they used, from run samples taken every 5 s.</p>\n");
    if (l.samples.len < 2) return w.writeAll("<p class=\"muted\">The launch was too short for run samples.</p></section>\n");
    try w.writeAll("<div class=\"charts\">\n");
    try writeArea(w, l, false);
    try writeArea(w, l, true);
    try w.writeAll("</div>\n<ul class=\"legend\"><li><i class=\"sw-res\"></i>reserved</li><li><i class=\"sw-use\"></i>in use</li><li>dashed: the budget</li></ul>\n</section>\n");
}

fn writeArea(w: *std.Io.Writer, l: *const Launch, memory: bool) !void {
    const width: f64 = 540;
    const height: f64 = 210;
    const left: f64 = 64;
    const right: f64 = 12;
    const top: f64 = 12;
    const bottom: f64 = 26;
    const pw = width - left - right;
    const ph = height - top - bottom;
    var most: f64 = if (memory) l.max_memory else l.max_threads;
    for (l.samples) |s| most = @max(most, if (memory) @max(s.reserved_mib, s.mem_mib orelse 0) else @max(s.threads, s.cpu orelse 0));
    most = @max(most, 1);
    const budget = if (memory) l.max_memory else l.max_threads;

    try w.print("<div><h3>{s}</h3><svg viewBox=\"0 0 {d:.0} {d:.0}\" role=\"img\" aria-label=\"{s}\">\n", .{ if (memory) "Memory" else "Threads and CPU cores", width, height, if (memory) "Memory reserved and in use" else "Threads reserved and CPU cores in use" });
    var buf: [32]u8 = undefined;
    for ([_]f64{ 0, 0.5, 1 }) |f| {
        const y = top + ph - f * ph;
        try w.print("<line class=\"grid\" x1=\"{d:.0}\" y1=\"{d:.1}\" x2=\"{d:.0}\" y2=\"{d:.1}\"/><text x=\"{d:.0}\" y=\"{d:.1}\" text-anchor=\"end\">", .{ left, y, width - right, y, left - 8, y + 4 });
        if (f == 0) {
            try w.writeAll("0");
        } else if (memory) {
            var lw: std.Io.Writer = .fixed(&buf);
            try size(&lw, most * f);
            try w.writeAll(lw.buffered());
        } else try w.print("{d:.0}", .{most * f});
        try w.writeAll("</text>");
    }
    const step = tickStep(l.span, 6);
    var tick: f64 = 0;
    while (tick <= l.span + step * 0.001) : (tick += step) {
        const x = left + tick / l.span * pw;
        try w.print("<text x=\"{d:.1}\" y=\"{d:.0}\" text-anchor=\"middle\">{s}</text>", .{ x, height - 8, tickLabel(&buf, tick, step) });
    }
    try w.print("<line class=\"axis\" x1=\"{d:.0}\" y1=\"{d:.1}\" x2=\"{d:.0}\" y2=\"{d:.1}\"/>\n", .{ left, top + ph, width - right, top + ph });

    // Each series starts and ends at zero with the launch.
    for ([_]bool{ false, true }) |used| {
        for ([_]bool{ true, false }) |area| {
            try w.print("<{s} class=\"{s}-{s}\" points=\"", .{ if (area) "polygon" else "polyline", if (area) "area" else "line", if (used) "use" else "res" });
            try w.print("{d:.1},{d:.1} ", .{ left, top + ph });
            for (l.samples) |s| {
                const v: f64 = if (memory) (if (used) s.mem_mib orelse continue else s.reserved_mib) else (if (used) s.cpu orelse continue else s.threads);
                try w.print("{d:.1},{d:.1} ", .{ left + @min(s.t / l.span, 1) * pw, top + ph - @min(v / most, 1) * ph });
            }
            try w.print("{d:.1},{d:.1}\"/>\n", .{ left + pw, top + ph });
        }
    }
    if (budget > 0) {
        const y = top + ph - @min(budget / most, 1) * ph;
        try w.print("<line class=\"budget\" x1=\"{d:.0}\" y1=\"{d:.1}\" x2=\"{d:.0}\" y2=\"{d:.1}\"/>\n", .{ left, y, width - right, y });
    }
    try w.writeAll("</svg></div>\n");
}

/// The critical path step by step, why ready rules waited, and the full
/// bottleneck report.
fn writeLimits(gpa: Allocator, a: Allocator, w: *std.Io.Writer, l: *const Launch, launch_dir: []const u8) !void {
    try w.writeAll("<section id=\"limits\"><h2>What limited the launch</h2>\n");
    if (l.path.len > 0) {
        var ran: f64 = 0;
        var waited: f64 = 0;
        var steps: std.ArrayList(report.Attempt) = .empty;
        var i = l.path.len;
        while (i > 0) {
            i -= 1;
            for (l.rows) |r| if (eql(u8, r.rule, l.path[i]) and r.attempt == (l.last.get(r.rule) orelse 0)) {
                try steps.append(a, r);
                ran += r.wall_s;
                waited += r.waited_s;
                break;
            };
        }
        try w.writeAll("<h3>Critical path</h3>\n<p class=\"lead\">The chain of rules that ended last, each waiting on the one before it: ");
        try duration(w, ran);
        try w.writeAll(" running and ");
        try duration(w, waited);
        try w.writeAll(" waiting for resources.</p>\n<div class=\"wide\"><table><thead><tr><th>rule</th><th class=\"n\">started</th><th class=\"n\">waited</th><th class=\"n\">ran</th><th>over the launch</th></tr></thead><tbody>\n");
        for (steps.items) |r| {
            const start = l.at(r.started_ns);
            try w.writeAll("<tr><td class=\"name\">");
            try escape(w, r.rule);
            try w.writeAll("</td><td class=\"n\">");
            try duration(w, start);
            try w.writeAll("</td><td class=\"n\">");
            try duration(w, r.waited_s);
            try w.writeAll("</td><td class=\"n\">");
            try duration(w, r.wall_s);
            const from = @max(start - r.waited_s, 0) / l.span * 100;
            const run_at = start / l.span * 100;
            try w.print("</td><td><div class=\"bar\"><i class=\"b-wait\" style=\"left:{d:.2}%;width:{d:.2}%;opacity:.45\"></i><i class=\"b-{s}\" style=\"left:{d:.2}%;width:{d:.2}%\"></i></div></td></tr>\n", .{ from, run_at - from, tone(r.status), run_at, @max(r.wall_s / l.span * 100, 0.5) });
        }
        try w.writeAll("</tbody></table></div>\n");
    }

    var recorded = false;
    var totals = try report.waitTotals(gpa, a, launch_dir, &recorded);
    report.sortByValue(&totals);
    try w.writeAll("<h3>Why ready rules waited</h3>\n");
    if (totals.count() == 0) {
        try w.writeAll("<p class=\"muted\">No rule waited for resources once it was ready.</p>\n");
    } else {
        var most: f64 = 0;
        for (totals.values()) |v| most = @max(most, v);
        try w.writeAll("<p class=\"lead\">Seconds that rules were ready to start but waited, added up over all rules, by what they waited for.</p>\n<div class=\"wide\"><table><thead><tr><th>waited for</th><th class=\"n\">rule-seconds</th><th></th></tr></thead><tbody>\n");
        for (totals.keys(), totals.values()) |k, v| {
            try w.writeAll("<tr><td>");
            try escape(w, k);
            try w.print("</td><td class=\"n\">{d:.1}</td><td><div class=\"bar\"><i class=\"b-wait\" style=\"width:{d:.2}%\"></i></div></td></tr>\n", .{ v, v / @max(most, 0.001) * 100 });
        }
        try w.writeAll("</tbody></table></div>\n");
    }

    var text: std.Io.Writer.Allocating = .init(a);
    report.writeBottlenecks(gpa, a, &text.writer, launch_dir) catch {};
    try w.writeAll("<details class=\"full\"><summary>The full bottleneck report, as <code>workz report --bottlenecks</code> prints it</summary><pre>");
    try escape(w, text.written());
    try w.writeAll("</pre></details>\n</section>\n");
}

/// Per kind of rule: the threads and memory requested against what the
/// attempts used, and the suggested requests, with the memory as bars on
/// one scale.
fn writeKinds(a: Allocator, w: *std.Io.Writer, rows: []const report.Attempt) !void {
    const list = try report.suggestions(a, rows);
    try w.writeAll("<section id=\"kinds\"><h2>Requests per kind of rule</h2>\n");
    if (list.len == 0) return w.writeAll("<p class=\"muted\">No attempt completed.</p></section>\n");
    var top: f64 = 1;
    for (list) |s| top = @max(top, @max(s.memory_mib, s.peak_mib));
    try w.writeAll("<p class=\"lead\">Completed attempts by kind of rule, the rule name without its sample part. Suggested requests cover the largest peak with a fifth to spare, as <code>workz report --suggest</code> prints them.</p>\n");
    try w.writeAll("<div class=\"wide\"><table><thead><tr><th rowspan=\"2\">kind</th><th rowspan=\"2\" class=\"n\">attempts</th><th colspan=\"3\" class=\"grp\">threads</th><th colspan=\"3\" class=\"grp\">memory</th><th rowspan=\"2\">memory against request</th></tr>\n<tr><th class=\"n\">request</th><th class=\"n\">most used</th><th class=\"n\">suggested</th><th class=\"n\">request</th><th class=\"n\">peak</th><th class=\"n\">suggested</th></tr></thead><tbody>\n");
    for (list) |s| {
        try w.writeAll("<tr><td class=\"name\">");
        try escape(w, s.kind);
        try w.print("</td><td class=\"n\">{d}</td><td class=\"n\">{d:.0}</td><td class=\"n\">{d:.1}</td><td class=\"n\">", .{ s.attempts, s.threads, s.threads_used });
        if (s.delegated) try w.writeAll("-") else try w.print("{d:.0}", .{s.suggest_threads});
        try w.writeAll("</td><td class=\"n\">");
        try size(w, s.memory_mib);
        try w.writeAll("</td><td class=\"n\">");
        try size(w, s.peak_mib);
        try w.writeAll("</td><td class=\"n\">");
        if (s.delegated) try w.writeAll("<span class=\"muted\">delegated</span>") else try size(w, s.suggest_mib);
        try w.print("</td><td><div class=\"bar\"><i class=\"b-req\" style=\"width:{d:.2}%\"></i><i class=\"b-peak\" style=\"width:{d:.2}%\"></i></div></td></tr>\n", .{ s.memory_mib / top * 100, @max(s.peak_mib / top * 100, 0.5) });
    }
    try w.writeAll("</tbody></table></div>\n<ul class=\"legend\"><li><i class=\"sw-res\"></i>memory request</li><li><i class=\"sw-use\"></i>largest peak</li>");
    for (list) |s| if (s.delegated) {
        try w.writeAll("<li>delegated: most attempts handed their work to a process outside workz</li>");
        break;
    };
    try w.writeAll("</ul>\n</section>\n");
}

/// Each attempt that did not complete, with the end of its standard error;
/// the first few are open.
fn writeFailures(gpa: Allocator, a: Allocator, w: *std.Io.Writer, rows: []const report.Attempt, count: usize) !void {
    try w.print("<section id=\"failures\"><h2>Failures ({d})</h2>\n", .{count});
    if (count == 0) return w.writeAll("<p class=\"muted\">Every attempt completed.</p></section>\n");
    var shown: usize = 0;
    for (rows) |r| {
        if (eql(u8, r.status, "completed")) continue;
        try w.print("<details class=\"failure\"{s}><summary><code>", .{if (shown < 3) " open" else ""});
        shown += 1;
        try escape(w, r.rule);
        try w.print("</code> attempt {d} <span class=\"chip c-{s}\">", .{ r.attempt, tone(r.status) });
        try escape(w, r.status);
        try w.writeAll("</span> <span class=\"reason\">");
        try escape(w, r.reason);
        try w.writeAll("</span></summary><pre>");
        const tail = sys.readTail(gpa, try std.fs.path.join(a, &.{ r.dir, "stderr.log" }), 8192) catch null;
        if (tail) |t| {
            defer gpa.free(t);
            // The last forty lines.
            var start = t.len;
            var lines: usize = 0;
            while (start > 0 and lines < 41) : (start -= 1) {
                if (t[start - 1] == '\n') lines += 1;
            }
            if (std.mem.trim(u8, t[start..], " \r\n").len == 0) try w.writeAll("(no standard error)") else try escape(w, t[start..]);
        } else try w.writeAll("(no standard error)");
        try w.writeAll("</pre></details>\n");
    }
    try w.writeAll("</section>\n");
}

/// Every attempt with its times and requests, in a table that scrolls under
/// a fixed header.
fn writeAttempts(w: *std.Io.Writer, l: *const Launch) !void {
    try w.print("<section id=\"attempts\"><h2>Attempts ({d})</h2>\n", .{l.rows.len});
    try w.writeAll("<div class=\"scroll\"><table><thead><tr><th>rule</th><th class=\"n\">#</th><th>status</th><th class=\"n\">started</th><th class=\"n\">waited</th><th class=\"n\">ran</th><th class=\"n\">CPU s</th><th class=\"n\">threads</th><th class=\"n\">memory</th><th class=\"n\">peak</th><th>waited for</th></tr></thead><tbody>\n");
    for (l.rows) |r| {
        try w.writeAll("<tr><td class=\"name\">");
        try escape(w, r.rule);
        try w.print("</td><td class=\"n\">{d}</td><td><span class=\"chip c-{s}\">", .{ r.attempt, tone(r.status) });
        try escape(w, r.status);
        try w.writeAll("</span></td><td class=\"n\">");
        if (r.started_ns > 0) try duration(w, l.at(r.started_ns)) else try w.writeAll("-");
        try w.writeAll("</td><td class=\"n\">");
        try duration(w, r.waited_s);
        try w.writeAll("</td><td class=\"n\">");
        try duration(w, r.wall_s);
        try w.print("</td><td class=\"n\">{d:.1}</td><td class=\"n\">{d:.0}</td><td class=\"n\">", .{ r.cpu_s, r.threads });
        try size(w, r.request_mib);
        try w.writeAll("</td><td class=\"n\">");
        if (r.peak_mib) |p| try size(w, p) else try w.writeAll("-");
        try w.writeAll("</td><td>");
        try escape(w, r.wait_reason);
        try w.writeAll("</td></tr>\n");
    }
    try w.writeAll("</tbody></table></div>\n</section>\n");
}
