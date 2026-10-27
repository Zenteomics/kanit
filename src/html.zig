//! `workz report --format html`, and the page a running launch keeps up to
//! date: one self-contained page drawn like an engineering sheet. A title
//! block gives the launch at a glance; numbered figures show the pipeline
//! as a schematic of its steps with the state of every rule, where the CPU
//! time went, each sample's run of each step, the steps with their
//! requests, the timeline, the use of the budget and what limited the
//! launch; tables list the failures and every attempt. While the launch
//! runs the page asks the browser to reload it every 5 s. Colors follow the
//! reader's light or dark setting, and the page prints. No scripts and no
//! remote assets.
const std = @import("std");
const sys = @import("sys.zig");
const model = @import("model.zig");
const report = @import("report.zig");
const units = @import("units.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const duration = units.duration;
const size = units.size;

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

/// `name` cut to `max` characters by dropping its middle.
fn middle(a: Allocator, name: []const u8, max: usize) []const u8 {
    if (name.len <= max or max < 5) return name;
    const keep = max - 3;
    const head = (keep + 1) / 2;
    return std.fmt.allocPrint(a, "{s}...{s}", .{ name[0..head], name[name.len - (keep - head) ..] }) catch name;
}

/// A round step for axis ticks, giving at most `most` of them over `span`.
fn tickStep(span: f64, most: f64) f64 {
    const steps = [_]f64{ 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 86400 };
    for (steps) |s| if (span / s <= most) return s;
    // Longer spans step by whole days, still at most `most` ticks.
    return 86400 * @ceil(span / 86400 / most);
}

/// An axis tick label: `0`, `0.5s`, `30s`, `2m`, `2m30s`, `1h`, `1h30m`; ticks
/// less than a second apart keep a decimal.
fn tickLabel(buf: []u8, s: f64, step: f64) []const u8 {
    const r = if (s == 0)
        std.fmt.bufPrint(buf, "0", .{})
    else if (step < 1)
        std.fmt.bufPrint(buf, "{d:.1}s", .{s})
    else blk: {
        const v: u64 = std.math.lossyCast(u64, @round(s));
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

// The page is drawn on paper with a faint grid: ink line work, hairline
// frames, condensed capitals for labels and monospace figures. Categories
// (or steps) take eight inks in a fixed order, validated for color vision
// deficiency against each paper; magnitude uses one ink ramp. States are
// drawn in ink, by form: done solid, reused hatched, running outlined,
// waiting dashed; so no state takes a category's hue, and red is kept for
// failure. Dark mode is a charcoal sheet with pale ink.
// The sheet in light: ink on paper. Categories c1-c8 keep one hue each in
// both themes; q1-q7 shade the samples matrix from fast to slow; --rule draws
// frames and dividers, --tab the figure numbers.
const light_theme =
    \\color-scheme:light;--paper:#f7f5ef;--sheet:#fbfaf6;--ink:#1d2b3a;--ink2:#4a5866;--muted:#5f6b78;--hair:#cfd3d8;--pend:#7d8894;
    \\--rule:#1d2b3a;--tab:#1d2b3a;--tab-ink:#fbfaf6;--g1:rgba(29,43,58,.04);--g2:rgba(29,43,58,.08);--wash:rgba(29,43,58,.05);
    \\--c1:#2b5fae;--c2:#c46a1a;--c3:#23896b;--c4:#8a5cc2;--c5:#a6841a;--c6:#2c86ad;--c7:#b84f7a;--c8:#6d7f2d;--c0:#9aa3ad;
    \\--q1:#e4e9f0;--q2:#c6d0dc;--q3:#a2b1c3;--q4:#8a9cb1;--q5:#5a718c;--q6:#3b5370;--q7:#1d2b3a;--t4:#1d2b3a;--t5:#fff;
    \\--done:#1d2b3a;--fail:#c62828;--fail-ink:#fff;--cancel:#7f8a96
;

// The sheet in dark: a neutral charcoal on which the same hues sit in a
// darker band, so no color glares against another; frames are a soft slate
// rather than bright ink.
const dark_theme =
    \\color-scheme:dark;--paper:#0c0f13;--sheet:#1a1f26;--ink:#e2e6eb;--ink2:#a9b2be;--muted:#7c8796;--hair:#2a3038;--pend:#6e7a89;
    \\--rule:#6e7a89;--tab:#3a4452;--tab-ink:#e2e6eb;--g1:rgba(214,222,232,.03);--g2:rgba(214,222,232,.06);--wash:rgba(214,222,232,.045);
    \\--c1:#5a87d6;--c2:#cf7838;--c3:#2fa07c;--c4:#9677d6;--c5:#a98a28;--c6:#3a9cc2;--c7:#cc6b93;--c8:#839744;--c0:#69737f;
    \\--q1:#262d37;--q2:#323c4a;--q3:#435163;--q4:#5a6b81;--q5:#7b8da5;--q6:#a3b2c5;--q7:#cfd8e3;--t4:#f6f7f9;--t5:#0c0f13;
    \\--done:#c9d2dd;--fail:#e5605c;--fail-ink:#0c0f13;--cancel:#707c8c
;

/// The choices of the theme switch; auto follows the reader's setting.
const themes = [_][]const u8{ "auto", "light", "dark" };

// The reader's color scheme decides, unless the theme switch on the page
// picks one; print is always light. The switch is three radio buttons that
// come before the sheet, `.page`, so the sheet takes its theme from the
// checked one with a sibling selector and the page needs no script.
const style = ".page{" ++ light_theme ++ "}\n" ++
    "@media (prefers-color-scheme:dark){#theme-auto:checked~.page{" ++ dark_theme ++ "}}\n" ++
    "#theme-dark:checked~.page{" ++ dark_theme ++ "}\n" ++
    "@media print{.page,#theme-auto:checked~.page,#theme-dark:checked~.page{" ++ light_theme ++ "}}\n" ++
    @embedFile("templates/report.css");

/// The page for one launch.
pub fn write(gpa: Allocator, a: Allocator, w: *std.Io.Writer, launch_dir: []const u8) !void {
    var l = try model.load(gpa, a, launch_dir);
    defer l.deinit();
    const p: Page = .{ .a = a, .w = w, .l = &l, .groups = try groups(a, &l) };

    try w.writeAll("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    // A running launch's page asks to be loaded again with its next state.
    if (!l.finished) try w.writeAll("<meta http-equiv=\"refresh\" content=\"5\">\n");
    try w.writeAll("<title>");
    try escape(w, l.name);
    try w.writeAll(" - workz launch ");
    try escape(w, l.id);
    try w.print("</title>\n<style>\n{s}</style></head><body>\n", .{style});
    // The theme switch's buttons come before the sheet they restyle; its
    // labels sit in the sheet's corner.
    for (themes) |t| try w.print("<input class=\"pick\" type=\"radio\" name=\"theme\" id=\"theme-{s}\" aria-label=\"{s} theme\"{s}>", .{ t, t, if (std.mem.eql(u8, t, "auto")) " checked" else "" });
    try w.writeAll("\n<div class=\"page\"><main>\n");

    try p.themeSwitch();
    try p.titleBlock();
    try p.nav();
    try p.pipeline();
    try p.time();
    try p.matrix();
    try p.stepsTable();
    try p.timeline();
    try p.budget();
    try p.limits();
    try p.failures();
    try p.attemptsTable();

    try w.writeAll("<footer>Drawn by ");
    try escape(w, if (l.engine.len > 0) l.engine else "workz");
    try w.writeAll(" from <span class=\"mono\">.workz/launches/");
    try escape(w, l.id);
    try w.writeAll("</span>");
    if (!l.finished) try w.writeAll(" &middot; this page reloads every 5 s while the launch runs");
    try w.writeAll(" &middot; no scripts, nothing loaded from elsewhere</footer>\n</main></div></body></html>\n");
}

/// Colors go to categories when the workflow declares any, else to steps,
/// in pipeline order, so a color stays with its group while a launch runs.
/// With more than eight groups, the eighth and later share gray.
const Groups = struct {
    names: []const []const u8,

    fn index(self: Groups, name: []const u8) usize {
        for (self.names, 0..) |n, i| if (eql(u8, n, name)) return i;
        return 0;
    }

    fn slot(self: Groups, name: []const u8) usize {
        const i = self.index(name);
        if (self.names.len <= 8) return i + 1;
        return if (i < 7) i + 1 else 0;
    }
};

fn groupName(l: *const model.Launch, step: usize) []const u8 {
    const s = l.steps[step];
    return if (l.by_category) s.category orelse "uncategorized" else s.name;
}

fn groups(a: Allocator, l: *const model.Launch) !Groups {
    var names: std.ArrayList([]const u8) = .empty;
    for (l.steps, 0..) |_, i| {
        const g = groupName(l, i);
        for (names.items) |x| {
            if (eql(u8, x, g)) break;
        } else try names.append(a, g);
    }
    return .{ .names = names.items };
}

const Page = struct {
    a: Allocator,
    w: *std.Io.Writer,
    l: *const model.Launch,
    groups: Groups,

    fn slotOfStep(self: Page, step: usize) usize {
        return self.groups.slot(groupName(self.l, step));
    }

    fn slotOfRule(self: Page, name: []const u8) usize {
        return self.slotOfStep(self.stepOfRule(name) orelse return 0);
    }

    fn stepOfRule(self: Page, name: []const u8) ?usize {
        return if (self.l.ruleOf(name)) |r| r.step else null;
    }

    fn groupLabel(self: Page) []const u8 {
        return if (self.l.by_category) "category" else "step";
    }

    fn figure(self: Page, id: []const u8, no: []const u8, title: []const u8, note: []const u8) !void {
        try self.w.print("<section class=\"fig\" id=\"{s}\"><div class=\"fig-h\"><span class=\"no\">{s}</span><h2>{s}</h2>", .{ id, no, title });
        if (note.len > 0) try self.w.print("<span class=\"note\">{s}</span>", .{note});
        try self.w.writeAll("</div><div class=\"fig-b\">\n");
    }

    fn endFigure(self: Page) !void {
        try self.w.writeAll("</div></section>\n");
    }

    // ---- title block ----

    /// Under the status stamp of a launch that did not complete, why: the
    /// reason it was refused or stopped, or its first failure and how many
    /// more there were.
    fn whyNotCompleted(self: Page) !void {
        const w = self.w;
        const l = self.l;
        if (!l.finished or eql(u8, l.status, "completed")) return;
        if (l.@"error") |e| {
            try w.writeAll("<div class=\"sub why\">");
            try escape(w, e);
            return w.writeAll("</div>");
        }
        var first: ?model.Attempt = null;
        var more: usize = 0;
        for (l.rows) |r| {
            if (r.completed() or eql(u8, r.status, "cancelled")) continue;
            if (first == null) first = r else more += 1;
        }
        const f = first orelse return;
        try w.writeAll("<div class=\"sub why\"><span class=\"mono\">");
        try escape(w, f.rule);
        try w.writeAll("</span>: ");
        try escape(w, if (f.reason.len > 0) f.reason else f.status);
        if (more > 0) try w.print("; {d} more {s}", .{ more, if (more == 1) "failure" else "failures" });
        try w.writeAll("</div>");
    }

    fn titleBlock(self: Page) !void {
        const w = self.w;
        const l = self.l;
        try w.writeAll("<header class=\"title\"><div class=\"row r1\"><div class=\"cell\"><span class=\"k\">workz &middot; launch report</span><h1>");
        try escape(w, l.name);
        try w.writeAll("</h1></div>\n<div class=\"cell\"><span class=\"k\">status</span>");
        const tone: []const u8 = if (!l.finished) "s-run live" else if (eql(u8, l.status, "completed")) "s-ok" else if (eql(u8, l.status, "interrupted") or eql(u8, l.status, "stopped")) "s-cancel" else "s-fail";
        try w.print("<span class=\"stamp {s}\">", .{tone});
        try escape(w, if (l.finished) l.status else "running");
        try w.writeAll("</span>");
        try self.whyNotCompleted();
        try w.writeAll("</div>\n<div class=\"cell\"><span class=\"k\">launch</span><span class=\"mono\">");
        try escape(w, l.id);
        try w.writeAll("</span></div>\n<div class=\"cell\"><span class=\"k\">started</span>");
        if (l.started_text.len >= 19) {
            try escape(w, l.started_text[0..10]);
            try w.writeAll(" ");
            try escape(w, l.started_text[11..19]);
            try w.writeAll(" UTC");
        } else try w.writeAll("-");
        try w.writeAll("</div>\n<div class=\"cell\"><span class=\"k\">engine</span>");
        try escape(w, if (l.engine.len > 0) l.engine else "workz");
        try w.writeAll("</div></div>\n<div class=\"row r2\">");

        // Elapsed, and what limited it: the largest lower bound.
        try w.writeAll("<div class=\"cell\"><span class=\"k\">elapsed</span><div class=\"big\">");
        try duration(w, l.elapsed_s);
        try w.writeAll("</div><div class=\"sub\">");
        if (l.binding) |bi| {
            if (l.overBound()) |over| {
                try w.writeAll("limited by ");
                try report.boundName(w, l.bounds[bi]);
                try w.print(", {d:.0}% over that bound", .{over});
            } else try w.writeAll("too short to say what limited it");
        } else try w.writeAll(if (l.finished) "nothing ran in this launch" else "starting");
        try w.writeAll("</div></div>\n");

        // Rules, by outcome.
        const c = l.counts;
        try w.print("<div class=\"cell\"><span class=\"k\">rules done</span><div class=\"big\">{d} of {d}</div><div class=\"sub\">", .{ c.completed + c.reused, l.selected });
        try w.print("{d} ran, {d} reused", .{ c.completed, c.reused });
        if (c.running > 0) try w.print("; {d} running", .{c.running});
        if (c.waiting + c.pending > 0) try w.print("; {d} to go", .{c.waiting + c.pending});
        if (c.failed > 0) try w.print("; {d} failed", .{c.failed});
        if (c.blocked > 0) try w.print("; {d} blocked", .{c.blocked});
        if (c.cancelled + c.not_run > 0) try w.print("; {d} not run", .{c.cancelled + c.not_run});
        if (eql(u8, l.status, "refused")) try w.writeAll("; the launch was refused, so none ran");
        try w.writeAll("</div></div>\n");

        // The pipeline's shape.
        try w.writeAll("<div class=\"cell\"><span class=\"k\">pipeline</span><div class=\"big\">");
        if (l.samples.len > 0) {
            try w.print("{d} &times; {d}</div><div class=\"sub\">samples by steps", .{ l.samples.len, l.steps.len });
        } else {
            try units.count(w, l.steps.len, "step", "steps");
            try w.writeAll("</div><div class=\"sub\">no samples declared");
        }
        if (l.by_category) try w.print(", {d} {s}", .{ self.groups.names.len, if (self.groups.names.len == 1) "category" else "categories" });
        try w.writeAll("</div></div>\n");

        // CPU and memory against the budget.
        var cores: f64 = 0;
        var cores_n: f64 = 0;
        var mem: f64 = 0;
        for (l.usage()) |s| {
            if (s.cpu_cores) |x| {
                cores += x;
                cores_n += 1;
            }
            if (s.memory_current) |m| mem = @max(mem, @as(f64, @floatFromInt(m)) / 1048576.0);
        }
        try w.writeAll("<div class=\"cell\"><span class=\"k\">CPU</span><div class=\"big\">");
        if (cores_n > 0) {
            try w.print("{d:.1}</div><div class=\"sub\">cores in use on average, of {d:.0} threads", .{ cores / cores_n, l.max_threads });
        } else try w.print("{d:.0}</div><div class=\"sub\">threads in the budget; no run samples", .{l.max_threads});
        try w.writeAll("</div></div>\n<div class=\"cell\"><span class=\"k\">memory</span><div class=\"big\">");
        if (mem > 0) {
            try size(w, mem);
            try w.writeAll("</div><div class=\"sub\">peak in use; budget ");
        } else try w.writeAll("-</div><div class=\"sub\">no run samples; budget ");
        try size(w, l.max_memory_mib);
        try w.writeAll("</div></div>\n<div class=\"cell\"><span class=\"k\">workz itself</span><div class=\"big\">");
        if (l.engine_cpu_s) |cpu| {
            try w.print("{d:.2} s</div><div class=\"sub\">CPU time of the engine", .{cpu});
            if (l.engine_rss_mib) |rss| {
                try w.writeAll(", ");
                try size(w, rss);
                try w.writeAll(" peak");
            }
        } else try w.writeAll("-</div><div class=\"sub\">measured when the launch ends");
        try w.writeAll("</div></div></div></header>\n");
        if (l.@"error") |e| {
            try w.writeAll("<div class=\"error\">");
            try escape(w, e);
            try w.writeAll("</div>\n");
        }
    }

    fn nav(self: Page) !void {
        const w = self.w;
        try w.writeAll("<nav><a href=\"#pipeline\"><b>1</b>Pipeline</a><a href=\"#time\"><b>2</b>CPU time</a>");
        if (self.l.samples.len > 0) try w.writeAll("<a href=\"#samples\"><b>3</b>Samples by step</a>");
        try w.writeAll("<a href=\"#steps\"><b>T1</b>Steps</a><a href=\"#timeline\"><b>4</b>Timeline</a><a href=\"#budget\"><b>5</b>Budget</a><a href=\"#limits\"><b>6</b>What limited it</a>");
        try w.print("<a href=\"#failures\"><b>T2</b>Failures ({d})</a><a href=\"#attempts\"><b>T3</b>Attempts ({d})</a></nav>\n", .{ failedCount(self.l), self.l.rows.len });
    }

    /// The theme switch, a tag at the sheet's corner: radio buttons the
    /// stylesheet reads with :has(), so the page needs no script. Auto
    /// follows the reader's color scheme.
    fn themeSwitch(self: Page) !void {
        const w = self.w;
        try w.writeAll("<div class=\"corner\"><span class=\"theme\"><span class=\"k\">theme</span>");
        for (themes) |t| try w.print("<label for=\"theme-{s}\">{s}</label>", .{ t, t });
        try w.writeAll("</span></div>\n");
    }

    // ---- FIG. 1: the pipeline ----

    fn pipeline(self: Page) !void {
        const w = self.w;
        const l = self.l;
        try self.figure("pipeline", "FIG. 1", "Pipeline", "each box a step, in graph order; each cell a rule");
        if (l.steps.len == 0) {
            if (l.snapshot_problem) |why| {
                try w.writeAll("<p class=\"muted\">The workflow snapshot cannot be read: ");
                try escape(w, why);
                try w.writeAll("</p>");
            } else try w.writeAll("<p class=\"muted\">No rule was selected.</p>");
            return self.endFigure();
        }
        // Columns by graph depth; within a column, steps follow their
        // producers' rows so wires cross less.
        var cols: std.ArrayList(std.ArrayList(usize)) = .empty;
        for (l.steps, 0..) |s, i| {
            while (cols.items.len <= s.depth) try cols.append(self.a, .empty);
            try cols.items[s.depth].append(self.a, i);
        }
        const row = try self.a.alloc(f64, l.steps.len);
        for (cols.items) |*col| {
            for (col.items) |si| {
                const ps = l.steps[si].parents.items;
                var sum: f64 = 0;
                for (ps) |pi| sum += row[pi];
                // A step without producers keeps its pipeline order.
                row[si] = if (ps.len > 0) sum / @as(f64, @floatFromInt(ps.len)) else @as(f64, @floatFromInt(si)) * 1e-3;
            }
            std.mem.sort(usize, col.items, row, struct {
                fn lt(r: []f64, x: usize, y: usize) bool {
                    if (r[x] != r[y]) return r[x] < r[y];
                    return x < y;
                }
            }.lt);
            for (col.items, 0..) |si, k| row[si] = @floatFromInt(k);
        }
        var most_rows: usize = 1;
        for (cols.items) |col| most_rows = @max(most_rows, col.items.len);
        const n_cols: f64 = @floatFromInt(cols.items.len);
        const gap: f64 = 40;
        // One width for every box: what the sheet leaves for each column,
        // widened to fit the longest step name beside its count; a wider
        // drawing scales down to the sheet.
        var need: f64 = 0;
        for (l.steps) |s| {
            var count_buf: [24]u8 = undefined;
            const count = std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ s.selected(), s.selected() }) catch "";
            need = @max(need, 12 + @as(f64, @floatFromInt(s.name.len)) * 7.2 + 10 + @as(f64, @floatFromInt(count.len)) * 6.8 + 8 + 4);
        }
        const box_w: f64 = @min(@max(@max(160, @min(230, (1170 - gap * (n_cols - 1)) / n_cols)), need), 280);
        const box_h: f64 = 66;
        const vgap: f64 = 18;
        const margin: f64 = 6;
        const width = margin * 2 + n_cols * box_w + (n_cols - 1) * gap;
        const height = margin * 2 + @as(f64, @floatFromInt(most_rows)) * (box_h + vgap) - vgap;
        // Rows line up across columns, so the gaps between them form
        // channels that wires can follow past other boxes.
        const xs = try self.a.alloc(f64, l.steps.len);
        const ys = try self.a.alloc(f64, l.steps.len);
        const cs = try self.a.alloc(usize, l.steps.len);
        for (cols.items, 0..) |col, c| for (col.items, 0..) |si, k| {
            xs[si] = margin + @as(f64, @floatFromInt(c)) * (box_w + gap);
            ys[si] = margin + @as(f64, @floatFromInt(k)) * (box_h + vgap);
            cs[si] = c;
        };

        try w.writeAll("<div class=\"wide\">");
        try w.print("<svg viewBox=\"0 0 {d:.0} {d:.0}\" style=\"min-width:{d:.0}px\" role=\"img\" aria-label=\"The pipeline: {d} steps\">\n", .{ width, height, @min(width, 900), l.steps.len });
        try w.writeAll("<defs><pattern id=\"hatch\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\" patternTransform=\"rotate(45)\"><line class=\"hatch\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"4\"/></pattern>");
        try w.writeAll("<marker id=\"arrow\" viewBox=\"0 0 6 6\" refX=\"6\" refY=\"3\" markerWidth=\"6\" markerHeight=\"6\" orient=\"auto\"><path class=\"arrow\" d=\"M0,0 L6,3 L0,6 z\"/></marker></defs>\n");
        // Wires first, under the boxes, at right angles from the right side
        // of the producer to the left side of the consumer. A wire to the
        // next column turns in the gap between them; one that skips columns
        // runs along the channel above its consumer's row (below it, for the
        // first row), past the boxes in between.
        for (l.steps, 0..) |s, si| for (s.parents.items) |pi| {
            const x1 = xs[pi] + box_w;
            const y1 = ys[pi] + box_h / 2;
            const x2 = xs[si];
            const y2 = ys[si] + box_h / 2;
            if (cs[si] == cs[pi] + 1) {
                try w.print("<path class=\"wire\" marker-end=\"url(#arrow)\" d=\"M{d:.1},{d:.1} H{d:.1} V{d:.1} H{d:.1}\"/>", .{ x1, y1, x2 - gap / 2, y2, x2 - 1 });
            } else if (cs[si] > cs[pi]) {
                const channel = if (ys[si] > margin + 1) ys[si] - vgap / 2 else ys[si] + box_h + vgap / 2;
                try w.print("<path class=\"wire\" marker-end=\"url(#arrow)\" d=\"M{d:.1},{d:.1} H{d:.1} V{d:.1} H{d:.1} V{d:.1} H{d:.1}\"/>", .{ x1, y1, x1 + gap / 2, channel, x2 - gap / 2, y2, x2 - 1 });
            } else try w.print("<path class=\"wire\" marker-end=\"url(#arrow)\" d=\"M{d:.1},{d:.1} L{d:.1},{d:.1}\"/>", .{ x1, y1, x2 - 1, y2 });
        };
        try w.writeAll("\n");
        for (l.steps, 0..) |s, si| try self.stepBox(s, si, xs[si], ys[si], box_w, box_h);
        try w.writeAll("</svg></div>\n");
        try w.writeAll("<ul class=\"legend\"><li><i class=\"st-completed\"></i>done in this launch</li><li><i class=\"st-reused\"></i>reused from an earlier launch</li>");
        try w.writeAll("<li><i class=\"st-running\"></i>running</li><li><i class=\"st-waiting\"></i>ready, waiting for resources</li><li><i class=\"st-pending\"></i>not ready, or not run</li>");
        try w.writeAll("<li><i class=\"st-failed\"></i>failed</li><li><i class=\"st-blocked\"></i>blocked by a failure</li><li><i class=\"st-cancelled\"></i>cancelled</li>");
        try w.print("<li>left edge: the {s}, as in every figure</li></ul>\n", .{self.groupLabel()});
        if (l.reused_unrecorded > 0) try w.print("<p class=\"lead\" style=\"margin-top:10px\">{d} reused {s} no run left in the records: the launch that made {s} outputs was cleaned up.</p>\n", .{ l.reused_unrecorded, if (l.reused_unrecorded == 1) "rule has" else "rules have", if (l.reused_unrecorded == 1) "its" else "their" });
        try self.endFigure();
    }

    fn stepBox(self: Page, s: model.Step, si: usize, x: f64, y: f64, bw: f64, bh: f64) !void {
        const w = self.w;
        const l = self.l;
        const active = s.count(.running) + s.count(.stopping) > 0;
        const bad = s.count(.failed) + s.count(.blocked) > 0;
        const done = s.count(.completed) + s.count(.reused);
        try w.writeAll("<g><title>");
        try escape(w, s.name);
        try w.print(": {d} of {d} done", .{ done, s.selected() });
        if (s.count(.reused) > 0) try w.print(" ({d} reused)", .{s.count(.reused)});
        if (s.count(.running) > 0) try w.print(", {d} running", .{s.count(.running)});
        if (s.count(.waiting) > 0) try w.print(", {d} waiting", .{s.count(.waiting)});
        if (s.count(.failed) > 0) try w.print(", {d} failed", .{s.count(.failed)});
        if (s.count(.blocked) > 0) try w.print(", {d} blocked", .{s.count(.blocked)});
        if (s.runs > 0) {
            try w.writeAll("; median ");
            try duration(w, s.median_s);
        }
        if (s.tool) |t| {
            try w.writeAll("; ");
            try escape(w, t);
        }
        try w.writeAll("</title>");
        try w.print("<rect class=\"box{s}\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\"/>", .{ if (bad) " bad" else if (active) " active" else "", x, y, bw, bh });
        try w.print("<rect class=\"g{d}\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"4\" height=\"{d:.1}\"/>", .{ self.slotOfStep(si), x + 0.6, y + 0.6, bh - 1.2 });
        // The name takes the width left of the count, at about 7.2 px a
        // character.
        var count_buf: [24]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ done, s.selected() }) catch "";
        const chars: usize = @intFromFloat(@max((bw - 12 - 8 - 10 - @as(f64, @floatFromInt(count_text.len)) * 6.8) / 7.2, 6));
        try w.print("<text class=\"t-name\" x=\"{d:.1}\" y=\"{d:.1}\">", .{ x + 12, y + 18 });
        try escape(w, middle(self.a, s.name, chars));
        try w.print("</text><text class=\"t-count\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"end\">{d}/{d}</text>", .{ x + bw - 8, y + 18, done, s.selected() });
        // The tool and the median run under the name.
        try w.print("<text class=\"t-sub\" x=\"{d:.1}\" y=\"{d:.1}\">", .{ x + 12, y + 34 });
        if (s.tool) |t| try escape(w, middle(self.a, t, 18));
        if (s.runs > 0) {
            if (s.tool != null) try w.writeAll(" &#183; ");
            try duration(w, s.median_s);
        }
        try w.writeAll("</text>");
        // A cell per rule while they fit, else one bar split by state.
        const left = x + 12;
        const right = x + bw - 8;
        const cy = y + 44;
        const ch: f64 = 14;
        const n = s.rules.items.len;
        const cell_gap: f64 = 2;
        const cw = (right - left - cell_gap * @as(f64, @floatFromInt(n -| 1))) / @as(f64, @floatFromInt(@max(n, 1)));
        if (cw >= 5) {
            for (s.rules.items, 0..) |ri, k| {
                const r = l.rules[ri];
                try w.print("<rect class=\"st-{s}\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\"><title>", .{ @tagName(r.state), left + @as(f64, @floatFromInt(k)) * (cw + cell_gap), cy, cw, ch });
                try escape(w, r.name);
                try w.print(": {s}", .{stateText(r.state)});
                if (r.run) |run| {
                    try w.writeAll(", ");
                    try duration(w, run.wall_s);
                }
                try w.writeAll("</title></rect>");
            }
        } else {
            var at = left;
            const order = [_]model.State{ .completed, .reused, .running, .stopping, .waiting, .failed, .blocked, .cancelled, .pending, .not_run };
            for (order) |st| {
                const k = s.count(st);
                if (k == 0) continue;
                const len = (right - left) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
                try w.print("<rect class=\"st-{s}\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\"><title>{d} {s}</title></rect>", .{ @tagName(st), at, cy, @max(len - 1, 1), ch, k, stateText(st) });
                at += len;
            }
        }
        try w.writeAll("</g>\n");
    }

    // ---- FIG. 2: CPU time ----

    fn time(self: Page) !void {
        const w = self.w;
        const l = self.l;
        try self.figure("time", "FIG. 2", "Where the CPU time went", "the latest run of every rule");
        const cpu = l.cpu();
        if (cpu.all <= 0) {
            try w.writeAll("<p class=\"muted\">No rule has completed yet.</p>");
            return self.endFigure();
        }
        try w.writeAll("<p class=\"lead\">CPU time of the latest completed run of every rule: ");
        try duration(w, cpu.all);
        if (cpu.here < cpu.all) {
            try w.writeAll(" in all, of which this launch ran ");
            try duration(w, cpu.here);
            try w.writeAll("; the rest is from earlier launches, whose outputs it reused.</p>\n");
        } else try w.writeAll(" in all.</p>\n");
        // By group, in pipeline order so the colors read left to right.
        const by = try self.a.alloc(f64, self.groups.names.len);
        @memset(by, 0);
        for (l.rules) |r| if (r.selected) if (r.run) |run| {
            by[self.groups.index(groupName(l, r.step))] += run.cpu_s;
        };
        try w.print("<div class=\"split\" role=\"img\" aria-label=\"CPU time by {s}\">", .{self.groupLabel()});
        for (self.groups.names, by) |g, v| {
            if (v <= 0) continue;
            try w.print("<i class=\"g{d}\" style=\"flex:{d:.3} 1 0\" title=\"", .{ self.groups.slot(g), v });
            try escape(w, g);
            try w.writeAll(": ");
            try duration(w, v);
            try w.writeAll(" CPU\"></i>");
        }
        try w.writeAll("</div>\n<ul class=\"legend\">");
        // The legend names what the bar shows: a group with no completed run
        // yet has no CPU time to show.
        for (self.groups.names, by) |g, v| {
            if (v <= 0) continue;
            try w.print("<li><i class=\"g{d}\"></i><b>", .{self.groups.slot(g)});
            try escape(w, g);
            try w.writeAll("</b>&nbsp; ");
            try duration(w, v);
            try w.writeAll(", ");
            try units.percent(w, v, cpu.all);
            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>\n");
        const tools = try l.totals(self.a, .tool);
        if (tools.len > 0) {
            var most: f64 = 0;
            for (tools) |t| most = @max(most, t.cpu_s);
            try w.writeAll("<div class=\"wide\" style=\"margin-top:16px\"><table><thead><tr><th>tool</th><th class=\"n\">steps</th><th class=\"n\">runs</th><th class=\"n\">wall time</th><th>CPU time</th></tr></thead><tbody>\n");
            for (tools) |t| {
                try w.writeAll("<tr><td>");
                try escape(w, t.name);
                try w.print("</td><td class=\"n\">{d}</td><td class=\"n\">{d}</td><td class=\"n\">", .{ t.steps, t.runs });
                try duration(w, t.wall_s);
                try w.print("</td><td><div class=\"hbar\"><div class=\"bar\"><i class=\"b-use\" style=\"width:{d:.2}%\"></i></div><span>", .{@max(t.cpu_s / @max(most, 0.001) * 100, 0.5)});
                try duration(w, t.cpu_s);
                try w.writeAll(", ");
                try units.percent(w, t.cpu_s, cpu.all);
                try w.writeAll("</span></div></td></tr>\n");
            }
            try w.writeAll("</tbody></table></div>\n");
        }
        try self.endFigure();
    }

    // ---- FIG. 3: samples by step ----

    fn matrix(self: Page) !void {
        const w = self.w;
        const l = self.l;
        if (l.samples.len == 0) return;
        try self.figure("samples", "FIG. 3", "Samples by step", "shade: wall time against the step's median");
        try w.writeAll("<p class=\"lead\">One cell for each sample's rule of each step, shaded by its wall time against the median of that step, so a shade means the same in every column. Hover a cell for its numbers.</p>\n");
        var whole = false;
        for (l.rules) |r| whole = whole or (r.selected and r.labels.sample == null);
        try w.writeAll("<div class=\"wide\"><table class=\"matrix\"><thead><tr><th></th>");
        for (l.steps, 0..) |s, si| {
            try w.writeAll("<th class=\"step\" title=\"");
            try escape(w, s.name);
            if (s.category) |c| {
                try w.writeAll(", ");
                try escape(w, c);
            }
            try w.print("\"><i class=\"g{d}\"></i>", .{self.slotOfStep(si)});
            try escape(w, middle(self.a, s.name, 24));
            try w.writeAll("</th>");
        }
        try w.writeAll("<th class=\"n\">CPU time</th></tr></thead><tbody>\n");
        var rows: std.ArrayList(?[]const u8) = .empty;
        for (l.samples) |n| try rows.append(self.a, n);
        if (whole) try rows.append(self.a, null);
        for (rows.items) |sample| {
            try w.writeAll("<tr><td class=\"row\">");
            if (sample) |n| try escape(w, n) else try w.writeAll("<span class=\"muted\">whole run</span>");
            try w.writeAll("</td>");
            var cpu: f64 = 0;
            for (l.steps, 0..) |s, si| {
                const ri = l.cell(si, sample) orelse {
                    try w.writeAll("<td class=\"none\"></td>");
                    continue;
                };
                const r = l.rules[ri];
                const mark: []const u8 = switch (r.state) {
                    .failed => "x",
                    .cancelled => "-",
                    .blocked => "/",
                    else => "",
                };
                if (r.run) |run| {
                    cpu += run.cpu_s;
                    const slow = l.slow(r);
                    const reused = if (run.reused_from != null) " reused" else "";
                    if (s.runs < 2) {
                        try w.print("<td class=\"cell solo{s}\" title=\"", .{reused});
                    } else try w.print("<td class=\"cell q{d}{s}{s}\" title=\"", .{ shade(run.wall_s, s.median_s), if (slow) " slow" else "", reused });
                    try self.cellTitle(r, sample, s);
                    try w.print("\">{s}</td>", .{if (slow) "!" else mark});
                } else {
                    const cls: []const u8 = switch (r.state) {
                        .failed => "failed",
                        .cancelled => "cancelled",
                        .running, .stopping => "running",
                        .waiting => "waiting",
                        else => "none",
                    };
                    try w.print("<td class=\"cell {s}\" title=\"", .{cls});
                    try self.cellTitle(r, sample, s);
                    try w.print("\">{s}</td>", .{mark});
                }
            }
            try w.writeAll("<td class=\"sum\">");
            try duration(w, cpu);
            try w.writeAll("</td></tr>\n");
        }
        try w.writeAll("</tbody></table></div>\n<ul class=\"legend\"><li>against the step's median: under 0.9x&nbsp;<span class=\"scale\"><i class=\"q1\"></i><i class=\"q2\"></i><i class=\"q3\"></i><i class=\"q4\"></i><i class=\"q5\"></i><i class=\"q6\"></i><i class=\"q7\"></i></span>2x or more</li>");
        try w.writeAll("<li><i class=\"q2\"></i>the step's only run</li><li><b>!</b>&nbsp; 1.5 times the median and 2 s longer</li><li><i style=\"background-image:repeating-linear-gradient(135deg,var(--ink) 0 1.5px,transparent 1.5px 5px)\"></i>reused from an earlier launch</li>");
        try w.writeAll("<li><b>x</b>&nbsp; failed</li><li><b>/</b>&nbsp; blocked</li><li><b>-</b>&nbsp; cancelled</li><li><i style=\"background:var(--wash)\"></i>no run</li></ul>\n");
        try self.endFigure();
    }

    fn cellTitle(self: Page, r: model.Rule, sample: ?[]const u8, s: model.Step) !void {
        const w = self.w;
        if (sample) |n| try escape(w, n) else try w.writeAll("whole run");
        try w.writeAll(" &middot; ");
        try escape(w, s.name);
        try w.print(": {s}", .{stateText(r.state)});
        const run = r.run orelse return;
        try w.writeAll(", ");
        try duration(w, run.wall_s);
        try w.print(" wall, {d:.1} s CPU", .{run.cpu_s});
        if (run.peak_mib) |p| {
            try w.writeAll(", peak ");
            try size(w, p);
        }
        if (s.median_s > 0 and s.runs > 1) try w.print(", {d:.2}x the step's median", .{run.wall_s / s.median_s});
        if (run.attempt > 1) try w.print(", attempt {d}", .{run.attempt});
        if (run.reused_from) |from| {
            try w.writeAll(", reused from launch ");
            try escape(w, from);
        }
    }

    // ---- TABLE 1: steps ----

    fn stepsTable(self: Page) !void {
        const w = self.w;
        const l = self.l;
        try self.figure("steps", "TABLE 1", "Steps", "the latest run of every rule");
        if (l.steps.len == 0) {
            try w.writeAll("<p class=\"muted\">No step.</p>");
            return self.endFigure();
        }
        try w.writeAll("<p class=\"lead\">Every step in pipeline order. The spread places each run on the step's own time scale, from 0 to its longest run, with the median as a line. Memory used is the largest process memory of a run, or its cgroup peak for rules with shared inputs or containers; the rest of the cgroup peak is page cache. The suggested request covers the memory used with a fifth to spare, as <code>workz report --suggest</code> prints it.</p>\n");
        try w.writeAll("<div class=\"wide\"><table><thead><tr><th>step</th><th class=\"n\">runs</th><th class=\"n\">median</th><th>spread of wall time</th><th class=\"n\">cores used</th><th>memory used of request</th><th class=\"n\">suggested</th></tr></thead><tbody>\n");
        for (l.steps, 0..) |s, si| {
            try w.print("<tr><td class=\"name\"><i class=\"g{d}\"></i>", .{self.slotOfStep(si)});
            try escape(w, s.name);
            var parts: usize = 0;
            for ([_]?[]const u8{ s.category, s.tool }) |label| if (label) |text| {
                try w.writeAll(if (parts == 0) "<small>" else " &middot; ");
                try escape(w, text);
                parts += 1;
            };
            if (s.samples > 0) {
                try w.writeAll(if (parts == 0) "<small>" else " &middot; ");
                try units.count(w, s.samples, "sample", "samples");
                parts += 1;
            }
            if (parts > 0) try w.writeAll("</small>");
            try w.print("</td><td class=\"n\">{d}", .{s.runs});
            if (s.reused > 0) try w.print("<small class=\"sub\">{d} reused</small>", .{s.reused});
            if (s.failed_attempts > 0) try w.print("<small class=\"sub\" style=\"color:var(--fail)\">{d} failed</small>", .{s.failed_attempts});
            try w.writeAll("</td><td class=\"n\">");
            if (s.runs > 0) try duration(w, s.median_s) else try w.writeAll("-");
            try w.writeAll("</td><td>");
            try self.strip(s);
            try w.writeAll("</td><td class=\"n\">");
            if (s.runs > 0 and s.judged() and !s.mostlyIdle()) try w.print("{d:.1} of {d:.0}", .{ s.cores, s.threads }) else try w.writeAll("-");
            try w.writeAll("</td>");
            if (s.runs == 0 or s.mostlyIdle()) {
                try w.writeAll("<td class=\"muted\">");
                try w.writeAll(if (s.mostlyIdle()) "idle: used almost none of its request" else "-");
                try w.writeAll("</td>");
            } else {
                const req = @max(s.request_mib, 1);
                const cache = @max(s.peak_mib - s.used_mib, 0);
                try w.print("<td><div class=\"hbar\"><div class=\"bar\" title=\"used {d:.0} MiB, cgroup peak {d:.0} MiB, request {d:.0} MiB\"><i class=\"b-cache\" style=\"width:{d:.2}%\"></i><i class=\"b-use\" style=\"width:{d:.2}%\"></i></div><span>", .{ s.used_mib, s.peak_mib, s.request_mib, @min((s.used_mib + cache) / req * 100, 100), @min(@max(s.used_mib / req * 100, 0.5), 100) });
                try size(w, s.used_mib);
                try w.writeAll(" of ");
                try size(w, s.request_mib);
                try w.writeAll("</span></div></td>");
            }
            try w.writeAll("<td class=\"n\">");
            switch (s.sizing.note) {
                .none, .idle => try w.writeAll("-"),
                .measured, .out_of_memory => {
                    try w.print("{d:.0} {s}, ", .{ s.sizing.threads, if (s.sizing.threads == 1) "thread" else "threads" });
                    try size(w, s.sizing.memory_mib);
                    if (s.sizing.note == .out_of_memory) try w.writeAll("<small class=\"sub\" style=\"color:var(--fail)\">out of memory: a guess above the request</small>");
                    if (s.sizing.at_thread_limit) try w.writeAll("<small class=\"sub\">kept all its threads busy: it may use more if given them</small>");
                    // A suggestion from few runs covers only the inputs measured.
                    if (s.runs < 3) try w.print("<small class=\"sub\">from {d} {s}</small>", .{ s.runs, if (s.runs == 1) "run" else "runs" });
                },
            }
            try w.writeAll("</td></tr>\n");
        }
        try w.writeAll("</tbody></table></div>\n<ul class=\"legend\"><li><i style=\"background:var(--q5);border-radius:50%\"></i>a run</li><li><i style=\"background:var(--sheet);border:2px solid var(--ink);border-radius:50%\"></i>1.5 times the median and 2 s longer</li><li><i style=\"background:var(--ink);width:2px\"></i>median</li><li><i class=\"b-use\"></i>memory used</li><li><i class=\"b-cache\"></i>page cache in the cgroup peak</li></ul>\n");
        try self.endFigure();
    }

    /// A step's runs as dots on its own wall-time scale, with the median as
    /// a line and the scale's end labelled.
    fn strip(self: Page, s: model.Step) !void {
        const w = self.w;
        const l = self.l;
        if (s.runs < 2) return w.writeAll(if (s.runs == 1) "<span class=\"muted\">one run</span>" else "<span class=\"muted\">-</span>");
        const max = @max(s.walls.items[s.walls.items.len - 1], 0.001);
        const x0: f64 = 7;
        const width: f64 = 130;
        try w.writeAll("<svg class=\"strip\" viewBox=\"0 0 192 26\" role=\"img\" aria-label=\"wall time of each run\">");
        try w.print("<line class=\"gridline\" x1=\"{d:.0}\" y1=\"13\" x2=\"{d:.0}\" y2=\"13\"/>", .{ x0, x0 + width });
        try w.print("<line class=\"med\" x1=\"{d:.1}\" y1=\"5\" x2=\"{d:.1}\" y2=\"21\"/>", .{ x0 + s.median_s / max * width, x0 + s.median_s / max * width });
        for (s.rules.items) |ri| {
            const r = l.rules[ri];
            const run = r.run orelse continue;
            try w.print("<circle cx=\"{d:.1}\" cy=\"13\" r=\"4.5\"{s}><title>", .{ x0 + run.wall_s / max * width, if (l.slow(r)) " class=\"slow\"" else "" });
            try escape(w, r.labels.sample orelse r.name);
            try w.writeAll(": ");
            try duration(w, run.wall_s);
            try w.writeAll("</title></circle>");
        }
        var buf: [32]u8 = undefined;
        var fw: std.Io.Writer = .fixed(&buf);
        try duration(&fw, max);
        try w.print("<text x=\"{d:.0}\" y=\"16\">{s}</text></svg>", .{ x0 + width + 10, fw.buffered() });
    }

    // ---- FIG. 4: timeline ----

    fn timeline(self: Page) !void {
        const w = self.w;
        const l = self.l;
        try self.figure("timeline", "FIG. 4", "Timeline", "this launch's attempts, in the order they started");
        const Bar = struct { name: []const u8, attempt: i64, start: f64, wall: f64, waited: f64, status: []const u8, slot: usize, open: bool, crit: bool };
        var bars: std.ArrayList(Bar) = .empty;
        for (l.rows) |r| if (r.started_ns > 0) {
            const crit = for (l.path) |p| {
                if (eql(u8, l.rules[p.rule].name, r.rule)) break true;
            } else false;
            try bars.append(self.a, .{ .name = r.rule, .attempt = r.attempt, .start = l.at(r.started_ns), .wall = r.wall_s, .waited = r.waited_s, .status = r.status, .slot = self.slotOfRule(r.rule), .open = false, .crit = crit });
        };
        // Attempts still running have no record yet; they run up to now.
        for (l.rules) |r| if (r.selected and r.state.active() and r.started_ns > 0) {
            const start = l.at(r.started_ns);
            try bars.append(self.a, .{ .name = r.name, .attempt = r.attempts, .start = start, .wall = @max(l.elapsed_s - start, 0.1), .waited = 0, .status = "running", .slot = self.slotOfRule(r.name), .open = true, .crit = false });
        };
        if (bars.items.len == 0) {
            try w.writeAll("<p class=\"muted\">No attempt started in this launch.</p>");
            return self.endFigure();
        }
        std.mem.sort(Bar, bars.items, {}, struct {
            fn lt(_: void, x: Bar, y: Bar) bool {
                return x.start < y.start;
            }
        }.lt);
        var span = @max(l.elapsed_s, 0.001);
        for (bars.items) |b| span = @max(span, b.start + b.wall);
        const n = bars.items.len;
        const row_h: f64 = if (n <= 60) 18 else if (n <= 250) 10 else if (n <= 400) 6 else 3;
        const labels = row_h >= 10;
        const width: f64 = 1180;
        const label_w: f64 = if (labels) 210 else 16;
        const x0 = label_w;
        const plot_w = width - label_w - 14;
        const top: f64 = 46;
        const height = top + @as(f64, @floatFromInt(n)) * row_h + 8;
        try w.print("<svg viewBox=\"0 0 {d:.0} {d:.0}\" role=\"img\" aria-label=\"Timeline of {d} attempts\">\n", .{ width, height, n });
        try w.writeAll("<defs><marker id=\"dim\" viewBox=\"0 0 8 8\" refX=\"7\" refY=\"4\" markerWidth=\"8\" markerHeight=\"8\" orient=\"auto-start-reverse\"><path class=\"arrow\" d=\"M0,1 L8,4 L0,7 z\"/></marker></defs>");
        // The elapsed time as a dimension line over the plot.
        var buf: [32]u8 = undefined;
        var fw: std.Io.Writer = .fixed(&buf);
        try duration(&fw, l.elapsed_s);
        const end_x = x0 + @min(l.elapsed_s / span, 1) * plot_w;
        const mid = (x0 + end_x) / 2;
        try w.print("<line class=\"dim\" x1=\"{d:.1}\" y1=\"12\" x2=\"{d:.1}\" y2=\"12\" marker-start=\"url(#dim)\" marker-end=\"url(#dim)\"/>", .{ x0 + 1, end_x - 1 });
        try w.print("<line class=\"dim\" x1=\"{d:.1}\" y1=\"4\" x2=\"{d:.1}\" y2=\"20\"/><line class=\"dim\" x1=\"{d:.1}\" y1=\"4\" x2=\"{d:.1}\" y2=\"20\"/>", .{ x0, x0, end_x, end_x });
        try w.print("<rect x=\"{d:.1}\" y=\"3\" width=\"112\" height=\"18\" style=\"fill:var(--sheet)\"/><text class=\"dimtext\" x=\"{d:.1}\" y=\"16\" text-anchor=\"middle\">{s}{s}</text>", .{ mid - 56, mid, if (l.finished) "ELAPSED " else "SO FAR ", fw.buffered() });
        if (labels) for (0..n) |i| if (i % 2 == 1) {
            try w.print("<rect class=\"zebra\" x=\"0\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.1}\"/>", .{ top + @as(f64, @floatFromInt(i)) * row_h, width, row_h });
        };
        const step = tickStep(span, 10);
        var tick: f64 = 0;
        while (tick <= span + step * 0.001) : (tick += step) {
            const x = x0 + tick / span * plot_w;
            try w.print("<line class=\"gridline\" x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\"/><text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\">{s}</text>", .{ x, top - 6, x, height - 6, x, top - 10, tickLabel(&buf, tick, step) });
        }
        try w.writeAll("\n");
        for (bars.items, 0..) |b, i| {
            const y = top + @as(f64, @floatFromInt(i)) * row_h;
            const wait_from = x0 + @max(b.start - b.waited, 0) / span * plot_w;
            const run_from = x0 + b.start / span * plot_w;
            const run_to = x0 + @min(b.start + b.wall, span) / span * plot_w;
            if (labels) {
                const label = if (b.attempt > 1) try std.fmt.allocPrint(self.a, "{s} #{d}", .{ middle(self.a, b.name, 24), b.attempt }) else middle(self.a, b.name, 28);
                try w.print("<text x=\"{d:.0}\" y=\"{d:.1}\" text-anchor=\"end\"{s}{s}>", .{ label_w - 10, y + row_h * 0.7, if (row_h < 12) " font-size=\"9\"" else "", if (b.crit) " style=\"fill:var(--ink);font-weight:600\"" else "" });
                try escape(w, label);
                try w.writeAll("</text>");
            }
            if (run_from - wait_from >= 0.5) try w.print("<rect class=\"g0\" opacity=\".4\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\"/>", .{ wait_from, y + row_h * 0.42, run_from - wait_from, row_h * 0.16 });
            const pad: f64 = if (row_h >= 12) 3 else if (row_h >= 6) 1 else 0;
            var class_buf: [24]u8 = undefined;
            const class = if (b.open) "st-running" else if (eql(u8, b.status, "completed")) std.fmt.bufPrint(&class_buf, "g{d}", .{b.slot}) catch "g0" else if (eql(u8, b.status, "cancelled")) "st-cancelled" else "st-failed";
            try w.print("<rect class=\"{s}\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\"{s}><title>", .{ class, run_from, y + pad, @max(run_to - run_from, 1), row_h - 2 * pad, if (b.crit) " style=\"stroke:var(--ink);stroke-width:2\"" else "" });
            try escape(w, b.name);
            try w.print(", attempt {d}: {s}; started at ", .{ b.attempt, b.status });
            try duration(w, b.start);
            try w.writeAll(", waited ");
            try duration(w, b.waited);
            try w.writeAll(if (b.open) ", running for " else ", ran ");
            try duration(w, b.wall);
            try w.writeAll("</title></rect>\n");
        }
        // The legend names only the groups this launch's attempts belong to.
        try w.writeAll("</svg>\n<ul class=\"legend\">");
        var other: usize = 0;
        const present = try self.a.alloc(bool, self.groups.names.len);
        @memset(present, false);
        for (bars.items) |b| if (self.stepOfRule(b.name)) |si| {
            present[self.groups.index(groupName(l, si))] = true;
        };
        for (self.groups.names, 0..) |g, i| {
            if (!present[i]) continue;
            if (self.groups.names.len > 8 and i >= 7) {
                other += 1;
                continue;
            }
            try w.print("<li><i class=\"g{d}\"></i>", .{self.groups.slot(g)});
            try escape(w, g);
            try w.writeAll("</li>");
        }
        if (other > 0) try w.print("<li><i class=\"g0\"></i>{d} other {s}</li>", .{ other, if (self.l.by_category) "categories" else "steps" });
        try w.writeAll("<li><i class=\"st-running\"></i>running</li><li><i class=\"st-failed\"></i>failed</li><li><i class=\"st-cancelled\"></i>cancelled</li><li><i class=\"g0\" style=\"opacity:.4;height:4px\"></i>waiting for resources</li><li><i style=\"outline:1.5px solid var(--ink);outline-offset:-1.5px\"></i>critical path</li></ul>\n");
        try self.endFigure();
    }

    // ---- FIG. 5: the budget ----

    fn budget(self: Page) !void {
        const w = self.w;
        try self.figure("budget", "FIG. 5", "Use of the budget", "run samples every 5 s");
        if (self.l.usage().len < 2) {
            try w.writeAll("<p class=\"muted\">Fewer than two run samples: the launch was too short to chart.</p>");
            return self.endFigure();
        }
        try w.writeAll("<div style=\"display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:26px\">\n");
        try self.area(false);
        try self.area(true);
        try w.writeAll("</div>\n<ul class=\"legend\"><li><i style=\"background:var(--q2)\"></i>reserved by running rules</li><li><i class=\"g1\"></i>in use: CPU cores; memory with page cache</li><li><i style=\"border-top:1.5px dashed var(--ink2);height:0;margin-top:5px\"></i>the budget</li></ul>\n");
        try self.endFigure();
    }

    fn area(self: Page, memory: bool) !void {
        const w = self.w;
        const l = self.l;
        const samples = l.usage();
        const width: f64 = 560;
        const height: f64 = 220;
        const left: f64 = 70;
        const right: f64 = 12;
        const top: f64 = 14;
        const bottom: f64 = 28;
        const pw = width - left - right;
        const ph = height - top - bottom;
        const span = @max(l.elapsed_s, 0.001);
        const budget_v = if (memory) l.max_memory_mib else l.max_threads;
        var most = budget_v;
        for (samples) |s| most = @max(most, if (memory) @max(s.memory_reserved_mib, if (s.memory_current) |m| @as(f64, @floatFromInt(m)) / 1048576.0 else 0) else @max(s.threads_reserved, s.cpu_cores orelse 0));
        most = @max(most, 1);
        try w.print("<div><div class=\"k\">{s}</div><svg viewBox=\"0 0 {d:.0} {d:.0}\" role=\"img\" aria-label=\"{s}\">\n", .{ if (memory) "memory reserved and in use" else "threads reserved, CPU cores in use", width, height, if (memory) "Memory reserved and in use" else "Threads reserved and CPU cores in use" });
        var buf: [32]u8 = undefined;
        for ([_]f64{ 0, 0.5, 1 }) |f| {
            const y = top + ph - f * ph;
            try w.print("<line class=\"gridline\" x1=\"{d:.0}\" y1=\"{d:.1}\" x2=\"{d:.0}\" y2=\"{d:.1}\"/><text x=\"{d:.0}\" y=\"{d:.1}\" text-anchor=\"end\">", .{ left, y, width - right, y, left - 8, y + 4 });
            if (f == 0) {
                try w.writeAll(if (memory) "0 MiB" else "0 cores");
            } else if (memory) {
                var fw: std.Io.Writer = .fixed(&buf);
                try size(&fw, most * f);
                try w.writeAll(fw.buffered());
            } else try w.print("{d:.0} cores", .{most * f});
            try w.writeAll("</text>");
        }
        const step = tickStep(span, 6);
        var tick: f64 = 0;
        while (tick <= span + step * 0.001) : (tick += step) {
            try w.print("<text x=\"{d:.1}\" y=\"{d:.0}\" text-anchor=\"middle\">{s}</text>", .{ left + tick / span * pw, height - 8, tickLabel(&buf, tick, step) });
        }
        try w.print("<line class=\"axis\" x1=\"{d:.0}\" y1=\"{d:.1}\" x2=\"{d:.0}\" y2=\"{d:.1}\"/>\n", .{ left, top + ph, width - right, top + ph });
        for ([_]bool{ false, true }) |used| {
            try w.print("<polygon style=\"fill:var({s});opacity:{s}\" points=\"{d:.1},{d:.1} ", .{ if (used) "--c1" else "--q2", if (used) ".22" else ".85", left, top + ph });
            for (samples) |s| {
                const v: f64 = if (memory) (if (used) (if (s.memory_current) |m| @as(f64, @floatFromInt(m)) / 1048576.0 else continue) else s.memory_reserved_mib) else (if (used) s.cpu_cores orelse continue else s.threads_reserved);
                try w.print("{d:.1},{d:.1} ", .{ left + @min(l.at(s.ns) / span, 1) * pw, top + ph - @min(v / most, 1) * ph });
            }
            try w.print("{d:.1},{d:.1}\"/>\n", .{ left + pw, top + ph });
        }
        // The in-use line on top.
        try w.writeAll("<polyline style=\"fill:none;stroke:var(--ink);stroke-width:2;stroke-linejoin:round\" points=\"");
        for (samples) |s| {
            const v: f64 = if (memory) (if (s.memory_current) |m| @as(f64, @floatFromInt(m)) / 1048576.0 else continue) else s.cpu_cores orelse continue;
            try w.print("{d:.1},{d:.1} ", .{ left + @min(l.at(s.ns) / span, 1) * pw, top + ph - @min(v / most, 1) * ph });
        }
        try w.writeAll("\"/>\n");
        if (budget_v > 0) {
            const y = top + ph - @min(budget_v / most, 1) * ph;
            try w.print("<line style=\"stroke:var(--ink2);stroke-width:1.5;stroke-dasharray:5 4\" x1=\"{d:.0}\" y1=\"{d:.1}\" x2=\"{d:.0}\" y2=\"{d:.1}\"/>\n", .{ left, y, width - right, y });
        }
        try w.writeAll("</svg></div>\n");
    }

    // ---- FIG. 6: what limited the launch ----

    fn limits(self: Page) !void {
        const w = self.w;
        const l = self.l;
        try self.figure("limits", "FIG. 6", "What limited the launch", "this launch only");
        if (l.bounds.len == 0) {
            try w.writeAll("<p class=\"muted\">No attempt ran in this launch.</p>");
            return self.endFigure();
        }
        const span = @max(l.elapsed_s, 0.001);
        // The bounds: the launch could not take less than any of them, so
        // the largest is what limited it.
        try w.writeAll("<p class=\"lead\">");
        var verdict: std.Io.Writer.Allocating = .init(self.a);
        try report.writeVerdict(&verdict.writer, l);
        const text = verdict.written();
        if (text.len > 0) {
            try w.writeAll(&.{std.ascii.toUpper(text[0])});
            try escape(w, text[1..]);
            try w.writeAll(". ");
        }
        try w.writeAll("The launch could not take less than any bound below; a full bar is its elapsed time.</p>\n");
        try w.writeAll("<div class=\"wide\"><table><thead><tr><th>bound</th><th class=\"n\">at least</th><th>use</th><th>against the elapsed time</th></tr></thead><tbody>\n");
        for (l.bounds, 0..) |b, i| {
            try w.print("<tr><td class=\"name\"{s}>", .{if (l.binding == i) " style=\"font-weight:700\"" else ""});
            try report.boundName(w, b);
            try w.writeAll("</td><td class=\"n\">");
            try duration(w, b.seconds);
            try w.writeAll("</td><td>");
            try report.boundUse(w, l, b);
            try w.print("</td><td><div class=\"bar\"><i class=\"{s}\" style=\"width:{d:.2}%\"></i></div></td></tr>\n", .{ if (l.binding == i) "b-use" else "b-cache", @min(b.seconds / span, 1) * 100 });
        }
        try w.writeAll("</tbody></table></div>\n");

        if (l.path.len > 0) {
            try w.writeAll("<div class=\"k\" style=\"margin-top:18px\">critical path</div><p class=\"lead\">The longest chain of work in this launch: ");
            try duration(w, l.path_ran_s);
            try w.writeAll(" of work. Once ready, its rules waited ");
            try duration(w, l.path_waited_s);
            try w.writeAll(", and they were held ");
            try duration(w, l.path_held_s);
            try w.writeAll(" for producers off the path");
            if (l.path_between_s >= 0.05) {
                try w.writeAll("; ");
                try duration(w, l.path_between_s);
                try w.writeAll(" passed between attempts");
            }
            if (l.path_after_s >= 0.05) {
                try w.writeAll("; the launch ended ");
                try duration(w, l.path_after_s);
                try w.writeAll(" after the path did");
            }
            try w.writeAll(". Together these make up the elapsed time.</p>\n<div class=\"wide\"><table><thead><tr><th>rule</th><th>step</th><th class=\"n\">started</th><th class=\"n\">held</th><th class=\"n\">waited</th><th class=\"n\">ran</th><th>over the launch</th></tr></thead><tbody>\n");
            for (l.path) |p| {
                const r = l.rules[p.rule];
                try w.print("<tr><td class=\"name\"><i class=\"g{d}\"></i>", .{self.slotOfStep(r.step)});
                try escape(w, r.name);
                if (p.earlier > 0) try w.print("<small>over {d} attempts</small>", .{p.earlier + 1});
                try w.writeAll("</td><td>");
                try escape(w, r.labels.step);
                inline for (.{ p.start_s, p.held_s, p.waited_s, p.ran_s }) |v| {
                    try w.writeAll("</td><td class=\"n\">");
                    try duration(w, v);
                }
                const ready = @max(p.start_s - p.waited_s, 0);
                const held_from = @max(ready - p.held_s, 0) / span * 100;
                const wait_from = ready / span * 100;
                const at = p.start_s / span * 100;
                // With retries the run spans its attempts and the time between them.
                const run_w = @max((p.end_s - p.start_s) / span * 100, 0.5);
                try w.print("</td><td><div class=\"bar\" style=\"border-color:var(--hair)\"><i class=\"b-held\" style=\"left:{d:.2}%;width:{d:.2}%\"></i><i class=\"b-wait\" style=\"left:{d:.2}%;width:{d:.2}%\"></i><i class=\"g{d}\" style=\"left:{d:.2}%;width:{d:.2}%\"></i></div></td></tr>\n", .{ held_from, wait_from - held_from, wait_from, at - wait_from, self.slotOfStep(r.step), at, run_w });
            }
            if (l.path_after_s >= 0.05) {
                const last = l.path[l.path.len - 1].end_s;
                try w.writeAll("<tr><td class=\"name muted\">after the path</td><td></td><td class=\"n\">");
                try duration(w, last);
                try w.writeAll("</td><td></td><td></td><td class=\"n\">");
                try duration(w, l.path_after_s);
                try w.print("</td><td><div class=\"bar\" style=\"border-color:var(--hair)\"><i class=\"b-cache\" style=\"left:{d:.2}%;width:{d:.2}%\"></i></div></td></tr>\n", .{ last / span * 100, l.path_after_s / span * 100 });
            }
            // The running swatch in the first rule's color, as its bar has.
            try w.print("</tbody></table></div>\n<ul class=\"legend\"><li><i class=\"b-held\"></i>held for producers off the path</li><li><i class=\"b-wait\"></i>ready, waiting for resources</li><li><i class=\"g{d}\"></i>running, in the color of its category</li></ul>\n", .{self.slotOfStep(l.rules[l.path[0].rule].step)});
        }
        try w.writeAll("<div class=\"k\" style=\"margin-top:18px\">waiting for resources</div>");
        var most: f64 = 0;
        for (l.waits.values()) |v| most = @max(most, v);
        if (!l.waits_recorded or most < 0.05) {
            try w.writeAll(if (!l.waits_recorded) "<p class=\"muted\">This launch's engine did not record why rules waited.</p>\n" else "<p class=\"muted\">No rule waited for resources once it was ready.</p>\n");
        } else {
            try w.writeAll("<p class=\"lead\">How many ready rules waited for each resource, on average over the launch, and the seconds they waited added up.</p>\n<div class=\"wide\"><table><thead><tr><th>waited for</th><th class=\"n\">rules waiting</th><th>rule-seconds</th></tr></thead><tbody>\n");
            for (l.waits.keys(), l.waits.values()) |k, v| {
                if (v < 0.05) continue;
                try w.writeAll("<tr><td>");
                try escape(w, k);
                const avg = v / span;
                if (avg < 0.05) try w.writeAll("</td><td class=\"n\">&lt;0.1") else try w.print("</td><td class=\"n\">{d:.1}", .{avg});
                try w.print("</td><td><div class=\"hbar\"><div class=\"bar\"><i class=\"b-wait\" style=\"width:{d:.2}%\"></i></div><span>", .{v / @max(most, 0.001) * 100});
                try duration(w, v);
                try w.writeAll("</span></div></td></tr>\n");
            }
            try w.writeAll("</tbody></table></div>\n");
        }
        for (l.groups) |g| {
            try w.writeAll("<p class=\"lead\" style=\"margin-top:10px\">Resource group <b>");
            try escape(w, g.name);
            try w.writeAll("</b>: ");
            try duration(w, g.seconds);
            try w.writeAll(" of waiting. ");
            if (g.fit) |fit| {
                if (g.samples < 3) {
                    try w.print("Only {d} run {s} were taken while its rules waited, too few to judge.", .{ g.samples, if (g.samples == 1) "sample" else "samples" });
                } else if (fit >= 0.25) {
                    try w.print("In {d:.0}% of the {d} samples taken while a rule waited for it, the free threads and memory would have fitted a waiting rule: a higher <code>max</code> would have started it earlier.", .{ fit * 100, g.samples });
                } else try w.print("The budget was full in {d:.0}% of the {d} samples taken while its rules waited: a higher <code>max</code> would not help much.", .{ (1 - fit) * 100, g.samples });
            } else try w.writeAll("No run samples were taken while its rules waited.");
            try w.writeAll("</p>\n");
        }
        try self.endFigure();
    }

    // ---- TABLE 2: failures ----

    fn failures(self: Page) !void {
        const w = self.w;
        const l = self.l;
        try w.print("<section class=\"fig\" id=\"failures\"><div class=\"fig-h\"><span class=\"no\">TABLE 2</span><h2>Failures ({d})</h2>", .{failedCount(l)});
        try w.writeAll("<span class=\"note\">attempts that did not complete, with the end of their standard error</span></div><div class=\"fig-b\">\n");
        var shown: usize = 0;
        for (l.rows) |r| {
            if (r.completed()) continue;
            const recovered = if (l.ruleOf(r.rule)) |x| x.run != null and x.run.?.reused_from == null else false;
            const failed = !eql(u8, r.status, "cancelled");
            try w.print("<details class=\"failure{s}\"{s}><summary><span class=\"mono\">", .{ if (recovered) " retried" else "", if (shown < 3 and failed and !recovered) " open" else "" });
            shown += 1;
            try escape(w, r.rule);
            try w.print("</span> attempt {d} &middot; <b>", .{r.attempt});
            try escape(w, r.status);
            try w.writeAll("</b>");
            if (r.reason.len > 0 and !eql(u8, r.reason, r.status)) {
                try w.writeAll(": <span class=\"why\">");
                try escape(w, r.reason);
                try w.writeAll("</span>");
            }
            if (recovered) try w.writeAll(" <span class=\"muted\">&middot; a later attempt completed</span>");
            try w.writeAll("</summary><pre>");
            const tail = sys.readTail(l.gpa, try std.fs.path.join(self.a, &.{ r.dir, "stderr.log" }), 8192) catch null;
            if (tail) |t| {
                defer l.gpa.free(t);
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
        if (shown == 0) try w.writeAll(if (l.rows.len == 0) "<p class=\"muted\">No attempt ran in this launch.</p>\n" else "<p class=\"muted\">Every attempt of this launch completed.</p>\n");
        var blocked: usize = 0;
        for (l.rules) |r| blocked += @intFromBool(r.selected and r.state == .blocked);
        if (blocked > 0) try w.print("<p class=\"lead\">{d} {s} did not start because a producer failed.</p>\n", .{ blocked, if (blocked == 1) "rule was blocked: it" else "rules were blocked: they" });
        try self.endFigure();
    }

    // ---- TABLE 3: attempts ----

    fn attemptsTable(self: Page) !void {
        const w = self.w;
        const l = self.l;
        try w.print("<section class=\"fig\" id=\"attempts\"><div class=\"fig-h\"><span class=\"no\">TABLE 3</span><h2>Attempts ({d})</h2><span class=\"note\">this launch</span></div><div class=\"fig-b\">\n", .{l.rows.len});
        if (l.rows.len == 0) {
            try w.writeAll("<p class=\"muted\">No attempt ran in this launch.</p>");
            return self.endFigure();
        }
        const samples = l.samples.len > 0;
        try w.print("<div class=\"scroll\"><table><thead><tr><th>rule</th><th>step</th>{s}<th class=\"n\">#</th><th>status</th><th class=\"n\">started</th><th class=\"n\">waited</th><th class=\"n\">ran</th><th class=\"n\">CPU</th><th class=\"n\">threads</th><th class=\"n\">request</th><th class=\"n\">peak</th><th>waited for</th></tr></thead><tbody>\n", .{if (samples) "<th>sample</th>" else ""});
        for (l.rows) |r| {
            try w.print("<tr><td class=\"name\"><i class=\"g{d}\"></i>", .{self.slotOfRule(r.rule)});
            try escape(w, r.rule);
            try w.writeAll("</td><td>");
            try escape(w, r.step);
            if (samples) {
                try w.writeAll("</td><td>");
                if (r.sample) |s| try escape(w, s) else try w.writeAll("<span class=\"muted\">-</span>");
            }
            try w.print("</td><td class=\"n\">{d}</td><td>", .{r.attempt});
            try escape(w, r.status);
            try w.writeAll("</td><td class=\"n\">");
            if (r.started_ns > 0) try duration(w, l.at(r.started_ns)) else try w.writeAll("-");
            try w.writeAll("</td><td class=\"n\">");
            try duration(w, r.waited_s);
            try w.writeAll("</td><td class=\"n\">");
            try duration(w, r.wall_s);
            try w.print("</td><td class=\"n\">{d:.1} s</td><td class=\"n\">{d:.0}</td><td class=\"n\">", .{ r.cpu_s, r.threads });
            try size(w, r.request_mib);
            try w.writeAll("</td><td class=\"n\">");
            if (r.peak_mib) |p| try size(w, p) else try w.writeAll("-");
            try w.writeAll("</td><td>");
            try escape(w, r.wait_reason);
            try w.writeAll("</td></tr>\n");
        }
        try w.writeAll("</tbody></table></div>\n");
        try self.endFigure();
    }
};

fn failedCount(l: *const model.Launch) usize {
    var n: usize = 0;
    for (l.rows) |r| n += @intFromBool(!r.completed());
    return n;
}

fn stateText(s: model.State) []const u8 {
    return switch (s) {
        .pending => "not ready yet",
        .waiting => "waiting for resources",
        .running => "running",
        .stopping => "stopping",
        .completed => "completed",
        .reused => "reused",
        .failed => "failed",
        .blocked => "blocked by a failed producer",
        .cancelled => "cancelled",
        .not_run => "not run",
    };
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
