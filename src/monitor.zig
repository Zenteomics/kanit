//! `watch` and `status`: read-only views of a launch, built from its event
//! stream, its attempt files and the running tasks' cgroup counters.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const cgroup = @import("cgroup.zig");
const Allocator = std.mem.Allocator;

const RuleView = struct {
    status: []const u8,
    attempt: i64 = 0,
    dir: []const u8 = "",
    cg: ?[]const u8 = null,
    started_ns: i128 = 0,
    reason: []const u8 = "",
    finished_ns: i128 = 0,
};

pub const View = struct {
    arena: std.heap.ArenaAllocator,
    launch: []const u8 = "",
    selected: i64 = 0,
    started_ns: i128 = 0,
    finished: bool = false,
    final_status: []const u8 = "",
    rules: std.StringArrayHashMapUnmanaged(RuleView) = .empty,
    shared: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *View) void {
        self.arena.deinit();
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
    return if (x == .integer) x.integer else null;
}

pub fn load(gpa: Allocator, launch_dir: []const u8) !View {
    var view: View = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer view.deinit();
    const a = view.arena.allocator();
    view.launch = try a.dupe(u8, std.fs.path.basename(launch_dir));
    const path = try std.fs.path.join(gpa, &.{ launch_dir, "events.jsonl" });
    defer gpa.free(path);
    const text = sys.readFile(gpa, path, 1 << 30) catch |err| switch (err) {
        error.FileNotFound => return view,
        else => return err,
    };
    defer gpa.free(text);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        // A line still being written is skipped until it is complete.
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        const ev = str(parsed, "event") orelse continue;
        const at = parseTime(str(parsed, "time") orelse "") orelse 0;
        const rule = str(parsed, "rule");
        if (std.mem.eql(u8, ev, "launch_started")) {
            view.selected = int(parsed, "selected") orelse 0;
            view.started_ns = at;
        } else if (std.mem.eql(u8, ev, "launch_finished")) {
            view.finished = true;
            view.final_status = str(parsed, "status") orelse "";
        } else if (std.mem.eql(u8, ev, "shared_loading")) {
            try view.shared.put(a, str(parsed, "name") orelse "?", "loading");
        } else if (std.mem.eql(u8, ev, "shared_loaded")) {
            try view.shared.put(a, str(parsed, "name") orelse "?", "loaded");
        } else if (std.mem.eql(u8, ev, "shared_released")) {
            try view.shared.put(a, str(parsed, "name") orelse "?", "released");
        } else if (rule) |r| {
            const gop = try view.rules.getOrPut(a, r);
            if (!gop.found_existing) gop.value_ptr.* = .{ .status = "pending" };
            const rv = gop.value_ptr;
            if (std.mem.eql(u8, ev, "task_started")) {
                rv.status = "running";
                rv.attempt = int(parsed, "attempt") orelse 0;
                rv.dir = str(parsed, "directory") orelse "";
                rv.cg = str(parsed, "cgroup");
                rv.started_ns = at;
            } else if (std.mem.eql(u8, ev, "task_finished")) {
                rv.status = str(parsed, "status") orelse "finished";
                rv.reason = str(parsed, "reason") orelse "";
                rv.finished_ns = at;
            } else if (std.mem.eql(u8, ev, "task_retry")) {
                rv.status = "retrying";
            } else if (std.mem.eql(u8, ev, "task_reused")) {
                rv.status = "reused";
            } else if (std.mem.eql(u8, ev, "task_blocked")) {
                rv.status = "blocked";
            } else if (std.mem.eql(u8, ev, "task_failed")) {
                rv.status = "failed";
                rv.reason = str(parsed, "reason") orelse "";
            } else if (std.mem.eql(u8, ev, "task_cancelling")) {
                rv.status = "cancelling";
            }
        }
    }
    return view;
}

fn duration(w: *std.Io.Writer, ns: i128) !void {
    const s: u64 = @intCast(@max(@divFloor(ns, std.time.ns_per_s), 0));
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 });
}

fn bytes(w: *std.Io.Writer, n: ?u64) !void {
    const v = n orelse return w.writeAll("       -");
    const f: f64 = @floatFromInt(v);
    if (v >= 1 << 30) return w.print("{d:>5.1} Gi", .{f / (1 << 30)});
    if (v >= 1 << 20) return w.print("{d:>5.1} Mi", .{f / (1 << 20)});
    return w.print("{d:>5.1} Ki", .{f / 1024});
}

/// The last non-empty line of a file, shortened for display.
fn lastLine(gpa: Allocator, a: Allocator, path: []const u8) []const u8 {
    const tail = sys.readTail(gpa, path, 4096) catch return "";
    defer gpa.free(tail);
    var end = tail.len;
    while (end > 0 and (tail[end - 1] == '\n' or tail[end - 1] == '\r' or tail[end - 1] == ' ')) end -= 1;
    const start = if (std.mem.lastIndexOfScalar(u8, tail[0..end], '\n')) |p| p + 1 else 0;
    const line = tail[start..end];
    const cut = line[0..@min(line.len, 60)];
    var out = a.dupe(u8, cut) catch return "";
    for (out) |*c| if (c.* < 0x20) {
        c.* = ' ';
    };
    out = out;
    return out;
}

pub fn render(gpa: Allocator, w: *std.Io.Writer, view: *View) !void {
    const a = view.arena.allocator();
    const counts = [_][]const u8{ "running", "completed", "reused", "failed", "blocked", "cancelled", "retrying" };
    var n: [counts.len]usize = @splat(0);
    var it = view.rules.iterator();
    while (it.next()) |e| for (counts, 0..) |c, i| {
        if (std.mem.eql(u8, e.value_ptr.status, c) or (i == 0 and std.mem.eql(u8, e.value_ptr.status, "cancelling"))) n[i] += 1;
    };
    try w.print("launch {s}  ", .{view.launch});
    if (view.finished) try w.print("{s}", .{view.final_status}) else {
        try w.writeAll("elapsed ");
        try duration(w, sys.realNs() - view.started_ns);
    }
    try w.print("\n{d} selected:", .{view.selected});
    for (counts, n) |c, k| if (k > 0) try w.print(" {d} {s},", .{ k, c });
    const done = n[1] + n[2];
    try w.print(" {d} done\n", .{done});
    var sit = view.shared.iterator();
    while (sit.next()) |e| try w.print("shared {s}: {s}\n", .{ e.key_ptr.*, e.value_ptr.* });

    try w.writeAll("\nRUNNING                                      ATT  ELAPSED     MEM NOW  MEM PEAK  LAST OUTPUT\n");
    it = view.rules.iterator();
    var shown: usize = 0;
    while (it.next()) |e| {
        const rv = e.value_ptr;
        if (!std.mem.eql(u8, rv.status, "running") and !std.mem.eql(u8, rv.status, "cancelling")) continue;
        shown += 1;
        const name = e.key_ptr.*;
        try w.print("{s:<44} {d:>3}  ", .{ name[0..@min(name.len, 44)], @as(u64, @intCast(@max(rv.attempt, 0))) });
        try duration(w, sys.realNs() - rv.started_ns);
        try w.writeAll("  ");
        const cur = if (rv.cg) |cg| cgroup.readNumber(gpa, cg, "memory.current") else null;
        const peak = if (rv.cg) |cg| cgroup.readNumber(gpa, cg, "memory.peak") else null;
        try bytes(w, cur);
        try w.writeAll("  ");
        try bytes(w, peak);
        const err_path = try std.fs.path.join(a, &.{ rv.dir, "stderr.log" });
        var line = lastLine(gpa, a, err_path);
        if (line.len == 0) line = lastLine(gpa, a, try std.fs.path.join(a, &.{ rv.dir, "stdout.log" }));
        try w.print("  {s}\n", .{line});
    }
    if (shown == 0) try w.writeAll("(none)\n");

    var failures: usize = 0;
    it = view.rules.iterator();
    while (it.next()) |e| {
        const rv = e.value_ptr;
        if (!std.mem.eql(u8, rv.status, "failed")) continue;
        if (failures == 0) try w.writeAll("\nFAILED\n");
        failures += 1;
        if (failures > 10) continue;
        try w.print("{s}: {s}", .{ e.key_ptr.*, rv.reason });
        if (rv.dir.len > 0) try w.print("  ({s}/stderr.log)", .{rv.dir});
        try w.writeAll("\n");
    }
    if (failures > 10) try w.print("... and {d} more\n", .{failures - 10});
}

fn isTerminal() bool {
    var buf: [256]u8 = undefined;
    const n = linux.readlinkat(linux.AT.FDCWD, "/proc/self/fd/1", &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return false;
    const target = buf[0..n];
    return std.mem.startsWith(u8, target, "/dev/pts/") or std.mem.startsWith(u8, target, "/dev/tty");
}

/// Shows the newest launch. Refreshes every `interval_ms` until the launch
/// finishes, unless `once`.
pub fn watch(gpa: Allocator, io: std.Io, root: []const u8, once: bool, interval_ms: u64) !bool {
    var abuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&abuf);
    const rec = try records.recordsDir(fba.allocator(), root);
    var launch_arena = std.heap.ArenaAllocator.init(gpa);
    defer launch_arena.deinit();
    const dir = (try records.latestLaunch(gpa, launch_arena.allocator(), rec)) orelse {
        std.debug.print("workz: no launch recorded in {s}\n", .{rec});
        return false;
    };
    const tty = isTerminal();
    var obuf: [16384]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &obuf);
    while (true) {
        var view = try load(gpa, dir);
        defer view.deinit();
        if (tty and !once) try out.interface.writeAll("\x1b[H\x1b[2J");
        try render(gpa, &out.interface, &view);
        try out.interface.flush();
        if (once or view.finished) return true;
        const ts: linux.timespec = .{ .sec = @intCast(interval_ms / 1000), .nsec = @intCast((interval_ms % 1000) * std.time.ns_per_ms) };
        _ = linux.nanosleep(&ts, null);
    }
}

/// Prints the newest launch's summary, or its live view while it runs.
pub fn status(gpa: Allocator, io: std.Io, root: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try records.recordsDir(a, root);
    const dir = (try records.latestLaunch(gpa, a, rec)) orelse {
        std.debug.print("workz: no launch recorded in {s}\n", .{rec});
        return false;
    };
    const summary = sys.readFile(gpa, try std.fs.path.join(a, &.{ dir, "summary.json" }), 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return watch(gpa, io, root, true, 0),
        else => return err,
    };
    defer gpa.free(summary);
    try sys.writeAll(1, summary);
    return true;
}
