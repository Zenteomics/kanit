//! Unit tests of the scheduler's decisions: readiness, the budget, the order
//! of ready rules, failure reasons, retries, timers and interrupts, and a
//! seeded run of random graphs on a fake clock.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const schedule = workz.schedule;
const Status = schedule.Status;

const T = struct { status: Status };

const s_ns = std.time.ns_per_s;

test "[unit] - [scheduler]: a rule is ready when every parent completed, was reused or is excluded" {
    const tasks = [_]T{ .{ .status = .completed }, .{ .status = .reused }, .{ .status = .excluded }, .{ .status = .running }, .{ .status = .failed }, .{ .status = .pending } };
    const Case = struct { of: []const usize, want: schedule.Parents };
    const cases = [_]Case{
        .{ .of = &.{}, .want = .ready },
        .{ .of = &.{ 0, 1, 2 }, .want = .ready },
        .{ .of = &.{ 0, 3 }, .want = .waiting },
        .{ .of = &.{ 0, 5 }, .want = .waiting },
        .{ .of = &.{ 3, 4 }, .want = .blocked },
        .{ .of = &.{ 4, 3 }, .want = .blocked },
    };
    for (cases) |c| try testing.expectEqual(c.want, schedule.parents(&tasks, c.of));
    inline for (.{ Status.failed, Status.blocked, Status.cancelled, Status.not_started }) |st| {
        const one = [_]T{.{ .status = st }};
        try testing.expectEqual(schedule.Parents.blocked, schedule.parents(&one, &.{0}));
    }
}

test "[unit] - [scheduler]: a rule waits for the first limit it would pass, threads, memory, jobs, then groups" {
    var used = [_]u32{ 1, 0 };
    const budget: schedule.Budget = .{ .threads = 8, .memory_mib = 1000, .jobs = 3, .groups = &.{ 2, 1 } };
    const usage: schedule.Usage = .{ .threads = 6, .memory_mib = 900, .jobs = 2, .groups = &used };
    const Case = struct { need: schedule.Need, freed: u64 = 0, want: ?schedule.Limit };
    const cases = [_]Case{
        .{ .need = .{ .threads = 2, .memory_mib = 100 }, .want = null },
        .{ .need = .{ .threads = 3, .memory_mib = 100 }, .want = .threads },
        .{ .need = .{ .threads = 3, .memory_mib = 500 }, .want = .threads },
        .{ .need = .{ .threads = 2, .memory_mib = 101 }, .want = .memory },
        .{ .need = .{ .threads = 2, .memory_mib = 300 }, .freed = 200, .want = null },
        .{ .need = .{ .threads = 2, .memory_mib = 100, .groups = &.{.{ .index = 0, .count = 1 }} }, .want = null },
        .{ .need = .{ .threads = 2, .memory_mib = 100, .groups = &.{.{ .index = 0, .count = 2 }} }, .want = .{ .group = 0 } },
        .{ .need = .{ .threads = 2, .memory_mib = 100, .groups = &.{ .{ .index = 0, .count = 1 }, .{ .index = 1, .count = 2 } } }, .want = .{ .group = 1 } },
    };
    for (cases) |c| try testing.expectEqual(c.want, schedule.blocker(budget, usage, c.need, c.freed));
    const full: schedule.Usage = .{ .threads = 0, .memory_mib = 0, .jobs = 3, .groups = &used };
    try testing.expectEqual(@as(?schedule.Limit, .jobs), schedule.blocker(budget, full, .{ .threads = 1, .memory_mib = 1 }, 0));
}

test "[edge] - [scheduler]: a rule that exactly fills the budget fits, and one unit more never fits" {
    const budget: schedule.Budget = .{ .threads = 4, .memory_mib = 512, .jobs = 1 };
    try testing.expectEqual(@as(?schedule.Limit, null), schedule.blocker(budget, .{}, .{ .threads = 4, .memory_mib = 512 }, 0));
    try testing.expect(!schedule.neverFits(budget, 4, 512));
    try testing.expect(schedule.neverFits(budget, 5, 512));
    try testing.expect(schedule.neverFits(budget, 4, 513));
}

test "[property] - [scheduler]: giving back what was taken restores the usage" {
    var groups = [_]u32{ 0, 0 };
    var usage: schedule.Usage = .{ .groups = &groups };
    const a: schedule.Need = .{ .threads = 3, .memory_mib = 700, .groups = &.{.{ .index = 1, .count = 2 }} };
    const b: schedule.Need = .{ .threads = 1, .memory_mib = 64, .groups = &.{ .{ .index = 0, .count = 1 }, .{ .index = 1, .count = 1 } } };
    usage.take(a);
    usage.take(b);
    try testing.expectEqual(@as(u32, 4), usage.threads);
    try testing.expectEqual(@as(u64, 764), usage.memory_mib);
    try testing.expectEqual(@as(u32, 2), usage.jobs);
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, usage.groups);
    usage.give(a);
    usage.give(b);
    try testing.expectEqual(@as(u32, 0), usage.threads + usage.jobs);
    try testing.expectEqual(@as(u64, 0), usage.memory_mib);
    try testing.expectEqualSlices(u32, &.{ 0, 0 }, usage.groups);
}

test "[unit] - [scheduler]: estimates use the recorded time, else the median of the step, else one second" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const steps = [_][]const u8{ "align", "align", "align", "align", "count", "sort" };
    const walls = [_]f64{ 10, 20, 0, 40, 0, -1 };
    const est = try schedule.estimates(arena.allocator(), &steps, &walls);
    try testing.expectEqualSlices(f64, &.{ 10, 20, 20, 40, 1, 1 }, est);
    const two = try schedule.estimates(arena.allocator(), &.{ "x", "x", "x" }, &.{ 4, 6, 0 });
    try testing.expectEqual(@as(f64, 5), two[2]);
}

test "[unit] - [scheduler]: a rule's rank is its estimate plus the longest chain of work after it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const order = [_]usize{ 0, 1, 2, 3 };
    const children = [_][]const usize{ &.{ 1, 2 }, &.{3}, &.{3}, &.{} };
    const est = [_]f64{ 1, 5, 2, 3 };
    const ranks = try schedule.ranks(arena.allocator(), &order, &children, &est);
    try testing.expectEqualSlices(f64, &.{ 9, 8, 5, 3 }, ranks);
}

test "[unit] - [scheduler]: ready rules go by priority, then the longest work after them, then the order they became ready" {
    const order: schedule.Order = .{
        .priorities = &.{ 0, 0, 5, 0, 0 },
        .ranks = &.{ 3, 9, 1, 3, 3 },
        .ready_seq = &.{ 4, 7, 9, 2, 2 },
    };
    var ready = [_]usize{ 0, 1, 2, 3, 4 };
    std.mem.sort(usize, &ready, order, schedule.Order.before);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 3, 4, 0 }, &ready);
    const no_ranks: schedule.Order = .{ .priorities = &.{ 0, 0 }, .ranks = &.{}, .ready_seq = &.{ 2, 1 } };
    try testing.expect(no_ranks.before(1, 0));
}

test "[unit] - [scheduler]: an attempt's failure names its first cause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { end: schedule.End, reason: ?[]const u8, quote: bool = false };
    const cases = [_]Case{
        .{ .end = .{ .exit_code = 0 }, .reason = null },
        .{ .end = .{ .exit_code = 3 }, .reason = "exited with status 3", .quote = true },
        .{ .end = .{ .signal = 9 }, .reason = "killed by signal 9" },
        .{ .end = .{}, .reason = "" },
        .{ .end = .{ .exit_code = 0, .timed_out = true, .timeout_s = 90 }, .reason = "timed out after 90 s" },
        .{ .end = .{ .signal = 9, .oom_kills = 1, .memory_mib = 512 }, .reason = "out of memory: could not stay within its 512 MiB request" },
        .{ .end = .{ .signal = 15, .cancelled = true, .stop_why = "cancelled: the launch was interrupted", .timed_out = true }, .reason = "cancelled: the launch was interrupted" },
        .{ .end = .{ .exit_code = 0, .cancelled = true, .lost_service = "its service index failed" }, .reason = "its service index failed" },
        .{ .end = .{ .exit_code = 125, .container = true, .last_line = "Error: no such image" }, .reason = "status 125: the container engine failed, or the command exited 125: Error: no such image" },
        .{ .end = .{ .exit_code = 127, .container = true, .last_line = "sh: tool: not found" }, .reason = "the command could not run in the container (status 127): sh: tool: not found" },
        .{ .end = .{ .exit_code = 127 }, .reason = "exited with status 127", .quote = true },
        .{ .end = .{ .exit_code = 1, .container = true }, .reason = "exited with status 1", .quote = true },
    };
    for (cases) |c| {
        const got = try schedule.failure(a, c.end);
        if (c.reason) |want| {
            try testing.expectEqualStrings(want, got.?.reason);
            try testing.expectEqual(c.quote, got.?.quote_stderr);
        } else try testing.expectEqual(@as(?schedule.Failure, null), got);
    }
}

test "[unit] - [scheduler]: a failed attempt runs again only with attempts left and nothing stopping it" {
    try testing.expect(schedule.retried(1, 2, false, false, false));
    try testing.expect(!schedule.retried(2, 2, false, false, false));
    try testing.expect(!schedule.retried(1, 2, true, false, false));
    try testing.expect(!schedule.retried(1, 2, false, true, false));
    try testing.expect(!schedule.retried(1, 2, false, false, true));
    try testing.expect(!schedule.retried(1, 1, false, false, false));
}

test "[unit] - [scheduler]: a timeout terminates at the deadline and kills after the grace period" {
    const started: i128 = 1000 * s_ns;
    const d = schedule.deadline(started, 90).?;
    try testing.expectEqual(started + 90 * s_ns, d);
    try testing.expectEqual(@as(?i128, null), schedule.deadline(started, null));
    try testing.expectEqual(schedule.Timer.none, schedule.timer(d - 1, d, null, false));
    try testing.expectEqual(schedule.Timer.terminate, schedule.timer(d, d, null, false));
    try testing.expectEqual(schedule.Timer.none, schedule.timer(d + s_ns, d, null, true));
    const kill = schedule.killAt(d, 10 * s_ns, false);
    try testing.expectEqual(d + 10 * s_ns, kill);
    try testing.expectEqual(d + 20 * s_ns, schedule.killAt(d, 10 * s_ns, true));
    try testing.expectEqual(d + schedule.container_stop_ns, schedule.killAt(d, 0, true));
    try testing.expectEqual(schedule.Timer.none, schedule.timer(kill - 1, null, kill, true));
    try testing.expectEqual(schedule.Timer.kill, schedule.timer(kill, null, kill, true));
    try testing.expectEqual(schedule.Timer.kill, schedule.timer(kill, d, kill, false));
}

test "[unit] - [scheduler]: the first interrupt stops the launch, and another a second later kills" {
    const t0: i128 = 50 * s_ns;
    try testing.expectEqual(schedule.Interrupt.stop, schedule.interrupt(null, t0));
    try testing.expectEqual(schedule.Interrupt.ignore, schedule.interrupt(t0, t0 + s_ns - 1));
    try testing.expectEqual(schedule.Interrupt.kill, schedule.interrupt(t0, t0 + s_ns));
    try testing.expectEqual(schedule.Interrupt.kill, schedule.interrupt(t0, t0 + 60 * s_ns));
}

const Sim = struct {
    const Rule = struct { threads: u32, memory_mib: u64, group: ?usize, parents: []usize, children: std.ArrayList(usize) = .empty, wall: i128 };

    rules: []Rule,
    budget: schedule.Budget,

    fn need(self: *const Sim, i: usize, buf: *[1]schedule.GroupNeed) schedule.Need {
        const r = self.rules[i];
        if (r.group) |g| {
            buf[0] = .{ .index = g, .count = 1 };
            return .{ .threads = r.threads, .memory_mib = r.memory_mib, .groups = buf };
        }
        return .{ .threads = r.threads, .memory_mib = r.memory_mib };
    }
};

fn simulate(a: std.mem.Allocator, rnd: std.Random) !void {
    const n = rnd.intRangeAtMost(usize, 1, 30);
    const groups = [_]u32{ rnd.intRangeAtMost(u32, 1, 3), rnd.intRangeAtMost(u32, 1, 3) };
    var sim: Sim = .{
        .rules = try a.alloc(Sim.Rule, n),
        .budget = .{ .threads = rnd.intRangeAtMost(u32, 1, 16), .memory_mib = rnd.intRangeAtMost(u64, 64, 4096), .jobs = rnd.intRangeAtMost(u32, 1, 8), .groups = &groups },
    };
    for (sim.rules, 0..) |*r, i| {
        var parents: std.ArrayList(usize) = .empty;
        if (i > 0) for (0..rnd.intRangeAtMost(usize, 0, @min(i, 3))) |_| {
            const p = rnd.uintLessThan(usize, i);
            if (std.mem.indexOfScalar(usize, parents.items, p) == null) try parents.append(a, p);
        };
        r.* = .{
            .threads = rnd.intRangeAtMost(u32, 1, 20),
            .memory_mib = rnd.intRangeAtMost(u64, 1, 5000),
            .group = if (rnd.boolean()) rnd.uintLessThan(usize, 2) else null,
            .parents = parents.items,
            .wall = rnd.intRangeAtMost(i128, 1, 100) * s_ns,
        };
        for (parents.items) |p| try sim.rules[p].children.append(a, i);
    }
    const order = try a.alloc(usize, n);
    for (order, 0..) |*o, i| o.* = i;
    const children = try a.alloc([]const usize, n);
    for (children, sim.rules) |*c, r| c.* = r.children.items;
    const steps = try a.alloc([]const u8, n);
    @memset(steps, "s");
    const walls = try a.alloc(f64, n);
    for (walls, sim.rules) |*w, r| w.* = @floatFromInt(@divTrunc(r.wall, s_ns));
    const ranks = try schedule.ranks(a, order, children, try schedule.estimates(a, steps, walls));
    const priorities = try a.alloc(i64, n);
    for (priorities) |*p| p.* = rnd.intRangeAtMost(i64, 0, 2);
    const seq = try a.alloc(u64, n);
    @memset(seq, 0);
    const tasks = try a.alloc(T, n);
    @memset(tasks, .{ .status = .pending });
    const ends = try a.alloc(i128, n);
    var used = [_]u32{ 0, 0 };
    var usage: schedule.Usage = .{ .groups = &used };
    var now: i128 = 0;
    var counter: u64 = 0;
    var done: usize = 0;
    var gbuf: [1]schedule.GroupNeed = undefined;
    while (done < n) {
        var progressed = false;
        for (tasks, 0..) |*t, i| if (t.status == .pending) switch (schedule.parents(tasks, sim.rules[i].parents)) {
            .blocked => {
                t.status = .blocked;
                done += 1;
                progressed = true;
            },
            .ready => {
                t.status = .ready;
                counter += 1;
                seq[i] = counter;
                progressed = true;
            },
            .waiting => {},
        };
        var ready: std.ArrayList(usize) = .empty;
        for (tasks, 0..) |t, i| if (t.status == .ready) try ready.append(a, i);
        std.mem.sort(usize, ready.items, schedule.Order{ .priorities = priorities, .ranks = ranks, .ready_seq = seq }, schedule.Order.before);
        for (ready.items) |i| {
            const r = sim.rules[i];
            if (schedule.neverFits(sim.budget, r.threads, r.memory_mib)) {
                tasks[i].status = .failed;
                done += 1;
                progressed = true;
                continue;
            }
            const nd = sim.need(i, &gbuf);
            if (schedule.blocker(sim.budget, usage, nd, 0) != null) continue;
            for (r.parents) |p| try testing.expectEqual(Status.completed, tasks[p].status);
            usage.take(nd);
            try testing.expect(usage.threads <= sim.budget.threads and usage.memory_mib <= sim.budget.memory_mib and usage.jobs <= sim.budget.jobs);
            for (used, groups) |u, max| try testing.expect(u <= max);
            tasks[i].status = .running;
            ends[i] = now + r.wall;
        }
        for (tasks, 0..) |t, i| if (t.status == .ready) try testing.expect(schedule.blocker(sim.budget, usage, sim.need(i, &gbuf), 0) != null);
        var next: ?i128 = null;
        for (tasks, 0..) |t, i| if (t.status == .running) {
            next = if (next) |x| @min(x, ends[i]) else ends[i];
        };
        const at = next orelse {
            if (progressed) continue;
            for (tasks) |t| try testing.expect(t.status != .ready and t.status != .pending);
            break;
        };
        now = at;
        for (tasks, 0..) |*t, i| if (t.status == .running and ends[i] == now) {
            t.status = .completed;
            usage.give(sim.need(i, &gbuf));
            done += 1;
        };
    }
    try testing.expectEqual(n, done);
    try testing.expectEqual(@as(u32, 0), usage.threads + usage.jobs);
    try testing.expectEqual(@as(u64, 0), usage.memory_mib);
}

test "[property] - [scheduler]: random graphs never exceed the budget, never start a rule early and leave no fitting rule waiting" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    for (0..300) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        simulate(arena.allocator(), prng.random()) catch |err| {
            std.debug.print("seed {d}\n", .{testing.random_seed});
            return err;
        };
    }
}
