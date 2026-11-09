//! The run log: one row of a table per event, on standard error and in each
//! launch's `launch.log`. A row is the local time, the rules done, a status
//! tag, the rule's tool, step and sample in columns as wide as the selected
//! rules need (`names.zig`), its time, memory and cores, and a note; quoted
//! output and hints that belong to a row follow it at the name column. A
//! terminal leaves out the `START` rows, adds color, fits every line to the
//! window and keeps a footer of the steps below the rows; off a terminal a
//! heartbeat row carries the same progress every few minutes. `launch.log`
//! keeps every row whole and without color. A fixed few marks are Unicode,
//! with ASCII stand-ins outside a UTF-8 locale.
//!
//! Lines are kept per sink and written once per engine pass, at most a tenth
//! of a second after they were made; the footer is drawn from counts the
//! engine keeps, so neither depends on the number of rules.
const std = @import("std");
const sys = @import("sys.zig");
const units = @import("units.zig");
const names = @import("names.zig");
const clock = @import("clock.zig");
const schedule = @import("schedule.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Marks = struct {
    ok: []const u8,
    fail: []const u8,
    none: []const u8,
    quote: []const u8,
    full: []const u8,
    empty: []const u8,
    more: []const u8,
};

pub const unicode: Marks = .{ .ok = "✓", .fail = "✗", .none = "·", .quote = "│", .full = "━", .empty = "─", .more = "…" };
pub const ascii: Marks = .{ .ok = "+", .fail = "x", .none = ".", .quote = "|", .full = "#", .empty = "-", .more = "~" };

pub fn marksFor(env: *const std.process.Environ.Map) *const Marks {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |key| if (env.get(key)) |v| if (v.len > 0)
        return if (utf8Locale(v)) &unicode else &ascii;
    return &ascii;
}

pub fn utf8Locale(locale: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = @min(locale.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], locale[0..n]);
    return std.mem.indexOf(u8, lower, "utf-8") != null or std.mem.indexOf(u8, lower, "utf8") != null;
}

/// What a row of the run log reports, shown as its tag. The first six are
/// a rule's events; shared inputs, control commands and the progress
/// heartbeat are `INFO`, and problems that do not stop the launch `WARN`.
pub const Word = enum {
    started,
    completed,
    retrying,
    failed,
    blocked,
    cancelled,
    shared,
    control,
    warning,
    progress,

    pub fn tag(w: Word) []const u8 {
        return switch (w) {
            .started => "START",
            .completed => "DONE",
            .retrying => "RETRY",
            .failed => "FAIL",
            .blocked => "BLOCK",
            .cancelled => "STOP",
            .shared, .control, .progress => "INFO",
            .warning => "WARN",
        };
    }

    pub fn tint(w: Word) []const u8 {
        return switch (w) {
            .started, .progress => "\x1b[2m",
            .completed => "\x1b[32m",
            .retrying => "\x1b[33m",
            .failed => "\x1b[31;1m",
            .blocked => "\x1b[31m",
            .cancelled => "\x1b[35m",
            .shared, .control => "\x1b[36m",
            .warning => "\x1b[33;1m",
        };
    }
};

/// The width of the labels of the header and the summary.
pub const label_width = 11;
pub const status_width = 6;
const time_width = 8;
pub const gap = "  ";
pub const took_width = 7;

pub const Table = struct {
    total: usize = 0,
    done: usize = 4,
    step: usize = 4,
    sample: usize = 0,
    tool: usize = 0,
    memory: usize = 7,
    cores: usize = 3,
    threads: usize = 1,
    figures: bool = true,

    pub fn of(total: usize, widths: names.Widths, requests: []const u64, max_threads: u32) Table {
        var t: Table = .{ .total = total };
        t.done = @max(5, 2 * digits(total) + 1);
        t.step = @max(4, widths.step);
        t.sample = if (widths.sample > 0) @max(6, widths.sample) else 0;
        t.tool = if (widths.tool > 0) @max(4, widths.tool) else 0;
        // `units.size` writes 8 columns for 1000 to 1023 MiB and for 10.0
        // to 99.9 GiB, 7 below; a rule's peak stays within its request.
        for (requests) |mib| if (mib >= 1000) {
            t.memory = 8;
        };
        t.threads = digits(max_threads);
        t.cores = digits(max_threads) + 2;
        return t;
    }

    /// The widths for a launch without isolation, where nothing holds a
    /// rule's memory or cores to its request.
    pub fn unbounded(t: Table) Table {
        var u = t;
        u.memory = 8;
        u.cores = @max(u.cores, 5);
        return u;
    }

    /// The table narrowed to fit a terminal of `cols` columns: the name
    /// columns give up their width, the widest first, down to a minimum.
    pub fn fitted(t: Table, cols: usize) Table {
        var f = t;
        while (f.width() + 1 > cols) {
            const widest = @max(f.step, @max(f.sample, f.tool));
            if (widest <= 8) break;
            if (f.step == widest) f.step -= 1 else if (f.sample == widest) f.sample -= 1 else f.tool -= 1;
        }
        return f;
    }

    pub fn memoryColumn(t: Table) usize {
        return 2 * t.memory + 3;
    }

    pub fn cpuColumn(t: Table) usize {
        return t.cores + 3 + t.threads;
    }

    /// Where the status tag and an event's sentence start.
    pub fn statusColumn(t: Table) usize {
        return time_width + gap.len + t.done + gap.len;
    }

    /// Where the rule's names start, and its quoted output and hints.
    pub fn nameColumn(t: Table) usize {
        return t.statusColumn() + status_width + gap.len;
    }

    pub fn width(t: Table) usize {
        var c = t.nameColumn() + t.step + gap.len;
        if (t.tool > 0) c += t.tool + gap.len;
        if (t.sample > 0) c += t.sample + gap.len;
        c += took_width + gap.len;
        if (t.figures) c += t.memoryColumn() + gap.len + t.cpuColumn() + gap.len;
        return c;
    }
};

fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

pub const Style = struct {
    color: bool = false,
    marks: *const Marks = &ascii,
    table: Table = .{},
    cols: usize = 0,
    /// The terminal's height, which bounds the footer; 0 off a terminal.
    rows: usize = 0,

    pub fn blockColumn(s: Style) usize {
        return s.table.nameColumn();
    }

    pub fn on(s: Style, code: []const u8) []const u8 {
        return if (s.color) code else "";
    }

    pub fn off(s: Style) []const u8 {
        return if (s.color) "\x1b[0m" else "";
    }
};

pub fn timeText(buf: *[8]u8, c: clock.Civil) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ c.hour, c.minute, c.second }) catch unreachable;
}

pub fn pad(w: *Writer, text: []const u8, width: usize) !void {
    try w.writeAll(text);
    try w.splatByteAll(' ', width -| names.columns(text));
}

/// Writes `text` in a column of `width`, cut with the `more` mark when it
/// is longer, so the columns after it stay in place.
fn fit(w: *Writer, s: Style, text: []const u8, width: usize) !void {
    const n = names.columns(text);
    if (n <= width) return pad(w, text, width);
    if (width == 0) return;
    const head = cut(text, width - 1);
    try w.print("{s}{s}", .{ head, s.marks.more });
    try w.splatByteAll(' ', width - 1 - names.columns(head));
}

/// The longest start of `text` that takes at most `cols` columns.
pub fn cut(text: []const u8, cols: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = names.codepoint(text, i);
        n += names.width(c.value);
        if (n > cols) return text[0..i];
        i += c.len;
    }
    return text;
}

pub const Who = struct {
    step: []const u8 = "",
    sample: []const u8 = "",
    tool: []const u8 = "",
};

pub const Figures = struct {
    took_s: ?f64 = null,
    used_mib: ?f64 = null,
    request_mib: ?u64 = null,
    cores: ?f64 = null,
    threads: ?u32 = null,
};

/// One row of the run log.
pub fn line(w: *Writer, s: Style, time: []const u8, done: usize, word: Word, who: Who, f: Figures, note: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var b: Writer = .fixed(&buf);
    row(&b, s, time, done, word, who, f, note) catch {
        try row(w, s, time, done, word, who, f, note);
        return w.writeAll("\n");
    };
    const text = std.mem.trimEnd(u8, b.buffered(), " ");
    if (s.cols > 1 and visible(text) > s.cols - 1) {
        try clipped(w, s, text, s.cols - 2);
        try w.print("{s}\n", .{s.marks.more});
    } else try w.print("{s}\n", .{text});
}

/// Writes each line of `text`, cut with the `more` mark where it is wider
/// than the terminal.
fn fitLines(w: *Writer, s: Style, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) try w.writeAll("\n");
        first = false;
        if (s.cols > 1 and visible(l) > s.cols - 1) {
            try clipped(w, s, l, s.cols - 2);
            try w.writeAll(s.marks.more);
        } else try w.writeAll(l);
    }
}

/// The columns `text` takes on a terminal, without its escape sequences.
pub fn visible(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i = (std.mem.indexOfScalarPos(u8, text, i, 'm') orelse text.len - 1) + 1;
            continue;
        }
        const c = names.codepoint(text, i);
        n += names.width(c.value);
        i += c.len;
    }
    return n;
}

fn lead(w: *Writer, s: Style, time: []const u8, done: usize) !void {
    var nb: [32]u8 = undefined;
    try w.print("{s}{s}{s}{s}", .{ s.on("\x1b[2m"), time, gap, s.off() });
    try right(w, std.fmt.bufPrint(&nb, "{d}/{d}", .{ done, s.table.total }) catch "", s.table.done);
    try w.writeAll(gap);
}

pub fn right(w: *Writer, text: []const u8, width: usize) !void {
    try w.splatByteAll(' ', width -| names.columns(text));
    try w.writeAll(text);
}

fn row(w: *Writer, s: Style, time: []const u8, done: usize, word: Word, who: Who, f: Figures, note: []const u8) !void {
    try lead(w, s, time, done);
    try w.writeAll(s.on(word.tint()));
    try pad(w, word.tag(), status_width);
    try w.print("{s}{s}", .{ s.off(), gap });
    try whoCells(w, s, who);
    try figureCells(w, s, f);
    try w.writeAll(note);
}

/// The columns that name a rule: its tool, step and sample, each followed
/// by the gap. `watch` writes its rows with them too.
pub fn whoCells(w: *Writer, s: Style, who: Who) !void {
    const t = s.table;
    if (t.tool > 0) {
        try w.writeAll(s.on("\x1b[2m"));
        try fit(w, s, who.tool, t.tool);
        try w.writeAll(s.off());
        try w.writeAll(gap);
    }
    try fit(w, s, who.step, t.step);
    try w.writeAll(gap);
    if (t.sample > 0) {
        try fit(w, s, who.sample, t.sample);
        try w.writeAll(gap);
    }
}

/// The time, memory and CPU columns, each followed by the gap; memory and
/// CPU only when the table keeps its figures.
pub fn figureCells(w: *Writer, s: Style, f: Figures) !void {
    const t = s.table;
    var tb: [32]u8 = undefined;
    var tw: Writer = .fixed(&tb);
    if (f.took_s) |sec| units.duration(&tw, sec) catch {};
    try right(w, tw.buffered(), took_width);
    try w.writeAll(gap);
    if (!t.figures) return;
    if (f.request_mib) |req| {
        var ub: [32]u8 = undefined;
        var uw: Writer = .fixed(&ub);
        if (f.used_mib) |m| units.size(&uw, m) catch {} else uw.writeAll("-") catch {};
        try right(w, uw.buffered(), t.memory);
        try w.writeAll(" / ");
        var rb: [32]u8 = undefined;
        var rw: Writer = .fixed(&rb);
        units.size(&rw, @floatFromInt(req)) catch {};
        try right(w, rw.buffered(), t.memory);
    } else try w.splatByteAll(' ', t.memoryColumn());
    try w.writeAll(gap);
    if (f.threads) |n| {
        var cb: [32]u8 = undefined;
        try right(w, if (f.cores) |c| std.fmt.bufPrint(&cb, "{d:.1}", .{c}) catch "" else "-", t.cores);
        try w.print(" / {d}", .{n});
        try w.splatByteAll(' ', t.threads -| digits(n));
    } else try w.splatByteAll(' ', t.cpuColumn());
    try w.writeAll(gap);
}

/// The header of `whoCells`.
pub fn whoHeader(w: *Writer, s: Style) !void {
    const t = s.table;
    if (t.tool > 0) {
        try pad(w, "TOOL", t.tool);
        try w.writeAll(gap);
    }
    try pad(w, "STEP", t.step);
    try w.writeAll(gap);
    if (t.sample > 0) {
        try pad(w, "SAMPLE", t.sample);
        try w.writeAll(gap);
    }
}

/// The header of `figureCells`.
pub fn figureHeader(w: *Writer, s: Style) !void {
    const t = s.table;
    try right(w, "TOOK", took_width);
    try w.writeAll(gap);
    if (t.figures) {
        try right(w, "MEMORY", t.memoryColumn());
        try w.writeAll(gap);
        try right(w, "CPU", t.cpuColumn());
        try w.writeAll(gap);
    }
}

pub fn columnHeader(w: *Writer, s: Style) !void {
    try w.writeAll(s.on("\x1b[1m"));
    try pad(w, "TIME", time_width);
    try w.writeAll(gap);
    try right(w, "RULES", s.table.done);
    try w.writeAll(gap);
    try pad(w, "STATUS", status_width);
    try w.writeAll(gap);
    try whoHeader(w, s);
    try figureHeader(w, s);
    try w.print("NOTE{s}\n", .{s.off()});
}

pub fn quote(w: *Writer, s: Style, text: []const u8) !void {
    const col = s.blockColumn();
    try w.splatByteAll(' ', col);
    // The mark, a space, the text and a mark where it was cut fit in all
    // but the terminal's last column.
    const room = if (s.cols > col + 4) s.cols - col - 4 else 0;
    const shown = if (s.cols == 0) text else cut(text, room);
    const whole = shown.len == text.len;
    try w.print("{s}{s} {s}{s}{s}\n", .{ s.on("\x1b[2m"), s.marks.quote, if (whole) shown else std.mem.trimEnd(u8, shown, " "), if (whole) "" else s.marks.more, s.off() });
}

pub fn hint(w: *Writer, s: Style, command: []const u8, where: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var b: Writer = .fixed(&buf);
    b.splatByteAll(' ', s.blockColumn()) catch {};
    b.print("{s}{s}{s}", .{ s.on("\x1b[36m"), command, s.off() }) catch {};
    if (where.len > 0) b.print("   {s}{s}{s}", .{ s.on("\x1b[2m"), where, s.off() }) catch {};
    const text = b.buffered();
    if (s.cols > 1 and visible(text) > s.cols - 1) {
        try clipped(w, s, text, s.cols - 2);
        try w.writeAll(s.marks.more);
    } else try w.writeAll(text);
    try w.writeAll("\n");
}

pub fn divider(w: *Writer, s: Style, c: clock.Civil) !void {
    try w.print("{s}--- {d}-{d:0>2}-{d:0>2} ---{s}\n", .{ s.on("\x1b[2m"), @as(u32, @intCast(c.year)), c.month, c.day, s.off() });
}

fn mentions(text: []const u8, word: []const u8) bool {
    if (word.len == 0 or text.len < word.len) return false;
    var k: usize = 0;
    while (k + word.len <= text.len) : (k += 1) {
        if (!std.ascii.eqlIgnoreCase(text[k .. k + word.len], word)) continue;
        const before = k == 0 or !std.ascii.isAlphanumeric(text[k - 1]);
        const after = k + word.len == text.len or !std.ascii.isAlphanumeric(text[k + word.len]);
        if (before and after) return true;
    }
    return false;
}

pub fn versionText(tool: []const u8, printed: []const u8) []const u8 {
    const named = tool.len > 0 and printed.len > tool.len and std.ascii.startsWithIgnoreCase(printed, tool);
    var i: usize = 0;
    while (i < printed.len) : (i += 1) {
        if (!std.ascii.isDigit(printed[i]) or (i > 0 and std.ascii.isAlphanumeric(printed[i - 1]))) continue;
        var j = i;
        var dots: usize = 0;
        while (j < printed.len and (std.ascii.isAlphanumeric(printed[j]) or printed[j] == '.' or printed[j] == '-' or printed[j] == '_')) : (j += 1) {
            if (printed[j] == '.') dots += 1;
        }
        if (dots > 0) return std.mem.trimEnd(u8, printed[if (named or mentions(printed[0..i], tool)) i else 0..j], ".-_");
        i = j;
    }
    return printed;
}

pub fn thousands(w: *Writer, n: usize) !void {
    if (n < 1000) return w.print("{d}", .{n});
    try thousands(w, n / 1000);
    try w.print(",{d:0>3}", .{n % 1000});
}

fn counted(w: *Writer, n: usize, one: []const u8, many: []const u8) !void {
    try thousands(w, n);
    try w.print(" {s}", .{if (n == 1) one else many});
}

// --- Header ---

pub const StepLine = struct {
    name: []const u8,
    rules: usize,
    tool: ?[]const u8 = null,
    version: []const u8 = "",
};

pub const Header = struct {
    version: []const u8,
    workflow: []const u8,
    launch: []const u8,
    rules: usize,
    samples: usize,
    steps: []const StepLine,
    budget: []const u8,
    isolated: bool,
    records: []const u8,
    page: bool,
};

const header_steps_max = 40;

fn label(w: *Writer, s: Style, name: []const u8) !void {
    try w.splatByteAll(' ', time_width + gap.len);
    try w.print("{s}", .{s.on("\x1b[2m")});
    try pad(w, name, label_width);
    try w.print("{s}{s}", .{ s.off(), gap });
}

pub fn header(w: *Writer, s: Style, h: Header) !void {
    try w.print("{s}kanit {s}{s}   {s}   launch {s}\n", .{ s.on("\x1b[1m"), h.version, s.off(), h.workflow, h.launch });
    try label(w, s, "plan");
    try counted(w, h.rules, "rule", "rules");
    var tools = false;
    var versions = false;
    for (h.steps) |st| {
        tools = tools or st.tool != null;
        versions = versions or st.version.len > 0;
    }
    const grouped = h.steps.len < h.rules or h.samples > 0;
    if (grouped) {
        try w.writeAll(": ");
        try counted(w, h.steps.len, "step", "steps");
        if (h.samples > 0) {
            try w.writeAll(" for ");
            try counted(w, h.samples, "sample", "samples");
        }
    }
    try w.writeAll("\n");
    try label(w, s, "budget");
    try w.print("{s}, {s}\n", .{ h.budget, if (h.isolated) "isolated" else "no isolation" });
    try label(w, s, "records");
    try w.print("{s}   log launch.log", .{h.records});
    if (h.page) try w.writeAll("   page report.html");
    try w.writeAll("\n");
    if (!grouped and !tools) return;
    var step_w: usize = 4;
    var tool_w: usize = 4;
    var version_w: usize = 7;
    var rules_w: usize = 5;
    for (h.steps[0..@min(h.steps.len, header_steps_max)]) |st| {
        step_w = @max(step_w, names.columns(st.name));
        tool_w = @max(tool_w, names.columns(st.tool orelse "-"));
        version_w = @max(version_w, names.columns(st.version));
        var cb: [24]u8 = undefined;
        var cw: Writer = .fixed(&cb);
        thousands(&cw, st.rules) catch {};
        rules_w = @max(rules_w, cw.buffered().len);
    }
    const indent = time_width + gap.len;
    try w.writeAll("\n");
    try w.splatByteAll(' ', indent);
    try w.writeAll(s.on("\x1b[1m"));
    if (tools) {
        try pad(w, "TOOL", tool_w);
        try w.writeAll(gap);
        if (versions) {
            try pad(w, "VERSION", version_w);
            try w.writeAll(gap);
        }
    }
    try pad(w, "STEP", step_w);
    try w.writeAll(gap);
    try right(w, "RULES", rules_w);
    try w.print("{s}\n", .{s.off()});
    for (h.steps, 0..) |st, k| {
        try w.splatByteAll(' ', indent);
        if (k == header_steps_max) {
            try w.print("+{d} more steps; kanit plan lists them\n", .{h.steps.len - k});
            break;
        }
        if (tools) {
            try pad(w, st.tool orelse "-", tool_w);
            try w.writeAll(gap);
            if (versions) {
                try pad(w, if (st.version.len > 0) st.version else "-", version_w);
                try w.writeAll(gap);
            }
        }
        try pad(w, st.name, step_w);
        try w.writeAll(gap);
        var nb: [24]u8 = undefined;
        var nw: Writer = .fixed(&nb);
        try thousands(&nw, st.rules);
        try right(w, nw.buffered(), rules_w);
        try w.writeAll("\n");
    }
}

// --- Progress ---

pub const StepProgress = struct {
    name: []const u8,
    tool: []const u8 = "",
    selected: u32,
    done: u32,
    failed: u32,
    blocked: u32 = 0,
    stopped: u32 = 0,
    running: u32,
    ended: bool,
};

pub const Running = struct {
    word: []const u8,
    seconds: f64,
};

pub const Progress = struct {
    selected: usize,
    done: usize,
    running: usize,
    failed: usize,
    blocked: usize,
    cancelled: usize,
    elapsed_s: f64,
    steps: []const StepProgress,
    grouped: bool,
    running_list: []const Running,
};

const bar_width = 24;
const step_bar_width = 16;

pub fn counts(w: *Writer, s: Style, p: Progress) !void {
    try thousands(w, p.done);
    try w.writeAll(" of ");
    try counted(w, p.selected, "rule", "rules");
    if (p.running > 0) {
        try w.print("   {s}", .{s.on("\x1b[36m")});
        try thousands(w, p.running);
        try w.print(" running{s}", .{s.off()});
    }
    if (p.failed > 0) {
        try w.print("   {s}", .{s.on("\x1b[31;1m")});
        try thousands(w, p.failed);
        try w.print(" failed{s}", .{s.off()});
    }
    if (p.blocked > 0) {
        try w.writeAll("   ");
        try thousands(w, p.blocked);
        try w.writeAll(" blocked");
    }
    if (p.cancelled > 0) {
        try w.writeAll("   ");
        try thousands(w, p.cancelled);
        try w.writeAll(" stopped");
    }
    try w.writeAll("   ");
    try units.duration(w, p.elapsed_s);
}

/// A bar of `cells`: done in green, running in cyan, failed, blocked and
/// stopped in red, the rest empty.
fn meter(w: *Writer, s: Style, total_: usize, done: usize, running: usize, bad: usize, cells: usize) !void {
    const total = @max(total_, 1);
    const parts = [_]struct { n: usize, code: []const u8 }{
        .{ .n = done, .code = "\x1b[32m" },
        .{ .n = running, .code = "\x1b[36m" },
        .{ .n = bad, .code = "\x1b[31m" },
    };
    var filled: usize = 0;
    for (parts, 0..) |part, k| {
        var n = part.n * cells / total;
        if (n == 0 and part.n > 0) n = 1;
        n = @min(n, cells - filled);
        if (n == 0) continue;
        try w.writeAll(s.on(part.code));
        const mark = if (k == 0 or s.color) s.marks.full else s.marks.empty;
        for (0..n) |_| try w.writeAll(mark);
        try w.writeAll(s.off());
        filled += n;
    }
    try w.writeAll(s.on("\x1b[2m"));
    for (0..cells - filled) |_| try w.writeAll(s.marks.empty);
    try w.writeAll(s.off());
}

pub fn bar(w: *Writer, s: Style, p: Progress) !void {
    try meter(w, s, p.selected, p.done, p.running, p.failed + p.blocked + p.cancelled, bar_width);
}

/// One step of the step table: its tool and name in the columns of the
/// rows above, a bar, the rules done of its rules, and how the others are.
fn stepRow(w: *Writer, s: Style, st: StepProgress, count_w: usize) !void {
    const t = s.table;
    if (t.tool > 0) {
        try w.writeAll(s.on("\x1b[2m"));
        try fit(w, s, st.tool, t.tool);
        try w.print("{s}{s}", .{ s.off(), gap });
    }
    try fit(w, s, st.name, t.step);
    try w.writeAll(gap);
    try meter(w, s, st.selected, st.done, st.running, st.failed + st.blocked + st.stopped, step_bar_width);
    try w.writeAll(gap);
    var nb: [48]u8 = undefined;
    try right(w, std.fmt.bufPrint(&nb, "{d}/{d}", .{ st.done, st.selected }) catch "", count_w);
    if (st.done == st.selected) return w.print("  {s}{s}{s}", .{ s.on("\x1b[32m"), s.marks.ok, s.off() });
    var first = true;
    const parts = [_]struct { n: u32, what: []const u8, code: []const u8 }{
        .{ .n = st.failed, .what = "failed", .code = "\x1b[31;1m" },
        .{ .n = st.running, .what = "running", .code = "\x1b[36m" },
        .{ .n = st.blocked, .what = "blocked", .code = "" },
        .{ .n = st.stopped, .what = "stopped", .code = "" },
    };
    for (parts, 0..) |part, k| if (part.n > 0) {
        try w.writeAll(if (first) "  " else ", ");
        if (first and k == 0) try w.print("{s}{s}{s} ", .{ s.on("\x1b[31;1m"), s.marks.fail, s.off() });
        first = false;
        try w.print("{s}{d} {s}{s}", .{ s.on(part.code), part.n, part.what, s.off() });
    };
}

fn countWidth(p: Progress) usize {
    var most: u32 = 1;
    for (p.steps) |st| most = @max(most, st.selected);
    return 2 * digits(most) + 1;
}

/// Writes `text` cut to `cols` visible columns, skipping escape sequences,
/// so that no line on a terminal wraps.
pub fn clipped(w: *Writer, s: Style, text: []const u8, cols: usize) !void {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = std.mem.indexOfScalarPos(u8, text, i, 'm') orelse text.len - 1;
            try w.writeAll(text[i .. end + 1]);
            i = end + 1;
            continue;
        }
        const c = names.codepoint(text, i);
        n += names.width(c.value);
        if (n > cols) {
            try w.writeAll(s.off());
            return;
        }
        try w.writeAll(text[i .. i + c.len]);
        i += c.len;
    }
}

/// The step table, at most `room` rows: every step when they fit, else the
/// steps still running or with failures and one row counting the rest.
/// Each row ends with a newline and is cut to `width` when it is set.
pub fn stepTable(w: *Writer, s: Style, p: Progress, indent: usize, room: usize, width: ?usize) !usize {
    const count_w = countWidth(p);
    const all = p.steps.len <= room;
    var shown: usize = 0;
    var hidden: usize = 0;
    var hidden_done: usize = 0;
    var buf: [1024]u8 = undefined;
    for (p.steps) |st| {
        const done = st.done == st.selected;
        if (!all and (done or shown + 1 >= room)) {
            hidden += 1;
            hidden_done += @intFromBool(done);
            continue;
        }
        var bw: Writer = .fixed(&buf);
        bw.splatByteAll(' ', indent) catch {};
        stepRow(&bw, s, st, count_w) catch {};
        if (width) |cols| try clipped(w, s, bw.buffered(), cols) else try w.writeAll(bw.buffered());
        try w.writeAll("\n");
        shown += 1;
    }
    if (hidden > 0) {
        var bw: Writer = .fixed(&buf);
        bw.splatByteAll(' ', indent) catch {};
        bw.print("+{d} more {s}", .{ hidden, if (hidden == 1) "step" else "steps" }) catch {};
        if (hidden_done > 0) bw.print(", {d} done {s}{s}{s}", .{ hidden_done, s.on("\x1b[32m"), s.marks.ok, s.off() }) catch {};
        if (width) |cols| try clipped(w, s, bw.buffered(), cols) else try w.writeAll(bw.buffered());
        try w.writeAll("\n");
        shown += 1;
    }
    return shown;
}

fn runningItems(w: *Writer, s: Style, list: []const Running, total: usize, room: usize) !void {
    var used: usize = 0;
    var shown: usize = 0;
    for (list) |r| {
        var buf: [96]u8 = undefined;
        var iw: Writer = .fixed(&buf);
        units.duration(&iw, r.seconds) catch {};
        const need = 3 + names.columns(r.word) + 1 + iw.buffered().len;
        if (used + need + 6 > room) break;
        try w.print("   {s}{s}{s} {s}", .{ s.on("\x1b[36m"), r.word, s.off(), iw.buffered() });
        used += need;
        shown += 1;
    }
    if (shown < total) try w.print("   +{d}", .{total - shown});
}

/// The footer below the rows on a terminal: a blank line, the step table,
/// then a line of the counts, the elapsed time and the running rules. Without steps
/// the line opens with a bar of all the rules.
pub fn footer(w: *Writer, s: Style, p: Progress) !usize {
    const width = if (s.cols > 1) s.cols - 1 else 79;
    const steps = p.grouped and p.steps.len > 0;
    const row_w = s.table.tool + gap.len + s.table.step + gap.len + step_bar_width + gap.len + countWidth(p) + 24;
    const indent = if (steps and s.table.nameColumn() + row_w <= width) s.table.nameColumn() else 0;
    // A blank line and the step table take at most half the terminal, and
    // none of a terminal under six rows, which keeps only the counts.
    var lines: usize = 0;
    if (steps and (s.rows == 0 or s.rows >= 6)) {
        try w.writeAll("\n");
        lines = 1;
        const room = if (s.rows > 0) s.rows / 2 - 2 else header_steps_max;
        lines += try stepTable(w, s, p, indent, room, width);
    }
    var buf: [2048]u8 = undefined;
    var lw: Writer = .fixed(&buf);
    lw.splatByteAll(' ', indent) catch {};
    if (!steps) {
        bar(&lw, s, p) catch {};
        lw.writeAll("  ") catch {};
    }
    counts(&lw, s, p) catch {};
    const used = names.columns(lw.buffered());
    if (p.running > 0 and width > used + 12) runningItems(&lw, s, p.running_list, p.running, width - used) catch {};
    try clipped(w, s, lw.buffered(), width);
    return lines + 1;
}

/// The heartbeat off a terminal: an `INFO` row with the counts, then the
/// step table and the running rules under the rule's names.
pub fn heartbeat(w: *Writer, s: Style, time: []const u8, done: usize, p: Progress) !void {
    const indent = s.table.nameColumn();
    var cb: [256]u8 = undefined;
    var cw: Writer = .fixed(&cb);
    try counts(&cw, s, p);
    try line(w, s, time, done, .progress, .{}, .{}, cw.buffered());
    if (p.grouped and p.steps.len > 0) _ = try stepTable(w, s, p, indent, header_steps_max, null);
    if (p.running > 0) {
        try w.splatByteAll(' ', indent);
        try w.print("{s}running{s}", .{ s.on("\x1b[2m"), s.off() });
        try runningItems(w, s, p.running_list, p.running, 160);
        try w.writeAll("\n");
    }
}

// --- Details ---

pub const Block = enum { none, stderr, memory };

pub fn signalName(n: u32) ?[]const u8 {
    return switch (n) {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        4 => "SIGILL",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        24 => "SIGXCPU",
        25 => "SIGXFSZ",
        else => null,
    };
}

pub fn ending(w: *Writer, e: schedule.End) !Block {
    if (e.lost_service) |why| {
        try w.writeAll(why);
        return .none;
    }
    if (e.timed_out) {
        try w.writeAll("timed out at ");
        try units.duration(w, @floatFromInt(e.timeout_s));
        return .stderr;
    }
    if (e.oom_kills > 0) {
        try w.writeAll("out of memory");
        return .memory;
    }
    if (e.exit_code) |c| {
        if (c == 0) return .none;
        try w.print("exit {d}", .{c});
        if (e.container and c == 125) try w.writeAll(": the container engine failed, or the command exited 125");
        if (e.container and (c == 126 or c == 127)) try w.writeAll(": the command could not run in the container");
        if (!e.container and c == 127) try w.writeAll(": command not found");
        if (!e.container and c == 126) try w.writeAll(": command cannot run");
        return .stderr;
    }
    if (e.signal) |n| {
        if (signalName(n)) |sig| try w.print("killed by {s}", .{sig}) else try w.print("killed by signal {d}", .{n});
        return .stderr;
    }
    return .none;
}

// --- Sinks ---

pub const Level = enum { quiet, normal, verbose };

pub const Sink = struct {
    fd: sys.Fd,
    style: Style,
    level: Level,
    terminal: bool,
    owned: bool = false,
    /// Whether the column header was written; a quiet sink writes it
    /// before its first row.
    headed: bool = false,
    pending: std.ArrayList(u8) = .empty,
    last_flush_ns: i128 = 0,

    fn shows(self: *const Sink, word: Word) bool {
        return switch (self.level) {
            .quiet => word == .failed or word == .warning or word == .control,
            .normal => !(self.terminal and word == .started),
            .verbose => true,
        };
    }
};

pub const flush_ns: i128 = 100 * std.time.ns_per_ms;
pub const heartbeat_ns: i128 = 5 * 60 * std.time.ns_per_s;

pub const Log = struct {
    gpa: Allocator,
    zone: clock.Zone,
    sinks: [2]?Sink = .{ null, null },
    detail: std.Io.Writer.Allocating,
    showing: [2]bool = .{ false, false },
    day: ?clock.Civil = null,
    footer_lines: usize = 0,
    /// The columns each footer line took, to count the rows it takes after
    /// the terminal was resized.
    footer_widths: std.ArrayList(usize) = .empty,
    footer_ns: i128 = 0,
    footer_dirty: bool = true,
    done: usize = 0,

    pub fn init(gpa: Allocator, zone: clock.Zone) Log {
        return .{ .gpa = gpa, .zone = zone, .detail = .init(gpa) };
    }

    pub fn deinit(self: *Log) void {
        for (&self.sinks) |*slot| if (slot.*) |*s| {
            s.pending.deinit(self.gpa);
            if (s.owned) sys.close(s.fd);
        };
        self.detail.deinit();
        self.footer_widths.deinit(self.gpa);
    }

    pub fn terminal(self: *Log) ?*Sink {
        if (self.sinks[0]) |*s| if (s.terminal) return s;
        return null;
    }

    pub fn text(self: *Log) *Writer {
        self.detail.clearRetainingCapacity();
        return &self.detail.writer;
    }

    fn now(self: *Log) [8]u8 {
        const c = self.zone.local(sys.realNs());
        var out: [8]u8 = undefined;
        _ = timeText(&out, c);
        if (self.day) |d| if (!clock.Civil.sameDay(d, c)) for (&self.sinks) |*slot| if (slot.*) |*s| {
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &s.pending);
            divider(&aw.writer, s.style, c) catch {};
            s.pending = aw.toArrayList();
        };
        self.day = c;
        return out;
    }

    pub fn emit(self: *Log, word: Word, who: Who, f: Figures) void {
        var t = self.now();
        const note = self.detail.written();
        for (&self.sinks, 0..) |*slot, k| {
            self.showing[k] = false;
            const s = &(slot.* orelse continue);
            if (!s.shows(word)) continue;
            self.showing[k] = true;
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &s.pending);
            if (!s.headed) columnHeader(&aw.writer, s.style) catch {};
            s.headed = true;
            line(&aw.writer, s.style, &t, self.done, word, who, f, note) catch {};
            s.pending = aw.toArrayList();
        }
        self.footer_dirty = true;
    }

    pub fn quoteLine(self: *Log, text_: []const u8) void {
        for (&self.sinks, 0..) |*slot, k| {
            if (!self.showing[k]) continue;
            const s = &(slot.* orelse continue);
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &s.pending);
            quote(&aw.writer, s.style, text_) catch {};
            s.pending = aw.toArrayList();
        }
    }

    pub fn hintLine(self: *Log, command: []const u8, where: []const u8, on_terminal: []const u8) void {
        for (&self.sinks, 0..) |*slot, k| {
            if (!self.showing[k]) continue;
            const s = &(slot.* orelse continue);
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &s.pending);
            hint(&aw.writer, s.style, command, if (s.terminal) on_terminal else where) catch {};
            s.pending = aw.toArrayList();
        }
    }

    pub fn opening(self: *Log, h: Header) void {
        _ = self.now();
        for (&self.sinks) |*slot| {
            const s = &(slot.* orelse continue);
            if (s.level == .quiet) continue;
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &s.pending);
            var opened: std.Io.Writer.Allocating = .init(self.gpa);
            defer opened.deinit();
            header(&opened.writer, s.style, h) catch {};
            opened.writer.writeAll("\n") catch {};
            columnHeader(&opened.writer, s.style) catch {};
            fitLines(&aw.writer, s.style, opened.written()) catch {};
            s.headed = true;
            s.pending = aw.toArrayList();
        }
    }

    pub fn raw(self: *Log, sink: usize, bytes: []const u8) void {
        const s = &(self.sinks[sink] orelse return);
        s.pending.appendSlice(self.gpa, bytes) catch {};
    }

    pub fn beat(self: *Log, p: Progress) void {
        var t = self.now();
        for (&self.sinks) |*slot| {
            const s = &(slot.* orelse continue);
            if (s.terminal or s.level == .quiet) continue;
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &s.pending);
            heartbeat(&aw.writer, s.style, &t, self.done, p) catch {};
            s.pending = aw.toArrayList();
        }
    }

    pub fn deadline(self: *const Log) ?i128 {
        var best: ?i128 = null;
        for (self.sinks) |slot| {
            const s = slot orelse continue;
            if (s.pending.items.len == 0) continue;
            const at = s.last_flush_ns + flush_ns;
            best = if (best) |b| @min(b, at) else at;
        }
        return best;
    }

    pub fn footerDue(self: *const Log, now_ns: i128) bool {
        const s = self.sinks[0] orelse return false;
        if (!s.terminal) return false;
        if (self.footer_dirty) return now_ns - self.footer_ns >= flush_ns;
        return now_ns - self.footer_ns >= std.time.ns_per_s;
    }

    pub fn flush(self: *Log, now_ns: i128, force: bool, footer_text: ?[]const u8, footer_lines: usize) void {
        for (&self.sinks) |*slot| {
            const s = &(slot.* orelse continue);
            if (s.terminal) continue;
            if (s.pending.items.len == 0) continue;
            if (!force and now_ns - s.last_flush_ns < flush_ns and s.pending.items.len < 16 * 1024) continue;
            sys.writeAll(s.fd, s.pending.items) catch {};
            s.pending.clearRetainingCapacity();
            s.last_flush_ns = now_ns;
        }
        const s = self.terminal() orelse return;
        const lines_due = s.pending.items.len > 0 and (force or now_ns - s.last_flush_ns >= flush_ns or s.pending.items.len >= 16 * 1024);
        if (!lines_due and footer_text == null and !(force and self.footer_lines > 0)) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        if (self.footer_lines > 0) {
            var rows: usize = 0;
            for (self.footer_widths.items) |n| rows += if (s.style.cols > 0) @max(1, (n + s.style.cols - 1) / s.style.cols) else 1;
            if (rows > 1) out.print(self.gpa, "\r\x1b[{d}A\x1b[J", .{rows - 1}) catch {} else out.appendSlice(self.gpa, "\r\x1b[J") catch {};
            self.footer_lines = 0;
        }
        if (lines_due) {
            out.appendSlice(self.gpa, s.pending.items) catch {};
            s.pending.clearRetainingCapacity();
            s.last_flush_ns = now_ns;
        }
        if (footer_text) |f| {
            out.appendSlice(self.gpa, f) catch {};
            self.footer_widths.clearRetainingCapacity();
            var it = std.mem.splitScalar(u8, f, '\n');
            while (it.next()) |l| self.footer_widths.append(self.gpa, visible(l)) catch {};
            self.footer_lines = footer_lines;
            self.footer_ns = now_ns;
            self.footer_dirty = false;
        }
        sys.writeAll(s.fd, out.items) catch {};
    }
};
