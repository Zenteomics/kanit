//! A launch as its records describe it, read once for every report.
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

// ---- attempt records ----

/// Time a ready attempt waited for one resource.
pub const Wait = struct { reason: []const u8, seconds: f64 };

/// Units of a resource group an attempt held while it ran.
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
    /// What admission reserved for it, a container's Podman client
    /// included; records that do not say reserved `request_mib`.
    reserved_mib: ?f64 = null,
    /// Units of resource groups it held.
    groups: []const GroupUse = &.{},
    /// cgroup peak (includes page cache) and process peak RSS.
    peak_mib: ?f64,
    rss_mib: f64,
    /// The largest anonymous memory the cgroup was seen to hold while the
    /// attempt ran, sampled; null without isolation or in older records.
    anon_mib: ?f64 = null,
    oom_kill: f64,
    limit_events: f64,
    waited_s: f64,
    /// What it waited for longest, and every wait by reason.
    wait_reason: []const u8,
    waits: []const Wait = &.{},
    /// The engine recorded the attempt's queue; older records lack it.
    queue_recorded: bool = false,
    /// Share of wall time some task of the attempt stalled on each resource.
    cpu_stall: ?f64,
    memory_stall: ?f64,
    io_stall: ?f64,
    /// The attempt mapped shared inputs, which count in its RSS but are
    /// charged to their holders.
    uses_shared: bool,
    /// The diagnostics files a failed attempt kept, as the rule wrote them.
    diagnostics: []const []const u8 = &.{},
    /// Ran in a container: its process is the Podman client.
    in_container: bool = false,
    /// Start time, nanoseconds since the epoch; 0 when not recorded.
    started_ns: i128 = 0,
    /// What the rule is: its step, and its category, tool and sample when
    /// known, as the workflow declared them or as derived from its name.
    step: []const u8 = "",
    category: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    sample: ?[]const u8 = null,
    /// Directory of the attempt's files.
    dir: []const u8 = "",
    /// For a rule reused in a launch, the earlier launch whose attempt made
    /// its outputs; null for an attempt of the launch itself.
    reused_from: ?[]const u8 = null,

    pub fn completed(self: Attempt) bool {
        return eql(u8, self.status, "completed");
    }

    pub fn cpuEfficiency(self: Attempt) f64 {
        if (self.wall_s <= 0 or self.threads <= 0) return 0;
        return self.cpu_s / (self.wall_s * self.threads);
    }

    /// The attempt ran for at least half a second but its own cgroup did
    /// almost nothing: under a tenth of its CPU request and a twentieth of
    /// its memory request. The command waited (a sleep, the network, a
    /// lock) or handed the work to a process outside its cgroup, such as
    /// another supervisor's; its counters size nothing either way.
    pub fn idle(self: Attempt) bool {
        if (self.wall_s < 0.5 or !self.completed()) return false;
        const memory = @max(self.peak_mib orelse 0, self.rss_mib);
        return self.cpuEfficiency() < 0.1 and memory < @max(self.request_mib * 0.05, 64);
    }

    /// The memory a request must cover: the largest process RSS, or the
    /// cgroup peak where the process size misses the work (mapped shared
    /// inputs count in the RSS but are charged to their holders; in a
    /// container the process is the Podman client). Page cache beyond it
    /// is reclaimed under the limit, not counted. Processes running at once
    /// can hold more than the largest of them: the sampled anonymous memory
    /// is a lower bound, and the result is never below it.
    pub fn usedMib(self: Attempt) f64 {
        if (self.uses_shared or self.in_container) if (self.peak_mib) |p| return p;
        return @max(self.rss_mib, self.anon_mib orelse 0);
    }

    /// Whether `usedMib` comes from the cgroup's counters, not the process.
    pub fn usedIsPeak(self: Attempt) bool {
        if ((self.uses_shared or self.in_container) and self.peak_mib != null) return true;
        return (self.anon_mib orelse 0) > self.rss_mib;
    }
};

/// A string field, or "" when it is missing.
fn str(v: Value, key: []const u8) []const u8 {
    return fields.str(v, key) orelse "";
}

/// The strings of array `v`; others and a missing array give none.
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

/// An attempt's labels as its record holds them; a record written before
/// labels existed gets the labels derived from its rule name and image.
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

/// The median of `xs`, which must be sorted ascending; 0 when empty.
pub fn median(xs: []const f64) f64 {
    if (xs.len == 0) return 0;
    const m = xs.len / 2;
    return if (xs.len % 2 == 1) xs[m] else (xs[m - 1] + xs[m]) / 2;
}

/// Reads every attempt record of a launch, in rule and attempt order:
/// `attempts/<rule>/<NNN>/record.json`, where NNN is zero-padded so the
/// names sort by number. An attempt still running has no record yet.
pub fn attempts(gpa: Allocator, a: Allocator, launch_dir: []const u8, unreadable: ?*std.ArrayList([]const u8)) ![]Attempt {
    const dir = try std.fs.path.join(a, &.{ launch_dir, "attempts" });
    var out: std.ArrayList(Attempt) = .empty;
    for ((try sys.dirNames(gpa, a, dir)) orelse &.{}) |rule| {
        const rule_dir = try std.fs.path.join(a, &.{ dir, rule });
        for ((try sys.dirNames(gpa, a, rule_dir)) orelse &.{}) |n| {
            if (try readRecord(gpa, a, try std.fs.path.join(a, &.{ rule_dir, n, "record.json" }), unreadable)) |r| try out.append(a, r);
        }
    }
    return out.items;
}

/// The attempt in record file `path`, or null when there is none yet or it
/// cannot be read. The path of a record that exists but does not parse is
/// added to `unreadable`, in `a`.
fn readRecord(gpa: Allocator, a: Allocator, path: []const u8, unreadable: ?*std.ArrayList([]const u8)) !?Attempt {
    const bytes = sys.readFile(gpa, path, 16 << 20) catch |err| return if (err == error.OutOfMemory) err else null;
    defer gpa.free(bytes);
    const v = std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (unreadable) |list| try list.append(a, path);
        return null;
    };
    // A record of a newer format is left out rather than misread.
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
        try waits.append(a, .{ .reason = str(item, "reason"), .seconds = s });
        if (s > top_s) {
            top_s = s;
            top_reason = str(item, "reason");
        }
    };
    var groups: std.ArrayList(GroupUse) = .empty;
    if (req) |q| if (get(q, "groups")) |gs| if (gs == .array) for (gs.array.items) |item| {
        try groups.append(a, .{ .name = str(item, "name"), .count = num(get(item, "count")) orelse 1 });
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
        .diagnostics = try stringsOf(a, get(v, "diagnostics")),
        .started_ns = tracker.parseTime(str(v, "started")) orelse 0,
        .step = labels.step,
        .category = labels.category,
        .tool = labels.tool,
        .sample = labels.sample,
        .dir = try a.dupe(u8, std.fs.path.dirname(path).?),
    };
}

/// For each rule in `names`, which a launch reused, the attempt that made
/// the outputs it reused: the rule's last completed attempt in an earlier
/// launch of the same working directory. Launch IDs begin with their start
/// time, so earlier launches sort first. A rule whose earlier launch was
/// cleaned up is left out.
pub fn reusedAttempts(gpa: Allocator, a: Allocator, launch_dir: []const u8, names: []const []const u8, unreadable: ?*std.ArrayList([]const u8)) ![]Attempt {
    if (names.len == 0) return &.{};
    var wanted: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (names) |n| try wanted.put(a, n, {});
    const launches_dir = std.fs.path.dirname(launch_dir) orelse return &.{};
    const id = std.fs.path.basename(launch_dir);
    const launches = try records.launchNames(gpa, a, std.fs.path.dirname(launches_dir) orelse return &.{});

    var out: std.ArrayList(Attempt) = .empty;
    // Newest earlier launch first, so each rule takes its last completed attempt.
    var k = launches.len;
    while (k > 0 and wanted.count() > 0) {
        k -= 1;
        const launch = launches[k];
        if (!std.mem.lessThan(u8, launch, id)) continue;
        var i: usize = 0;
        while (i < wanted.count()) {
            const rule = wanted.keys()[i];
            // The rule's last completed attempt in that launch, if any.
            const rule_dir = try std.fs.path.join(a, &.{ launches_dir, launch, "attempts", rule });
            const numbers = (try sys.dirNames(gpa, a, rule_dir)) orelse &.{};
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
            } else i += 1;
        }
    }
    return out.items;
}

// ---- the launch ----

/// Where a selected rule stands.
pub const State = enum {
    /// Its producers have not finished.
    pending,
    /// Ready, waiting for resources.
    waiting,
    running,
    /// Asked to stop, still running.
    stopping,
    completed,
    reused,
    failed,
    /// A producer did not complete.
    blocked,
    cancelled,
    /// The launch ended before it was ready.
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
    /// Attempts started in this launch.
    attempts: u32 = 0,
    /// Its latest completed run: this launch's, or, for a rule reused here,
    /// the earlier run whose outputs it reused.
    run: ?Attempt = null,
    /// This launch's last attempt, whatever its result.
    final: ?Attempt = null,
    /// Index of its step in `Launch.steps`.
    step: usize = 0,
    /// The current attempt's times while it runs, for the live page.
    started_ns: i128 = 0,
    reason: []const u8 = "",
};

/// How to size a step's request from its runs.
pub const Sizing = struct {
    threads: f64 = 0,
    memory_mib: f64 = 0,
    /// Why there is no plain suggestion: the runs were idle, or an
    /// attempt was killed for exceeding its memory, so the suggestion is a
    /// guess above the request it exceeded.
    note: enum { none, measured, idle, out_of_memory } = .none,
    /// The runs kept nine tenths or more of the threads they requested busy
    /// over their time: the request capped them, so what they would use is not known, and more threads may help.
    at_thread_limit: bool = false,
};

pub const Step = struct {
    name: []const u8,
    category: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    /// Producers deep in the graph, and the first rule of the step in the
    /// file: the pipeline order.
    depth: u32 = 0,
    first: usize = 0,
    rules: std.ArrayList(usize) = .empty,
    /// Steps whose rules produce inputs of this step's rules.
    parents: std.ArrayList(usize) = .empty,
    samples: usize = 0,
    /// Selected rules by state.
    states: [@typeInfo(State).@"enum".fields.len]u32 = @splat(0),

    // The latest completed run of each rule.
    runs: usize = 0,
    reused: usize = 0,
    /// Wall times, ascending, and their median.
    walls: std.ArrayList(f64) = .empty,
    median_s: f64 = 0,
    wall_s: f64 = 0,
    cpu_s: f64 = 0,
    /// The most cores one run kept busy, and the threads requested.
    cores: f64 = 0,
    threads: f64 = 0,
    request_mib: f64 = 0,
    /// The largest `Attempt.usedMib` and cgroup peak of the runs.
    used_mib: f64 = 0,
    used_is_peak: bool = false,
    peak_mib: f64 = 0,
    idle: usize = 0,
    limit_events: f64 = 0,
    /// Thread-seconds the runs reserved: wall time times threads.
    reserved_s: f64 = 0,
    stall_n: usize = 0,
    cpu_stall: f64 = 0,
    memory_stall: f64 = 0,
    io_stall: f64 = 0,
    // This launch's attempts that did not complete.
    failed_attempts: usize = 0,
    oom_kills: f64 = 0,
    /// The largest request an attempt exceeded when it was killed.
    oom_request_mib: f64 = 0,
    sizing: Sizing = .{},

    pub fn count(self: Step, s: State) u32 {
        return self.states[@intFromEnum(s)];
    }

    pub fn selected(self: Step) usize {
        return self.rules.items.len;
    }

    /// CPU use of the runs: their CPU time over the thread-seconds they
    /// reserved, so a long run weighs more than a short one.
    pub fn efficiency(self: Step) f64 {
        return if (self.reserved_s > 0) self.cpu_s / self.reserved_s else 0;
    }

    /// The runs add up to a second or more, enough to judge their CPU use.
    pub fn judged(self: Step) bool {
        return self.wall_s >= 1;
    }

    /// What the step spent its time on, judged from its stall shares and CPU
    /// use; "-" when there is too little to judge: runs under a second in
    /// all, or no stall shares to tell waiting from work.
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
        // Busy, but on fewer cores than it reserved: the program runs
        // fewer threads than it was given.
        if (self.threads >= 2 and self.cores >= 0.7 and self.cores < self.threads * 0.6) return "runs fewer threads";
        if (!stalls) return "-";
        return if (eff < 0.3) "mostly idle" else "mixed";
    }

    /// Most runs were idle.
    pub fn mostlyIdle(self: Step) bool {
        return self.runs > 0 and self.idle * 2 > self.runs;
    }
};

/// One rule on the critical path, with every attempt it made in this launch.
pub const PathRow = struct {
    rule: usize,
    /// Seconds from the launch start to its first attempt's start.
    start_s: f64,
    /// Time its attempts waited once ready, and the time they ran.
    waited_s: f64,
    ran_s: f64,
    /// Attempts before the final one.
    earlier: i64,
    /// Time between the end of the rule before it on the path, or the
    /// launch's start, and its becoming ready: it waited for producers off
    /// the path.
    held_s: f64 = 0,
    /// Time between its attempts that none of them waited or ran, as when
    /// a stopped attempt was retried later.
    between_s: f64 = 0,
    /// When its last attempt ended, seconds from the launch start.
    end_s: f64 = 0,
};

/// Launches shorter than this are not judged: starting the engine,
/// checking inputs and recording attempts are then a large part of them,
/// and a few milliseconds swing any share.
pub const judge_s: f64 = 2;

/// A lower bound on the elapsed time of the attempts a launch made: the
/// longest chain of work, which no budget can shorten; the work one limit
/// of the budget had to carry; the CPU time its rules used, over the
/// threads; or the engine's own CPU time, as the engine works on one
/// thread.
pub const Bound = struct {
    kind: enum { chain, threads, cpu, memory, jobs, group, engine },
    /// The group, for a group.
    name: []const u8 = "",
    /// Thread-, CPU-, MiB-, job- or unit-seconds of work, and the limit
    /// that carried it; both 0 for the chain and the engine.
    work: f64 = 0,
    limit: f64 = 0,
    seconds: f64,
};

pub const GroupAdvice = struct {
    name: []const u8,
    /// Rule-seconds that ready rules waited for the group.
    seconds: f64,
    /// Share of the run samples taken while some rule waited for the group
    /// in which the free threads and memory had room for one of the waiting
    /// rules; null without samples.
    fit: ?f64,
    /// Those samples.
    samples: usize = 0,
};

pub const Total = struct { name: []const u8, steps: usize = 0, runs: usize = 0, wall_s: f64 = 0, cpu_s: f64 = 0 };

pub const SampleRow = struct {
    name: []const u8,
    steps: usize = 0,
    runs: usize = 0,
    wall_s: f64 = 0,
    cpu_s: f64 = 0,
    /// Its longest run, and that run's step.
    slowest: ?usize = null,
};

pub const Counts = struct { completed: usize = 0, reused: usize = 0, failed: usize = 0, blocked: usize = 0, cancelled: usize = 0, not_run: usize = 0, running: usize = 0, waiting: usize = 0, pending: usize = 0 };

pub const Launch = struct {
    gpa: Allocator,
    dir: []const u8,
    id: []const u8,
    workdir: []const u8 = "",
    /// The working directory's base name, which names the launch.
    name: []const u8 = "launch",
    /// "workz X.Y.Z", without the executable's digest.
    engine: []const u8 = "",
    /// The engine with its executable's digest, and the workflow file's
    /// digest, as `launch.json` holds them; "" when not recorded.
    engine_id: []const u8 = "",
    workflow_sha256: []const u8 = "",
    /// Record files that exist but do not parse, which were left out.
    unreadable: std.ArrayList([]const u8) = .empty,
    /// The `--threads STEP=N` the launch ran with.
    thread_overrides: []const []const u8 = &.{},
    started_text: []const u8 = "",
    max_threads: f64 = 0,
    max_memory_mib: f64 = 0,
    max_jobs: f64 = 0,
    /// "running" until `summary.json` exists, then its status.
    status: []const u8 = "running",
    finished: bool = false,
    @"error": ?[]const u8 = null,
    /// Seconds since the launch started: from the summary when it ended,
    /// else up to the newest event or now.
    elapsed_s: f64 = 0,
    /// When the launch started its rules, nanoseconds since the epoch.
    t0_ns: i128 = 0,
    counts: Counts = .{},
    selected: usize = 0,
    engine_cpu_s: ?f64 = null,
    engine_rss_mib: ?f64 = null,

    tracker: tracker.Tracker,
    wf: ?workflow.Workflow = null,
    g: ?graph.Graph = null,
    /// Why the workflow snapshot gives no graph, when it does not.
    snapshot_problem: ?[]const u8 = null,

    /// This launch's attempts, in rule and attempt order.
    rows: []const Attempt = &.{},
    /// Rules reused here whose earlier run is gone from the records.
    reused_unrecorded: usize = 0,
    /// Every rule of the workflow, in file order; `selected` marks the
    /// launch's.
    rules: []Rule = &.{},
    /// Each rule's index in `rules`, by name.
    rule_index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Steps of the selected rules, in pipeline order.
    steps: []Step = &.{},
    /// Distinct samples of the selected rules, in name order.
    samples: []const []const u8 = &.{},
    /// Some selected rule declares a category.
    by_category: bool = false,
    /// The critical path: the longest chain of work in this launch, its
    /// work and the time its rules waited once ready.
    path: []const PathRow = &.{},
    path_ran_s: f64 = 0,
    path_waited_s: f64 = 0,
    path_held_s: f64 = 0,
    path_between_s: f64 = 0,
    /// Seconds from the end of the path's last rule to the end of the
    /// launch: rules off the path still ran. Held, waited, ran, between and
    /// after add up to the elapsed time.
    path_after_s: f64 = 0,
    /// Lower bounds on the elapsed time, and the largest of them: what
    /// limited the launch.
    bounds: []const Bound = &.{},
    binding: ?usize = null,
    /// Rule-seconds that ready attempts waited, by reason, most first.
    waits: std.StringArrayHashMapUnmanaged(f64) = .empty,
    /// Some attempt recorded its queue.
    waits_recorded: bool = false,
    groups: []const GroupAdvice = &.{},

    pub fn deinit(self: *Launch) void {
        if (self.g) |*g| g.deinit();
        if (self.wf) |*wf| wf.deinit();
        self.tracker.deinit();
    }

    /// How far the launch ran over its largest bound, in percent; null when
    /// no attempt ran, or the launch is too short to say.
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

    /// Seconds from the launch start to `ns`.
    pub fn at(self: *const Launch, ns: i128) f64 {
        return @as(f64, @floatFromInt(ns - self.t0_ns)) / 1e9;
    }

    /// CPU seconds of every rule's latest run, and of those this launch ran.
    pub fn cpu(self: *const Launch) struct { all: f64, here: f64 } {
        var all: f64 = 0;
        var here: f64 = 0;
        for (self.rules) |r| if (r.selected) if (r.run) |run| {
            all += run.cpu_s;
            if (run.reused_from == null) here += run.cpu_s;
        };
        return .{ .all = all, .here = here };
    }

    /// Runs summed per value of a label, most CPU time first; rules
    /// without that label are left out.
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

    /// Each sample's runs, most CPU time first.
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

    /// The selected rule named `name`.
    pub fn ruleOf(self: *const Launch, name: []const u8) ?*const Rule {
        const i = self.rule_index.get(name) orelse return null;
        return if (self.rules[i].selected) &self.rules[i] else null;
    }

    /// Whether a run took at least 1.5 times its step's median and 2 s more:
    /// worth a look, since the same work took longer on this data.
    pub fn slow(self: *const Launch, r: Rule) bool {
        const run = r.run orelse return false;
        const m = self.steps[r.step].median_s;
        return m > 0 and run.wall_s >= m * 1.5 and run.wall_s - m >= 2;
    }

    /// The rule of `step` with `sample` (null: the rules without a sample);
    /// with several, the one whose run took longest.
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

/// "workz X.Y.Z" from an engine ID, without the executable's digest.
fn engineName(id: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, id, " sha256:")) |i| id[0..i] else id;
}

/// A key for a pair of names, such as a sample and a step.
fn pairKey(a: Allocator, x: []const u8, y: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ x, y });
}

/// The reason a workflow snapshot gave no graph: its problems, which name
/// their lines, on one line, or the error's name.
fn snapshotProblem(a: Allocator, p: *const workflow.Problem, err: anyerror) ![]const u8 {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (p.message.len == 0) return @errorName(err);
    return std.mem.replaceOwned(u8, a, p.message, "\n", "; ");
}

/// A JSON record file, or null when there is none. One that exists but does
/// not parse reads as absent, and its path is added to `unreadable`, in `a`.
fn readJson(gpa: Allocator, a: Allocator, path: []const u8, unreadable: *std.ArrayList([]const u8)) !?Value {
    const bytes = sys.readFile(gpa, path, 1 << 20) catch |err| return if (err == error.OutOfMemory) err else null;
    defer gpa.free(bytes);
    const v = std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch |err| {
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

/// Reads a launch's records into one model. `a` holds everything the model
/// returns; call `deinit` for the event tracker and the workflow.
pub fn load(gpa: Allocator, a: Allocator, launch_dir: []const u8) !Launch {
    var l: Launch = .{ .gpa = gpa, .dir = launch_dir, .id = std.fs.path.basename(launch_dir), .tracker = try tracker.Tracker.init(gpa, launch_dir) };
    errdefer l.deinit();
    _ = try l.tracker.update();
    const tr = &l.tracker;

    if (try readJson(gpa, a, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }), &l.unreadable)) |v| {
        l.workdir = str(v, "workdir");
        if (l.workdir.len > 0) l.name = std.fs.path.basename(l.workdir);
        l.engine_id = str(v, "engine");
        l.engine = engineName(l.engine_id);
        l.workflow_sha256 = str(v, "workflow_sha256");
        if (get(v, "thread_overrides")) |list| if (list == .array) {
            var given: std.ArrayList([]const u8) = .empty;
            for (list.array.items) |item| if (item == .string) try given.append(a, item.string);
            l.thread_overrides = given.items;
        };
        l.started_text = str(v, "started");
        l.max_threads = num(get(v, "max_threads")) orelse 0;
        l.max_memory_mib = num(get(v, "max_memory_mib")) orelse 0;
        l.max_jobs = num(get(v, "jobs")) orelse 0;
    }
    if (tr.max_threads > 0) l.max_threads = @floatFromInt(tr.max_threads);
    if (tr.max_memory_mib > 0) l.max_memory_mib = @floatFromInt(tr.max_memory_mib);
    if (tr.max_jobs > 0) l.max_jobs = @floatFromInt(tr.max_jobs);
    l.t0_ns = if (tr.launch_ns != 0) tr.launch_ns else tr.started_ns;
    l.selected = tr.selected;

    const summary = try readJson(gpa, a, try std.fs.path.join(a, &.{ launch_dir, "summary.json" }), &l.unreadable);
    if (summary) |s| {
        l.finished = true;
        l.status = str(s, "status");
        l.@"error" = optStr(get(s, "error"));
        l.elapsed_s = @max(num(get(s, "elapsed_s")) orelse 0, 0);
        if (num(get(s, "selected"))) |n| l.selected = std.math.lossyCast(usize, n);
        if (get(s, "engine_cost")) |c| {
            l.engine_cpu_s = num(get(c, "cpu_s"));
            l.engine_rss_mib = num(get(c, "max_rss_mib"));
        }
        if (l.engine.len == 0) l.engine = engineName(str(s, "engine"));
    } else if (tr.finished) {
        l.finished = true;
        l.status = tr.final_status;
        if (tr.final_error.len > 0) l.@"error" = tr.final_error;
    }
    if (l.elapsed_s == 0 and l.t0_ns != 0) {
        const end = if (tr.finished) tr.finished_ns else if (summary == null) sys.realNs() else l.t0_ns;
        l.elapsed_s = @max(@as(f64, @floatFromInt(end - l.t0_ns)) / 1e9, 0);
    }

    l.rows = try attempts(gpa, a, launch_dir, &l.unreadable);
    var reused_names: std.ArrayList([]const u8) = .empty;
    for (tr.rules.items) |r| if (r.status == .reused) try reused_names.append(a, r.name);
    const reused = try reusedAttempts(gpa, a, launch_dir, reused_names.items, &l.unreadable);
    l.reused_unrecorded = reused_names.items.len - reused.len;

    // The workflow snapshot gives every rule its labels and the graph.
    var problem: workflow.Problem = .{};
    if (l.workdir.len > 0) {
        if (workflow.load(gpa, try std.fs.path.join(a, &.{ launch_dir, "workflow" }), l.workdir, &problem)) |wf| {
            l.wf = wf;
            // The launch ran with its `--threads` overrides.
            for (l.thread_overrides) |o| if (std.mem.indexOfScalar(u8, o, '=')) |eq| {
                const n = std.fmt.parseInt(u32, o[eq + 1 ..], 10) catch continue;
                _ = l.wf.?.overrideThreads(o[0..eq], n);
            };
            if (graph.build(gpa, &l.wf.?, &problem)) |g| {
                l.g = g;
            } else |err| l.snapshot_problem = try snapshotProblem(a, &problem, err);
        } else |err| l.snapshot_problem = try snapshotProblem(a, &problem, err);
    }
    if (problem.message.len > 0) gpa.free(problem.message);

    try collectRules(a, &l, reused);
    try collectSteps(a, &l);
    try collectPath(a, &l);
    try collectBounds(a, &l);
    try collectWaits(a, &l);
    return l;
}

/// Every rule with its state, its run and its final attempt.
fn collectRules(a: Allocator, l: *Launch, reused: []const Attempt) !void {
    const tr = &l.tracker;
    var rules: std.ArrayList(Rule) = .empty;
    if (l.wf) |wf| {
        for (wf.rules) |r| try rules.append(a, .{ .name = r.name, .labels = r.labels, .selected = tr.index.contains(r.name) });
    } else {
        // Without the snapshot, the rules are those the events and the
        // attempt records name, with the labels the records carry.
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
    // A rule no event speaks of takes its state from its last attempt.
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
    for (l.rows) |row| {
        const i = index.get(row.rule) orelse continue;
        const r = &rules.items[i];
        if (r.final == null or row.attempt > r.final.?.attempt) r.final = row;
        if (row.completed()) r.run = row;
    }
    for (reused) |row| if (index.get(row.rule)) |i| {
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

/// The steps of the selected rules in pipeline order, with what their runs
/// took and the request to suggest.
fn collectSteps(a: Allocator, l: *Launch) !void {
    var depth: []u32 = &.{};
    if (l.g) |g| {
        depth = try a.alloc(u32, l.rules.len);
        for (g.order) |i| {
            depth[i] = 0;
            for (g.parents[i]) |p| depth[i] = @max(depth[i], depth[p] + 1);
        }
    }
    // This launch's attempts that did not complete, per rule.
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
    // A rule's request also counts where it has no run yet.
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
    // Pipeline order: graph depth, then the step's first rule in the file.
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
    // Edges between steps, from the rules' producers.
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

/// The request to suggest for a step: memory from the largest used memory
/// plus a fifth, in 64 MiB steps; threads from the most cores a run used,
/// rounded up and at most the request. A step whose attempt was killed for
/// exceeding its memory gets half again the request it exceeded, at least;
/// an idle step keeps its request, as its counters measured nothing.
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

/// The critical path: the longest chain of work through the graph, each
/// rule weighing the wall time of its attempts in this launch, as retries
/// run one after another. However large the budget, the launch could not
/// take less.
fn collectPath(a: Allocator, l: *Launch) !void {
    const g = l.g orelse return;
    const n = l.rules.len;
    const work = try a.alloc(f64, n);
    const waited = try a.alloc(f64, n);
    const tries = try a.alloc(i64, n);
    // Each rule's first attempt, which tells when the rule became ready,
    // and when its last attempt ended, in seconds from the launch's start.
    const first = try a.alloc(?Attempt, n);
    const ended = try a.alloc(f64, n);
    @memset(work, 0);
    @memset(waited, 0);
    @memset(tries, 0);
    @memset(first, null);
    @memset(ended, 0);
    for (l.rows) |r| if (l.rule_index.get(r.rule)) |i| {
        work[i] += r.wall_s;
        waited[i] += r.waited_s;
        tries[i] += 1;
        if (r.started_ns > 0) {
            if (first[i] == null or r.started_ns < first[i].?.started_ns) first[i] = r;
            ended[i] = @max(ended[i], l.at(r.started_ns) + r.wall_s);
        }
    };
    // The longest chain ending at each rule, and the producer it continues.
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
        // A rule that did no work here, reused or not selected, only links.
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
    // Held: from the end of the rule before on the path, or from the start.
    var prev_end: f64 = 0;
    for (rows.items) |*p| {
        p.held_s = @max(p.held_s - prev_end, 0);
        prev_end = ended[p.rule];
        l.path_ran_s += p.ran_s;
        l.path_waited_s += p.waited_s;
        l.path_held_s += p.held_s;
        l.path_between_s += p.between_s;
    }
    l.path_after_s = @max(l.elapsed_s - prev_end, 0);
    l.path = rows.items;
}

/// The lower bounds on the elapsed time: the critical path, and for each
/// limit of the budget the work it carried over the limit. The largest is
/// what limited the launch; the elapsed time beyond it went to waiting
/// that scheduling could not avoid, to launching and to starting rules.
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
    // The CPU time used fits in the threads however rules are ordered; far
    // below the threads bound, the requests reserved more than was used.
    if (l.max_threads > 0 and cpu > 0) try bounds.append(a, .{ .kind = .cpu, .work = cpu, .limit = l.max_threads, .seconds = cpu / l.max_threads });
    // A shared input's memory counts against the budget while it is held.
    const end_ns = l.t0_ns + std.math.lossyCast(i128, l.elapsed_s * 1e9);
    for (l.shared()) |s| {
        const open: f64 = if (s.held_since > 0) @as(f64, @floatFromInt(@max(end_ns - s.held_since, 0))) / 1e9 else 0;
        memory += (s.reserved_mib orelse s.declared_mib) * (s.held_s + open);
    }
    if (l.max_memory_mib > 0 and memory > 0) try bounds.append(a, .{ .kind = .memory, .work = memory, .limit = l.max_memory_mib, .seconds = memory / l.max_memory_mib });
    // Every rule takes a thread, so jobs bind only below the thread budget.
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

/// Waiting by reason from this launch's attempt records, and for each
/// resource group whether the budget had room while its rules waited.
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
        // Each sample counts once, however many rules waited at it.
        var moments: usize = 0;
        var fit: usize = 0;
        for (tr.samples.items) |s| {
            var waiting = false;
            var fits = false;
            for (tr.group_waits.items) |w| {
                if (!eql(u8, w.group, name) or w.to_ns == 0 or s.ns < w.from_ns or s.ns >= w.to_ns) continue;
                waiting = true;
                const v = tr.rules.items[w.rule];
                if (l.max_threads - s.threads_reserved >= @as(f64, @floatFromInt(v.threads)) and l.max_memory_mib - s.memory_reserved_mib >= @as(f64, @floatFromInt(v.memory_mib))) fits = true;
            }
            moments += @intFromBool(waiting);
            fit += @intFromBool(fits);
        }
        try groups.append(a, .{ .name = name, .seconds = seconds, .samples = moments, .fit = if (moments > 0) @as(f64, @floatFromInt(fit)) / @as(f64, @floatFromInt(moments)) else null });
    }
    l.groups = groups.items;
}
