//! The state of one launch, kept up to date from its event stream: every
//! selected rule with its status and attempt, the shared inputs, the run
//! samples and the waits for resource groups. The stream is read
//! incrementally: an update parses only the complete lines appended since
//! the previous one. The live views and the reports both build on it.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fields = @import("fields.zig");
const Allocator = std.mem.Allocator;
const str = fields.str;
const int = fields.int;
const whole = fields.whole;
const float = fields.float;

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

    /// The word shown for the state: a rule being stopped is "stopping",
    /// and "cancelled" once it has ended.
    pub fn label(s: Status) []const u8 {
        return if (s == .cancelling) "stopping" else @tagName(s);
    }

    pub fn done(s: Status) bool {
        return s == .completed or s == .reused;
    }
};

pub const RuleView = struct {
    name: []const u8,
    status: Status = .waiting,
    attempt: u32 = 0,
    /// The shared inputs its latest attempt holds.
    shared: []const []const u8 = &.{},
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
    /// Rules whose attempts started using it, by rule index, each once.
    users: std.ArrayList(usize) = .empty,
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
    /// Seconds its holders held memory, from loading to release, and when
    /// the current one began; a holder still held when the records end
    /// counts to that end.
    held_s: f64 = 0,
    held_since: i128 = 0,
};

/// One run sample, taken every 5 s while rules run.
pub const Sample = struct {
    ns: i128,
    threads_reserved: f64,
    memory_reserved_mib: f64,
    /// The part of it shared inputs hold, once.
    shared_reserved_mib: f64 = 0,
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
    max_jobs: u32 = 0,
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
    /// The engine that ran the launch, with its digest, from `launch.json`.
    engine: []const u8 = "",
    engine_key: ?i64 = null,
    /// Bytes of earlier outputs moved into `previous/` so far.
    previous_bytes: u64 = 0,
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
                if (str(v, "engine")) |e| t.engine = e;
                t.engine_key = int(v, "engine_key");
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
        // A line that does not parse is skipped; running out of memory is not.
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch |err| return if (err == error.OutOfMemory) err else {};
        const a = self.arena.allocator();
        const ev = str(v, "event") orelse return;
        const at = parseTime(str(v, "time") orelse "") orelse 0;
        if (self.started_ns == 0) self.started_ns = at;
        const eql = std.mem.eql;
        if (eql(u8, ev, "launch_started")) {
            self.launch_ns = at;
            self.selected = whole(u32, v, "selected") orelse 0;
            self.max_threads = whole(u32, v, "max_threads") orelse 0;
            self.max_memory_mib = whole(u64, v, "max_memory_mib") orelse 0;
            self.max_jobs = whole(u32, v, "jobs") orelse 0;
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
        } else if (eql(u8, ev, "output_preserved")) {
            self.previous_bytes += whole(u64, v, "bytes") orelse 0;
        } else if (eql(u8, ev, "sample")) {
            self.memory_current = if (int(v, "memory_current")) |m| @intCast(m) else null;
            self.cpu_cores = float(v, "cpu_cores_used");
            try self.samples.append(a, .{
                .ns = at,
                .threads_reserved = float(v, "threads_reserved") orelse 0,
                .memory_reserved_mib = float(v, "memory_reserved_mib") orelse 0,
                .shared_reserved_mib = float(v, "shared_reserved_mib") orelse 0,
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
            // Its memory is held from loading until release or failure.
            if (eql(u8, ev, "shared_loading")) {
                s.held_since = at;
            } else if ((eql(u8, ev, "shared_released") or eql(u8, ev, "shared_failed")) and s.held_since > 0) {
                s.held_s += @as(f64, @floatFromInt(at - s.held_since)) / 1e9;
                s.held_since = 0;
            }
        } else if (std.mem.startsWith(u8, ev, "task_")) if (str(v, "rule")) |name| {
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
                r.attempt = whole(u32, v, "attempt") orelse 0;
                r.dir = try a.dupe(u8, str(v, "directory") orelse "");
                r.cg = if (str(v, "cgroup")) |cg| try a.dupe(u8, cg) else null;
                r.threads = whole(u32, v, "threads") orelse 0;
                r.memory_mib = whole(u64, v, "memory_mib") orelse 0;
                r.started_ns = at;
                r.finished_ns = 0;
                // The shared inputs the attempt holds.
                if (v.object.get("shared")) |list| if (list == .array) {
                    var names: std.ArrayList([]const u8) = .empty;
                    for (list.array.items) |item| if (item == .string) {
                        try names.append(a, try a.dupe(u8, item.string));
                        const sv = try self.sharedView(item.string);
                        if (std.mem.indexOfScalar(usize, sv.users.items, ri) == null) try sv.users.append(a, ri);
                    };
                    r.shared = names.items;
                };
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
        };
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
