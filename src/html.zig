//! `workz report --format html`: one self-contained page for a launch, from
//! its records. It leads with what the launch did: where its CPU time went
//! by category and tool, each sample's run of each step, and each step's
//! spread across its samples. Then come the timeline, the use of the
//! budget, what limited the launch, the failures with the end of their
//! standard error, and every attempt. Colors follow the reader's light or
//! dark setting, and the page prints. No scripts and no remote assets.
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

/// One run sample: threads reserved, cores and memory in use, memory reserved.
const Usage = struct { t: f64, threads: f64, cpu: ?f64, mem_mib: ?f64, reserved_mib: f64 };

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

/// The state family of a status: completed and reused are `ok`, cancelled
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

/// `, 12%` of `total`, or `, <1%` for a small nonzero part.
fn share(w: *std.Io.Writer, part: f64, total: f64) !void {
    const pct = if (total > 0) part / total * 100 else 0;
    if (pct > 0 and pct < 0.5) return w.writeAll(", &lt;1%");
    try w.print(", {d:.0}%", .{pct});
}

/// A round step for axis ticks, giving at most `most` of them over `span`.
fn tickStep(span: f64, most: f64) f64 {
    const steps = [_]f64{ 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 86400 };
    for (steps) |s| if (span / s <= most) return s;
    return 86400;
}

/// An axis tick label: `0`, `0.5s`, `30s`, `2m`, `2m30s`, `1h`, `1h30m`; ticks
/// less than a second apart keep a decimal.
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

// The colors: eight categorical hues in a fixed order for categories (or
// steps), one blue ramp for magnitude, and status colors kept for state.
// Light and dark each have their own validated steps.
const style =
    \\:root{color-scheme:light dark;--page:#f9f9f7;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;
    \\--grid:#e1e0d9;--base:#c3c2b7;--ring:rgba(11,11,11,.10);--wash:rgba(11,11,11,.035);
    \\--c1:#2a78d6;--c2:#eb6834;--c3:#1baf7a;--c4:#eda100;--c5:#e87ba4;--c6:#008300;--c7:#6250d6;--c8:#e34948;
    \\--q1:#cde2fb;--q2:#9ec5f4;--q3:#6da7ec;--q4:#3987e5;--q5:#256abf;--q6:#184f95;--q7:#0d366b;--ql:#0b0b0b;--qh:#ffffff;
    \\--good:#0ca30c;--warn:#fab219;--crit:#d03b3b;
    \\--mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
    \\--sans:system-ui,-apple-system,"Segoe UI",sans-serif}
    \\@media (prefers-color-scheme:dark){:root{--page:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;
    \\--grid:#2c2c2a;--base:#383835;--ring:rgba(255,255,255,.10);--wash:rgba(255,255,255,.04);
    \\--c1:#3987e5;--c2:#d95926;--c3:#199e70;--c4:#c98500;--c5:#d55181;--c6:#008300;--c7:#9085e9;--c8:#e66767;
    \\--q1:#0d366b;--q2:#184f95;--q3:#256abf;--q4:#2a78d6;--q5:#5598e7;--q6:#86b6ef;--q7:#cde2fb;--ql:#f0efec;--qh:#0b0b0b}}
    \\*{box-sizing:border-box}body{margin:0;background:var(--page);color:var(--ink);font:14px/1.5 var(--sans)}
    \\main{max-width:1200px;margin:0 auto;padding:32px 24px 40px}
    \\.eyebrow{font-size:12px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
    \\h1{font-size:28px;line-height:1.25;margin:6px 0;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
    \\h2{font-size:17px;margin:0 0 4px}h3{font-size:14px;margin:22px 0 8px}
    \\.meta{color:var(--ink2);margin:0}code{font-family:var(--mono);font-size:.92em}
    \\.error{margin:12px 0 0;padding:10px 14px;border-radius:8px;border-left:4px solid var(--crit);background:var(--wash)}
    \\.badge,.chip{display:inline-flex;align-items:center;gap:6px;border-radius:999px;white-space:nowrap;background:var(--wash);border:1px solid var(--ring);color:var(--ink2)}
    \\.badge{font-size:13px;font-weight:600;padding:2px 12px;color:var(--ink)}.chip{font-size:12px;padding:0 8px}
    \\.dot{width:8px;height:8px;border-radius:50%;display:inline-block;flex:none}
    \\.d-ok{background:var(--good)}.d-fail{background:var(--crit)}.d-cancel{background:var(--muted)}.d-run{background:var(--c1)}
    \\nav{display:flex;gap:6px;flex-wrap:wrap;margin:18px 0 22px}
    \\nav a{color:var(--ink2);text-decoration:none;font-size:13px;padding:3px 11px;border:1px solid var(--ring);border-radius:999px;background:var(--surface)}
    \\nav a:hover{color:var(--ink);border-color:var(--base)}
    \\.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:20px}
    \\.card{background:var(--surface);border:1px solid var(--ring);border-radius:12px;padding:14px 16px}
    \\.card .k{font-size:12.5px;font-weight:600;color:var(--ink2)}
    \\.card .v{font-size:24px;font-weight:600;margin-top:2px;white-space:nowrap}
    \\.card .s{font-size:12.5px;color:var(--ink2)}
    \\section{background:var(--surface);border:1px solid var(--ring);border-radius:12px;padding:20px 22px;margin-bottom:20px}
    \\.lead{color:var(--ink2);margin:0 0 14px;font-size:13px;max-width:90ch}.muted{color:var(--muted)}
    \\svg{display:block;width:100%;height:auto;font-family:var(--sans)}svg text{fill:var(--muted);font-size:11px}
    \\svg text.crit{fill:var(--ink);font-weight:600}
    \\.grid{stroke:var(--grid);stroke-width:1}.axis{stroke:var(--base);stroke-width:1}.zebra{fill:var(--wash)}
    \\.g1{background:var(--c1);fill:var(--c1)}.g2{background:var(--c2);fill:var(--c2)}.g3{background:var(--c3);fill:var(--c3)}
    \\.g4{background:var(--c4);fill:var(--c4)}.g5{background:var(--c5);fill:var(--c5)}.g6{background:var(--c6);fill:var(--c6)}
    \\.g7{background:var(--c7);fill:var(--c7)}.g8{background:var(--c8);fill:var(--c8)}.g0{background:var(--muted);fill:var(--muted)}
    \\.st-fail{fill:var(--crit)}.st-cancel{fill:var(--base)}.wait{fill:var(--muted);opacity:.35}
    \\rect.crit{stroke:var(--ink);stroke-width:1.5}
    \\.area-res{fill:var(--muted);opacity:.18}.line-res{fill:none;stroke:var(--muted);stroke-width:1.5}
    \\.area-use{fill:var(--c1);opacity:.10}.line-use{fill:none;stroke:var(--c1);stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
    \\.budget{stroke:var(--ink2);stroke-width:1;stroke-dasharray:4 4}
    \\.legend{display:flex;flex-wrap:wrap;gap:6px 18px;list-style:none;padding:0;margin:12px 0 0;font-size:12.5px;color:var(--ink2)}
    \\.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}
    \\.legend b{font-weight:600;color:var(--ink)}
    \\.sw-wait{background:var(--muted);opacity:.35}.sw-crit{border:1.5px solid var(--ink)}.sw-res{background:var(--muted);opacity:.4}
    \\.sw-use{background:var(--c1)}.sw-fail{background:var(--crit)}.sw-cancel{background:var(--base)}
    \\.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:24px}.charts h3{margin-top:4px}
    \\.split{display:flex;height:24px;gap:2px;margin:4px 0}.split i{display:block;min-width:3px}
    \\.split i:first-child{border-radius:4px 0 0 4px}.split i:last-child{border-radius:0 4px 4px 0}
    \\table{border-collapse:collapse;width:100%;font-size:13px}
    \\th{font-size:12px;font-weight:600;color:var(--ink2);text-align:left;padding:8px 10px;border-bottom:1px solid var(--base);white-space:nowrap;background:var(--surface)}
    \\td{padding:6px 10px;border-bottom:1px solid var(--grid);vertical-align:middle;font-variant-numeric:tabular-nums}
    \\.n{text-align:right;white-space:nowrap}tbody tr:hover td{background:var(--wash)}td.name{font-family:var(--mono);font-size:12.5px;white-space:nowrap}
    \\td.name small{display:block;font-family:var(--sans);font-size:12px;color:var(--ink2);margin-left:18px}
    \\small.sub{display:block;font-size:12px;color:var(--ink2);white-space:nowrap}
    \\td.name i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:8px;vertical-align:-1px}
    \\.wide{overflow-x:auto;scrollbar-color:var(--base) transparent}.scroll{max-height:70vh;overflow:auto;border:1px solid var(--ring);border-radius:8px}
    \\.scroll thead th{position:sticky;top:0;z-index:1}
    \\.bar{position:relative;height:8px;min-width:120px;background:var(--grid);border-radius:4px}
    \\.bar i{position:absolute;left:0;top:0;bottom:0;border-radius:4px}
    \\.b-req{background:var(--muted);opacity:.45}.b-use{background:var(--c1)}.b-wait{background:var(--muted)}
    \\.b-ok{background:var(--c1)}.b-fail{background:var(--crit)}.b-cancel{background:var(--base)}.b-run{background:var(--c1)}
    \\.hbar{display:flex;align-items:center;gap:10px}.hbar .bar{flex:1}.hbar span{min-width:76px;text-align:right;color:var(--ink2);white-space:nowrap}
    \\.matrix{border-collapse:separate;border-spacing:2px;width:auto}
    \\.matrix th{border:0;padding:4px;font-weight:500;background:none}
    \\.matrix th.step{writing-mode:vertical-rl;transform:rotate(180deg);text-align:left;vertical-align:top;padding:4px 2px;font-family:var(--mono);font-size:11.5px;color:var(--ink2);white-space:nowrap}
    \\.matrix th.step i{display:inline-block;width:9px;height:9px;border-radius:2px;margin-bottom:6px}
    \\.matrix td{width:30px;min-width:30px;height:24px;padding:0;border:0;text-align:center;font-size:12px;font-weight:700;border-radius:4px}
    \\.matrix tbody tr:hover td{background:revert-layer}
    \\.matrix td.row{width:auto;text-align:left;padding:0 10px 0 0;font-family:var(--mono);font-weight:400;font-size:12.5px;white-space:nowrap}
    \\.matrix td.sum{width:auto;text-align:right;padding:0 0 0 12px;font-weight:400;color:var(--ink2);white-space:nowrap}
    \\.matrix td.none{background:var(--wash)}.matrix td.cell:hover{outline:2px solid var(--ink);outline-offset:-2px}
    \\.q1{background:var(--q1);color:var(--ql)}.q2{background:var(--q2);color:var(--ql)}.q3{background:var(--q3);color:var(--ql)}
    \\.q4{background:var(--q4);color:#fff}.q5{background:var(--q5);color:var(--qh)}.q6{background:var(--q6);color:var(--qh)}.q7{background:var(--q7);color:var(--qh)}
    \\.matrix td.solo{background:var(--base)}.matrix td.fail{background:var(--crit);color:#fff}.matrix td.cancel{background:var(--base);color:var(--ink)}
    \\.matrix td.slow{box-shadow:inset 0 0 0 2px var(--warn)}
    \\.matrix td.reused{position:relative}.matrix td.reused::after{content:"";position:absolute;top:3px;right:3px;width:5px;height:5px;border-radius:50%;background:var(--ink);box-shadow:0 0 0 1.5px var(--surface)}
    \\.sw-reused{background:radial-gradient(circle at 70% 30%,var(--ink) 0 2px,var(--surface) 2.5px 3.5px,var(--q3) 4px)}
    \\.scale{display:inline-flex;gap:2px;vertical-align:-2px;margin:0 6px 0 2px}.scale i{width:14px;height:10px;margin:0;border-radius:0}
    \\.strip{width:180px;height:26px;display:block}.strip circle{fill:var(--c1);stroke:var(--surface);stroke-width:2}
    \\.strip circle.slow{fill:var(--warn)}.strip circle.fail{fill:var(--crit)}.strip .med{stroke:var(--ink);stroke-width:2}
    \\.failure{border:1px solid var(--ring);border-left:4px solid var(--crit);border-radius:8px;margin:10px 0;overflow:hidden}
    \\.failure summary{cursor:pointer;padding:10px 14px}.failure .reason{color:var(--ink)}
    \\pre{margin:0;padding:12px 14px;background:var(--wash);font:12px/1.5 var(--mono);overflow:auto;max-height:420px;white-space:pre-wrap;word-break:break-word}
    \\.failure pre{border-top:1px solid var(--ring)}
    \\details.full>summary{cursor:pointer;color:var(--ink2);margin-top:18px}
    \\details.full pre{border:1px solid var(--ring);border-radius:8px;margin-top:8px;white-space:pre;max-height:none}
    \\footer{color:var(--muted);font-size:12px;text-align:center;margin-top:24px}
    \\@media print{:root{color-scheme:light}body{background:#fff}main{max-width:none;padding:0}nav{display:none}
    \\section,.card,.failure{break-inside:avoid}.scroll{max-height:none;overflow:visible;border:0}pre{max-height:none}}
;

/// A color group, a category or a step, with the CPU time of its completed
/// attempts.
const Group = struct { name: []const u8, cpu_s: f64 = 0, first: usize = 0 };

/// A step as the launch ran it: its labels, when it first started, and what
/// its attempts took.
const Step = struct {
    name: []const u8,
    category: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    first_ns: i128 = 0,
    attempts: usize = 0,
    completed: usize = 0,
    failed: usize = 0,
    samples: usize = 0,
    /// Wall times of the completed attempts, ascending.
    walls: std.ArrayList(f64) = .empty,
    cpu_s: f64 = 0,
    peak_mib: f64 = 0,
    request_mib: f64 = 0,
    threads: f64 = 0,
    /// The most cores one attempt kept busy on average.
    cores: f64 = 0,
    /// Completed runs reused from earlier launches.
    reused: usize = 0,
    /// Position in the pipeline, from the workflow's graph; unknown when the
    /// snapshot cannot be read.
    rank: ?u64 = null,
};

/// What the page shows about the launch, read once from its records.
const Launch = struct {
    /// The attempts of this launch: the timeline, budget, limits, failures
    /// and attempt table show these.
    rows: []const report.Attempt,
    /// The attempts of this launch and, for each rule it reused, the attempt
    /// that made the outputs it reused: the time, samples and steps sections
    /// show the whole pipeline from these.
    all: []const report.Attempt,
    /// CPU seconds of the reused attempts in `all`.
    reused_cpu: f64 = 0,
    summary: ?Value,
    status: []const u8,
    t0: i128 = 0,
    span: f64,
    elapsed: f64,
    max_threads: f64 = 0,
    max_memory: f64 = 0,
    usage: []const Usage,
    path: []const []const u8,
    /// The highest attempt number of each rule: its final attempt.
    last: std.StringHashMapUnmanaged(i64),
    /// Steps in pipeline order: by their depth in the workflow's graph, else
    /// by when their first attempt started.
    steps: []Step,
    /// Distinct samples, in name order.
    sample_names: []const []const u8,
    /// Colors go to categories when the workflow declares any, else to
    /// steps; `groups` lists them by CPU time, most first, so the largest
    /// keep a hue of their own.
    by_category: bool,
    groups: []const Group,
    medians: std.StringHashMapUnmanaged(f64),

    fn onPath(self: *const Launch, r: report.Attempt) bool {
        if (!self.final(r)) return false;
        for (self.path) |n| if (eql(u8, n, r.rule)) return true;
        return false;
    }

    fn final(self: *const Launch, r: report.Attempt) bool {
        return (self.last.get(r.rule) orelse 0) == r.attempt;
    }

    fn at(self: *const Launch, ns: i128) f64 {
        return @as(f64, @floatFromInt(ns - self.t0)) / 1e9;
    }

    fn groupName(self: *const Launch, step: []const u8, category: ?[]const u8) []const u8 {
        return if (self.by_category) category orelse "uncategorized" else step;
    }

    /// The color slot of a group: 1 to 8 by CPU time; with more than eight
    /// groups the eighth and later share the neutral slot 0, "other".
    fn slot(self: *const Launch, group: []const u8) usize {
        for (self.groups, 0..) |g, i| if (eql(u8, g.name, group)) {
            if (self.groups.len <= 8) return i + 1;
            return if (i < 7) i + 1 else 0;
        };
        return 0;
    }

    fn slotOf(self: *const Launch, r: report.Attempt) usize {
        return self.slot(self.groupName(r.step, r.category));
    }

    fn stepSlot(self: *const Launch, s: Step) usize {
        return self.slot(self.groupName(s.name, s.category));
    }

    fn groupLabel(self: *const Launch) []const u8 {
        return if (self.by_category) "category" else "step";
    }
};

pub fn write(gpa: Allocator, a: Allocator, w: *std.Io.Writer, launch_dir: []const u8) !void {
    const rows = try report.attempts(gpa, a, launch_dir);
    const summary = readJson(gpa, a, try std.fs.path.join(a, &.{ launch_dir, "summary.json" }));
    const info = readJson(gpa, a, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }));

    // A rule reused here is shown with the attempt that made its outputs.
    const reused = try report.reusedAttempts(gpa, a, launch_dir);
    const all = try std.mem.concat(a, report.Attempt, &.{ rows, reused });
    var l: Launch = .{
        .rows = rows,
        .all = all,
        .summary = summary,
        .status = if (summary) |s| str(s, "status") else "running",
        .span = 0,
        .elapsed = if (summary) |s| num(get(s, "elapsed_s")) orelse 0 else 0,
        .usage = &.{},
        .path = &.{},
        .last = .empty,
        .steps = &.{},
        .sample_names = &.{},
        .by_category = false,
        .groups = &.{},
        .medians = .empty,
    };

    // Launch start, budget and run samples from the event stream.
    var usage: std.ArrayList(Usage) = .empty;
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
                try usage.append(a, .{
                    .t = @as(f64, @floatFromInt(at - l.t0)) / 1e9,
                    .threads = num(get(v, "threads_reserved")) orelse 0,
                    .cpu = num(get(v, "cpu_cores_used")),
                    .mem_mib = if (num(get(v, "memory_current"))) |m| m / 1048576.0 else null,
                    .reserved_mib = num(get(v, "memory_reserved_mib")) orelse 0,
                });
            }
        }
    }
    l.usage = usage.items;
    l.span = l.elapsed;
    for (rows) |r| if (r.started_ns > 0) {
        l.span = @max(l.span, l.at(r.started_ns) + r.wall_s);
    };
    // A rule reused here has no attempt in this launch, so `last` holds one
    // attempt number per rule across both.
    for (all) |r| {
        const gop = try l.last.getOrPut(a, r.rule);
        if (!gop.found_existing or r.attempt > gop.value_ptr.*) gop.value_ptr.* = r.attempt;
    }
    for (reused) |r| l.reused_cpu += r.cpu_s;
    l.span = @max(l.span, 0.001);
    l.path = try report.criticalPathNames(gpa, a, launch_dir, rows);
    try collectSteps(a, &l, try report.stepOrder(gpa, a, launch_dir));

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
    try w.print(" <span class=\"badge\"><i class=\"dot d-{s}\"></i>", .{tone(l.status)});
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
    try w.writeAll("<nav><a href=\"#time\">Where the time went</a>");
    if (l.sample_names.len > 0) try w.writeAll("<a href=\"#samples\">Samples by step</a>");
    try w.writeAll("<a href=\"#steps\">Steps</a><a href=\"#timeline\">Timeline</a><a href=\"#budget\">Budget</a><a href=\"#limits\">What limited it</a>");
    try w.print("<a href=\"#failures\">Failures ({d})</a><a href=\"#attempts\">Attempts ({d})</a></nav>\n", .{ failures, rows.len });

    try writeCards(w, &l);
    try writeTime(a, w, &l);
    try writeMatrix(a, w, &l);
    try writeSteps(a, w, &l);
    try writeTimeline(a, w, &l);
    try writeBudget(w, &l);
    try writeLimits(gpa, a, w, &l, launch_dir);
    try writeFailures(gpa, a, w, rows, failures);
    try writeAttempts(w, &l);

    try w.writeAll("<footer>Written by ");
    try escape(w, if (engine.len > 0) engine else "workz");
    try w.writeAll(" from the records in <code>.workz/launches/");
    try escape(w, id);
    try w.writeAll("</code>. The page has no scripts and loads nothing from elsewhere.</footer>\n</main></body></html>\n");
}

/// The steps in pipeline order with what their attempts took, the samples,
/// the color groups and each step's median wall time.
fn collectSteps(a: Allocator, l: *Launch, order: std.StringHashMapUnmanaged(u64)) !void {
    var map: std.StringArrayHashMapUnmanaged(Step) = .empty;
    var pairs: std.StringHashMapUnmanaged(void) = .empty;
    var samples: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (l.all) |r| {
        if (r.category != null) l.by_category = true;
        const gop = try map.getOrPut(a, r.step);
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = r.step, .rank = order.get(r.step) };
        const s = gop.value_ptr;
        if (s.category == null) s.category = r.category;
        if (s.tool == null) s.tool = r.tool;
        if (r.started_ns > 0 and (s.first_ns == 0 or r.started_ns < s.first_ns)) s.first_ns = r.started_ns;
        s.attempts += 1;
        s.request_mib = @max(s.request_mib, r.request_mib);
        s.threads = @max(s.threads, r.threads);
        if (eql(u8, r.status, "completed")) {
            s.completed += 1;
            s.reused += @intFromBool(r.reused_from != null);
            try s.walls.append(a, r.wall_s);
            s.cpu_s += r.cpu_s;
            s.peak_mib = @max(s.peak_mib, r.peak_mib orelse r.rss_mib);
            if (r.wall_s > 0) s.cores = @max(s.cores, r.cpu_s / r.wall_s);
        } else if (!eql(u8, r.status, "cancelled")) s.failed += 1;
        if (r.sample) |name| {
            try samples.put(a, name, {});
            const pair = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ r.step, name });
            if (!pairs.contains(pair)) {
                try pairs.put(a, pair, {});
                s.samples += 1;
            }
        }
    }
    const steps = map.values();
    for (steps) |*s| std.mem.sort(f64, s.walls.items, {}, std.sort.asc(f64));
    std.mem.sort(Step, steps, {}, struct {
        fn before(_: void, x: Step, y: Step) bool {
            if (x.rank != null and y.rank != null and x.rank.? != y.rank.?) return x.rank.? < y.rank.?;
            if (x.first_ns != y.first_ns) {
                if (x.first_ns == 0) return false;
                if (y.first_ns == 0) return true;
                return x.first_ns < y.first_ns;
            }
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.before);
    l.steps = steps;

    const names = samples.keys();
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    l.sample_names = names;

    var groups: std.ArrayList(Group) = .empty;
    for (steps) |s| {
        const g = l.groupName(s.name, s.category);
        for (groups.items) |*x| {
            if (eql(u8, x.name, g)) {
                x.cpu_s += s.cpu_s;
                break;
            }
        } else try groups.append(a, .{ .name = g, .cpu_s = s.cpu_s, .first = groups.items.len });
    }
    std.mem.sort(Group, groups.items, {}, struct {
        fn before(_: void, x: Group, y: Group) bool {
            if (x.cpu_s != y.cpu_s) return x.cpu_s > y.cpu_s;
            return x.first < y.first;
        }
    }.before);
    l.groups = groups.items;
    l.medians = try report.stepMedians(a, l.all);
}

/// The launch at a glance: elapsed time, rules, the pipeline's samples and
/// steps, attempts, CPU and memory use against the budget, and the
/// engine's own cost.
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

    try w.print("<div class=\"card\"><div class=\"k\">Rules done</div><div class=\"v\">{d:.0} of {d:.0}</div><div class=\"s\">{d:.0} ran, {d:.0} reused", .{ completed + reused, selected, completed, reused });
    if (failed + blocked > 0) try w.print(", {d:.0} failed or blocked", .{failed + blocked});
    if (cancelled > 0) try w.print(", {d:.0} not run", .{cancelled});
    try w.writeAll("</div></div>\n");

    var categories: usize = 0;
    var tools: std.StringHashMapUnmanaged(void) = .empty;
    if (l.by_category) categories = l.groups.len;
    for (l.steps) |st| if (st.tool) |t| {
        tools.put(std.heap.page_allocator, t, {}) catch {};
    };
    defer tools.deinit(std.heap.page_allocator);
    try w.writeAll("<div class=\"card\"><div class=\"k\">Pipeline</div><div class=\"v\">");
    if (l.sample_names.len > 0) {
        try w.print("{d} {s}</div><div class=\"s\">{d} {s}", .{ l.sample_names.len, if (l.sample_names.len == 1) "sample" else "samples", l.steps.len, if (l.steps.len == 1) "step" else "steps" });
    } else try w.print("{d} {s}</div><div class=\"s\">no samples declared", .{ l.steps.len, if (l.steps.len == 1) "step" else "steps" });
    if (categories > 0) try w.print(" in {d} {s}", .{ categories, if (categories == 1) "category" else "categories" });
    if (tools.count() > 0) try w.print(", {d} {s}", .{ tools.count(), if (tools.count() == 1) "tool" else "tools" });
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
    for (l.usage) |x| {
        threads += x.threads;
        if (x.cpu) |c| {
            cpu += c;
            cpu_n += 1;
        }
        if (x.mem_mib) |m| peak = @max(peak, m);
    }
    const n: f64 = @floatFromInt(l.usage.len);
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

/// CPU time of the completed attempts as one bar split by category (or by
/// step), and per tool.
fn writeTime(a: Allocator, w: *std.Io.Writer, l: *const Launch) !void {
    var total: f64 = 0;
    for (l.groups) |g| total += g.cpu_s;
    try w.writeAll("<section id=\"time\"><h2>Where the time went</h2>\n");
    if (total <= 0) return w.writeAll("<p class=\"muted\">No attempt completed.</p></section>\n");
    if (l.reused_cpu > 0) {
        try w.writeAll("<p class=\"lead\">CPU time of every rule's completed run: ");
        try duration(w, total);
        try w.writeAll(" in all. This launch ran ");
        try duration(w, @max(total - l.reused_cpu, 0));
        try w.print(" of it; the rest is from earlier launches, whose outputs it reused. Each {s} keeps its color across the page.</p>\n", .{l.groupLabel()});
    } else {
        try w.writeAll("<p class=\"lead\">CPU time of the completed attempts: ");
        try duration(w, total);
        try w.print(" in all. Each {s} keeps its color across the page.</p>\n", .{l.groupLabel()});
    }
    // Past eight groups, the eighth and later fold into one "other" part.
    const shown = if (l.groups.len <= 8) l.groups.len else 7;
    var rest: f64 = 0;
    for (l.groups[shown..]) |g| rest += g.cpu_s;
    try w.print("<h3>By {s}</h3>\n<div class=\"split\" role=\"img\" aria-label=\"CPU time by {s}\">", .{ l.groupLabel(), l.groupLabel() });
    for (l.groups[0..shown]) |g| {
        if (g.cpu_s <= 0) continue;
        try w.print("<i class=\"g{d}\" style=\"flex:{d:.3} 1 0\" title=\"", .{ l.slot(g.name), g.cpu_s });
        try escape(w, g.name);
        try w.print(": {d:.1} s CPU\"></i>", .{g.cpu_s});
    }
    if (rest > 0) {
        try w.print("<i class=\"g0\" style=\"flex:{d:.3} 1 0\" title=\"", .{rest});
        for (l.groups[shown..], 0..) |g, i| {
            if (i > 0) try w.writeAll(", ");
            try escape(w, g.name);
        }
        try w.print(": {d:.1} s CPU\"></i>", .{rest});
    }
    try w.writeAll("</div>\n<ul class=\"legend\">");
    for (l.groups[0..shown]) |g| {
        try w.print("<li><i class=\"g{d}\"></i><b>", .{l.slot(g.name)});
        try escape(w, g.name);
        try w.writeAll("</b>&nbsp; ");
        try duration(w, g.cpu_s);
        try share(w, g.cpu_s, total);
        try w.writeAll("</li>");
    }
    if (shown < l.groups.len) {
        try w.print("<li><i class=\"g0\"></i><b>{d} other {s}</b>&nbsp; ", .{ l.groups.len - shown, if (l.by_category) "categories" else "steps" });
        try duration(w, rest);
        try share(w, rest, total);
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul>\n");

    const tools = try report.labelTotals(a, l.all, .tool);
    if (tools.len > 0) {
        var most: f64 = 0;
        for (tools) |t| most = @max(most, t.cpu_s);
        try w.writeAll("<h3>By tool</h3>\n<div class=\"wide\"><table><thead><tr><th>tool</th><th class=\"n\">steps</th><th class=\"n\">attempts</th><th class=\"n\">wall time</th><th>CPU time</th></tr></thead><tbody>\n");
        for (tools) |t| {
            try w.writeAll("<tr><td>");
            try escape(w, t.name);
            try w.print("</td><td class=\"n\">{d}</td><td class=\"n\">{d}</td><td class=\"n\">", .{ t.steps, t.attempts });
            try duration(w, t.wall_s);
            try w.print("</td><td><div class=\"hbar\"><div class=\"bar\"><i class=\"b-use\" style=\"width:{d:.2}%\"></i></div><span>", .{@max(t.cpu_s / @max(most, 0.001) * 100, 0.5)});
            try duration(w, t.cpu_s);
            try share(w, t.cpu_s, total);
            try w.writeAll("</span></div></td></tr>\n");
        }
        try w.writeAll("</tbody></table></div>\n");
    }
    try w.writeAll("</section>\n");
}

/// The final attempt of each sample's run of a step, or null.
fn cellOf(l: *const Launch, sample: ?[]const u8, step: []const u8) ?report.Attempt {
    var best: ?report.Attempt = null;
    for (l.all) |r| {
        if (!l.final(r) or !eql(u8, r.step, step)) continue;
        if (sample) |want| {
            const have = r.sample orelse continue;
            if (!eql(u8, have, want)) continue;
        } else if (r.sample != null) continue;
        if (best == null or r.wall_s > best.?.wall_s) best = r;
    }
    return best;
}

/// The shade of a run, 1 to 7, by its wall time against its step's median:
/// under 0.9x, 1x, 1.1x, 1.25x, 1.5x, 2x, and 2x or more.
fn shade(wall: f64, median: f64) usize {
    if (median <= 0) return 3;
    const bounds = [_]f64{ 0.9, 1.0, 1.1, 1.25, 1.5, 2.0 };
    const ratio = wall / median;
    for (bounds, 1..) |b, i| if (ratio < b) return i;
    return 7;
}

/// One row per sample and one column per step, in pipeline order: each cell
/// the sample's run of the step, shaded by its wall time among the samples
/// of that step. Steps without a sample get a last row of their own.
fn writeMatrix(a: Allocator, w: *std.Io.Writer, l: *const Launch) !void {
    if (l.sample_names.len == 0) return;
    try w.writeAll("<section id=\"samples\"><h2>Samples by step</h2>\n<p class=\"lead\">Each cell is one sample's run of one step, shaded by its wall time against the median of that step, so a shade means the same in every column. Hover a cell for its numbers.</p>\n");
    var whole = false;
    for (l.all) |r| whole = whole or r.sample == null;

    try w.writeAll("<div class=\"wide\"><table class=\"matrix\"><thead><tr><th></th>");
    for (l.steps) |s| {
        try w.writeAll("<th class=\"step\" title=\"");
        try escape(w, s.name);
        if (s.category) |c| {
            try w.writeAll(", ");
            try escape(w, c);
        }
        if (s.tool) |t| {
            try w.writeAll(", ");
            try escape(w, t);
        }
        try w.print("\"><i class=\"g{d}\"></i>", .{l.stepSlot(s)});
        try escape(w, middle(a, s.name, 24));
        try w.writeAll("</th>");
    }
    try w.writeAll("<th class=\"n\">CPU time</th></tr></thead><tbody>\n");
    var rows_out: usize = 0;
    var row_names: std.ArrayList(?[]const u8) = .empty;
    for (l.sample_names) |n| try row_names.append(a, n);
    if (whole) try row_names.append(a, null);
    for (row_names.items) |sample| {
        rows_out += 1;
        try w.writeAll("<tr><td class=\"row\">");
        if (sample) |n| try escape(w, n) else try w.writeAll("<span class=\"muted\">whole run</span>");
        try w.writeAll("</td>");
        var cpu: f64 = 0;
        for (l.steps) |s| {
            const r = cellOf(l, sample, s.name) orelse {
                try w.writeAll("<td class=\"none\"></td>");
                continue;
            };
            const t = tone(r.status);
            const median = l.medians.get(s.name) orelse 0;
            const slow = eql(u8, t, "ok") and report.slowAgainstStep(r, median);
            if (eql(u8, t, "ok")) {
                cpu += r.cpu_s;
                const reused = if (r.reused_from != null) " reused" else "";
                if (s.completed < 2) {
                    try w.print("<td class=\"cell solo{s}\" title=\"", .{reused});
                } else try w.print("<td class=\"cell q{d}{s}{s}\" title=\"", .{ shade(r.wall_s, median), if (slow) " slow" else "", reused });
            } else try w.print("<td class=\"cell {s}\" title=\"", .{t});
            if (sample) |n| try escape(w, n) else try w.writeAll("whole run");
            try w.writeAll(" &middot; ");
            try escape(w, s.name);
            try w.writeAll(": ");
            try escape(w, r.status);
            try w.writeAll(", ");
            try duration(w, r.wall_s);
            try w.print(" wall, {d:.1} s CPU", .{r.cpu_s});
            if (r.peak_mib) |p| {
                try w.writeAll(", peak ");
                try size(w, p);
            }
            if (median > 0 and eql(u8, t, "ok")) try w.print(", {d:.2}x the step's median", .{r.wall_s / median});
            if (r.attempt > 1) try w.print(", attempt {d}", .{r.attempt});
            if (r.reused_from) |from| {
                try w.writeAll(", reused from launch ");
                try escape(w, from);
            }
            try w.print("\">{s}</td>", .{if (eql(u8, t, "fail")) "x" else if (eql(u8, t, "cancel")) "-" else if (slow) "!" else ""});
        }
        try w.writeAll("<td class=\"sum\">");
        try duration(w, cpu);
        try w.writeAll("</td></tr>\n");
    }
    try w.writeAll("</tbody></table></div>\n<ul class=\"legend\"><li>against the step's median: under 0.9x&nbsp;<span class=\"scale\"><i class=\"q1\"></i><i class=\"q2\"></i><i class=\"q3\"></i><i class=\"q4\"></i><i class=\"q5\"></i><i class=\"q6\"></i><i class=\"q7\"></i></span>2x or more</li><li><i class=\"solo\" style=\"background:var(--base)\"></i>the step's only run</li>");
    try w.writeAll("<li><b>!</b>&nbsp; at least 1.5 times the step's median and 2 s longer</li><li><b>x</b>&nbsp; failed</li><li><b>-</b>&nbsp; cancelled</li>");
    if (l.reused_cpu > 0) try w.writeAll("<li><i class=\"sw-reused\"></i>reused: run in an earlier launch</li>");
    try w.writeAll("<li><i style=\"background:var(--wash);border:1px solid var(--ring)\"></i>no completed run</li></ul>\n</section>\n");
}

/// One row per step in pipeline order: its labels, how many samples and
/// attempts, the spread of wall time across its samples, the cores and
/// memory it used against its request, and the suggested request.
fn writeSteps(a: Allocator, w: *std.Io.Writer, l: *const Launch) !void {
    const suggestions = try report.suggestions(a, l.all);
    try w.writeAll("<section id=\"steps\"><h2>Steps</h2>\n<p class=\"lead\">Every step in pipeline order. The spread shows each completed run as a dot on the step's own time scale, with its median as a bar: a dot far to the right is a run worth a look. Suggested requests cover the largest peak with a fifth to spare, as <code>workz report --suggest</code> prints them.</p>\n");
    if (l.steps.len == 0) return w.writeAll("<p class=\"muted\">No attempt ran.</p></section>\n");
    try w.writeAll("<div class=\"wide\"><table><thead><tr><th>step</th><th class=\"n\">runs</th><th class=\"n\">median</th><th>spread of wall time</th><th class=\"n\">cores used</th><th>memory, peak of request</th><th class=\"n\">suggested</th></tr></thead><tbody>\n");
    for (l.steps) |s| {
        try w.print("<tr><td class=\"name\"><i class=\"g{d}\"></i>", .{l.stepSlot(s)});
        try escape(w, s.name);
        // What the step is: its category, tool and number of samples.
        var parts: usize = 0;
        for ([_]?[]const u8{ s.category, s.tool }) |label| if (label) |text| {
            try w.writeAll(if (parts == 0) "<small>" else " &middot; ");
            try escape(w, text);
            parts += 1;
        };
        if (s.samples > 0) {
            try w.writeAll(if (parts == 0) "<small>" else " &middot; ");
            try w.print("{d} {s}", .{ s.samples, if (s.samples == 1) "sample" else "samples" });
            parts += 1;
        }
        if (parts > 0) try w.writeAll("</small>");
        try w.print("</td><td class=\"n\">{d}", .{s.attempts});
        if (s.failed > 0) try w.print("<small class=\"sub\"><i class=\"dot d-fail\"></i> {d} failed</small>", .{s.failed});
        if (s.reused > 0) try w.print("<small class=\"sub\">{d} reused</small>", .{s.reused});
        try w.writeAll("</td><td class=\"n\">");
        const median = l.medians.get(s.name) orelse 0;
        if (s.completed > 0) try duration(w, median) else try w.writeAll("-");
        try w.writeAll("</td><td>");
        try writeStrip(w, l, s, median);
        try w.writeAll("</td><td class=\"n\">");
        if (s.completed > 0) try w.print("{d:.1} of {d:.0}", .{ s.cores, s.threads }) else try w.writeAll("-");
        // A step without a completed run has no peak to show.
        if (s.completed == 0) try w.writeAll("</td><td class=\"muted\">-</td><td class=\"n\">") else {
            try w.writeAll("</td><td><div class=\"hbar\"><div class=\"bar\">");
            if (s.request_mib > 0) try w.print("<i class=\"b-use\" style=\"width:{d:.2}%\"></i>", .{@min(@max(s.peak_mib / s.request_mib * 100, 0.5), 100)});
            try w.writeAll("</div><span>");
            try size(w, s.peak_mib);
            try w.writeAll(" of ");
            try size(w, s.request_mib);
            try w.writeAll("</span></div></td><td class=\"n\">");
        }
        const found = for (suggestions) |g| {
            if (eql(u8, g.step, s.name)) break g;
        } else null;
        if (found) |g| {
            if (g.delegated) try w.writeAll("<span class=\"muted\">delegated</span>") else {
                try w.print("{d:.0} {s}, ", .{ g.suggest_threads, if (g.suggest_threads == 1) "thread" else "threads" });
                try size(w, g.suggest_mib);
            }
        } else try w.writeAll("-");
        try w.writeAll("</td></tr>\n");
    }
    try w.writeAll("</tbody></table></div>\n<ul class=\"legend\"><li><i class=\"sw-use\" style=\"border-radius:50%\"></i>a completed run</li><li><i style=\"background:var(--warn);border-radius:50%\"></i>at least 1.5 times the median and 2 s longer</li><li><i style=\"background:var(--ink);width:2px\"></i>median</li><li><i class=\"sw-use\"></i>largest peak against the memory request</li></ul>\n</section>\n");
}

/// A step's completed runs as dots on its own wall-time scale, with the
/// median as a bar.
fn writeStrip(w: *std.Io.Writer, l: *const Launch, s: Step, median: f64) !void {
    if (s.completed < 2) return w.writeAll(if (s.completed == 1) "<span class=\"muted\">one run</span>" else "<span class=\"muted\">-</span>");
    const max = @max(s.walls.items[s.walls.items.len - 1], 0.001);
    const x0: f64 = 7;
    const width: f64 = 166;
    try w.writeAll("<svg class=\"strip\" viewBox=\"0 0 180 26\" role=\"img\" aria-label=\"wall time of each run\">");
    try w.print("<line class=\"grid\" x1=\"{d:.0}\" y1=\"13\" x2=\"{d:.0}\" y2=\"13\"/>", .{ x0, x0 + width });
    try w.print("<line class=\"med\" x1=\"{d:.1}\" y1=\"5\" x2=\"{d:.1}\" y2=\"21\"/>", .{ x0 + median / max * width, x0 + median / max * width });
    for (l.all) |r| {
        if (!eql(u8, r.step, s.name) or !eql(u8, r.status, "completed")) continue;
        try w.print("<circle cx=\"{d:.1}\" cy=\"13\" r=\"4.5\"{s}><title>", .{ x0 + r.wall_s / max * width, if (report.slowAgainstStep(r, median)) " class=\"slow\"" else "" });
        try escape(w, r.sample orelse r.rule);
        try w.writeAll(": ");
        try duration(w, r.wall_s);
        try w.writeAll("</title></circle>");
    }
    try w.writeAll("</svg>");
}

/// One row per attempt in start order, labelled with its rule: the wait
/// before it as a thin bar, its run in the color of its category (or
/// step), failures and cancellations in their state colors, and the
/// attempts on the critical path outlined.
fn writeTimeline(a: Allocator, w: *std.Io.Writer, l: *const Launch) !void {
    var list: std.ArrayList(report.Attempt) = .empty;
    for (l.rows) |r| if (r.started_ns > 0) try list.append(a, r);
    std.mem.sort(report.Attempt, list.items, {}, struct {
        fn lt(_: void, x: report.Attempt, y: report.Attempt) bool {
            return x.started_ns < y.started_ns;
        }
    }.lt);
    try w.print("<section id=\"timeline\"><h2>Timeline</h2>\n<p class=\"lead\">Every attempt in the order it started: the time it waited for resources, then its run, in the color of its {s}.</p>\n", .{l.groupLabel()});
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
        const t = tone(r.status);
        var class_buf: [16]u8 = undefined;
        const class = if (eql(u8, t, "fail")) "st-fail" else if (eql(u8, t, "cancel")) "st-cancel" else std.fmt.bufPrint(&class_buf, "g{d}", .{l.slotOf(r)}) catch "g0";
        try w.print("<rect class=\"{s}{s}\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"{d:.0}\"><title>", .{ class, if (crit) " crit" else "", run_from, y + pad, @max(run_to - run_from, 1), row_h - 2 * pad, @min(pad, 2) });
        try escape(w, r.rule);
        try w.print(", attempt {d}: ", .{r.attempt});
        try escape(w, r.status);
        try w.writeAll(" (");
        try escape(w, r.step);
        if (r.sample) |sm| {
            try w.writeAll(", ");
            try escape(w, sm);
        }
        try w.writeAll("); started at ");
        try duration(w, start);
        try w.writeAll(", waited ");
        try duration(w, r.waited_s);
        try w.writeAll(", ran ");
        try duration(w, r.wall_s);
        try w.writeAll("</title></rect>\n");
    }
    // The legend names only the groups this launch's attempts belong to.
    try w.writeAll("</svg>\n<ul class=\"legend\">");
    var other: usize = 0;
    for (l.groups, 0..) |g, i| {
        const present = for (list.items) |r| {
            if (eql(u8, l.groupName(r.step, r.category), g.name)) break true;
        } else false;
        if (!present) continue;
        if (l.groups.len > 8 and i >= 7) {
            other += 1;
            continue;
        }
        try w.print("<li><i class=\"g{d}\"></i>", .{l.slot(g.name)});
        try escape(w, g.name);
        try w.writeAll("</li>");
    }
    if (other > 0) try w.print("<li><i class=\"g0\"></i>{d} other {s}</li>", .{ other, if (l.by_category) "categories" else "steps" });
    try w.writeAll("<li><i class=\"sw-fail\"></i>failed</li><li><i class=\"sw-cancel\"></i>cancelled</li><li><i class=\"sw-wait\"></i>waiting for resources</li><li><i class=\"sw-crit\"></i>critical path</li></ul>\n</section>\n");
}

/// Threads reserved and CPU cores in use, then memory reserved and in use,
/// from the run samples, against the budget.
fn writeBudget(w: *std.Io.Writer, l: *const Launch) !void {
    try w.writeAll("<section id=\"budget\"><h2>Use of the budget</h2>\n<p class=\"lead\">What the scheduler reserved for running rules, and what they used, from run samples taken every 5 s.</p>\n");
    if (l.usage.len < 2) return w.writeAll("<p class=\"muted\">The launch was too short for run samples.</p></section>\n");
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
    for (l.usage) |s| most = @max(most, if (memory) @max(s.reserved_mib, s.mem_mib orelse 0) else @max(s.threads, s.cpu orelse 0));
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
            for (l.usage) |s| {
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
            for (l.rows) |r| if (eql(u8, r.rule, l.path[i]) and l.final(r)) {
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
        try w.writeAll(" waiting for resources.</p>\n<div class=\"wide\"><table><thead><tr><th>rule</th><th>step</th><th class=\"n\">started</th><th class=\"n\">waited</th><th class=\"n\">ran</th><th>over the launch</th></tr></thead><tbody>\n");
        for (steps.items) |r| {
            const start = l.at(r.started_ns);
            try w.print("<tr><td class=\"name\"><i class=\"g{d}\"></i>", .{l.slotOf(r)});
            try escape(w, r.rule);
            try w.writeAll("</td><td>");
            try escape(w, r.step);
            try w.writeAll("</td><td class=\"n\">");
            try duration(w, start);
            try w.writeAll("</td><td class=\"n\">");
            try duration(w, r.waited_s);
            try w.writeAll("</td><td class=\"n\">");
            try duration(w, r.wall_s);
            const from = @max(start - r.waited_s, 0) / l.span * 100;
            const run_at = start / l.span * 100;
            try w.print("</td><td><div class=\"bar\"><i class=\"b-wait\" style=\"left:{d:.2}%;width:{d:.2}%;opacity:.45\"></i><i class=\"g{d}\" style=\"left:{d:.2}%;width:{d:.2}%\"></i></div></td></tr>\n", .{ from, run_at - from, l.slotOf(r), run_at, @max(r.wall_s / l.span * 100, 0.5) });
        }
        try w.writeAll("</tbody></table></div>\n");
    }

    var recorded = false;
    var totals = try report.waitTotals(gpa, a, launch_dir, &recorded);
    report.sortByValue(&totals);
    try w.writeAll("<h3>Why ready rules waited</h3>\n");
    var most: f64 = 0;
    for (totals.values()) |v| most = @max(most, v);
    if (most < 0.05) {
        try w.writeAll("<p class=\"muted\">No rule waited for resources once it was ready.</p>\n");
    } else {
        try w.writeAll("<p class=\"lead\">Seconds that rules were ready to start but waited, added up over all rules, by what they waited for.</p>\n<div class=\"wide\"><table><thead><tr><th>waited for</th><th>rule-seconds</th></tr></thead><tbody>\n");
        for (totals.keys(), totals.values()) |k, v| {
            if (v < 0.05) continue;
            try w.writeAll("<tr><td>");
            try escape(w, k);
            try w.print("</td><td><div class=\"hbar\"><div class=\"bar\"><i class=\"b-wait\" style=\"width:{d:.2}%\"></i></div><span>{d:.1}</span></div></td></tr>\n", .{ v / @max(most, 0.001) * 100, v });
        }
        try w.writeAll("</tbody></table></div>\n");
    }

    var text: std.Io.Writer.Allocating = .init(a);
    report.writeBottlenecks(gpa, a, &text.writer, launch_dir) catch {};
    try w.writeAll("<details class=\"full\"><summary>The full bottleneck report, as <code>workz report --bottlenecks</code> prints it</summary><pre>");
    try escape(w, text.written());
    try w.writeAll("</pre></details>\n</section>\n");
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
        try w.print("</code> attempt {d} <span class=\"chip\"><i class=\"dot d-{s}\"></i>", .{ r.attempt, tone(r.status) });
        try escape(w, r.status);
        try w.writeAll("</span> <span class=\"reason\">");
        try escape(w, r.reason);
        try w.writeAll("</span> <span class=\"muted\">");
        try escape(w, r.step);
        if (r.sample) |s| {
            try w.writeAll(", ");
            try escape(w, s);
        }
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

/// Every attempt with its labels, times and requests, in a table that
/// scrolls under a fixed header.
fn writeAttempts(w: *std.Io.Writer, l: *const Launch) !void {
    try w.print("<section id=\"attempts\"><h2>Attempts ({d})</h2>\n", .{l.rows.len});
    const samples = l.sample_names.len > 0;
    try w.print("<div class=\"scroll\"><table><thead><tr><th>rule</th><th>step</th>{s}<th class=\"n\">#</th><th>status</th><th class=\"n\">started</th><th class=\"n\">waited</th><th class=\"n\">ran</th><th class=\"n\">CPU s</th><th class=\"n\">threads</th><th class=\"n\">memory</th><th class=\"n\">peak</th><th>waited for</th></tr></thead><tbody>\n", .{if (samples) "<th>sample</th>" else ""});
    for (l.rows) |r| {
        try w.print("<tr><td class=\"name\"><i class=\"g{d}\"></i>", .{l.slotOf(r)});
        try escape(w, r.rule);
        try w.writeAll("</td><td>");
        try escape(w, r.step);
        if (samples) {
            try w.writeAll("</td><td>");
            if (r.sample) |s| try escape(w, s) else try w.writeAll("<span class=\"muted\">-</span>");
        }
        try w.print("</td><td class=\"n\">{d}</td><td><span class=\"chip\"><i class=\"dot d-{s}\"></i>", .{ r.attempt, tone(r.status) });
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
