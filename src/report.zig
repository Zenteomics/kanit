//! `report`: what a launch's attempts used and what limited the run, as
//! text, TSV and JSON. The figures come from `model.zig`, which the HTML
//! page reads too.
const std = @import("std");
const model = @import("model.zig");
const units = @import("units.zig");
const Allocator = std.mem.Allocator;
const Attempt = model.Attempt;

fn cut(name: []const u8, n: usize) []const u8 {
    return name[0..@min(name.len, n)];
}

// ---- one row per attempt ----

/// One attempt as TSV and JSON show it. The JSON form keeps unrounded
/// numbers and adds the start time and the attempt directory.
const Row = struct {
    rule: []const u8,
    attempt: i64,
    status: []const u8,
    wall_s: f64,
    cpu_s: f64,
    cpu_efficiency: f64,
    threads: f64,
    memory_mib: f64,
    peak_mib: ?f64,
    max_rss_mib: f64,
    peak_per_request: ?f64,
    oom_kills: f64,
    limit_events: f64,
    waited_s: f64,
    wait_reason: ?[]const u8,
    cpu_stall: ?f64,
    memory_stall: ?f64,
    io_stall: ?f64,
    idle: bool,
    reason: ?[]const u8,
    step: []const u8,
    sample: ?[]const u8,
    category: ?[]const u8,
    tool: ?[]const u8,
    started_ns: i128,
    directory: []const u8,

    fn of(r: Attempt) Row {
        return .{
            .rule = r.rule,
            .attempt = r.attempt,
            .status = r.status,
            .wall_s = r.wall_s,
            .cpu_s = r.cpu_s,
            .cpu_efficiency = r.cpuEfficiency(),
            .threads = r.threads,
            .memory_mib = r.request_mib,
            .peak_mib = r.peak_mib,
            .max_rss_mib = r.rss_mib,
            .peak_per_request = if (r.peak_mib) |p| if (r.request_mib > 0) p / r.request_mib else null else null,
            .oom_kills = r.oom_kill,
            .limit_events = r.limit_events,
            .waited_s = r.waited_s,
            .wait_reason = if (r.wait_reason.len > 0) r.wait_reason else null,
            .cpu_stall = r.cpu_stall,
            .memory_stall = r.memory_stall,
            .io_stall = r.io_stall,
            .idle = r.idle(),
            .reason = if (r.reason.len > 0) r.reason else null,
            .step = r.step,
            .sample = r.sample,
            .category = r.category,
            .tool = r.tool,
            .started_ns = r.started_ns,
            .directory = r.dir,
        };
    }
};

// A missing number prints as NA, which R and pandas read as missing; a
// missing text prints as -.
fn opt(w: *std.Io.Writer, v: anytype, comptime fmt: []const u8) !void {
    if (v) |x| try w.print(fmt, .{x}) else try w.writeAll(if (comptime std.mem.eql(u8, fmt, "{s}")) "-" else "NA");
}

/// One row per attempt, tab-separated, with a header; NA for no number and
/// `-` for no text.
pub fn writeTsv(w: *std.Io.Writer, rows: []const Attempt) !void {
    try w.writeAll("rule\tattempt\tstatus\twall_s\tcpu_s\tcpu_efficiency\tthreads\tmemory_mib\tpeak_mib\tmax_rss_mib\tpeak_per_request\toom_kills\tlimit_events\twaited_s\twait_reason\tcpu_stall\tmemory_stall\tio_stall\tidle\treason\tstep\tsample\tcategory\ttool\n");
    for (rows) |a| {
        const r = Row.of(a);
        try w.print("{s}\t{d}\t{s}\t{d:.3}\t{d:.3}\t{d:.2}\t{d:.0}\t{d:.0}\t", .{ r.rule, r.attempt, r.status, r.wall_s, r.cpu_s, r.cpu_efficiency, r.threads, r.memory_mib });
        try opt(w, r.peak_mib, "{d:.1}");
        try w.print("\t{d:.1}\t", .{r.max_rss_mib});
        try opt(w, r.peak_per_request, "{d:.2}");
        try w.print("\t{d:.0}\t{d:.0}\t{d:.3}\t", .{ r.oom_kills, r.limit_events, r.waited_s });
        try opt(w, r.wait_reason, "{s}");
        try w.writeAll("\t");
        try opt(w, r.cpu_stall, "{d:.3}");
        try w.writeAll("\t");
        try opt(w, r.memory_stall, "{d:.3}");
        try w.writeAll("\t");
        try opt(w, r.io_stall, "{d:.3}");
        try w.print("\t{}\t", .{r.idle});
        try opt(w, r.reason, "{s}");
        try w.print("\t{s}\t", .{r.step});
        try opt(w, r.sample, "{s}");
        try w.writeAll("\t");
        try opt(w, r.category, "{s}");
        try w.writeAll("\t");
        try opt(w, r.tool, "{s}");
        try w.writeAll("\n");
    }
}

/// The same attempts as a JSON array, with the TSV's field names.
pub fn writeJson(a: Allocator, w: *std.Io.Writer, rows: []const Attempt) !void {
    const out = try a.alloc(Row, rows.len);
    for (out, rows) |*o, r| o.* = Row.of(r);
    try w.print("{f}\n", .{std.json.fmt(out, .{ .whitespace = .indent_2 })});
}

// ---- request suggestions ----

/// The suggested request of every step that has one, as TSV or JSON.
pub fn writeSuggestions(w: *std.Io.Writer, l: *const model.Launch, json: bool) !void {
    const Suggestion = struct {
        step: []const u8,
        runs: usize,
        threads: f64,
        threads_used: f64,
        suggest_threads: f64,
        memory_mib: f64,
        used_mib: f64,
        used_basis: []const u8,
        peak_mib: f64,
        suggest_mib: f64,
        note: []const u8,
        at_thread_limit: bool,
    };
    var list: std.ArrayList(Suggestion) = .empty;
    defer list.deinit(l.gpa);
    for (l.steps) |s| {
        if (s.sizing.note == .none) continue;
        try list.append(l.gpa, .{
            .step = s.name,
            .runs = s.runs,
            .threads = s.threads,
            .threads_used = s.cores,
            .suggest_threads = s.sizing.threads,
            .memory_mib = s.request_mib,
            .used_mib = s.used_mib,
            .used_basis = if (s.used_is_peak) "cgroup" else "process",
            .peak_mib = s.peak_mib,
            .suggest_mib = s.sizing.memory_mib,
            .note = @tagName(s.sizing.note),
            .at_thread_limit = s.sizing.at_thread_limit,
        });
    }
    if (json) return w.print("{f}\n", .{std.json.fmt(list.items, .{})});
    try w.writeAll("step\truns\tthreads\tthreads_used\tsuggest_threads\tmemory_mib\tused_mib\tused_basis\tpeak_mib\tsuggest_mib\tnote\tat_thread_limit\n");
    for (list.items) |s| try w.print("{s}\t{d}\t{d:.0}\t{d:.2}\t{d:.0}\t{d:.0}\t{d:.0}\t{s}\t{d:.0}\t{d:.0}\t{s}\t{}\n", .{ s.step, s.runs, s.threads, s.threads_used, s.suggest_threads, s.memory_mib, s.used_mib, s.used_basis, s.peak_mib, s.suggest_mib, s.note, s.at_thread_limit });
}

// ---- comparing two launches ----

/// The change from `was` to `now` as printed with `decimals` places, so two
/// values that print alike show no change; `-` where either is below
/// `floor`, too small for a share to mean anything.
fn change(w: *std.Io.Writer, was: f64, now: f64, decimals: u8, floor: f64) !void {
    const scale = std.math.pow(f64, 10, @floatFromInt(decimals));
    const x = @round(was * scale) / scale;
    const y = @round(now * scale) / scale;
    if (x <= 0 or y <= 0 or x < floor or y < floor) return w.writeAll("       -");
    const pct = (y - x) / x * 100;
    try w.print(" {d:>6.0}%", .{if (@abs(pct) < 0.5) 0 else pct});
}

/// Half the range of a step's wall times over their median: how much its
/// runs differ among themselves; null with fewer than three runs.
fn spread(s: model.Step) ?f64 {
    const xs = s.walls.items;
    if (xs.len < 3 or s.median_s <= 0) return null;
    return (xs[xs.len - 1] - xs[0]) / 2 / s.median_s;
}

/// Thread-seconds that a launch's attempts reserved: wall time times threads.
fn reserved(rows: []const Attempt) f64 {
    var total: f64 = 0;
    for (rows) |r| total += r.wall_s * r.threads;
    return total;
}

fn budget(w: *std.Io.Writer, l: *const model.Launch) !void {
    try w.print("{d:.0} threads, ", .{l.max_threads});
    try units.size(w, l.max_memory_mib);
    try w.print(", {d:.0} jobs", .{l.max_jobs});
}

/// Compares launch `now_dir` with the baseline `was_dir`: their budgets,
/// engines and workflows, the launches' elapsed time, attempts and reserved
/// thread-seconds, then each step's latest runs, this launch's or reused:
/// median wall time, largest peak and total CPU time. One run of each is
/// all there is, so a change inside the runs' own spread is marked.
pub fn writeCompare(gpa: Allocator, a: Allocator, w: *std.Io.Writer, was_dir: []const u8, now_dir: []const u8) !void {
    var was = try model.load(gpa, a, was_dir);
    defer was.deinit();
    var now = try model.load(gpa, a, now_dir);
    defer now.deinit();
    try w.print("baseline {s}\nlaunch   {s}\n", .{ was_dir, now_dir });
    try w.writeAll("budget   ");
    try budget(w, &was);
    try w.writeAll(" against ");
    try budget(w, &now);
    try w.writeAll("\n");
    const budgets_differ = was.max_threads != now.max_threads or was.max_memory_mib != now.max_memory_mib or was.max_jobs != now.max_jobs;
    if (budgets_differ) try w.writeAll("note: the budgets differ, so the elapsed time compares the budgets as well as the work\n");
    if (was.workflow_sha256.len > 0 and now.workflow_sha256.len > 0 and !std.mem.eql(u8, was.workflow_sha256, now.workflow_sha256))
        try w.writeAll("note: the workflow file differs\n");
    if (was.engine_id.len > 0 and now.engine_id.len > 0 and !std.mem.eql(u8, was.engine_id, now.engine_id))
        try w.print("note: the engine differs: {s} against {s}\n", .{ was.engine_id, now.engine_id });
    try w.writeAll("\n                            BASELINE     LAUNCH   CHANGE\n");
    try w.print("  elapsed s               {d:>10.1} {d:>10.1}", .{ was.elapsed_s, now.elapsed_s });
    try change(w, was.elapsed_s, now.elapsed_s, 1, 0.1);
    if (budgets_differ) try w.writeAll("  budgets differ");
    try w.print("\n  attempts                {d:>10} {d:>10}\n  thread-seconds reserved {d:>10.0} {d:>10.0}", .{ was.rows.len, now.rows.len, reserved(was.rows), reserved(now.rows) });
    try change(w, reserved(was.rows), reserved(now.rows), 0, 1);
    try w.writeAll("\n\nper step (latest run of every rule)\n");
    try w.writeAll("                                       WALL S, MEDIAN            PEAK MiB, LARGEST           CPU S, TOTAL\n");
    try w.writeAll("  STEP                           RUNS  BASELINE  LAUNCH CHANGE  BASELINE  LAUNCH CHANGE  BASELINE  LAUNCH CHANGE\n");
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (was.steps) |s| try names.put(a, s.name, {});
    for (now.steps) |s| try names.put(a, s.name, {});
    for (names.keys()) |name| {
        const x = for (was.steps) |s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else model.Step{ .name = name };
        const y = for (now.steps) |s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else model.Step{ .name = name };
        try w.print("  {s:<30} {d:>4}", .{ cut(name, 30), y.runs });
        if (x.runs == 0 or y.runs == 0) {
            const ran = if (x.runs == 0) y else x;
            if (x.runs == 0) {
                try w.print("  {s:>8} {d:>7.2}      -  {s:>8} {d:>7.0}      -  {s:>8} {d:>7.1}      -", .{ "-", ran.median_s, "-", ran.peak_mib, "-", ran.cpu_s });
            } else try w.print("  {d:>8.2} {s:>7}      -  {d:>8.0} {s:>7}      -  {d:>8.1} {s:>7}      -", .{ ran.median_s, "-", ran.peak_mib, "-", ran.cpu_s, "-" });
            try w.print("  no completed run in the {s}\n", .{if (x.runs == 0) "baseline" else "launch"});
            continue;
        }
        // Counters of idle runs size nothing, so they do not compare.
        const outside = x.mostlyIdle() or y.mostlyIdle();
        try w.print("  {d:>8.2} {d:>7.2}", .{ x.median_s, y.median_s });
        try change(w, x.median_s, y.median_s, 2, 0.1);
        try w.print("  {d:>8.0} {d:>7.0}", .{ x.peak_mib, y.peak_mib });
        if (outside) try w.writeAll("       -") else try change(w, x.peak_mib, y.peak_mib, 0, 8);
        try w.print("  {d:>8.1} {d:>7.1}", .{ x.cpu_s, y.cpu_s });
        if (outside) try w.writeAll("       -") else try change(w, x.cpu_s, y.cpu_s, 1, 0.1);
        if (outside) try w.print("  idle in the {s}", .{if (x.mostlyIdle()) "baseline" else "launch"});
        // A median that moved less than the runs differ among themselves
        // has not shown a change.
        const noise = @max(spread(x) orelse 0, spread(y) orelse 0);
        if (noise > 0 and x.median_s >= 0.1 and @abs(y.median_s / x.median_s - 1) < noise) try w.writeAll("  wall time within its runs' spread");
        if (y.reused == y.runs) try w.writeAll("  reused in the launch") else if (y.reused > 0) try w.print("  {d} reused in the launch", .{y.reused});
        try w.writeAll("\n");
    }
}

// ---- what limited a launch ----

/// Prints what limited the launch (its critical path, waiting by reason,
/// resource groups, budget use), then each step's requests against its
/// runs, the time per category, tool and sample, and the shared inputs.
pub fn writeBottlenecks(gpa: Allocator, a: Allocator, w: *std.Io.Writer, launch_dir: []const u8) !void {
    var l = try model.load(gpa, a, launch_dir);
    defer l.deinit();

    try w.print("launch {s}: ", .{l.id});
    try units.duration(w, l.elapsed_s);
    try w.print(" elapsed; {d} {s} in this launch, {d:.0} thread-seconds reserved\n", .{ l.rows.len, if (l.rows.len == 1) "attempt" else "attempts", reserved(l.rows) });
    if (l.rows.len == 0) {
        try w.writeAll("no rule started in this launch");
        if (l.@"error") |e| try w.print(": {s}", .{e});
        try w.writeAll("\n");
    }
    var idle: usize = 0;
    for (l.rows) |r| idle += @intFromBool(r.idle());
    if (idle > 0) try w.print("note: {d} {s} used almost none of {s} requests while running (idle): such an attempt waited, or handed its work to a process outside its cgroup, so its counters size nothing\n", .{ idle, if (idle == 1) "attempt" else "attempts", if (idle == 1) "its" else "their" });

    try writeLimits(w, &l);
    try writePath(w, &l);
    try writeWaits(w, &l);
    try writeSteps(w, &l);
    try writeTime(a, w, &l);
    try writeShared(w, &l);
    try writeUtilization(w, &l);
}

/// What a bound is, in a few words: `threads`, `group disk`.
pub fn boundName(w: *std.Io.Writer, b: model.Bound) !void {
    switch (b.kind) {
        .chain => try w.writeAll("critical path"),
        .threads, .memory, .jobs => try w.writeAll(@tagName(b.kind)),
        .cpu => try w.writeAll("CPU time"),
        .engine => try w.writeAll("engine"),
        .group => try w.print("group {s}", .{b.name}),
    }
}

/// How hard a bound's limit was used: the average reserved over the
/// elapsed time against the limit, or the critical path's rules.
pub fn boundUse(w: *std.Io.Writer, l: *const model.Launch, b: model.Bound) !void {
    const avg = if (l.elapsed_s > 0) b.work / l.elapsed_s else 0;
    switch (b.kind) {
        .chain => {
            try units.count(w, l.path.len, "rule", "rules");
            try w.writeAll(" in a chain of work");
        },
        .threads => try w.print("{d:.1} of {d:.0} threads reserved on average", .{ avg, b.limit }),
        .cpu => try w.print("{d:.1} of {d:.0} cores busy on average", .{ avg, b.limit }),
        .jobs => try w.print("{d:.1} of {d:.0} jobs running on average", .{ avg, b.limit }),
        .group => try w.print("{d:.1} of {d:.0} units held on average", .{ avg, b.limit }),
        .memory => {
            try units.size(w, avg);
            try w.writeAll(" of ");
            try units.size(w, b.limit);
            try w.writeAll(" reserved on average");
        },
        .engine => try w.writeAll("the engine's own CPU time: checks, scheduling and records"),
    }
}

/// The step whose rules reserved the most thread-seconds they did not use,
/// and those seconds; null when none reserved more than one thread.
fn idlestStep(l: *const model.Launch) ?struct { step: *const model.Step, unused: f64 } {
    var best: ?*const model.Step = null;
    var most: f64 = 0;
    for (l.steps) |*s| {
        if (s.runs == 0 or s.threads < 2) continue;
        const unused = s.threads * s.wall_s - s.cpu_s;
        if (unused > most) {
            most = unused;
            best = s;
        }
    }
    return .{ .step = best orelse return null, .unused = most };
}

/// One sentence on what limited the launch, from the largest bound.
pub fn writeVerdict(w: *std.Io.Writer, l: *const model.Launch) !void {
    const b = l.bounds[l.binding orelse return];
    const over = l.overBound() orelse {
        try w.writeAll(if (l.finished) "too short to say what limited it: it took " else "too early to say what limits it: it has taken ");
        try units.duration(w, l.elapsed_s);
        return w.writeAll(", and starting and recording rules weigh too much in so short a time");
    };
    switch (b.kind) {
        .chain => try w.writeAll("the critical path"),
        .threads => try w.writeAll("the thread budget"),
        .cpu => try w.writeAll("the CPU work"),
        .memory => try w.writeAll("the memory budget"),
        .jobs => try w.writeAll("the jobs limit"),
        .group => try w.print("resource group {s}", .{b.name}),
        .engine => try w.writeAll("the engine's own work"),
    }
    try w.writeAll(if (l.finished) " limited this launch: it took " else " limits this launch so far: it has taken ");
    try units.duration(w, l.elapsed_s);
    try w.print(", {d:.0}% more than ", .{over});
    switch (b.kind) {
        .chain => {
            try w.writeAll("the work on its critical path");
            // Each delay names what would cut it: the path's own waits yield
            // to a higher priority; a hold means producers off the path
            // started late, which only more room in the budget changes.
            const notable = struct {
                fn f(s: f64, work: f64) bool {
                    return s >= 0.5 and s >= 0.05 * work;
                }
            }.f;
            if (notable(l.path_waited_s, l.path_ran_s)) {
                try w.writeAll("; its rules waited ");
                try units.duration(w, l.path_waited_s);
                try w.writeAll(" once ready, which a higher priority for them would cut");
            }
            if (notable(l.path_held_s, l.path_ran_s)) {
                try w.writeAll("; its rules were held ");
                try units.duration(w, l.path_held_s);
                try w.writeAll(" for producers off the path, which started late for want of resources");
            }
        },
        .threads => {
            try w.writeAll("its rules' thread requests need at that limit");
            // Requests, not use, fill the thread budget: say how much of
            // what they reserved the rules kept busy, and where most went
            // unused.
            const cpu = for (l.bounds) |x| {
                if (x.kind == .cpu) break x.work;
            } else 0;
            if (cpu > 0 and cpu < 0.8 * b.work) {
                try w.print("; they kept {d:.0}% of the threads they reserved busy", .{cpu / b.work * 100});
                if (idlestStep(l)) |x| if (x.unused >= 0.1 * b.work) {
                    try w.print(", least of all step {s}, which used {d:.1} of its {d:.0} threads at most", .{ x.step.name, x.step.cores, x.step.threads });
                };
            }
        },
        .engine => try w.writeAll("the engine's own CPU time; its rules are so short that recording and starting them takes about as long as running them"),
        .cpu, .memory, .jobs, .group => try w.writeAll("its work needs at that limit"),
    }
}

fn writeLimits(w: *std.Io.Writer, l: *const model.Launch) !void {
    try w.writeAll("\nwhat limited the launch (the attempts it made could not take less than any of these)\n");
    if (l.bounds.len == 0) return w.writeAll("  nothing: no attempt ran in this launch\n");
    for (l.bounds, 0..) |b, i| {
        var name_buf: [64]u8 = undefined;
        var nw: std.Io.Writer = .fixed(&name_buf);
        try boundName(&nw, b);
        try w.print("  {s} {s:<28} ", .{ if (l.binding == i) ">" else " ", cut(nw.buffered(), 28) });
        try units.right(w, 9, units.duration, .{b.seconds});
        try w.writeAll("  ");
        try boundUse(w, l, b);
        try w.writeAll("\n");
    }
    try w.writeAll("  ");
    try writeVerdict(w, l);
    try w.writeAll("\n");
}

fn writePath(w: *std.Io.Writer, l: *const model.Launch) !void {
    try w.writeAll("\ncritical path (the longest chain of work in this launch, and when each rule waited once ready)\n");
    if (l.snapshot_problem) |why| return w.print("  none: the workflow snapshot cannot be read: {s}\n", .{why});
    if (l.path.len == 0) return w.writeAll("  none: no attempt ran\n");
    for (l.path) |p| {
        try w.writeAll("  at ");
        try units.right(w, 8, units.duration, .{p.start_s});
        try w.print("  {s:<40} ran ", .{cut(l.rules[p.rule].name, 40)});
        try units.right(w, 8, units.duration, .{p.ran_s});
        try w.writeAll(", waited ");
        try units.right(w, 8, units.duration, .{p.waited_s});
        if (p.held_s >= 0.05) {
            try w.writeAll(", held ");
            try units.duration(w, p.held_s);
            try w.writeAll(" for producers off the path");
        }
        if (p.earlier > 0) try w.print(", over {d} attempts", .{p.earlier + 1});
        if (p.between_s >= 0.05) {
            try w.writeAll(", ");
            try units.duration(w, p.between_s);
            try w.writeAll(" between them");
        }
        try w.writeAll("\n");
    }
    // Together these terms make up the elapsed time.
    try w.print("  {d} {s}: ", .{ l.path.len, if (l.path.len == 1) "rule" else "rules" });
    try units.duration(w, l.path_ran_s);
    try w.writeAll(" of work, ");
    try units.duration(w, l.path_waited_s);
    try w.writeAll(" waiting once ready, ");
    try units.duration(w, l.path_held_s);
    try w.writeAll(" held for producers off the path");
    if (l.path_between_s >= 0.05) {
        try w.writeAll(", ");
        try units.duration(w, l.path_between_s);
        try w.writeAll(" between attempts");
    }
    if (l.path_after_s >= 0.05) {
        try w.writeAll("; the launch ended ");
        try units.duration(w, l.path_after_s);
        try w.writeAll(" after the path did");
    }
    try w.writeAll("\n");
}

fn writeWaits(w: *std.Io.Writer, l: *const model.Launch) !void {
    try w.writeAll("\nwaiting for resources (ready rules that waited, on average over the launch, and their rule-seconds)\n");
    if (!l.waits_recorded) {
        try w.writeAll(if (l.rows.len == 0) "  none: no attempt ran\n" else "  not recorded: this launch's engine did not record wait reasons\n");
    } else {
        var any = false;
        for (l.waits.keys(), l.waits.values()) |k, s| if (s >= 0.05) {
            any = true;
            const avg = if (l.elapsed_s > 0) s / l.elapsed_s else 0;
            if (avg < 0.05) try w.print("  {s:<32}   <0.1 rules  ", .{cut(k, 32)}) else try w.print("  {s:<32} {d:>6.1} rules  ", .{ cut(k, 32), avg });
            try units.right(w, 9, units.duration, .{s});
            try w.writeAll("\n");
        };
        if (!any) try w.writeAll("  none\n");
        if (l.waits.get("starting")) |s| if (s >= 0.05) try w.writeAll("  starting: the budget had room; the engine was recording ended attempts and starting other rules\n");
    }
    if (l.groups.len == 0) return;
    try w.writeAll("\nresource groups (while their rules waited)\n");
    for (l.groups) |g| {
        try w.print("  {s:<30} ", .{cut(g.name, 30)});
        try units.right(w, 9, units.duration, .{g.seconds});
        try w.writeAll(" waited; ");
        const fit = g.fit orelse {
            try w.writeAll("no run samples while they waited\n");
            continue;
        };
        if (g.samples < 3) {
            try w.print("{d} run {s} while they waited, too few to judge\n", .{ g.samples, if (g.samples == 1) "sample" else "samples" });
        } else if (fit >= 0.25) {
            try w.print("in {d:.0}% of {d} samples a waiting rule fitted the free threads and memory: a higher max would have started it earlier\n", .{ fit * 100, g.samples });
        } else try w.print("the budget was full in {d:.0}% of {d} samples: a higher max would not help much\n", .{ (1 - fit) * 100, g.samples });
    }
}

fn writeSteps(w: *std.Io.Writer, l: *const model.Launch) !void {
    var reused: usize = 0;
    for (l.steps) |s| reused += s.reused;
    try w.writeAll("\nsteps (the latest completed run of every rule");
    if (reused > 0) try w.print("; {d} reused from earlier launches", .{reused});
    try w.writeAll(")\n");
    try w.writeAll("  STEP                            RUNS     MEDIAN  CPU USE  THREADS    REQUEST       USED       PEAK    SUGGEST  CHARACTER\n");
    for (l.steps) |s| {
        try w.print("  {s:<30} {d:>5} ", .{ cut(s.name, 30), s.runs });
        if (s.runs == 0) {
            try w.print("{s:>10} {s:>8} {d:>8.0} ", .{ "-", "-", s.threads });
            try units.right(w, 10, units.size, .{s.request_mib});
            try w.print(" {s:>10} {s:>10}", .{ "-", "-" });
        } else {
            try units.right(w, 10, units.duration, .{s.median_s});
            // Counters of very short runs can add up past the threads.
            if (s.judged()) try w.print(" {d:>7.0}% {d:>8.0} ", .{ @min(s.efficiency() * 100, 100), s.threads }) else try w.print(" {s:>8} {d:>8.0} ", .{ "-", s.threads });
            try units.right(w, 10, units.size, .{s.request_mib});
            try w.writeAll(" ");
            if (s.mostlyIdle()) try w.print("{s:>10} {s:>10}", .{ "-", "-" }) else {
                try units.right(w, 10, units.size, .{s.used_mib});
                try w.writeAll(" ");
                try units.right(w, 10, units.size, .{s.peak_mib});
            }
        }
        try w.writeAll(" ");
        if (s.sizing.note == .none or s.sizing.note == .idle) try w.print("{s:>10}", .{"-"}) else try units.right(w, 10, units.size, .{s.sizing.memory_mib});
        try w.writeAll("  ");
        switch (s.sizing.note) {
            .idle => try w.print("idle: used almost none of its request ({d} of {d} runs); no sizing", .{ s.idle, s.runs }),
            .none => try w.writeAll(if (s.failed_attempts > 0) "no completed run" else "not run"),
            .out_of_memory => try w.print("{d:.0} out-of-memory {s}: the suggestion is half again the request it exceeded", .{ s.oom_kills, if (s.oom_kills == 1) "kill" else "kills" }),
            .measured => {
                try w.writeAll(s.character());
                if (s.request_mib > 2 * s.sizing.memory_mib and s.request_mib - s.sizing.memory_mib >= 256) {
                    try w.writeAll("; requests ");
                    try units.size(w, s.request_mib - s.sizing.memory_mib);
                    try w.writeAll(" more than the suggestion");
                }
                if (s.limit_events > 0 and s.peak_mib >= s.request_mib * 0.99 and s.used_mib < s.request_mib) try w.writeAll("; reached its request through page cache (reclaimed, not killed)");
                if (s.threads > 1 and s.cores < s.threads * 0.5) try w.print("; uses about {d:.1} of {d:.0} threads", .{ s.cores, s.threads });
                if (s.sizing.at_thread_limit) {
                    if (s.threads <= 1) try w.writeAll("; kept its thread busy") else try w.print("; kept all {d:.0} of its threads busy", .{s.threads});
                    try w.writeAll(": it may use more if given them");
                }
            },
        }
        if (s.reused > 0) try w.print("; {d} reused", .{s.reused});
        try w.writeAll("\n");
    }
    try w.writeAll("  USED: the largest resident memory of one process, or the cgroup peak for rules with shared inputs or containers\n");
    try w.writeAll("  PEAK: the memory charged to the rule's cgroup, page cache included; libraries already in memory count in USED only\n");
}

/// CPU time per category and per tool, and per sample with its slowest
/// step; each section only when some rule has that label.
fn writeTime(a: Allocator, w: *std.Io.Writer, l: *const model.Launch) !void {
    const cpu = l.cpu();
    // Shares of a total under a second are noise.
    const shares = cpu.all >= 1;
    inline for (.{ .category, .tool }) |by| {
        const list = try l.totals(a, by);
        if (list.len > 0) {
            try w.print("\ntime per {s} (the latest run of every rule)\n", .{@tagName(by)});
            try w.print("  {s:<30} STEPS  RUNS       WALL        CPU  CPU SHARE\n", .{if (by == .category) "CATEGORY" else "TOOL"});
            for (list) |t| {
                try w.print("  {s:<30} {d:>5} {d:>5} ", .{ cut(t.name, 30), t.steps, t.runs });
                try units.right(w, 10, units.duration, .{t.wall_s});
                try w.writeAll(" ");
                try units.right(w, 10, units.duration, .{t.cpu_s});
                if (shares) try units.right(w, 11, units.percent, .{ t.cpu_s, cpu.all }) else try w.print("{s:>11}", .{"-"});
                try w.writeAll("\n");
            }
        }
    }
    const samples = try l.sampleRows(a);
    if (samples.len == 0) return;
    try w.writeAll("\nsamples (the latest run of every rule), most CPU time first\n");
    try w.writeAll("  SAMPLE                         STEPS  RUNS       WALL        CPU  SLOWEST STEP\n");
    for (samples) |row| {
        try w.print("  {s:<30} {d:>5} {d:>5} ", .{ cut(row.name, 30), row.steps, row.runs });
        try units.right(w, 10, units.duration, .{row.wall_s});
        try w.writeAll(" ");
        try units.right(w, 10, units.duration, .{row.cpu_s});
        if (row.slowest) |ri| {
            const r = l.rules[ri];
            try w.print("  {s} ", .{r.labels.step});
            try units.duration(w, r.run.?.wall_s);
            if (l.slow(r)) try w.print("; {d:.1}x the step's median", .{r.run.?.wall_s / l.steps[r.step].median_s});
        }
        try w.writeAll("\n");
    }
}

fn writeShared(w: *std.Io.Writer, l: *const model.Launch) !void {
    if (l.shared().len == 0) return;
    try w.writeAll("\nshared inputs\n");
    try w.writeAll("  NAME                           TYPE     STARTS       LOAD     MEMORY       PEAK    SUGGEST\n");
    for (l.shared()) |s| {
        const peak: f64 = if (s.memory_peak) |p| @as(f64, @floatFromInt(p)) / 1048576.0 else 0;
        try w.print("  {s:<30} {s:<8} {d:>6} ", .{ cut(s.name, 30), if (s.service) "service" else "mapped", s.starts });
        try units.right(w, 10, units.duration, .{s.load_s});
        try w.writeAll(" ");
        try units.right(w, 10, units.size, .{s.declared_mib});
        try w.writeAll(" ");
        if (peak > 0) try units.right(w, 10, units.size, .{peak}) else try w.print("{s:>10}", .{"-"});
        // A service holds mostly what it loaded: its peak plus a twentieth.
        if (s.service and peak > 0) {
            const suggest = @ceil(peak * 1.05 / 64.0) * 64.0;
            try w.writeAll(" ");
            try units.right(w, 10, units.size, .{suggest});
            if (s.declared_mib > suggest * 1.5 and s.declared_mib - suggest >= 256) {
                try w.writeAll("  declares ");
                try units.size(w, s.declared_mib - suggest);
                try w.writeAll(" more than the suggestion");
            }
            if (peak >= s.declared_mib * 0.95) try w.writeAll("  held almost all of its memory");
        } else try w.print(" {s:>10}", .{"-"});
        if (s.starts > 1) try w.print("  loaded {d} times", .{s.starts});
        if (s.failed) try w.writeAll("  failed");
        try w.writeAll("\n");
    }
}

fn writeUtilization(w: *std.Io.Writer, l: *const model.Launch) !void {
    try w.writeAll("\nuse of the budget (run samples every 5 s)\n");
    const samples = l.usage();
    if (samples.len == 0) return w.writeAll("  no samples: the run was shorter than one interval, or its engine did not record them\n");
    var threads: f64 = 0;
    var memory: f64 = 0;
    var cores: f64 = 0;
    var cores_n: f64 = 0;
    var in_use: f64 = 0;
    for (samples) |s| {
        threads += s.threads_reserved;
        memory += s.memory_reserved_mib;
        if (s.cpu_cores) |c| {
            cores += c;
            cores_n += 1;
        }
        if (s.memory_current) |m| in_use = @max(in_use, @as(f64, @floatFromInt(m)) / 1048576.0);
    }
    const n: f64 = @floatFromInt(samples.len);
    try w.print("  threads reserved {d:.1} of {d:.0} on average", .{ threads / n, l.max_threads });
    if (cores_n > 0) try w.print("; CPU cores in use {d:.1} on average", .{cores / cores_n});
    try w.writeAll("\n  memory reserved ");
    try units.size(w, memory / n);
    try w.writeAll(" of ");
    try units.size(w, l.max_memory_mib);
    try w.writeAll(" on average");
    if (in_use > 0) {
        try w.writeAll("; the run's memory in use, page cache included, peaked at ");
        try units.size(w, in_use);
    }
    try w.writeAll("\n");
}
