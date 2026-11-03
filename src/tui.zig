//! Interactive `watch` on a terminal. A header shows the launch's progress
//! and its use of the budget; below it, one of five views: the table of
//! rules, a timeline, the details of one rule, its output as it grows, or
//! the keys. The terminal is put in raw mode on the alternate screen and
//! restored on every exit; each refresh writes one frame in place.
//!
//! Frames are ASCII. With color, bars and badges are colored cells; without
//! it, the same layout uses characters, so every view reads the same.
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

/// Decodes one key from the start of `in`; `used` is the number of bytes it
/// took. An escape sequence this view does not use is skipped whole.
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
    if (in.len == 1 or (in[1] != '[' and in[1] != 'O')) return .escape;
    // CSI: parameters and intermediates, then one final byte in 0x40-0x7e.
    var i: usize = 2;
    while (i < in.len and (in[i] < 0x40 or in[i] > 0x7e)) i += 1;
    if (i == in.len) {
        // Incomplete: wait for the rest.
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

/// Order of the table rows.
pub const Sort = enum {
    /// Running first, then waiting, failed, done and pending.
    status,
    /// Longest running or longest run first.
    elapsed,
    /// Largest recorded peak first.
    memory,
    name,
};

/// A control command chosen in the view, for the run loop to send.
pub const Action = struct { cmd: []const u8, rule: ?usize };

/// How long `X` waits for its confirming second press.
const confirm_ns = 3 * std.time.ns_per_s;

pub const Ui = struct {
    /// Producers and consumers of each rule, for its details.
    links: Links = .{},
    mode: Mode = .table,
    /// The view `?` was pressed in, shown again when the keys close.
    before_help: Mode = .table,
    filter: Filter = .all,
    /// Selected rule (index into the tracker's rules, stable as it only
    /// grows) and the first visible row.
    selected: ?usize = null,
    /// Set once a key moved the selection: it then stays on its rule as rows
    /// reorder; until then it follows the top row.
    chosen: bool = false,
    top: usize = 0,
    stderr: bool = true,
    quit: bool = false,
    sort: Sort = .status,
    /// Rows whose name contains this text; typed after `/`.
    query: [64]u8 = undefined,
    query_len: usize = 0,
    typing: bool = false,
    /// A control command to send, set by `S`, `R` and a confirmed `X`.
    action: ?Action = null,
    /// A line shown in place of the key hints until `message_until`.
    message: [160]u8 = undefined,
    message_len: usize = 0,
    message_until: i128 = 0,
    /// Table rows on screen in the last frame.
    page: usize = 20,
    color: bool = false,
    /// Time of the key being applied, set by the run loop; messages and the
    /// confirmation of `X` count from it.
    clock_ns: i128 = 0,
    /// A second `X` before this time cancels the launch.
    confirm_until: i128 = 0,

    /// Applies a key. `rows` lists the visible rules in display order;
    /// `page` is the number of table rows on screen.
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
                    // The rule acted on stays selected as its row moves.
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

    /// Keys while typing a search: text, backspace, enter to keep it and
    /// escape to clear it.
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

    /// Keeps the selection on screen: a selection that left the filter
    /// moves to the nearest row, and `top` scrolls to show it.
    pub fn settle(self: *Ui, rows: []const usize, page: usize) void {
        if (rows.len == 0) {
            self.top = 0;
            return;
        }
        if (!self.chosen) self.selected = rows[@min(self.top, rows.len - 1)];
        // Without a selection, or when it left the view, the top row is
        // selected.
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

/// Visible rules in display order. By status: running first, then
/// waiting, failed, done and pending, each in the order the launch reached
/// them; or by elapsed time, recorded peak or name. `query` keeps the rules
/// whose name contains it.
pub fn visible(a: Allocator, t: *const Tracker, f: Filter, sort: Sort, query: []const u8, now_ns: i128) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    for (t.rules.items, 0..) |r, i| {
        if (!f.keeps(r.status)) continue;
        if (query.len > 0 and std.mem.indexOf(u8, r.name, query) == null) continue;
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
                    const o = std.mem.order(u8, rx.name, ry.name);
                    if (o != .eq) return o == .lt;
                },
            }
            return x < y;
        }
    }.lt);
    return out.items;
}

/// Bytes of `s` that fill at most `cols` columns, counting each UTF-8
/// sequence as one column and never cutting one.
pub fn fit(s: []const u8, cols: usize) usize {
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (c & 0xc0 == 0x80) continue;
        if (n == cols) return i;
        n += 1;
    }
    return s.len;
}

/// The byte where the last `cols` columns of `s` start, counting each UTF-8
/// sequence as one column.
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
const on_green = "\x1b[42m";
const on_yellow = "\x1b[43m";
const on_red = "\x1b[41m";
const on_blue = "\x1b[44m";
const on_magenta = "\x1b[45m";
const on_cyan = "\x1b[46m";
/// The empty part of a bar: bright black, a grey in most themes.
const on_track = "\x1b[100m";

/// One line of a frame: text and SGR sequences, cut at `cols` visible
/// columns. Sequences are dropped when color is off.
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

    /// Visible text, cut at the width; control characters become spaces.
    fn text(self: *Line, s: []const u8) void {
        const cut = s[0..fit(s, self.cols -| self.used)];
        const start = self.len;
        self.raw(cut);
        for (self.buf[start..self.len]) |*c| if (c.* < 0x20 or c.* == 0x7f) {
            c.* = ' ';
        };
        for (cut) |c| self.used += @intFromBool(c & 0xc0 != 0x80);
    }

    /// Text that ends with "..." where the rest of the line cannot hold it,
    /// so a cut is never read as the whole text.
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

    /// Pads with spaces up to visible column `col`.
    fn to(self: *Line, col: usize) void {
        if (col > self.used) self.spaces(col - self.used);
    }

    /// `s` in a field of `width` columns, cut or padded; right-aligned with
    /// `right`.
    fn field(self: *Line, s: []const u8, width: usize, right: bool) void {
        const cut = s[0..fit(s, width)];
        var shown: usize = 0;
        for (cut) |c| shown += @intFromBool(c & 0xc0 != 0x80);
        if (right) self.spaces(width - shown);
        self.text(cut);
        if (!right) self.spaces(width - shown);
    }

    /// A name in a field of `width` columns. A longer one keeps its start
    /// and end around "...", since rules of one step differ at the end.
    fn name(self: *Line, s: []const u8, width: usize) void {
        if (fit(s, width) == s.len or width < 7) return self.field(s, width, false);
        const keep = width - 3;
        const head = (keep + 1) / 2;
        self.text(s[0..fit(s, head)]);
        self.text("...");
        self.text(s[tailStart(s, keep - head)..]);
    }

    /// `n` cells of background `bg` with color, or of `ch` without.
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

    /// A bar of `width` cells split into parts proportional to `parts`, each
    /// at least one cell when it is not zero and there is room; the rest is
    /// the empty track.
    fn bar(self: *Line, width: usize, total: f64, parts: []const Part) void {
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
        if (!self.color) self.text("[");
        for (parts, 0..) |p, i| self.cells(cells_of[i], p.bg, p.ch);
        self.cells(width - taken, on_track, '.');
        if (!self.color) self.text("]");
    }
};

const Part = struct { value: f64, bg: []const u8, ch: u8 };

/// Writes frame lines: each cleared to its end, the last one without a
/// newline so the frame never scrolls.
const Frame = struct {
    w: *std.Io.Writer,
    cols: usize,
    rows: usize,
    color: bool,
    line: usize = 0,

    fn begin(self: *const Frame) Line {
        return .{ .cols = self.cols, .color = self.color };
    }

    fn put(self: *Frame, l: *const Line) !void {
        if (self.line >= self.rows) return;
        if (self.line > 0) try self.w.writeAll("\r\n");
        try self.w.writeAll(l.buf[0..l.len]);
        if (self.color) try self.w.writeAll(reset);
        try self.w.writeAll("\x1b[K");
        self.line += 1;
    }

    fn blank(self: *Frame) !void {
        var l = self.begin();
        try self.put(&l);
    }

    fn finish(self: *Frame) !void {
        try self.w.writeAll("\x1b[J");
    }
};

/// Elapsed time as m:ss, or h:mm:ss from an hour on.
fn clock(buf: []u8, ns: i128) []const u8 {
    const s: u64 = @intCast(@max(@divFloor(ns, std.time.ns_per_s), 0));
    const r = if (s >= 3600) std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) else std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 });
    return r catch "";
}

/// A byte count in a few characters: 980K, 4.2M, 202M, 1.5G.
fn compact(buf: []u8, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n == 0) return "0";
    const r = if (n >= 1 << 30)
        std.fmt.bufPrint(buf, "{d:.1}G", .{f / (1 << 30)})
    else if (n >= 10 << 20)
        std.fmt.bufPrint(buf, "{d:.0}M", .{f / (1 << 20)})
    else if (n >= 1 << 20)
        std.fmt.bufPrint(buf, "{d:.1}M", .{f / (1 << 20)})
    else
        std.fmt.bufPrint(buf, "{d:.0}K", .{f / 1024});
    return r catch "";
}

/// A tick label for the timeline axis: 0, 45s, 2m, 1m30s, 1h, 1h20m.
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

const Look = struct { label: []const u8, badge: ?[]const u8 = null, fg: []const u8 = "" };

fn look(s: Status) Look {
    return switch (s) {
        .running => .{ .label = "running", .badge = "\x1b[46;30m" },
        .cancelling => .{ .label = "stopping", .badge = "\x1b[45;30m" },
        .failed => .{ .label = "failed", .badge = "\x1b[41;97;1m" },
        .retrying => .{ .label = "retrying", .fg = "\x1b[33;1m" },
        .waiting => .{ .label = "waiting", .fg = yellow },
        .pending => .{ .label = "pending", .fg = dim },
        .completed => .{ .label = "completed", .fg = green },
        .reused => .{ .label = "reused", .fg = "\x1b[32;2m" },
        .blocked => .{ .label = "blocked", .fg = red },
        .cancelled => .{ .label = "cancelled", .fg = magenta },
    };
}

/// The color of a bar filled to `ratio` of its limit: green, then yellow
/// from 70%, red from 90%.
fn pressure(ratio: f64) []const u8 {
    return if (ratio >= 0.9) on_red else if (ratio >= 0.7) on_yellow else on_green;
}

/// Draws one frame of the current view into `w`. With `live`, the output of
/// running rules is read from their logs; counters come from the tracker,
/// sampled by the run loop. Tests draw without it.
pub fn draw(gpa: Allocator, w: *std.Io.Writer, t: *const Tracker, ui: *Ui, cols: usize, rows: usize, now_ns: i128, live: bool) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Frame = .{ .w = w, .cols = cols, .rows = rows, .color = ui.color };
    try w.writeAll("\x1b[H");
    const end_ns = if (t.finished) t.finished_ns else now_ns;
    try drawHeader(&f, t, end_ns);
    // A blank line sets the body apart when the terminal has room for it.
    if (rows >= 24) try f.blank();

    const list = try visible(a, t, ui.filter, ui.sort, ui.queryText(), now_ns);
    const footer = 1;
    const head = f.line + 1;
    const page = rows -| (head + footer);
    ui.page = page;
    ui.settle(list, page);
    const space = rows -| (f.line + footer);
    switch (ui.mode) {
        .table => try drawTable(gpa, a, &f, t, ui, list, page, now_ns, live),
        .timeline => try drawTimeline(&f, t, ui, list, page, end_ns),
        .log => try drawLog(gpa, a, &f, t, ui, space, live),
        .details => try drawDetails(gpa, a, &f, t, ui, space, now_ns, live),
        .help => try drawHelp(&f, space),
    }
    while (f.line < rows -| footer) try f.blank();
    try drawFooter(&f, ui, now_ns);
    try f.finish();
}

fn drawHeader(f: *Frame, t: *const Tracker, end_ns: i128) !void {
    var cb: [16]u8 = undefined;
    const state = if (t.finished) t.final_status else "running";
    const elapsed = clock(&cb, end_ns - t.started_ns);
    // Title bar: the whole line in reverse video, the state as a badge.
    var l = f.begin();
    l.sgr(reverse ++ bold);
    l.text(" workz ");
    l.sgr(reset ++ reverse);
    if (t.workdir_name.len > 0) l.print(" {s} ", .{t.workdir_name});
    if (f.cols >= 70) l.print(" launch {s} ", .{t.launch});
    const right = state.len + elapsed.len + 5;
    if (f.cols > l.used + right) l.spaces(f.cols - l.used - right);
    l.sgr(reset);
    l.sgr(if (std.mem.eql(u8, state, "running")) "\x1b[46;30;1m" else if (std.mem.eql(u8, state, "completed")) "\x1b[42;30;1m" else if (std.mem.eql(u8, state, "interrupted") or std.mem.eql(u8, state, "stopped")) "\x1b[45;30;1m" else "\x1b[41;97;1m");
    l.print(" {s} ", .{state});
    l.sgr(reset ++ reverse);
    l.print(" {s} ", .{elapsed});
    l.to(f.cols);
    try f.put(&l);

    const bar_w = std.math.clamp(f.cols -| 76, 10, 40);
    const done = t.count(.completed) + t.count(.reused);
    const running = t.count(.running) + t.count(.cancelling);
    const waiting = t.count(.waiting) + t.count(.retrying);
    const failed = t.count(.failed) + t.count(.blocked);
    const cancelled = t.count(.cancelled);
    const pending = t.count(.pending);
    l = f.begin();
    l.sgr(dim);
    l.text(" progress  ");
    l.sgr(reset);
    l.bar(bar_w, @floatFromInt(t.rules.items.len), &.{
        .{ .value = @floatFromInt(done), .bg = on_green, .ch = '#' },
        .{ .value = @floatFromInt(running), .bg = on_cyan, .ch = '>' },
        .{ .value = @floatFromInt(failed), .bg = on_red, .ch = '!' },
        .{ .value = @floatFromInt(cancelled), .bg = on_magenta, .ch = 'x' },
        .{ .value = @floatFromInt(waiting), .bg = on_yellow, .ch = '~' },
    });
    l.sgr(bold);
    l.print("  {d}/{d} done", .{ done, t.selected });
    if (t.selected > 0) l.print(" ({d}%)", .{done * 100 / t.selected});
    l.sgr(reset);
    // Zero counts are left out, except failures.
    if (running > 0) {
        l.sgr(cyan);
        l.print("  {d} running", .{running});
    }
    if (waiting > 0) {
        l.sgr(reset ++ yellow);
        l.print("  {d} waiting", .{waiting});
    }
    if (pending > 0) {
        l.sgr(reset ++ dim);
        l.print("  {d} pending", .{pending});
    }
    l.sgr(reset);
    l.sgr(if (failed > 0) red ++ bold else dim);
    l.print("  {d} failed", .{failed});
    l.sgr(reset);
    if (cancelled > 0) {
        l.sgr(magenta);
        l.print("  {d} cancelled", .{cancelled});
        l.sgr(reset);
    }
    try f.put(&l);

    const res = t.reserved();
    const reserved_th: f64 = @floatFromInt(res.threads);
    // Use is sampled while rules run; an ended launch uses nothing.
    const cores: ?f64 = if (t.finished) null else t.cpu_cores;
    const in_use: ?u64 = if (t.finished) null else t.memory_current;
    const busy = @min(cores orelse 0, reserved_th);
    l = f.begin();
    l.sgr(dim);
    l.text(" threads   ");
    l.sgr(reset);
    l.bar(bar_w, @floatFromInt(@max(t.max_threads, 1)), &.{
        .{ .value = busy, .bg = on_cyan, .ch = '#' },
        .{ .value = reserved_th - busy, .bg = on_blue, .ch = '=' },
    });
    l.print("  {d}/{d} reserved", .{ res.threads, t.max_threads });
    if (cores) |c| l.print("   {d:.1} cores busy", .{c});
    try f.put(&l);

    const mib: f64 = 1 << 20;
    const reserved_b: f64 = @as(f64, @floatFromInt(res.memory_mib)) * mib;
    const used_b: f64 = if (in_use) |m| @floatFromInt(m) else 0;
    var mb: [3][16]u8 = undefined;
    l = f.begin();
    l.sgr(dim);
    l.text(" memory    ");
    l.sgr(reset);
    l.bar(bar_w, @as(f64, @floatFromInt(@max(t.max_memory_mib, 1))) * mib, &.{
        .{ .value = @min(used_b, @max(reserved_b, used_b)), .bg = on_cyan, .ch = '#' },
        .{ .value = reserved_b - @min(used_b, reserved_b), .bg = on_blue, .ch = '=' },
    });
    l.print("  {s}/{s} reserved", .{ compact(&mb[0], res.memory_mib << 20), compact(&mb[1], t.max_memory_mib << 20) });
    if (in_use) |m| l.print("   {s} in use", .{compact(&mb[2], m)});
    try f.put(&l);

    for (t.shared.items, 0..) |s, i| {
        l = f.begin();
        l.sgr(dim);
        l.text(if (i == 0) " shared    " else "           ");
        l.sgr(reset);
        l.sgr(bold);
        l.text(s.name);
        l.sgr(reset);
        l.text("  ");
        const held = std.mem.eql(u8, s.state, "loading") or std.mem.eql(u8, s.state, "ready");
        l.sgr(if (std.mem.eql(u8, s.state, "ready")) green else if (std.mem.eql(u8, s.state, "loading")) yellow else if (std.mem.eql(u8, s.state, "failed")) red else dim);
        l.text(s.state);
        l.sgr(reset);
        const amount: ?u64 = if (held) s.live_memory orelse s.memory_peak else s.memory_peak;
        if (amount) |m| l.print("  {s} {s}", .{ compact(&mb[0], m), if (held) "held" else "peak" });
        if (s.users.items.len > 0) l.print(", used by {d} {s}", .{ s.users.items.len, if (s.users.items.len == 1) "rule" else "rules" });
        try f.put(&l);
    }
    if (t.final_error.len > 0) {
        l = f.begin();
        l.sgr(red ++ bold);
        l.print(" {s}", .{t.final_error});
        try f.put(&l);
    }
}

/// Which table columns fit in `cols`, and their widths.
const Columns = struct {
    name: usize,
    cpu: bool,
    bar: bool,
    mem: bool,

    const gutter = 2;
    const status_w = 11;
    const att_w = 4;
    const time_w = 9;
    const cpu_w = 9;
    const bar_w = 9;
    const mem_w = 11;

    fn of(cols: usize) Columns {
        const name = std.math.clamp(cols * 28 / 100, 12, 40);
        var rest = cols -| (gutter + status_w + name + 1 + att_w + time_w);
        var c: Columns = .{ .name = name, .cpu = false, .bar = false, .mem = false };
        if (rest >= mem_w + 8) {
            c.mem = true;
            rest -= mem_w;
        }
        if (rest >= cpu_w + 8) {
            c.cpu = true;
            rest -= cpu_w;
        }
        if (rest >= bar_w + 16) c.bar = true;
        return c;
    }
};

fn drawTable(gpa: Allocator, a: Allocator, f: *Frame, t: *const Tracker, ui: *Ui, list: []const usize, page: usize, now_ns: i128, live: bool) !void {
    const c = Columns.of(f.cols);
    var l = f.begin();
    l.sgr(bold);
    l.text("  ");
    l.field(" STATUS", Columns.status_w, false);
    l.field("RULE", c.name + 1, false);
    l.field("ATT", Columns.att_w - 1, true);
    l.field("TIME", Columns.time_w, true);
    if (c.cpu) l.field("CPU", Columns.cpu_w, true);
    if (c.bar) {
        l.spaces(1);
        l.spaces(1);
        l.field("MEMORY", Columns.bar_w - 2, false);
    }
    if (c.mem) l.field(if (c.bar) "" else "MEMORY", Columns.mem_w, true);
    // The label that fits whole.
    const room = l.cols -| l.used;
    l.text(if (room >= 22) "  LAST OUTPUT / REASON" else if (room >= 13) "  LAST OUTPUT" else "");
    try f.put(&l);
    const end = @min(ui.top + page, list.len);
    for (list[ui.top..end]) |ri| {
        const r = &t.rules.items[ri];
        const selected = ui.selected != null and ui.selected.? == ri;
        l = f.begin();
        try drawRow(gpa, a, &l, r, selected, c, now_ns, live);
        try f.put(&l);
    }
    if (list.len == 0) {
        l = f.begin();
        l.sgr(dim);
        l.text(if (ui.query_len > 0) "  no rule name contains the search" else "  no rules in this view");
        try f.put(&l);
    }
}

fn drawRow(gpa: Allocator, a: Allocator, l: *Line, r: *const RuleView, selected: bool, c: Columns, now_ns: i128, live: bool) !void {
    const lk = look(r.status);
    var buf: [4][24]u8 = undefined;
    if (selected) {
        l.sgr(cyan ++ bold);
        l.text("> ");
        l.sgr(reset);
    } else l.text("  ");
    if (lk.badge) |b| {
        l.sgr(b);
        l.print(" {s} ", .{lk.label});
        l.sgr(reset);
        l.spaces(Columns.status_w -| (lk.label.len + 2));
    } else {
        l.sgr(lk.fg);
        l.text(" ");
        l.field(lk.label, Columns.status_w - 1, false);
        l.sgr(reset);
    }
    if (selected) l.sgr(reverse);
    if (r.status == .pending) l.sgr(dim);
    l.name(r.name, c.name);
    l.sgr(reset);
    l.spaces(1);
    const muted = r.status == .pending or r.status.done();

    var att: []const u8 = "";
    if (r.attempt > 0) att = std.fmt.bufPrint(&buf[0], "{d}", .{r.attempt}) catch "";
    l.sgr(if (r.attempt > 1) yellow else if (muted) dim else "");
    l.field(att, Columns.att_w - 1, true);
    l.sgr(reset);

    const time_ns: i128 = if (r.started_ns > 0) elapsedOf(r, now_ns) else if (r.ready_ns > 0 and r.status == .waiting) now_ns - r.ready_ns else -1;
    l.sgr(if (r.started_ns == 0 or muted) dim else "");
    l.field(if (time_ns >= 0) clock(&buf[1], time_ns) else "", Columns.time_w, true);
    l.sgr(reset);

    if (c.cpu) {
        const cores: ?f64 = if (r.status.active()) r.live_cores else if (r.cpu_s != null and r.finished_ns > r.started_ns) r.cpu_s.? / (@as(f64, @floatFromInt(r.finished_ns - r.started_ns)) / 1e9) else null;
        const text = if (cores) |v| std.fmt.bufPrint(&buf[2], "{d:.1}/{d}", .{ v, r.threads }) catch "" else "";
        l.sgr(if (muted) dim else "");
        l.field(text, Columns.cpu_w, true);
        l.sgr(reset);
    }

    const mem: ?u64 = if (r.status.active()) r.live_memory else r.memory_peak;
    const limit: u64 = r.memory_mib << 20;
    if (c.bar) {
        l.spaces(2);
        const width = Columns.bar_w - 2;
        // Only running rules get a bar; a finished rule's peak is its value.
        if (mem != null and limit > 0 and r.status.active()) {
            const ratio = @as(f64, @floatFromInt(mem.?)) / @as(f64, @floatFromInt(limit));
            const n: usize = @min(width, @as(usize, @intFromFloat(@ceil(@min(ratio, 1) * @as(f64, @floatFromInt(width))))));
            l.cells(n, pressure(ratio), if (ratio >= 0.9) '!' else '#');
            l.cells(width - n, on_track, '.');
        } else l.spaces(width);
    }
    if (c.mem) {
        var mtext: []const u8 = "";
        if (mem) |m| {
            mtext = if (limit > 0) std.fmt.bufPrint(&buf[3], "{s}/{s}", .{ compact(&buf[2], m), compact(&buf[1], limit) }) catch "" else compact(&buf[3], m);
        }
        l.sgr(if (muted) dim else "");
        l.field(mtext, Columns.mem_w, true);
        l.sgr(reset);
    }

    l.text("  ");
    if (r.status.active() and live) {
        l.clipped(monitor.lastOutput(gpa, a, r.dir, l.cols));
    } else if (r.reason.len > 0) {
        l.sgr(switch (r.status) {
            .failed => red,
            .waiting, .retrying => yellow,
            else => dim,
        });
        l.clipped(r.reason);
        l.sgr(reset);
    }
}

fn drawTimeline(f: *Frame, t: *const Tracker, ui: *Ui, list: []const usize, page: usize, end_ns: i128) !void {
    const name_w = std.math.clamp(f.cols / 4, 10, 32);
    const axis_w = f.cols -| (2 + name_w + 1);
    const span: i128 = @max(end_ns - t.started_ns, std.time.ns_per_s);
    const span_s: u64 = @intCast(@divFloor(span + std.time.ns_per_s - 1, std.time.ns_per_s));
    // Ticks at a round step, at most one per ten columns.
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
        const x = base + col(t.started_ns + @as(i128, tick) * std.time.ns_per_s, t.started_ns, span, axis_w);
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
        l.sgr(if (selected) reverse else if (r.status == .pending) dim else look(r.status).fg);
        l.name(r.name, name_w);
        l.sgr(reset);
        l.text(" ");
        // Each column is blank, waiting, or the attempt's run in its result.
        var x: usize = 0;
        const ready_at = if (r.ready_ns > 0) col(r.ready_ns, t.started_ns, span, axis_w) else axis_w;
        const start_at = if (r.started_ns > 0) col(r.started_ns, t.started_ns, span, axis_w) else axis_w;
        const stop_at = if (r.started_ns > 0) col(if (r.finished_ns > 0) r.finished_ns else end_ns, t.started_ns, span, axis_w) + 1 else axis_w;
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

/// Everything known about the selected rule: its state and request, its
/// times, and while it runs its cgroup's counters and pressure.
fn drawDetails(gpa: Allocator, a: Allocator, f: *Frame, t: *const Tracker, ui: *Ui, space: usize, now_ns: i128, live: bool) !void {
    const ri = ui.selected orelse return;
    const r = &t.rules.items[ri];
    const lk = look(r.status);
    var b: [4][24]u8 = undefined;
    var l = f.begin();
    l.sgr(bold);
    l.print("  {s}", .{r.name});
    l.sgr(reset);
    l.text("   ");
    if (lk.badge) |badge| {
        l.sgr(badge);
        l.print(" {s} ", .{lk.label});
    } else {
        l.sgr(lk.fg);
        l.text(lk.label);
    }
    l.sgr(reset);
    if (r.attempt > 0) l.print("   attempt {d}", .{r.attempt});
    try f.put(&l);
    l = f.begin();
    l.sgr(dim);
    l.text("  ");
    var i: usize = 0;
    while (i < f.cols -| 4) : (i += 1) l.text("-");
    try f.put(&l);

    const Row = struct {
        fn label(line: *Line, name: []const u8) void {
            line.sgr(dim);
            line.text("  ");
            line.field(name, 12, false);
            line.sgr(reset);
        }
    };
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
        l.print("{d} threads, {s}", .{ r.threads, compact(&b[0], r.memory_mib << 20) });
        try f.put(&l);
    }
    // What it reads from, what reads from it, and the shared inputs it holds.
    for ([_]struct { []const u8, ?[]const []const u8 }{
        .{ "after", ui.links.after.get(r.name) },
        .{ "before", ui.links.before.get(r.name) },
        .{ "shared", if (r.shared.len > 0) r.shared else null },
    }) |row| {
        const names = row[1] orelse continue;
        if (names.len == 0) continue;
        l = f.begin();
        Row.label(&l, row[0]);
        for (names, 0..) |n, k| l.print("{s}{s}", .{ if (k == 0) "" else ", ", n });
        try f.put(&l);
    }
    if (r.ready_ns > 0) {
        l = f.begin();
        Row.label(&l, "ready");
        l.print("{s} after the launch started", .{clock(&b[0], r.ready_ns - t.started_ns)});
        try f.put(&l);
    }
    if (r.started_ns > 0) {
        l = f.begin();
        Row.label(&l, "started");
        l.print("{s}; {s} {s}", .{ clock(&b[0], r.started_ns - t.started_ns), if (r.finished_ns > 0) "ran for" else "running for", clock(&b[1], elapsedOf(r, now_ns)) });
        try f.put(&l);
    }
    const gauge_w = std.math.clamp(f.cols / 4, 10, 30);
    if (r.status.active()) {
        const counters: ?cgroup.Counters = if (live) (if (r.cg) |cg| cgroup.read(gpa, cg) else null) else null;
        if (r.live_cores) |cores| {
            l = f.begin();
            Row.label(&l, "cpu");
            l.bar(gauge_w, @floatFromInt(@max(r.threads, 1)), &.{.{ .value = cores, .bg = on_cyan, .ch = '#' }});
            l.print("  {d:.1} of {d} threads", .{ cores, r.threads });
            if (counters) |cn| if (cn.cpu_usage_usec) |us| l.print(", {d:.1} s so far", .{@as(f64, @floatFromInt(us)) / 1e6});
            try f.put(&l);
        }
        if (r.live_memory) |m| {
            const limit: f64 = @floatFromInt(@max(r.memory_mib << 20, 1));
            const ratio = @as(f64, @floatFromInt(m)) / limit;
            l = f.begin();
            Row.label(&l, "memory");
            l.bar(gauge_w, limit, &.{.{ .value = @floatFromInt(m), .bg = pressure(ratio), .ch = '#' }});
            l.print("  {s} now", .{compact(&b[0], m)});
            if (r.live_peak) |p| l.print(", {s} peak", .{compact(&b[1], p)});
            l.print(", of {s}", .{compact(&b[2], r.memory_mib << 20)});
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
            l.print("cpu {d:.1} s, memory {d:.1} s, I/O {d:.1} s", .{ sec(cn.cpu_some_us), sec(cn.memory_some_us), sec(cn.io_some_us) });
            try f.put(&l);
        }
    } else {
        if (r.cpu_s) |cpu| {
            l = f.begin();
            Row.label(&l, "cpu");
            l.print("{d:.2} s", .{cpu});
            if (r.finished_ns > r.started_ns) l.print(", {d:.1} of {d} threads on average", .{ cpu / (@as(f64, @floatFromInt(r.finished_ns - r.started_ns)) / 1e9), r.threads });
            try f.put(&l);
        }
        if (r.memory_peak) |m| {
            l = f.begin();
            Row.label(&l, "memory");
            l.print("{s} peak", .{compact(&b[0], m)});
            if (r.memory_mib > 0) l.print(" of {s}", .{compact(&b[1], r.memory_mib << 20)});
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

/// A log line, red when it reports an error and yellow for a warning.
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
    l.print(" {s} ", .{r.name});
    l.sgr(reset ++ reverse);
    l.print(" attempt {d}  {s}  {s} ", .{ r.attempt, look(r.status).label, stream });
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
        // "?" comes second, so a narrow terminal still shows where the keys are.
        .table => &.{ .{ .key = "q", .what = "quit" }, .{ .key = "?", .what = "keys" }, .{ .key = "enter", .what = "log" }, .{ .key = "i", .what = "details" }, .{ .key = "t", .what = "timeline" }, .{ .key = "S R X", .what = "stop retry cancel" }, .{ .key = "/", .what = "search" }, .{ .key = "s", .what = "sort" }, .{ .key = "a r w f d", .what = "filter" } },
        .timeline => &.{ .{ .key = "q", .what = "back" }, .{ .key = "?", .what = "keys" }, .{ .key = "j k", .what = "move" }, .{ .key = "enter", .what = "log" }, .{ .key = "t", .what = "table" } },
        .log => &.{ .{ .key = "q", .what = "back" }, .{ .key = "?", .what = "keys" }, .{ .key = "o", .what = "stdout/stderr" }, .{ .key = "j k", .what = "rule" } },
        .details => &.{ .{ .key = "q", .what = "back" }, .{ .key = "?", .what = "keys" }, .{ .key = "j k", .what = "rule" }, .{ .key = "enter", .what = "log" }, .{ .key = "S", .what = "stop" }, .{ .key = "R", .what = "retry" } },
        .help => &.{.{ .key = "q", .what = "back" }},
    };
    // The view's state on the right: filter, sort and search.
    var sb: [128]u8 = undefined;
    const state = if (ui.query_len > 0)
        std.fmt.bufPrint(&sb, "{s} | {s} | \"{s}\" ", .{ @tagName(ui.filter), @tagName(ui.sort), ui.queryText() }) catch ""
    else
        std.fmt.bufPrint(&sb, "{s} | {s} ", .{ @tagName(ui.filter), @tagName(ui.sort) }) catch "";
    const room = f.cols -| (state.len + 1);
    l.text(" ");
    for (hints) |h| {
        if (l.used + h.key.len + h.what.len + 4 > room) break;
        l.sgr(reverse);
        if (!l.color) l.print("[{s}]", .{h.key}) else l.print(" {s} ", .{h.key});
        l.sgr(reset);
        l.print(" {s} ", .{h.what});
    }
    if (f.cols > l.used + state.len) {
        l.to(f.cols - state.len);
        l.sgr(dim);
        l.text(state);
    }
    try f.put(&l);
}

// --- Running the view ---

/// The terminal in raw mode on the alternate screen; `leave` restores it.
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

/// Reads the live counters the view shows into the tracker: memory and CPU
/// of running attempts, memory of held shared inputs, and the run's CPU
/// cores and memory. A read that fails keeps the last value, because a
/// cgroup can be missing for a moment as an attempt starts or ends.
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

/// Appends a command chosen in the view to the launch's control file.
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

/// Runs the interactive view until `q` or an interrupt. The launch is
/// followed while it runs and stays browsable after it ends.
pub fn run(gpa: Allocator, t: *Tracker, interval_ms: u64, color: bool) !bool {
    var set = linux.sigemptyset();
    for ([_]linux.SIG{ .INT, .TERM, .HUP, .WINCH }) |s| linux.sigaddset(&set, s);
    _ = try sys.check(linux.sigprocmask(linux.SIG.BLOCK, &set, null));
    const sigfd: sys.Fd = @intCast(try sys.check(linux.signalfd(-1, &set, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK)));
    defer sys.close(sigfd);

    const terminal = try Terminal.enter();
    defer terminal.leave();
    var ui: Ui = .{ .color = color };
    var links_arena = std.heap.ArenaAllocator.init(gpa);
    defer links_arena.deinit();
    ui.links = try loadLinks(gpa, links_arena.allocator(), std.fs.path.dirname(t.events_path) orelse ".");
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
                    // A sequence too long for the buffer is dropped.
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
            // A sequence cut by the read waits for its remaining bytes.
            std.mem.copyForwards(u8, input[0 .. pending - at], input[at..pending]);
            pending -= at;
        }
    }
    return true;
}

/// Each rule's producers and consumers, by name, from the launch's copy of
/// its workflow; empty when that cannot be read.
pub const Links = struct {
    after: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    before: std.StringHashMapUnmanaged([]const []const u8) = .empty,
};

pub fn loadLinks(gpa: Allocator, a: Allocator, launch_dir: []const u8) !Links {
    var links: Links = .{};
    const info = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }), 1 << 20) catch return links;
    defer gpa.free(info);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, info, .{}) catch return links;
    const workdir = if (v == .object) (if (v.object.get("workdir")) |w| (if (w == .string) w.string else return links) else return links) else return links;
    var problem: workflow.Problem = .{};
    defer if (problem.message.len > 0) gpa.free(problem.message);
    var wf = workflow.loadRecorded(gpa, try std.fs.path.join(a, &.{ launch_dir, "workflow" }), workdir, &problem) catch return links;
    defer wf.deinit();
    var g = graph.build(gpa, &wf, &problem) catch return links;
    defer g.deinit();
    for (wf.rules, 0..) |r, i| {
        const name = try a.dupe(u8, r.name);
        for ([_]struct { []const usize, *std.StringHashMapUnmanaged([]const []const u8) }{ .{ g.parents[i], &links.after }, .{ g.children[i], &links.before } }) |pair| {
            const names = try a.alloc([]const u8, pair[0].len);
            for (pair[0], names) |j, *n| n.* = try a.dupe(u8, wf.rules[j].name);
            try pair[1].put(a, name, names);
        }
    }
    return links;
}
