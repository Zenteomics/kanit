//! `watch` and `status`: read-only views of a launch, built from its event
//! stream, its attempt files and the running tasks' cgroup counters. The
//! event stream is read incrementally: a refresh parses only the complete
//! lines appended since the previous one.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const cgroup = @import("cgroup.zig");
const tui = @import("tui.zig");
const clean = @import("clean.zig");
const Allocator = std.mem.Allocator;

pub const Status = enum {
    waiting,
    running,
    cancelling,
    retrying,
    completed,
    reused,
    failed,
    blocked,
    cancelled,

    pub fn active(s: Status) bool {
        return s == .running or s == .cancelling;
    }

    pub fn done(s: Status) bool {
        return s == .completed or s == .reused;
    }
};

pub const RuleView = struct {
    name: []const u8,
    status: Status = .waiting,
    attempt: u32 = 0,
    /// Attempt directory and cgroup of the latest attempt.
    dir: []const u8 = "",
    cg: ?[]const u8 = null,
    /// Event times, nanoseconds since the epoch; 0 when not reached.
    ready_ns: i128 = 0,
    started_ns: i128 = 0,
    finished_ns: i128 = 0,
    /// Failure reason, or the current wait reason while waiting.
    reason: []const u8 = "",
    memory_peak: ?u64 = null,
    cpu_s: ?f64 = null,
    /// Request of the latest attempt.
    threads: u32 = 0,
    memory_mib: u64 = 0,
};

pub const SharedView = struct {
    name: []const u8,
    state: []const u8,
    memory_peak: ?u64 = null,
};

/// The state of one launch, kept up to date from its event stream.
pub const Tracker = struct {
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    events_path: []const u8,
    offset: u64 = 0,
    /// Bytes of a line not yet terminated.
    partial: std.ArrayList(u8) = .empty,

    launch: []const u8 = "",
    selected: u32 = 0,
    started_ns: i128 = 0,
    max_threads: u32 = 0,
    max_memory_mib: u64 = 0,
    /// The run's cgroup, when isolated.
    run_cg: ?[]const u8 = null,
    finished: bool = false,
    finished_ns: i128 = 0,
    final_status: []const u8 = "",
    final_error: []const u8 = "",
    /// The run's memory in use and CPU cores used: from the last sample, or
    /// read live by the interactive view.
    memory_current: ?u64 = null,
    cpu_cores: ?f64 = null,
    rules: std.ArrayList(RuleView) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,
    shared: std.ArrayList(SharedView) = .empty,

    pub fn init(gpa: Allocator, launch_dir: []const u8) !Tracker {
        var t: Tracker = .{ .arena = std.heap.ArenaAllocator.init(gpa), .gpa = gpa, .events_path = "" };
        errdefer t.arena.deinit();
        const a = t.arena.allocator();
        t.events_path = try std.fs.path.join(a, &.{ launch_dir, "events.jsonl" });
        t.launch = try a.dupe(u8, std.fs.path.basename(launch_dir));
        return t;
    }

    pub fn deinit(self: *Tracker) void {
        self.partial.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Reads and applies the events appended since the last call; true when
    /// any was applied.
    pub fn update(self: *Tracker) !bool {
        const fd = sys.openRead(self.gpa, self.events_path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer sys.close(fd);
        var changed = false;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const rc = linux.pread(fd, &buf, buf.len, @intCast(self.offset));
            const n = sys.check(rc) catch return changed;
            if (n == 0) break;
            self.offset += n;
            var rest: []const u8 = buf[0..n];
            while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                if (self.partial.items.len > 0) {
                    try self.partial.appendSlice(self.gpa, rest[0..nl]);
                    try self.apply(self.partial.items);
                    self.partial.clearRetainingCapacity();
                } else try self.apply(rest[0..nl]);
                rest = rest[nl + 1 ..];
                changed = true;
            }
            try self.partial.appendSlice(self.gpa, rest);
        }
        return changed;
    }

    fn rule(self: *Tracker, name: []const u8) !*RuleView {
        const gop = try self.index.getOrPut(self.arena.allocator(), name);
        if (!gop.found_existing) {
            const owned = try self.arena.allocator().dupe(u8, name);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = self.rules.items.len;
            try self.rules.append(self.arena.allocator(), .{ .name = owned });
        }
        return &self.rules.items[gop.value_ptr.*];
    }

    fn sharedView(self: *Tracker, name: []const u8) !*SharedView {
        for (self.shared.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        try self.shared.append(self.arena.allocator(), .{ .name = try self.arena.allocator().dupe(u8, name), .state = "" });
        return &self.shared.items[self.shared.items.len - 1];
    }

    /// Applies one event line. Strings kept beyond the line are copied into
    /// the tracker's arena; the parse itself uses a scratch arena.
    pub fn apply(self: *Tracker, line: []const u8) !void {
        if (line.len == 0) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch return;
        const a = self.arena.allocator();
        const ev = str(v, "event") orelse return;
        const at = parseTime(str(v, "time") orelse "") orelse 0;
        if (self.started_ns == 0) self.started_ns = at;
        const eql = std.mem.eql;
        if (eql(u8, ev, "launch_started")) {
            self.selected = @intCast(int(v, "selected") orelse 0);
            self.max_threads = @intCast(int(v, "max_threads") orelse 0);
            self.max_memory_mib = @intCast(int(v, "max_memory_mib") orelse 0);
            self.run_cg = if (str(v, "cgroup")) |cg| try a.dupe(u8, cg) else null;
        } else if (eql(u8, ev, "launch_finished")) {
            self.finished = true;
            self.finished_ns = at;
            self.final_status = try a.dupe(u8, str(v, "status") orelse "");
            self.final_error = try a.dupe(u8, str(v, "error") orelse "");
        } else if (eql(u8, ev, "sample")) {
            self.memory_current = if (int(v, "memory_current")) |m| @intCast(m) else null;
            self.cpu_cores = float(v, "cpu_cores_used");
        } else if (std.mem.startsWith(u8, ev, "shared_")) {
            const s = try self.sharedView(str(v, "name") orelse "?");
            s.state = if (eql(u8, ev, "shared_loading")) "loading" else if (eql(u8, ev, "shared_loaded")) "ready" else if (eql(u8, ev, "shared_released")) "released" else if (eql(u8, ev, "shared_failed")) "failed" else s.state;
            if (int(v, "memory_peak")) |m| s.memory_peak = @intCast(m);
        } else if (str(v, "rule")) |name| {
            const r = try self.rule(name);
            if (eql(u8, ev, "task_waiting")) {
                if (r.ready_ns == 0) r.ready_ns = at;
                r.status = .waiting;
                r.reason = try a.dupe(u8, str(v, "reason") orelse "");
            } else if (eql(u8, ev, "task_started")) {
                if (r.ready_ns == 0) r.ready_ns = at;
                r.status = .running;
                r.attempt = @intCast(int(v, "attempt") orelse 0);
                r.dir = try a.dupe(u8, str(v, "directory") orelse "");
                r.cg = if (str(v, "cgroup")) |cg| try a.dupe(u8, cg) else null;
                r.threads = @intCast(int(v, "threads") orelse 0);
                r.memory_mib = @intCast(int(v, "memory_mib") orelse 0);
                r.started_ns = at;
                r.finished_ns = 0;
                r.reason = "";
            } else if (eql(u8, ev, "task_finished")) {
                const st = str(v, "status") orelse "";
                r.status = if (eql(u8, st, "completed")) .completed else if (eql(u8, st, "cancelled")) .cancelled else .failed;
                r.reason = try a.dupe(u8, str(v, "reason") orelse "");
                r.finished_ns = at;
                if (int(v, "memory_peak")) |m| r.memory_peak = @intCast(m);
                r.cpu_s = float(v, "cpu_s");
            } else if (eql(u8, ev, "task_retry")) {
                r.status = .retrying;
            } else if (eql(u8, ev, "task_reused")) {
                r.status = .reused;
            } else if (eql(u8, ev, "task_blocked")) {
                r.status = .blocked;
            } else if (eql(u8, ev, "task_failed")) {
                r.status = .failed;
                r.reason = try a.dupe(u8, str(v, "reason") orelse "");
                if (r.finished_ns == 0) r.finished_ns = at;
            } else if (eql(u8, ev, "task_cancelling")) {
                r.status = .cancelling;
            }
        }
    }

    /// Threads and memory reserved by the running attempts (shared inputs
    /// are not included).
    pub fn reserved(self: *const Tracker) struct { threads: u64, memory_mib: u64 } {
        var th: u64 = 0;
        var mem: u64 = 0;
        for (self.rules.items) |r| if (r.status.active()) {
            th += r.threads;
            mem += r.memory_mib;
        };
        return .{ .threads = th, .memory_mib = mem };
    }

    pub fn count(self: *const Tracker, s: Status) usize {
        var n: usize = 0;
        for (self.rules.items) |r| n += @intFromBool(r.status == s);
        return n;
    }
};

/// Parses "YYYY-MM-DDTHH:MM:SS.mmmZ" into nanoseconds since the epoch.
pub fn parseTime(t: []const u8) ?i128 {
    if (t.len < 20) return null;
    const y = std.fmt.parseInt(i64, t[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, t[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, t[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, t[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, t[14..16], 10) catch return null;
    const s = std.fmt.parseInt(i64, t[17..19], 10) catch return null;
    const ms: i64 = if (t.len >= 23 and t[19] == '.') std.fmt.parseInt(i64, t[20..23], 10) catch 0 else 0;
    // Days from civil date (Howard Hinnant's algorithm).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const secs = days * 86400 + h * 3600 + mi * 60 + s;
    return @as(i128, secs) * std.time.ns_per_s + @as(i128, ms) * std.time.ns_per_ms;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn int(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer and x.integer >= 0) x.integer else null;
}

fn float(v: std.json.Value, key: []const u8) ?f64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return switch (x) {
        .float => x.float,
        .integer => @floatFromInt(x.integer),
        else => null,
    };
}

pub fn duration(w: *std.Io.Writer, ns: i128) !void {
    const s: u64 = @intCast(@max(@divFloor(ns, std.time.ns_per_s), 0));
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 });
}

pub fn bytes(w: *std.Io.Writer, n: ?u64) !void {
    const v = n orelse return w.writeAll("       -");
    const f: f64 = @floatFromInt(v);
    if (v >= 1 << 30) return w.print("{d:>5.1} Gi", .{f / (1 << 30)});
    if (v >= 1 << 20) return w.print("{d:>5.1} Mi", .{f / (1 << 20)});
    return w.print("{d:>5.1} Ki", .{f / 1024});
}

/// The last non-empty line of a file, with control characters blanked and
/// cut to `max` bytes; allocated in `a`.
pub fn lastLine(gpa: Allocator, a: Allocator, path: []const u8, max: usize) []const u8 {
    const tail = sys.readTail(gpa, path, 4096) catch return "";
    defer gpa.free(tail);
    var end = tail.len;
    while (end > 0 and (tail[end - 1] == '\n' or tail[end - 1] == '\r' or tail[end - 1] == ' ')) end -= 1;
    const start = if (std.mem.lastIndexOfScalar(u8, tail[0..end], '\n')) |p| p + 1 else 0;
    const out = a.dupe(u8, tail[start..end][0..@min(end - start, max)]) catch return "";
    for (out) |*c| if (c.* < 0x20 or c.* == 0x7f) {
        c.* = ' ';
    };
    return out;
}

/// The latest output line of an attempt: its standard error, else its
/// standard output.
pub fn lastOutput(gpa: Allocator, a: Allocator, dir: []const u8, max: usize) []const u8 {
    if (dir.len == 0) return "";
    const line = lastLine(gpa, a, std.fs.path.join(a, &.{ dir, "stderr.log" }) catch return "", max);
    if (line.len > 0) return line;
    return lastLine(gpa, a, std.fs.path.join(a, &.{ dir, "stdout.log" }) catch return "", max);
}

/// The plain text view: header, running tasks with live counters, failures.
pub fn render(gpa: Allocator, w: *std.Io.Writer, t: *const Tracker, now_ns: i128) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try w.print("launch {s}  ", .{t.launch});
    if (t.finished) {
        try w.print("{s}", .{t.final_status});
        if (t.final_error.len > 0) try w.print(": {s}", .{t.final_error});
    } else {
        try w.writeAll("elapsed ");
        try duration(w, now_ns - t.started_ns);
    }
    try w.print("\n{d} selected:", .{t.selected});
    for (std.enums.values(Status)) |s| {
        const k = t.count(s);
        if (k > 0) try w.print(" {d} {s},", .{ k, @tagName(s) });
    }
    try w.print(" {d} done\n", .{t.count(.completed) + t.count(.reused)});
    for (t.shared.items) |s| try w.print("shared {s}: {s}\n", .{ s.name, s.state });

    try w.writeAll("\nRUNNING                                      ATT  ELAPSED     MEM NOW  MEM PEAK  LAST OUTPUT\n");
    var shown: usize = 0;
    for (t.rules.items) |r| {
        if (!r.status.active()) continue;
        shown += 1;
        try w.print("{s:<44} {d:>3}  ", .{ r.name[0..@min(r.name.len, 44)], r.attempt });
        try duration(w, now_ns - r.started_ns);
        try w.writeAll("  ");
        try bytes(w, if (r.cg) |cg| cgroup.readNumber(gpa, cg, "memory.current") else null);
        try w.writeAll("  ");
        try bytes(w, if (r.cg) |cg| cgroup.readNumber(gpa, cg, "memory.peak") else null);
        try w.print("  {s}\n", .{lastOutput(gpa, a, r.dir, 60)});
    }
    if (shown == 0) try w.writeAll("(none)\n");

    var failures: usize = 0;
    for (t.rules.items) |r| {
        if (r.status != .failed) continue;
        if (failures == 0) try w.writeAll("\nFAILED\n");
        failures += 1;
        if (failures > 10) continue;
        try w.print("{s}: {s}", .{ r.name, r.reason });
        if (r.dir.len > 0) try w.print("  ({s}/stderr.log)", .{r.dir});
        try w.writeAll("\n");
    }
    if (failures > 10) try w.print("... and {d} more\n", .{failures - 10});
}

/// Shows the newest launch: interactively when both standard input and
/// output are terminals and `once` is not set; otherwise as text, refreshed
/// every `interval_ms` until the launch finishes, or once.
pub fn watch(gpa: Allocator, io: std.Io, root: []const u8, once: bool, interval_ms: u64) !bool {
    var launch_arena = std.heap.ArenaAllocator.init(gpa);
    defer launch_arena.deinit();
    const rec = try records.recordsDir(launch_arena.allocator(), root);
    const dir = (try records.latestLaunch(gpa, launch_arena.allocator(), rec)) orelse {
        std.debug.print("workz: no launch recorded in {s}\n", .{rec});
        return false;
    };
    var tracker = try Tracker.init(gpa, dir);
    defer tracker.deinit();
    if (!once and tui.isTerminal(0) and tui.isTerminal(1)) return tui.run(gpa, &tracker, interval_ms);
    const tty = tui.isTerminal(1);
    var obuf: [16384]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &obuf);
    while (true) {
        _ = try tracker.update();
        if (tty and !once) try out.interface.writeAll("\x1b[H\x1b[2J");
        try render(gpa, &out.interface, &tracker, sys.realNs());
        try out.interface.flush();
        if (once or tracker.finished) return true;
        const ts: linux.timespec = .{ .sec = @intCast(interval_ms / 1000), .nsec = @intCast((interval_ms % 1000) * std.time.ns_per_ms) };
        _ = linux.nanosleep(&ts, null);
    }
}

/// One line per launch, newest first, for the last `n`: start, status,
/// elapsed time, counts and the error of a failed launch.
pub fn history(gpa: Allocator, w: *std.Io.Writer, root: []const u8, n: usize) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try records.recordsDir(a, root);
    const names = try clean.launchNames(gpa, a, rec);
    try w.writeAll("LAUNCH                          STATUS        ELAPSED   DONE  FAILED  OTHER\n");
    var shown: usize = 0;
    var i = names.len;
    while (i > 0 and shown < n) : (shown += 1) {
        i -= 1;
        const path = try std.fs.path.join(a, &.{ rec, "launches", names[i], "summary.json" });
        const text = sys.readFile(gpa, path, 1 << 20) catch {
            try w.print("{s:<31} {s:<13}\n", .{ names[i], "running?" });
            continue;
        };
        defer gpa.free(text);
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch continue;
        const counts = if (v.object.get("counts")) |c| c else std.json.Value{ .null = {} };
        const cnt = struct {
            fn of(c: std.json.Value, k: []const u8) u64 {
                return if (c == .object) (if (c.object.get(k)) |x| (if (x == .integer and x.integer > 0) @intCast(x.integer) else 0) else 0) else 0;
            }
        }.of;
        const done = cnt(counts, "completed") + cnt(counts, "reused");
        const bad = cnt(counts, "failed") + cnt(counts, "blocked");
        const other = cnt(counts, "cancelled") + cnt(counts, "not_started");
        const elapsed = float(v, "elapsed_s") orelse 0;
        var dur: [16]u8 = undefined;
        var dw: std.Io.Writer = .fixed(&dur);
        try duration(&dw, @intFromFloat(elapsed * 1e9));
        try w.print("{s:<31} {s:<13} {s} {d:>5} {d:>7} {d:>6}", .{ names[i], str(v, "status") orelse "?", dw.buffered(), done, bad, other });
        if (str(v, "error")) |e| try w.print("  {s}", .{e[0..@min(e.len, 100)]});
        try w.writeAll("\n");
    }
}

/// Prints the newest launch's summary, or its live view while it runs.
pub fn status(gpa: Allocator, io: std.Io, root: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try records.recordsDir(a, root);
    const dir = (try records.latestLaunch(gpa, a, rec)) orelse {
        std.debug.print("workz: no launch recorded in {s}\n", .{rec});
        return false;
    };
    const summary = sys.readFile(gpa, try std.fs.path.join(a, &.{ dir, "summary.json" }), 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return watch(gpa, io, root, true, 0),
        else => return err,
    };
    defer gpa.free(summary);
    try sys.writeAll(1, summary);
    return true;
}
