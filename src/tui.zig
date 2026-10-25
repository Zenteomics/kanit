//! Interactive `watch` on a terminal: a task table to scroll and filter, the
//! selected attempt's log as it grows, and a timeline. The terminal is put
//! in raw mode on the alternate screen and restored on every exit; each
//! refresh writes one frame that overwrites the previous one in place.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const process = @import("process.zig");
const cgroup = @import("cgroup.zig");
const monitor = @import("monitor.zig");
const Allocator = std.mem.Allocator;
const Tracker = monitor.Tracker;
const Status = monitor.Status;

pub fn isTerminal(fd: sys.Fd) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.tcgetattr(fd, &t)) == .SUCCESS;
}

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

pub const Mode = enum { table, log, timeline, details };

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

pub const Ui = struct {
    mode: Mode = .table,
    filter: Filter = .all,
    /// Selected rule (index into the tracker's rules, stable as it only
    /// grows) and the first visible row.
    selected: ?usize = null,
    top: usize = 0,
    stderr: bool = true,
    quit: bool = false,
    sort: Sort = .status,
    /// Rows whose name contains this text; typed after `/`.
    query: [64]u8 = undefined,
    query_len: usize = 0,
    typing: bool = false,
    /// A control command to send, set by `S`, `R` and `X`.
    action: ?Action = null,
    /// A line shown in place of the help until `message_until`.
    message: [160]u8 = undefined,
    message_len: usize = 0,
    message_until: i128 = 0,
    /// Table rows on screen in the last frame.
    page: usize = 20,

    /// Applies a key. `rows` lists the visible rules in display order;
    /// `page` is the number of table rows on screen.
    pub fn key(self: *Ui, k: Key, rows: []const usize, page: usize) void {
        if (self.typing) return self.typeKey(k);
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
                    self.action = .{ .cmd = "stop", .rule = sel };
                },
                'R' => if (self.selected) |sel| {
                    self.action = .{ .cmd = "retry", .rule = sel };
                },
                'X' => self.action = .{ .cmd = "cancel", .rule = null },
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
    }

    /// Keeps the selection on screen: a selection that left the filter
    /// moves to the nearest row, and `top` scrolls to show it.
    pub fn settle(self: *Ui, rows: []const usize, page: usize) void {
        if (rows.len == 0) {
            self.top = 0;
            return;
        }
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

fn elapsedOf(r: *const monitor.RuleView, now_ns: i128) i128 {
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
                    const mx = rx.memory_peak orelse 0;
                    const my = ry.memory_peak orelse 0;
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

/// Writes frame lines: each cut to the width and cleared to its end.
const Frame = struct {
    w: *std.Io.Writer,
    cols: usize,
    rows: usize,
    line: usize = 0,
    buf: [1024]u8 = undefined,

    /// Formats one line; `style` (an SGR sequence) wraps it when set.
    fn put(self: *Frame, style: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
        if (self.line >= self.rows) return;
        var fw: std.Io.Writer = .fixed(&self.buf);
        fw.print(fmt, args) catch {};
        const text = fw.buffered();
        if (self.line > 0) try self.w.writeAll("\r\n");
        if (style) |s| try self.w.writeAll(s);
        try self.w.writeAll(text[0..fit(text, self.cols)]);
        if (style != null) try self.w.writeAll("\x1b[0m");
        try self.w.writeAll("\x1b[K");
        self.line += 1;
    }

    fn finish(self: *Frame) !void {
        try self.w.writeAll("\x1b[J");
    }
};

/// `s` cut or padded with spaces to `cols` columns, in `buf`; right-aligned
/// with `right`.
fn pad(buf: []u8, s: []const u8, cols: usize, right: bool) []const u8 {
    const cut = s[0..fit(s, cols)];
    var shown: usize = 0;
    for (cut) |c| shown += @intFromBool(c & 0xc0 != 0x80);
    const spaces = @min(cols - shown, buf.len -| cut.len);
    const n = @min(cut.len, buf.len - spaces);
    if (right) {
        @memset(buf[0..spaces], ' ');
        @memcpy(buf[spaces..][0..n], cut[0..n]);
    } else {
        @memcpy(buf[0..n], cut[0..n]);
        @memset(buf[n..][0..spaces], ' ');
    }
    return buf[0 .. n + spaces];
}

fn colorOf(s: Status) []const u8 {
    return switch (s) {
        .failed, .blocked => "\x1b[31m",
        .running, .cancelling, .retrying => "\x1b[36m",
        .waiting => "\x1b[33m",
        .pending => "\x1b[90m",
        .cancelled => "\x1b[35m",
        .completed, .reused => "\x1b[32m",
    };
}

fn clock(buf: []u8, ns: i128) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    monitor.duration(&w, ns) catch {};
    return w.buffered();
}

fn size(buf: []u8, n: ?u64) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    monitor.bytes(&w, n) catch {};
    return w.buffered();
}

/// Draws one frame of the current view into `w`. With `live`, running rows
/// show their cgroup's current and peak memory and logs are read; tests
/// draw without it.
pub fn draw(gpa: Allocator, w: *std.Io.Writer, t: *const Tracker, ui: *Ui, cols: usize, rows: usize, now_ns: i128, live: bool) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Frame = .{ .w = w, .cols = cols, .rows = rows };
    try w.writeAll("\x1b[H");

    var cb: [16]u8 = undefined;
    const end_ns = if (t.finished) t.finished_ns else now_ns;
    const state = if (t.finished) t.final_status else "running";
    try f.put("\x1b[1m", "workz watch  {s}  {s}  {s}", .{ t.launch, state, clock(&cb, end_ns - t.started_ns) });
    var mb: [16]u8 = undefined;
    const done = t.count(.completed) + t.count(.reused);
    const res = t.reserved();
    try f.put(null, "{d}/{d} done  {d} running  {d} waiting  {d} pending  {d} failed", .{ done, t.selected, t.count(.running) + t.count(.cancelling), t.count(.waiting), t.count(.pending), t.count(.failed) + t.count(.blocked) });
    if (t.cpu_cores) |cores| {
        try f.put(null, "reserved {d}/{d} threads, {d}/{d} MiB   using {d:.1} cores, {s}", .{ res.threads, t.max_threads, res.memory_mib, t.max_memory_mib, cores, std.mem.trim(u8, size(&mb, t.memory_current), " ") });
    } else try f.put(null, "reserved {d}/{d} threads, {d}/{d} MiB", .{ res.threads, t.max_threads, res.memory_mib, t.max_memory_mib });
    // One line per shared input: its state and, while it is held, its memory.
    for (t.shared.items) |s| {
        var sb: [16]u8 = undefined;
        const held = std.mem.eql(u8, s.state, "loading") or std.mem.eql(u8, s.state, "ready");
        const cur: ?u64 = if (live and held) (if (s.cg) |cg| cgroup.readNumber(gpa, cg, "memory.current") else null) else s.memory_peak;
        try f.put(null, "shared {s}: {s}, {s} {s}", .{ s.name, s.state, if (held) "holding" else "peak", std.mem.trim(u8, size(&sb, cur), " ") });
    }
    if (t.final_error.len > 0) try f.put("\x1b[31m", "{s}", .{t.final_error});

    const list = try visible(a, t, ui.filter, ui.sort, ui.queryText(), now_ns);
    const footer = 1;
    const head = f.line + 1;
    const page = rows -| (head + footer);
    ui.page = page;
    ui.settle(list, page);

    switch (ui.mode) {
        .table => try drawTable(gpa, a, &f, t, ui, list, page, now_ns, live),
        .timeline => try drawTimeline(&f, t, ui, list, page, end_ns),
        .log => try drawLog(gpa, a, &f, t, ui, rows -| (f.line + footer), live),
        .details => try drawDetails(gpa, a, &f, t, ui, rows -| (f.line + footer), now_ns, live),
    }
    while (f.line < rows -| footer) try f.put(null, "", .{});
    const help = switch (ui.mode) {
        .table => "q quit  enter log  i details  t timeline  a/r/w/f/d filter  s sort  / search  S stop  R retry  X cancel",
        .timeline => "q back  j/k move  enter log  t table",
        .log => "q back  o stdout/stderr  j/k rule",
        .details => "q back  j/k rule  enter log  S stop  R retry",
    };
    if (ui.typing) {
        try f.put("\x1b[7m", "search: {s}_  (enter keeps, esc clears)", .{ui.queryText()});
    } else if (ui.message_len > 0 and now_ns < ui.message_until) {
        try f.put("\x1b[7m", "{s}", .{ui.message[0..ui.message_len]});
    } else if (ui.query_len > 0) {
        try f.put("\x1b[7m", "[{s}, {s}, \"{s}\"] {s}", .{ @tagName(ui.filter), @tagName(ui.sort), ui.queryText(), help });
    } else try f.put("\x1b[7m", "[{s}, {s}] {s}", .{ @tagName(ui.filter), @tagName(ui.sort), help });
    try f.finish();
}

fn drawTable(gpa: Allocator, a: Allocator, f: *Frame, t: *const Tracker, ui: *Ui, list: []const usize, page: usize, now_ns: i128, live: bool) !void {
    const name_w = @min(@max(f.cols / 3, 12), 48);
    var nb: [256]u8 = undefined;
    try f.put("\x1b[1m", "{s:<10} {s} {s:>3} {s:>8} {s:>8} {s:>8}  {s}", .{ "STATUS", pad(&nb, "RULE", name_w, false), "ATT", "TIME", "MEM", "PEAK", "LAST OUTPUT / REASON" });
    const end = @min(ui.top + page, list.len);
    for (list[ui.top..end]) |ri| {
        const r = &t.rules.items[ri];
        var cb: [16]u8 = undefined;
        var mb: [2][16]u8 = undefined;
        const time_ns: i128 = if (r.started_ns == 0) (if (r.ready_ns > 0) now_ns - r.ready_ns else 0) else if (r.finished_ns > 0) r.finished_ns - r.started_ns else now_ns - r.started_ns;
        var cur: ?u64 = null;
        var peak: ?u64 = r.memory_peak;
        var tail: []const u8 = r.reason;
        if (live and r.status.active()) {
            if (r.cg) |cg| {
                cur = cgroup.readNumber(gpa, cg, "memory.current");
                peak = cgroup.readNumber(gpa, cg, "memory.peak");
            }
            tail = monitor.lastOutput(gpa, a, r.dir, f.cols);
        }
        const selected = ui.selected != null and ui.selected.? == ri;
        try f.put(if (selected) "\x1b[7m" else colorOf(r.status), "{s:<10} {s} {d:>3} {s:>8} {s:>8} {s:>8}  {s}", .{
            @tagName(r.status), pad(&nb, r.name, name_w, false), r.attempt, clock(&cb, time_ns), size(&mb[0], cur), size(&mb[1], peak), tail,
        });
    }
    if (list.len == 0) try f.put(null, "(no rules in this view)", .{});
}

fn drawTimeline(f: *Frame, t: *const Tracker, ui: *Ui, list: []const usize, page: usize, end_ns: i128) !void {
    const name_w = @min(@max(f.cols / 4, 10), 32);
    const bar_w = f.cols -| (name_w + 2);
    const span: i128 = @max(end_ns - t.started_ns, 1);
    var cb: [16]u8 = undefined;
    var nb: [256]u8 = undefined;
    var sb: [512]u8 = undefined;
    try f.put("\x1b[1m", "{s}  0{s}", .{ pad(&nb, "RULE", name_w, false), pad(&sb, clock(&cb, span), bar_w -| 1, true) });
    var bar: [512]u8 = undefined;
    const width = @min(bar_w, bar.len);
    const end = @min(ui.top + page, list.len);
    for (list[ui.top..end]) |ri| {
        const r = &t.rules.items[ri];
        @memset(bar[0..width], ' ');
        const col = struct {
            fn at(ns: i128, start: i128, sp: i128, w: usize) usize {
                if (ns <= start) return 0;
                const c: usize = @intCast(@divFloor((ns - start) * @as(i128, @intCast(w)), sp));
                return @min(c, w -| 1);
            }
        }.at;
        if (width > 0) {
            if (r.ready_ns > 0) {
                const stop = if (r.started_ns > 0) r.started_ns else if (r.finished_ns > 0) r.finished_ns else end_ns;
                @memset(bar[col(r.ready_ns, t.started_ns, span, width) .. col(stop, t.started_ns, span, width) + 1], '.');
            }
            if (r.started_ns > 0) {
                const stop = if (r.finished_ns > 0) r.finished_ns else end_ns;
                const mark: u8 = switch (r.status) {
                    .failed, .blocked => '!',
                    .cancelled => 'x',
                    .running, .cancelling, .retrying => '>',
                    else => '=',
                };
                @memset(bar[col(r.started_ns, t.started_ns, span, width) .. col(stop, t.started_ns, span, width) + 1], mark);
            }
        }
        const selected = ui.selected != null and ui.selected.? == ri;
        try f.put(if (selected) "\x1b[7m" else colorOf(r.status), "{s}  {s}", .{ pad(&nb, r.name, name_w, false), bar[0..width] });
    }
}

/// Everything known about the selected rule: its state and request, its
/// times, and while it runs its cgroup's counters and pressure.
fn drawDetails(gpa: Allocator, a: Allocator, f: *Frame, t: *const Tracker, ui: *Ui, space: usize, now_ns: i128, live: bool) !void {
    const ri = ui.selected orelse return;
    const r = &t.rules.items[ri];
    var b: [3][16]u8 = undefined;
    try f.put("\x1b[1m", "{s}", .{r.name});
    try f.put(null, "status     {s}, attempt {d}", .{ @tagName(r.status), r.attempt });
    if (r.reason.len > 0) try f.put(null, "{s} {s}", .{ if (r.status == .waiting) "waits for " else "reason    ", r.reason });
    if (r.threads > 0) try f.put(null, "request    {d} threads, {d} MiB", .{ r.threads, r.memory_mib });
    if (r.ready_ns > 0) try f.put(null, "ready at   {s}", .{clock(&b[0], r.ready_ns - t.started_ns)});
    if (r.started_ns > 0) try f.put(null, "started at {s}, {s} {s}", .{ clock(&b[0], r.started_ns - t.started_ns), if (r.finished_ns > 0) "ran" else "running for", clock(&b[1], elapsedOf(r, now_ns)) });
    if (r.cpu_s) |c| try f.put(null, "cpu        {d:.2} s", .{c});
    if (r.memory_peak) |m| try f.put(null, "peak       {s}", .{std.mem.trim(u8, size(&b[2], m), " ")});
    if (live and r.status.active()) if (r.cg) |cg| {
        const c = cgroup.read(gpa, cg);
        try f.put(null, "memory     {s} now, {s} peak, {d} near-limit events", .{ std.mem.trim(u8, size(&b[0], c.memory_current), " "), std.mem.trim(u8, size(&b[1], c.memory_peak), " "), c.memory_max_events });
        if (c.cpu_usage_usec) |us| try f.put(null, "cpu        {d:.2} s so far", .{@as(f64, @floatFromInt(us)) / 1e6});
        const stall = struct {
            fn s(v: ?u64) f64 {
                return @as(f64, @floatFromInt(v orelse 0)) / 1e6;
            }
        }.s;
        try f.put(null, "stalled    cpu {d:.1} s, memory {d:.1} s, io {d:.1} s", .{ stall(c.cpu_some_us), stall(c.memory_some_us), stall(c.io_some_us) });
        try f.put(null, "cgroup     {s}", .{cg});
    };
    if (r.dir.len > 0) try f.put(null, "files      {s}", .{r.dir});
    if (!live or r.dir.len == 0 or f.line + 2 >= space) return;
    try f.put("\x1b[1m", "last output", .{});
    const tail = sys.readTail(gpa, try std.fs.path.join(a, &.{ r.dir, "stderr.log" }), 4096) catch return;
    defer gpa.free(tail);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, tail, "\n"), '\n');
    while (it.next()) |l| try lines.append(a, l);
    const room = space -| f.line;
    for (lines.items[lines.items.len -| room..]) |l| {
        const clean = try a.dupe(u8, l);
        for (clean) |*c| if (c.* < 0x20 or c.* == 0x7f) {
            c.* = ' ';
        };
        try f.put(null, "  {s}", .{clean});
    }
}

fn drawLog(gpa: Allocator, a: Allocator, f: *Frame, t: *const Tracker, ui: *Ui, space: usize, live: bool) !void {
    const ri = ui.selected orelse return;
    const r = &t.rules.items[ri];
    const stream = if (ui.stderr) "stderr" else "stdout";
    try f.put("\x1b[1m", "{s}  attempt {d}  {s}  {s}", .{ r.name, r.attempt, @tagName(r.status), stream });
    if (r.dir.len == 0) return f.put(null, "(not started)", .{});
    if (!live) return;
    const path = try std.fs.path.join(a, &.{ r.dir, try std.fmt.allocPrint(a, "{s}.log", .{stream}) });
    const want = space -| 1;
    const tail = sys.readTail(gpa, path, @min(want * (f.cols + 1) * 4 + 1, 1 << 20)) catch return f.put(null, "(no {s} yet)", .{stream});
    defer gpa.free(tail);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, tail, "\n"), '\n');
    while (it.next()) |l| try lines.append(a, l);
    const from = lines.items.len -| want;
    for (lines.items[from..]) |l| {
        const clean = try a.dupe(u8, l);
        for (clean) |*c| if (c.* < 0x20 or c.* == 0x7f) {
            c.* = ' ';
        };
        try f.put(null, "{s}", .{clean});
    }
}

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

    fn size() struct { cols: usize, rows: usize } {
        var ws: std.posix.winsize = undefined;
        if (linux.errno(linux.ioctl(1, linux.T.IOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
        return .{ .cols = ws.col, .rows = ws.row };
    }
};

/// Runs the interactive view until `q` or an interrupt. The launch is
/// followed while it runs and stays browsable after it ends.
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

pub fn run(gpa: Allocator, t: *Tracker, interval_ms: u64) !bool {
    var set = linux.sigemptyset();
    for ([_]linux.SIG{ .INT, .TERM, .HUP, .WINCH }) |s| linux.sigaddset(&set, s);
    _ = try sys.check(linux.sigprocmask(linux.SIG.BLOCK, &set, null));
    const sigfd: sys.Fd = @intCast(try sys.check(linux.signalfd(-1, &set, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK)));
    defer sys.close(sigfd);

    const term = try Terminal.enter();
    defer term.leave();
    var ui: Ui = .{};
    var frame: std.Io.Writer.Allocating = .init(gpa);
    defer frame.deinit();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var input: [64]u8 = undefined;
    var pending: usize = 0;
    var next_ns = sys.monoNs();
    var last_cpu: ?u64 = null;
    var last_cpu_ns: i128 = 0;
    while (!ui.quit) {
        const now = sys.monoNs();
        if (now >= next_ns) {
            _ = try t.update();
            next_ns = now + @as(i128, interval_ms) * std.time.ns_per_ms;
            // The run's own counters, between two refreshes.
            if (t.run_cg) |cg| if (!t.finished) {
                t.memory_current = cgroup.readNumber(gpa, cg, "memory.current");
                const cpu = cgroup.cpuUsage(gpa, cg);
                if (cpu != null and last_cpu != null and now > last_cpu_ns)
                    t.cpu_cores = @as(f64, @floatFromInt(cpu.? -| last_cpu.?)) / (@as(f64, @floatFromInt(now - last_cpu_ns)) / 1e3);
                last_cpu = cpu;
                last_cpu_ns = now;
            };
        }
        const sz = Terminal.size();
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
            const list = try visible(scratch.allocator(), t, ui.filter, ui.sort, ui.queryText(), sys.realNs());
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
