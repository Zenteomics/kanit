//! `report`: what a launch's attempts used.
//!
//! Everything is read from the launch directory: the attempt records, the
//! event stream, the run samples and the workflow snapshot. Nothing is
//! measured again.
const std = @import("std");
const sys = @import("sys.zig");
const state = @import("state.zig");
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

    pub fn cpuEfficiency(self: Attempt) f64 {
        if (self.wall_s <= 0 or self.threads <= 0) return 0;
        return self.cpu_s / (self.wall_s * self.threads);
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
            .cpu_s = if (get(v, "rusage")) |ru| num(get(ru, "cpu_s")) orelse 0 else 0,
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
    try w.writeAll("rule\tattempt\tstatus\twall_s\tcpu_s\tcpu_efficiency\tthreads\tmemory_mib\tpeak_mib\tmax_rss_mib\tpeak_per_request\toom_kills\tlimit_events\twaited_s\twait_reason\tcpu_stall\tmemory_stall\tio_stall\treason\n");
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
        try w.print("\t{s}\n", .{if (r.reason.len > 0) r.reason else "-"});
    }
}

pub fn writeJson(w: *std.Io.Writer, rows: []const Attempt) !void {
    try w.print("{f}\n", .{std.json.fmt(rows, .{ .whitespace = .indent_2 })});
}
