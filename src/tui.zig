//! Interactive `watch` on a terminal. A header shows the launch's progress
//! and its use of the budget, then a table of its steps; below it, one of
//! five views: the table of rules, a timeline, the details of one rule, its
//! output as it grows, or the keys. The rows use the run log's columns,
//! tags, units and marks (`log.zig`), so the view and the log read alike.
//! The terminal is put in raw mode on the alternate screen and restored on
//! every exit; each refresh writes one frame in place. `snapshot` writes the
//! same view once as text, for `watch --once` and a watch into a file.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const process = @import("process.zig");
const cgroup = @import("cgroup.zig");
const monitor = @import("monitor.zig");
const tracker = @import("tracker.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const term = @import("term.zig");
const log = @import("log.zig");
const naming = @import("names.zig");
const units = @import("units.zig");
const Allocator = std.mem.Allocator;
const Tracker = tracker.Tracker;
const Status = tracker.Status;
const RuleView = tracker.RuleView;

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    enter,
    escape,
    interrupt,
};

pub fn decode(in: []const u8, used: *usize) ?Key {
    used.* = 0;
    if (in.len == 0) return null;
    used.* = 1;
    switch (in[0]) {
        3 => return .interrupt,
        '\r', '\n' => return .enter,
        0x1b => {},
        else => return .{ .char = in[0] },
    }
    if (in.len == 1 or in[1] == 0x1b) return .escape;
    if (in[1] != '[' and in[1] != 'O') {
        used.* = 2;
        return null;
    }
    var i: usize = 2;
    while (i < in.len and (in[i] < 0x40 or in[i] > 0x7e)) i += 1;
    if (i == in.len) {
        used.* = 0;
        return null;
    }
    used.* = i + 1;
    const params = in[2..i];
    return switch (in[i]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '~' => if (std.mem.eql(u8, params, "5")) .page_up else if (std.mem.eql(u8, params, "6")) .page_down else if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) .home else if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) .end else null,
        else => null,
    };
}

pub const Filter = enum {
    all,
    active,
    waiting,
    failed,
    done,

    fn keeps(f: Filter, s: Status) bool {
        return switch (f) {
            .all => true,
            .active => s.active() or s == .retrying,
            .waiting => s == .waiting or s == .pending,
            .failed => s == .failed or s == .blocked or s == .cancelled,
            .done => s.done(),
        };
    }
};

pub const Mode = enum { table, log, timeline, details, help };

pub const Sort = enum {
    status,
    elapsed,
    memory,
    name,
};

pub const Action = struct { cmd: []const u8, rule: ?usize };

const confirm_ns = 3 * std.time.ns_per_s;

pub const Ui = struct {
    links: Links = .{},
    mode: Mode = .table,
    before_help: Mode = .table,
    filter: Filter = .all,
    selected: ?usize = null,
    chosen: bool = false,
    top: usize = 0,
    stderr: bool = true,
    quit: bool = false,
    sort: Sort = .status,
    query: [64]u8 = undefined,
    query_len: usize = 0,
    typing: bool = false,
    action: ?Action = null,
    message: [160]u8 = undefined,
    message_len: usize = 0,
    message_until: i128 = 0,
    page: usize = 20,
    color: bool = false,
    marks: *const log.Marks = &log.ascii,
    clock_ns: i128 = 0,
    confirm_until: i128 = 0,

    pub fn key(self: *Ui, k: Key, rows: []const usize, page: usize) void {
        if (self.typing) return self.typeKey(k);
        if (self.mode == .help) {
            switch (k) {
                .interrupt => self.quit = true,
                .escape, .left => self.mode = self.before_help,
                .char => |c| if (c == 'q' or c == '?') {
                    self.mode = self.before_help;
                },
                else => {},
            }
            return;
        }
        switch (k) {
            .interrupt => self.quit = true,
            .escape, .left => if (self.mode == .table) {
                if (k == .escape) self.quit = true;
            } else {
                self.mode = .table;
            },
            .enter, .right => if (self.selected != null) {
                self.mode = .log;
            },
            .up => self.move(rows, -1),
            .down => self.move(rows, 1),
            .page_up => self.move(rows, -@as(isize, @intCast(@max(page, 1)))),
            .page_down => self.move(rows, @intCast(@max(page, 1))),
            .home => self.move(rows, std.math.minInt(isize) / 2),
            .end => self.move(rows, std.math.maxInt(isize) / 2),
            .char => |c| switch (c) {
                'q' => if (self.mode == .table) {
                    self.quit = true;
                } else {
                    self.mode = .table;
                },
                '?' => {
                    self.before_help = self.mode;
                    self.mode = .help;
                },
                'j' => self.move(rows, 1),
                'k' => self.move(rows, -1),
                ' ' => self.move(rows, @intCast(@max(page, 1))),
                'b' => self.move(rows, -@as(isize, @intCast(@max(page, 1)))),
                'g' => self.move(rows, std.math.minInt(isize) / 2),
                'G' => self.move(rows, std.math.maxInt(isize) / 2),
                'l' => if (self.selected != null) {
                    self.mode = .log;
                },
                'h' => self.mode = .table,
                't' => self.mode = if (self.mode == .timeline) .table else .timeline,
                'o' => self.stderr = !self.stderr,
                'a' => self.setFilter(.all),
                'r' => self.setFilter(.active),
                'w' => self.setFilter(.waiting),
                'f' => self.setFilter(.failed),
                'd' => self.setFilter(.done),
                'i' => if (self.selected != null) {
                    self.mode = if (self.mode == .details) .table else .details;
                },
                's' => self.sort = @enumFromInt((@intFromEnum(self.sort) + 1) % std.enums.values(Sort).len),
                '/' => {
                    self.typing = true;
                    self.query_len = 0;
                    self.top = 0;
                },
                'S' => if (self.selected) |sel| {
                    self.chosen = true;
                    self.action = .{ .cmd = "stop", .rule = sel };
                },
                'R' => if (self.selected) |sel| {
                    self.chosen = true;
                    self.action = .{ .cmd = "retry", .rule = sel };
                },
                'X' => if (self.clock_ns < self.confirm_until) {
                    self.confirm_until = 0;
                    self.action = .{ .cmd = "cancel", .rule = null };
                } else {
                    self.confirm_until = self.clock_ns + confirm_ns;
                    self.say("press X again to cancel the launch", self.clock_ns);
                },
                else => {},
            },
        }
    }

    fn typeKey(self: *Ui, k: Key) void {
        switch (k) {
            .enter => self.typing = false,
            .escape, .interrupt => {
                self.typing = false;
                self.query_len = 0;
            },
            .char => |c| if (c == 127 or c == 8) {
                self.query_len -|= 1;
            } else if (c >= 0x20 and c < 0x7f and self.query_len < self.query.len) {
                self.query[self.query_len] = c;
                self.query_len += 1;
            },
            else => {},
        }
        self.top = 0;
    }

    pub fn queryText(self: *const Ui) []const u8 {
        return self.query[0..self.query_len];
    }

    pub fn say(self: *Ui, text: []const u8, now_ns: i128) void {
        const n = @min(text.len, self.message.len);
        @memcpy(self.message[0..n], text[0..n]);
        self.message_len = n;
        self.message_until = now_ns + 4 * std.time.ns_per_s;
    }

    fn setFilter(self: *Ui, f: Filter) void {
        self.filter = f;
        self.chosen = false;
        self.top = 0;
        self.selected = null;
        if (self.mode == .log) self.mode = .table;
    }

    fn position(self: *const Ui, rows: []const usize) ?usize {
        const sel = self.selected orelse return null;
        return std.mem.indexOfScalar(usize, rows, sel);
    }

    fn move(self: *Ui, rows: []const usize, by: isize) void {
        if (rows.len == 0) return;
        const cur: isize = if (self.position(rows)) |p| @intCast(p) else if (by > 0) -1 else @intCast(rows.len);
        const next = std.math.clamp(cur +| by, 0, @as(isize, @intCast(rows.len - 1)));
        self.selected = rows[@intCast(next)];
        self.chosen = true;
    }

    pub fn settle(self: *Ui, rows: []const usize, page: usize) void {
        if (rows.len == 0) {
            self.top = 0;
            return;
        }
        if (!self.chosen) self.selected = rows[@min(self.top, rows.len - 1)];
        const pos = self.position(rows) orelse blk: {
            self.selected = rows[@min(self.top, rows.len - 1)];
            break :blk self.position(rows);
        };
        if (pos) |p| {
            if (p < self.top) self.top = p;
            if (page > 0 and p >= self.top + page) self.top = p + 1 - page;
        }
        if (self.top + page > rows.len) self.top = rows.len -| page;
    }
};

fn rank(s: Status) u8 {
    return switch (s) {
        .running, .cancelling => 0,
        .retrying => 1,
        .waiting => 2,
        .failed, .blocked, .cancelled => 3,
        .completed, .reused => 4,
        .pending => 5,
    };
}

fn elapsedOf(r: *const RuleView, now_ns: i128) i128 {
    if (r.started_ns == 0) return 0;
    return (if (r.finished_ns > 0) r.finished_ns else now_ns) - r.started_ns;
}

pub fn visible(a: Allocator, t: *const Tracker, f: Filter, sort: Sort, query: []const u8, now_ns: i128) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    for (t.rules.items, 0..) |r, i| {
        if (!f.keeps(r.status)) continue;
        if (query.len > 0 and std.mem.indexOf(u8, r.name, query) == null and std.mem.indexOf(u8, r.shown, query) == null) continue;
        try out.append(a, i);
    }
    const Ctx = struct { t: *const Tracker, sort: Sort, now: i128 };
    std.mem.sort(usize, out.items, Ctx{ .t = t, .sort = sort, .now = now_ns }, struct {
        fn lt(c: Ctx, x: usize, y: usize) bool {
            const rx = &c.t.rules.items[x];
            const ry = &c.t.rules.items[y];
            switch (c.sort) {
                .status => {
                    const kx = rank(rx.status);
                    const ky = rank(ry.status);
                    if (kx != ky) return kx < ky;
                },
                .elapsed => {
                    const ex = elapsedOf(rx, c.now);
                    const ey = elapsedOf(ry, c.now);
                    if (ex != ey) return ex > ey;
                },
                .memory => {
                    const mx = rx.memory_peak orelse rx.live_peak orelse 0;
                    const my = ry.memory_peak orelse ry.live_peak orelse 0;
                    if (mx != my) return mx > my;
                },
                .name => {
                    const o = std.mem.order(u8, rx.shown, ry.shown);
                    if (o != .eq) return o == .lt;
                },
            }
            return x < y;
        }
    }.lt);
    return out.items;
}

/// The bytes of `s` that fit in `cols` columns.
pub fn fit(s: []const u8, cols: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = naming.codepoint(s, i);
        const w = naming.width(c.value);
        if (n + w > cols) return i;
        n += w;
        i += c.len;
    }
    return s.len;
}

fn tailStart(s: []const u8, cols: usize) usize {
    var n: usize = 0;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] & 0xc0 == 0x80) continue;
        n += 1;
        if (n == cols) return i;
    }
    return 0;
}

// --- Drawing ---

const reset = "\x1b[0m";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const reverse = "\x1b[7m";
const red = "\x1b[31m";
const green = "\x1b[32m";
const yellow = "\x1b[33m";
const magenta = "\x1b[35m";
const cyan = "\x1b[36m";
const blue = "\x1b[34m";
const on_green = "\x1b[42m";
const on_yellow = "\x1b[43m";
const on_red = "\x1b[41m";
const on_blue = "\x1b[44m";
const on_magenta = "\x1b[45m";
const on_cyan = "\x1b[46m";
const on_track = "\x1b[100m";

const Line = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    cols: usize,
    used: usize = 0,
    color: bool,

    fn sgr(self: *Line, seq: []const u8) void {
        if (self.color) self.raw(seq);
    }

    fn raw(self: *Line, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn text(self: *Line, s: []const u8) void {
        const cut = s[0..fit(s, self.cols -| self.used)];
        const start = self.len;
        self.raw(cut);
        const shown = term.blankControls(self.buf[start..self.len]);
        self.len = start + shown.len;
        self.used += naming.columns(shown);
    }

    fn clipped(self: *Line, s: []const u8) void {
        const room = self.cols -| self.used;
        if (fit(s, room) == s.len or room < 4) return self.text(s);
        self.text(s[0..fit(s, room - 3)]);
        self.text("...");
    }

    fn print(self: *Line, comptime fmt: []const u8, args: anytype) void {
        var tmp: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&tmp);
        w.print(fmt, args) catch {};
        self.text(w.buffered());
    }

    fn spaces(self: *Line, n: usize) void {
        var i: usize = 0;
        while (i < n and self.used < self.cols) : (i += 1) {
            self.raw(" ");
            self.used += 1;
        }
    }

    fn to(self: *Line, col: usize) void {
        if (col > self.used) self.spaces(col - self.used);
    }

    fn field(self: *Line, s: []const u8, width: usize, right: bool) void {
        const cut = s[0..fit(s, width)];
        const shown = naming.columns(cut);
        if (right) self.spaces(width - shown);
        self.text(cut);
        if (!right) self.spaces(width - shown);
    }

    fn name(self: *Line, s: []const u8, width: usize) void {
        if (fit(s, width) == s.len or width < 7) return self.field(s, width, false);
        const keep = width - 3;
        const head = (keep + 1) / 2;
        self.text(s[0..fit(s, head)]);
        self.text("...");
        self.text(s[tailStart(s, keep - head)..]);
    }

    fn cells(self: *Line, n: usize, bg: []const u8, ch: u8) void {
        if (n == 0) return;
        if (self.color) {
            self.raw(bg);
            self.spaces(n);
            self.raw(reset);
            return;
        }
        var i: usize = 0;
        while (i < n and self.used < self.cols) : (i += 1) {
            self.raw(&.{ch});
            self.used += 1;
        }
    }

    /// Writes `mark` `n` times in `fg`.
    fn marks(self: *Line, n: usize, fg: []const u8, mark: []const u8) void {
        if (n == 0) return;
        self.sgr(fg);
        var i: usize = 0;
        while (i < n and self.used < self.cols) : (i += 1) {
            self.raw(mark);
            self.used += 1;
        }
        self.sgr(reset);
    }

    /// A bar of `width` marks, the parts in their colors and the rest dim,
    /// as the run log draws its steps. Without color only the first part
    /// is drawn full, and the counts beside the bar say the rest.
    fn bar(self: *Line, m: *const log.Marks, width: usize, total: f64, parts: []const Part) void {
        var cells_of: [8]usize = @splat(0);
        var taken: usize = 0;
        if (total > 0) for (parts, 0..) |p, i| {
            const share = @max(p.value, 0) / total * @as(f64, @floatFromInt(width));
            var n: usize = std.math.lossyCast(usize, @floor(share));
            if (n == 0 and p.value > 0) n = 1;
            n = @min(n, width - taken);
            cells_of[i] = n;
            taken += n;
        };
        for (parts, 0..) |p, i| self.marks(cells_of[i], p.fg, if (i == 0 or self.color) m.full else m.empty);
        self.marks(width - taken, dim, m.empty);
    }
};

const Part = struct { value: f64, fg: []const u8 };

const Frame = struct {
    w: *std.Io.Writer,
    cols: usize,
    rows: usize,
    color: bool,
    /// Lines end in newlines, without cursor movement or erasing, for a
    /// snapshot.
    plain: bool = false,
    line: usize = 0,

    fn begin(self: *const Frame) Line {
        return .{ .cols = self.cols, .color = self.color };
    }

    fn put(self: *Frame, l: *const Line) !void {
        if (self.line >= self.rows) return;
        if (self.plain) {
            try self.w.writeAll(std.mem.trimEnd(u8, l.buf[0..l.len], " "));
            if (self.color) try self.w.writeAll(reset);
            try self.w.writeAll("\n");
            self.line += 1;
            return;
        }
        if (self.line > 0) try self.w.writeAll("\r\n");
        try self.w.writeAll(l.buf[0..l.len]);
        if (self.color) try self.w.writeAll(reset);
        try self.w.writeAll("\x1b[K");
        self.line += 1;
    }

    /// Puts a line already written in the run log's styles, cut to the
    /// width with the `more` mark.
    fn putRaw(self: *Frame, s: log.Style, text: []const u8) !void {
        var l = self.begin();
        var b: std.Io.Writer = .fixed(&l.buf);
        if (self.cols > 1 and log.visible(text) > self.cols - 1) {
            log.clipped(&b, s, text, self.cols - 2) catch {};
            b.writeAll(s.marks.more) catch {};
        } else b.writeAll(text) catch {};
        l.len = b.buffered().len;
        try self.put(&l);
    }

    fn blank(self: *Frame) !void {
        var l = self.begin();
        try self.put(&l);
    }

    fn finish(self: *Frame) !void {
        if (!self.plain) try self.w.writeAll("\x1b[J");
    }
};

fn tickLabel(buf: []u8, s: u64) []const u8 {
    const r = if (s == 0)
        std.fmt.bufPrint(buf, "0", .{})
    else if (s < 60)
        std.fmt.bufPrint(buf, "{d}s", .{s})
    else if (s < 3600 and s % 60 == 0)
        std.fmt.bufPrint(buf, "{d}m", .{s / 60})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m{d}s", .{ s / 60, s % 60 })
    else if (s % 3600 == 0)
        std.fmt.bufPrint(buf, "{d}h", .{s / 3600})
    else
        std.fmt.bufPrint(buf, "{d}h{d}m", .{ s / 3600, s / 60 % 60 });
    return r catch "";
}

/// A rule's state as the view shows it: a tag in the run log's style and
/// its color. `WAIT` covers a rule whose producers have yet to end and one
/// that waits for room in the budget; its note says which.
const State = struct { tag: []const u8, tint: []const u8 };

fn state(s: Status) State {
    return switch (s) {
        .running => .{ .tag = "RUN", .tint = cyan },
        .cancelling => .{ .tag = "STOP", .tint = magenta },
        .retrying => .{ .tag = "RETRY", .tint = yellow },
        .waiting => .{ .tag = "WAIT", .tint = yellow },
        .pending => .{ .tag = "WAIT", .tint = dim },
        .completed => .{ .tag = "DONE", .tint = green },
        .reused => .{ .tag = "REUSE", .tint = "\x1b[32;2m" },
        .failed => .{ .tag = "FAIL", .tint = "\x1b[31;1m" },
        .blocked => .{ .tag = "BLOCK", .tint = red },
        .cancelled => .{ .tag = "STOP", .tint = magenta },
    };
}

fn seconds(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

fn duration(buf: []u8, s: f64) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    units.duration(&w, s) catch {};
    return w.buffered();
}

fn size(buf: []u8, bytes: u64) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    units.size(&w, @as(f64, @floatFromInt(bytes)) / 1048576.0) catch {};
    return w.buffered();
}

/// The rule's step and sample word, or its name when the launch's names
/// are not known.
fn wordOf(t: *const Tracker, name: []const u8) []const u8 {
    const i = t.index.get(name) orelse return name;
    return t.rules.items[i].shown;
}

/// The run log's table for the view's rows: the same columns, as wide as
/// the launch's rules need, held to their largest request (else the
/// budget's) and the budget's thread count so that they never move while
/// the launch runs. A row is the selection mark and the tag, then the log's
/// name columns and figures; on a terminal the names narrow to fit, and the
/// figures stay while the note keeps a dozen columns.
fn styleOf(t: *const Tracker, ui: *const Ui, cols: usize) log.Style {
    var w: naming.Widths = .{ .step = 0, .sample = 0 };
    for (t.rules.items) |r| {
        w.step = @max(w.step, naming.columns(r.step));
        w.sample = @max(w.sample, naming.columns(r.sample));
        w.tool = @max(w.tool, naming.columns(r.tool));
    }
    const largest = if (t.names) |n| (if (n.max_request_mib > 0) n.max_request_mib else t.max_memory_mib) else t.max_memory_mib;
    const budget = [_]u64{largest};
    const threads: u32 = @intCast(@max(t.max_threads, 1));
    var table = log.Table.of(t.selected, w, &budget, threads);
    if (!t.isolated) table = table.unbounded();
    if (cols > 0 and rowWidth(table) + note_room > cols) {
        table = log.Table.of(t.selected, w.capped(), &budget, threads);
        if (!t.isolated) table = table.unbounded();
    }
    if (cols > 0) {
        table.figures = rowWidth(table) + note_room <= cols;
        table = table.fitted(cols + table.nameColumn() - lead_width);
    }
    return .{ .color = ui.color, .marks = ui.marks, .table = table, .cols = cols };
}

const lead_width = 2 + log.status_width + log.gap.len;
const note_room = 12;

fn rowWidth(table: log.Table) usize {
    return table.width() - table.nameColumn() + lead_width;
}

fn drawHeader(f: *Frame, t: *const Tracker, ui: *const Ui, end_ns: i128) !void {
    var tb: [32]u8 = undefined;
    const run_state = if (t.finished) t.final_status else "running";
    const elapsed = if (t.started_ns == 0) "-" else duration(&tb, seconds(end_ns - t.started_ns));
    var engine_words = std.mem.tokenizeScalar(u8, t.engine, ' ');
    const program = engine_words.next() orelse "kanit";
    const version = engine_words.next() orelse "";
    const name = if (t.workflow_name.len > 0) t.workflow_name else t.workdir_name;

    var l = f.begin();
    if (!f.plain) l.sgr(reverse ++ bold);
    l.print(" {s}{s}{s} ", .{ program, if (version.len > 0) " " else "", version });
    l.sgr(reset);
    if (!f.plain) l.sgr(reverse);
    if (name.len > 0) l.print("  {s}  ", .{name}) else l.text(" ");
    if (f.cols >= 70) l.print(" launch {s} ", .{t.launch});
    const right = run_state.len + elapsed.len + 5;
    if (f.cols > l.used + right) l.spaces(f.cols - l.used - right);
    l.sgr(reset);
    l.sgr(if (std.mem.eql(u8, run_state, "running")) "\x1b[46;30;1m" else if (std.mem.eql(u8, run_state, "completed")) "\x1b[42;30;1m" else if (std.mem.eql(u8, run_state, "interrupted") or std.mem.eql(u8, run_state, "stopped")) "\x1b[45;30;1m" else "\x1b[41;97;1m");
    l.print(" {s} ", .{run_state});
    l.sgr(reset);
    if (!f.plain) l.sgr(reverse);
    l.print(" {s} ", .{elapsed});
    if (!f.plain) l.to(f.cols);
    try f.put(&l);

    const bar_w = std.math.clamp(f.cols -| 80, 12, 40);
    const done = t.count(.completed) + t.count(.reused);
    const running = t.count(.running) + t.count(.cancelling) + t.count(.retrying);
    const waiting = t.count(.waiting) + t.count(.pending);
    const failed = t.count(.failed);
    const blocked = t.count(.blocked);
    const stopped = t.count(.cancelled);
    l = f.begin();
    gaugeLabel(&l, "rules");
    l.bar(ui.marks, bar_w, @floatFromInt(@max(t.selected, 1)), &.{
        .{ .value = @floatFromInt(done), .fg = green },
        .{ .value = @floatFromInt(running), .fg = cyan },
        .{ .value = @floatFromInt(failed + blocked + stopped), .fg = red },
    });
    l.print("  {d} of {d} done", .{ done, t.selected });
    const counts = [_]struct { n: usize, what: []const u8, fg: []const u8 }{
        .{ .n = running, .what = "running", .fg = cyan },
        .{ .n = waiting, .what = "waiting", .fg = yellow },
        .{ .n = failed, .what = "failed", .fg = red ++ bold },
        .{ .n = blocked, .what = "blocked", .fg = red },
        .{ .n = stopped, .what = "stopped", .fg = magenta },
    };
    for (counts) |c| if (c.n > 0) {
        l.text("   ");
        l.sgr(c.fg);
        l.print("{d} {s}", .{ c.n, c.what });
        l.sgr(reset);
    };
    try f.put(&l);

    const res = t.reserved();
    const reserved_th: f64 = @floatFromInt(res.threads);
    const cores: ?f64 = if (t.finished) null else t.cpu_cores;
    const in_use: ?u64 = if (t.finished) null else t.memory_current;
    const busy = @min(cores orelse 0, reserved_th);
    l = f.begin();
    gaugeLabel(&l, "threads");
    l.bar(ui.marks, bar_w, @floatFromInt(@max(t.max_threads, 1)), &.{
        .{ .value = busy, .fg = cyan },
        .{ .value = reserved_th - busy, .fg = blue },
    });
    l.print("  {d} of {d} reserved", .{ res.threads, t.max_threads });
    if (cores) |c| l.print("   {d:.1} cores busy", .{c});
    try f.put(&l);

    const mib: f64 = 1 << 20;
    const reserved_b: f64 = @as(f64, @floatFromInt(res.memory_mib)) * mib;
    const used_b: f64 = if (in_use) |m| @floatFromInt(m) else 0;
    var mb: [3][24]u8 = undefined;
    l = f.begin();
    gaugeLabel(&l, "memory");
    l.bar(ui.marks, bar_w, @as(f64, @floatFromInt(@max(t.max_memory_mib, 1))) * mib, &.{
        .{ .value = @min(used_b, @max(reserved_b, used_b)), .fg = cyan },
        .{ .value = reserved_b - @min(used_b, reserved_b), .fg = blue },
    });
    l.print("  {s} of {s} reserved", .{ if (res.memory_mib == 0) "0" else size(&mb[0], res.memory_mib << 20), size(&mb[1], t.max_memory_mib << 20) });
    if (in_use) |m| l.print("   {s} in use", .{size(&mb[2], m)});
    try f.put(&l);

    for (t.shared.items, 0..) |sh, i| {
        l = f.begin();
        gaugeLabel(&l, if (i == 0) "shared" else "");
        l.sgr(bold);
        l.text(sh.name);
        l.sgr(reset);
        l.text("   ");
        const held = std.mem.eql(u8, sh.state, "loading") or std.mem.eql(u8, sh.state, "ready");
        l.sgr(if (std.mem.eql(u8, sh.state, "ready")) green else if (std.mem.eql(u8, sh.state, "loading")) yellow else if (std.mem.eql(u8, sh.state, "failed")) red else dim);
        l.text(sh.state);
        l.sgr(reset);
        const amount: ?u64 = if (held) sh.live_memory orelse sh.memory_peak else sh.memory_peak;
        if (amount) |m| l.print("   {s} {s}", .{ size(&mb[0], m), if (held) "held" else "peak" });
        if (sh.users.items.len > 0) l.print(", used by {d} {s}", .{ sh.users.items.len, if (sh.users.items.len == 1) "rule" else "rules" });
        try f.put(&l);
    }
    if (t.unreadable_lines > 0) {
        l = f.begin();
        gaugeLabel(&l, "");
        l.sgr(yellow);
        l.print("{d} {s} of events.jsonl could not be read and {s} left out", .{ t.unreadable_lines, if (t.unreadable_lines == 1) "line" else "lines", if (t.unreadable_lines == 1) "is" else "are" });
        try f.put(&l);
    }
    if (t.final_error.len > 0) {
        l = f.begin();
        l.sgr(red ++ bold);
        l.print(" {s}", .{t.final_error});
        try f.put(&l);
    }
}

fn gaugeLabel(l: *Line, name: []const u8) void {
    l.sgr(dim);
    l.text(" ");
    l.field(name, 9, false);
    l.sgr(reset);
}

/// How far each step is, from the rules the launch selected.
fn progressOf(a: Allocator, t: *const Tracker, now_ns: i128) !?log.Progress {
    const n = t.names orelse return null;
    if (n.steps.len == 0) return null;
    const steps = try a.alloc(log.StepProgress, n.steps.len);
    for (steps, n.steps) |*st, ns| st.* = .{ .name = ns.name, .tool = ns.tool orelse "", .selected = 0, .done = 0, .failed = 0, .running = 0, .ended = false };
    var samples = false;
    for (t.rules.items) |r| {
        const k = r.step_index orelse continue;
        samples = samples or r.sample.len > 0;
        const st = &steps[k];
        st.selected += 1;
        switch (r.status) {
            .completed, .reused => st.done += 1,
            .failed => st.failed += 1,
            .blocked => st.blocked += 1,
            .cancelled => st.stopped += 1,
            .running, .cancelling, .retrying => st.running += 1,
            else => {},
        }
    }
    var shown: std.ArrayList(log.StepProgress) = .empty;
    for (steps) |*st| if (st.selected > 0) {
        if (st.tool.len == 0) for (t.rules.items) |r| if (r.step_index != null and &steps[r.step_index.?] == st and r.tool.len > 0) {
            st.tool = r.tool;
            break;
        };
        st.ended = st.done + st.failed + st.blocked + st.stopped == st.selected;
        try shown.append(a, st.*);
    };
    return .{
        .selected = t.selected,
        .done = t.count(.completed) + t.count(.reused),
        .running = t.count(.running) + t.count(.cancelling) + t.count(.retrying),
        .failed = t.count(.failed),
        .blocked = t.count(.blocked),
        .cancelled = t.count(.cancelled),
        .elapsed_s = if (t.started_ns > 0) seconds(now_ns - t.started_ns) else 0,
        .steps = shown.items,
        .grouped = shown.items.len < t.rules.items.len or samples,
        .running_list = &.{},
    };
}

/// The table of the steps, under the rule table's tool and step columns,
/// at most `room` rows; returns the rows written.
fn drawSteps(a: Allocator, f: *Frame, t: *const Tracker, s: log.Style, room: usize, now_ns: i128) !usize {
    const p = (try progressOf(a, t, now_ns)) orelse return 0;
    if (!p.grouped) return 0;
    var out: std.Io.Writer.Allocating = .init(a);
    _ = try log.stepTable(&out.writer, s, p, lead_width, room, null);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    while (it.next()) |line| {
        try f.putRaw(s, line);
        lines += 1;
    }
    return lines;
}

fn drawTable(gpa: Allocator, a: Allocator, f: *Frame, t: *const Tracker, ui: *const Ui, s: log.Style, list: []const usize, page: usize, now_ns: i128, live: bool) !void {
    var head: std.Io.Writer.Allocating = .init(a);
    try head.writer.writeAll(s.on(bold));
    try head.writer.writeAll("  ");
    try log.pad(&head.writer, "STATUS", log.status_width);
    try head.writer.writeAll(log.gap);
    try log.whoHeader(&head.writer, s);
    try log.figureHeader(&head.writer, s);
    try head.writer.print("NOTE{s}", .{s.off()});
    try f.putRaw(s, head.written());
    const end = @min(ui.top + page, list.len);
    for (list[ui.top..end]) |ri| {
        const selected = !f.plain and ui.selected != null and ui.selected.? == ri;
        var row: std.Io.Writer.Allocating = .init(a);
        try ruleRow(gpa, a, &row.writer, t, &ui.links, s, ri, selected, now_ns, live);
        try f.putRaw(s, row.written());
    }
    if (list.len == 0) {
        var l = f.begin();
        l.sgr(dim);
        l.text(if (ui.query_len > 0) "  no rule name contains the search" else "  no rules in this view");
        try f.put(&l);
    }
}

/// One rule's row: the selection mark, its tag, the run log's name columns
/// and figures, and a note. A selected row is drawn in
/// reverse video, without the colors of its cells.
fn ruleRow(gpa: Allocator, a: Allocator, w: *std.Io.Writer, t: *const Tracker, links: *const Links, s0: log.Style, ri: usize, selected: bool, now_ns: i128, live: bool) !void {
    const r = &t.rules.items[ri];
    const st = state(r.status);
    var s = s0;
    if (selected) {
        s.color = false;
        if (s0.color) try w.writeAll(reverse);
        try w.writeAll("> ");
    } else try w.writeAll("  ");
    try w.writeAll(s.on(st.tint));
    try log.pad(w, st.tag, log.status_width);
    try w.print("{s}{s}", .{ s.off(), log.gap });
    if (r.status == .pending) try w.writeAll(s.on(dim));
    try log.whoCells(w, s, .{ .tool = r.tool, .step = r.step, .sample = r.sample });
    try w.writeAll(s.off());
    try log.figureCells(w, s, figuresOf(r, now_ns));
    try note(gpa, a, w, t, links, s, r, now_ns, live);
    if (selected and s0.color) try w.writeAll(reset);
}

fn figuresOf(r: *const RuleView, now_ns: i128) log.Figures {
    var f: log.Figures = .{};
    if (r.status == .waiting or r.status == .pending) return f;
    const active = r.status.active() or r.status == .retrying;
    if (r.started_ns > 0) {
        if (active) f.took_s = seconds(now_ns - r.started_ns) else if (r.finished_ns > 0) f.took_s = r.wall_s orelse seconds(r.finished_ns - r.started_ns);
    }
    if (r.memory_mib > 0 and r.started_ns > 0) f.request_mib = r.memory_mib;
    const mem: ?u64 = if (active) r.live_memory else r.memory_peak;
    if (mem) |m| f.used_mib = @as(f64, @floatFromInt(m)) / 1048576.0;
    if (r.threads > 0 and r.started_ns > 0) f.threads = r.threads;
    if (active) f.cores = r.live_cores else if (r.cpu_s) |cpu| if (f.took_s) |took| if (took >= 0.1) {
        f.cores = cpu / took;
    };
    return f;
}

/// What a row says after its figures: the attempt of a rule tried more
/// than once, the last line a running rule wrote, what a waiting rule
/// waits for, and why a rule failed, was blocked or was stopped.
fn note(gpa: Allocator, a: Allocator, w: *std.Io.Writer, t: *const Tracker, links: *const Links, s: log.Style, r: *const RuleView, now_ns: i128, live: bool) !void {
    var buf: [32]u8 = undefined;
    switch (r.status) {
        .running => {
            const last = if (live) monitor.lastOutput(gpa, a, r.dir, 200) else "";
            if (r.attempt > 1) try w.print("attempt {d}{s}", .{ r.attempt, if (last.len > 0) ": " else "" });
            try w.print("{s}{s}{s}", .{ s.on(dim), last, s.off() });
        },
        .completed => if (r.attempt > 1) try w.print("after {d} attempts", .{r.attempt}),
        .cancelling => try w.writeAll("stopping"),
        .waiting => {
            const why = if (std.mem.startsWith(u8, r.reason, "group:")) r.reason["group:".len..] else r.reason;
            if (r.attempt > 0) try w.print("attempt {d}, ", .{r.attempt + 1});
            try w.print("{s}for {s}{s}", .{ s.on(yellow), if (why.len > 0) why else "room", s.off() });
            const since = @max(r.ready_ns, r.finished_ns);
            if (since > 0) try w.print(", {s}", .{duration(&buf, seconds(now_ns - since))});
        },
        .pending => if (firstUnfinished(t, links, r.name)) |p| {
            try w.print("{s}after {s}{s}", .{ s.on(dim), p, s.off() });
        },
        .blocked => {
            if (cause(t, links, r.name, 0)) |c| try w.print("after {s} {s}", .{ c.word, c.what }) else try w.writeAll("after a rule it needs did not complete");
        },
        .failed, .retrying => try w.print("{s}{s}{s}", .{ s.on(red), r.reason, s.off() }),
        .cancelled => try w.writeAll(if (std.mem.startsWith(u8, r.reason, "cancelled: ")) r.reason["cancelled: ".len..] else r.reason),
        else => {},
    }
}

fn firstUnfinished(t: *const Tracker, links: *const Links, name: []const u8) ?[]const u8 {
    const parents = links.after.get(name) orelse return null;
    for (parents) |p| {
        const i = t.index.get(p) orelse continue;
        if (!t.rules.items[i].status.done()) return t.rules.items[i].shown;
    }
    return null;
}

const Cause = struct { word: []const u8, what: []const u8 };

/// The failure at the root of a blocked rule's chain, as the run log
/// names it.
fn cause(t: *const Tracker, links: *const Links, name: []const u8, depth: usize) ?Cause {
    if (depth > 64) return null;
    const parents = links.after.get(name) orelse return null;
    for (parents) |p| {
        const i = t.index.get(p) orelse continue;
        const pr = &t.rules.items[i];
        switch (pr.status) {
            .failed => return .{ .word = pr.shown, .what = "failed" },
            .cancelled => return .{ .word = pr.shown, .what = "was stopped" },
            .blocked => if (cause(t, links, p, depth + 1)) |c| return c,
            else => {},
        }
    }
    return null;
}

pub fn draw(gpa: Allocator, w: *std.Io.Writer, t: *const Tracker, ui: *Ui, cols: usize, rows: usize, now_ns: i128, live: bool) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Frame = .{ .w = w, .cols = cols, .rows = rows, .color = ui.color };
    try w.writeAll("\x1b[H");
    const end_ns = if (t.finished) t.finished_ns else now_ns;
    try drawHeader(&f, t, ui, end_ns);
    if (rows >= 24) try f.blank();
    const s = styleOf(t, ui, cols);
    if (ui.mode == .table and rows >= 16) {
        if (try drawSteps(a, &f, t, s, @max(rows / 3, 4), now_ns) > 0 and rows >= 24) try f.blank();
    }

    const list = try visible(a, t, ui.filter, ui.sort, ui.queryText(), now_ns);
    const footer = 1;
    const head = f.line + 1;
    const page = rows -| (head + footer);
    ui.page = page;
    ui.settle(list, page);
    const space = rows -| (f.line + footer);
    switch (ui.mode) {
        .table => try drawTable(gpa, a, &f, t, ui, s, list, page, now_ns, live),
        .timeline => try drawTimeline(&f, t, ui, list, page, end_ns),
        .log => try drawLog(gpa, a, &f, t, ui, space, live),
        .details => try drawDetails(gpa, a, &f, t, ui, space, now_ns, live),
        .help => try drawHelp(&f, space),
    }
    while (f.line < rows -| footer) try f.blank();
    try drawFooter(&f, ui, now_ns);
    try f.finish();
}

/// Writes the view once as text: the header, the steps and every rule,
/// for `watch --once` and a watch whose output is not a terminal. `links`
/// are the launch's, loaded once by the caller (`Late`).
pub fn snapshot(gpa: Allocator, w: *std.Io.Writer, t: *Tracker, links: *const Links, cols: usize, color: bool, marks: *const log.Marks, now_ns: i128) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var sampler: Sampler = .{};
    sampler.sample(gpa, t, sys.monoNs());
    var ui: Ui = .{ .color = color, .marks = marks, .links = links.* };
    var f: Frame = .{ .w = w, .cols = cols, .rows = std.math.maxInt(usize), .color = color, .plain = true };
    const end_ns = if (t.finished) t.finished_ns else now_ns;
    try drawHeader(&f, t, &ui, end_ns);
    try f.blank();
    const s = styleOf(t, &ui, cols);
    if (try drawSteps(a, &f, t, s, std.math.maxInt(usize), now_ns) > 0) try f.blank();
    const list = try visible(a, t, .all, .status, "", now_ns);
    try drawTable(gpa, a, &f, t, &ui, s, list, list.len, now_ns, true);
}

fn drawTimeline(f: *Frame, t: *const Tracker, ui: *Ui, list: []const usize, page: usize, end_ns: i128) !void {
    const name_w = std.math.clamp(f.cols / 4, 10, 32);
    const axis_w = f.cols -| (2 + name_w + 1);
    const origin = if (t.started_ns != 0) t.started_ns else end_ns;
    const span: i128 = @max(end_ns - origin, std.time.ns_per_s);
    const span_s: u64 = @intCast(@divFloor(span + std.time.ns_per_s - 1, std.time.ns_per_s));
    const steps = [_]u64{ 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 86400 };
    const max_ticks = @max(axis_w / 10, 1);
    const step = for (steps) |s| {
        if (span_s / s <= max_ticks) break s;
    } else 86400;
    const col = struct {
        fn at(ns: i128, start: i128, sp: i128, w: usize) usize {
            if (ns <= start or w == 0) return 0;
            const x: usize = @intCast(@divFloor((ns - start) * @as(i128, @intCast(w)), sp));
            return @min(x, w - 1);
        }
    }.at;

    var l = f.begin();
    l.sgr(bold);
    l.text("  ");
    l.field("RULE", name_w, false);
    l.text(" ");
    l.sgr(reset ++ dim);
    var tb: [16]u8 = undefined;
    var tick: u64 = 0;
    const base = l.used;
    while (tick <= span_s) : (tick += step) {
        const x = base + col(origin + @as(i128, tick) * std.time.ns_per_s, origin, span, axis_w);
        const label = tickLabel(&tb, tick);
        if (x < l.used or x + label.len > f.cols) continue;
        l.to(x);
        l.text(label);
    }
    try f.put(&l);

    const end = @min(ui.top + page, list.len);
    for (list[ui.top..end]) |ri| {
        const r = &t.rules.items[ri];
        const selected = ui.selected != null and ui.selected.? == ri;
        l = f.begin();
        if (selected) {
            l.sgr(cyan ++ bold);
            l.text("> ");
            l.sgr(reset);
        } else l.text("  ");
        l.sgr(if (selected) reverse else if (r.status == .pending) dim else state(r.status).tint);
        l.name(r.shown, name_w);
        l.sgr(reset);
        l.text(" ");
        var x: usize = 0;
        const ready_at = if (r.ready_ns > 0) col(r.ready_ns, origin, span, axis_w) else axis_w;
        const start_at = if (r.started_ns > 0) col(r.started_ns, origin, span, axis_w) else axis_w;
        const stop_at = if (r.started_ns > 0) col(if (r.finished_ns > 0) r.finished_ns else end_ns, origin, span, axis_w) + 1 else axis_w;
        if (ready_at > 0) l.spaces(@min(ready_at, axis_w));
        x = @min(ready_at, axis_w);
        if (start_at > x) {
            l.sgr(dim ++ yellow);
            var i = x;
            while (i < start_at) : (i += 1) l.text(".");
            l.sgr(reset);
            x = start_at;
        }
        if (r.started_ns > 0 and stop_at > x) {
            const bg: []const u8 = switch (r.status) {
                .failed, .blocked => on_red,
                .cancelled, .cancelling => on_magenta,
                .running, .retrying => on_cyan,
                else => on_green,
            };
            const ch: u8 = switch (r.status) {
                .failed, .blocked => '!',
                .cancelled, .cancelling => 'x',
                .running, .retrying => '>',
                else => '=',
            };
            l.cells(@min(stop_at, axis_w) - x, bg, ch);
        }
        try f.put(&l);
    }
}

fn drawDetails(gpa: Allocator, a: Allocator, f: *Frame, t: *const Tracker, ui: *Ui, space: usize, now_ns: i128, live: bool) !void {
    const ri = ui.selected orelse return;
    const r = &t.rules.items[ri];
    const st = state(r.status);
    var b: [4][32]u8 = undefined;
    var l = f.begin();
    l.sgr(bold);
    l.print("  {s}", .{r.shown});
    l.sgr(reset);
    l.text("   ");
    l.sgr(st.tint);
    l.text(st.tag);
    l.sgr(reset);
    if (r.attempt > 0) l.print("   attempt {d}", .{r.attempt});
    try f.put(&l);
    l = f.begin();
    l.sgr(dim);
    l.text("  ");
    l.marks(f.cols -| 4, dim, ui.marks.empty);
    try f.put(&l);

    const Row = struct {
        fn label(line: *Line, name: []const u8) void {
            line.sgr(dim);
            line.text("  ");
            line.field(name, 12, false);
            line.sgr(reset);
        }
    };
    if (r.tool.len > 0) {
        l = f.begin();
        Row.label(&l, "tool");
        l.text(r.tool);
        try f.put(&l);
    }
    if (r.reason.len > 0) {
        l = f.begin();
        Row.label(&l, if (r.status == .waiting) "waits for" else "reason");
        l.sgr(if (r.status == .failed) red else yellow);
        l.text(r.reason);
        try f.put(&l);
    }
    if (r.threads > 0) {
        l = f.begin();
        Row.label(&l, "request");
        l.print("{d} {s}, {s}", .{ r.threads, if (r.threads == 1) "thread" else "threads", size(&b[0], r.memory_mib << 20) });
        try f.put(&l);
    }
    for ([_]struct { []const u8, ?[]const []const u8 }{
        .{ "after", ui.links.after.get(r.name) },
        .{ "before", ui.links.before.get(r.name) },
        .{ "shared", if (r.shared.len > 0) r.shared else null },
    }) |row| {
        const names = row[1] orelse continue;
        if (names.len == 0) continue;
        l = f.begin();
        Row.label(&l, row[0]);
        const words = std.mem.eql(u8, row[0], "shared");
        for (names, 0..) |n, k| l.print("{s}{s}", .{ if (k == 0) "" else ", ", if (words) n else wordOf(t, n) });
        try f.put(&l);
    }
    if (r.ready_ns > 0) {
        l = f.begin();
        Row.label(&l, "ready");
        l.print("{s} after the launch started", .{duration(&b[0], seconds(r.ready_ns - t.started_ns))});
        try f.put(&l);
    }
    if (r.started_ns > 0) {
        l = f.begin();
        Row.label(&l, "started");
        l.print("{s} after the launch started; {s} {s}", .{ duration(&b[0], seconds(r.started_ns - t.started_ns)), if (r.finished_ns > 0) "ran for" else "running for", duration(&b[1], seconds(elapsedOf(r, now_ns))) });
        try f.put(&l);
    }
    const gauge_w = std.math.clamp(f.cols / 4, 10, 30);
    if (r.status.active()) {
        const counters: ?cgroup.Counters = if (live) (if (r.cg) |cg| cgroup.read(gpa, cg) else null) else null;
        if (r.live_cores) |cores| {
            l = f.begin();
            Row.label(&l, "cpu");
            l.bar(ui.marks, gauge_w, @floatFromInt(@max(r.threads, 1)), &.{.{ .value = cores, .fg = cyan }});
            l.print("  {d:.1} of {d} {s}", .{ cores, r.threads, if (r.threads == 1) "thread" else "threads" });
            if (counters) |cn| if (cn.cpu_usage_usec) |us| l.print(", {s} so far", .{duration(&b[0], @as(f64, @floatFromInt(us)) / 1e6)});
            try f.put(&l);
        }
        if (r.live_memory) |m| {
            const limit: f64 = @floatFromInt(@max(r.memory_mib << 20, 1));
            const ratio = @as(f64, @floatFromInt(m)) / limit;
            l = f.begin();
            Row.label(&l, "memory");
            l.bar(ui.marks, gauge_w, limit, &.{.{ .value = @floatFromInt(m), .fg = if (ratio >= 0.9) red else if (ratio >= 0.7) yellow else green }});
            l.print("  {s} now", .{size(&b[0], m)});
            if (r.live_peak) |p| l.print(", {s} peak", .{size(&b[1], p)});
            l.print(", of {s}", .{size(&b[2], r.memory_mib << 20)});
            if (counters) |cn| if (cn.memory_max_events > 0) {
                l.sgr(yellow);
                l.print(" ({d} times at its limit)", .{cn.memory_max_events});
            };
            try f.put(&l);
        }
        if (counters) |cn| {
            const sec = struct {
                fn of(v: ?u64) f64 {
                    return @as(f64, @floatFromInt(v orelse 0)) / 1e6;
                }
            }.of;
            l = f.begin();
            Row.label(&l, "stalled");
            l.print("cpu {s}, memory {s}, I/O {s}", .{ duration(&b[0], sec(cn.cpu_some_us)), duration(&b[1], sec(cn.memory_some_us)), duration(&b[2], sec(cn.io_some_us)) });
            try f.put(&l);
        }
    } else {
        if (r.cpu_s) |cpu| {
            l = f.begin();
            Row.label(&l, "cpu");
            l.text(duration(&b[0], cpu));
            if (r.finished_ns > r.started_ns) l.print(", {d:.1} of {d} {s} on average", .{ cpu / seconds(r.finished_ns - r.started_ns), r.threads, if (r.threads == 1) "thread" else "threads" });
            try f.put(&l);
        }
        if (r.memory_peak) |m| {
            l = f.begin();
            Row.label(&l, "memory");
            l.print("{s} peak", .{size(&b[0], m)});
            if (r.memory_mib > 0) l.print(" of {s}", .{size(&b[1], r.memory_mib << 20)});
            try f.put(&l);
        }
    }
    if (r.dir.len > 0) {
        l = f.begin();
        Row.label(&l, "files");
        l.text(monitor.shownPath(a, r.dir));
        try f.put(&l);
    }
    if (r.cg) |cg| if (r.status.active()) {
        l = f.begin();
        Row.label(&l, "cgroup");
        l.text(cg);
        try f.put(&l);
    };
    if (!live or r.dir.len == 0 or f.line + 3 >= space) return;
    try f.blank();
    l = f.begin();
    l.sgr(bold);
    l.text("  last output");
    try f.put(&l);
    const tail = sys.readTail(gpa, try std.fs.path.join(a, &.{ r.dir, if (ui.stderr) "stderr.log" else "stdout.log" }), 4096) catch return;
    defer gpa.free(tail);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, tail, "\n"), '\n');
    while (it.next()) |line| try lines.append(a, line);
    const room = space -| f.line;
    for (lines.items[lines.items.len -| room..]) |line| {
        l = f.begin();
        l.text("    ");
        logLine(&l, line);
        try f.put(&l);
    }
}

fn logLine(l: *Line, line: []const u8) void {
    var low: [256]u8 = undefined;
    const n = @min(line.len, low.len);
    for (line[0..n], 0..) |c, i| low[i] = std.ascii.toLower(c);
    const lowered = low[0..n];
    if (std.mem.indexOf(u8, lowered, "error") != null or std.mem.indexOf(u8, lowered, "fatal") != null) {
        l.sgr(red);
    } else if (std.mem.indexOf(u8, lowered, "warn") != null) l.sgr(yellow);
    l.text(line);
    l.sgr(reset);
}

fn drawLog(gpa: Allocator, a: Allocator, f: *Frame, t: *const Tracker, ui: *Ui, space: usize, live: bool) !void {
    const ri = ui.selected orelse return;
    const r = &t.rules.items[ri];
    const stream = if (ui.stderr) "stderr" else "stdout";
    var l = f.begin();
    l.sgr(reverse ++ bold);
    l.print(" {s} ", .{r.shown});
    l.sgr(reset ++ reverse);
    l.print(" attempt {d}  {s}  {s} ", .{ r.attempt, state(r.status).tag, stream });
    l.sgr(reset);
    l.sgr(dim);
    l.print("  o: {s}", .{if (ui.stderr) "stdout" else "stderr"});
    try f.put(&l);
    if (r.dir.len == 0) {
        l = f.begin();
        l.sgr(dim);
        l.text("  not started yet");
        return f.put(&l);
    }
    if (!live) return;
    const path = try std.fs.path.join(a, &.{ r.dir, try std.fmt.allocPrint(a, "{s}.log", .{stream}) });
    const want = space -| 1;
    const tail = sys.readTail(gpa, path, @min(want * (f.cols + 1) * 4 + 1, 1 << 20)) catch {
        l = f.begin();
        l.sgr(dim);
        l.print("  nothing on {s} yet", .{stream});
        return f.put(&l);
    };
    defer gpa.free(tail);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, tail, "\n"), '\n');
    while (it.next()) |line| try lines.append(a, line);
    if (lines.items.len == 1 and lines.items[0].len == 0) {
        l = f.begin();
        l.sgr(dim);
        l.print("  nothing on {s} yet", .{stream});
        return f.put(&l);
    }
    for (lines.items[lines.items.len -| want..]) |line| {
        l = f.begin();
        logLine(&l, line);
        try f.put(&l);
    }
}

const help_lines = [_][2][]const u8{
    .{ "", "Move" },
    .{ "j k  up down", "move the selection" },
    .{ "PgUp PgDn g G", "a page up or down, the first or last rule" },
    .{ "", "Views" },
    .{ "enter", "follow the selected rule's output; o switches stderr and stdout" },
    .{ "i", "details of the selected rule: request, times, live counters" },
    .{ "t", "timeline of the launch" },
    .{ "?", "these keys" },
    .{ "", "Filter, search and sort" },
    .{ "a r w f d", "all rules, or running, waiting, failed, done ones" },
    .{ "/", "search rule names; enter keeps the search, esc clears it" },
    .{ "s", "sort by status, elapsed time, peak memory or name" },
    .{ "", "Steer the launch" },
    .{ "S", "stop the selected rule" },
    .{ "R", "retry the selected rule" },
    .{ "X X", "cancel the launch (press twice)" },
    .{ "", "Leave" },
    .{ "q esc", "back to the table, or leave from it" },
    .{ "ctrl-c", "leave" },
};

fn drawHelp(f: *Frame, space: usize) !void {
    for (help_lines, 0..) |h, shown| {
        if (shown >= space) return;
        var l = f.begin();
        if (h[0].len == 0) {
            l.sgr(bold);
            l.print("  {s}", .{h[1]});
        } else {
            l.text("    ");
            l.sgr(cyan);
            l.field(h[0], 16, false);
            l.sgr(reset);
            l.clipped(h[1]);
        }
        try f.put(&l);
    }
}

fn drawFooter(f: *Frame, ui: *const Ui, now_ns: i128) !void {
    var l = f.begin();
    if (ui.typing) {
        l.sgr(reverse);
        l.print(" / {s}_ ", .{ui.queryText()});
        l.sgr(reset ++ dim);
        l.text("  enter keeps the search, esc clears it");
        return f.put(&l);
    }
    if (ui.message_len > 0 and now_ns < ui.message_until) {
        l.sgr(yellow ++ bold);
        l.print(" {s}", .{ui.message[0..ui.message_len]});
        return f.put(&l);
    }
    const Hint = struct { key: []const u8, what: []const u8 };
    const hints: []const Hint = switch (ui.mode) {
        .table => &.{ .{ .key = "q", .what = "quit" }, .{ .key = "?", .what = "keys" }, .{ .key = "enter", .what = "log" }, .{ .key = "i", .what = "details" }, .{ .key = "t", .what = "timeline" }, .{ .key = "S R X", .what = "stop retry cancel" }, .{ .key = "/", .what = "search" }, .{ .key = "s", .what = "sort" }, .{ .key = "a r w f d", .what = "filter" } },
        .timeline => &.{ .{ .key = "q", .what = "back" }, .{ .key = "?", .what = "keys" }, .{ .key = "j k", .what = "move" }, .{ .key = "enter", .what = "log" }, .{ .key = "t", .what = "table" } },
        .log => &.{ .{ .key = "q", .what = "back" }, .{ .key = "?", .what = "keys" }, .{ .key = "o", .what = "stdout/stderr" }, .{ .key = "j k", .what = "rule" } },
        .details => &.{ .{ .key = "q", .what = "back" }, .{ .key = "?", .what = "keys" }, .{ .key = "j k", .what = "rule" }, .{ .key = "enter", .what = "log" }, .{ .key = "S", .what = "stop" }, .{ .key = "R", .what = "retry" } },
        .help => &.{.{ .key = "q", .what = "back" }},
    };
    var sb: [128]u8 = undefined;
    const view = if (ui.query_len > 0)
        std.fmt.bufPrint(&sb, "{s} | {s} | \"{s}\" ", .{ @tagName(ui.filter), @tagName(ui.sort), ui.queryText() }) catch ""
    else
        std.fmt.bufPrint(&sb, "{s} | {s} ", .{ @tagName(ui.filter), @tagName(ui.sort) }) catch "";
    const room = f.cols -| (view.len + 1);
    l.text(" ");
    for (hints) |h| {
        if (l.used + h.key.len + h.what.len + 4 > room) break;
        l.sgr(reverse);
        if (!l.color) l.print("[{s}]", .{h.key}) else l.print(" {s} ", .{h.key});
        l.sgr(reset);
        l.print(" {s} ", .{h.what});
    }
    if (f.cols > l.used + view.len) {
        l.to(f.cols - view.len);
        l.sgr(dim);
        l.text(view);
    }
    try f.put(&l);
}

// --- Running the view ---

const Terminal = struct {
    saved: linux.termios,

    fn enter() !Terminal {
        var t: linux.termios = undefined;
        _ = try sys.check(linux.tcgetattr(0, &t));
        const saved = t;
        t.lflag.ECHO = false;
        t.lflag.ICANON = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.iflag.IXON = false;
        t.iflag.ICRNL = false;
        t.iflag.BRKINT = false;
        t.iflag.INPCK = false;
        t.iflag.ISTRIP = false;
        t.cc[@intFromEnum(linux.V.MIN)] = 1;
        t.cc[@intFromEnum(linux.V.TIME)] = 0;
        _ = try sys.check(linux.tcsetattr(0, .FLUSH, &t));
        sys.writeAll(1, "\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J") catch {};
        return .{ .saved = saved };
    }

    fn leave(self: *const Terminal) void {
        sys.writeAll(1, "\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        _ = linux.tcsetattr(0, .DRAIN, &self.saved);
    }
};

pub const Sampler = struct {
    run_cpu: ?u64 = null,
    run_ns: i128 = 0,

    pub fn sample(self: *Sampler, gpa: Allocator, t: *Tracker, now_ns: i128) void {
        for (t.rules.items) |*r| {
            if (!r.status.active()) continue;
            const cg = r.cg orelse continue;
            if (cgroup.readNumber(gpa, cg, "memory.current")) |m| r.live_memory = m;
            if (cgroup.readNumber(gpa, cg, "memory.peak")) |p| r.live_peak = p;
            if (cgroup.cpuUsage(gpa, cg)) |us| {
                if (r.live_cpu_usec) |last| if (now_ns > r.live_cpu_ns and us >= last) {
                    r.live_cores = @as(f64, @floatFromInt(us - last)) / (@as(f64, @floatFromInt(now_ns - r.live_cpu_ns)) / 1e3);
                };
                r.live_cpu_usec = us;
                r.live_cpu_ns = now_ns;
            }
        }
        for (t.shared.items) |*s| {
            const cg = s.cg orelse continue;
            if (cgroup.readNumber(gpa, cg, "memory.current")) |m| s.live_memory = m;
        }
        const cg = t.run_cg orelse return;
        if (t.finished) return;
        if (cgroup.readNumber(gpa, cg, "memory.current")) |m| t.memory_current = m;
        const cpu = cgroup.cpuUsage(gpa, cg) orelse return;
        if (self.run_cpu) |last| if (now_ns > self.run_ns and cpu >= last) {
            t.cpu_cores = @as(f64, @floatFromInt(cpu - last)) / (@as(f64, @floatFromInt(now_ns - self.run_ns)) / 1e3);
        };
        self.run_cpu = cpu;
        self.run_ns = now_ns;
    }
};

fn send(gpa: Allocator, t: *const Tracker, ui: *Ui, act: Action) void {
    var buf: [256]u8 = undefined;
    const name = if (act.rule) |ri| t.rules.items[ri].name else "";
    const line = (if (act.rule != null) std.fmt.bufPrint(&buf, "{s} {s}\n", .{ act.cmd, name }) else std.fmt.bufPrint(&buf, "{s}\n", .{act.cmd})) catch return;
    var said: [200]u8 = undefined;
    const path = std.fs.path.join(gpa, &.{ std.fs.path.dirname(t.events_path).?, "control" }) catch return;
    defer gpa.free(path);
    if (t.finished) return ui.say("the launch has ended", sys.realNs());
    const fd = sys.openWrite(gpa, path, .append) catch return ui.say("cannot open the control file", sys.realNs());
    defer sys.close(fd);
    sys.writeAll(fd, line) catch return;
    ui.say(std.fmt.bufPrint(&said, "sent: {s}", .{std.mem.trimEnd(u8, line, "\n")}) catch "sent", sys.realNs());
}

pub fn run(gpa: Allocator, t: *Tracker, late: *Late, interval_ms: u64, color: bool, marks: *const log.Marks) !bool {
    var set = linux.sigemptyset();
    for ([_]linux.SIG{ .INT, .TERM, .HUP, .WINCH }) |s| linux.sigaddset(&set, s);
    _ = try sys.check(linux.sigprocmask(linux.SIG.BLOCK, &set, null));
    const sigfd: sys.Fd = @intCast(try sys.check(linux.signalfd(-1, &set, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK)));
    defer sys.close(sigfd);

    const terminal = try Terminal.enter();
    defer terminal.leave();
    var ui: Ui = .{ .color = color, .marks = marks };
    const launch_dir = std.fs.path.dirname(t.events_path) orelse ".";
    ui.links = late.links;
    var sampler: Sampler = .{};
    var frame: std.Io.Writer.Allocating = .init(gpa);
    defer frame.deinit();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var input: [64]u8 = undefined;
    var pending: usize = 0;
    var next_ns = sys.monoNs();
    while (!ui.quit) {
        const now = sys.monoNs();
        if (now >= next_ns) {
            _ = try t.update();
            _ = try t.settleEnd();
            if (late.pending(t)) {
                late.read(gpa, t, launch_dir);
                ui.links = late.links;
            }
            sampler.sample(gpa, t, now);
            next_ns = now + @as(i128, interval_ms) * std.time.ns_per_ms;
        }
        const sz = term.size(1);
        frame.clearRetainingCapacity();
        try draw(gpa, &frame.writer, t, &ui, sz.cols, sz.rows, sys.realNs(), true);
        try sys.writeAll(1, frame.written());

        var fds = [_]linux.pollfd{
            .{ .fd = 0, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = sigfd, .events = linux.POLL.IN, .revents = 0 },
        };
        process.wait(&fds, next_ns);
        if (fds[1].revents != 0) {
            const seen = process.readSignals(sigfd);
            if (process.has(seen, .INT) or process.has(seen, .TERM) or process.has(seen, .HUP)) break;
        }
        if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) break;
        if (fds[0].revents & linux.POLL.IN != 0) {
            const n = sys.read(0, input[pending..]) catch break;
            if (n == 0) break;
            pending += n;
            _ = scratch.reset(.retain_capacity);
            ui.clock_ns = sys.realNs();
            const list = try visible(scratch.allocator(), t, ui.filter, ui.sort, ui.queryText(), ui.clock_ns);
            var at: usize = 0;
            while (at < pending) {
                var used: usize = 0;
                const k = decode(input[at..pending], &used);
                if (used == 0) {
                    if (at == 0 and pending == input.len) at = pending;
                    break;
                }
                at += used;
                if (k) |key| ui.key(key, list, ui.page);
                if (ui.action) |act| {
                    send(gpa, t, &ui, act);
                    ui.action = null;
                }
                if (ui.quit) break;
            }
            std.mem.copyForwards(u8, input[0 .. pending - at], input[at..pending]);
            pending -= at;
        }
    }
    return true;
}

/// The launch's facts, names and the links between its rules, which a view
/// loads once. A view that started before its launch wrote its records
/// reads them again on later refreshes: the facts until `launch.json` is
/// there, then the names and links for at most `max_tries` refreshes,
/// since a launch recorded by an older engine or with an unreadable
/// workflow never has them. A failed attempt keeps nothing.
pub const Late = struct {
    arena: ?std.heap.ArenaAllocator = null,
    names: naming.Names = undefined,
    links: Links = .{},
    tries: u32 = 0,

    const max_tries = 50;

    pub fn pending(self: *const Late, t: *const Tracker) bool {
        if (!t.launch_read) return true;
        return self.tries < max_tries and (t.names == null or self.links.after.count() == 0);
    }

    pub fn read(self: *Late, gpa: Allocator, t: *Tracker, launch_dir: []const u8) void {
        if (!t.launch_read and !t.readLaunch()) return;
        if (!self.pending(t)) return;
        self.tries += 1;
        if (self.arena) |*a| _ = a.reset(.free_all) else self.arena = std.heap.ArenaAllocator.init(gpa);
        const got = loadLaunch(gpa, self.arena.?.allocator(), launch_dir) catch return;
        if (got.names) |n| {
            self.names = n;
            t.applyNames(&self.names);
        }
        self.links = got.links;
    }

    pub fn deinit(self: *Late) void {
        if (self.arena) |*a| a.deinit();
    }
};

pub const Links = struct {
    after: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    before: std.StringHashMapUnmanaged([]const []const u8) = .empty,
};

pub fn loadLinks(gpa: Allocator, a: Allocator, launch_dir: []const u8) !Links {
    return (try loadLaunch(gpa, a, launch_dir)).links;
}

pub const Loaded = struct { names: ?naming.Names = null, links: Links = .{} };

/// The launch's names and the links between its rules, from one read of its
/// recorded workflow; none when the workflow cannot be read.
pub fn loadLaunch(gpa: Allocator, a: Allocator, launch_dir: []const u8) !Loaded {
    var out: Loaded = .{};
    var links: Links = .{};
    const info = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }), 1 << 20) catch return out;
    defer gpa.free(info);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, info, .{}) catch return out;
    const workdir = if (v == .object) (if (v.object.get("workdir")) |w| (if (w == .string) w.string else return out) else return out) else return out;
    var problem: workflow.Problem = .{};
    defer if (problem.message.len > 0) gpa.free(problem.message);
    var wf = workflow.loadRecorded(gpa, try std.fs.path.join(a, &.{ launch_dir, "workflow" }), workdir, &problem) catch return out;
    defer wf.deinit();
    out.names = naming.Names.init(a, wf.rules) catch null;
    var g = graph.build(gpa, &wf, &problem) catch return out;
    defer g.deinit();
    for (wf.rules, 0..) |r, i| {
        const name = try a.dupe(u8, r.name);
        for ([_]struct { []const usize, *std.StringHashMapUnmanaged([]const []const u8) }{ .{ g.parents[i], &links.after }, .{ g.children[i], &links.before } }) |pair| {
            const names = try a.alloc([]const u8, pair[0].len);
            for (pair[0], names) |j, *n| n.* = try a.dupe(u8, wf.rules[j].name);
            try pair[1].put(a, name, names);
        }
    }
    out.links = links;
    return out;
}
