//! The scheduler's decisions, apart from the processes they start: whether a
//! rule's parents let it run, whether it fits the budget, the order of ready
//! rules, why an attempt failed and whether it runs again, and what a timer
//! or an interrupt does. Every function takes plain data, and the time as a
//! number of nanoseconds on the monotonic clock, so the same inputs always
//! give the same decision. The engine in `run.zig` applies the decisions.
const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const Status = enum { pending, ready, staging, running, completed, reused, failed, blocked, cancelled, not_started, excluded };

pub const Parents = enum { waiting, ready, blocked };

pub fn parents(tasks: anytype, of: []const usize) Parents {
    var verdict: Parents = .ready;
    for (of) |p| switch (tasks[p].status) {
        .completed, .reused, .excluded => {},
        .failed, .blocked, .cancelled, .not_started => return .blocked,
        else => verdict = .waiting,
    };
    return verdict;
}

pub const GroupNeed = struct { index: usize, count: u32 };

pub const Need = struct {
    threads: u32,
    memory_mib: u64,
    groups: []const GroupNeed = &.{},
};

pub const Budget = struct {
    threads: u32,
    memory_mib: u64,
    jobs: u32,
    groups: []const u32 = &.{},
};

pub const Usage = struct {
    threads: u32 = 0,
    memory_mib: u64 = 0,
    jobs: u32 = 0,
    groups: []u32 = &.{},

    pub fn take(self: *Usage, need: Need) void {
        self.jobs += 1;
        self.threads += need.threads;
        self.memory_mib += need.memory_mib;
        for (need.groups) |g| self.groups[g.index] += g.count;
    }

    pub fn give(self: *Usage, need: Need) void {
        self.jobs -= 1;
        self.threads -= need.threads;
        self.memory_mib -= need.memory_mib;
        for (need.groups) |g| self.groups[g.index] -= g.count;
    }
};

pub const Limit = union(enum) { threads, memory, jobs, group: usize };

pub fn blocker(budget: Budget, usage: Usage, need: Need, freed_mib: u64) ?Limit {
    if (usage.threads + need.threads > budget.threads) return .threads;
    if (usage.memory_mib - freed_mib + need.memory_mib > budget.memory_mib) return .memory;
    if (usage.jobs + 1 > budget.jobs) return .jobs;
    for (need.groups) |g| if (usage.groups[g.index] + g.count > budget.groups[g.index]) return .{ .group = g.index };
    return null;
}

pub fn neverFits(budget: Budget, threads: u32, memory_mib: u64) bool {
    return threads > budget.threads or memory_mib > budget.memory_mib;
}

pub fn estimates(a: Allocator, steps: []const []const u8, recorded_wall_s: []const f64) ![]f64 {
    const est = try a.alloc(f64, steps.len);
    var by_step: std.StringHashMapUnmanaged(std.ArrayList(f64)) = .empty;
    defer {
        var it = by_step.valueIterator();
        while (it.next()) |list| list.deinit(a);
        by_step.deinit(a);
    }
    for (steps, recorded_wall_s, est) |step, wall, *e| {
        e.* = 0;
        if (wall <= 0) continue;
        e.* = wall;
        const gop = try by_step.getOrPut(a, step);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, wall);
    }
    for (steps, est) |step, *e| if (e.* == 0) {
        e.* = 1;
        if (by_step.get(step)) |list| {
            std.mem.sort(f64, list.items, {}, std.sort.asc(f64));
            e.* = model.median(list.items);
        }
    };
    return est;
}

pub fn ranks(a: Allocator, order: []const usize, children: []const []const usize, est: []const f64) ![]f64 {
    const out = try a.alloc(f64, est.len);
    var k = order.len;
    while (k > 0) {
        k -= 1;
        const i = order[k];
        var after: f64 = 0;
        for (children[i]) |c| after = @max(after, out[c]);
        out[i] = est[i] + after;
    }
    return out;
}

pub const Order = struct {
    priorities: []const i64,
    ranks: []const f64,
    ready_seq: []const u64,

    pub fn before(self: Order, x: usize, y: usize) bool {
        if (self.priorities[x] != self.priorities[y]) return self.priorities[x] > self.priorities[y];
        if (self.ranks.len > 0 and self.ranks[x] != self.ranks[y]) return self.ranks[x] > self.ranks[y];
        if (self.ready_seq[x] != self.ready_seq[y]) return self.ready_seq[x] < self.ready_seq[y];
        return x < y;
    }
};

pub const End = struct {
    lost_service: ?[]const u8 = null,
    cancelled: bool = false,
    stop_why: []const u8 = "cancelled",
    timed_out: bool = false,
    timeout_s: u64 = 0,
    oom_kills: u64 = 0,
    memory_mib: u64 = 0,
    exit_code: ?u8 = null,
    signal: ?u32 = null,
    container: bool = false,
    last_line: []const u8 = "",
};

pub const Failure = struct {
    reason: []const u8,
    quote_stderr: bool = false,
};

pub fn failure(a: Allocator, e: End) !?Failure {
    if (e.lost_service) |why| return .{ .reason = why };
    if (e.cancelled) return .{ .reason = e.stop_why };
    if (e.timed_out) return .{ .reason = try std.fmt.allocPrint(a, "timed out after {d} s", .{e.timeout_s}) };
    if (e.oom_kills > 0) return .{ .reason = try std.fmt.allocPrint(a, "out of memory: could not stay within its {d} MiB request", .{e.memory_mib}) };
    if (e.exit_code) |c| {
        if (c == 0) return null;
        if (e.container and c == 125) return .{ .reason = try std.fmt.allocPrint(a, "status 125: the container engine failed, or the command exited 125: {s}", .{e.last_line}) };
        if (e.container and (c == 126 or c == 127)) return .{ .reason = try std.fmt.allocPrint(a, "the command could not run in the container (status {d}): {s}", .{ c, e.last_line }) };
        return .{ .reason = try std.fmt.allocPrint(a, "exited with status {d}", .{c}), .quote_stderr = true };
    }
    if (e.signal) |s| return .{ .reason = try std.fmt.allocPrint(a, "killed by signal {d}", .{s}) };
    return .{ .reason = "" };
}

pub fn retried(attempts: u32, max_attempts: u32, cancelled: bool, stopping: bool, lost_service: bool) bool {
    return !cancelled and !stopping and !lost_service and attempts < max_attempts;
}

pub const container_stop_ns: i128 = 10 * std.time.ns_per_s;

pub fn killAt(now: i128, grace_ns: i128, container: bool) i128 {
    return now + grace_ns + if (container) container_stop_ns else 0;
}

pub fn deadline(started: i128, timeout_s: ?u64) ?i128 {
    const s = timeout_s orelse return null;
    return started + @as(i128, s) * std.time.ns_per_s;
}

pub const Timer = enum { none, terminate, kill };

pub fn timer(now: i128, deadline_ns: ?i128, kill_at: ?i128, timed_out: bool) Timer {
    if (kill_at) |k| return if (now >= k) .kill else .none;
    if (deadline_ns) |d| if (now >= d and !timed_out) return .terminate;
    return .none;
}

pub const Interrupt = enum { stop, kill, ignore };

pub fn interrupt(signalled_at: ?i128, now: i128) Interrupt {
    const at = signalled_at orelse return .stop;
    return if (now - at >= std.time.ns_per_s) .kill else .ignore;
}
