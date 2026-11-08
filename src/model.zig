//! A launch as its records describe it, read once for every report
//! (`load`), or kept current while the launch runs (`Live`).
//!
//! The event stream gives the state of every selected rule, the run samples
//! and the shared inputs (`tracker.Tracker`); the attempt records give what
//! each attempt used; the records of earlier launches give the runs whose
//! outputs this launch reused; the workflow snapshot gives the graph, so
//! the pipeline keeps its shape where nothing ran. A figure that several
//! reports show is computed here, once.
//!
//! Two scopes are kept apart. The pipeline sections (steps, samples, labels,
//! sizing) use the latest completed run of every rule, this launch's or the
//! one it reused. The launch sections (critical path, waits, budget,
//! failures) use this launch's attempts only.
const std = @import("std");
const sys = @import("sys.zig");
const state = @import("state.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const tracker = @import("tracker.zig");
const fields = @import("fields.zig");
const records = @import("records.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const eql = std.mem.eql;
const get = fields.get;
const num = fields.number;

// --- Attempt records ---

pub const Wait = struct { reason: []const u8, seconds: f64 };

pub const GroupUse = struct { name: []const u8, count: f64 };

pub const Attempt = struct {
    rule: []const u8,
    attempt: i64,
    status: []const u8,
    reason: []const u8,
    wall_s: f64,
    cpu_s: f64,
    threads: f64,
    request_mib: f64,
    reserved_mib: ?f64 = null,
    groups: []const GroupUse = &.{},
    peak_mib: ?f64,
    rss_mib: f64,
    rss_bound: bool = false,
    anon_mib: ?f64 = null,
    oom_kill: f64,
    limit_events: f64,
    waited_s: f64,
    wait_reason: []const u8,
    waits: []const Wait = &.{},
    queue_recorded: bool = false,
    cpu_stall: ?f64,
    memory_stall: ?f64,
    io_stall: ?f64,
    uses_shared: bool,
    diagnostics: []const []const u8 = &.{},
    in_container: bool = false,
    started_ns: i128 = 0,
    step: []const u8 = "",
    category: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    sample: ?[]const u8 = null,
    dir: []const u8 = "",
    reused_from: ?[]const u8 = null,

    pub fn completed(self: Attempt) bool {
        return eql(u8, self.status, "completed");
    }

    pub fn cpuEfficiency(self: Attempt) f64 {
        if (self.wall_s <= 0 or self.threads <= 0) return 0;
        return self.cpu_s / (self.wall_s * self.threads);
    }

    pub fn idle(self: Attempt) bool {
        if (self.wall_s < 0.5 or !self.completed()) return false;
        const memory = @max(self.peak_mib orelse 0, self.rss_mib);
        return self.cpuEfficiency() < 0.1 and memory < @max(self.request_mib * 0.05, 64);
    }

    pub fn usedMib(self: Attempt) f64 {
        if (self.uses_shared or self.in_container) if (self.peak_mib) |p| return p;
        return @max(self.rss_mib, self.anon_mib orelse 0);
    }

    pub fn usedIsBound(self: Attempt) bool {
        return self.rss_bound and !self.usedIsPeak();
    }

    pub fn usedIsPeak(self: Attempt) bool {
        if ((self.uses_shared or self.in_container) and self.peak_mib != null) return true;
        return (self.anon_mib orelse 0) > self.rss_mib;
    }
};

fn str(v: Value, key: []const u8) []const u8 {
    return fields.str(v, key) orelse "";
}

fn stringsOf(a: Allocator, v: ?Value) ![]const []const u8 {
    const x = v orelse return &.{};
    if (x != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (x.array.items) |item| if (item == .string) try out.append(a, item.string);
    return out.items;
}

fn optStr(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string and x.string.len > 0) x.string else null;
}

fn labelsOf(v: Value) workflow.Labels {
    if (get(v, "labels")) |lv| if (lv == .object) if (optStr(get(lv, "step"))) |step| return .{
        .step = step,
        .category = optStr(get(lv, "category")),
        .tool = optStr(get(lv, "tool")),
        .sample = optStr(get(lv, "sample")),
    };
    const image: ?[]const u8 = if (get(v, "request")) |q| optStr(get(q, "container")) else null;
    return workflow.deriveLabels(str(v, "rule"), image);
}

fn stall(cg: ?Value, key: []const u8, wall: f64) ?f64 {
    const c = cg orelse return null;
    const us = num(get(c, key)) orelse return null;
    if (wall <= 0) return null;
    return @min(us / 1e6 / wall, 1.0);
}

pub fn median(xs: []const f64) f64 {
    if (xs.len == 0) return 0;
    const m = xs.len / 2;
    return if (xs.len % 2 == 1) xs[m] else (xs[m - 1] + xs[m]) / 2;
}

pub fn attempts(gpa: Allocator, a: Allocator, launch_dir: []const u8, unreadable: ?*std.ArrayList([]const u8)) ![]Attempt {
    const dir = try std.fs.path.join(a, &.{ launch_dir, "attempts" });
    var out: std.ArrayList(Attempt) = .empty;
    for ((try sys.dirNames(gpa, a, dir)) orelse &.{}) |rule| {
        const rule_dir = try std.fs.path.join(a, &.{ dir, rule });
        for ((try records.attemptNames(gpa, a, rule_dir)) orelse &.{}) |n| {
            if (try readRecord(gpa, a, try std.fs.path.join(a, &.{ rule_dir, n, "record.json" }), unreadable)) |r| try out.append(a, r);
        }
    }
    return out.items;
}

fn readRecord(gpa: Allocator, a: Allocator, path: []const u8, unreadable: ?*std.ArrayList([]const u8)) !?Attempt {
    const bytes = sys.readFile(gpa, path, 16 << 20) catch |err| return if (err == error.OutOfMemory) err else null;
    defer gpa.free(bytes);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const attempt = (try parseRecord(scratch.allocator(), a, bytes, path, unreadable)) orelse return null;
    return try own(a, attempt);
}

fn own(a: Allocator, x: Attempt) !Attempt {
    var y = x;
    y.rule = try a.dupe(u8, x.rule);
    y.status = try a.dupe(u8, x.status);
    y.reason = try a.dupe(u8, x.reason);
    y.wait_reason = try a.dupe(u8, x.wait_reason);
    const waits = try a.alloc(Wait, x.waits.len);
    for (waits, x.waits) |*to, w| to.* = .{ .reason = try a.dupe(u8, w.reason), .seconds = w.seconds };
    y.waits = waits;
    const groups = try a.alloc(GroupUse, x.groups.len);
    for (groups, x.groups) |*to, g| to.* = .{ .name = try a.dupe(u8, g.name), .count = g.count };
    y.groups = groups;
    const diagnostics = try a.alloc([]const u8, x.diagnostics.len);
    for (diagnostics, x.diagnostics) |*to, d| to.* = try a.dupe(u8, d);
    y.diagnostics = diagnostics;
    y.step = try a.dupe(u8, x.step);
    y.category = if (x.category) |s| try a.dupe(u8, s) else null;
    y.tool = if (x.tool) |s| try a.dupe(u8, s) else null;
    y.sample = if (x.sample) |s| try a.dupe(u8, s) else null;
    y.dir = try a.dupe(u8, x.dir);
    y.reused_from = if (x.reused_from) |s| try a.dupe(u8, s) else null;
    return y;
}

fn parseRecord(t: Allocator, a: Allocator, bytes: []const u8, path: []const u8, unreadable: ?*std.ArrayList([]const u8)) !?Attempt {
    const v = std.json.parseFromSliceLeaky(Value, t, bytes, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (unreadable) |list| try list.append(a, path);
        return null;
    };
    if (fields.newer(v, records.record_version)) {
        if (unreadable) |list| try list.append(a, path);
        return null;
    }
    const wall = num(get(v, "wall_s")) orelse 0;
    const req = get(v, "request");
    const cg: ?Value = if (get(v, "cgroup")) |c| (if (c == .object) c else null) else null;
    const queue = get(v, "queue");
    var waits: std.ArrayList(Wait) = .empty;
    var top_reason: []const u8 = "";
    var top_s: f64 = 0;
    if (queue) |q| if (get(q, "reasons")) |rs| if (rs == .array) for (rs.array.items) |item| {
        const s = num(get(item, "seconds")) orelse 0;
        try waits.append(t, .{ .reason = str(item, "reason"), .seconds = s });
        if (s > top_s) {
            top_s = s;
            top_reason = str(item, "reason");
        }
    };
    var groups: std.ArrayList(GroupUse) = .empty;
    if (req) |q| if (get(q, "groups")) |gs| if (gs == .array) for (gs.array.items) |item| {
        try groups.append(t, .{ .name = str(item, "name"), .count = num(get(item, "count")) orelse 1 });
    };
    const labels = labelsOf(v);
    return .{
        .rule = str(v, "rule"),
        .attempt = std.math.lossyCast(u32, num(get(v, "attempt")) orelse 0),
        .status = str(v, "status"),
        .reason = str(v, "reason"),
        .wall_s = wall,
        .cpu_s = num(get(v, "cpu_s")) orelse if (get(v, "rusage")) |ru| num(get(ru, "cpu_s")) orelse 0 else 0,
        .threads = if (req) |q| num(get(q, "threads")) orelse 1 else 1,
        .request_mib = if (req) |q| num(get(q, "memory_mib")) orelse 0 else 0,
        .reserved_mib = if (req) |q| num(get(q, "reserved_mib")) else null,
        .groups = groups.items,
        .peak_mib = if (cg) |c| if (num(get(c, "memory_peak"))) |p| p / 1048576.0 else null else null,
        .rss_mib = if (get(v, "rusage")) |ru| (num(get(ru, "maxrss_kib")) orelse 0) / 1024.0 else 0,
        .rss_bound = if (get(v, "rusage")) |ru| if (num(get(ru, "engine_maxrss_kib"))) |e| (num(get(ru, "maxrss_kib")) orelse 0) <= e else false else false,
        .anon_mib = if (cg) |c| if (num(get(c, "anon_peak"))) |p| p / 1048576.0 else null else null,
        .oom_kill = if (cg) |c| num(get(c, "oom_kill")) orelse 0 else 0,
        .limit_events = if (cg) |c| num(get(c, "memory_max_events")) orelse 0 else 0,
        .waited_s = if (queue) |q| num(get(q, "waited_s")) orelse 0 else 0,
        .wait_reason = top_reason,
        .waits = waits.items,
        .queue_recorded = queue != null,
        .cpu_stall = stall(cg, "cpu_some_us", wall),
        .memory_stall = stall(cg, "memory_some_us", wall),
        .io_stall = stall(cg, "io_some_us", wall),
        .uses_shared = if (req) |q| if (get(q, "shared")) |sh| sh == .array and sh.array.items.len > 0 else false else false,
        .in_container = if (req) |q| if (get(q, "container")) |c| c == .string else false else false,
        .diagnostics = try stringsOf(t, get(v, "diagnostics")),
        .started_ns = tracker.parseTime(str(v, "started")) orelse 0,
        .step = labels.step,
        .category = labels.category,
        .tool = labels.tool,
        .sample = labels.sample,
        .dir = std.fs.path.dirname(path).?,
    };
}

pub fn reusedAttempts(gpa: Allocator, a: Allocator, launch_dir: []const u8, names: []const []const u8, unreadable: ?*std.ArrayList([]const u8)) ![]Attempt {
    if (names.len == 0) return &.{};
    var wanted: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (names) |n| try wanted.put(a, n, {});
    const launches_dir = std.fs.path.dirname(launch_dir) orelse return &.{};
    const id = std.fs.path.basename(launch_dir);
    const launches = try records.launchNames(gpa, a, std.fs.path.dirname(launches_dir) orelse return &.{});

    var out: std.ArrayList(Attempt) = .empty;
    var k = launches.len;
    while (k > 0 and wanted.count() > 0) {
        k -= 1;
        const launch = launches[k];
        if (!std.mem.lessThan(u8, launch, id)) continue;
        const attempts_dir = try std.fs.path.join(a, &.{ launches_dir, launch, "attempts" });
        const ran = (try sys.dirNames(gpa, a, attempts_dir)) orelse continue;
        for (ran) |rule| {
            const i = wanted.getIndex(rule) orelse continue;
            const rule_dir = try std.fs.path.join(a, &.{ attempts_dir, rule });
            const numbers = (try records.attemptNames(gpa, a, rule_dir)) orelse &.{};
            var j = numbers.len;
            const found = while (j > 0) {
                j -= 1;
                const r = (try readRecord(gpa, a, try std.fs.path.join(a, &.{ rule_dir, numbers[j], "record.json" }), unreadable)) orelse continue;
                if (r.completed()) break r;
            } else null;
            if (found) |r| {
                var reused = r;
                reused.reused_from = launch;
                try out.append(a, reused);
                wanted.swapRemoveAt(i);
            }
        }
    }
    return out.items;
}

// --- The launch ---

pub const State = enum {
    pending,
    waiting,
    running,
    stopping,
    completed,
    reused,
    failed,
    blocked,
    cancelled,
    not_run,

    pub fn active(s: State) bool {
        return s == .running or s == .stopping;
    }
};

pub const Rule = struct {
    name: []const u8,
    labels: workflow.Labels,
    selected: bool,
    state: State = .not_run,
    attempts: u32 = 0,
    run: ?*const Attempt = null,
    final: ?*const Attempt = null,
    step: usize = 0,
    started_ns: i128 = 0,
    reason: []const u8 = "",
};

pub const Sizing = struct {
    threads: f64 = 0,
    memory_mib: f64 = 0,
    note: enum { none, measured, idle, out_of_memory } = .none,
    at_thread_limit: bool = false,
};

pub const Step = struct {
    name: []const u8,
    category: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    depth: u32 = 0,
    first: usize = 0,
    rules: std.ArrayList(usize) = .empty,
    parents: std.ArrayList(usize) = .empty,
    samples: usize = 0,
    states: [@typeInfo(State).@"enum".fields.len]u32 = @splat(0),

    runs: usize = 0,
    reused: usize = 0,
    walls: std.ArrayList(f64) = .empty,
    median_s: f64 = 0,
    wall_s: f64 = 0,
    cpu_s: f64 = 0,
    cores: f64 = 0,
    threads: f64 = 0,
    request_mib: f64 = 0,
    used_mib: f64 = 0,
    used_is_peak: bool = false,
    used_bound: bool = false,
    peak_mib: f64 = 0,
    idle: usize = 0,
    limit_events: f64 = 0,
    reserved_s: f64 = 0,
    stall_n: usize = 0,
    cpu_stall: f64 = 0,
    memory_stall: f64 = 0,
    io_stall: f64 = 0,
    failed_attempts: usize = 0,
    oom_kills: f64 = 0,
    oom_request_mib: f64 = 0,
    sizing: Sizing = .{},

    pub fn count(self: Step, s: State) u32 {
        return self.states[@intFromEnum(s)];
    }

    pub fn selected(self: Step) usize {
        return self.rules.items.len;
    }

    pub fn efficiency(self: Step) f64 {
        return if (self.reserved_s > 0) self.cpu_s / self.reserved_s else 0;
    }

    pub fn judged(self: Step) bool {
        return self.wall_s >= 1;
    }

    pub fn character(self: Step) []const u8 {
        if (!self.judged()) return "-";
        const eff = self.efficiency();
        const stalls = self.stall_n > 0;
        if (stalls) {
            const n: f64 = @floatFromInt(self.stall_n);
            if (self.memory_stall / n >= 0.2) return "memory-throttled";
            if (self.io_stall / n >= 0.3) return "I/O-bound";
            if (self.cpu_stall / n >= 0.3) return "CPU-starved";
        }
        if (eff >= 0.7) return "CPU-bound";
        if (self.threads >= 2 and self.cores >= 0.7 and self.cores < self.threads * 0.6) return "runs fewer threads";
        if (!stalls) return "-";
        return if (eff < 0.3) "mostly idle" else "mixed";
    }

    pub fn mostlyIdle(self: Step) bool {
        return self.runs > 0 and self.idle * 2 > self.runs;
    }
};

pub const PathRow = struct {
    rule: usize,
    start_s: f64,
    waited_s: f64,
    ran_s: f64,
    earlier: i64,
    held_s: f64 = 0,
    between_s: f64 = 0,
    end_s: f64 = 0,
};

pub const judge_s: f64 = 2;

pub const Bound = struct {
    kind: enum { chain, threads, cpu, memory, jobs, group, engine },
    name: []const u8 = "",
    work: f64 = 0,
    limit: f64 = 0,
    seconds: f64,
};

pub const GroupAdvice = struct {
    name: []const u8,
    seconds: f64,
    fit: ?f64,
    samples: usize = 0,
};

pub const Total = struct { name: []const u8, steps: usize = 0, runs: usize = 0, wall_s: f64 = 0, cpu_s: f64 = 0 };

pub const SampleRow = struct {
    name: []const u8,
    steps: usize = 0,
    runs: usize = 0,
    wall_s: f64 = 0,
    cpu_s: f64 = 0,
    slowest: ?usize = null,
};

pub const Counts = struct { completed: usize = 0, reused: usize = 0, failed: usize = 0, blocked: usize = 0, cancelled: usize = 0, not_run: usize = 0, running: usize = 0, waiting: usize = 0, pending: usize = 0 };

pub const Launch = struct {
    gpa: Allocator,
    dir: []const u8,
    id: []const u8,
    workdir: []const u8 = "",
    name: []const u8 = "launch",
    engine: []const u8 = "",
    engine_id: []const u8 = "",
    workflow_sha256: []const u8 = "",
    unreadable: std.ArrayList([]const u8) = .empty,
    thread_overrides: []const []const u8 = &.{},
    started_text: []const u8 = "",
    max_threads: f64 = 0,
    max_memory_mib: f64 = 0,
    max_jobs: f64 = 0,
    status: []const u8 = "running",
    finished: bool = false,
    @"error": ?[]const u8 = null,
    elapsed_s: f64 = 0,
    t0_ns: i128 = 0,
    counts: Counts = .{},
    selected: usize = 0,
    engine_cpu_s: ?f64 = null,
    engine_rss_mib: ?f64 = null,

    tracker: tracker.Tracker,
    wf: ?workflow.Workflow = null,
    g: ?graph.Graph = null,
    borrowed: bool = false,
    snapshot_problem: ?[]const u8 = null,

    rows: []const Attempt = &.{},
    reused_unrecorded: usize = 0,
    rules: []Rule = &.{},
    rule_index: std.StringHashMapUnmanaged(usize) = .empty,
    steps: []Step = &.{},
    samples: []const []const u8 = &.{},
    by_category: bool = false,
    path: []const PathRow = &.{},
    path_ran_s: f64 = 0,
    path_waited_s: f64 = 0,
    path_held_s: f64 = 0,
    path_between_s: f64 = 0,
    path_checks_s: f64 = 0,
    path_after_s: f64 = 0,
    bounds: []const Bound = &.{},
    binding: ?usize = null,
    waits: std.StringArrayHashMapUnmanaged(f64) = .empty,
    waits_recorded: bool = false,
    groups: []const GroupAdvice = &.{},

    pub fn deinit(self: *Launch) void {
        if (!self.borrowed) {
            if (self.g) |*g| g.deinit();
            if (self.wf) |*wf| wf.deinit();
        }
        self.tracker.deinit();
    }

    pub fn overBound(self: *const Launch) ?f64 {
        const b = self.bounds[self.binding orelse return null];
        if (self.elapsed_s < judge_s or b.seconds <= 0) return null;
        return @max(self.elapsed_s / b.seconds - 1, 0) * 100;
    }

    pub fn usage(self: *const Launch) []const tracker.Sample {
        return self.tracker.samples.items;
    }

    pub fn shared(self: *const Launch) []const tracker.SharedView {
        return self.tracker.shared.items;
    }

    pub fn at(self: *const Launch, ns: i128) f64 {
        return @as(f64, @floatFromInt(ns - self.t0_ns)) / 1e9;
    }

    pub fn cpu(self: *const Launch) struct { all: f64, here: f64 } {
        var all: f64 = 0;
        var here: f64 = 0;
        for (self.rules) |r| if (r.selected) if (r.run) |run| {
            all += run.cpu_s;
            if (run.reused_from == null) here += run.cpu_s;
        };
        return .{ .all = all, .here = here };
    }

    pub fn totals(self: *const Launch, a: Allocator, by: enum { category, tool }) ![]Total {
        var map: std.StringArrayHashMapUnmanaged(Total) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (self.rules) |r| {
            if (!r.selected) continue;
            const run = r.run orelse continue;
            const name = (switch (by) {
                .category => r.labels.category,
                .tool => r.labels.tool,
            }) orelse continue;
            const gop = try map.getOrPut(a, name);
            if (!gop.found_existing) gop.value_ptr.* = .{ .name = name };
            const t = gop.value_ptr;
            t.runs += 1;
            t.wall_s += run.wall_s;
            t.cpu_s += run.cpu_s;
            const pair = try pairKey(a, name, r.labels.step);
            if (!seen.contains(pair)) {
                try seen.put(a, pair, {});
                t.steps += 1;
            }
        }
        const list = map.values();
        std.mem.sort(Total, list, {}, struct {
            fn more(_: void, x: Total, y: Total) bool {
                return x.cpu_s > y.cpu_s;
            }
        }.more);
        return list;
    }

    pub fn sampleRows(self: *const Launch, a: Allocator) ![]SampleRow {
        var map: std.StringArrayHashMapUnmanaged(SampleRow) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (self.rules, 0..) |r, i| {
            if (!r.selected) continue;
            const name = r.labels.sample orelse continue;
            const run = r.run orelse continue;
            const gop = try map.getOrPut(a, name);
            if (!gop.found_existing) gop.value_ptr.* = .{ .name = name };
            const row = gop.value_ptr;
            row.runs += 1;
            row.wall_s += run.wall_s;
            row.cpu_s += run.cpu_s;
            if (row.slowest == null or run.wall_s > self.rules[row.slowest.?].run.?.wall_s) row.slowest = i;
            const pair = try pairKey(a, name, r.labels.step);
            if (!seen.contains(pair)) {
                try seen.put(a, pair, {});
                row.steps += 1;
            }
        }
        const list = map.values();
        std.mem.sort(SampleRow, list, {}, struct {
            fn more(_: void, x: SampleRow, y: SampleRow) bool {
                return x.cpu_s > y.cpu_s;
            }
        }.more);
        return list;
    }

    pub fn ruleOf(self: *const Launch, name: []const u8) ?*const Rule {
        const i = self.rule_index.get(name) orelse return null;
        return if (self.rules[i].selected) &self.rules[i] else null;
    }

    pub fn slow(self: *const Launch, r: Rule) bool {
        const run = r.run orelse return false;
        const m = self.steps[r.step].median_s;
        return m > 0 and run.wall_s >= m * 1.5 and run.wall_s - m >= 2;
    }

    pub fn cell(self: *const Launch, step: usize, sample: ?[]const u8) ?usize {
        var best: ?usize = null;
        for (self.steps[step].rules.items) |ri| {
            const r = self.rules[ri];
            if (sample) |want| {
                const have = r.labels.sample orelse continue;
                if (!eql(u8, have, want)) continue;
            } else if (r.labels.sample != null) continue;
            const wall = if (r.run) |run| run.wall_s else -1;
            if (best == null or wall > (if (self.rules[best.?].run) |b| b.wall_s else -1)) best = ri;
        }
        return best;
    }
};

fn engineName(id: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, id, " sha256:")) |i| id[0..i] else id;
}

fn pairKey(a: Allocator, x: []const u8, y: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ x, y });
}

fn snapshotProblem(a: Allocator, p: *const workflow.Problem, err: anyerror) ![]const u8 {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (p.message.len == 0) return @errorName(err);
    return std.mem.replaceOwned(u8, a, p.message, "\n", "; ");
}

fn readJson(gpa: Allocator, t: Allocator, a: Allocator, path: []const u8, unreadable: *std.ArrayList([]const u8)) !?Value {
    const bytes = sys.readFile(gpa, path, records.launch_record_max) catch |err| return if (err == error.OutOfMemory) err else null;
    defer gpa.free(bytes);
    const v = std.json.parseFromSliceLeaky(Value, t, bytes, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        try unreadable.append(a, path);
        return null;
    };
    if (fields.newer(v, records.record_version)) {
        try unreadable.append(a, path);
        return null;
    }
    return v;
}

fn stateOf(s: tracker.Status, finished: bool) State {
    return switch (s) {
        .pending => if (finished) .not_run else .pending,
        .waiting, .retrying => if (finished) .not_run else .waiting,
        .running => .running,
        .cancelling => .stopping,
        .completed => .completed,
        .reused => .reused,
        .failed => .failed,
        .blocked => .blocked,
        .cancelled => .cancelled,
    };
}

pub const Snapshot = struct { wf: *const workflow.Workflow, g: *const graph.Graph };

pub fn load(gpa: Allocator, a: Allocator, launch_dir: []const u8) !Launch {
    return loadWith(gpa, a, launch_dir, null);
}

pub fn loadWith(gpa: Allocator, a: Allocator, launch_dir: []const u8, given: ?Snapshot) !Launch {
    var l: Launch = .{ .gpa = gpa, .dir = launch_dir, .id = std.fs.path.basename(launch_dir), .tracker = try tracker.Tracker.init(gpa, launch_dir) };
    errdefer l.deinit();
    _ = try l.tracker.update();
    _ = try readSettings(gpa, a, &l);
    follow(&l);
    const end = try readEnd(gpa, a, try std.fs.path.join(a, &.{ launch_dir, "summary.json" }), &l.unreadable);
    if (end == null) _ = try l.tracker.settleEnd();
    settle(&l, end);

    l.rows = try attempts(gpa, a, launch_dir, &l.unreadable);
    var reused_names: std.ArrayList([]const u8) = .empty;
    for (l.tracker.rules.items) |r| if (r.status == .reused) try reused_names.append(a, r.name);
    const reused = try reusedAttempts(gpa, a, launch_dir, reused_names.items, &l.unreadable);
    l.reused_unrecorded = reused_names.items.len - reused.len;

    if (given) |s| {
        l.wf = s.wf.*;
        l.g = s.g.*;
        l.borrowed = true;
    } else try readSnapshot(gpa, a, &l);
    try collect(a, &l, reused);
    return l;
}

fn readSettings(gpa: Allocator, a: Allocator, l: *Launch) !bool {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const before = l.unreadable.items.len;
    const v = (try readJson(gpa, scratch.allocator(), a, try std.fs.path.join(a, &.{ l.dir, "launch.json" }), &l.unreadable)) orelse
        return l.unreadable.items.len > before;
    l.workdir = try a.dupe(u8, str(v, "workdir"));
    if (l.workdir.len > 0) l.name = std.fs.path.basename(l.workdir);
    l.engine_id = try a.dupe(u8, str(v, "engine"));
    l.engine = engineName(l.engine_id);
    l.workflow_sha256 = try a.dupe(u8, str(v, "workflow_sha256"));
    if (get(v, "thread_overrides")) |list| if (list == .array) {
        var given: std.ArrayList([]const u8) = .empty;
        for (list.array.items) |item| if (item == .string) try given.append(a, try a.dupe(u8, item.string));
        l.thread_overrides = given.items;
    };
    l.started_text = try a.dupe(u8, str(v, "started"));
    l.max_threads = num(get(v, "max_threads")) orelse 0;
    l.max_memory_mib = num(get(v, "max_memory_mib")) orelse 0;
    l.max_jobs = num(get(v, "jobs")) orelse 0;
    return true;
}

fn follow(l: *Launch) void {
    const tr = &l.tracker;
    if (tr.max_threads > 0) l.max_threads = @floatFromInt(tr.max_threads);
    if (tr.max_memory_mib > 0) l.max_memory_mib = @floatFromInt(tr.max_memory_mib);
    if (tr.max_jobs > 0) l.max_jobs = @floatFromInt(tr.max_jobs);
    l.t0_ns = if (tr.launch_ns != 0) tr.launch_ns else tr.started_ns;
}

const End = struct {
    status: []const u8,
    @"error": ?[]const u8,
    elapsed_s: f64,
    selected: ?usize,
    engine: []const u8,
    engine_cpu_s: ?f64 = null,
    engine_rss_mib: ?f64 = null,
};

fn readEnd(gpa: Allocator, a: Allocator, path: []const u8, unreadable: *std.ArrayList([]const u8)) !?End {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const s = (try readJson(gpa, scratch.allocator(), a, path, unreadable)) orelse return null;
    var end: End = .{
        .status = try a.dupe(u8, str(s, "status")),
        .@"error" = if (optStr(get(s, "error"))) |e| try a.dupe(u8, e) else null,
        .elapsed_s = @max(num(get(s, "elapsed_s")) orelse 0, 0),
        .selected = if (num(get(s, "selected"))) |n| std.math.lossyCast(usize, n) else null,
        .engine = try a.dupe(u8, engineName(str(s, "engine"))),
    };
    if (get(s, "engine_cost")) |c| {
        end.engine_cpu_s = num(get(c, "cpu_s"));
        end.engine_rss_mib = num(get(c, "max_rss_mib"));
    }
    return end;
}

fn settle(l: *Launch, end: ?End) void {
    const tr = &l.tracker;
    l.finished = false;
    l.status = "running";
    l.@"error" = null;
    l.elapsed_s = 0;
    l.selected = tr.selected;
    if (end) |s| {
        l.finished = true;
        l.status = s.status;
        l.@"error" = s.@"error";
        l.elapsed_s = s.elapsed_s;
        if (s.selected) |n| l.selected = n;
        l.engine_cpu_s = s.engine_cpu_s;
        l.engine_rss_mib = s.engine_rss_mib;
        if (l.engine.len == 0) l.engine = s.engine;
    } else if (tr.finished) {
        l.finished = true;
        l.status = tr.final_status;
        if (tr.final_error.len > 0) l.@"error" = tr.final_error;
    }
    if (l.elapsed_s == 0 and l.t0_ns != 0) {
        const to = if (tr.finished) tr.finished_ns else if (end == null) sys.realNs() else l.t0_ns;
        l.elapsed_s = @max(@as(f64, @floatFromInt(to - l.t0_ns)) / 1e9, 0);
    }
}

fn readSnapshot(gpa: Allocator, a: Allocator, l: *Launch) !void {
    if (l.workdir.len == 0) return;
    var problem: workflow.Problem = .{};
    defer if (problem.message.len > 0) gpa.free(problem.message);
    if (workflow.loadRecorded(gpa, try std.fs.path.join(a, &.{ l.dir, "workflow" }), l.workdir, &problem)) |wf| {
        l.wf = wf;
        for (l.thread_overrides) |o| if (std.mem.lastIndexOfScalar(u8, o, '=')) |eq| {
            const n = std.fmt.parseInt(u32, o[eq + 1 ..], 10) catch continue;
            _ = l.wf.?.overrideThreads(o[0..eq], n);
        };
        if (graph.build(gpa, &l.wf.?, &problem)) |g| {
            l.g = g;
        } else |err| l.snapshot_problem = try snapshotProblem(a, &problem, err);
    } else |err| l.snapshot_problem = try snapshotProblem(a, &problem, err);
}

fn collect(a: Allocator, l: *Launch, reused: []const Attempt) !void {
    try collectRules(a, l, reused);
    try collectSteps(a, l);
    try collectPath(a, l);
    try collectBounds(a, l);
    try collectWaits(a, l);
}

fn clearFigures(l: *Launch) void {
    l.counts = .{};
    l.rules = &.{};
    l.rule_index = .empty;
    l.steps = &.{};
    l.samples = &.{};
    l.by_category = false;
    l.path = &.{};
    l.path_ran_s = 0;
    l.path_waited_s = 0;
    l.path_held_s = 0;
    l.path_between_s = 0;
    l.path_checks_s = 0;
    l.path_after_s = 0;
    l.bounds = &.{};
    l.binding = null;
    l.waits = .empty;
    l.waits_recorded = false;
    l.groups = &.{};
}

pub const Live = struct {
    gpa: Allocator,
    keep: std.heap.ArenaAllocator,
    view: std.heap.ArenaAllocator,
    launch: Launch,
    summary_path: []const u8,
    rows: std.ArrayList(Attempt) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    next: std.ArrayList(u32) = .empty,
    asked: std.StringHashMapUnmanaged(void) = .empty,
    reused: std.ArrayList(Attempt) = .empty,
    settings_read: bool = false,
    end: ?End = null,
    end_unreadable: bool = false,
    refreshes: usize = 0,
    swept: bool = false,

    pub fn open(gpa: Allocator, launch_dir: []const u8) !Live {
        var self: Live = .{ .gpa = gpa, .keep = .init(gpa), .view = .init(gpa), .launch = undefined, .summary_path = "" };
        errdefer self.keep.deinit();
        errdefer self.view.deinit();
        const keep = self.keep.allocator();
        const dir = try keep.dupe(u8, launch_dir);
        self.summary_path = try std.fs.path.join(keep, &.{ dir, "summary.json" });
        self.launch = .{ .gpa = gpa, .dir = dir, .id = std.fs.path.basename(dir), .tracker = try tracker.Tracker.init(gpa, dir) };
        errdefer self.launch.deinit();
        _ = try self.refresh();
        return self;
    }

    pub fn deinit(self: *Live) void {
        self.launch.deinit();
        self.view.deinit();
        self.keep.deinit();
    }

    pub fn refresh(self: *Live) !bool {
        const gpa = self.gpa;
        const keep = self.keep.allocator();
        const l = &self.launch;
        const tr = &l.tracker;
        var changed = try tr.update();
        if (!self.settings_read) {
            self.settings_read = try readSettings(gpa, keep, l);
            if (self.settings_read) {
                try readSnapshot(gpa, keep, l);
                changed = true;
            }
        }
        follow(l);
        if (self.end == null and !self.end_unreadable) {
            const before = l.unreadable.items.len;
            self.end = try readEnd(gpa, keep, self.summary_path, &l.unreadable);
            self.end_unreadable = l.unreadable.items.len > before;
            if (self.end != null or self.end_unreadable) changed = true;
        }
        if (self.end == null and !tr.finished and try tr.settleEnd()) changed = true;
        settle(l, self.end);

        if (self.refreshes == 0 or (l.finished and !self.swept)) {
            if (try self.sweep()) changed = true;
            self.swept = l.finished;
        }
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        for (tr.rules.items, 0..) |r, i| {
            if (i == self.next.items.len) try self.next.append(keep, 1);
            const last = if (r.status.active()) r.attempt -| 1 else r.attempt;
            var n = self.next.items[i];
            var gap = false;
            while (n <= last) : (n += 1) {
                const dir = std.fmt.bufPrint(&buf, "{s}/attempts/{s}/{d:0>3}", .{ l.dir, r.name, n }) catch break;
                switch (try self.readOnce(dir)) {
                    .read => changed = true,
                    .known => {},
                    .missing => gap = true,
                }
                if (!gap) self.next.items[i] = n + 1;
            }
        }
        var names: std.ArrayList([]const u8) = .empty;
        for (tr.rules.items) |r| if (r.status == .reused and !self.asked.contains(r.name)) {
            try self.asked.put(keep, r.name, {});
            try names.append(keep, r.name);
        };
        if (names.items.len > 0) {
            try self.reused.appendSlice(keep, try reusedAttempts(gpa, keep, l.dir, names.items, &l.unreadable));
            changed = true;
        }
        l.reused_unrecorded = self.asked.count() - self.reused.items.len;

        if (changed) std.mem.sort(Attempt, self.rows.items, {}, rowOrder);
        l.rows = self.rows.items;
        if (changed or !l.finished or self.refreshes == 0) {
            _ = self.view.reset(.retain_capacity);
            clearFigures(l);
            try collect(self.view.allocator(), l, self.reused.items);
        }
        self.refreshes += 1;
        return changed;
    }

    fn sweep(self: *Live) !bool {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const t = scratch.allocator();
        const dir = try std.fs.path.join(t, &.{ self.launch.dir, "attempts" });
        var found = false;
        for ((try sys.dirNames(self.gpa, t, dir)) orelse &.{}) |rule| {
            const rule_dir = try std.fs.path.join(t, &.{ dir, rule });
            for ((try records.attemptNames(self.gpa, t, rule_dir)) orelse &.{}) |n| {
                if (try self.readOnce(try std.fs.path.join(t, &.{ rule_dir, n })) == .read) found = true;
            }
        }
        return found;
    }

    fn readOnce(self: *Live, dir: []const u8) !enum { read, known, missing } {
        if (self.seen.contains(dir)) return .known;
        const keep = self.keep.allocator();
        const l = &self.launch;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/record.json", .{dir}) catch return .missing;
        const before = l.unreadable.items.len;
        const row = try readRecord(self.gpa, keep, path, &l.unreadable);
        const unreadable = l.unreadable.items.len > before;
        if (unreadable) l.unreadable.items[before] = try keep.dupe(u8, path);
        if (row == null and !unreadable) return .missing;
        try self.seen.put(keep, try keep.dupe(u8, dir), {});
        if (row) |r| try self.rows.append(keep, r);
        return .read;
    }
};

fn rowOrder(_: void, x: Attempt, y: Attempt) bool {
    return switch (std.mem.order(u8, x.rule, y.rule)) {
        .lt => true,
        .gt => false,
        .eq => x.attempt < y.attempt,
    };
}

fn collectRules(a: Allocator, l: *Launch, reused: []const Attempt) !void {
    const tr = &l.tracker;
    var rules: std.ArrayList(Rule) = .empty;
    if (l.wf) |wf| {
        try rules.ensureTotalCapacityPrecise(a, wf.rules.len);
        for (wf.rules) |r| rules.appendAssumeCapacity(.{ .name = r.name, .labels = r.labels, .selected = tr.index.contains(r.name) });
    } else {
        var names: std.StringArrayHashMapUnmanaged(?workflow.Labels) = .empty;
        for (tr.rules.items) |r| try names.put(a, r.name, null);
        for (l.rows) |row| try names.put(a, row.rule, null);
        for ([_][]const Attempt{ l.rows, reused }) |list| for (list) |row| if (names.getPtr(row.rule)) |labels| {
            labels.* = .{ .step = row.step, .category = row.category, .tool = row.tool, .sample = row.sample };
        };
        for (names.keys(), names.values()) |name, labels| try rules.append(a, .{ .name = name, .labels = labels orelse workflow.deriveLabels(name, null), .selected = true });
    }
    const index = &l.rule_index;
    for (rules.items, 0..) |r, i| try index.put(a, r.name, i);
    for (l.rows) |row| if (index.get(row.rule)) |i| if (!tr.index.contains(row.rule)) {
        rules.items[i].state = if (row.completed()) .completed else if (eql(u8, row.status, "cancelled")) .cancelled else .failed;
    };
    for (tr.rules.items) |v| {
        const i = index.get(v.name) orelse continue;
        const r = &rules.items[i];
        r.state = stateOf(v.status, l.finished);
        r.attempts = v.attempt;
        r.started_ns = v.started_ns;
        r.reason = v.reason;
    }
    for (l.rows) |*row| {
        const i = index.get(row.rule) orelse continue;
        const r = &rules.items[i];
        if (r.final == null or row.attempt > r.final.?.attempt) r.final = row;
        if (row.completed()) r.run = row;
    }
    for (reused) |*row| if (index.get(row.rule)) |i| {
        rules.items[i].run = row;
    };
    l.rules = rules.items;
    var c: Counts = .{};
    for (l.rules) |r| if (r.selected) switch (r.state) {
        .completed => c.completed += 1,
        .reused => c.reused += 1,
        .failed => c.failed += 1,
        .blocked => c.blocked += 1,
        .cancelled => c.cancelled += 1,
        .not_run => c.not_run += 1,
        .running, .stopping => c.running += 1,
        .waiting => c.waiting += 1,
        .pending => c.pending += 1,
    };
    l.counts = c;
}

fn collectSteps(a: Allocator, l: *Launch) !void {
    var depth: []u32 = &.{};
    if (l.g) |g| {
        depth = try a.alloc(u32, l.rules.len);
        for (g.order) |i| {
            depth[i] = 0;
            for (g.parents[i]) |p| depth[i] = @max(depth[i], depth[p] + 1);
        }
    }
    const Missed = struct { failed: usize = 0, oom_kills: f64 = 0, oom_request_mib: f64 = 0 };
    const missed = try a.alloc(Missed, l.rules.len);
    @memset(missed, .{});
    for (l.rows) |row| if (!row.completed()) if (l.rule_index.get(row.rule)) |ri| {
        const m = &missed[ri];
        if (!eql(u8, row.status, "cancelled")) m.failed += 1;
        if (row.oom_kill > 0) {
            m.oom_kills += row.oom_kill;
            m.oom_request_mib = @max(m.oom_request_mib, row.request_mib);
        }
    };
    var map: std.StringArrayHashMapUnmanaged(Step) = .empty;
    var samples: std.StringArrayHashMapUnmanaged(void) = .empty;
    var pairs: std.StringHashMapUnmanaged(void) = .empty;
    for (l.rules, 0..) |*r, i| {
        if (!r.selected) continue;
        const gop = try map.getOrPut(a, r.labels.step);
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = r.labels.step, .first = i, .depth = if (depth.len > 0) depth[i] else 0 };
        const s = gop.value_ptr;
        r.step = gop.index;
        try s.rules.append(a, i);
        if (s.category == null) s.category = r.labels.category;
        if (s.tool == null) s.tool = r.labels.tool;
        if (depth.len > 0) s.depth = @min(s.depth, depth[i]);
        s.states[@intFromEnum(r.state)] += 1;
        if (r.labels.category != null) l.by_category = true;
        if (r.labels.sample) |name| {
            try samples.put(a, name, {});
            const pair = try pairKey(a, r.labels.step, name);
            if (!pairs.contains(pair)) {
                try pairs.put(a, pair, {});
                s.samples += 1;
            }
        }
        s.failed_attempts += missed[i].failed;
        s.oom_kills += missed[i].oom_kills;
        s.oom_request_mib = @max(s.oom_request_mib, missed[i].oom_request_mib);
        const run = r.run orelse continue;
        s.runs += 1;
        s.reused += @intFromBool(run.reused_from != null);
        try s.walls.append(a, run.wall_s);
        s.wall_s += run.wall_s;
        s.cpu_s += run.cpu_s;
        if (run.wall_s > 0) s.cores = @max(s.cores, run.cpu_s / run.wall_s);
        s.threads = @max(s.threads, run.threads);
        s.request_mib = @max(s.request_mib, run.request_mib);
        if (run.usedMib() >= s.used_mib) {
            s.used_mib = run.usedMib();
            s.used_is_peak = run.usedIsPeak();
            s.used_bound = run.usedIsBound();
        }
        s.peak_mib = @max(s.peak_mib, run.peak_mib orelse run.rss_mib);
        s.idle += @intFromBool(run.idle());
        s.limit_events += run.limit_events;
        s.reserved_s += run.wall_s * run.threads;
        if (run.cpu_stall) |cs| {
            s.cpu_stall += cs;
            s.memory_stall += run.memory_stall orelse 0;
            s.io_stall += run.io_stall orelse 0;
            s.stall_n += 1;
        }
    }
    if (l.wf) |wf| for (l.rules, 0..) |r, i| if (r.selected) {
        const s = &map.values()[r.step];
        s.threads = @max(s.threads, @as(f64, @floatFromInt(wf.rules[i].threads)));
        s.request_mib = @max(s.request_mib, @as(f64, @floatFromInt(wf.rules[i].memory_mib)));
    };
    for (map.values()) |*s| {
        std.mem.sort(f64, s.walls.items, {}, std.sort.asc(f64));
        s.median_s = median(s.walls.items);
        s.sizing = size(s.*);
    }
    const steps = map.values();
    const order = try a.alloc(usize, steps.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, steps, struct {
        fn lt(ss: []Step, x: usize, y: usize) bool {
            if (ss[x].depth != ss[y].depth) return ss[x].depth < ss[y].depth;
            return ss[x].first < ss[y].first;
        }
    }.lt);
    const sorted = try a.alloc(Step, steps.len);
    const new_index = try a.alloc(usize, steps.len);
    for (order, 0..) |old, new| {
        sorted[new] = steps[old];
        new_index[old] = new;
    }
    for (l.rules) |*r| if (r.selected) {
        r.step = new_index[r.step];
    };
    l.steps = sorted;
    if (l.g) |g| for (l.rules, 0..) |r, i| if (r.selected) {
        const s = &l.steps[r.step];
        for (g.parents[i]) |p| {
            if (!l.rules[p].selected) continue;
            const ps = l.rules[p].step;
            if (ps == r.step) continue;
            if (std.mem.indexOfScalar(usize, s.parents.items, ps) == null) try s.parents.append(a, ps);
        }
    };
    const names = samples.keys();
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    l.samples = names;
}

fn size(s: Step) Sizing {
    if (s.mostlyIdle()) return .{ .threads = @max(s.threads, 1), .memory_mib = s.request_mib, .note = .idle };
    var out: Sizing = .{};
    if (s.runs > 0) {
        out.note = .measured;
        out.memory_mib = @max(@ceil(s.used_mib * 1.2 / 64.0) * 64.0, 64);
        out.threads = @min(@max(@ceil(s.cores - 0.05), 1), @max(s.threads, 1));
        out.at_thread_limit = s.judged() and s.efficiency() >= 0.9;
    }
    if (s.oom_kills > 0) {
        out.note = .out_of_memory;
        out.memory_mib = @max(out.memory_mib, @ceil(s.oom_request_mib * 1.5 / 64.0) * 64.0);
        if (out.threads == 0) out.threads = @max(s.threads, 1);
    }
    return out;
}

fn collectPath(a: Allocator, l: *Launch) !void {
    const g = l.g orelse return;
    const n = l.rules.len;
    const work = try a.alloc(f64, n);
    const waited = try a.alloc(f64, n);
    const tries = try a.alloc(i64, n);
    const first = try a.alloc(?Attempt, n);
    const ended = try a.alloc(f64, n);
    @memset(work, 0);
    @memset(waited, 0);
    @memset(tries, 0);
    @memset(first, null);
    @memset(ended, 0);
    for (l.rows) |r| if (l.rule_index.get(r.rule)) |i| if (l.rules[i].selected) {
        work[i] += r.wall_s;
        waited[i] += r.waited_s;
        tries[i] += 1;
        if (r.started_ns > 0) {
            if (first[i] == null or r.started_ns < first[i].?.started_ns) first[i] = r;
            ended[i] = @max(ended[i], l.at(r.started_ns) + r.wall_s);
        }
    };
    const longest = try a.alloc(f64, n);
    const from = try a.alloc(?usize, n);
    var end: ?usize = null;
    for (g.order) |i| {
        from[i] = null;
        for (g.parents[i]) |p| if (from[i] == null or longest[p] > longest[from[i].?]) {
            from[i] = p;
        };
        longest[i] = work[i] + if (from[i]) |p| longest[p] else 0;
        if (work[i] > 0 and (end == null or longest[i] > longest[end.?])) end = i;
    }
    var rows: std.ArrayList(PathRow) = .empty;
    var cur = end;
    while (cur) |i| : (cur = from[i]) {
        if (work[i] == 0) continue;
        const start = if (first[i]) |f| l.at(f.started_ns) else 0;
        const ready = if (first[i]) |f| start - f.waited_s else 0;
        try rows.append(a, .{
            .rule = i,
            .start_s = start,
            .waited_s = waited[i],
            .ran_s = work[i],
            .earlier = tries[i] - 1,
            .held_s = ready,
            .between_s = @max(ended[i] - ready - waited[i] - work[i], 0),
            .end_s = ended[i],
        });
    }
    std.mem.reverse(PathRow, rows.items);
    var prev_end: f64 = 0;
    for (rows.items) |*p| {
        p.held_s = @max(p.held_s - prev_end, 0);
        prev_end = ended[p.rule];
        l.path_ran_s += p.ran_s;
        l.path_waited_s += p.waited_s;
        l.path_held_s += p.held_s;
        l.path_between_s += p.between_s;
    }
    l.path_checks_s = @min(l.tracker.checks_s, l.elapsed_s);
    l.path_after_s = @max(l.elapsed_s - l.path_checks_s - prev_end, 0);
    l.path = rows.items;
}

fn collectBounds(a: Allocator, l: *Launch) !void {
    var bounds: std.ArrayList(Bound) = .empty;
    if (l.path.len > 0) try bounds.append(a, .{ .kind = .chain, .seconds = l.path_ran_s });
    var threads: f64 = 0;
    var cpu: f64 = 0;
    var memory: f64 = 0;
    var jobs: f64 = 0;
    for (l.rows) |r| {
        threads += r.threads * r.wall_s;
        cpu += r.cpu_s;
        memory += (r.reserved_mib orelse r.request_mib) * r.wall_s;
        jobs += r.wall_s;
    }
    if (l.max_threads > 0 and threads > 0) try bounds.append(a, .{ .kind = .threads, .work = threads, .limit = l.max_threads, .seconds = threads / l.max_threads });
    if (l.max_threads > 0 and cpu > 0) try bounds.append(a, .{ .kind = .cpu, .work = cpu, .limit = l.max_threads, .seconds = cpu / l.max_threads });
    const end_ns = l.t0_ns + std.math.lossyCast(i128, l.elapsed_s * 1e9);
    for (l.shared()) |s| {
        const open: f64 = if (s.held_since > 0) @as(f64, @floatFromInt(@max(end_ns - s.held_since, 0))) / 1e9 else 0;
        memory += (s.reserved_mib orelse s.declared_mib) * (s.held_s + open);
    }
    if (l.max_memory_mib > 0 and memory > 0) try bounds.append(a, .{ .kind = .memory, .work = memory, .limit = l.max_memory_mib, .seconds = memory / l.max_memory_mib });
    if (l.max_jobs > 0 and l.max_jobs < l.max_threads and jobs > 0) try bounds.append(a, .{ .kind = .jobs, .work = jobs, .limit = l.max_jobs, .seconds = jobs / l.max_jobs });
    if (l.wf) |wf| for (wf.groups) |grp| {
        var units: f64 = 0;
        for (l.rows) |r| for (r.groups) |u| if (eql(u8, u.name, grp.name)) {
            units += u.count * r.wall_s;
        };
        if (units > 0 and grp.max > 0) try bounds.append(a, .{ .kind = .group, .name = grp.name, .work = units, .limit = @floatFromInt(grp.max), .seconds = units / @as(f64, @floatFromInt(grp.max)) });
    };
    if (l.engine_cpu_s) |e| if (e > 0) try bounds.append(a, .{ .kind = .engine, .seconds = e });
    l.bounds = bounds.items;
    for (l.bounds, 0..) |b, i| if (l.binding == null or b.seconds > l.bounds[l.binding.?].seconds) {
        l.binding = i;
    };
}

fn collectWaits(a: Allocator, l: *Launch) !void {
    for (l.rows) |r| {
        if (r.queue_recorded) l.waits_recorded = true;
        for (r.waits) |w| {
            const gop = try l.waits.getOrPut(a, w.reason);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += w.seconds;
        }
    }
    const Ctx = struct {
        values: []const f64,
        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
            return c.values[x] > c.values[y];
        }
    };
    l.waits.sort(Ctx{ .values = l.waits.values() });

    const tr = &l.tracker;
    var groups: std.ArrayList(GroupAdvice) = .empty;
    for (l.waits.keys(), l.waits.values()) |reason, seconds| {
        if (!std.mem.startsWith(u8, reason, "group:") or seconds < 0.05) continue;
        const name = reason["group:".len..];
        var moments: usize = 0;
        var fit: usize = 0;
        for (tr.samples.items) |s| {
            var waiting = false;
            var fits = false;
            for (tr.group_waits.items) |w| {
                if (!eql(u8, w.group, name) or w.to_ns == 0 or s.ns < w.from_ns or s.ns >= w.to_ns) continue;
                const v = tr.rules.items[w.rule];
                if (v.threads == 0 and v.memory_mib == 0) continue;
                waiting = true;
                if (l.max_threads - s.threads_reserved >= @as(f64, @floatFromInt(v.threads)) and l.max_memory_mib - s.memory_reserved_mib >= @as(f64, @floatFromInt(v.memory_mib))) fits = true;
            }
            moments += @intFromBool(waiting);
            fit += @intFromBool(fits);
        }
        try groups.append(a, .{ .name = name, .seconds = seconds, .samples = moments, .fit = if (moments > 0) @as(f64, @floatFromInt(fit)) / @as(f64, @floatFromInt(moments)) else null });
    }
    l.groups = groups.items;
}
