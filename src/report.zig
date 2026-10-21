//! `report`: what a launch's attempts used, and what limited the run.
//!
//! Everything is read from the launch directory: the attempt records, the
//! event stream, the run samples and the workflow snapshot. Nothing is
//! measured again.
const std = @import("std");
const sys = @import("sys.zig");
const state = @import("state.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const monitor = @import("monitor.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Attempt = struct {
    rule: []const u8,
    attempt: i64,
    status: []const u8,
    reason: []const u8,
    wall_s: f64,
    cpu_s: f64,
    threads: f64,
    request_mib: f64,
    /// cgroup peak (includes page cache) and process peak RSS.
    peak_mib: ?f64,
    rss_mib: f64,
    oom_kill: f64,
    limit_events: f64,
    waited_s: f64,
    wait_reason: []const u8,
    /// Share of wall time some task of the attempt stalled on each resource.
    cpu_stall: ?f64,
    memory_stall: ?f64,
    io_stall: ?f64,
    /// The attempt mapped shared inputs, which count in its RSS but are
    /// charged to their holders.
    uses_shared: bool,
    /// Ran in a container: its process is the Podman client.
    in_container: bool = false,

    pub fn cpuEfficiency(self: Attempt) f64 {
        if (self.wall_s <= 0 or self.threads <= 0) return 0;
        return self.cpu_s / (self.wall_s * self.threads);
    }

    /// The attempt ran for at least half a second but its own cgroup did almost nothing:
    /// under a tenth of its CPU request and a twentieth of its memory request. The command
    /// most likely handed the work to another supervisor (systemd, a
    /// container runtime), whose use workz does not see.
    pub fn delegated(self: Attempt) bool {
        if (self.wall_s < 0.5 or !std.mem.eql(u8, self.status, "completed")) return false;
        const memory = @max(self.peak_mib orelse 0, self.rss_mib);
        return self.cpuEfficiency() < 0.1 and memory < @max(self.request_mib * 0.05, 64);
    }
};

fn num(v: ?Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn str(v: Value, key: []const u8) []const u8 {
    const x = get(v, key) orelse return "";
    return if (x == .string) x.string else "";
}

fn stall(cg: ?Value, key: []const u8, wall: f64) ?f64 {
    const c = cg orelse return null;
    const us = num(get(c, key)) orelse return null;
    if (wall <= 0) return null;
    return @min(us / 1e6 / wall, 1.0);
}

/// Reads every attempt record of a launch, in rule and attempt order.
pub fn attempts(gpa: Allocator, a: Allocator, launch_dir: []const u8) ![]Attempt {
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    const dir = try std.fs.path.join(a, &.{ launch_dir, "attempts" });
    state.listFiles(gpa, dir, &files) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    std.mem.sort([]u8, files.items, {}, lessPath);
    var out: std.ArrayList(Attempt) = .empty;
    for (files.items) |f| {
        // attempts/<rule>/<NNN>/record.json; files under previous/ are outputs.
        if (!std.mem.endsWith(u8, f, "/record.json") or std.mem.indexOf(u8, f, "/previous/") != null) continue;
        const bytes = sys.readFile(gpa, f, 16 << 20) catch continue;
        defer gpa.free(bytes);
        const v = std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch continue;
        const wall = num(get(v, "wall_s")) orelse 0;
        const req = get(v, "request");
        const cg: ?Value = if (get(v, "cgroup")) |c| (if (c == .object) c else null) else null;
        const queue = get(v, "queue");
        var top_reason: []const u8 = "";
        var top_s: f64 = 0;
        if (queue) |q| if (get(q, "reasons")) |rs| if (rs == .array) for (rs.array.items) |w| {
            const s = num(get(w, "seconds")) orelse 0;
            if (s > top_s) {
                top_s = s;
                top_reason = str(w, "reason");
            }
        };
        try out.append(a, .{
            .rule = str(v, "rule"),
            .attempt = @intFromFloat(num(get(v, "attempt")) orelse 0),
            .status = str(v, "status"),
            .reason = str(v, "reason"),
            .wall_s = wall,
            .cpu_s = num(get(v, "cpu_s")) orelse if (get(v, "rusage")) |ru| num(get(ru, "cpu_s")) orelse 0 else 0,
            .threads = if (req) |q| num(get(q, "threads")) orelse 1 else 1,
            .request_mib = if (req) |q| num(get(q, "memory_mib")) orelse 0 else 0,
            .peak_mib = if (cg) |c| if (num(get(c, "memory_peak"))) |p| p / 1048576.0 else null else null,
            .rss_mib = if (get(v, "rusage")) |ru| (num(get(ru, "maxrss_kib")) orelse 0) / 1024.0 else 0,
            .oom_kill = if (cg) |c| num(get(c, "oom_kill")) orelse 0 else 0,
            .limit_events = if (cg) |c| num(get(c, "memory_max_events")) orelse 0 else 0,
            .waited_s = if (queue) |q| num(get(q, "waited_s")) orelse 0 else 0,
            .wait_reason = top_reason,
            .cpu_stall = stall(cg, "cpu_some_us", wall),
            .memory_stall = stall(cg, "memory_some_us", wall),
            .io_stall = stall(cg, "io_some_us", wall),
            .uses_shared = if (req) |q| if (get(q, "shared")) |sh| sh == .array and sh.array.items.len > 0 else false else false,
            .in_container = if (req) |q| if (get(q, "container")) |c| c == .string else false else false,
        });
    }
    return out.items;
}

fn lessPath(_: void, x: []u8, y: []u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn opt(w: *std.Io.Writer, v: ?f64, comptime fmt: []const u8) !void {
    if (v) |x| try w.print(fmt, .{x}) else try w.writeAll("NA");
}

/// One row per attempt, tab-separated, with a header.
pub fn writeTsv(w: *std.Io.Writer, rows: []const Attempt) !void {
    try w.writeAll("rule\tattempt\tstatus\twall_s\tcpu_s\tcpu_efficiency\tthreads\tmemory_mib\tpeak_mib\tmax_rss_mib\tpeak_per_request\toom_kills\tlimit_events\twaited_s\twait_reason\tcpu_stall\tmemory_stall\tio_stall\tdelegated\treason\n");
    for (rows) |r| {
        try w.print("{s}\t{d}\t{s}\t{d:.3}\t{d:.3}\t{d:.2}\t{d:.0}\t{d:.0}\t", .{ r.rule, r.attempt, r.status, r.wall_s, r.cpu_s, r.cpuEfficiency(), r.threads, r.request_mib });
        try opt(w, r.peak_mib, "{d:.1}");
        try w.print("\t{d:.1}\t", .{r.rss_mib});
        try opt(w, if (r.peak_mib) |p| if (r.request_mib > 0) p / r.request_mib else null else null, "{d:.2}");
        try w.print("\t{d:.0}\t{d:.0}\t{d:.3}\t{s}\t", .{ r.oom_kill, r.limit_events, r.waited_s, if (r.wait_reason.len > 0) r.wait_reason else "-" });
        try opt(w, r.cpu_stall, "{d:.3}");
        try w.writeAll("\t");
        try opt(w, r.memory_stall, "{d:.3}");
        try w.writeAll("\t");
        try opt(w, r.io_stall, "{d:.3}");
        try w.print("\t{}\t{s}\n", .{ r.delegated(), if (r.reason.len > 0) r.reason else "-" });
    }
}

pub fn writeJson(w: *std.Io.Writer, rows: []const Attempt) !void {
    try w.print("{f}\n", .{std.json.fmt(rows, .{ .whitespace = .indent_2 })});
}

/// The kind of rule an attempt belongs to, so samples of one step can be
/// compared: the part after the last "__" ("s1__STAR_ALIGN" is
/// "STAR_ALIGN"), otherwise the part before the last "_" ("classify_03JW"
/// is "classify"), otherwise the whole name.
pub fn pattern(name: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, name, "__")) |i| return name[i + 2 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '_')) |i| if (i > 0) return name[0..i];
    return name;
}

const Timing = struct { start: ?i128 = null, finish: ?i128 = null, waited: f64 = 0, status: []const u8 = "" };

/// Prints what limited the launch: its critical path, waiting by reason,
/// request sizing per kind of rule, stall character and utilization.
pub fn writeBottlenecks(gpa: Allocator, a: Allocator, w: *std.Io.Writer, launch_dir: []const u8) !void {
    const rows = try attempts(gpa, a, launch_dir);
    const events_path = try std.fs.path.join(a, &.{ launch_dir, "events.jsonl" });
    const text = sys.readFile(gpa, events_path, 1 << 30) catch "";
    defer if (text.len > 0) gpa.free(text);

    var timing: std.StringHashMapUnmanaged(Timing) = .empty;
    var launch_start: ?i128 = null;
    var launch_end: ?i128 = null;
    var max_threads: f64 = 0;
    var max_memory: f64 = 0;
    var samples: usize = 0;
    var cpu_used_sum: f64 = 0;
    var cpu_used_n: usize = 0;
    var threads_reserved_sum: f64 = 0;
    var memory_reserved_sum: f64 = 0;
    var memory_current_max: f64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }) catch continue;
        const ev = str(v, "event");
        const at = monitor.parseTime(str(v, "time"));
        if (std.mem.eql(u8, ev, "launch_started")) {
            launch_start = at;
            max_threads = num(get(v, "max_threads")) orelse 0;
            max_memory = num(get(v, "max_memory_mib")) orelse 0;
        } else if (std.mem.eql(u8, ev, "launch_finished")) {
            launch_end = at;
        } else if (std.mem.eql(u8, ev, "sample")) {
            samples += 1;
            if (num(get(v, "cpu_cores_used"))) |c| {
                cpu_used_sum += c;
                cpu_used_n += 1;
            }
            threads_reserved_sum += num(get(v, "threads_reserved")) orelse 0;
            memory_reserved_sum += num(get(v, "memory_reserved_mib")) orelse 0;
            memory_current_max = @max(memory_current_max, (num(get(v, "memory_current")) orelse 0) / 1048576.0);
        } else if (std.mem.eql(u8, ev, "task_started") or std.mem.eql(u8, ev, "task_finished") or std.mem.eql(u8, ev, "task_reused")) {
            const gop = try timing.getOrPut(a, str(v, "rule"));
            if (!gop.found_existing) gop.value_ptr.* = .{};
            if (std.mem.eql(u8, ev, "task_started")) {
                gop.value_ptr.start = at;
                gop.value_ptr.waited = num(get(v, "waited_s")) orelse 0;
            } else if (std.mem.eql(u8, ev, "task_reused")) {
                gop.value_ptr.status = "reused";
            } else {
                gop.value_ptr.finish = at;
                gop.value_ptr.status = str(v, "status");
            }
        }
    }
    const t0 = launch_start orelse 0;
    const elapsed = if (launch_end != null and launch_start != null) @as(f64, @floatFromInt(launch_end.? - t0)) / 1e9 else 0;
    var ran: usize = 0;
    var task_s: f64 = 0;
    var delegated: usize = 0;
    for (rows) |r| {
        ran += 1;
        task_s += r.wall_s;
        delegated += @intFromBool(r.delegated());
    }
    try w.print("launch {s}: {d:.1} s elapsed, {d} attempts, {d:.1} task-seconds\n", .{ std.fs.path.basename(launch_dir), elapsed, ran, task_s });
    if (delegated > 0) try w.print("note: {d} attempts used almost none of their requests while they ran; their commands most likely handed the work to another supervisor, so workz's counters, sizing and character below do not describe it\n", .{delegated});

    try criticalPath(gpa, a, w, launch_dir, &timing, t0);

    var recorded = false;
    var by_reason = try waitTotals(gpa, a, launch_dir, &recorded);
    try w.writeAll("\nwaiting for resources (ready but not started)\n");
    if (!recorded) {
        try w.writeAll("  not recorded: this launch's engine did not record wait reasons\n");
    } else if (by_reason.count() == 0) try w.writeAll("  none\n");
    sortByValue(&by_reason);
    for (by_reason.keys(), by_reason.values()) |k, s| try w.print("  {s:<32} {d:>9.1} s\n", .{ k, s });

    // Sizing and character per kind of rule.
    const Kind = struct { n: usize = 0, delegated: usize = 0, request: f64 = 0, peak: f64 = 0, rss: f64 = 0, oom: f64 = 0, limit: f64 = 0, shared: bool = false, container: bool = false, threads: f64 = 0, eff: f64 = 0, wall: f64 = 0, cpu_stall: f64 = 0, mem_stall: f64 = 0, io_stall: f64 = 0, stall_n: usize = 0, cpu_par: f64 = 0 };
    var kinds: std.StringArrayHashMapUnmanaged(Kind) = .empty;
    for (rows) |r| {
        if (!std.mem.eql(u8, r.status, "completed") and r.oom_kill == 0) continue;
        const gop = try kinds.getOrPut(a, pattern(r.rule));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const k = gop.value_ptr;
        k.n += 1;
        k.delegated += @intFromBool(r.delegated());
        k.request = @max(k.request, r.request_mib);
        k.peak = @max(k.peak, r.peak_mib orelse 0);
        k.rss = @max(k.rss, r.rss_mib);
        k.oom += r.oom_kill;
        k.limit += r.limit_events;
        k.shared = k.shared or r.uses_shared;
        k.container = k.container or r.in_container;
        k.threads = @max(k.threads, r.threads);
        k.eff += r.cpuEfficiency();
        k.wall += r.wall_s;
        if (r.wall_s > 0) k.cpu_par = @max(k.cpu_par, r.cpu_s / r.wall_s);
        if (r.cpu_stall != null) {
            k.cpu_stall += r.cpu_stall.?;
            k.mem_stall += r.memory_stall orelse 0;
            k.io_stall += r.io_stall orelse 0;
            k.stall_n += 1;
        }
    }
    try w.writeAll("\nrequests per kind of rule (completed attempts)\n");
    try w.writeAll("  KIND                             N   WALL S   MEM REQ  MAX RSS   PEAK  SUGGEST  THREADS  CPU EFF  CHARACTER\n");
    for (kinds.keys(), kinds.values()) |name, k| {
        const n: f64 = @floatFromInt(k.n);
        // Suggested request: the largest peak plus a fifth, in 64 MiB steps. The
        // process RSS counts mapped shared inputs, which their holders carry,
        // and in a container it is the Podman client's, so rules with shared
        // inputs or a container are sized by their cgroup peak.
        const basis = if ((k.shared or k.container) and k.peak > 0) k.peak else k.rss;
        const suggest = @ceil(basis * 1.2 / 64.0) * 64.0;
        const eff = k.eff / n;
        if (k.delegated * 2 > k.n) {
            try w.print("  {s:<30} {d:>3} {d:>8.1} {d:>8.0}M {s:>8} {s:>7} {s:>8} {d:>8.0} {s:>8}  work ran outside workz ({d} of {d} attempts); no sizing\n", .{ name[0..@min(name.len, 30)], k.n, k.wall, k.request, "-", "-", "-", k.threads, "-", k.delegated, k.n });
            continue;
        }
        try w.print("  {s:<30} {d:>3} {d:>8.1} {d:>8.0}M {d:>7.0}M {d:>6.0}M {d:>7.0}M {d:>8.0} {d:>8.2}  {s}", .{ name[0..@min(name.len, 30)], k.n, k.wall, k.request, k.rss, k.peak, @max(suggest, 64), k.threads, eff, character(k.stall_n, k.cpu_stall / @max(n, 1), k.mem_stall / @max(n, 1), k.io_stall / @max(n, 1), eff) });
        if (k.oom > 0) {
            try w.print("; {d:.0} out-of-memory kills: raise the request", .{k.oom});
        } else if (k.request > 2 * @max(suggest, 64) and k.request - suggest >= 256) {
            try w.print("; requests {d:.0}M more than its peak needs", .{k.request - suggest});
        }
        if (k.oom == 0 and k.limit > 0 and k.peak >= k.request * 0.99 and k.rss < k.request) try w.writeAll("; reached its request through page cache (reclaimed, not killed)");
        if (k.threads > 1 and k.cpu_par < k.threads * 0.5) try w.print("; uses about {d:.1} of {d:.0} threads", .{ k.cpu_par, k.threads });
        try w.writeAll("\n");
    }

    try w.writeAll("\nutilization (run samples every 5 s)\n");
    if (samples == 0) {
        try w.writeAll("  no samples: the run was shorter than one interval, or its engine did not record them\n");
    } else {
        const ns: f64 = @floatFromInt(samples);
        try w.print("  threads reserved {d:.1} of {d:.0} on average", .{ threads_reserved_sum / ns, max_threads });
        if (cpu_used_n > 0) try w.print("; CPU in use {d:.1} cores", .{cpu_used_sum / @as(f64, @floatFromInt(cpu_used_n))});
        try w.print("\n  memory reserved {d:.0} of {d:.0} MiB on average", .{ memory_reserved_sum / ns, max_memory });
        if (memory_current_max > 0) try w.print("; run cgroup peaked at {d:.0} MiB", .{memory_current_max});
        try w.writeAll("\n");
    }
}

fn character(stall_n: usize, cpu: f64, mem: f64, io: f64, eff: f64) []const u8 {
    if (stall_n == 0) return if (eff >= 0.7) "CPU-bound" else "-";
    if (mem >= 0.2) return "memory-throttled";
    if (io >= 0.3) return "I/O-bound";
    if (cpu >= 0.3) return "CPU-starved";
    if (eff >= 0.7) return "CPU-bound";
    if (eff < 0.3) return "mostly waiting";
    return "mixed";
}

fn sortByValue(map: *std.StringArrayHashMapUnmanaged(f64)) void {
    const Ctx = struct {
        values: []const f64,
        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
            return c.values[x] > c.values[y];
        }
    };
    map.sort(Ctx{ .values = map.values() });
}

/// Total seconds of waiting per reason, from every attempt record.
fn waitTotals(gpa: Allocator, a: Allocator, launch_dir: []const u8, recorded: *bool) !std.StringArrayHashMapUnmanaged(f64) {
    var totals: std.StringArrayHashMapUnmanaged(f64) = .empty;
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    state.listFiles(gpa, try std.fs.path.join(a, &.{ launch_dir, "attempts" }), &files) catch return totals;
    for (files.items) |f| {
        if (!std.mem.endsWith(u8, f, "/record.json") or std.mem.indexOf(u8, f, "/previous/") != null) continue;
        const bytes = sys.readFile(gpa, f, 16 << 20) catch continue;
        defer gpa.free(bytes);
        const v = std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch continue;
        const q = get(v, "queue") orelse continue;
        recorded.* = true;
        const rs = get(q, "reasons") orelse continue;
        if (rs != .array) continue;
        for (rs.array.items) |item| {
            const gop = try totals.getOrPut(a, try a.dupe(u8, str(item, "reason")));
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += num(get(item, "seconds")) orelse 0;
        }
    }
    return totals;
}

/// Follows the run back from the last task to finish: each step's producer
/// is the parent that finished last, the one it was waiting for.
fn criticalPath(gpa: Allocator, a: Allocator, w: *std.Io.Writer, launch_dir: []const u8, timing: *std.StringHashMapUnmanaged(Timing), t0: i128) !void {
    const launch_json = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }), 1 << 20) catch return;
    defer gpa.free(launch_json);
    const lv = std.json.parseFromSliceLeaky(Value, a, launch_json, .{ .allocate = .alloc_always }) catch return;
    const root = str(lv, "workdir");
    var problem: workflow.Problem = .{};
    var wf = workflow.load(gpa, try std.fs.path.join(a, &.{ launch_dir, "workflow" }), root, &problem) catch {
        if (problem.message.len > 0) gpa.free(problem.message);
        try w.writeAll("\ncritical path: the workflow snapshot cannot be read\n");
        return;
    };
    defer wf.deinit();
    var g = graph.build(gpa, &wf, &problem) catch return;
    defer g.deinit();

    var last: ?usize = null;
    var last_finish: i128 = 0;
    for (wf.rules, 0..) |r, i| {
        const t = timing.get(r.name) orelse continue;
        const f = t.finish orelse continue;
        if (last == null or f > last_finish) {
            last = i;
            last_finish = f;
        }
    }
    try w.writeAll("\ncritical path (last task back to the start)\n");
    var cur = last orelse {
        try w.writeAll("  no task ran\n");
        return;
    };
    var path: std.ArrayList(usize) = .empty;
    while (true) {
        try path.append(a, cur);
        var next: ?usize = null;
        var next_finish: i128 = 0;
        for (g.parents[cur]) |p| {
            const t = timing.get(wf.rules[p].name) orelse continue;
            const f = t.finish orelse continue;
            if (next == null or f > next_finish) {
                next = p;
                next_finish = f;
            }
        }
        cur = next orelse break;
    }
    var run_s: f64 = 0;
    var wait_s: f64 = 0;
    var i = path.items.len;
    while (i > 0) {
        i -= 1;
        const ri = path.items[i];
        const r = &wf.rules[ri];
        const t = timing.get(r.name).?;
        const run = if (t.start != null and t.finish != null) @as(f64, @floatFromInt(t.finish.? - t.start.?)) / 1e9 else 0;
        const at = if (t.start) |s| @as(f64, @floatFromInt(s - t0)) / 1e9 else 0;
        // Ready when the last producer finished, or at the launch start; the
        // time from ready to start is waiting, whether or not records say why.
        var ready = t0;
        for (g.parents[ri]) |p| if (timing.get(wf.rules[p].name)) |pt| if (pt.finish) |f| {
            ready = @max(ready, f);
        };
        const waited = if (t.start) |s| @max(@as(f64, @floatFromInt(s - ready)) / 1e9, 0) else 0;
        run_s += run;
        wait_s += waited;
        try w.print("  at {d:>8.1} s  {s:<44} ran {d:>8.1} s, waited {d:>6.1} s\n", .{ at, r.name[0..@min(r.name.len, 44)], run, waited });
    }
    try w.print("  {d} steps: {d:.1} s running, {d:.1} s waiting for resources\n", .{ path.items.len, run_s, wait_s });
}
