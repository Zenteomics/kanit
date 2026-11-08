//! The run log: one line per event, the same on a terminal, on standard
//! error off a terminal and in each launch's `launch.log`. A line is the
//! local time, a status word, the rule's step and sample in padded columns
//! (`names.zig`) and its details; lines that belong to an event follow it at
//! the detail column. A terminal adds color, cuts quoted output to the window
//! and keeps a footer of progress below the lines; off a terminal a heartbeat
//! line carries the same progress every few minutes. `launch.log` keeps every
//! line whole and without color. A fixed few marks are Unicode, with ASCII
//! stand-ins outside a UTF-8 locale.
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
};

pub const unicode: Marks = .{ .ok = "✓", .fail = "✗", .none = "·", .quote = "│", .full = "━", .empty = "─" };
pub const ascii: Marks = .{ .ok = "+", .fail = "x", .none = ".", .quote = "|", .full = "#", .empty = "-" };

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

pub const Word = enum {
    started,
    completed,
    retrying,
    failed,
    blocked,
    cancelled,
    step,
    sample,
    shared,
    tool,
    control,
    warning,
    progress,

    pub fn tint(w: Word) []const u8 {
        return switch (w) {
            .started, .progress => "\x1b[2m",
            .completed => "\x1b[32m",
            .retrying => "\x1b[33m",
            .failed => "\x1b[31;1m",
            .blocked => "\x1b[31m",
            .cancelled => "\x1b[35m",
            .step, .sample => "\x1b[1m",
            .shared, .tool, .control => "\x1b[36m",
            .warning => "\x1b[33;1m",
        };
    }
};

pub const word_width = 9;
const time_width = 8;
const gap = "  ";

pub const Style = struct {
    color: bool = false,
    marks: *const Marks = &ascii,
    widths: names.Widths = .{ .step = 0, .sample = 0 },
    cols: usize = 0,

    pub fn detailColumn(s: Style) usize {
        var c: usize = time_width + gap.len + word_width + gap.len + s.widths.step + gap.len;
        if (s.widths.sample > 0) c += s.widths.sample + gap.len;
        if (s.widths.tool > 0) c += s.widths.tool + gap.len;
        return c;
    }

    fn on(s: Style, code: []const u8) []const u8 {
        return if (s.color) code else "";
    }

    fn off(s: Style) []const u8 {
        return if (s.color) "\x1b[0m" else "";
    }
};

pub fn timeText(buf: *[8]u8, c: clock.Civil) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ c.hour, c.minute, c.second }) catch unreachable;
}

fn pad(w: *Writer, text: []const u8, width: usize) !void {
    try w.writeAll(text);
    try w.splatByteAll(' ', width -| names.columns(text));
}

pub fn cut(text: []const u8, cols: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (n == cols) return text[0..i];
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i = @min(text.len, i + len);
        n += 1;
    }
    return text;
}

pub const Who = struct {
    step: []const u8 = "",
    sample: []const u8 = "",
    tool: []const u8 = "",
};

pub fn line(w: *Writer, s: Style, time: []const u8, word: Word, who: Who, detail: []const u8) !void {
    var buf: [8192]u8 = undefined;
    var b: Writer = .fixed(&buf);
    columns(&b, s, time, word, who, detail) catch return columns(w, s, time, word, who, detail);
    try w.print("{s}\n", .{std.mem.trimEnd(u8, b.buffered(), " ")});
}

fn columns(w: *Writer, s: Style, time: []const u8, word: Word, who: Who, detail: []const u8) !void {
    try w.print("{s}{s}{s}{s}{s}", .{ s.on("\x1b[2m"), time, s.off(), gap, s.on(word.tint()) });
    try pad(w, @tagName(word), word_width);
    try w.print("{s}{s}", .{ s.off(), gap });
    try pad(w, who.step, s.widths.step);
    try w.writeAll(gap);
    if (s.widths.sample > 0) {
        try pad(w, who.sample, s.widths.sample);
        try w.writeAll(gap);
    }
    if (s.widths.tool > 0) {
        if (who.tool.len > 0) try w.print("{s}{s}{s}", .{ s.on("\x1b[2m"), who.tool, s.off() });
        try w.splatByteAll(' ', s.widths.tool -| names.columns(who.tool));
        try w.writeAll(gap);
    }
    try w.writeAll(detail);
}

pub fn quote(w: *Writer, s: Style, text: []const u8) !void {
    const col = s.detailColumn();
    try w.splatByteAll(' ', col);
    const room = if (s.cols > col + 3) s.cols - col - 3 else 0;
    const shown = if (s.cols == 0) text else cut(text, room);
    const whole = shown.len == text.len;
    try w.print("{s}{s} {s}{s}{s}\n", .{ s.on("\x1b[2m"), s.marks.quote, if (whole) shown else std.mem.trimEnd(u8, shown, " "), if (whole) "" else "...", s.off() });
}

pub fn hint(w: *Writer, s: Style, command: []const u8, where: []const u8) !void {
    try w.splatByteAll(' ', s.detailColumn());
    try w.print("{s}{s}{s}", .{ s.on("\x1b[36m"), command, s.off() });
    if (where.len > 0) try w.print("   {s}{s}{s}", .{ s.on("\x1b[2m"), where, s.off() });
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
    tool: ?[]const u8 = null,
    rules: usize,
};

pub const ToolLine = struct {
    name: []const u8,
    version: []const u8 = "",
    steps: []const u8,
};

pub const Header = struct {
    version: []const u8,
    workflow: []const u8,
    launch: []const u8,
    rules: usize,
    samples: usize,
    steps: []const StepLine,
    tools: []const ToolLine = &.{},
    budget: []const u8,
    isolated: bool,
    records: []const u8,
    page: bool,
};

const header_lines_max = 3;

fn label(w: *Writer, s: Style, name: []const u8) !void {
    try w.splatByteAll(' ', time_width + gap.len);
    try w.print("{s}", .{s.on("\x1b[2m")});
    try pad(w, name, word_width);
    try w.print("{s}{s}", .{ s.off(), gap });
}

pub fn header(w: *Writer, s: Style, h: Header) !void {
    try w.print("{s}kanit {s}{s}   {s}   launch {s}\n", .{ s.on("\x1b[1m"), h.version, s.off(), h.workflow, h.launch });
    try label(w, s, "plan");
    try counted(w, h.rules, "rule", "rules");
    const grouped = h.steps.len < h.rules or h.samples > 0;
    if (grouped) {
        try w.writeAll(" in ");
        try counted(w, h.steps.len, "step", "steps");
    }
    if (h.samples > 0) {
        try w.writeAll(" for ");
        try counted(w, h.samples, "sample", "samples");
    }
    try w.writeAll("\n");
    try label(w, s, "budget");
    try w.print("{s}, {s}\n", .{ h.budget, if (h.isolated) "isolated" else "no isolation" });
    if (grouped) {
        try label(w, s, "steps");
        const start = time_width + gap.len + word_width + gap.len;
        const width = if (s.cols > start + 20) s.cols - 1 else 120;
        var at = start;
        var lines: usize = 1;
        for (h.steps, 0..) |st, k| {
            var buf: [160]u8 = undefined;
            var iw: Writer = .fixed(&buf);
            iw.print("{s} ", .{st.name}) catch {};
            thousands(&iw, st.rules) catch {};
            const item = iw.buffered();
            const need = names.columns(item) + if (at > start) @as(usize, 3) else 0;
            const more: usize = if (lines == header_lines_max and k + 1 < h.steps.len) 12 else 0;
            if (at > start and at + need + more > width) {
                if (lines == header_lines_max) {
                    try w.print("   +{d} more", .{h.steps.len - k});
                    break;
                }
                try w.writeAll("\n");
                try w.splatByteAll(' ', start);
                at = start;
                lines += 1;
            }
            if (at > start) try w.writeAll("   ");
            try w.writeAll(item);
            at += names.columns(item) + if (at > start) @as(usize, 3) else 0;
        }
        try w.writeAll("\n");
    }
    if (h.tools.len > 0) {
        var name_w: usize = 0;
        var version_w: usize = 0;
        for (h.tools) |t| {
            name_w = @max(name_w, names.columns(t.name));
            version_w = @max(version_w, names.columns(t.version));
        }
        for (h.tools, 0..) |t, k| {
            try label(w, s, if (k == 0) "tools" else "");
            try pad(w, t.name, name_w + 3);
            if (version_w > 0) {
                if (t.version.len > 0) try pad(w, t.version, version_w + 3) else {
                    try w.print("{s}{s}{s}", .{ s.on("\x1b[2m"), "-", s.off() });
                    try w.splatByteAll(' ', version_w + 2);
                }
            }
            try w.print("{s}{s}{s}\n", .{ s.on("\x1b[2m"), t.steps, s.off() });
        }
    }
    try label(w, s, "records");
    try w.print("{s}   log launch.log", .{h.records});
    if (h.page) try w.writeAll("   page report.html");
    try w.writeAll("\n");
}

// --- Progress ---

pub const StepProgress = struct {
    name: []const u8,
    selected: u32,
    done: u32,
    failed: u32,
    blocked: u32 = 0,
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
    steps_ok: usize,
    grouped: bool,
    running_list: []const Running,
};

const bar_width = 24;

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
        try w.writeAll(" cancelled");
    }
    try w.writeAll("   ");
    try units.duration(w, p.elapsed_s);
}

pub fn bar(w: *Writer, s: Style, p: Progress) !void {
    const total = @max(p.selected, 1);
    const parts = [_]struct { n: usize, code: []const u8 }{
        .{ .n = p.done, .code = "\x1b[32m" },
        .{ .n = p.running, .code = "\x1b[36m" },
        .{ .n = p.failed + p.blocked + p.cancelled, .code = "\x1b[31m" },
    };
    var filled: usize = 0;
    for (parts, 0..) |part, k| {
        var n = part.n * bar_width / total;
        if (n == 0 and part.n > 0) n = 1;
        n = @min(n, bar_width - filled);
        if (n == 0) continue;
        try w.writeAll(s.on(part.code));
        const mark = if (k == 0 or s.color) s.marks.full else s.marks.empty;
        for (0..n) |_| try w.writeAll(mark);
        try w.writeAll(s.off());
        filled += n;
    }
    try w.writeAll(s.on("\x1b[2m"));
    for (0..bar_width - filled) |_| try w.writeAll(s.marks.empty);
    try w.writeAll(s.off());
}

fn stepItem(w: *Writer, s: Style, st: StepProgress) !void {
    try w.print("{s} ", .{st.name});
    if (st.failed > 0) {
        try w.print("{s}{s}{s} ", .{ s.on("\x1b[31m"), s.marks.fail, s.off() });
    } else if (st.done == st.selected) try w.print("{s}{s}{s} ", .{ s.on("\x1b[32m"), s.marks.ok, s.off() });
    try w.print("{d}/{d}", .{ st.done, st.selected });
    if (st.running > 0) try w.print(", {s}{d} running{s}", .{ s.on("\x1b[36m"), st.running, s.off() });
    if (st.blocked > 0) try w.print(", {d} blocked", .{st.blocked});
}

fn itemColumns(st: StepProgress) usize {
    var buf: [256]u8 = undefined;
    var iw: Writer = .fixed(&buf);
    stepItem(&iw, .{}, st) catch return 256;
    return names.columns(iw.buffered());
}

pub fn stepsLine(w: *Writer, s: Style, p: Progress, width: usize) !void {
    var used: usize = 0;
    var shown: usize = 0;
    var full = true;
    for (p.steps) |st| {
        const need = itemColumns(st) + if (shown > 0) @as(usize, 3) else 0;
        if (used + need > width) {
            full = false;
            break;
        }
        used += need;
        shown += 1;
    }
    if (full) {
        for (p.steps, 0..) |st, k| {
            if (k > 0) try w.writeAll("   ");
            try stepItem(w, s, st);
        }
        return;
    }
    used = 0;
    shown = 0;
    if (p.steps_ok > 0) {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d} {s} ", .{ p.steps_ok, if (p.steps_ok == 1) "step" else "steps" }) catch "";
        try w.print("{s}{s}{s}{s}", .{ text, s.on("\x1b[32m"), s.marks.ok, s.off() });
        used = names.columns(text) + 1;
        shown = 1;
    }
    const open = p.steps.len - p.steps_ok;
    var listed: usize = 0;
    for (p.steps) |st| {
        if (st.done == st.selected) continue;
        const need = itemColumns(st) + if (shown > 0) @as(usize, 3) else 0;
        if (used + need + 8 > width) break;
        if (shown > 0) try w.writeAll("   ");
        try stepItem(w, s, st);
        used += need;
        shown += 1;
        listed += 1;
    }
    if (listed < open) try w.print("   +{d}", .{open - listed});
}

pub fn runningLine(w: *Writer, s: Style, list: []const Running, total: usize, width: usize) !void {
    try w.print("{s}running{s}", .{ s.on("\x1b[2m"), s.off() });
    var used: usize = 7;
    var shown: usize = 0;
    for (list) |r| {
        var buf: [96]u8 = undefined;
        var iw: Writer = .fixed(&buf);
        units.duration(&iw, r.seconds) catch {};
        const need = 3 + names.columns(r.word) + 1 + iw.buffered().len;
        if (used + need + 6 > width) break;
        try w.print("   {s}{s}{s} {s}", .{ s.on("\x1b[36m"), r.word, s.off(), iw.buffered() });
        used += need;
        shown += 1;
    }
    if (shown < total) try w.print("   +{d}", .{total - shown});
}

pub fn footer(w: *Writer, s: Style, p: Progress) !usize {
    const width = if (s.cols > 1) s.cols - 1 else 79;
    try bar(w, s, p);
    try w.writeAll("  ");
    try counts(w, s, p);
    var lines: usize = 1;
    if (p.grouped and p.steps.len > 0) {
        try w.writeAll("\n");
        try stepsLine(w, s, p, width);
        lines += 1;
    }
    if (p.running > 0) {
        try w.writeAll("\n");
        try runningLine(w, s, p.running_list, p.running, width);
        lines += 1;
    }
    return lines;
}

pub fn heartbeat(w: *Writer, s: Style, time: []const u8, p: Progress) !void {
    const indent = time_width + gap.len + word_width + gap.len;
    const width: usize = 160;
    try w.print("{s}{s}{s}{s}{s}", .{ s.on("\x1b[2m"), time, s.off(), gap, s.on(Word.progress.tint()) });
    try pad(w, "progress", word_width);
    try w.print("{s}{s}", .{ s.off(), gap });
    try counts(w, s, p);
    try w.writeAll("\n");
    if (p.grouped and p.steps.len > 0) {
        try w.splatByteAll(' ', indent);
        try stepsLine(w, s, p, width - indent);
        try w.writeAll("\n");
    }
    if (p.running > 0) {
        try w.splatByteAll(' ', indent);
        try runningLine(w, s, p.running_list, p.running, width - indent);
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

pub fn ending(w: *Writer, e: schedule.End, wall_s: f64) !Block {
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
        try w.print("out of memory at its {d} MiB", .{e.memory_mib});
        return .memory;
    }
    if (e.exit_code) |c| {
        if (c == 0) return .none;
        try w.print("exit {d}", .{c});
        if (e.container and c == 125) try w.writeAll(": the container engine failed, or the command exited 125");
        if (e.container and (c == 126 or c == 127)) try w.writeAll(": the command could not run in the container");
        if (!e.container and c == 127) try w.writeAll(": command not found");
        if (!e.container and c == 126) try w.writeAll(": command cannot run");
        try w.writeAll(" after ");
        try units.duration(w, wall_s);
        return .stderr;
    }
    if (e.signal) |n| {
        if (signalName(n)) |sig| try w.print("killed by {s}", .{sig}) else try w.print("killed by signal {d}", .{n});
        try w.writeAll(" after ");
        try units.duration(w, wall_s);
        return .stderr;
    }
    return .none;
}

pub const Use = struct {
    wall_s: f64,
    memory_mib: ?f64 = null,
    request_mib: u64,
    cpu_s: ?f64 = null,
    threads: u32,
    attempts: u32 = 1,
};

const duration_width = 6;
const size_width = 8;

pub fn usage(w: *Writer, u: Use) !void {
    var buf: [256]u8 = undefined;
    var b: Writer = .fixed(&buf);
    try units.right(&b, duration_width, units.duration, .{u.wall_s});
    const cpu = u.cpu_s != null and u.wall_s >= 0.1;
    if (u.memory_mib) |m| {
        try b.writeAll("   mem ");
        try units.right(&b, size_width, units.size, .{m});
        try b.writeAll(" of ");
        try units.right(&b, size_width, units.size, .{@as(f64, @floatFromInt(u.request_mib))});
    } else if (cpu or u.attempts > 1) try b.splatByteAll(' ', 3 + 4 + size_width + 4 + size_width);
    if (cpu) {
        try b.print("   cpu {d:>4.1} of {d}", .{ u.cpu_s.? / u.wall_s, u.threads });
    } else if (u.attempts > 1) try b.splatByteAll(' ', 14);
    if (u.attempts > 1) try b.print("   after {d} attempts", .{u.attempts});
    try w.writeAll(std.mem.trimEnd(u8, b.buffered(), " "));
}

pub fn request(w: *Writer, threads: u32, memory_mib: u64) !void {
    try w.print("{d:>2} {s:<7}   ", .{ threads, if (threads == 1) "thread" else "threads" });
    try units.right(w, size_width, units.size, .{@as(f64, @floatFromInt(memory_mib))});
}

// --- Sinks ---

pub const Level = enum { quiet, normal, verbose };

pub const Sink = struct {
    fd: sys.Fd,
    style: Style,
    level: Level,
    terminal: bool,
    owned: bool = false,
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
    footer_ns: i128 = 0,
    footer_dirty: bool = true,

    pub fn init(gpa: Allocator, zone: clock.Zone) Log {
        return .{ .gpa = gpa, .zone = zone, .detail = .init(gpa) };
    }

    pub fn deinit(self: *Log) void {
        for (&self.sinks) |*slot| if (slot.*) |*s| {
            s.pending.deinit(self.gpa);
            if (s.owned) sys.close(s.fd);
        };
        self.detail.deinit();
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

    pub fn emit(self: *Log, word: Word, who: Who) void {
        var t = self.now();
        const detail = self.detail.written();
        for (&self.sinks, 0..) |*slot, k| {
            self.showing[k] = false;
            const s = &(slot.* orelse continue);
            if (!s.shows(word)) continue;
            self.showing[k] = true;
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &s.pending);
            line(&aw.writer, s.style, &t, word, who, detail) catch {};
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
            header(&aw.writer, s.style, h) catch {};
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
            heartbeat(&aw.writer, s.style, &t, p) catch {};
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
            if (self.footer_lines > 1) out.print(self.gpa, "\r\x1b[{d}A\x1b[J", .{self.footer_lines - 1}) catch {} else out.appendSlice(self.gpa, "\r\x1b[J") catch {};
            self.footer_lines = 0;
        }
        if (lines_due) {
            out.appendSlice(self.gpa, s.pending.items) catch {};
            s.pending.clearRetainingCapacity();
            s.last_flush_ns = now_ns;
        }
        if (footer_text) |f| {
            out.appendSlice(self.gpa, f) catch {};
            self.footer_lines = footer_lines;
            self.footer_ns = now_ns;
            self.footer_dirty = false;
        }
        sys.writeAll(s.fd, out.items) catch {};
    }
};
