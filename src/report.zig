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
const clean = @import("clean.zig");
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

fn optStr(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string and x.string.len > 0) x.string else null;
}

/// An attempt's labels as its record holds them; records written before
/// labels existed get the labels derived from the rule name and image.
fn labelsOf(v: Value) workflow.Labels {
    const image: ?[]const u8 = if (get(v, "request")) |q| optStr(get(q, "container")) else null;
    var l = workflow.deriveLabels(str(v, "rule"), image);
    if (get(v, "labels")) |lv| if (lv == .object) {
        if (optStr(get(lv, "step"))) |s| l.step = s;
        l.category = optStr(get(lv, "category"));
        l.tool = optStr(get(lv, "tool"));
        l.sample = optStr(get(lv, "sample"));
    };
    return l;
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
        if (try readRecord(gpa, a, f)) |r| try out.append(a, r);
    }
    return out.items;
}

/// The attempt in record file `path`, or null when it cannot be read.
fn readRecord(gpa: Allocator, a: Allocator, path: []const u8) !?Attempt {
    const bytes = sys.readFile(gpa, path, 16 << 20) catch return null;
    defer gpa.free(bytes);
    const v = std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch return null;
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
    const labels = labelsOf(v);
    return .{
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
        .started_ns = monitor.parseTime(str(v, "started")) orelse 0,
        .step = labels.step,
        .category = labels.category,
        .tool = labels.tool,
        .sample = labels.sample,
        .dir = try a.dupe(u8, std.fs.path.dirname(path).?),
    };
}

/// For each rule a launch reused, the attempt that made the outputs it
/// reused: the rule's last completed attempt in an earlier launch of the same
/// working directory. Launch IDs begin with their start time, so earlier
/// launches sort first. A rule whose earlier launch was cleaned up is left
/// out.
pub fn reusedAttempts(gpa: Allocator, a: Allocator, launch_dir: []const u8) ![]Attempt {
    var wanted: std.StringArrayHashMapUnmanaged(void) = .empty;
    {
        const text = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "events.jsonl" }), 1 << 30) catch return &.{};
        defer gpa.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "\"task_reused\"") == null) continue;
            const v = std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }) catch continue;
            if (std.mem.eql(u8, str(v, "event"), "task_reused")) try wanted.put(a, str(v, "rule"), {});
        }
    }
    if (wanted.count() == 0) return &.{};

    const launches_dir = std.fs.path.dirname(launch_dir) orelse return &.{};
    const id = std.fs.path.basename(launch_dir);
    const names = try clean.launchNames(gpa, a, std.fs.path.dirname(launches_dir) orelse return &.{});

    var out: std.ArrayList(Attempt) = .empty;
    // Newest earlier launch first, so each rule takes its last completed attempt.
    var k = names.len;
    while (k > 0 and wanted.count() > 0) {
        k -= 1;
        const launch = names[k];
        if (!std.mem.lessThan(u8, launch, id)) continue;
        var i: usize = 0;
        while (i < wanted.count()) {
            const rule = wanted.keys()[i];
            // A rule has at most four attempts in a launch: one and three retries.
            const found = for ([_][]const u8{ "004", "003", "002", "001" }) |n| {
                const path = try std.fs.path.join(a, &.{ launches_dir, launch, "attempts", rule, n, "record.json" });
                const r = (try readRecord(gpa, a, path)) orelse continue;
                if (std.mem.eql(u8, r.status, "completed")) break r;
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

fn lessPath(_: void, x: []u8, y: []u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn opt(w: *std.Io.Writer, v: ?f64, comptime fmt: []const u8) !void {
    if (v) |x| try w.print(fmt, .{x}) else try w.writeAll("NA");
}

/// One row per attempt, tab-separated, with a header.
pub fn writeTsv(w: *std.Io.Writer, rows: []const Attempt) !void {
    try w.writeAll("rule\tattempt\tstatus\twall_s\tcpu_s\tcpu_efficiency\tthreads\tmemory_mib\tpeak_mib\tmax_rss_mib\tpeak_per_request\toom_kills\tlimit_events\twaited_s\twait_reason\tcpu_stall\tmemory_stall\tio_stall\tdelegated\treason\tstep\tsample\tcategory\ttool\n");
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
        try w.print("\t{}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ r.delegated(), if (r.reason.len > 0) r.reason else "-", r.step, r.sample orelse "-", r.category orelse "-", r.tool orelse "-" });
    }
}

pub fn writeJson(w: *std.Io.Writer, rows: []const Attempt) !void {
    try w.print("{f}\n", .{std.json.fmt(rows, .{ .whitespace = .indent_2 })});
}

pub const Suggestion = struct {
    step: []const u8,
    attempts: usize,
    delegated: bool,
    threads: f64,
    threads_used: f64,
    suggest_threads: f64,
    memory_mib: f64,
    peak_mib: f64,
    suggest_mib: f64,
};

/// Request suggestions per step from completed attempts: memory
/// from the largest peak plus a fifth in 64 MiB steps (the cgroup peak for
/// rules with shared inputs or a container, else the process RSS), threads
/// from the most cores an attempt used, rounded up and at most the request.
/// Steps whose work ran outside workz get none.
pub fn suggestions(a: Allocator, rows: []const Attempt) ![]Suggestion {
    var steps: std.StringArrayHashMapUnmanaged(Suggestion) = .empty;
    var basis_peak: std.StringHashMapUnmanaged(bool) = .empty;
    var deleg: std.StringHashMapUnmanaged(usize) = .empty;
    for (rows) |r| {
        if (!std.mem.eql(u8, r.status, "completed")) continue;
        const k = r.step;
        const gop = try steps.getOrPut(a, k);
        if (!gop.found_existing) gop.value_ptr.* = .{ .step = k, .attempts = 0, .delegated = false, .threads = 0, .threads_used = 0, .suggest_threads = 0, .memory_mib = 0, .peak_mib = 0, .suggest_mib = 0 };
        const s = gop.value_ptr;
        s.attempts += 1;
        s.threads = @max(s.threads, r.threads);
        s.memory_mib = @max(s.memory_mib, r.request_mib);
        if (r.wall_s > 0) s.threads_used = @max(s.threads_used, r.cpu_s / r.wall_s);
        const peak_based = r.uses_shared or r.in_container;
        if (peak_based) try basis_peak.put(a, k, true);
        s.peak_mib = @max(s.peak_mib, if (peak_based) r.peak_mib orelse r.rss_mib else r.rss_mib);
        const d = try deleg.getOrPut(a, k);
        if (!d.found_existing) d.value_ptr.* = 0;
        d.value_ptr.* += @intFromBool(r.delegated());
    }
    for (steps.values()) |*s| {
        s.delegated = (deleg.get(s.step) orelse 0) * 2 > s.attempts;
        if (s.delegated) continue;
        s.suggest_mib = @max(@ceil(s.peak_mib * 1.2 / 64.0) * 64.0, 64);
        s.suggest_threads = @min(@max(@ceil(s.threads_used - 0.05), 1), @max(s.threads, 1));
    }
    return steps.values();
}

pub fn writeSuggestions(w: *std.Io.Writer, list: []const Suggestion, json: bool) !void {
    if (json) {
        try w.print("{f}\n", .{std.json.fmt(list, .{})});
        return;
    }
    try w.writeAll("step\tattempts\tthreads\tthreads_used\tsuggest_threads\tmemory_mib\tpeak_mib\tsuggest_mib\tdelegated\n");
    for (list) |s| try w.print("{s}\t{d}\t{d:.0}\t{d:.2}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{}\n", .{ s.step, s.attempts, s.threads, s.threads_used, s.suggest_threads, s.memory_mib, s.peak_mib, s.suggest_mib, s.delegated });
}

const StepStats = struct { n: usize = 0, delegated: usize = 0, walls: std.ArrayList(f64) = .empty, peak: f64 = 0, cpu: f64 = 0 };

fn stepStats(a: Allocator, rows: []const Attempt) !std.StringArrayHashMapUnmanaged(StepStats) {
    var steps: std.StringArrayHashMapUnmanaged(StepStats) = .empty;
    for (rows) |r| {
        if (!std.mem.eql(u8, r.status, "completed")) continue;
        const gop = try steps.getOrPut(a, r.step);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const k = gop.value_ptr;
        k.n += 1;
        k.delegated += @intFromBool(r.delegated());
        try k.walls.append(a, r.wall_s);
        k.peak = @max(k.peak, r.peak_mib orelse r.rss_mib);
        k.cpu += r.cpu_s;
    }
    for (steps.values()) |*k| std.mem.sort(f64, k.walls.items, {}, std.sort.asc(f64));
    return steps;
}

/// The median of `xs`, which must be sorted ascending; 0 when empty.
pub fn median(xs: []const f64) f64 {
    if (xs.len == 0) return 0;
    const m = xs.len / 2;
    return if (xs.len % 2 == 1) xs[m] else (xs[m - 1] + xs[m]) / 2;
}

/// The change from `was` to `now` as printed with `decimals` places, so two
/// values that print alike show no change.
fn change(w: *std.Io.Writer, was: f64, now: f64, decimals: u8) !void {
    const scale = std.math.pow(f64, 10, @floatFromInt(decimals));
    const x = @round(was * scale) / scale;
    const y = @round(now * scale) / scale;
    if (x <= 0) return w.writeAll("       -");
    const pct = (y - x) / x * 100;
    try w.print(" {d:>6.0}%", .{if (@abs(pct) < 0.5) 0 else pct});
}

/// Compares launch `now_dir` with the baseline `was_dir`: session totals,
/// then per step the completed attempts, median wall time, largest
/// peak memory and total CPU time of each, with the change.
pub fn writeCompare(gpa: Allocator, a: Allocator, w: *std.Io.Writer, was_dir: []const u8, now_dir: []const u8) !void {
    const was_rows = try attempts(gpa, a, was_dir);
    const now_rows = try attempts(gpa, a, now_dir);
    const was_s = summaryElapsed(gpa, a, was_dir) orelse 0;
    const now_s = summaryElapsed(gpa, a, now_dir) orelse 0;
    var was_task: f64 = 0;
    var now_task: f64 = 0;
    for (was_rows) |r| was_task += r.wall_s * r.threads;
    for (now_rows) |r| now_task += r.wall_s * r.threads;
    try w.print("baseline {s}\nlaunch   {s}\n\n", .{ was_dir, now_dir });
    try w.writeAll("                          BASELINE     LAUNCH   CHANGE\n");
    try w.print("  elapsed s             {d:>10.1} {d:>10.1}", .{ was_s, now_s });
    try change(w, was_s, now_s, 1);
    try w.print("\n  attempts              {d:>10} {d:>10}\n  reserved thread-s     {d:>10.0} {d:>10.0}", .{ was_rows.len, now_rows.len, was_task, now_task });
    try change(w, was_task, now_task, 0);
    try w.writeAll("\n\nper step (completed attempts)\n");
    try w.writeAll("  STEP                             N   WALL S (MEDIAN)          PEAK MiB (MAX)           CPU S (TOTAL)\n");
    const was_k = try stepStats(a, was_rows);
    const now_k = try stepStats(a, now_rows);
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (was_k.keys()) |k| try names.put(a, k, {});
    for (now_k.keys()) |k| try names.put(a, k, {});
    for (names.keys()) |name| {
        const x = was_k.get(name) orelse StepStats{};
        const y = now_k.get(name) orelse StepStats{};
        // A step reused, or not selected, on one side has nothing to compare.
        if (x.n == 0 or y.n == 0) {
            const ran = if (x.n == 0) y else x;
            const nums = .{ median(ran.walls.items), ran.peak, ran.cpu };
            try w.print("  {s:<30} {d:>3}  ", .{ name[0..@min(name.len, 30)], y.n });
            if (x.n == 0) {
                try w.print("{s:>7} {d:>7.2}       -  {s:>7} {d:>7.0}       -  {s:>7} {d:>7.1}       -", .{ "-", nums[0], "-", nums[1], "-", nums[2] });
            } else try w.print("{d:>7.2} {s:>7}       -  {d:>7.0} {s:>7}       -  {d:>7.1} {s:>7}       -", .{ nums[0], "-", nums[1], "-", nums[2], "-" });
            try w.print("  no completed attempt in the {s}\n", .{if (x.n == 0) "baseline" else "launch"});
            continue;
        }
        try w.print("  {s:<30} {d:>3}  {d:>7.2} {d:>7.2}", .{ name[0..@min(name.len, 30)], y.n, median(x.walls.items), median(y.walls.items) });
        try change(w, median(x.walls.items), median(y.walls.items), 2);
        // Use measured outside workz's cgroups does not compare.
        const outside = x.delegated * 2 > x.n or y.delegated * 2 > y.n;
        try w.print("  {d:>7.0} {d:>7.0}", .{ x.peak, y.peak });
        if (outside) try w.writeAll("       -") else try change(w, x.peak, y.peak, 0);
        try w.print("  {d:>7.1} {d:>7.1}", .{ x.cpu, y.cpu });
        if (outside) try w.writeAll("       -") else try change(w, x.cpu, y.cpu, 1);
        if (outside) try w.print("  {s} ran its work outside workz", .{if (x.delegated * 2 > x.n) "baseline" else "launch"});
        try w.writeAll("\n");
    }
}

/// A label of rules that reports can group attempts by.
pub const By = enum { category, tool, sample };

/// Completed attempts summed over one value of a label.
pub const Total = struct { name: []const u8, attempts: usize = 0, wall_s: f64 = 0, cpu_s: f64 = 0, steps: usize = 0 };

/// Completed attempts summed per value of label `by`, most CPU time first;
/// attempts without that label are left out.
pub fn labelTotals(a: Allocator, rows: []const Attempt, by: By) ![]Total {
    var map: std.StringArrayHashMapUnmanaged(Total) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (rows) |r| {
        if (!std.mem.eql(u8, r.status, "completed")) continue;
        const name = switch (by) {
            .category => r.category,
            .tool => r.tool,
            .sample => r.sample,
        } orelse continue;
        const gop = try map.getOrPut(a, name);
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = name };
        const t = gop.value_ptr;
        t.attempts += 1;
        t.wall_s += r.wall_s;
        t.cpu_s += r.cpu_s;
        const pair = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ name, r.step });
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

/// The median wall time of each step's completed attempts.
pub fn stepMedians(a: Allocator, rows: []const Attempt) !std.StringHashMapUnmanaged(f64) {
    var walls: std.StringArrayHashMapUnmanaged(std.ArrayList(f64)) = .empty;
    for (rows) |r| {
        if (!std.mem.eql(u8, r.status, "completed")) continue;
        const gop = try walls.getOrPut(a, r.step);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, r.wall_s);
    }
    var out: std.StringHashMapUnmanaged(f64) = .empty;
    for (walls.keys(), walls.values()) |k, *v| {
        std.mem.sort(f64, v.items, {}, std.sort.asc(f64));
        try out.put(a, k, median(v.items));
    }
    return out;
}

/// An attempt slower than its step's median by half again and by at least
/// two seconds: worth a look, since the same work took longer on this data.
pub fn slowAgainstStep(r: Attempt, step_median: f64) bool {
    return step_median > 0 and r.wall_s >= step_median * 1.5 and r.wall_s - step_median >= 2;
}

/// Time per category and per tool, and per sample with its slowest step,
/// from the completed attempts; each section only when some rule has that
/// label.
fn writeLabelSections(a: Allocator, w: *std.Io.Writer, rows: []const Attempt) !void {
    var cpu_all: f64 = 0;
    for (rows) |r| if (std.mem.eql(u8, r.status, "completed")) {
        cpu_all += r.cpu_s;
    };
    for ([_]By{ .category, .tool }) |by| {
        const list = try labelTotals(a, rows, by);
        if (list.len == 0) continue;
        try w.print("\ntime per {s} (completed attempts)\n", .{@tagName(by)});
        try w.print("  {s:<30} STEPS  ATTEMPTS     WALL S      CPU S  CPU SHARE\n", .{if (by == .category) "CATEGORY" else "TOOL"});
        for (list) |t| try w.print("  {s:<30} {d:>5} {d:>9} {d:>10.1} {d:>10.1} {d:>9.1}%\n", .{ t.name[0..@min(t.name.len, 30)], t.steps, t.attempts, t.wall_s, t.cpu_s, if (cpu_all > 0) t.cpu_s / cpu_all * 100 else 0 });
    }
    const samples = try labelTotals(a, rows, .sample);
    if (samples.len == 0) return;
    const medians = try stepMedians(a, rows);
    try w.writeAll("\nsamples (completed attempts), most CPU time first\n");
    try w.writeAll("  SAMPLE                         STEPS  ATTEMPTS     WALL S      CPU S  SLOWEST STEP\n");
    for (samples) |t| {
        var slow: ?Attempt = null;
        for (rows) |r| {
            if (!std.mem.eql(u8, r.status, "completed")) continue;
            const s = r.sample orelse continue;
            if (!std.mem.eql(u8, s, t.name)) continue;
            if (slow == null or r.wall_s > slow.?.wall_s) slow = r;
        }
        try w.print("  {s:<30} {d:>5} {d:>9} {d:>10.1} {d:>10.1}", .{ t.name[0..@min(t.name.len, 30)], t.steps, t.attempts, t.wall_s, t.cpu_s });
        if (slow) |r| {
            const m = medians.get(r.step) orelse 0;
            try w.print("  {s} {d:.1} s", .{ r.step, r.wall_s });
            if (slowAgainstStep(r, m)) try w.print("; {d:.1}x the step's median", .{r.wall_s / m});
        }
        try w.writeAll("\n");
    }
}

const Timing = struct { start: ?i128 = null, finish: ?i128 = null, waited: f64 = 0, status: []const u8 = "" };

/// Prints what limited the launch: its critical path, waiting by reason,
/// request sizing per step, stall character and utilization.
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
    var shared: std.StringArrayHashMapUnmanaged(SharedUse) = .empty;
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
        } else if (std.mem.startsWith(u8, ev, "shared_")) {
            const gop = try shared.getOrPut(a, str(v, "name"));
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const s = gop.value_ptr;
            if (std.mem.eql(u8, ev, "shared_loading")) {
                s.starts += 1;
                s.loading_at = at;
                if (num(get(v, "memory_mib"))) |m| {
                    s.service = true;
                    s.declared_mib = m;
                } else if (num(get(v, "bytes"))) |b| s.declared_mib = b / 1048576.0;
            } else if (std.mem.eql(u8, ev, "shared_loaded")) {
                if (s.loading_at) |l| if (at) |now| {
                    s.load_s += @as(f64, @floatFromInt(now - l)) / 1e9;
                };
            } else if (std.mem.eql(u8, ev, "shared_released") or std.mem.eql(u8, ev, "shared_failed")) {
                s.peak_mib = @max(s.peak_mib, (num(get(v, "memory_peak")) orelse 0) / 1048576.0);
                if (std.mem.eql(u8, ev, "shared_failed")) s.failed = true;
            }
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
    // The summary's elapsed time starts with the engine, before the checks
    // that precede launch_started; events give it while a launch runs.
    const elapsed = summaryElapsed(gpa, a, launch_dir) orelse if (launch_end != null and launch_start != null) @as(f64, @floatFromInt(launch_end.? - t0)) / 1e9 else 0;
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
    try groupAdvice(a, w, text);

    // Sizing and character per step.
    const Step = struct { n: usize = 0, delegated: usize = 0, request: f64 = 0, peak: f64 = 0, rss: f64 = 0, oom: f64 = 0, limit: f64 = 0, shared: bool = false, container: bool = false, threads: f64 = 0, eff: f64 = 0, wall: f64 = 0, cpu_stall: f64 = 0, mem_stall: f64 = 0, io_stall: f64 = 0, stall_n: usize = 0, cpu_par: f64 = 0 };
    var steps: std.StringArrayHashMapUnmanaged(Step) = .empty;
    for (rows) |r| {
        if (!std.mem.eql(u8, r.status, "completed") and r.oom_kill == 0) continue;
        const gop = try steps.getOrPut(a, r.step);
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
    try w.writeAll("\nrequests per step (completed attempts)\n");
    try w.writeAll("  STEP                             N   WALL S   MEM REQ  MAX RSS   PEAK  SUGGEST  THREADS  CPU EFF  CHARACTER\n");
    for (steps.keys(), steps.values()) |name, k| {
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

    try writeLabelSections(a, w, rows);

    if (shared.count() > 0) {
        try w.writeAll("\nshared inputs\n");
        try w.writeAll("  NAME                           KIND     STARTS   LOAD S   MEMORY     PEAK  SUGGEST\n");
        for (shared.keys(), shared.values()) |name, s| {
            try w.print("  {s:<30} {s:<8} {d:>6} {d:>8.1} {d:>7.0}M {d:>7.0}M", .{ name[0..@min(name.len, 30)], if (s.service) "service" else "mapped", s.starts, s.load_s, s.declared_mib, s.peak_mib });
            // A service holds mostly what it loaded: its peak plus a twentieth.
            if (s.service and s.peak_mib > 0) {
                const suggest = @ceil(s.peak_mib * 1.05 / 64.0) * 64.0;
                try w.print(" {d:>7.0}M", .{suggest});
                if (s.declared_mib > suggest * 1.5 and s.declared_mib - suggest >= 256) try w.print("  declares {d:.0}M more than it held", .{s.declared_mib - suggest});
                if (s.peak_mib >= s.declared_mib * 0.95) try w.writeAll("  held almost all of its memory");
            } else try w.print(" {s:>8}", .{"-"});
            if (s.starts > 1) try w.print("  loaded {d} times", .{s.starts});
            if (s.failed) try w.writeAll("  failed");
            try w.writeAll("\n");
        }
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

fn summaryElapsed(gpa: Allocator, a: Allocator, launch_dir: []const u8) ?f64 {
    const path = std.fs.path.join(a, &.{ launch_dir, "summary.json" }) catch return null;
    const bytes = sys.readFile(gpa, path, 1 << 20) catch return null;
    defer gpa.free(bytes);
    const v = std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch return null;
    return num(get(v, "elapsed_s"));
}

/// For each resource group that held ready rules: whether the budget had
/// room for a waiting rule while it waited, from the run samples. If it
/// did, the group's limit, not the budget, held the work back.
fn groupAdvice(a: Allocator, w: *std.Io.Writer, text: []const u8) !void {
    const Sample = struct { t: i128, threads: f64, mem: f64 };
    const Wait = struct { rule: []const u8, group: []const u8, from: i128, to: i128 = 0 };
    var samples: std.ArrayList(Sample) = .empty;
    var waits: std.ArrayList(Wait) = .empty;
    var open: std.StringHashMapUnmanaged(usize) = .empty;
    var request: std.StringHashMapUnmanaged([2]f64) = .empty;
    var max_threads: f64 = 0;
    var max_memory: f64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }) catch continue;
        const ev = str(v, "event");
        const at = monitor.parseTime(str(v, "time")) orelse continue;
        if (std.mem.eql(u8, ev, "launch_started")) {
            max_threads = num(get(v, "max_threads")) orelse 0;
            max_memory = num(get(v, "max_memory_mib")) orelse 0;
        } else if (std.mem.eql(u8, ev, "sample")) {
            try samples.append(a, .{ .t = at, .threads = num(get(v, "threads_reserved")) orelse 0, .mem = num(get(v, "memory_reserved_mib")) orelse 0 });
        } else if (std.mem.eql(u8, ev, "task_waiting") or std.mem.eql(u8, ev, "task_started")) {
            const rule = str(v, "rule");
            // The rule's previous wait ends here.
            if (open.fetchRemove(rule)) |kv| waits.items[kv.value].to = at;
            if (std.mem.eql(u8, ev, "task_started")) {
                try request.put(a, rule, .{ num(get(v, "threads")) orelse 1, num(get(v, "memory_mib")) orelse 0 });
            } else if (std.mem.startsWith(u8, str(v, "reason"), "group:")) {
                try open.put(a, rule, waits.items.len);
                try waits.append(a, .{ .rule = rule, .group = str(v, "reason")[6..], .from = at });
            }
        }
    }
    if (samples.items.len == 0 or waits.items.len == 0) return;
    var groups: std.StringArrayHashMapUnmanaged(struct { seconds: f64 = 0, moments: usize = 0, fit: usize = 0 }) = .empty;
    for (waits.items) |wt| {
        if (wt.to == 0) continue;
        const gop = try groups.getOrPut(a, wt.group);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.seconds += @as(f64, @floatFromInt(wt.to - wt.from)) / 1e9;
        const req = request.get(wt.rule) orelse continue;
        for (samples.items) |s| {
            if (s.t < wt.from or s.t >= wt.to) continue;
            gop.value_ptr.moments += 1;
            if (max_threads - s.threads >= req[0] and max_memory - s.mem >= req[1]) gop.value_ptr.fit += 1;
        }
    }
    var first = true;
    for (groups.keys(), groups.values()) |name, g| {
        if (g.moments == 0) continue;
        if (first) try w.writeAll("\nresource groups (while their rules waited)\n");
        first = false;
        const share = @as(f64, @floatFromInt(g.fit)) / @as(f64, @floatFromInt(g.moments)) * 100;
        try w.print("  {s:<30} {d:>9.1} s waited; ", .{ name[0..@min(name.len, 30)], g.seconds });
        if (share >= 25) {
            try w.print("in {d:.0}% of the samples a waiting rule fitted the free threads and memory: a higher max would have started it earlier\n", .{share});
        } else try w.print("the budget was full in {d:.0}% of the samples: a higher max would not help much\n", .{100 - share});
    }
}

const SharedUse = struct {
    service: bool = false,
    starts: usize = 0,
    loading_at: ?i128 = null,
    load_s: f64 = 0,
    declared_mib: f64 = 0,
    peak_mib: f64 = 0,
    failed: bool = false,
};

fn character(stall_n: usize, cpu: f64, mem: f64, io: f64, eff: f64) []const u8 {
    if (stall_n == 0) return if (eff >= 0.7) "CPU-bound" else "-";
    if (mem >= 0.2) return "memory-throttled";
    if (io >= 0.3) return "I/O-bound";
    if (cpu >= 0.3) return "CPU-starved";
    if (eff >= 0.7) return "CPU-bound";
    if (eff < 0.3) return "mostly waiting";
    return "mixed";
}

/// Sorts totals by value, largest first.
pub fn sortByValue(map: *std.StringArrayHashMapUnmanaged(f64)) void {
    const Ctx = struct {
        values: []const f64,
        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
            return c.values[x] > c.values[y];
        }
    };
    map.sort(Ctx{ .values = map.values() });
}

/// Total seconds of waiting per reason, from every attempt record;
/// `recorded` is set when any attempt recorded its queue.
pub fn waitTotals(gpa: Allocator, a: Allocator, launch_dir: []const u8, recorded: *bool) !std.StringArrayHashMapUnmanaged(f64) {
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

/// The pipeline position of each step in the launch's workflow: steps whose
/// rules sit fewer producers deep come first, then by the first rule of the
/// step in the file. Empty when the workflow snapshot cannot be read.
pub fn stepOrder(gpa: Allocator, a: Allocator, launch_dir: []const u8) !std.StringHashMapUnmanaged(u64) {
    var rank: std.StringHashMapUnmanaged(u64) = .empty;
    const launch_json = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }), 1 << 20) catch return rank;
    defer gpa.free(launch_json);
    const lv = std.json.parseFromSliceLeaky(Value, a, launch_json, .{ .allocate = .alloc_always }) catch return rank;
    var problem: workflow.Problem = .{};
    var wf = workflow.load(gpa, try std.fs.path.join(a, &.{ launch_dir, "workflow" }), str(lv, "workdir"), &problem) catch {
        if (problem.message.len > 0) gpa.free(problem.message);
        return rank;
    };
    defer wf.deinit();
    var g = graph.build(gpa, &wf, &problem) catch return rank;
    defer g.deinit();
    const depth = try a.alloc(u64, wf.rules.len);
    for (g.order) |i| {
        depth[i] = 0;
        for (g.parents[i]) |pi| depth[i] = @max(depth[i], depth[pi] + 1);
    }
    for (wf.rules, 0..) |r, i| {
        const key = depth[i] << 32 | @as(u64, @intCast(i));
        const gop = try rank.getOrPut(a, try a.dupe(u8, r.labels.step));
        if (!gop.found_existing or key < gop.value_ptr.*) gop.value_ptr.* = key;
    }
    return rank;
}

/// Names of the rules on the critical path: from the attempt that finished
/// last back through the producer that finished last before it.
pub fn criticalPathNames(gpa: Allocator, a: Allocator, launch_dir: []const u8, rows: []const Attempt) ![]const []const u8 {
    var finish: std.StringHashMapUnmanaged(i128) = .empty;
    for (rows) |r| if (r.started_ns > 0) {
        const f = r.started_ns + @as(i128, @intFromFloat(r.wall_s * 1e9));
        const gop = try finish.getOrPut(a, r.rule);
        if (!gop.found_existing or f > gop.value_ptr.*) gop.value_ptr.* = f;
    };
    const launch_json = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }), 1 << 20) catch return &.{};
    defer gpa.free(launch_json);
    const lv = std.json.parseFromSliceLeaky(Value, a, launch_json, .{ .allocate = .alloc_always }) catch return &.{};
    var problem: workflow.Problem = .{};
    var wf = workflow.load(gpa, try std.fs.path.join(a, &.{ launch_dir, "workflow" }), str(lv, "workdir"), &problem) catch {
        if (problem.message.len > 0) gpa.free(problem.message);
        return &.{};
    };
    defer wf.deinit();
    var g = graph.build(gpa, &wf, &problem) catch return &.{};
    defer g.deinit();
    var cur: ?usize = null;
    var best: i128 = 0;
    for (wf.rules, 0..) |r, i| if (finish.get(r.name)) |f| if (cur == null or f > best) {
        cur = i;
        best = f;
    };
    var names: std.ArrayList([]const u8) = .empty;
    while (cur) |i| {
        try names.append(a, try a.dupe(u8, wf.rules[i].name));
        var next: ?usize = null;
        var next_f: i128 = 0;
        for (g.parents[i]) |pi| if (finish.get(wf.rules[pi].name)) |f| if (next == null or f > next_f) {
            next = pi;
            next_f = f;
        };
        cur = next;
    }
    return names.items;
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
    try w.print("  {d} {s}: {d:.1} s running, {d:.1} s waiting for resources\n", .{ path.items.len, if (path.items.len == 1) "rule" else "rules", run_s, wait_s });
}
