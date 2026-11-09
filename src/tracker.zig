//! The state of one launch, kept up to date from its event stream: every
//! selected rule with its status and attempt, the shared inputs, the run
//! samples and the waits for resource groups. The stream is read
//! incrementally: an update parses only the complete lines appended since
//! the previous one. The live views and the reports both build on it. Given
//! the launch's names (`names.zig`), each rule also carries the tool, step
//! and sample the views show.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fields = @import("fields.zig");
const flat = @import("flat.zig");
const records = @import("records.zig");
const naming = @import("names.zig");
const event_version = records.event_version;
const Allocator = std.mem.Allocator;
const str = fields.str;
const int = fields.int;
const whole = fields.whole;
const float = fields.float;

pub const Status = enum {
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

    pub fn label(s: Status) []const u8 {
        return if (s == .cancelling) "stopping" else @tagName(s);
    }

    pub fn done(s: Status) bool {
        return s == .completed or s == .reused;
    }
};

/// An event line's fields, read from the flat line or from its JSON tree
/// with the same rules (`fields.zig`).
const Fields = union(enum) {
    flat: *const flat.Flat,
    tree: std.json.Value,

    fn get(self: Fields, key: []const u8) ?std.json.Value {
        return switch (self) {
            .flat => |f| f.get(key),
            .tree => |v| fields.get(v, key),
        };
    }

    fn str(self: Fields, key: []const u8) ?[]const u8 {
        return fields.strOf(self.get(key));
    }

    fn int(self: Fields, key: []const u8) ?i64 {
        return fields.intOf(self.get(key));
    }

    fn whole(self: Fields, comptime T: type, key: []const u8) ?T {
        return std.math.cast(T, self.int(key) orelse return null);
    }

    fn float(self: Fields, key: []const u8) ?f64 {
        return fields.number(self.get(key));
    }

    /// An array version is newer too, as `fields.newer` reads one.
    fn newer(self: Fields, known: i64) bool {
        return self.isArray("v") or fields.newerOf(self.get("v"), known);
    }

    /// Whether `key` holds an array, and its string items in order.
    fn isArray(self: Fields, key: []const u8) bool {
        return switch (self) {
            .flat => |f| f.isArray(key),
            .tree => |v| if (fields.get(v, key)) |x| x == .array else false,
        };
    }

    fn strings(self: Fields, key: []const u8) Strings {
        return switch (self) {
            .flat => |f| .{ .flat = f.strings(key) },
            .tree => |v| .{ .tree = if (fields.get(v, key)) |x| (if (x == .array) x.array.items else &.{}) else &.{} },
        };
    }
};

const Strings = union(enum) {
    flat: flat.Strings,
    tree: []const std.json.Value,

    fn next(self: *Strings) ?[]const u8 {
        switch (self.*) {
            .flat => |*f| return f.next(),
            .tree => |*items| while (items.len > 0) {
                const x = items.*[0];
                items.* = items.*[1..];
                if (x == .string) return x.string;
            },
        }
        return null;
    }
};

pub const RuleView = struct {
    name: []const u8,
    shown: []const u8 = "",
    tool: []const u8 = "",
    step: []const u8 = "",
    sample: []const u8 = "",
    /// The rule's step in the launch's names, when they are known.
    step_index: ?u32 = null,
    status: Status = .waiting,
    attempt: u32 = 0,
    shared: []const []const u8 = &.{},
    dir: []const u8 = "",
    cg: ?[]const u8 = null,
    ready_ns: i128 = 0,
    started_ns: i128 = 0,
    finished_ns: i128 = 0,
    reason: []const u8 = "",
    memory_peak: ?u64 = null,
    cpu_s: ?f64 = null,
    /// The ended attempt's time from its start to its exit, as the run log
    /// shows it; the event times around it also cover setup and records.
    wall_s: ?f64 = null,
    threads: u32 = 0,
    memory_mib: u64 = 0,
    live_memory: ?u64 = null,
    live_peak: ?u64 = null,
    live_cores: ?f64 = null,
    live_cpu_usec: ?u64 = null,
    live_cpu_ns: i128 = 0,
};

pub const SharedView = struct {
    name: []const u8,
    state: []const u8,
    users: std.ArrayList(usize) = .empty,
    memory_peak: ?u64 = null,
    cg: ?[]const u8 = null,
    live_memory: ?u64 = null,
    service: bool = false,
    starts: u32 = 0,
    load_s: f64 = 0,
    loading_ns: i128 = 0,
    declared_mib: f64 = 0,
    reserved_mib: ?f64 = null,
    failed: bool = false,
    held_s: f64 = 0,
    held_since: i128 = 0,
};

pub const Sample = struct {
    ns: i128,
    threads_reserved: f64,
    memory_reserved_mib: f64,
    shared_reserved_mib: f64 = 0,
    memory_current: ?u64,
    cpu_cores: ?f64,
};

pub const GroupWait = struct { rule: usize, group: []const u8, from_ns: i128, to_ns: i128 = 0 };

pub const Tracker = struct {
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    events_path: []const u8,
    offset: u64 = 0,
    partial: std.ArrayList(u8) = .empty,

    launch: []const u8 = "",
    workdir_name: []const u8 = "",
    /// The workflow's name, for the views' titles, and whether the launch
    /// held its rules to their requests.
    workflow_name: []const u8 = "",
    isolated: bool = true,
    launch_read: bool = false,
    selected: u32 = 0,
    started_ns: i128 = 0,
    launch_ns: i128 = 0,
    checks_s: f64 = 0,
    unreadable_lines: usize = 0,
    max_threads: u32 = 0,
    max_memory_mib: u64 = 0,
    max_jobs: u32 = 0,
    run_cg: ?[]const u8 = null,
    ending: bool = false,
    finished: bool = false,
    finished_ns: i128 = 0,
    final_status: []const u8 = "",
    last_ns: i128 = 0,
    final_error: []const u8 = "",
    memory_current: ?u64 = null,
    cpu_cores: ?f64 = null,
    rules: std.ArrayList(RuleView) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,
    shared: std.ArrayList(SharedView) = .empty,
    samples: std.ArrayList(Sample) = .empty,
    group_waits: std.ArrayList(GroupWait) = .empty,
    engine: []const u8 = "",
    engine_key: ?i64 = null,
    previous_bytes: u64 = 0,
    open_wait: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    names: ?*const naming.Names = null,

    pub fn init(gpa: Allocator, launch_dir: []const u8) !Tracker {
        var t: Tracker = .{ .arena = std.heap.ArenaAllocator.init(gpa), .gpa = gpa, .events_path = "" };
        errdefer t.arena.deinit();
        const a = t.arena.allocator();
        t.events_path = try std.fs.path.join(a, &.{ launch_dir, "events.jsonl" });
        t.launch = try a.dupe(u8, std.fs.path.basename(launch_dir));
        _ = t.readLaunch();
        return t;
    }

    /// Reads the launch's `launch.json`, which a launch writes just after
    /// its directory; a view that started first reads it again until it
    /// exists. The file is parsed in a scratch arena and only its fields
    /// are kept, so a failed read keeps nothing. Returns whether it was read.
    pub fn readLaunch(self: *Tracker) bool {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const s = scratch.allocator();
        const dir = std.fs.path.dirname(self.events_path) orelse return false;
        const path = std.fs.path.join(s, &.{ dir, "launch.json" }) catch return false;
        const text = sys.readFile(self.gpa, path, 1 << 20) catch return false;
        defer self.gpa.free(text);
        const v = std.json.parseFromSliceLeaky(std.json.Value, s, text, .{}) catch return false;
        const a = self.arena.allocator();
        if (str(v, "workdir")) |wd| self.workdir_name = a.dupe(u8, std.fs.path.basename(wd)) catch "";
        if (str(v, "engine")) |e| self.engine = a.dupe(u8, e) catch "";
        if (str(v, "workflow_name")) |n| self.workflow_name = a.dupe(u8, n) catch "";
        if (v == .object) if (v.object.get("isolation")) |iso| if (iso == .bool) {
            self.isolated = iso.bool;
        };
        self.engine_key = int(v, "engine_key");
        self.launch_read = true;
        return true;
    }

    /// Takes the launch's names, and names the rules already seen by them.
    pub fn applyNames(self: *Tracker, n: *const naming.Names) void {
        self.names = n;
        for (self.rules.items) |*r| if (n.find(r.name)) |k| {
            r.shown = n.word[k];
            r.tool = n.tool[k];
            r.step = n.step[k];
            r.sample = n.sample[k];
            r.step_index = n.step_of[k];
        };
    }

    pub fn deinit(self: *Tracker) void {
        self.partial.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn markUnfinished(self: *Tracker) void {
        self.finished = true;
        self.final_status = "unfinished";
        self.finished_ns = self.last_ns;
        for (self.rules.items) |*r| if (r.status == .running or r.status == .cancelling) {
            r.status = .cancelled;
            r.reason = "its engine ended without recording its end";
            if (r.finished_ns == 0) r.finished_ns = self.last_ns;
        };
    }

    pub fn settleEnd(self: *Tracker) !bool {
        if (self.finished) return true;
        const dir = std.fs.path.dirname(self.events_path) orelse return false;
        if (records.launchActive(self.gpa, dir)) return false;
        _ = try self.update();
        if (!self.finished) self.markUnfinished();
        return true;
    }

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
            var view: RuleView = .{ .name = owned, .shown = owned, .step = owned };
            if (self.names) |n| if (n.find(owned)) |k| {
                view.shown = n.word[k];
                view.tool = n.tool[k];
                view.step = n.step[k];
                view.sample = n.sample[k];
                view.step_index = n.step_of[k];
            };
            try self.rules.append(self.arena.allocator(), view);
        }
        return &self.rules.items[gop.value_ptr.*];
    }

    fn sharedView(self: *Tracker, name: []const u8) !*SharedView {
        for (self.shared.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        try self.shared.append(self.arena.allocator(), .{ .name = try self.arena.allocator().dupe(u8, name), .state = "" });
        return &self.shared.items[self.shared.items.len - 1];
    }

    pub fn apply(self: *Tracker, line: []const u8) !void {
        if (line.len == 0) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        var line_fields: flat.Flat = undefined;
        const v: Fields = if (flat.read(&line_fields, line)) .{ .flat = &line_fields } else .{ .tree = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), line, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.unreadable_lines += 1;
            return;
        } };
        if (v.newer(event_version)) {
            self.unreadable_lines += 1;
            return;
        }
        const a = self.arena.allocator();
        const ev = v.str("event") orelse return;
        const at = parseTime(v.str("time") orelse "") orelse 0;
        if (self.started_ns == 0) self.started_ns = at;
        if (at > self.last_ns) self.last_ns = at;
        const eql = std.mem.eql;
        if (eql(u8, ev, "launch_started")) {
            self.launch_ns = at;
            self.checks_s = @max(v.float("checks_s") orelse 0, 0);
            self.selected = v.whole(u32, "selected") orelse 0;
            self.max_threads = v.whole(u32, "max_threads") orelse 0;
            self.max_memory_mib = v.whole(u64, "max_memory_mib") orelse 0;
            self.max_jobs = v.whole(u32, "jobs") orelse 0;
            self.run_cg = if (v.str("cgroup")) |cg| try a.dupe(u8, cg) else null;
            var rule_names = v.strings("rules");
            while (rule_names.next()) |n| {
                const r = try self.rule(n);
                r.status = .pending;
            }
        } else if (eql(u8, ev, "launch_ending")) {
            self.ending = true;
        } else if (eql(u8, ev, "launch_finished")) {
            self.finished = true;
            self.finished_ns = at;
            self.final_status = try a.dupe(u8, v.str("status") orelse "");
            self.final_error = try a.dupe(u8, v.str("error") orelse "");
        } else if (eql(u8, ev, "output_preserved")) {
            self.previous_bytes += v.whole(u64, "bytes") orelse 0;
        } else if (eql(u8, ev, "sample")) {
            self.memory_current = if (v.int("memory_current")) |m| @intCast(m) else null;
            self.cpu_cores = if (v.float("cpu_cores_used")) |c| @max(c, 0) else null;
            try self.samples.append(a, .{
                .ns = at,
                .threads_reserved = @max(v.float("threads_reserved") orelse 0, 0),
                .memory_reserved_mib = @max(v.float("memory_reserved_mib") orelse 0, 0),
                .shared_reserved_mib = @max(v.float("shared_reserved_mib") orelse 0, 0),
                .memory_current = self.memory_current,
                .cpu_cores = self.cpu_cores,
            });
        } else if (std.mem.startsWith(u8, ev, "shared_")) {
            const s = try self.sharedView(v.str("name") orelse "?");
            s.state = if (eql(u8, ev, "shared_loading")) "loading" else if (eql(u8, ev, "shared_loaded")) "ready" else if (eql(u8, ev, "shared_released")) "released" else if (eql(u8, ev, "shared_failed")) "failed" else s.state;
            if (v.int("memory_peak")) |m| s.memory_peak = @max(s.memory_peak orelse 0, @as(u64, @intCast(m)));
            if (eql(u8, ev, "shared_loading")) {
                s.cg = if (v.str("cgroup")) |cg| try a.dupe(u8, cg) else null;
                s.starts += 1;
                s.loading_ns = at;
                if (v.float("memory_mib")) |m| {
                    s.service = true;
                    s.declared_mib = m;
                    s.reserved_mib = v.float("reserved_mib");
                } else if (v.float("bytes")) |b| s.declared_mib = b / 1048576.0;
            } else if (eql(u8, ev, "shared_loaded")) {
                if (s.loading_ns > 0) s.load_s += @as(f64, @floatFromInt(at - s.loading_ns)) / 1e9;
            } else if (eql(u8, ev, "shared_failed")) s.failed = true;
            if (eql(u8, ev, "shared_loading")) {
                s.held_since = at;
            } else if ((eql(u8, ev, "shared_released") or eql(u8, ev, "shared_failed")) and s.held_since > 0) {
                s.held_s += @as(f64, @floatFromInt(at - s.held_since)) / 1e9;
                s.held_since = 0;
            }
        } else if (std.mem.startsWith(u8, ev, "task_")) if (v.str("rule")) |name| {
            const r = try self.rule(name);
            const ri = self.index.get(name).?;
            if (eql(u8, ev, "task_waiting") or eql(u8, ev, "task_started")) {
                if (self.open_wait.fetchRemove(ri)) |kv| self.group_waits.items[kv.value].to_ns = at;
            }
            if (eql(u8, ev, "task_waiting")) {
                if (r.ready_ns == 0) r.ready_ns = at;
                r.status = .waiting;
                if (v.whole(u32, "threads")) |n| r.threads = n;
                if (v.whole(u64, "memory_mib")) |n| r.memory_mib = n;
                r.reason = try a.dupe(u8, v.str("reason") orelse "");
                if (std.mem.startsWith(u8, r.reason, "group:")) {
                    try self.open_wait.put(a, ri, self.group_waits.items.len);
                    try self.group_waits.append(a, .{ .rule = ri, .group = r.reason["group:".len..], .from_ns = at });
                }
            } else if (eql(u8, ev, "task_started")) {
                if (r.ready_ns == 0) r.ready_ns = at;
                r.status = .running;
                r.attempt = v.whole(u32, "attempt") orelse 0;
                r.dir = try a.dupe(u8, v.str("directory") orelse "");
                r.cg = if (v.str("cgroup")) |cg| try a.dupe(u8, cg) else null;
                r.threads = v.whole(u32, "threads") orelse 0;
                r.memory_mib = v.whole(u64, "memory_mib") orelse 0;
                r.started_ns = at;
                r.finished_ns = 0;
                r.wall_s = null;
                if (v.isArray("shared")) {
                    var names: std.ArrayList([]const u8) = .empty;
                    var items = v.strings("shared");
                    while (items.next()) |item| {
                        try names.append(a, try a.dupe(u8, item));
                        const sv = try self.sharedView(item);
                        if (std.mem.indexOfScalar(usize, sv.users.items, ri) == null) try sv.users.append(a, ri);
                    }
                    r.shared = names.items;
                }
                r.reason = "";
                r.live_memory = null;
                r.live_peak = null;
                r.live_cores = null;
                r.live_cpu_usec = null;
            } else if (eql(u8, ev, "task_finished")) {
                const st = v.str("status") orelse "";
                r.status = if (eql(u8, st, "completed")) .completed else if (eql(u8, st, "cancelled")) .cancelled else .failed;
                r.reason = try a.dupe(u8, v.str("reason") orelse "");
                r.finished_ns = at;
                if (v.int("memory_peak")) |m| r.memory_peak = @intCast(m);
                r.cpu_s = v.float("cpu_s");
                r.wall_s = v.float("wall_s");
            } else if (eql(u8, ev, "task_retry")) {
                r.status = .retrying;
            } else if (eql(u8, ev, "task_reused")) {
                r.status = .reused;
            } else if (eql(u8, ev, "task_blocked")) {
                r.status = .blocked;
            } else if (eql(u8, ev, "task_failed")) {
                r.status = .failed;
                r.reason = try a.dupe(u8, v.str("reason") orelse "");
                if (r.finished_ns == 0) r.finished_ns = at;
            } else if (eql(u8, ev, "task_cancelling")) {
                r.status = .cancelling;
            }
        };
    }

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

pub fn parseTime(t: []const u8) ?i128 {
    if (t.len < 20) return null;
    const y = std.fmt.parseInt(i64, t[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, t[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, t[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, t[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, t[14..16], 10) catch return null;
    const s = std.fmt.parseInt(i64, t[17..19], 10) catch return null;
    const ms: i64 = if (t.len >= 23 and t[19] == '.') std.fmt.parseInt(i64, t[20..23], 10) catch 0 else 0;
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
