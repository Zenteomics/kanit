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
const term = @import("term.zig");
const model = @import("model.zig");
const clean = @import("clean.zig");
const Allocator = std.mem.Allocator;

pub const Status = enum {
    /// Selected but not yet ready: its producers have not finished.
    pending,
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
    /// Counters of a running attempt, sampled by the interactive view. A
    /// failed read keeps the last value; `live_cores` is the CPU used
    /// between the last two samples.
    live_memory: ?u64 = null,
    live_peak: ?u64 = null,
    live_cores: ?f64 = null,
    live_cpu_usec: ?u64 = null,
    live_cpu_ns: i128 = 0,
};

pub const SharedView = struct {
    name: []const u8,
    state: []const u8,
    /// The largest memory peak of any of its holders.
    memory_peak: ?u64 = null,
    /// cgroup of the current holder, for live counters.
    cg: ?[]const u8 = null,
    /// Memory the holder uses, sampled by the interactive view.
    live_memory: ?u64 = null,
    /// A container service, not mapped files.
    service: bool = false,
    /// Holders started, and the seconds they took to become ready.
    starts: u32 = 0,
    load_s: f64 = 0,
    loading_ns: i128 = 0,
    /// Memory the input is counted for: a service's declared memory, or the
    /// pages of its files.
    declared_mib: f64 = 0,
    failed: bool = false,
};

/// One run sample, taken every 5 s while rules run.
pub const Sample = struct {
    ns: i128,
    threads_reserved: f64,
    memory_reserved_mib: f64,
    /// The run cgroup's memory in use and CPU cores used, when isolated.
    memory_current: ?u64,
    cpu_cores: ?f64,
};

/// The time a ready rule waited for a resource group, for the advice on
/// whether a larger group would have started it earlier.
pub const GroupWait = struct { rule: usize, group: []const u8, from_ns: i128, to_ns: i128 = 0 };

/// The state of one launch, kept up to date from its event stream.
pub const Tracker = struct {
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    events_path: []const u8,
    offset: u64 = 0,
    /// Bytes of a line not yet terminated.
    partial: std.ArrayList(u8) = .empty,

    launch: []const u8 = "",
    /// Base name of the working directory, from `launch.json`; empty when
    /// it cannot be read.
    workdir_name: []const u8 = "",
    selected: u32 = 0,
    /// Time of the first event, and of `launch_started`, when the launch
    /// began its rules after its checks.
    started_ns: i128 = 0,
    launch_ns: i128 = 0,
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
    /// Every run sample, oldest first.
    samples: std.ArrayList(Sample) = .empty,
    /// Waits for resource groups; one still open has `to_ns` 0.
    group_waits: std.ArrayList(GroupWait) = .empty,
    /// The open group wait of each rule, by rule index.
    open_wait: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    pub fn init(gpa: Allocator, launch_dir: []const u8) !Tracker {
        var t: Tracker = .{ .arena = std.heap.ArenaAllocator.init(gpa), .gpa = gpa, .events_path = "" };
        errdefer t.arena.deinit();
        const a = t.arena.allocator();
        t.events_path = try std.fs.path.join(a, &.{ launch_dir, "events.jsonl" });
        t.launch = try a.dupe(u8, std.fs.path.basename(launch_dir));
        if (sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }), 1 << 20)) |text| {
            defer gpa.free(text);
            if (std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always })) |v| {
                if (str(v, "workdir")) |wd| t.workdir_name = std.fs.path.basename(wd);
            } else |_| {}
        } else |_| {}
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
            self.launch_ns = at;
            self.selected = @intCast(int(v, "selected") orelse 0);
            self.max_threads = @intCast(int(v, "max_threads") orelse 0);
            self.max_memory_mib = @intCast(int(v, "max_memory_mib") orelse 0);
            self.run_cg = if (str(v, "cgroup")) |cg| try a.dupe(u8, cg) else null;
            // Every selected rule is listed from the start, as pending.
            if (v.object.get("rules")) |rs| if (rs == .array) for (rs.array.items) |n| if (n == .string) {
                const r = try self.rule(n.string);
                r.status = .pending;
            };
        } else if (eql(u8, ev, "launch_finished")) {
            self.finished = true;
            self.finished_ns = at;
            self.final_status = try a.dupe(u8, str(v, "status") orelse "");
            self.final_error = try a.dupe(u8, str(v, "error") orelse "");
        } else if (eql(u8, ev, "sample")) {
            self.memory_current = if (int(v, "memory_current")) |m| @intCast(m) else null;
            self.cpu_cores = float(v, "cpu_cores_used");
            try self.samples.append(a, .{
                .ns = at,
                .threads_reserved = float(v, "threads_reserved") orelse 0,
                .memory_reserved_mib = float(v, "memory_reserved_mib") orelse 0,
                .memory_current = self.memory_current,
                .cpu_cores = self.cpu_cores,
            });
        } else if (std.mem.startsWith(u8, ev, "shared_")) {
            const s = try self.sharedView(str(v, "name") orelse "?");
            s.state = if (eql(u8, ev, "shared_loading")) "loading" else if (eql(u8, ev, "shared_loaded")) "ready" else if (eql(u8, ev, "shared_released")) "released" else if (eql(u8, ev, "shared_failed")) "failed" else s.state;
            if (int(v, "memory_peak")) |m| s.memory_peak = @max(s.memory_peak orelse 0, @as(u64, @intCast(m)));
            if (eql(u8, ev, "shared_loading")) {
                s.cg = if (str(v, "cgroup")) |cg| try a.dupe(u8, cg) else null;
                s.starts += 1;
                s.loading_ns = at;
                if (float(v, "memory_mib")) |m| {
                    s.service = true;
                    s.declared_mib = m;
                } else if (float(v, "bytes")) |b| s.declared_mib = b / 1048576.0;
            } else if (eql(u8, ev, "shared_loaded")) {
                if (s.loading_ns > 0) s.load_s += @as(f64, @floatFromInt(at - s.loading_ns)) / 1e9;
            } else if (eql(u8, ev, "shared_failed")) s.failed = true;
        } else if (str(v, "rule")) |name| {
            const r = try self.rule(name);
            const ri = self.index.get(name).?;
            // A rule's wait for a resource group ends when it waits for
            // something else or starts.
            if (eql(u8, ev, "task_waiting") or eql(u8, ev, "task_started")) {
                if (self.open_wait.fetchRemove(ri)) |kv| self.group_waits.items[kv.value].to_ns = at;
            }
            if (eql(u8, ev, "task_waiting")) {
                if (r.ready_ns == 0) r.ready_ns = at;
                r.status = .waiting;
                r.reason = try a.dupe(u8, str(v, "reason") orelse "");
                if (std.mem.startsWith(u8, r.reason, "group:")) {
                    try self.open_wait.put(a, ri, self.group_waits.items.len);
                    try self.group_waits.append(a, .{ .rule = ri, .group = r.reason["group:".len..], .from_ns = at });
                }
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
                r.live_memory = null;
                r.live_peak = null;
                r.live_cores = null;
                r.live_cpu_usec = null;
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

/// A path as shown to a person: relative to the current directory when it
/// lies below it, else as given.
pub fn shownPath(a: Allocator, path: []const u8) []const u8 {
    const here = sys.cwd(a) catch return path;
    const below = here.len > 1 and path.len > here.len + 1 and std.mem.startsWith(u8, path, here) and path[here.len] == '/';
    return if (below) path[here.len + 1 ..] else path;
}

/// The last non-empty line of a file, with control characters blanked and
/// cut to `max` bytes; allocated in `a`.
pub fn lastLine(gpa: Allocator, a: Allocator, path: []const u8, max: usize) []const u8 {
    const lines = lastLines(gpa, a, path, 1, max);
    return if (lines.len == 0) "" else lines[0];
}

/// The last `n` non-empty lines of a file, oldest first, with control
/// characters blanked and each cut to `max` bytes; allocated in `a`.
pub fn lastLines(gpa: Allocator, a: Allocator, path: []const u8, n: usize, max: usize) []const []const u8 {
    const tail = sys.readTail(gpa, path, 4096) catch return &.{};
    defer gpa.free(tail);
    var found: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitBackwardsScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        if (found.items.len == n) break;
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len == 0) continue;
        const out = a.dupe(u8, line[0..@min(line.len, max)]) catch break;
        for (out) |*c| if (c.* < 0x20 or c.* == 0x7f) {
            c.* = ' ';
        };
        found.append(a, out) catch break;
    }
    std.mem.reverse([]const u8, found.items);
    return found.items;
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
pub fn watch(gpa: Allocator, io: std.Io, root: []const u8, once: bool, interval_ms: u64, color: bool) !bool {
    var launch_arena = std.heap.ArenaAllocator.init(gpa);
    defer launch_arena.deinit();
    const rec = try records.recordsDir(launch_arena.allocator(), root);
    const dir = (try records.latestLaunch(gpa, launch_arena.allocator(), rec)) orelse {
        std.debug.print("workz: no launch recorded in {s}\n", .{rec});
        return false;
    };
    var tracker = try Tracker.init(gpa, dir);
    defer tracker.deinit();
    if (!once and term.isTerminal(0) and term.isTerminal(1)) return tui.run(gpa, &tracker, interval_ms, color);
    const tty = term.isTerminal(1);
    var obuf: [16384]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &obuf);
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

/// Writes a readable summary of an ended launch from its records: how it
/// ended and how long it took, the counts, its slowest rules or its
/// failures, where its records are, and what to run next.
pub fn writeSummary(gpa: Allocator, a: Allocator, w: *std.Io.Writer, launch_dir: []const u8, color: bool) !void {
    const s: term.Style = .{ .on = color };
    const text = try sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "summary.json" }), 1 << 20);
    defer gpa.free(text);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always });
    const outcome = str(v, "status") orelse "?";
    const elapsed = float(v, "elapsed_s") orelse 0;
    const counts = if (v == .object) v.object.get("counts") else null;
    const count = struct {
        fn of(c: ?std.json.Value, k: []const u8) u64 {
            const o = c orelse return 0;
            return if (int(o, k)) |n| @intCast(n) else 0;
        }
    }.of;
    const completed = count(counts, "completed");
    const reused = count(counts, "reused");
    const failed = count(counts, "failed");
    const blocked = count(counts, "blocked");
    const cancelled = count(counts, "cancelled");
    const not_started = count(counts, "not_started");
    const selected = if (int(v, "selected")) |n| @as(u64, @intCast(n)) else 0;
    // The label column holds the outcome badge and one space after it.
    const col = @max(outcome.len + 3, 10);
    const label = struct {
        fn put(wr: *std.Io.Writer, st: term.Style, width: usize, name: []const u8) !void {
            try wr.print(" {s}{s}{s}", .{ st.dim(), name, st.reset() });
            try wr.splatByteAll(' ', width -| name.len);
        }
    }.put;

    const badge = if (std.mem.eql(u8, outcome, "completed")) "\x1b[42;30;1m" else if (std.mem.eql(u8, outcome, "interrupted")) "\x1b[45;30;1m" else "\x1b[41;97;1m";
    if (color) {
        try w.print(" {s} {s} \x1b[0m", .{ badge, outcome });
        try w.splatByteAll(' ', col - (outcome.len + 2));
    } else try label(w, s, col, outcome);
    var dur: [32]u8 = undefined;
    const took = std.fmt.bufPrint(&dur, "{d:.1} s", .{elapsed}) catch "";
    if (std.mem.eql(u8, outcome, "refused")) {
        try w.print("{s}\n", .{str(v, "error") orelse ""});
    } else if (std.mem.eql(u8, outcome, "completed")) {
        try w.print("{d} rules in {s}: {d} ran, {d} reused", .{ selected, took, completed, reused });
        if (cancelled > 0) try w.print(", {d} stopped", .{cancelled});
        try w.writeAll("\n");
    } else {
        try w.print("after {s}: {d} completed, {d} reused", .{ took, completed, reused });
        if (failed > 0) try w.print(", {s}{d} failed{s}", .{ s.red(), failed, s.reset() });
        if (blocked > 0) try w.print(", {d} blocked", .{blocked});
        if (cancelled > 0) try w.print(", {d} cancelled", .{cancelled});
        if (not_started > 0) try w.print(", {d} not started", .{not_started});
        try w.writeAll("\n");
        if (str(v, "error")) |e| {
            try label(w, s, col, "error");
            try w.print("{s}{s}{s}\n", .{ s.red(), e, s.reset() });
        }
    }

    // The last attempt of each rule, from the attempt records.
    const rows = model.attempts(gpa, a, launch_dir) catch &.{};
    var last: std.ArrayList(model.Attempt) = .empty;
    for (rows, 0..) |r, i| {
        if (i + 1 < rows.len and std.mem.eql(u8, rows[i + 1].rule, r.rule)) continue;
        try last.append(a, r);
    }
    // Up to five failures, their reasons aligned after the longest name.
    const max_failures = 5;
    var failures: usize = 0;
    var name_w: usize = 0;
    for (last.items) |r| if (!std.mem.eql(u8, r.status, "completed")) {
        if (failures < max_failures) name_w = @max(name_w, @min(r.rule.len, 40));
        failures += 1;
    };
    var shown: usize = 0;
    for (last.items) |r| {
        if (std.mem.eql(u8, r.status, "completed")) continue;
        if (shown == max_failures) break;
        try label(w, s, col, if (shown == 0) "failures" else "");
        try w.print("{s}{s}{s}", .{ s.bold(), r.rule, s.reset() });
        try w.splatByteAll(' ', name_w -| r.rule.len + 2);
        try w.print("{s}{s}{s}\n", .{ s.red(), r.reason, s.reset() });
        // The attempt's last error line, unless the reason already holds it.
        const said = if (r.dir.len == 0) "" else lastLine(gpa, a, try std.fs.path.join(a, &.{ r.dir, "stderr.log" }), 160);
        if (said.len > 0 and std.mem.indexOf(u8, r.reason, said) == null) {
            try label(w, s, col, "");
            try w.splatByteAll(' ', name_w + 2);
            try w.print("{s}| {s}{s}\n", .{ s.dim(), said, s.reset() });
        }
        shown += 1;
    }
    if (failures > shown) {
        try label(w, s, col, "");
        try w.print("and {d} more; workz report lists every attempt\n", .{failures - shown});
    }
    if (shown == 0 and last.items.len > 0) {
        std.mem.sort(model.Attempt, last.items, {}, struct {
            fn gt(_: void, x: model.Attempt, y: model.Attempt) bool {
                return x.wall_s > y.wall_s;
            }
        }.gt);
        try label(w, s, col, "slowest");
        for (last.items[0..@min(last.items.len, 3)], 0..) |r, i| try w.print("{s}{s} {d:.1} s", .{ if (i == 0) "" else ", ", r.rule, r.wall_s });
        try w.writeAll("\n");
    }
    // The launch's own page sits among its records; a launch without one
    // shows its directory.
    const page = try std.fs.path.join(a, &.{ launch_dir, "report.html" });
    const has_page = sys.exists(gpa, page);
    try label(w, s, col, if (has_page) "page" else "records");
    try w.print("{s}\n", .{shownPath(a, if (has_page) page else launch_dir)});
    try label(w, s, col, "next");
    if (std.mem.eql(u8, outcome, "completed")) {
        try w.print("{s}workz report --bottlenecks{s}   what limited this launch\n", .{ s.cyan(), s.reset() });
        if (!has_page) {
            try label(w, s, col, "");
            try w.print("{s}workz report --format html -o report.html{s}   the launch as one page\n", .{ s.cyan(), s.reset() });
        }
    } else if (std.mem.eql(u8, outcome, "refused")) {
        try w.writeAll("fix the cause above and run the same command again\n");
    } else {
        for (last.items) |r| if (!std.mem.eql(u8, r.status, "completed")) {
            try w.print("{s}workz logs {s}{s}   the output of the failed attempt\n", .{ s.cyan(), r.rule, s.reset() });
            try label(w, s, col, "");
            break;
        };
        try w.writeAll("run the same command again: rules that completed are reused\n");
    }
}

/// Prints the newest launch's summary, or its live view while it runs: with
/// `human`, the readable summary, else its `summary.json` as written.
pub fn status(gpa: Allocator, io: std.Io, root: []const u8, human: bool, color: bool) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try records.recordsDir(a, root);
    const dir = (try records.latestLaunch(gpa, a, rec)) orelse {
        std.debug.print("workz: no launch recorded in {s}\n", .{rec});
        return false;
    };
    const summary = sys.readFile(gpa, try std.fs.path.join(a, &.{ dir, "summary.json" }), 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return watch(gpa, io, root, true, 0, false),
        else => return err,
    };
    defer gpa.free(summary);
    if (human) {
        var buf: [16384]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(io, &buf);
        try writeSummary(gpa, a, &out.interface, dir, color);
        try out.interface.flush();
        return true;
    }
    try sys.writeAll(1, summary);
    return true;
}
