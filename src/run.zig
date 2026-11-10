//! The run loop: admission, dispatch, reaping, timeouts, retries,
//! cancellation, shared-input holders and records.
//!
//! One thread waits in ppoll on a signalfd and the shared holders' pipes, with
//! the nearest timeout as its deadline. Ready rules are tried by priority,
//! then, when several are ready, by the estimated chain of work they head
//! (the critical-path rank), then by the time they became ready, then by
//! file order; every rule whose CPU, memory, group, shared-input and job
//! requests fit starts.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const state = @import("state.zig");
const records = @import("records.zig");
const process = @import("process.zig");
const cgroup = @import("cgroup.zig");
const naming = @import("names.zig");
const fields = @import("fields.zig");
const logging = @import("log.zig");
const clock = @import("clock.zig");
const summary_text = @import("summary.zig");
const container = @import("container.zig");
const plan = @import("plan.zig");
const model = @import("model.zig");
const html = @import("html.zig");
const monitor = @import("monitor.zig");
const units = @import("units.zig");
const term = @import("term.zig");
const schedule = @import("schedule.zig");
const Allocator = std.mem.Allocator;

pub const version = @import("root.zig").version;

pub const Options = struct {
    jobs: ?u32 = null,
    max_threads: ?u32 = null,
    max_memory_mib: ?u64 = null,
    keep_going: bool = false,
    retry: u32 = 0,
    timeout_s: ?u64 = null,
    rerun: bool = false,
    rerun_rules: []const []const u8 = &.{},

    input_manifest: ?[]const u8 = null,
    isolation: bool = true,
    pass_env: []const []const u8 = &.{},
    thread_overrides: []const []const u8 = &.{},
    grace_s: u64 = 10,
    quiet: bool = false,
    verbose: bool = false,
    json: bool = false,
    color: bool = true,
    slice: ?[]const u8 = null,

    pub fn forced(self: Options, name: []const u8) bool {
        if (self.rerun) return true;
        for (self.rerun_rules) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

pub const Outcome = enum(u8) { ok = 0, failed = 1, invalid = 2, interrupted = 130 };

const Status = schedule.Status;

const after_failure = "cancelled: the launch stopped after a failure";
const after_interrupt = "cancelled: the launch was interrupted";

/// How the selected rules of one step or one sample stand.
const Group = struct {
    selected: u32 = 0,
    completed: u32 = 0,
    reused: u32 = 0,
    failed: u32 = 0,
    blocked: u32 = 0,
    cancelled: u32 = 0,
    not_started: u32 = 0,
    running: u32 = 0,

    fn ended(g: Group) u32 {
        return g.completed + g.reused + g.failed + g.blocked + g.cancelled + g.not_started;
    }

    fn slot(g: *Group, s: Status) ?*u32 {
        return switch (s) {
            .completed => &g.completed,
            .reused => &g.reused,
            .failed => &g.failed,
            .blocked => &g.blocked,
            .cancelled => &g.cancelled,
            .not_started => &g.not_started,
            .running, .staging => &g.running,
            else => null,
        };
    }

    fn move(g: *Group, old: Status, new: Status) void {
        if (g.slot(old)) |c| c.* -= 1;
        if (g.slot(new)) |c| c.* += 1;
    }
};

const Tally = struct {
    status: [@typeInfo(Status).@"enum".fields.len]usize = @splat(0),
    steps: []Group = &.{},
    samples: []Group = &.{},
};

const Task = struct {
    status: Status = .pending,
    attempts: u32 = 0,
    max_attempts: u32 = 1,
    key: ?state.Key = null,
    pid: linux.pid_t = 0,
    cg: ?cgroup.Group = null,
    anon_peak: ?u64 = null,
    stop_why: []const u8 = "stopped",
    dir: []const u8 = "",
    started_ns: i128 = 0,
    started_real: i128 = 0,
    engine_rss_kib: i64 = 0,
    deadline_ns: ?i128 = null,
    kill_at: ?i128 = null,
    ended: ?process.Reaped = null,
    timed_out: bool = false,
    cancelled: bool = false,
    lost_service: ?[]const u8 = null,
    spawned: bool = false,
    reason: []const u8 = "",
    diagnostics: []const []const u8 = &.{},
    ready_ns: i128 = 0,
    wait_reason: ?[]const u8 = null,
    wait_since: i128 = 0,
    waits: std.ArrayList(Wait) = .empty,
    queued_s: f64 = 0,
    container_name: ?[]const u8 = null,
};

const Wait = struct { reason: []const u8, seconds: f64 };

const Listed = packed struct { woken: bool = false, active: bool = false, staged: bool = false, ready: bool = false };

fn topoOrder(pos: []const usize, x: usize, y: usize) std.math.Order {
    return std.math.order(pos[x], pos[y]);
}

const Version = struct {
    command: []const u8,
    container: ?[]const u8,
    image: ?[]const u8,
    file: []const u8,
    rule: usize = 0,
    pid: linux.pid_t = 0,
    started: bool = false,
    running: bool = false,
    exit_code: ?u32 = null,
    stopped: bool = false,
};

const TaskKeys = struct {
    tasks: []const Task,
    pub fn get(self: TaskKeys, p: usize) ?[]const u8 {
        return if (self.tasks[p].key) |k| k.key else null;
    }
};

const Guard = struct {
    pid: linux.pid_t,
    fd: sys.Fd,

    fn start(a: Allocator, envp: *const process.Vec, devnull: sys.Fd) !Guard {
        var pipe: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
        defer sys.close(pipe[0]);
        errdefer sys.close(pipe[1]);
        const exe = try sys.childExe(a);
        const argv = try process.Vec.init(a, &.{ "kanit", "__guard" });
        const spec: process.Spec = .{ .path = exe.ptr, .argv = argv.items.ptr, .envp = envp.items.ptr, .cwd = "/", .stdin = pipe[0], .stdout = devnull, .stderr = 2 };
        return .{ .pid = try process.spawn(&spec), .fd = pipe[1] };
    }

    fn note(self: Guard, sign: u8, pgid: linux.pid_t) void {
        var buf: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{c}{d}\n", .{ sign, pgid }) catch return;
        sys.writeAll(self.fd, text) catch {};
    }

    fn stop(self: Guard) void {
        sys.close(self.fd);
        if (self.pid == 0) return;
        var status: u32 = 0;
        _ = linux.wait4(self.pid, &status, 0, null);
    }
};

const Network = struct {
    pid: linux.pid_t,
    userns: sys.Fd,
    netns: sys.Fd,
    alive: sys.Fd,

    fn start(gpa: Allocator, a: Allocator, envp: *const process.Vec, run_cgroup: []const u8) !Network {
        var pipe: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
        defer sys.close(pipe[0]);
        var alive: [2]i32 = undefined;
        _ = sys.check(linux.pipe2(&alive, .{ .CLOEXEC = true })) catch |err| {
            sys.close(pipe[1]);
            return err;
        };
        defer sys.close(alive[0]);
        errdefer sys.close(alive[1]);
        const exe = try sys.childExe(a);
        const argv = try process.Vec.init(a, &.{ "kanit", "__netns", try std.fmt.allocPrint(a, "{s}/cgroup.kill", .{run_cgroup}) });
        const spec: process.Spec = .{ .path = exe.ptr, .argv = argv.items.ptr, .envp = envp.items.ptr, .cwd = "/", .stdin = alive[0], .stdout = pipe[1], .stderr = 2 };
        const pid = process.spawn(&spec) catch |err| {
            sys.close(pipe[1]);
            return err;
        };
        sys.close(pipe[1]);
        var buf: [16]u8 = undefined;
        const n = sys.read(pipe[0], &buf) catch 0;
        errdefer {
            process.signalPid(pid, .KILL);
            var status: u32 = 0;
            _ = linux.wait4(pid, &status, 0, null);
        }
        if (n < 5 or !std.mem.startsWith(u8, buf[0..n], "ready")) return error.NetworkNotReady;
        const user_path = try std.fmt.allocPrint(gpa, "/proc/{d}/ns/user", .{pid});
        defer gpa.free(user_path);
        const net_path = try std.fmt.allocPrint(gpa, "/proc/{d}/ns/net", .{pid});
        defer gpa.free(net_path);
        const userns = try sys.openRead(gpa, user_path);
        errdefer sys.close(userns);
        return .{ .pid = pid, .userns = userns, .netns = try sys.openRead(gpa, net_path), .alive = alive[1] };
    }

    fn stop(self: Network) void {
        sys.close(self.userns);
        sys.close(self.netns);
        if (self.pid > 0) {
            process.signalPid(self.pid, .KILL);
            var status: u32 = 0;
            _ = linux.wait4(self.pid, &status, 0, null);
        }
        sys.close(self.alive);
    }
};

const HolderState = enum { idle, loading, ready, stopping, failed };

const Holder = struct {
    bytes: u64,
    mib: u64,
    reserve_mib: u64,
    users: u32 = 0,
    st: HolderState = .idle,
    pid: linux.pid_t = 0,
    pipe: sys.Fd = -1,
    cg: ?cgroup.Group = null,
    container_name: ?[]const u8 = null,
    stop_fd: sys.Fd = -1,
    starts: u32 = 0,
    served: u32 = 0,
    started_ns: i128 = 0,
    kill_at: ?i128 = null,
    failure: ?[]const u8 = null,
    failed_starts: u32 = 0,
    held: bool = false,
    ready_deadline: ?i128 = null,
    timed_out: bool = false,
};

pub fn defaultThreads() u32 {
    return @intCast(std.Thread.getCpuCount() catch 1);
}

pub fn defaultMemoryMib(gpa: Allocator) u64 {
    const text = sys.readFile(gpa, "/proc/meminfo", 1 << 16) catch return 4096;
    defer gpa.free(text);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;
        var parts = std.mem.tokenizeScalar(u8, line[9..], ' ');
        const kib = std.fmt.parseInt(u64, parts.next() orelse break, 10) catch break;
        return kib / 1024 * 3 / 4;
    }
    return 4096;
}

const Engine = struct {
    gpa: Allocator,
    a: Allocator,
    wf: *const workflow.Workflow,
    g: *const graph.Graph,
    mask: []const bool,
    opts: Options,
    budget: schedule.Budget,

    tasks: []Task,
    holders: []Holder,
    usage: schedule.Usage,
    group_needs: []const []const schedule.GroupNeed,
    group_reasons: []const []const u8,
    priorities: []const i64,
    ready_seq: []u64,
    ready_counter: u64 = 0,
    topo_pos: []const usize,
    wake: std.PriorityQueue(usize, []const usize, topoOrder),
    by_pid: std.AutoHashMapUnmanaged(linux.pid_t, usize) = .empty,
    active: std.ArrayList(usize) = .empty,
    staged: std.ArrayList(usize) = .empty,
    ready_list: std.ArrayList(usize) = .empty,
    listed: []Listed,

    st: *state.State,
    ids: *state.Identities,
    cut: *state.Cutoff,
    events: *records.Events,
    journal: *records.Journal,
    launch_dir: []const u8,
    launch_id: []const u8,
    engine_id: []const u8,
    env_text: []const u8,
    envp: process.Vec,
    bash: [:0]const u8,
    devnull: sys.Fd,
    tree: ?cgroup.Tree,
    network: ?Network,
    guard: ?Guard = null,
    ranks: []const f64 = &.{},
    control_path: []const u8 = "",
    control_watch: sys.Fd = -1,
    control_offset: u64 = 0,
    control_skip: bool = false,
    podman: ?[]const u8 = null,
    containers_cg: ?cgroup.Group = null,
    images: std.StringHashMapUnmanaged([]const u8) = .empty,
    extras: []const []const u8 = &.{},
    sigfd: sys.Fd,

    stopping: bool = false,
    ending: bool = false,
    interrupted: bool = false,
    interrupted_at: i128 = 0,
    signalled_at: ?i128 = null,
    fatal: ?[]const u8 = null,
    dirty: bool = false,
    pending_done: std.ArrayList([]const u8) = .empty,
    pending_files: std.ArrayList([]const u8) = .empty,
    pending_envs: std.ArrayList([]const u8) = .empty,
    last_save_ns: i128 = 0,
    freed_ns: i128 = 0,
    next_sample_ns: i128 = 0,
    last_sample_ns: i128 = 0,
    last_cpu_us: ?u64 = null,
    page_path: ?[]const u8 = null,
    next_page_ns: i128 = 0,
    leftover_cgroups: std.ArrayList([]const u8) = .empty,
    helpers: std.ArrayList(linux.pid_t) = .empty,
    finished: usize = 0,
    selected: usize = 0,
    previous_bytes: u64 = 0,
    versions: std.ArrayList(Version) = .empty,
    start_mono: i128 = 0,
    names: naming.Names,
    log: logging.Log,
    tally: Tally,
    blocked_by: []usize,
    stop_cause: ?usize = null,
    next_beat_ns: i128 = 0,
    view_steps: std.ArrayList(logging.StepProgress) = .empty,
    view_running: std.ArrayList(logging.Running) = .empty,
    footer_text: std.Io.Writer.Allocating,
    ended_log: bool = false,
    latest_shown: []const u8 = "",

    // --- The run log ---

    fn say(self: *Engine, word: logging.Word, i: usize, f: logging.Figures) void {
        self.log.emit(word, .{ .step = self.names.step[i], .sample = self.names.sample[i], .tool = self.names.tool[i] }, f);
    }

    fn figures(self: *Engine, i: usize, wall_s: f64, counters: ?cgroup.Counters, reaped: process.Reaped) logging.Figures {
        const r = self.rule(i);
        const cpu = taskCpu(counters, reaped);
        return .{
            .took_s = wall_s,
            .used_mib = usedMib(r, &self.tasks[i], counters, reaped),
            .request_mib = r.memory_mib,
            .cores = if (wall_s >= 0.1) cpu / wall_s else null,
            .threads = r.threads,
        };
    }

    fn request(self: *Engine, i: usize) logging.Figures {
        const r = self.rule(i);
        return .{ .request_mib = r.memory_mib, .threads = r.threads };
    }

    fn quoteStderr(self: *Engine, dir: []const u8, n: usize) bool {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const lines = monitor.lastLines(self.gpa, sa, std.fs.path.join(sa, &.{ dir, "stderr.log" }) catch return false, n, 1000);
        for (lines) |l| self.log.quoteLine(l);
        return lines.len > 0;
    }

    fn quoteDiagnostics(self: *Engine, dir: []const u8, kept: []const []const u8) bool {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var any = false;
        for (kept) |d| {
            const lines = monitor.lastLines(self.gpa, sa, std.fs.path.join(sa, &.{ dir, "diagnostics", d }) catch continue, 3, 1000);
            if (lines.len == 0) continue;
            self.log.quoteLine(std.fmt.allocPrint(sa, "{s}:", .{d}) catch continue);
            for (lines) |l| self.log.quoteLine(l);
            any = true;
        }
        return any;
    }

    fn hintLogs(self: *Engine, i: usize, dir: []const u8) void {
        var buf: [256]u8 = undefined;
        const command = std.fmt.bufPrint(&buf, "kanit logs {s}", .{self.names.word[i]}) catch return;
        var where: [4096]u8 = undefined;
        var latest: [4096]u8 = undefined;
        const real = std.fmt.bufPrint(&where, "{s}/", .{monitor.shownPath(self.a, dir)}) catch "";
        const short = std.fmt.bufPrint(&latest, "{s}{s}/", .{ self.latest_shown, dir[self.launch_dir.len..] }) catch real;
        self.log.hintLine(command, real, short);
    }

    fn rootOf(self: *Engine, i: usize) ?usize {
        var fallback: ?usize = null;
        for (self.g.parents[i]) |p| switch (self.tasks[p].status) {
            .failed, .cancelled, .not_started => return p,
            .blocked => if (fallback == null) {
                fallback = self.blocked_by[p];
            },
            else => {},
        };
        return fallback;
    }

    fn rootText(self: *Engine, root: usize) []const u8 {
        return switch (self.tasks[root].status) {
            .failed => "failed",
            .cancelled => "was stopped",
            else => "did not start",
        };
    }

    fn setStatus(self: *Engine, i: usize, new: Status) void {
        const t = &self.tasks[i];
        const old = t.status;
        t.status = new;
        if (old == new or !self.mask[i]) return;
        self.tally.status[@intFromEnum(old)] -= 1;
        self.tally.status[@intFromEnum(new)] += 1;
        const c = &self.tally.status;
        self.log.done = c[@intFromEnum(Status.completed)] + c[@intFromEnum(Status.reused)];
        self.tally.steps[self.names.step_of[i]].move(old, new);
        if (self.names.sample_of[i]) |k| self.tally.samples[k].move(old, new);
        self.log.footer_dirty = true;
    }

    fn progressNow(self: *Engine) logging.Progress {
        const c = &self.tally.status;
        self.view_steps.clearRetainingCapacity();
        self.view_steps.ensureTotalCapacity(self.gpa, self.tally.steps.len) catch {};
        for (self.tally.steps, self.names.steps) |g, st| {
            if (g.selected == 0) continue;
            self.view_steps.appendAssumeCapacity(.{ .name = st.name, .tool = st.tool orelse "", .selected = g.selected, .done = g.completed + g.reused, .failed = g.failed, .blocked = g.blocked, .stopped = g.cancelled + g.not_started, .running = g.running, .ended = g.ended() == g.selected });
        }
        self.view_running.clearRetainingCapacity();
        const now = sys.monoNs();
        for (self.active.items) |i| {
            const t = self.tasks[i];
            if (t.status != .running) continue;
            self.view_running.append(self.gpa, .{ .word = self.names.word[i], .seconds = @as(f64, @floatFromInt(now - t.started_ns)) / 1e9 }) catch {};
        }
        std.mem.sort(logging.Running, self.view_running.items, {}, struct {
            fn longer(_: void, x: logging.Running, y: logging.Running) bool {
                return x.seconds > y.seconds;
            }
        }.longer);
        return .{
            .selected = self.selected,
            .done = c[@intFromEnum(Status.completed)] + c[@intFromEnum(Status.reused)],
            .running = c[@intFromEnum(Status.running)] + c[@intFromEnum(Status.staging)],
            .failed = c[@intFromEnum(Status.failed)],
            .blocked = c[@intFromEnum(Status.blocked)],
            .cancelled = c[@intFromEnum(Status.cancelled)] + c[@intFromEnum(Status.not_started)],
            .elapsed_s = @as(f64, @floatFromInt(now - self.start_mono)) / 1e9,
            .steps = self.view_steps.items,
            .grouped = self.view_steps.items.len < self.selected or self.names.samples.len > 0,
            .running_list = self.view_running.items,
        };
    }

    fn tick(self: *Engine, force: bool) void {
        const now = sys.monoNs();
        if (now >= self.next_beat_ns) {
            self.next_beat_ns = now + logging.heartbeat_ns;
            self.log.beat(self.progressNow());
        }
        var footer: ?[]const u8 = null;
        var lines: usize = 0;
        if (self.log.terminal()) |s| if (!self.ended_log and (force or self.log.footerDue(now) or s.pending.items.len > 0)) {
            const size = term.size(2);
            s.style.cols = size.cols;
            s.style.rows = size.rows;
            self.footer_text.clearRetainingCapacity();
            lines = logging.footer(&self.footer_text.writer, s.style, self.progressNow()) catch 0;
            footer = self.footer_text.written();
        };
        self.log.flush(now, force, footer, lines);
    }

    fn endLog(self: *Engine) void {
        self.ended_log = true;
        self.log.flush(sys.monoNs(), true, null, 0);
    }

    fn rule(self: *Engine, i: usize) *const workflow.Rule {
        return &self.wf.rules[i];
    }

    // --- Readiness and reuse ---

    fn wakeTask(self: *Engine, i: usize) void {
        if (self.listed[i].woken) return;
        self.listed[i].woken = true;
        self.wake.push(self.gpa, i) catch unreachable;
    }

    fn settled(self: *Engine, i: usize) void {
        for (self.g.children[i]) |c| self.wakeTask(c);
    }

    fn listActive(self: *Engine, i: usize) void {
        if (self.listed[i].active) return;
        self.listed[i].active = true;
        self.active.appendAssumeCapacity(i);
    }

    fn listStaged(self: *Engine, i: usize) void {
        if (self.listed[i].staged) return;
        self.listed[i].staged = true;
        self.staged.appendAssumeCapacity(i);
    }

    fn listReady(self: *Engine, i: usize) void {
        if (self.listed[i].ready) return;
        self.listed[i].ready = true;
        self.ready_list.appendAssumeCapacity(i);
    }

    fn keepListed(self: *Engine, list: *std.ArrayList(usize), status: Status, comptime flag: []const u8) void {
        var kept: usize = 0;
        for (list.items) |i| {
            if (self.tasks[i].status == status) {
                list.items[kept] = i;
                kept += 1;
            } else @field(self.listed[i], flag) = false;
        }
        list.shrinkRetainingCapacity(kept);
    }

    fn updateReadiness(self: *Engine) !void {
        const Cause = struct { root: ?usize, first: usize, count: usize };
        var causes: std.ArrayList(Cause) = .empty;
        defer causes.deinit(self.gpa);
        while (self.wake.pop()) |i| {
            self.listed[i].woken = false;
            const t = &self.tasks[i];
            if (t.status != .pending) continue;
            switch (schedule.parents(self.tasks, self.g.parents[i])) {
                .blocked => {
                    const root = self.rootOf(i);
                    self.blocked_by[i] = root orelse i;
                    self.setStatus(i, .blocked);
                    t.reason = "it needs a rule that did not complete";
                    self.finished += 1;
                    self.settled(i);
                    self.events.emit("task_blocked", .{ .rule = self.rule(i).name });
                    for (causes.items) |*c| {
                        if (c.root == root) {
                            c.count += 1;
                            break;
                        }
                    } else try causes.append(self.gpa, .{ .root = root, .first = i, .count = 1 });
                },
                .waiting => {},
                .ready => if (!self.stopping) try self.makeReady(i),
            }
        }
        for (causes.items) |c| {
            const w = self.log.text();
            if (c.root) |r| w.print("after {s} {s}", .{ self.names.word[r], self.rootText(r) }) catch {} else w.writeAll("after a rule it needs did not complete") catch {};
            if (c.count > 1) {
                w.writeAll(", with ") catch {};
                logging.thousands(w, c.count - 1) catch {};
                w.print(" more {s}", .{if (c.count == 2) "rule" else "rules"}) catch {};
            }
            self.say(.blocked, c.first, .{});
        }
    }

    fn makeReady(self: *Engine, i: usize) !void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        var missing: ?[]const u8 = null;
        var unreadable = false;
        const key = state.ruleKey(self.a, self.ids, self.wf, self.g.parents[i], i, self.st, self.cut, TaskKeys{ .tasks = self.tasks }, self.env_text, self.engine_id, self.extras[i], &missing) catch |err| switch (err) {
            error.Unreadable => blk: {
                unreadable = true;
                break :blk null;
            },
            else => return err,
        };
        if (key == null) {
            self.setStatus(i, .failed);
            t.reason = if (unreadable) self.ids.problem else try std.fmt.allocPrint(self.a, "missing input {s}", .{missing.?});
            self.finished += 1;
            self.settled(i);
            self.events.emit("task_failed", .{ .rule = r.name, .attempt = @as(?u32, null), .reason = t.reason });
            const w = self.log.text();
            if (unreadable) w.writeAll(t.reason) catch {} else w.print("missing input {s}", .{monitor.shownPath(self.a, missing.?)}) catch {};
            self.say(.failed, i, .{});
            self.stopAfter(i);
            return;
        }
        t.key = key.?;
        if (!self.opts.forced(r.name)) if (self.st.data.rules.map.get(r.name)) |e| {
            if (try state.reuseCheck(self.gpa, self.ids, &e, &key.?) == .reuse) {
                if (!self.st.data.envs.map.contains(e.env)) {
                    const sa = self.st.allocator();
                    try self.st.data.envs.map.put(sa, try sa.dupe(u8, e.env), try sa.dupe(u8, self.env_text));
                    try self.pending_envs.append(self.gpa, e.env);
                    self.dirty = true;
                }
                self.setStatus(i, .reused);
                self.finished += 1;
                self.settled(i);
                self.events.emit("task_reused", .{ .rule = r.name });
                return;
            }
        };
        self.setStatus(i, .ready);
        self.listReady(i);
        self.ready_counter += 1;
        self.ready_seq[i] = self.ready_counter;
        t.ready_ns = sys.monoNs();
    }

    // --- Admission ---

    fn need(self: *Engine, i: usize) schedule.Need {
        const r = self.rule(i);
        return .{ .threads = r.threads, .memory_mib = reservedMib(r), .groups = self.group_needs[i] };
    }

    fn neverFits(self: *Engine, i: usize) ?[]const u8 {
        const r = self.rule(i);
        var mib = reservedMib(r);
        for (r.shared_index) |hi| mib += self.holders[hi].reserve_mib;
        if (!schedule.neverFits(self.budget, r.threads, mib)) return null;
        return std.fmt.allocPrint(self.a, "it needs {d} threads and {d} MiB; the run allows {d} threads and {d} MiB", .{ r.threads, mib, self.budget.threads, self.budget.memory_mib }) catch "it needs more than the run allows";
    }

    fn blocker(self: *Engine, i: usize) ?[]const u8 {
        return self.blockerFreeing(i, 0);
    }

    fn blockerFreeing(self: *Engine, i: usize, freed_mib: u64) ?[]const u8 {
        var n = self.need(i);
        for (self.rule(i).shared_index) |hi| {
            const h = &self.holders[hi];
            if (!h.held) n.memory_mib += h.reserve_mib;
        }
        return switch (schedule.blocker(self.budget, self.usage, n, freed_mib) orelse return null) {
            .threads => "threads",
            .memory => "memory",
            .jobs => "jobs",
            .group => |gi| self.group_reasons[gi],
        };
    }

    fn setWait(self: *Engine, i: usize, reason: ?[]const u8) !void {
        const t = &self.tasks[i];
        if (t.wait_reason) |cur| {
            if (reason != null and std.mem.eql(u8, cur, reason.?)) return;
            try self.closeWait(t, cur);
        }
        t.wait_reason = reason;
        t.wait_since = sys.monoNs();
        if (reason) |why| self.events.emit("task_waiting", .{ .rule = self.rule(i).name, .reason = why, .threads = self.rule(i).threads, .memory_mib = self.rule(i).memory_mib });
    }

    fn endWait(self: *Engine, i: usize) !void {
        const t = &self.tasks[i];
        if (t.wait_reason) |cur| if (budgetReason(cur) and self.freed_ns > t.wait_since) {
            const s = @as(f64, @floatFromInt(self.freed_ns - t.wait_since)) / 1e9;
            try self.addWait(t, cur, s);
            t.wait_reason = "starting";
            t.wait_since = self.freed_ns;
        };
        try self.setWait(i, null);
    }

    fn closeWait(self: *Engine, t: *Task, reason: []const u8) !void {
        try self.addWait(t, reason, @as(f64, @floatFromInt(sys.monoNs() - t.wait_since)) / 1e9);
    }

    fn addWait(self: *Engine, t: *Task, reason: []const u8, s: f64) !void {
        for (t.waits.items) |*w| if (std.mem.eql(u8, w.reason, reason)) {
            w.seconds += s;
            return;
        };
        try t.waits.append(self.a, .{ .reason = reason, .seconds = s });
    }

    fn reserve(self: *Engine, i: usize, take: bool) void {
        if (take) self.usage.take(self.need(i)) else {
            self.usage.give(self.need(i));
            self.freed_ns = sys.monoNs();
        }
    }

    fn admit(self: *Engine) !void {
        if (self.stopping) return;
        var ready: std.ArrayList(usize) = .empty;
        defer ready.deinit(self.gpa);
        self.keepListed(&self.ready_list, .ready, "ready");
        try ready.appendSlice(self.gpa, self.ready_list.items);
        if (ready.items.len > 1 and self.ranks.len == 0) try self.computeRanks();
        std.mem.sortUnstable(usize, ready.items, self.order(), schedule.Order.before);
        for (ready.items) |i| {
            if (self.stopping) break;
            if (self.neverFits(i)) |why| {
                try self.setWait(i, null);
                self.endUnstarted(i, false, null, .failed, why);
                continue;
            }
            if (self.blocker(i)) |why| {
                const idle = self.idleMib(i);
                if (std.mem.eql(u8, why, "memory") and idle > 0 and self.blockerFreeing(i, idle) == null) self.releaseIdle(i);
                try self.setWait(i, why);
                continue;
            }
            self.reserve(i, true);
            self.setStatus(i, .staging);
            self.listStaged(i);
            const r = self.rule(i);
            var waiting = false;
            var failure: ?[]const u8 = null;
            for (r.shared_index) |hi| {
                const h = &self.holders[hi];
                if (!h.held) self.usage.memory_mib += h.reserve_mib;
                h.held = true;
                h.users += 1;
            }
            for (r.shared_index) |hi| {
                const h = &self.holders[hi];
                if (h.st == .failed and h.failure != null) failure = h.failure;
                if (h.st == .idle) try self.startHolderOrFail(hi);
                if (self.tasks[i].status != .staging) break;
                if (h.st != .ready) waiting = true;
            }
            if (self.tasks[i].status != .staging) continue;
            if (failure) |why| {
                try self.setWait(i, null);
                self.failStaged(i, why);
            } else if (waiting) {
                const name = for (r.shared_index) |hi| {
                    if (self.holders[hi].st != .ready) break self.wf.shared[hi].name;
                } else unreachable;
                try self.setWait(i, try std.fmt.allocPrint(self.a, "loading shared:{s}", .{name}));
            } else try self.start(i);
        }
    }

    fn computeRanks(self: *Engine) !void {
        const n = self.wf.rules.len;
        const steps = try self.a.alloc([]const u8, n);
        const walls = try self.a.alloc(f64, n);
        for (self.wf.rules, steps, walls) |r, *s, *w| {
            s.* = r.labels.step;
            w.* = if (self.st.data.rules.map.get(r.name)) |e| e.wall_s else 0;
        }
        self.ranks = try schedule.ranks(self.a, self.g.order, self.g.children, try schedule.estimates(self.a, steps, walls));
    }

    fn order(self: *Engine) schedule.Order {
        return .{ .priorities = self.priorities, .ranks = self.ranks, .ready_seq = self.ready_seq };
    }

    // --- Starting attempts ---

    fn start(self: *Engine, i: usize) !void {
        self.prepareAndSpawn(i) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.failToStart(i, try std.fmt.allocPrint(self.a, "cannot prepare the attempt: {s}", .{sys.errorText(err)}));
        };
    }

    fn prepareAndSpawn(self: *Engine, i: usize) !void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        t.attempts += 1;
        t.cg = null;
        t.anon_peak = null;
        t.stop_why = "cancelled";
        t.dir = try std.fmt.allocPrint(self.a, "{s}/attempts/{s}/{d:0>3}", .{ self.launch_dir, r.name, t.attempts });
        try sys.mkdirAll(self.gpa, t.dir);
        t.timed_out = false;
        t.cancelled = false;
        t.lost_service = null;
        t.spawned = false;
        t.kill_at = null;
        t.ended = null;
        try self.endWait(i);
        t.queued_s = @as(f64, @floatFromInt(sys.monoNs() - t.ready_ns)) / 1e9;
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const script = try std.fmt.allocPrint(sa, "{s}/command.sh", .{t.dir});
        const body = if (r.container != null)
            try container.script(sa, r.shell)
        else
            try std.fmt.allocPrint(sa, "#!/usr/bin/env bash\nset -euo pipefail\n{s}\n", .{r.shell});
        try sys.writeFile(self.gpa, script, body);
        try records.writeJsonNew(self.gpa, try std.fmt.allocPrint(sa, "{s}/request.json", .{t.dir}), .{
            .v = records.record_version,
            .rule = r.name,
            .attempt = t.attempts,
            .shell = r.shell,
            .threads = r.threads,
            .memory_mib = r.memory_mib,
            .groups = r.groups,
            .shared = r.shared,
            .input = r.input,
            .output = r.output,
            .timeout_s = self.timeoutOf(r),
        });

        try self.journal.mark(self.gpa, "dispatch", r.name);

        for (r.output_abs, 0..) |o, k| {
            if (try sys.lstat(self.gpa, o)) |id| {
                const prev = try std.fmt.allocPrint(sa, "{s}/previous", .{t.dir});
                try sys.mkdir(self.gpa, prev);
                const dest = try std.fmt.allocPrint(sa, "{s}/{d}-{s}", .{ prev, k, std.fs.path.basename(o) });
                sys.rename(self.gpa, o, dest) catch |err|
                    return self.failToStart(i, try std.fmt.allocPrint(self.a, "cannot move its earlier output {s} into previous/: {s}", .{ r.output[k], sys.errorText(err) }));
                self.events.emit("output_preserved", .{ .rule = r.name, .path = r.output[k], .moved_to = dest, .bytes = id.size });
                self.previous_bytes += id.size;
            }
            self.ids.forget(o);
            if (std.fs.path.dirname(o)) |d| try sys.mkdirAll(self.gpa, d);
        }

        if (r.workdir_abs) |d| if (try self.prepareWorkdir(r, d)) |why| return self.failToStart(i, why);

        const out_fd = try sys.openWrite(self.gpa, try std.fmt.allocPrint(sa, "{s}/stdout.log", .{t.dir}), .truncate);
        defer sys.close(out_fd);
        const err_fd = try sys.openWrite(self.gpa, try std.fmt.allocPrint(sa, "{s}/stderr.log", .{t.dir}), .truncate);
        defer sys.close(err_fd);

        var procs: sys.Fd = -1;
        t.cg = null;
        if (self.tree) |tree| {
            const name = try std.fmt.allocPrint(sa, "task-{d}-{d}", .{ i, t.attempts });
            t.cg = try cgroup.create(self.gpa, self.a, tree, name, .{ .memory_bytes = r.memory_mib * 1024 * 1024, .threads = r.threads, .oom_group = true });
            procs = try (if (r.container != null) self.containers_cg.? else t.cg.?).openProcs();
        }
        defer if (procs >= 0) sys.close(procs);

        var spec: process.Spec = undefined;
        t.container_name = null;
        if (r.container) |img| {
            const name = try std.fmt.allocPrint(self.a, "workz-{s}-{d}-{d}", .{ self.launch_id, i, t.attempts });
            var extra_ro: std.ArrayList([]const u8) = .empty;
            for (r.shared_index) |hi| if (self.wf.shared[hi].path_abs) |p| try extra_ro.append(sa, p);
            const argv = try container.runArgv(sa, .{
                .podman = self.podman.?,
                .name = name,
                .image_id = self.images.get(img).?,
                .root = self.wf.root,
                .launch = self.launch_id,
                .cgroup_parent = if (t.cg) |cg| cg.path["/sys/fs/cgroup".len..] else null,
                .mounts = try container.mounts(sa, self.wf.root, r, extra_ro.items),
                .env = try self.containerEnv(sa, &try ruleVars(sa, r, t.dir)),
                .ipc_service = self.serviceOf(r),
                .image_mounts = r.mounts,
                .workdir = r.workdir_abs,
                .script = script,
            });
            t.container_name = name;
            spec = .{
                .path = (try sa.dupeZ(u8, self.podman.?)).ptr,
                .argv = (try process.Vec.init(sa, argv)).items.ptr,
                .envp = self.envp.items.ptr,
                .cwd = (try sa.dupeZ(u8, r.workdir_abs orelse self.wf.root)).ptr,
                .stdin = self.devnull,
                .stdout = out_fd,
                .stderr = err_fd,
                .cgroup_procs = procs,
            };
        } else {
            const env = try self.taskEnv(sa, r, t.dir);
            const argv = try process.Vec.init(sa, &.{ "bash", "-euo", "pipefail", script });
            spec = .{
                .path = self.bash.ptr,
                .argv = argv.items.ptr,
                .envp = env.items.ptr,
                .cwd = (try sa.dupeZ(u8, r.workdir_abs orelse self.wf.root)).ptr,
                .stdin = self.devnull,
                .stdout = out_fd,
                .stderr = err_fd,
                .cgroup_procs = procs,
                .userns = if (self.network) |n| n.userns else -1,
                .netns = if (self.network) |n| n.netns else -1,
            };
        }
        t.pid = process.spawn(&spec) catch |err| {
            return self.failToStart(i, try std.fmt.allocPrint(self.a, "cannot start: {s} ({s})", .{ sys.errorText(err), sys.errnoName() }));
        };
        t.spawned = true;
        self.setStatus(i, .running);
        self.listActive(i);
        try self.by_pid.put(self.gpa, t.pid, i);
        if (self.guard) |gd| gd.note('+', t.pid);
        self.queueVersion(i) catch {};
        for (r.shared_index) |hi| self.holders[hi].served += 1;
        t.started_ns = sys.monoNs();
        t.started_real = sys.realNs();
        t.engine_rss_kib = engineMaxRssKib();
        t.deadline_ns = schedule.deadline(t.started_ns, self.timeoutOf(r));
        self.events.emit("task_started", .{ .rule = r.name, .attempt = t.attempts, .pid = t.pid, .cgroup = if (t.cg) |cg| cg.path else null, .directory = t.dir, .threads = r.threads, .memory_mib = r.memory_mib, .waited_s = t.queued_s, .shared = r.shared });
        const w = self.log.text();
        if (t.max_attempts > 1) w.print("attempt {d} of {d}", .{ t.attempts, t.max_attempts }) catch {};
        if (t.queued_s >= 1) {
            w.writeAll(if (t.max_attempts > 1) ", waited " else "waited ") catch {};
            units.duration(w, t.queued_s) catch {};
        }
        self.say(.started, i, self.request(i));
    }

    fn timeoutOf(self: *Engine, r: *const workflow.Rule) ?u64 {
        return r.timeout_s orelse self.opts.timeout_s;
    }

    fn failToStart(self: *Engine, i: usize, reason: []const u8) void {
        self.restorePrevious(i) catch {};
        const t = &self.tasks[i];
        if (schedule.retried(t.attempts, t.max_attempts, false, self.stopping, false)) {
            const r = self.rule(i);
            self.writeUnstartedRecord(i, t.attempts, .failed, reason);
            if (t.cg) |cg| cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg.path) catch {};
            t.cg = null;
            self.reserve(i, false);
            self.setStatus(i, .ready);
            self.listReady(i);
            self.releaseShared(i);
            self.ready_counter += 1;
            self.ready_seq[i] = self.ready_counter;
            t.ready_ns = sys.monoNs();
            t.waits = .empty;
            t.wait_reason = null;
            self.events.emit("task_finished", .{ .rule = r.name, .attempt = t.attempts, .status = "failed", .reason = reason });
            self.events.emit("task_retry", .{ .rule = r.name, .next_attempt = t.attempts + 1 });
            self.log.text().print("{s}, attempt {d} of {d}", .{ reason, t.attempts, t.max_attempts }) catch {};
            self.say(.retrying, i, self.request(i));
            return;
        }
        self.endUnstarted(i, true, t.attempts, .failed, reason);
    }

    fn writeUnstartedRecord(self: *Engine, i: usize, n: u32, status: Status, reason: []const u8) void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        if (t.dir.len == 0) return;
        records.writeJson(self.gpa, std.fmt.allocPrint(self.a, "{s}/record.json", .{t.dir}) catch return, .{
            .v = records.record_version,
            .rule = r.name,
            .attempt = n,
            .status = @tagName(status),
            .reason = reason,
            .started = @as(?[]const u8, null),
            .finished = records.timeText(self.a, sys.realNs()) catch "",
            .wall_s = @as(f64, 0),
            .request = .{ .threads = r.threads, .memory_mib = r.memory_mib, .reserved_mib = reservedMib(r), .groups = r.groups, .shared = r.shared, .container = r.container },
            .labels = r.labels,
            .outputs = &[_]state.Output{},
            .key = if (t.key) |k| k.key else null,
        }) catch {};
    }

    fn restorePrevious(self: *Engine, i: usize) !void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        const entry = self.st.data.rules.map.getPtr(r.name);
        for (r.output_abs, r.output, 0..) |o, written, k| {
            const name = try std.fmt.allocPrint(self.a, "{d}-{s}", .{ k, std.fs.path.basename(o) });
            const prev = try std.fs.path.join(self.a, &.{ t.dir, "previous", name });
            const kept = try sys.lstat(self.gpa, prev);
            if (kept != null or t.spawned) if (try sys.lstat(self.gpa, o)) |left| {
                const failed_dir = try std.fs.path.join(self.a, &.{ t.dir, "failed" });
                sys.mkdir(self.gpa, failed_dir) catch |err| if (err != error.PathAlreadyExists) return err;
                const dest = try std.fs.path.join(self.a, &.{ failed_dir, name });
                try sys.rename(self.gpa, o, dest);
                self.ids.forget(o);
                self.events.emit("output_failed", .{ .rule = r.name, .path = written, .moved_to = dest, .bytes = left.size });
            };
            const kept_id = kept orelse continue;
            try sys.rename(self.gpa, prev, o);
            self.ids.forget(o);
            self.previous_bytes -|= kept_id.size;
            self.events.emit("output_restored", .{ .rule = r.name, .path = written, .moved_from = prev, .bytes = kept_id.size });
            const e = entry orelse continue;
            const sa = self.st.allocator();
            const outs = try sa.dupe(state.Output, e.outputs);
            for (outs) |*out| if (std.mem.eql(u8, out.path, o)) {
                const id = (try self.ids.get(o)) orelse continue;
                out.id = try sa.dupe(u8, id);
            };
            e.outputs = outs;
            self.dirty = true;
        }
    }

    fn endUnstarted(self: *Engine, i: usize, admitted: bool, attempt: ?u32, status: Status, reason: []const u8) void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        if (t.cg) |cg| cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg.path) catch {};
        t.cg = null;
        if (admitted) {
            self.reserve(i, false);
            self.releaseShared(i);
        }
        self.setStatus(i, status);
        t.reason = reason;
        self.finished += 1;
        self.settled(i);
        if (attempt) |n| self.writeUnstartedRecord(i, n, status, reason);
        if (status == .failed) {
            self.events.emit("task_failed", .{ .rule = r.name, .attempt = attempt, .reason = reason });
            self.log.text().writeAll(reason) catch {};
            self.say(.failed, i, .{});
            self.stopAfter(i);
        } else {
            self.events.emit("task_finished", .{ .rule = r.name, .attempt = attempt, .status = "cancelled", .reason = reason });
            self.stopDetail(self.log.text(), reason);
            self.say(.cancelled, i, .{});
        }
    }

    fn prepareWorkdir(self: *Engine, r: *const workflow.Rule, dir: []const u8) !?[]const u8 {
        sys.mkdirAll(self.gpa, dir) catch |err|
            return try std.fmt.allocPrint(self.a, "cannot make workdir {s}: {s}", .{ r.workdir.?, sys.errorText(err) });
        for (r.links) |l| {
            const path = try std.fs.path.join(self.a, &.{ dir, l.name });
            if (try sys.lstat(self.gpa, path)) |id| {
                if (id.mode & 0o170000 != 0o120000) return try std.fmt.allocPrint(self.a, "link {s} in workdir {s} would replace a file that is not a link", .{ l.name, r.workdir.? });
                _ = try sys.check(linux.unlinkat(linux.AT.FDCWD, try self.a.dupeZ(u8, path), 0));
            }
            _ = sys.check(linux.symlinkat(try self.a.dupeZ(u8, l.target_abs), linux.AT.FDCWD, try self.a.dupeZ(u8, path))) catch |err|
                return try std.fmt.allocPrint(self.a, "cannot make link {s}: {s}", .{ l.name, sys.errorText(err) });
        }
        return null;
    }

    fn containerEnv(self: *Engine, a: Allocator, extra: []const []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.envp.items) |e| {
            const kv = std.mem.span(e.?);
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const name = kv[0..eq];
            const keyed = for (state.keyed_env) |k| {
                if (std.mem.eql(u8, k, "PATH")) continue;
                if (std.mem.eql(u8, k, name)) break true;
            } else false;
            const passed = for (self.opts.pass_env) |k| {
                if (std.mem.eql(u8, k, name)) break true;
            } else false;
            if (passed) try list.append(a, name) else if (keyed) try list.append(a, kv);
        }
        try list.appendSlice(a, extra);
        return list.items;
    }

    fn taskEnv(self: *Engine, a: Allocator, r: *const workflow.Rule, dir: []const u8) !process.Vec {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.envp.items) |e| try list.append(a, std.mem.span(e.?));
        try list.appendSlice(a, &try ruleVars(a, r, dir));
        return process.Vec.init(a, list.items);
    }

    fn ruleVars(a: Allocator, r: *const workflow.Rule, dir: []const u8) ![4][]const u8 {
        return .{
            try std.fmt.allocPrint(a, "WORKZ_RULE={s}", .{r.name}),
            try std.fmt.allocPrint(a, "WORKZ_ATTEMPT_DIR={s}", .{dir}),
            try std.fmt.allocPrint(a, "WORKZ_THREADS={d}", .{r.threads}),
            try std.fmt.allocPrint(a, "WORKZ_MEMORY_MIB={d}", .{r.memory_mib}),
        };
    }

    // --- Shared input holders ---

    fn startHolder(self: *Engine, hi: usize) !void {
        self.holders[hi].starts += 1;
        self.holders[hi].started_ns = sys.monoNs();
        if (self.wf.shared[hi].isService()) return self.startService(hi);
        const h = &self.holders[hi];
        const s = self.wf.shared[hi];
        const argv = try process.Vec.init(self.a, &.{ "kanit", "__hold", s.path_abs.? });
        const exe = try sys.childExe(self.a);

        var pipe: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
        defer sys.close(pipe[1]);
        errdefer sys.close(pipe[0]);
        var procs: sys.Fd = -1;
        errdefer if (h.cg) |cg| {
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg.path) catch {};
            h.cg = null;
        };
        if (self.tree) |tree| {
            h.cg = try cgroup.create(self.gpa, self.a, tree, try std.fmt.allocPrint(self.a, "shared-{s}-{d}", .{ s.name, h.starts }), .{});
            procs = try h.cg.?.openProcs();
        }
        defer if (procs >= 0) sys.close(procs);
        const spec: process.Spec = .{
            .path = exe.ptr,
            .argv = argv.items.ptr,
            .envp = self.envp.items.ptr,
            .cwd = "/",
            .stdin = self.devnull,
            .stdout = pipe[1],
            .stderr = 2,
            .cgroup_procs = procs,
        };
        h.pid = try process.spawn(&spec);
        if (self.guard) |gd| gd.note('+', h.pid);
        h.pipe = pipe[0];
        h.st = .loading;
        self.events.emit("shared_loading", .{ .name = s.name, .path = s.path, .bytes = h.bytes, .pid = h.pid, .cgroup = if (h.cg) |cg| cg.path else null });
        self.log.text().writeAll("loading") catch {};
        self.log.emit(.shared, .{ .step = s.name }, .{ .request_mib = h.mib });
    }

    fn startService(self: *Engine, hi: usize) !void {
        const h = &self.holders[hi];
        const s = self.wf.shared[hi];
        const dir = try std.fmt.allocPrint(self.a, "{s}/shared", .{self.launch_dir});
        try sys.mkdirAll(self.gpa, dir);
        const script = try std.fmt.allocPrint(self.a, "{s}/{s}-{d}.sh", .{ dir, s.name, h.starts });
        try sys.writeFile(self.gpa, script, try container.serviceScript(self.a, s.command.?));
        const log_fd = try sys.openWrite(self.gpa, try std.fmt.allocPrint(self.a, "{s}/{s}-{d}.stderr.log", .{ dir, s.name, h.starts }), .truncate);
        defer sys.close(log_fd);
        const fifo = try std.fmt.allocPrint(self.a, "{s}/{s}-{d}.stop", .{ dir, s.name, h.starts });
        const stop_fd = try sys.openFifo(self.gpa, fifo);
        errdefer sys.close(stop_fd);

        var procs: sys.Fd = -1;
        errdefer if (h.cg) |cg| {
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg.path) catch {};
            h.cg = null;
        };
        if (self.tree) |tree| {
            h.cg = try cgroup.create(self.gpa, self.a, tree, try std.fmt.allocPrint(self.a, "shared-{s}-{d}", .{ s.name, h.starts }), .{ .memory_bytes = h.mib * 1024 * 1024, .oom_group = true });
            procs = try self.containers_cg.?.openProcs();
        }
        defer if (procs >= 0) sys.close(procs);
        const name = try std.fmt.allocPrint(self.a, "workz-{s}-shared-{s}-{d}", .{ self.launch_id, s.name, h.starts });
        var ro: std.ArrayList(container.Mount) = .empty;
        try ro.append(self.a, .{ .dir = self.wf.root, .write = false });
        if (s.path_abs) |pth| if (!workflow.within(self.wf.root, pth)) try ro.append(self.a, .{ .dir = pth, .write = false });
        const argv = try container.runArgv(self.a, .{
            .podman = self.podman.?,
            .name = name,
            .image_id = self.images.get(s.container.?).?,
            .root = self.wf.root,
            .launch = self.launch_id,
            .cgroup_parent = if (h.cg) |cg| cg.path["/sys/fs/cgroup".len..] else null,
            .mounts = ro.items,
            .env = try self.containerEnv(self.a, &.{
                try std.fmt.allocPrint(self.a, "WORKZ_SHARED={s}", .{s.name}),
                try std.fmt.allocPrint(self.a, "WORKZ_MEMORY_MIB={d}", .{h.mib}),
                try std.fmt.allocPrint(self.a, "WORKZ_SERVICE_STOP={s}", .{fifo}),
            }),
            .service = true,
            .image_mounts = s.mounts,
            .script = script,
        });

        var out: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&out, .{ .CLOEXEC = true }));
        defer sys.close(out[1]);
        errdefer sys.close(out[0]);
        const spec: process.Spec = .{
            .path = (try self.a.dupeZ(u8, self.podman.?)).ptr,
            .argv = (try process.Vec.init(self.a, argv)).items.ptr,
            .envp = self.envp.items.ptr,
            .cwd = "/",
            .stdin = self.devnull,
            .stdout = out[1],
            .stderr = log_fd,
            .cgroup_procs = procs,
        };
        h.pid = try process.spawn(&spec);
        if (self.guard) |gd| gd.note('+', h.pid);
        h.pipe = out[0];
        h.stop_fd = stop_fd;
        h.container_name = name;
        h.st = .loading;
        h.timed_out = false;
        h.ready_deadline = if (s.timeout_s) |t| sys.monoNs() + @as(i128, t) * std.time.ns_per_s else null;
        self.events.emit("shared_loading", .{ .name = s.name, .container = name, .memory_mib = h.mib, .reserved_mib = h.reserve_mib, .pid = h.pid, .cgroup = if (h.cg) |cg| cg.path else null });
        self.log.text().writeAll("starting the service") catch {};
        self.log.emit(.shared, .{ .step = s.name }, .{ .request_mib = h.mib });
    }

    fn stopHolder(self: *Engine, h: *Holder) void {
        h.st = .stopping;
        if (h.stop_fd >= 0) {
            sys.close(h.stop_fd);
            h.stop_fd = -1;
        }
        if (h.container_name) |name| {
            if (h.pipe >= 0) self.helper(container.stopAsync(self.a, self.podman.?, name, self.opts.grace_s, &self.envp, self.devnull));
        } else process.signalPid(h.pid, .TERM);
        h.kill_at = sys.monoNs() + (@as(i128, self.opts.grace_s) + 10) * std.time.ns_per_s;
    }

    fn holderReady(self: *Engine, hi: usize) !void {
        const h = &self.holders[hi];
        var buf: [128]u8 = undefined;
        const n = sys.read(h.pipe, &buf) catch 0;
        sys.close(h.pipe);
        h.pipe = -1;
        if (h.timed_out or h.st == .stopping) return;
        h.ready_deadline = null;
        if (n == 0 or !std.mem.startsWith(u8, buf[0..n], "ready")) {
            if (h.pid > 0) self.stopHolder(h);
            h.st = .failed;
            return;
        }
        h.st = .ready;
        const file = if (h.cg) |cg| cg.stat("file") else null;
        self.events.emit("shared_loaded", .{ .name = self.wf.shared[hi].name, .bytes = h.bytes, .holder_file_bytes = file });
        self.log.text().writeAll("ready") catch {};
        self.log.emit(.shared, .{ .step = self.wf.shared[hi].name }, .{ .took_s = @as(f64, @floatFromInt(sys.monoNs() - h.started_ns)) / 1e9 });
        for (self.tasks, 0..) |*t, i| {
            if (t.status != .staging) continue;
            if (self.sharedReady(i)) try self.start(i);
        }
    }

    fn serviceOf(self: *Engine, r: *const workflow.Rule) ?[]const u8 {
        for (r.shared_index) |hi| {
            const h = self.holders[hi];
            if (h.container_name) |name| return name;
        }
        return null;
    }

    fn sharedReady(self: *Engine, i: usize) bool {
        for (self.rule(i).shared_index) |hi| if (self.holders[hi].st != .ready) return false;
        return true;
    }

    fn releaseShared(self: *Engine, i: usize) void {
        for (self.rule(i).shared_index) |hi| {
            const h = &self.holders[hi];
            h.users -= 1;
            if (h.users == 0 and (self.stopping or !self.holderNeeded(hi))) self.releaseHolder(hi);
        }
    }

    fn holderNeeded(self: *Engine, hi: usize) bool {
        for (self.tasks, 0..) |t, i| {
            if (t.status != .pending and t.status != .ready) continue;
            if (std.mem.indexOfScalar(usize, self.rule(i).shared_index, hi) != null) return true;
        }
        return false;
    }

    fn releaseHolder(self: *Engine, hi: usize) void {
        const h = &self.holders[hi];
        if (h.pid > 0 and (h.st == .loading or h.st == .ready)) {
            self.stopHolder(h);
        } else if (h.pid == 0 and h.held) {
            self.usage.memory_mib -= h.reserve_mib;
            self.freed_ns = sys.monoNs();
            h.held = false;
        }
    }

    fn idleMib(self: *Engine, i: usize) u64 {
        var mib: u64 = 0;
        for (self.holders, 0..) |h, hi| {
            if (h.users > 0 or !h.held or h.st == .stopping) continue;
            const uses = std.mem.indexOfScalar(usize, self.rule(i).shared_index, hi) != null;
            if (!uses) mib += h.reserve_mib;
        }
        return mib;
    }

    fn releaseIdle(self: *Engine, i: ?usize) void {
        for (self.holders, 0..) |h, hi| {
            if (h.users > 0 or !h.held or h.st == .stopping) continue;
            if (i) |ri| {
                const uses = std.mem.indexOfScalar(usize, self.rule(ri).shared_index, hi) != null;
                if (uses) continue;
            } else if (!self.stopping and self.holderNeeded(hi)) continue;
            self.releaseHolder(hi);
        }
    }

    fn holderExited(self: *Engine, hi: usize, reaped: process.Reaped) !void {
        const h = &self.holders[hi];
        const s = self.wf.shared[hi];
        const was = h.st;
        if (self.guard) |gd| gd.note('-', h.pid);
        h.pid = 0;
        h.kill_at = null;
        for ([_]*sys.Fd{ &h.pipe, &h.stop_fd }) |fd| if (fd.* >= 0) {
            sys.close(fd.*);
            fd.* = -1;
        };
        var counters: ?cgroup.Counters = null;
        if (h.cg) |cg| {
            counters = cg.counters();
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg.path) catch {};
            h.cg = null;
        }
        const code = reaped.exitCode();
        if (h.container_name) |name| {
            if (code == null or code.? != 0) self.helper(container.removeAsync(self.a, self.podman.?, name, &self.envp, self.devnull));
            h.container_name = null;
        }
        const peak = if (counters) |c| c.memory_peak else null;
        if (h.held and h.users == 0) {
            self.usage.memory_mib -= h.reserve_mib;
            self.freed_ns = sys.monoNs();
            h.held = false;
        }
        if (was == .stopping) {
            h.st = .idle;
            self.events.emit("shared_released", .{ .name = s.name, .memory_peak = peak, .cpu_s = taskCpu(counters, reaped), .users = h.served, .held_s = @as(f64, @floatFromInt(sys.monoNs() - h.started_ns)) / 1e9 });
            h.served = 0;
            if (h.users > 0) try self.startHolderOrFail(hi);
            return;
        }
        h.st = .failed;
        var why: []const u8 = "the holder ended";
        if (h.timed_out) {
            why = try std.fmt.allocPrint(self.a, "did not become ready within {d} s", .{s.timeout_s.?});
        } else if (counters != null and counters.?.oom_kill > 0) {
            why = try std.fmt.allocPrint(self.a, "out of memory: could not stay within its {d} MiB", .{h.mib});
        } else if (s.isService()) {
            const log = try std.fmt.allocPrint(self.a, "{s}/shared/{s}-{d}.stderr.log", .{ self.launch_dir, s.name, h.starts });
            const last = try self.lastLineOf(log);
            const when = if (was == .ready) "after it was ready" else "before it was ready";
            why = if (code) |c|
                try std.fmt.allocPrint(self.a, "exited with status {d} {s}: {s}", .{ c, when, last })
            else
                try std.fmt.allocPrint(self.a, "killed by signal {d} {s}: {s}", .{ reaped.signal() orelse 0, when, last });
        }
        if (was != .ready and h.failed_starts < s.retries and h.users > 0 and !self.stopping) {
            h.failed_starts += 1;
            self.events.emit("shared_retry", .{ .name = s.name, .reason = why, .next_start = h.starts + 1 });
            self.log.text().print("restarting: {s}", .{why}) catch {};
            self.log.emit(.shared, .{ .step = s.name }, .{});
            try self.startHolderOrFail(hi);
            return;
        }
        try self.failHolder(hi, why, peak);
    }

    fn startHolderOrFail(self: *Engine, hi: usize) !void {
        self.startHolder(hi) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try self.failHolder(hi, try std.fmt.allocPrint(self.a, "could not start: {s}", .{sys.errorText(err)}), null),
        };
    }

    fn failHolder(self: *Engine, hi: usize, why: []const u8, peak: ?u64) !void {
        const h = &self.holders[hi];
        const s = self.wf.shared[hi];
        h.st = .failed;
        h.failure = try std.fmt.allocPrint(self.a, "shared input {s} could not be loaded: {s}", .{ s.name, why });
        self.events.emit("shared_failed", .{ .name = s.name, .reason = why, .memory_peak = peak });
        self.log.text().print("failed: {s}", .{why}) catch {};
        self.log.emit(.shared, .{ .step = s.name }, .{});
        const lost = try std.fmt.allocPrint(self.a, "shared service {s} failed while the rule used it: {s}", .{ s.name, why });
        for (self.tasks, 0..) |*t, i| {
            if (std.mem.indexOfScalar(usize, self.rule(i).shared_index, hi) == null) continue;
            if (t.status == .staging) self.failStaged(i, h.failure.?);
            if (t.status == .running and s.isService() and t.lost_service == null) {
                t.lost_service = lost;
                self.terminate(t, @as(i128, self.opts.grace_s) * std.time.ns_per_s);
                self.events.emit("task_cancelling", .{ .rule = self.rule(i).name });
            }
        }
    }

    fn failStaged(self: *Engine, i: usize, reason: []const u8) void {
        self.endUnstarted(i, true, null, .failed, reason);
    }

    // --- Finishing attempts ---

    fn finish(self: *Engine, i: usize, reaped: process.Reaped) !void {
        const t = &self.tasks[i];
        if (self.guard) |gd| gd.note('-', t.pid);
        const r = self.rule(i);
        const now_real = sys.realNs();
        const wall_s = @as(f64, @floatFromInt(sys.monoNs() - t.started_ns)) / 1e9;
        var counters: ?cgroup.Counters = null;
        if (t.cg) |cg| {
            counters = cg.counters();
            counters.?.anon_peak = t.anon_peak;
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg.path) catch {};
            t.cg = null;
        } else process.signalGroup(t.pid, .KILL);
        self.reserve(i, false);
        var released = false;
        errdefer if (!released) {
            self.setStatus(i, .failed);
            t.reason = "the engine could not record the attempt";
            self.releaseShared(i);
            self.finished += 1;
            self.settled(i);
        };

        var ok = false;
        var reason: []const u8 = "";
        var said: []const u8 = "";
        var quote = false;
        const code = reaped.exitCode();
        const sig = reaped.signal();
        const container_failed = r.container != null and code != null and code.? != 0;
        const end: schedule.End = .{
            .lost_service = t.lost_service,
            .cancelled = t.cancelled,
            .stop_why = t.stop_why,
            .timed_out = t.timed_out,
            .timeout_s = self.timeoutOf(r) orelse 0,
            .oom_kills = if (counters) |c| c.oom_kill else 0,
            .memory_mib = r.memory_mib,
            .exit_code = code,
            .signal = sig,
            .container = r.container != null,
            .last_line = if (container_failed) try self.lastLine(t.dir) else "",
        };
        if (try schedule.failure(self.a, end)) |f| {
            reason = f.reason;
            if (f.quote_stderr) {
                said = try self.errorLine(t.dir);
                quote = true;
            }
        } else {
            ok = true;
            for (r.output_abs, r.output) |o, written| {
                self.ids.forget(o);
                const id = try sys.lstat(self.gpa, o);
                if (id == null or !id.?.isReg()) {
                    ok = false;
                    reason = if (id == null)
                        try std.fmt.allocPrint(self.a, "exited 0 without output {s}", .{written})
                    else
                        try std.fmt.allocPrint(self.a, "exited 0, but its output {s} is not a regular file", .{written});
                    break;
                }
            }
        }
        self.writeSideFiles(r, t, ok, wall_s, reaped, counters) catch |err| {
            ok = false;
            reason = try std.fmt.allocPrint(self.a, "cannot write its log or benchmark file: {s}", .{sys.errorText(err)});
        };
        t.diagnostics = if (!ok and !t.cancelled) self.keepDiagnostics(r, t.dir) catch &.{} else &.{};
        if (quote and said.len == 0) for (t.diagnostics) |d| {
            said = try self.errorLineOf(try std.fs.path.join(self.a, &.{ t.dir, "diagnostics", d }));
            if (said.len > 0) break;
        };
        const brief = reason;
        if (said.len > 0) reason = try std.fmt.allocPrint(self.a, "{s}: {s}", .{ reason, said });
        if (t.container_name) |name| if (!ok)
            self.helper(container.removeAsync(self.a, self.podman.?, name, &self.envp, self.devnull));

        var outputs: std.ArrayList(state.Output) = .empty;
        if (ok) for (r.output_abs) |o| {
            const sa = self.st.allocator();
            const id = (try self.ids.get(o)) orelse "";
            const digest: ?[]const u8 = if (r.cutoff) try sa.dupe(u8, &try sys.sha256File(self.gpa, o)) else null;
            try outputs.append(sa, .{ .path = try sa.dupe(u8, o), .id = try sa.dupe(u8, id), .sha256 = digest });
        };
        if (ok and r.cutoff) try self.cut.record(self.a, i, outputs.items);

        const status: []const u8 = if (ok) "completed" else if (t.cancelled) "cancelled" else "failed";
        const finished_text = try records.timeText(self.a, now_real);
        try records.writeJson(self.gpa, try std.fmt.allocPrint(self.a, "{s}/record.json", .{t.dir}), .{
            .v = records.record_version,
            .rule = r.name,
            .attempt = t.attempts,
            .status = status,
            .reason = reason,
            .exit_code = code,
            .signal = sig,
            .started = try records.timeText(self.a, t.started_real),
            .finished = finished_text,
            .wall_s = wall_s,
            .cpu_s = taskCpu(counters, reaped),
            .cpu_source = if (cgroupCpu(counters) != null) "cgroup" else "rusage",
            .rusage = .{
                .cpu_s = reaped.cpuSeconds(),
                .maxrss_kib = reaped.usage.maxrss,
                .engine_maxrss_kib = t.engine_rss_kib,
            },
            .cgroup = counters,
            .request = .{ .threads = r.threads, .memory_mib = r.memory_mib, .reserved_mib = reservedMib(r), .groups = r.groups, .shared = r.shared, .container = r.container },
            .image = if (r.container) |img| self.images.get(img) else null,
            .version = r.version,
            .labels = r.labels,
            .outputs = outputs.items,
            .diagnostics = t.diagnostics,
            .queue = .{ .waited_s = t.queued_s, .reasons = t.waits.items },
            .key = if (t.key) |k| k.key else null,
        });

        if (ok) {
            self.setStatus(i, .completed);
            self.settled(i);
            self.releaseShared(i);
            released = true;
            const k = t.key.?;
            const sa = self.st.allocator();
            try self.st.data.rules.map.put(sa, try sa.dupe(u8, r.name), .{
                .key = try sa.dupe(u8, k.key),
                .command = try sa.dupe(u8, k.command),
                .env = try sa.dupe(u8, k.env),
                .request = try sa.dupe(u8, k.request),
                .writes = try sa.dupe(u8, k.writes),
                .inputs = try sa.dupe(u8, k.inputs),
                .parents = try sa.dupe(u8, k.parents),
                .engine = try sa.dupe(u8, k.engine),
                .outputs = outputs.items,
                .attempt = try sa.dupe(u8, t.dir),
                .finished = try sa.dupe(u8, finished_text),
                .wall_s = wall_s,
                .input_ids = ids: {
                    const out = try sa.alloc(state.InputId, k.input_ids.len);
                    for (out, k.input_ids) |*o, x| o.* = .{ .path = try sa.dupe(u8, x.path), .id = try sa.dupe(u8, x.id) };
                    break :ids out;
                },
            });
            if (!self.st.data.envs.map.contains(k.env)) {
                try self.st.data.envs.map.put(sa, try sa.dupe(u8, k.env), try sa.dupe(u8, self.env_text));
                try self.pending_envs.append(self.gpa, k.env);
            }
            try self.recordFiles(r);
            self.dirty = true;
            try self.pending_done.append(self.gpa, r.name);
            self.finished += 1;
            self.events.emit("task_finished", .{ .rule = r.name, .attempt = t.attempts, .status = "completed", .wall_s = wall_s, .cpu_s = taskCpu(counters, reaped), .maxrss_kib = reaped.usage.maxrss, .memory_peak = if (counters) |c| c.memory_peak else null });
            const note = self.log.text();
            if (t.attempts > 1) note.print("after {d} attempts", .{t.attempts}) catch {};
            self.say(.completed, i, self.figures(i, wall_s, counters, reaped));
            return;
        }
        t.reason = reason;
        self.events.emit("task_finished", .{ .rule = r.name, .attempt = t.attempts, .status = status, .reason = reason, .exit_code = code, .signal = sig, .wall_s = wall_s });
        self.restorePrevious(i) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.log.text().print("cannot put its earlier outputs back from {s}/previous: {s}", .{ monitor.shownPath(self.a, t.dir), sys.errorText(err) }) catch {};
                self.say(.warning, i, .{});
            },
        };
        if (schedule.retried(t.attempts, t.max_attempts, t.cancelled, self.stopping, t.lost_service != null)) {
            self.setStatus(i, .ready);
            self.listReady(i);
            self.releaseShared(i);
            released = true;
            self.ready_counter += 1;
            self.ready_seq[i] = self.ready_counter;
            t.ready_ns = sys.monoNs();
            t.waits = .empty;
            t.wait_reason = null;
            self.events.emit("task_retry", .{ .rule = r.name, .next_attempt = t.attempts + 1 });
            const w = self.log.text();
            const block = logging.ending(w, end) catch .none;
            if (self.log.detail.written().len == 0) w.writeAll(brief) catch {};
            w.print(", attempt {d} of {d}", .{ t.attempts, t.max_attempts }) catch {};
            self.say(.retrying, i, self.figures(i, wall_s, counters, reaped));
            if (block == .stderr) _ = self.quoteStderr(t.dir, 1);
            return;
        }
        self.setStatus(i, if (t.cancelled) .cancelled else .failed);
        self.releaseShared(i);
        released = true;
        self.finished += 1;
        self.settled(i);
        if (t.cancelled) {
            self.stopDetail(self.log.text(), t.stop_why);
            self.say(.cancelled, i, self.figures(i, wall_s, counters, reaped));
            return;
        }
        const w = self.log.text();
        const block = logging.ending(w, end) catch .none;
        if (self.log.detail.written().len == 0) w.writeAll(brief) catch {};
        if (t.attempts > 1) w.print(", attempt {d} of {d}", .{ t.attempts, t.max_attempts }) catch {};
        self.say(.failed, i, self.figures(i, wall_s, counters, reaped));
        var quoted = false;
        if (block == .stderr) quoted = self.quoteStderr(t.dir, 3);
        if (self.quoteDiagnostics(t.dir, t.diagnostics)) quoted = true;
        if (block == .memory) self.log.hintLine("raise its memory, or see kanit report --suggest", "", "");
        if (quoted) self.hintLogs(i, t.dir);
        self.stopAfter(i);
    }

    fn writeSideFiles(self: *Engine, r: *const workflow.Rule, t: *const Task, ok: bool, wall_s: f64, reaped: process.Reaped, counters: ?cgroup.Counters) !void {
        if (r.log_abs) |log| {
            if (std.fs.path.dirname(log)) |d| try sys.mkdirAll(self.gpa, d);
            const fd = try sys.openWrite(self.gpa, log, .truncate);
            defer sys.close(fd);
            for ([_][]const u8{ "stdout", "stderr" }) |stream| {
                const head = try std.fmt.allocPrint(self.a, "=== {s} ===\n", .{stream});
                try sys.writeAll(fd, head);
                const src = try std.fmt.allocPrint(self.a, "{s}/{s}.log", .{ t.dir, stream });
                const in = sys.openRead(self.gpa, src) catch continue;
                defer sys.close(in);
                var buf: [64 * 1024]u8 = undefined;
                while (true) {
                    const n = try sys.read(in, &buf);
                    if (n == 0) break;
                    try sys.writeAll(fd, buf[0..n]);
                }
            }
        }
        if (r.benchmark_abs) |b| if (ok) {
            if (std.fs.path.dirname(b)) |d| try sys.mkdirAll(self.gpa, d);
            try records.writeJson(self.gpa, b, .{
                .rule = r.name,
                .wall_time_secs = wall_s,
                .cpu_seconds = taskCpu(counters, reaped),
                .max_rss_mb = @as(f64, @floatFromInt(reaped.usage.maxrss)) / 1024.0,
                .memory_peak_mb = if (counters) |c| if (c.memory_peak) |p| @as(f64, @floatFromInt(p)) / 1048576.0 else null else null,
                .memory_limit_mb = r.memory_mib,
                .retries = t.attempts - 1,
            });
        };
    }

    fn lastLine(self: *Engine, dir: []const u8) ![]const u8 {
        return self.lastLineOf(try std.fmt.allocPrint(self.a, "{s}/stderr.log", .{dir}));
    }

    fn errorLine(self: *Engine, dir: []const u8) ![]const u8 {
        return self.errorLineOf(try std.fmt.allocPrint(self.a, "{s}/stderr.log", .{dir}));
    }

    fn errorLineOf(self: *Engine, path: []const u8) ![]const u8 {
        const line = try self.lastLineOf(path);
        const cut = sys.utf8Prefix(line, 200);
        const out = try self.a.dupe(u8, cut);
        for (out) |*ch| if (ch.* < 0x20 or ch.* == 0x7f) {
            ch.* = ' ';
        };
        return if (cut.len < line.len) std.fmt.allocPrint(self.a, "{s}...", .{out}) else out;
    }

    fn lastLineOf(self: *Engine, path: []const u8) ![]const u8 {
        const tail = sys.readTail(self.gpa, path, 2048) catch return "";
        defer self.gpa.free(tail);
        const trimmed = std.mem.trimEnd(u8, tail, " \r\n");
        const begin = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |k| k + 1 else 0;
        return sys.utf8Text(self.a, try self.a.dupe(u8, trimmed[begin..]));
    }

    fn keepDiagnostics(self: *Engine, r: *const workflow.Rule, dir: []const u8) ![]const []const u8 {
        if (r.diagnostics.len == 0) return &.{};
        const root = (try sys.realpath(self.a, self.wf.root)) orelse return &.{};
        var kept: std.ArrayList([]const u8) = .empty;
        for (r.diagnostics, r.diagnostics_abs) |written, abs| {
            const real = (sys.realpath(self.a, abs) catch null) orelse continue;
            if (!workflow.within(root, real) or workflow.inRecords(root, real)) continue;
            const id = (sys.stat(self.gpa, real) catch null) orelse continue;
            if (!id.isReg()) continue;
            const tail = sys.readTail(self.gpa, real, diagnostics_max) catch continue;
            defer self.gpa.free(tail);
            const copy = try std.fs.path.join(self.a, &.{ dir, "diagnostics", written });
            try sys.mkdirAll(self.gpa, std.fs.path.dirname(copy).?);
            try sys.writeFile(self.gpa, copy, tail);
            try kept.append(self.a, written);
        }
        return kept.items;
    }

    fn recordFiles(self: *Engine, r: *const workflow.Rule) !void {
        const sa = self.st.allocator();
        for ([_][]const []const u8{ r.input_abs, r.output_abs }) |paths| for (paths) |p| {
            const id = (try self.ids.get(p)) orelse continue;
            const gop = try self.st.data.files.map.getOrPut(sa, p);
            if (!gop.found_existing) gop.key_ptr.* = try sa.dupe(u8, p);
            gop.value_ptr.* = try sa.dupe(u8, id);
            try self.pending_files.append(self.gpa, p);
        };
    }

    // --- Control ---

    fn readControl(self: *Engine) !void {
        var drain: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        _ = linux.read(self.control_watch, &drain, drain.len);
        const fd = sys.openRead(self.gpa, self.control_path) catch return;
        defer sys.close(fd);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = sys.check(linux.pread(fd, &buf, buf.len, @intCast(self.control_offset))) catch return;
            if (n == 0) return;
            if (self.control_skip) {
                const nl = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse {
                    self.control_offset += n;
                    continue;
                };
                self.control_offset += nl + 1;
                self.control_skip = false;
                continue;
            }
            const end = (std.mem.lastIndexOfScalar(u8, buf[0..n], '\n') orelse {
                if (n < buf.len) return;
                self.log.text().print("control: ignored a line of over {d} bytes", .{buf.len}) catch {};
                self.log.emit(.control, .{}, .{});
                self.control_offset += n;
                self.control_skip = true;
                continue;
            }) + 1;
            self.control_offset += end;
            var it = std.mem.splitScalar(u8, buf[0..end], '\n');
            while (it.next()) |raw| {
                if (raw.len == 0) continue;
                const line = try sys.utf8Text(self.a, raw);
                var words = std.mem.tokenizeScalar(u8, line, ' ');
                const cmd = words.next() orelse continue;
                const name = words.next() orelse "";
                const result = try self.control(cmd, name);
                self.events.emit("control", .{ .command = cmd, .rule = name, .result = result });
                if (self.wf.findRule(name)) |ri| {
                    self.log.text().print("control {s}: {s}", .{ cmd, result }) catch {};
                    self.say(.control, ri, .{});
                } else {
                    self.log.text().print("control {s}{s}{s}: {s}", .{ cmd, if (name.len > 0) " " else "", name, result }) catch {};
                    self.log.emit(.control, .{}, .{});
                }
            }
        }
    }

    fn control(self: *Engine, cmd: []const u8, name: []const u8) ![]const u8 {
        const eql = std.mem.eql;
        if (self.ending) return "the launch is ending";
        if (eql(u8, cmd, "cancel")) {
            if (self.stopping) return "already stopping";
            self.interrupted = true;
            self.interrupted_at = sys.monoNs();
            self.beginStop();
            return "stopping the launch";
        }
        const i = self.wf.findRule(name) orelse return "no such rule";
        const t = &self.tasks[i];
        if (eql(u8, cmd, "stop")) switch (t.status) {
            .running => {
                if (t.cancelled) return "already stopping";
                t.cancelled = true;
                t.stop_why = "stopped on request";
                self.terminate(t, @as(i128, self.opts.grace_s) * std.time.ns_per_s);
                self.events.emit("task_cancelling", .{ .rule = name });
                return "stopping";
            },
            .pending, .ready, .staging => {
                try self.setWait(i, null);
                self.endUnstarted(i, t.status == .staging, null, .cancelled, "stopped on request");
                return "stopped before it started";
            },
            else => return "not running",
        };
        if (eql(u8, cmd, "retry")) {
            if (self.stopping) return "the launch is stopping";
            if (t.status != .failed and t.status != .cancelled) return "not failed";
            self.setStatus(i, .pending);
            t.reason = "";
            t.cancelled = false;
            t.max_attempts = t.attempts + 1;
            self.finished -= 1;
            self.wakeTask(i);
            var queue: std.ArrayList(usize) = .empty;
            defer queue.deinit(self.gpa);
            try queue.append(self.gpa, i);
            while (queue.pop()) |q| for (self.g.children[q]) |c| if (self.tasks[c].status == .blocked) {
                self.setStatus(c, .pending);
                self.tasks[c].reason = "";
                self.finished -= 1;
                self.wakeTask(c);
                try queue.append(self.gpa, c);
            };
            return "retrying";
        }
        return "unknown command";
    }

    // --- Stopping ---

    fn beginEnding(self: *Engine) void {
        if (self.ending) return;
        self.ending = true;
        self.events.emit("launch_ending", .{});
    }

    fn stopDetail(self: *Engine, w: *std.Io.Writer, reason: []const u8) void {
        if (std.mem.eql(u8, reason, after_failure)) {
            if (self.stop_cause) |c| w.print("stopped after {s} failed", .{self.names.word[c]}) catch {} else w.writeAll("stopped after a failure") catch {};
        } else if (std.mem.eql(u8, reason, after_interrupt)) {
            w.writeAll("stopped by an interrupt") catch {};
        } else w.writeAll(reason) catch {};
    }

    fn stopAfter(self: *Engine, i: usize) void {
        if (self.opts.keep_going) return;
        if (self.stop_cause == null) self.stop_cause = i;
        self.beginStop();
    }

    fn beginStop(self: *Engine) void {
        if (self.stopping) return;
        self.stopping = true;
        const grace = @as(i128, self.opts.grace_s) * std.time.ns_per_s;
        const why = if (self.interrupted) after_interrupt else after_failure;
        for (self.tasks, 0..) |*t, i| switch (t.status) {
            .running => {
                t.cancelled = true;
                t.stop_why = why;
                self.terminate(t, grace);
                self.events.emit("task_cancelling", .{ .rule = self.rule(i).name });
            },
            .staging => self.endUnstarted(i, true, null, .cancelled, why),
            else => {},
        };
        self.releaseIdle(null);
    }

    fn terminate(self: *Engine, t: *Task, grace: i128) void {
        if (t.kill_at != null) return;
        t.deadline_ns = null;
        process.signalGroup(t.pid, .TERM);
        if (t.container_name) |name|
            self.helper(container.stopAsync(self.a, self.podman.?, name, self.opts.grace_s, &self.envp, self.devnull));
        t.kill_at = schedule.killAt(sys.monoNs(), grace, t.container_name != null);
    }

    fn checkTimers(self: *Engine) void {
        const now = sys.monoNs();
        const grace = @as(i128, self.opts.grace_s) * std.time.ns_per_s;
        for (self.holders, 0..) |*h, hi| if (h.ready_deadline) |d| if (now >= d) {
            h.ready_deadline = null;
            if (h.st == .loading) {
                h.timed_out = true;
                self.events.emit("shared_timeout", .{ .name = self.wf.shared[hi].name });
                self.stopHolder(h);
                h.st = .loading;
            }
        };
        for (self.holders) |*h| if (h.kill_at) |k| if (now >= k) {
            process.signalPid(h.pid, .KILL);
            if (h.cg) |cg| cg.kill();
            h.kill_at = null;
        };
        for (self.active.items) |i| {
            const t = &self.tasks[i];
            if (t.status != .running) continue;
            switch (schedule.timer(now, t.deadline_ns, t.kill_at, t.timed_out)) {
                .none => {},
                .kill => {
                    process.signalGroup(t.pid, .KILL);
                    if (t.cg) |cg| cg.kill();
                    t.kill_at = null;
                },
                .terminate => {
                    t.timed_out = true;
                    self.terminate(t, grace);
                    self.events.emit("task_timeout", .{ .rule = self.rule(i).name, .attempt = t.attempts });
                },
            }
        }
    }

    fn stillRuns(t: *const Task) bool {
        if (t.cg) |cg| return cg.populated();
        return process.groupAlive(t.pid);
    }

    fn finishEnded(self: *Engine) !void {
        for (self.active.items) |i| {
            const t = &self.tasks[i];
            if (t.status != .running) continue;
            const rp = t.ended orelse continue;
            if (t.kill_at != null and stillRuns(t)) continue;
            t.ended = null;
            try self.finish(i, rp);
        }
    }

    fn nextDeadline(self: *Engine) ?i128 {
        var best: ?i128 = null;
        for (self.holders) |h| for ([_]?i128{ h.kill_at, h.ready_deadline }) |d| if (d) |v| {
            best = if (best) |b| @min(b, v) else v;
        };
        for (self.active.items) |i| {
            const t = self.tasks[i];
            if (t.status != .running) continue;
            const drain: ?i128 = if (t.ended != null) sys.monoNs() + 20 * std.time.ns_per_ms else null;
            for ([_]?i128{ t.deadline_ns, t.kill_at, drain }) |d| if (d) |v| {
                best = if (best) |b| @min(b, v) else v;
            };
        }
        if (self.dirty) {
            const save_at = self.last_save_ns + std.time.ns_per_s;
            best = if (best) |b| @min(b, save_at) else save_at;
        }
        best = if (best) |b| @min(b, self.next_sample_ns) else self.next_sample_ns;
        if (self.page_path != null) best = @min(best.?, self.next_page_ns);
        if (self.log.deadline()) |d| best = @min(best.?, d);
        if (self.log.terminal() != null) best = @min(best.?, self.log.footer_ns + std.time.ns_per_s);
        best = @min(best.?, self.next_beat_ns);
        return best;
    }

    fn sample(self: *Engine) void {
        const now = sys.monoNs();
        if (now < self.next_sample_ns) return;
        var running_n: usize = 0;
        var ready_n: usize = 0;
        for (self.tasks) |t| switch (t.status) {
            .running, .staging => running_n += 1,
            .ready => ready_n += 1,
            else => {},
        };
        var memory_current: ?u64 = null;
        var cpu_cores: ?f64 = null;
        if (self.tree) |tree| {
            memory_current = cgroup.readNumber(self.gpa, tree.root, "memory.current");
            for (self.tasks) |*t| if (t.status == .running) if (t.cg) |cg| if (cg.stat("anon")) |b| {
                t.anon_peak = @max(t.anon_peak orelse 0, b);
            };
            const cpu = cgroup.cpuUsage(self.gpa, tree.root);
            if (cpu != null and self.last_cpu_us != null and now > self.last_sample_ns)
                cpu_cores = @as(f64, @floatFromInt(cpu.? -| self.last_cpu_us.?)) / (@as(f64, @floatFromInt(now - self.last_sample_ns)) / 1e3);
            self.last_cpu_us = cpu;
        }
        var shared_mib: u64 = 0;
        for (self.holders) |h| if (h.held) {
            shared_mib += h.reserve_mib;
        };
        self.events.emit("sample", .{
            .running = running_n,
            .ready = ready_n,
            .threads_reserved = self.usage.threads,
            .memory_reserved_mib = self.usage.memory_mib,
            .shared_reserved_mib = shared_mib,
            .memory_current = memory_current,
            .cpu_cores_used = cpu_cores,
        });
        self.last_sample_ns = now;
        self.next_sample_ns = now + sample_interval_ns;
    }

    fn drawPage(self: *Engine) void {
        const path = self.page_path orelse return;
        const t0 = sys.monoNs();
        writePage(self.gpa, path, self.launch_dir, .{ .wf = self.wf, .g = self.g }) catch |err| {
            self.log.text().print("cannot write {s} ({s}); the page stops updating", .{ monitor.shownPath(self.a, path), sys.errorText(err) }) catch {};
            self.log.emit(.warning, .{}, .{});
            self.page_path = null;
            return;
        };
        const now = sys.monoNs();
        self.next_page_ns = now + @max(@as(i128, html.REFRESH_SECONDS) * std.time.ns_per_s, (now - t0) * 20);
    }

    fn saveState(self: *Engine, force: bool) !void {
        if (!self.dirty) return;
        const now = sys.monoNs();
        if (!force and now - self.last_save_ns < std.time.ns_per_s) return;
        if (force or self.st.logIsLarge())
            try self.st.save(self.gpa)
        else
            try self.st.appendLog(self.gpa, self.pending_done.items, self.pending_files.items, self.pending_envs.items);
        for (self.pending_done.items) |name| try self.journal.mark(self.gpa, "done", name);
        self.pending_done.clearRetainingCapacity();
        self.pending_files.clearRetainingCapacity();
        self.pending_envs.clearRetainingCapacity();
        self.dirty = false;
        self.last_save_ns = now;
    }

    fn running(self: *Engine) usize {
        self.keepListed(&self.active, .running, "active");
        self.keepListed(&self.staged, .staging, "staged");
        var n: usize = self.active.items.len + self.staged.items.len;
        for (self.holders) |h| n += @intFromBool(h.pid > 0);
        return n;
    }

    // --- Tool versions ---

    fn queueVersion(self: *Engine, i: usize) !void {
        if (try self.addVersion(i)) self.startVersion();
    }

    fn addVersion(self: *Engine, i: usize) !bool {
        const r = self.rule(i);
        const command = r.version orelse return false;
        const image: ?[]const u8 = if (r.container) |img| self.images.get(img) else null;
        for (self.versions.items) |v| {
            const same_image = if (v.image) |x| (image != null and std.mem.eql(u8, x, image.?)) else image == null;
            if (same_image and std.mem.eql(u8, v.command, command)) return false;
        }
        const dir = try std.fs.path.join(self.a, &.{ self.launch_dir, "versions" });
        try sys.mkdirAll(self.gpa, dir);
        try self.versions.append(self.a, .{
            .command = command,
            .container = r.container,
            .image = image,
            .file = try std.fmt.allocPrint(self.a, "{s}/{d}.log", .{ dir, self.versions.items.len + 1 }),
            .rule = i,
        });
        return true;
    }

    /// Runs the version commands of the selected rules before the first
    /// rule, at most four at a time, for the launch header. Commands still
    /// running at the deadline or at a signal go on beside the rules and are
    /// reaped with them; the summary reads their answers from
    /// `versions.json`. An interrupt is raised again for the main loop.
    fn measureVersions(self: *Engine) !void {
        for (self.mask, 0..) |on, i| if (on) {
            _ = try self.addVersion(i);
        };
        self.recordedAnswers();
        const most = 4;
        const deadline = sys.monoNs() + versions_wait_ns;
        var next: usize = 0;
        var waiting: std.ArrayList(struct { v: usize, pidfd: sys.Fd }) = .empty;
        defer {
            for (waiting.items) |r| sys.close(r.pidfd);
            waiting.deinit(self.gpa);
        }
        while (sys.monoNs() < deadline) {
            while (waiting.items.len < most and next < self.versions.items.len) : (next += 1) {
                const v = &self.versions.items[next];
                if (v.started) continue;
                v.started = true;
                v.pid = self.spawnVersion(v) catch |err| {
                    const text = std.fmt.allocPrint(self.a, "kanit: cannot start the version command: {s}\n", .{sys.errorText(err)}) catch continue;
                    sys.writeFile(self.gpa, v.file, text) catch {};
                    continue;
                };
                v.running = true;
                const fd = sys.check(linux.pidfd_open(v.pid, 0)) catch continue;
                try waiting.append(self.gpa, .{ .v = next, .pidfd = @intCast(fd) });
            }
            if (waiting.items.len == 0) break;
            var fds: [most + 1]linux.pollfd = undefined;
            for (waiting.items, 0..) |r, k| fds[k] = .{ .fd = r.pidfd, .events = linux.POLL.IN, .revents = 0 };
            fds[waiting.items.len] = .{ .fd = self.sigfd, .events = linux.POLL.IN, .revents = 0 };
            process.wait(fds[0 .. waiting.items.len + 1], deadline);
            if (fds[waiting.items.len].revents != 0) {
                const seen = process.readSignals(self.sigfd);
                var stop = false;
                for ([_]linux.SIG{ .INT, .TERM, .HUP }) |sig| if (process.has(seen, sig)) {
                    _ = linux.kill(linux.getpid(), sig);
                    stop = true;
                };
                if (stop) break;
            }
            var k: usize = waiting.items.len;
            while (k > 0) {
                k -= 1;
                if (fds[k].revents == 0) continue;
                const r = waiting.items[k];
                const v = &self.versions.items[r.v];
                var status: u32 = 0;
                var usage: linux.rusage = undefined;
                if (linux.errno(linux.wait4(v.pid, &status, 0, &usage)) == .SUCCESS) {
                    if (self.guard) |gd| gd.note('-', v.pid);
                    v.exit_code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 128 + @as(u32, @intFromEnum(linux.W.TERMSIG(status)));
                    v.running = false;
                }
                sys.close(r.pidfd);
                _ = waiting.swapRemove(k);
            }
        }
    }

    /// Takes, for each container version command, the answer an earlier
    /// launch recorded for the same image ID and command: an image's tools
    /// cannot change while its ID stays the same, so a launch of reused
    /// rules starts no container to ask again. Host commands always run.
    fn recordedAnswers(self: *Engine) void {
        var open: usize = 0;
        for (self.versions.items) |v| open += @intFromBool(v.image != null);
        if (open == 0) return;
        const launches_dir = std.fs.path.dirname(self.launch_dir) orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const s = scratch.allocator();
        const launches = records.launchNames(self.gpa, s, std.fs.path.dirname(launches_dir) orelse return) catch return;
        var k = launches.len;
        var read: usize = 0;
        while (k > 0 and read < 20 and open > 0) {
            k -= 1;
            if (std.mem.eql(u8, launches[k], self.launch_id)) continue;
            const path = std.fs.path.join(s, &.{ launches_dir, launches[k], "versions.json" }) catch return;
            const text = sys.readFile(self.gpa, path, 1 << 20) catch continue;
            defer self.gpa.free(text);
            read += 1;
            const v = std.json.parseFromSliceLeaky(std.json.Value, s, text, .{}) catch continue;
            const list = fields.get(v, "commands") orelse continue;
            if (list != .array) continue;
            for (list.array.items) |e| {
                if (fields.int(e, "exit_code") != 0) continue;
                const image = fields.str(e, "image") orelse continue;
                const command = fields.str(e, "command") orelse continue;
                const output = fields.str(e, "output") orelse continue;
                for (self.versions.items) |*ver| {
                    if (ver.started) continue;
                    const own = ver.image orelse continue;
                    if (!std.mem.eql(u8, own, image) or !std.mem.eql(u8, ver.command, command)) continue;
                    sys.writeFile(self.gpa, ver.file, output) catch continue;
                    ver.started = true;
                    ver.exit_code = 0;
                    open -= 1;
                }
            }
        }
    }

    fn versionOf(self: *Engine, i: usize) []const u8 {
        const r = self.rule(i);
        const command = r.version orelse return "";
        const image: ?[]const u8 = if (r.container) |img| self.images.get(img) else null;
        for (self.versions.items) |v| {
            const same_image = if (v.image) |x| (image != null and std.mem.eql(u8, x, image.?)) else image == null;
            if (!same_image or !std.mem.eql(u8, v.command, command)) continue;
            if (v.running or !v.started) return "measuring";
            if (v.stopped) return "no answer";
            if (v.exit_code != 0) return "failed";
            const head = sys.readHead(self.gpa, v.file, version_output_max) catch return "";
            defer self.gpa.free(head);
            const text = logging.versionText(self.names.tool[i], firstLine(head));
            return self.a.dupe(u8, logging.cut(text, 40)) catch "";
        }
        return "";
    }

    fn versionsRunning(self: *const Engine) bool {
        for (self.versions.items) |v| if (v.running) return true;
        return false;
    }

    fn startVersion(self: *Engine) void {
        if (self.versionsRunning() or self.interrupted) return;
        for (self.versions.items) |*v| {
            if (v.started) continue;
            v.started = true;
            v.pid = self.spawnVersion(v) catch |err| {
                const text = std.fmt.allocPrint(self.a, "kanit: cannot start the version command: {s}\n", .{sys.errorText(err)}) catch continue;
                sys.writeFile(self.gpa, v.file, text) catch {};
                continue;
            };
            v.running = true;
            return;
        }
    }

    fn spawnVersion(self: *Engine, v: *const Version) !linux.pid_t {
        const fd = try sys.openWrite(self.gpa, v.file, .truncate);
        defer sys.close(fd);
        var spec: process.Spec = undefined;
        if (v.image) |id| {
            const argv = try process.Vec.init(self.a, &.{
                self.podman.?,                      "run",
                "--rm",                             "--pull=never",
                "--label",                          try std.fmt.allocPrint(self.a, "workz.workdir={s}", .{self.wf.root}),
                "--label",                          try std.fmt.allocPrint(self.a, "workz.launch={s}", .{self.launch_id}),
                "--network=none",                   "--cap-drop=ALL",
                "--security-opt=no-new-privileges", "--security-opt=label=disable",
                "--read-only",                      "--log-driver=none",
                "--entrypoint",                     "/bin/sh",
                id,                                 "-c",
                v.command,
            });
            spec = .{ .path = (try self.a.dupeZ(u8, self.podman.?)).ptr, .argv = argv.items.ptr, .envp = self.envp.items.ptr, .cwd = "/", .stdin = self.devnull, .stdout = fd, .stderr = fd };
        } else {
            const argv = try process.Vec.init(self.a, &.{ "bash", "-c", v.command });
            spec = .{
                .path = self.bash.ptr,
                .argv = argv.items.ptr,
                .envp = self.envp.items.ptr,
                .cwd = (try self.a.dupeZ(u8, self.wf.root)).ptr,
                .stdin = self.devnull,
                .stdout = fd,
                .stderr = fd,
                .userns = if (self.network) |n| n.userns else -1,
                .netns = if (self.network) |n| n.netns else -1,
            };
        }
        const pid = try process.spawn(&spec);
        if (self.guard) |gd| gd.note('+', pid);
        return pid;
    }

    fn versionOfPid(self: *const Engine, pid: linux.pid_t) ?usize {
        for (self.versions.items, 0..) |v, vi| if (v.running and v.pid == pid) return vi;
        return null;
    }

    fn versionExited(self: *Engine, vi: usize, rp: process.Reaped) void {
        const v = &self.versions.items[vi];
        if (self.guard) |gd| gd.note('-', v.pid);
        v.exit_code = rp.exitCode() orelse if (rp.signal()) |s| 128 + @as(u32, @intCast(s)) else null;
        v.running = false;
        self.startVersion();
    }

    fn writeVersions(self: *Engine) !void {
        if (self.versions.items.len == 0) return;
        for (self.versions.items) |*v| if (v.running) {
            process.signalGroup(v.pid, .KILL);
            process.signalPid(v.pid, .KILL);
            v.stopped = true;
        };
        const Entry = struct { command: []const u8, container: ?[]const u8, image: ?[]const u8, status: []const u8, exit_code: ?u32, output: []const u8 };
        var entries: std.ArrayList(Entry) = .empty;
        for (self.versions.items) |v| {
            const head = try sys.readHead(self.gpa, v.file, version_output_max);
            defer self.gpa.free(head);
            try entries.append(self.a, .{
                .command = v.command,
                .container = v.container,
                .image = v.image,
                .status = if (!v.started) "not run" else if (v.stopped) "stopped" else if (v.exit_code == 0) "completed" else "failed",
                .exit_code = v.exit_code,
                .output = try sys.utf8Text(self.a, try self.a.dupe(u8, std.mem.trim(u8, head, " \t\r\n"))),
            });
        }
        try records.writeJson(self.gpa, try std.fs.path.join(self.a, &.{ self.launch_dir, "versions.json" }), .{ .v = records.record_version, .commands = entries.items });
    }

    fn keeperEnded(self: *Engine, rp: process.Reaped) bool {
        if (self.network) |*n| if (n.pid == rp.pid) {
            n.pid = 0;
            self.events.emit("network_holder_ended", .{ .exit_code = rp.exitCode(), .signal = rp.signal() });
            self.log.text().writeAll("the run's network holder ended; a killed engine would no longer end its tasks") catch {};
            self.log.emit(.warning, .{}, .{});
            return true;
        };
        if (self.guard) |*g| if (g.pid == rp.pid) {
            g.pid = 0;
            self.events.emit("guard_ended", .{ .exit_code = rp.exitCode(), .signal = rp.signal() });
            self.log.text().writeAll("the guard of tasks without isolation ended; a killed engine would leave its tasks running") catch {};
            self.log.emit(.warning, .{}, .{});
            return true;
        };
        return false;
    }

    fn helper(self: *Engine, pid: ?linux.pid_t) void {
        if (pid) |p| self.helpers.append(self.gpa, p) catch {};
    }

    fn awaitVersions(self: *Engine, limit_s: u64) void {
        const until = sys.monoNs() + @as(i128, limit_s) * std.time.ns_per_s;
        while (self.versionsRunning() and !self.interrupted and sys.monoNs() < until) {
            var fds = [_]linux.pollfd{.{ .fd = self.sigfd, .events = linux.POLL.IN, .revents = 0 }};
            process.wait(&fds, until);
            const seen = process.readSignals(self.sigfd);
            if (process.has(seen, .INT) or process.has(seen, .TERM) or process.has(seen, .HUP)) break;
            self.reapAll() catch {};
        }
    }

    fn awaitHelpers(self: *Engine, limit_s: u64) void {
        const until = sys.monoNs() + @as(i128, limit_s) * std.time.ns_per_s;
        while (self.helpers.items.len > 0 and sys.monoNs() < until) {
            var fds = [_]linux.pollfd{.{ .fd = self.sigfd, .events = linux.POLL.IN, .revents = 0 }};
            process.wait(&fds, until);
            _ = process.readSignals(self.sigfd);
            self.reapAll() catch {};
        }
    }

    fn reapAll(self: *Engine) !void {
        while (process.reap()) |rp| {
            if (self.by_pid.fetchRemove(rp.pid)) |kv| {
                const i = kv.value;
                const t = &self.tasks[i];
                if (t.status == .running and t.ended == null and t.pid == rp.pid) {
                    if (t.kill_at != null and stillRuns(t)) t.ended = rp else try self.finish(i, rp);
                    continue;
                }
            }
            for (self.holders, 0..) |*h, hi| {
                if (h.pid == rp.pid) {
                    try self.holderExited(hi, rp);
                    break;
                }
            } else if (self.versionOfPid(rp.pid)) |vi| {
                self.versionExited(vi, rp);
            } else if (self.keeperEnded(rp)) {
                continue;
            } else for (self.helpers.items, 0..) |pid, k| {
                if (pid == rp.pid) {
                    _ = self.helpers.swapRemove(k);
                    break;
                }
            }
        }
    }

    /// Acts on the interrupts in `seen`: the first stops the running rules,
    /// one within the next second is ignored, and a later one kills them.
    fn signals(self: *Engine, seen: u64) void {
        if (!(process.has(seen, .INT) or process.has(seen, .TERM) or process.has(seen, .HUP))) return;
        const now = sys.monoNs();
        switch (schedule.interrupt(self.signalled_at, now)) {
            .ignore => {},
            .kill => {
                self.log.text().writeAll("interrupted again: killing the running rules") catch {};
                self.log.emit(.control, .{}, .{});
                for (self.tasks) |*t| if (t.status == .running) {
                    t.kill_at = now;
                };
                for (self.holders) |*h| if (h.pid > 0) {
                    h.kill_at = now;
                };
            },
            .stop => {
                self.signalled_at = now;
                self.events.emit("cancel_requested", .{ .signal = if (process.has(seen, .INT)) "SIGINT" else if (process.has(seen, .TERM)) "SIGTERM" else "SIGHUP" });
                if (self.interrupted) {
                    self.log.text().writeAll("interrupted: the launch is already stopping; interrupt again to kill") catch {};
                    self.log.emit(.control, .{}, .{});
                } else {
                    self.interrupted = true;
                    self.interrupted_at = now;
                    self.log.text().writeAll("interrupted: stopping the running rules; interrupt again to kill") catch {};
                    self.log.emit(.control, .{}, .{});
                    self.beginStop();
                }
            },
        }
    }

    fn loop(self: *Engine) !void {
        var idle_passes: u32 = 0;
        self.signals(process.readSignals(self.sigfd));
        if (self.control_watch >= 0) try self.readControl();
        while (true) {
            try self.updateReadiness();
            self.releaseIdle(null);
            try self.admit();
            try self.saveState(false);
            if (self.running() == 0) {
                var any_ready = false;
                for (self.tasks) |t| any_ready = any_ready or t.status == .ready or t.status == .pending;
                if (!any_ready or self.stopping) break;
                idle_passes += 1;
                if (idle_passes >= 2) {
                    self.fatal = "ready rules cannot fit the budget";
                    for (self.tasks, 0..) |t, i| if (t.status == .ready) if (self.blocker(i)) |why| {
                        self.fatal = try std.fmt.allocPrint(self.a, "rule {s} cannot start: it waits for {s} with nothing running", .{ self.rule(i).name, why });
                        break;
                    };
                    break;
                }
                continue;
            }
            idle_passes = 0;
            var fds: std.ArrayList(linux.pollfd) = .empty;
            defer fds.deinit(self.gpa);
            try fds.append(self.gpa, .{ .fd = self.sigfd, .events = linux.POLL.IN, .revents = 0 });
            for (self.holders) |h| if (h.st == .loading and h.pipe >= 0) try fds.append(self.gpa, .{ .fd = h.pipe, .events = linux.POLL.IN, .revents = 0 });
            if (self.control_watch >= 0) try fds.append(self.gpa, .{ .fd = self.control_watch, .events = linux.POLL.IN, .revents = 0 });
            process.wait(fds.items, self.nextDeadline());
            self.signals(process.readSignals(self.sigfd));
            for (fds.items[1..]) |f| if (f.revents != 0) {
                if (f.fd == self.control_watch) try self.readControl();
                for (self.holders, 0..) |h, hi| if (h.pipe == f.fd) try self.holderReady(hi);
            };
            try self.reapAll();
            self.checkTimers();
            try self.finishEnded();
            self.sample();
            if (self.page_path != null and sys.monoNs() >= self.next_page_ns) self.drawPage();
            self.tick(false);
        }
    }
};

fn overridden(overrides: []const []const u8, step: []const u8) bool {
    for (overrides) |o| {
        const eq = std.mem.lastIndexOfScalar(u8, o, '=') orelse continue;
        if (std.mem.eql(u8, o[0..eq], step)) return true;
    }
    return false;
}

pub const container_client_mib: u64 = 32;

pub fn reservedMib(r: *const workflow.Rule) u64 {
    return r.memory_mib + if (r.container != null) container_client_mib else 0;
}

fn recoverPrevious(gpa: Allocator, a: Allocator, wf: *const workflow.Workflow, rec: []const u8, current: []const u8, events: *records.Events) !void {
    for (try records.pendingAttempts(gpa, a, rec, current)) |p| {
        const name = p.rule;
        const dir = p.dir;
        const r = &wf.rules[wf.ruleIndex(name) orelse continue];
        for (r.output_abs, r.output, 0..) |o, written, n| {
            const file = try std.fmt.allocPrint(a, "{d}-{s}", .{ n, std.fs.path.basename(o) });
            const prev = try std.fs.path.join(a, &.{ dir, "previous", file });
            const kept = (try sys.lstat(gpa, prev)) orelse continue;
            if (try sys.lstat(gpa, o)) |_| {
                const failed_dir = try std.fs.path.join(a, &.{ dir, "failed" });
                sys.mkdir(gpa, failed_dir) catch |err| if (err != error.PathAlreadyExists) return err;
                try sys.rename(gpa, o, try std.fs.path.join(a, &.{ failed_dir, file }));
            }
            if (std.fs.path.dirname(o)) |d| try sys.mkdirAll(gpa, d);
            try sys.rename(gpa, prev, o);
            events.emit("output_restored", .{ .rule = name, .path = written, .moved_from = prev, .bytes = kept.size });
        }
    }
}

pub const SharedSize = struct { bytes: u64, mib: u64, reserve_mib: u64 };

pub fn sharedSizes(gpa: Allocator, a: Allocator, wf: *const workflow.Workflow, runs: []const bool, failure: *[]const u8) ![]?SharedSize {
    const out = try a.alloc(?SharedSize, wf.shared.len);
    @memset(out, null);
    for (wf.rules, runs) |r, run_it| {
        if (!run_it) continue;
        for (r.shared_index) |hi| {
            if (out[hi] != null) continue;
            const s = wf.shared[hi];
            if (s.memory_mib) |mib| {
                out[hi] = .{ .bytes = mib * 1024 * 1024, .mib = mib, .reserve_mib = mib + container_client_mib };
                continue;
            }
            var failed: ?[]u8 = null;
            defer if (failed) |f| gpa.free(f);
            const bytes = state.pageBytes(gpa, s.path_abs.?, &failed) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    const why = if (err == error.NotRegularFile)
                        try std.fmt.allocPrint(a, "{s} is not a regular file, and a shared input maps every file it holds", .{failed.?})
                    else if (failed) |f| try std.fmt.allocPrint(a, "{s}: {s}", .{ f, sys.errorText(err) }) else sys.errorText(err);
                    failure.* = try std.fmt.allocPrint(a, "shared input {s} ({s}): {s}", .{ s.name, s.path.?, why });
                    return error.Unmeasurable;
                },
            };
            const mib = std.math.divCeil(u64, bytes, 1024 * 1024) catch unreachable;
            out[hi] = .{ .bytes = bytes, .mib = mib, .reserve_mib = mib };
        }
    }
    return out;
}

pub fn neededMib(r: *const workflow.Rule, sizes: []const ?SharedSize) u64 {
    var need = reservedMib(r);
    for (r.shared_index) |hi| need += if (sizes[hi]) |z| z.reserve_mib else 0;
    return need;
}

fn budgetReason(reason: []const u8) bool {
    for ([_][]const u8{ "jobs", "threads", "memory" }) |r| if (std.mem.eql(u8, reason, r)) return true;
    return std.mem.startsWith(u8, reason, "group:");
}

const version_output_max = 4096;
const versions_wait_ns: i128 = 5 * std.time.ns_per_s;

fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t");
        if (t.len > 0) return t;
    }
    return "";
}

const diagnostics_max = 64 * 1024;

const sample_interval_ns: i128 = 5 * std.time.ns_per_s;

fn groupIndex(wf: *const workflow.Workflow, name: []const u8) usize {
    for (wf.groups, 0..) |g, i| if (std.mem.eql(u8, g.name, name)) return i;
    unreachable;
}

fn protectScope(gpa: Allocator, a: Allocator, tree: cgroup.Tree, mib: u64, path_env: []const u8, envp: *const process.Vec, devnull: sys.Fd) bool {
    const systemctl = (process.findProgram(gpa, a, path_env, "systemctl") catch return false) orelse return false;
    const unit = std.fs.path.basename(tree.root);
    const prop = std.fmt.allocPrint(a, "MemoryLow={d}M", .{mib}) catch return false;
    var status: u32 = 0;
    _ = process.capture(gpa, a, &.{ systemctl, "--user", "set-property", "--runtime", unit, prop }, envp, devnull, &status) catch return false;
    return true;
}

/// The memory an attempt used, measured as the reports measure it
/// (`model.Attempt.usedMib`).
fn usedMib(r: *const workflow.Rule, t: *const Task, counters: ?cgroup.Counters, reaped: process.Reaped) ?f64 {
    const mib = 1048576.0;
    if (counters) |c| if (c.memory_peak) |p| {
        const peak = @as(f64, @floatFromInt(p)) / mib;
        if (c.oom_kill > 0) return peak;
        if (r.shared.len > 0 or r.container != null) return if (t.anon_peak) |b| @as(f64, @floatFromInt(b)) / mib else peak;
    };
    const rss = @as(f64, @floatFromInt(reaped.usage.maxrss)) / 1024.0;
    const anon = if (t.anon_peak) |b| @as(f64, @floatFromInt(b)) / mib else 0;
    if (anon > rss) return anon;
    if (reaped.usage.maxrss > t.engine_rss_kib) return rss;
    return null;
}

fn taskCpu(counters: ?cgroup.Counters, reaped: process.Reaped) f64 {
    return cgroupCpu(counters) orelse reaped.cpuSeconds();
}

fn cgroupCpu(counters: ?cgroup.Counters) ?f64 {
    const c = counters orelse return null;
    const us = c.cpu_usage_usec orelse return null;
    return @as(f64, @floatFromInt(us)) / 1e6;
}

const EngineCost = struct { cpu_s: f64, max_rss_mib: f64 };

const Summary = struct {
    v: u32 = records.record_version,
    engine: []const u8,
    engine_key: u32 = state.engine_key,
    launch: []const u8,
    status: []const u8,
    counts: struct { completed: usize = 0, reused: usize = 0, failed: usize = 0, blocked: usize = 0, cancelled: usize = 0, not_started: usize = 0, running: usize = 0, waiting: usize = 0, pending: usize = 0 },
    selected: usize,
    elapsed_s: f64,
    finished: []const u8,
    @"error": ?[]const u8,
    engine_cost: EngineCost,
    launch_dir: []const u8,
    failures: []const Failure = &.{},
    changed_outputs: []const ChangedOutput = &.{},
    previous_bytes: u64 = 0,
};

const Failure = struct { rule: []const u8, status: []const u8, reason: []const u8, stderr: ?[]const u8, diagnostics: []const []const u8 };
const ChangedOutput = struct { rule: []const u8, path: []const u8 };

fn writePage(gpa: Allocator, path: []const u8, launch_dir: []const u8, given: model.Snapshot) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try html.writeFileWith(gpa, arena.allocator(), path, launch_dir, null, given);
}

fn writeSummary(gpa: Allocator, a: Allocator, events: *records.Events, s: Summary) !void {
    events.emit("launch_finished", .{ .status = s.status, .counts = s.counts, .elapsed_s = s.elapsed_s, .@"error" = s.@"error" });
    try records.writeJson(gpa, try std.fs.path.join(a, &.{ s.launch_dir, "summary.json" }), s);
}

fn engineMaxRssKib() i64 {
    var ru: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &ru);
    return ru.maxrss;
}

fn engineCost() EngineCost {
    var ru: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &ru);
    const cpu = @as(f64, @floatFromInt(ru.utime.sec + ru.stime.sec)) + @as(f64, @floatFromInt(ru.utime.usec + ru.stime.usec)) / 1e6;
    return .{ .cpu_s = cpu, .max_rss_mib = @as(f64, @floatFromInt(ru.maxrss)) / 1024.0 };
}

const Refusal = struct {
    gpa: Allocator,
    a: Allocator,
    events: *records.Events,
    launch: []const u8,
    dir: []const u8,
    engine: []const u8,
    selected: usize,
    t0: i128,
    json: bool,
    changed: []const ChangedOutput = &.{},

    fn refuse(self: Refusal, outcome: Outcome, reason: []const u8) !Outcome {
        std.debug.print("kanit: {s}\n", .{reason});
        self.events.emit("launch_refused", .{ .reason = reason });
        const summary: Summary = .{
            .engine = self.engine,
            .launch = self.launch,
            .status = "refused",
            .counts = .{ .not_started = self.selected },
            .selected = self.selected,
            .elapsed_s = @as(f64, @floatFromInt(sys.monoNs() - self.t0)) / 1e9,
            .finished = try records.timeText(self.a, sys.realNs()),
            .@"error" = reason,
            .engine_cost = engineCost(),
            .launch_dir = self.dir,
            .changed_outputs = self.changed,
        };
        try writeSummary(self.gpa, self.a, self.events, summary);
        var w: std.Io.Writer.Allocating = .init(self.gpa);
        defer w.deinit();
        try w.writer.print("{f}\n", .{std.json.fmt(summary, .{})});
        if (self.json) try sys.writeAll(1, w.written());
        return outcome;
    }
};

fn findBash(gpa: Allocator) ?[:0]const u8 {
    for ([_][:0]const u8{ "/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash" }) |p| {
        if (sys.exists(gpa, p)) return p;
    }
    return null;
}

pub fn execute(gpa: Allocator, a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, mask: []const bool, opts: Options, environ: *const std.process.Environ.Map) !Outcome {
    const max_threads = opts.max_threads orelse defaultThreads();
    const max_memory = opts.max_memory_mib orelse defaultMemoryMib(gpa);
    const max_jobs = opts.jobs orelse max_threads;

    const rec = try records.recordsDir(a, wf.root);
    try records.makeRecordsDir(gpa, rec);
    const lock_fd = records.lock(gpa, rec) catch |err| switch (err) {
        error.Busy => {
            std.debug.print("kanit: another launch is running in {s}; watch it with kanit watch, or run again after it ends\n", .{wf.root});
            return .failed;
        },
        else => return err,
    };
    defer sys.close(lock_fd);

    const t_open = sys.monoNs();
    const launch = try records.newLaunch(gpa, a, rec);
    try sys.writeFile(gpa, try std.fs.path.join(a, &.{ launch.dir, "workflow" }), wf.source);
    var events = try records.Events.open(gpa, launch.dir);
    defer events.close();
    const exe = sys.self_exe;
    const exe_digest = try sys.sha256File(gpa, exe);
    const engine_id = try std.fmt.allocPrint(a, "kanit {s} sha256:{s}", .{ version, &exe_digest });
    var selected: usize = 0;
    for (mask) |m| selected += @intFromBool(m);
    try records.writeJson(gpa, try std.fs.path.join(a, &.{ launch.dir, "launch.json" }), .{
        .v = records.record_version,
        .engine = engine_id,
        .engine_key = state.engine_key,
        .launch = launch.id,
        .workflow = wf.path,
        .workflow_sha256 = &sys.sha256Bytes(wf.source),
        .workflow_name = wf.name,
        .workflow_version = wf.version,
        .workdir = wf.root,
        .started = try records.timeText(a, sys.realNs()),
        .max_threads = max_threads,
        .max_memory_mib = max_memory,
        .jobs = max_jobs,
        .isolation = opts.isolation,
        .keep_going = opts.keep_going,
        .rerun = opts.rerun,
        .retry = opts.retry,
        .timeout_s = opts.timeout_s,
        .input_manifest = opts.input_manifest,
        .pass_env = opts.pass_env,
        .thread_overrides = opts.thread_overrides,
        .slice = opts.slice,
        .selected = selected,
    });
    const refusal: Refusal = .{ .gpa = gpa, .a = a, .events = &events, .launch = launch.id, .dir = launch.dir, .engine = engine_id, .selected = selected, .t0 = t_open, .json = opts.json };

    var ids = state.Identities.init(gpa);
    defer ids.deinit();
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        for (r.input_abs, r.input) |in, written| {
            if (g.produces(in)) continue;
            const id = ids.get(in) catch |err| switch (err) {
                error.Unreadable => return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "rule {s}: {s}", .{ r.name, ids.problem })),
                else => return err,
            };
            if (id == null) return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "missing input of rule {s}: {s} (input paths are relative to {s}); create it, or fix the path", .{ r.name, written, wf.root }));
        }
    }

    var st = state.loadRecorded(gpa, a, rec) catch |err| switch (err) {
        error.UnsupportedState, error.CorruptState => return refusal.refuse(.invalid, (try state.loadErrorText(a, err, try std.fs.path.join(a, &.{ rec, "state.json" }))).?),
        else => return err,
    };
    defer st.deinit();
    recoverPrevious(gpa, a, wf, rec, launch.id, &events) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => std.debug.print("kanit: cannot put back the earlier outputs a killed launch moved aside: {s}\n", .{sys.errorText(err)}),
    };

    var changed: usize = 0;
    var first_changed: []const u8 = "";
    var changed_outputs: std.ArrayList(ChangedOutput) = .empty;
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        const e = st.data.rules.map.getPtr(r.name) orelse continue;
        for (e.outputs, 0..) |o, k| {
            switch (try state.checkOutput(gpa, &ids, o)) {
                .intact, .missing => continue,
                .refreshed => |now| {
                    const outs = try st.allocator().dupe(state.Output, e.outputs);
                    outs[k].id = try st.allocator().dupe(u8, now);
                    e.outputs = outs;
                    events.emit("output_identity_refreshed", .{ .rule = r.name, .path = o.path });
                    continue;
                },
                .changed => {},
            }
            if (opts.forced(r.name)) continue;
            changed += 1;
            if (first_changed.len == 0) first_changed = o.path;
            try changed_outputs.append(a, .{ .rule = r.name, .path = o.path });
            {
                std.debug.print("kanit: output of completed rule {s} changed since it was recorded: {s}\n", .{ r.name, o.path });
                events.emit("output_changed", .{ .rule = r.name, .path = o.path });
            }
        }
    }
    if (changed > 0) {
        var refused = refusal;
        refused.changed = changed_outputs.items;
        const which = if (changed == 1) "a recorded output" else try std.fmt.allocPrint(a, "{d} recorded outputs", .{changed});
        var opts_text: std.Io.Writer.Allocating = .init(a);
        var named: usize = 0;
        var rules_n: usize = 0;
        for (changed_outputs.items, 0..) |c, k| {
            const seen = for (changed_outputs.items[0..k]) |p| {
                if (std.mem.eql(u8, p.rule, c.rule)) break true;
            } else false;
            if (seen) continue;
            rules_n += 1;
            if (named == 5) continue;
            named += 1;
            try opts_text.writer.print("{s}--rerun-rule {s}", .{ if (named == 1) "" else " ", c.rule });
        }
        if (rules_n > named) try opts_text.writer.print(" (and {d} more rules)", .{rules_n - named});
        return refused.refuse(.failed, try std.fmt.allocPrint(a, "{s} changed outside kanit ({s}{s}); to run {s} again, keeping the earlier bytes in previous/, run with {s}, or with --rerun for every rule", .{ which, if (changed == 1) "" else "first ", first_changed, if (changed == 1) "the rule that wrote it" else "the rules that wrote them", opts_text.written() }));
    }

    if (opts.input_manifest) |mpath| {
        var notes: std.Io.Writer.Allocating = .init(gpa);
        defer notes.deinit();
        const m = try checkManifest(gpa, &st, &ids, mpath, true, &notes.writer);
        std.debug.print("{s}", .{notes.written()});
        events.emit("inputs_checked", .{ .manifest = mpath, .files = m.files, .files_read = m.read, .bytes_read = m.bytes_read, .seconds = m.seconds, .ok = m.ok });
        if (!m.usable) return refusal.refuse(.invalid, "the input manifest cannot be used");
        if (!m.ok) return refusal.refuse(.failed, "inputs do not match the input manifest");
    }
    var cut = try state.Cutoff.init(a, gpa, wf, &st, &ids, true);

    var journal = try records.Journal.open(gpa, rec);
    defer journal.close();

    var tree: ?cgroup.Tree = null;
    if (opts.isolation) {
        tree = cgroup.setup(gpa, a) catch |err| return refusal.refuse(.invalid, switch (err) {
            error.NotDelegated => "the run's scope cannot create cgroups for attempts: delegate the cpu, memory and pids controllers to the systemd user manager (see Installation), or use --no-isolation",
            else => try std.fmt.allocPrint(a, "cannot set up the run's cgroup: {s}", .{sys.errorText(err)}),
        });
    }

    const env_text = try state.envText(a, environ, opts.pass_env);

    const devnull = try sys.openRead(gpa, "/dev/null");
    defer sys.close(devnull);
    const host_envp = try process.Vec.init(a, try state.hostEnv(a, environ, opts.pass_env));

    var podman: ?[]const u8 = null;
    var images: std.StringHashMapUnmanaged([]const u8) = .empty;
    const refs = try container.imageRefs(a, wf, mask);
    if (refs.len > 0) {
        const tc = sys.monoNs();
        podman = (try container.findPodman(gpa, a, environ.get("PATH") orelse "/usr/bin:/bin")) orelse
            return refusal.refuse(.invalid, "the workflow has container rules but podman is not on PATH");
        var unresolved: ?container.Unresolved = null;
        images = try container.resolveImages(gpa, a, podman.?, refs, &host_envp, devnull, &unresolved);
        if (unresolved) |u| return refusal.refuse(.invalid, try u.text(a));
        const removed = try container.removeLeftovers(gpa, a, podman.?, wf.root, &host_envp, devnull);
        events.emit("containers_checked", .{ .images = images.count(), .leftovers_removed = removed, .seconds = @as(f64, @floatFromInt(sys.monoNs() - tc)) / 1e9 });
    }
    const extras = try container.ruleExtras(a, wf, &images);

    var decide: plan.Context = try .init(gpa, a, wf, g, &st, &ids, env_text, environ);
    decide.rerun = opts.rerun;
    decide.rerun_rules = opts.rerun_rules;
    decide.extras = extras;
    const decisions = decide.decideAll(mask) catch |err| switch (err) {
        error.Unreadable => return refusal.refuse(.invalid, ids.problem),
        else => return err,
    };
    const runs = try a.alloc(bool, wf.rules.len);
    for (runs, decisions, mask) |*r, d, m| r.* = m and d.run;
    var failure: []const u8 = "";
    const strict = sharedSizes(gpa, a, wf, runs, &failure) catch |err| switch (err) {
        error.Unmeasurable => return refusal.refuse(.invalid, failure),
        else => return err,
    };
    const sizes = sharedSizes(gpa, a, wf, mask, &failure) catch |err| switch (err) {
        error.Unmeasurable => strict,
        else => return err,
    };
    for (wf.rules, runs) |r, run_it| {
        if (!run_it) continue;
        if (r.threads > max_threads)
            return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "rule {s} requests {d} threads; the run allows {d}: raise --max-threads, or lower {s}", .{ r.name, r.threads, max_threads, if (overridden(opts.thread_overrides, r.labels.step)) try std.fmt.allocPrint(a, "--threads {s}", .{r.labels.step}) else "the rule's threads" }));
        const need = neededMib(&r, sizes);
        if (need > max_memory) {
            const with: []const u8 = if (r.shared_index.len > 0 and r.container != null)
                " with its shared inputs and its Podman client"
            else if (r.shared_index.len > 0)
                " with its shared inputs"
            else if (r.container != null)
                " with its Podman client"
            else
                "";
            return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "rule {s} needs {d} MiB{s}; the run allows {d} MiB: raise --max-memory, or lower the rule's memory", .{ r.name, need, with, max_memory }));
        }
    }
    const holders = try a.alloc(Holder, wf.shared.len);
    for (holders, sizes) |*h, z| h.* = if (z) |s| .{ .bytes = s.bytes, .mib = s.mib, .reserve_mib = s.reserve_mib } else .{ .bytes = 0, .mib = 0, .reserve_mib = 0 };
    const shared_info = try a.alloc(struct { name: []const u8, path: ?[]const u8, container: ?[]const u8, bytes: u64 }, wf.shared.len);
    for (wf.shared, holders, 0..) |s, h, i| shared_info[i] = .{ .name = s.name, .path = s.path_abs, .container = s.container, .bytes = h.bytes };

    if (tree) |t| {
        var shared_mib: u64 = 0;
        for (holders) |h| shared_mib += h.mib;
        if (shared_mib > 0) {
            const ok = protectScope(gpa, a, t, shared_mib, environ.get("PATH") orelse "/usr/bin:/bin", &host_envp, devnull);
            events.emit("memory_protected", .{ .memory_low_mib = shared_mib, .ok = ok });
        }
    }
    var containers_cg: ?cgroup.Group = null;
    if (podman != null) if (tree) |t| {
        containers_cg = cgroup.create(gpa, a, t, "containers", .{}) catch |err|
            return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "cannot create the cgroup for container clients: {s}", .{sys.errorText(err)}));
    };
    const sigfd = try process.setupSignals();
    defer sys.close(sigfd);

    var engine: Engine = .{
        .gpa = gpa,
        .a = a,
        .wf = wf,
        .g = g,
        .mask = mask,
        .opts = opts,
        .budget = .{
            .threads = max_threads,
            .memory_mib = max_memory,
            .jobs = max_jobs,
            .groups = blk: {
                const maxima = try a.alloc(u32, wf.groups.len);
                for (wf.groups, maxima) |grp, *m| m.* = grp.max;
                break :blk maxima;
            },
        },
        .usage = .{ .groups = blk: {
            const used = try a.alloc(u32, wf.groups.len);
            @memset(used, 0);
            break :blk used;
        } },
        .group_needs = blk: {
            const needs = try a.alloc([]const schedule.GroupNeed, wf.rules.len);
            for (wf.rules, needs) |r, *n| {
                const list = try a.alloc(schedule.GroupNeed, r.groups.len);
                for (r.groups, list) |gu, *need| need.* = .{ .index = groupIndex(wf, gu.name), .count = gu.count };
                n.* = list;
            }
            break :blk needs;
        },
        .priorities = blk: {
            const list = try a.alloc(i64, wf.rules.len);
            for (wf.rules, list) |r, *p| p.* = r.priority;
            break :blk list;
        },
        .ready_seq = blk: {
            const seq = try a.alloc(u64, wf.rules.len);
            @memset(seq, 0);
            break :blk seq;
        },
        .topo_pos = blk: {
            const pos = try a.alloc(usize, wf.rules.len);
            for (g.order, 0..) |ti, k| pos[ti] = k;
            break :blk pos;
        },
        .wake = undefined,
        .listed = blk: {
            const flags = try a.alloc(Listed, wf.rules.len);
            @memset(flags, .{});
            break :blk flags;
        },
        .tasks = try a.alloc(Task, wf.rules.len),
        .holders = holders,
        .group_reasons = blk: {
            const reasons = try a.alloc([]const u8, wf.groups.len);
            for (wf.groups, reasons) |grp, *s| s.* = try std.fmt.allocPrint(a, "group:{s}", .{grp.name});
            break :blk reasons;
        },
        .st = &st,
        .ids = &ids,
        .cut = &cut,
        .events = &events,
        .journal = &journal,
        .launch_dir = launch.dir,
        .launch_id = launch.id,
        .engine_id = state.engine_key_text,
        .env_text = env_text,
        .envp = host_envp,
        .podman = podman,
        .containers_cg = containers_cg,
        .images = images,
        .extras = extras,
        .bash = findBash(gpa) orelse {
            std.debug.print("kanit: bash not found\n", .{});
            return .invalid;
        },
        .devnull = devnull,
        .tree = tree,
        .network = null,
        .sigfd = sigfd,
        .selected = selected,
        .names = try naming.Names.init(a, wf.rules),
        .log = logging.Log.init(gpa, clock.Zone.load(gpa, a, environ.get("TZ"))),
        .tally = .{},
        .blocked_by = blk: {
            const roots = try a.alloc(usize, wf.rules.len);
            @memset(roots, 0);
            break :blk roots;
        },
        .footer_text = .init(gpa),
    };
    defer engine.log.deinit();
    defer engine.footer_text.deinit();
    defer engine.view_steps.deinit(gpa);
    defer engine.view_running.deinit(gpa);
    if (tree != null) {
        engine.network = Network.start(gpa, a, &engine.envp, tree.?.root) catch |err|
            return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "cannot create the run's network namespace: {s} ({s})", .{ sys.errorText(err), sys.errnoName() }));
    }
    defer if (engine.network) |n| n.stop();
    if (tree == null) engine.guard = Guard.start(a, &engine.envp, devnull) catch |err| guard: {
        std.debug.print("kanit: cannot start the guard of --no-isolation attempts ({s}); they may outlive a killed engine\n", .{sys.errorText(err)});
        break :guard null;
    };
    defer if (engine.guard) |gd| gd.stop();
    defer engine.pending_done.deinit(gpa);
    defer engine.pending_files.deinit(gpa);
    defer engine.pending_envs.deinit(gpa);
    defer engine.leftover_cgroups.deinit(gpa);
    defer engine.helpers.deinit(gpa);
    for (engine.tasks, 0..) |*t, i| {
        t.* = .{};
        if (!mask[i]) t.status = .excluded;
        t.max_attempts = 1 + (wf.rules[i].retries orelse opts.retry);
    }
    engine.tally.steps = try a.alloc(Group, engine.names.steps.len);
    @memset(engine.tally.steps, .{});
    engine.tally.samples = try a.alloc(Group, engine.names.samples.len);
    @memset(engine.tally.samples, .{});
    for (mask, 0..) |on, i| if (on) {
        engine.tally.status[@intFromEnum(Status.pending)] += 1;
        engine.tally.steps[engine.names.step_of[i]].selected += 1;
        if (engine.names.sample_of[i]) |k| engine.tally.samples[k].selected += 1;
    };
    engine.wake = .initContext(engine.topo_pos);
    defer engine.wake.deinit(gpa);
    defer engine.by_pid.deinit(gpa);
    defer engine.active.deinit(gpa);
    defer engine.staged.deinit(gpa);
    defer engine.ready_list.deinit(gpa);
    try engine.wake.ensureTotalCapacity(gpa, wf.rules.len);
    try engine.active.ensureTotalCapacity(gpa, wf.rules.len);
    try engine.staged.ensureTotalCapacity(gpa, wf.rules.len);
    try engine.ready_list.ensureTotalCapacity(gpa, wf.rules.len);
    for (g.order) |i| engine.wakeTask(i);
    engine.last_save_ns = sys.monoNs();
    engine.control_path = try std.fs.path.join(a, &.{ launch.dir, "control" });
    control: {
        const cfd = sys.openWrite(gpa, engine.control_path, .append) catch |err| {
            std.debug.print("kanit: cannot create {s} ({s}); `kanit control` will not reach this launch\n", .{ engine.control_path, sys.errorText(err) });
            break :control;
        };
        sys.close(cfd);
        const ifd = sys.check(linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK)) catch |err| {
            std.debug.print("kanit: cannot watch the control file ({s}); `kanit control` will not reach this launch\n", .{sys.errorText(err)});
            break :control;
        };
        const pz = try a.dupeZ(u8, engine.control_path);
        if (sys.check(linux.inotify_add_watch(@intCast(ifd), pz, linux.IN.MODIFY))) |_| {
            engine.control_watch = @intCast(ifd);
        } else |err| {
            std.debug.print("kanit: cannot watch the control file ({s}); `kanit control` will not reach this launch\n", .{sys.errorText(err)});
            sys.close(@intCast(ifd));
        }
    }
    defer if (engine.control_watch >= 0) sys.close(engine.control_watch);
    engine.next_sample_ns = engine.last_save_ns + sample_interval_ns;
    engine.last_sample_ns = engine.last_save_ns;
    if (engine.tree) |run_tree| engine.last_cpu_us = cgroup.cpuUsage(gpa, run_tree.root);
    {
        const marks = logging.marksFor(environ);
        var widths = engine.names.widths(mask);
        for (wf.shared) |sh| widths.step = @max(widths.step, naming.columns(sh.name));
        const requests = try a.alloc(u64, wf.rules.len + wf.shared.len);
        var max_threads_rule: u32 = 1;
        var nreq: usize = 0;
        for (wf.rules, 0..) |r, ri| if (mask[ri]) {
            requests[nreq] = r.memory_mib;
            nreq += 1;
            max_threads_rule = @max(max_threads_rule, r.threads);
        };
        for (holders) |h| if (h.mib > 0) {
            requests[nreq] = h.mib;
            nreq += 1;
        };
        var table = logging.Table.of(selected, widths, requests[0..nreq], max_threads_rule);
        if (!opts.isolation) table = table.unbounded();
        const tty = term.isTerminal(2);
        const cols = if (tty) term.size(2).cols else 0;
        var narrow = table;
        if (cols > 0 and cols < table.width() + 24) {
            narrow = logging.Table.of(selected, widths.capped(), requests[0..nreq], max_threads_rule);
            if (!opts.isolation) narrow = narrow.unbounded();
        }
        narrow.figures = cols == 0 or cols >= narrow.width() + 24;
        if (cols > 0) narrow = narrow.fitted(cols);
        const level: logging.Level = if (opts.quiet) .quiet else if (opts.verbose) .verbose else .normal;
        engine.log.sinks[0] = .{ .fd = 2, .style = .{ .color = opts.color and term.colorOn(2, environ), .marks = marks, .table = narrow, .cols = cols }, .level = level, .terminal = tty and level != .quiet };
        if (sys.openWrite(gpa, try std.fs.path.join(a, &.{ launch.dir, "launch.log" }), .append)) |fd| {
            engine.log.sinks[1] = .{ .fd = fd, .owned = true, .style = .{ .marks = marks, .table = table }, .level = .verbose, .terminal = false };
        } else |err| std.debug.print("kanit: cannot create {s}/launch.log ({s}); the launch keeps no text log\n", .{ launch.dir, sys.errorText(err) });
    }
    engine.start_mono = t_open;
    const t0 = t_open;
    var selected_names: std.ArrayList([]const u8) = .empty;
    for (wf.rules, 0..) |r, ri| if (mask[ri]) try selected_names.append(a, r.name);
    events.emit("launch_started", .{ .launch = launch.id, .selected = selected, .rules = selected_names.items, .max_threads = max_threads, .max_memory_mib = max_memory, .jobs = max_jobs, .isolation = opts.isolation, .cgroup = if (tree) |t| t.root else null, .shared = shared_info, .checks_s = @as(f64, @floatFromInt(sys.monoNs() - t_open)) / 1e9 });
    engine.page_path = try std.fs.path.join(a, &.{ launch.dir, "report.html" });
    {
        var budget: std.Io.Writer.Allocating = .init(a);
        try budget.writer.print("{d} threads, ", .{max_threads});
        try units.size(&budget.writer, @floatFromInt(max_memory));
        try budget.writer.print(", {d} jobs", .{max_jobs});
        if (opts.max_threads == null and opts.max_memory_mib == null) try budget.writer.writeAll(" (the defaults)");
        engine.measureVersions() catch {};
        var steps: std.ArrayList(logging.StepLine) = .empty;
        const first = try a.alloc(?usize, engine.names.steps.len);
        @memset(first, null);
        for (mask, 0..) |on, ri| if (on) {
            const k = engine.names.step_of[ri];
            if (first[k] == null or (engine.rule(first[k].?).version == null and engine.rule(ri).version != null)) first[k] = ri;
        };
        for (engine.tally.steps, engine.names.steps, first) |grp, step, rep_rule| if (grp.selected > 0) {
            const ri = rep_rule.?;
            const tool: ?[]const u8 = if (engine.names.tool[ri].len > 0) engine.names.tool[ri] else step.tool;
            try steps.append(a, .{ .name = step.name, .tool = tool, .rules = grp.selected, .version = engine.versionOf(ri) });
        };
        var samples: usize = 0;
        for (engine.tally.samples) |grp| samples += @intFromBool(grp.selected > 0);
        engine.latest_shown = monitor.shownPath(a, try std.fs.path.join(a, &.{ rec, "latest" }));
        engine.log.opening(.{
            .version = version,
            .workflow = wf.name,
            .launch = launch.id,
            .rules = selected,
            .samples = samples,
            .steps = steps.items,
            .budget = budget.written(),
            .isolated = opts.isolation,
            .records = try std.fmt.allocPrint(a, "{s}/", .{engine.latest_shown}),
            .page = engine.page_path != null,
        });
        engine.next_beat_ns = sys.monoNs() + logging.heartbeat_ns;
    }
    engine.drawPage();
    engine.tick(true);

    engine.loop() catch |err| {
        engine.fatal = sys.errorText(err);
        engine.beginStop();
        engine.beginEnding();
        while (engine.running() > 0) {
            var fds = [_]linux.pollfd{.{ .fd = sigfd, .events = linux.POLL.IN, .revents = 0 }};
            process.wait(&fds, engine.nextDeadline());
            _ = process.readSignals(sigfd);
            engine.reapAll() catch {};
            engine.checkTimers();
            engine.finishEnded() catch {};
        }
    };
    engine.beginEnding();
    engine.awaitVersions(10);
    engine.awaitHelpers(engine.opts.grace_s +| 10);
    engine.writeVersions() catch |err| std.debug.print("kanit: cannot write versions.json: {s}\n", .{sys.errorText(err)});

    var ran = false;
    for (engine.tasks) |t| ran = ran or t.status == .completed;
    var post = state.Identities.init(gpa);
    defer post.deinit();
    var post_cut = if (ran) try state.Cutoff.init(a, gpa, wf, engine.st, &post, false) else undefined;
    var check: std.heap.ArenaAllocator = .init(gpa);
    defer check.deinit();
    if (ran) for (wf.rules, 0..) |*r, i| {
        const t = &engine.tasks[i];
        if (t.status != .completed) continue;
        const k = t.key orelse continue;
        var missing: ?[]const u8 = null;
        _ = check.reset(.retain_capacity);
        const again = state.ruleKey(check.allocator(), &post, wf, g.parents[i], i, engine.st, &post_cut, TaskKeys{ .tasks = engine.tasks }, env_text, state.engine_key_text, engine.extras[i], &missing) catch |err| switch (err) {
            error.Unreadable => null,
            else => return err,
        };
        if (again == null or !std.mem.eql(u8, again.?.inputs, k.inputs)) {
            engine.fatal = try std.fmt.allocPrint(a, "inputs of rule {s} changed during the run", .{r.name});
            engine.setStatus(i, .failed);
            t.reason = "its inputs changed while the launch ran; run it again";
            engine.events.emit("task_failed", .{ .rule = r.name, .attempt = t.attempts, .reason = t.reason });
            _ = engine.st.data.rules.map.swapRemove(r.name);
            engine.dirty = true;
        }
    };

    for (engine.tasks, 0..) |t, i| if (t.status == .pending or t.status == .ready) {
        engine.setStatus(i, if (engine.interrupted) .cancelled else .not_started);
    };
    engine.dirty = true;
    try engine.saveState(true);
    try records.Journal.reset(gpa, rec);
    for (engine.leftover_cgroups.items) |path| cgroup.removePath(gpa, path) catch {};
    if (engine.control_watch >= 0) engine.readControl() catch {};

    var counts: [@typeInfo(Status).@"enum".fields.len]usize = @splat(0);
    for (engine.tasks) |t| counts[@intFromEnum(t.status)] += 1;
    const failed = counts[@intFromEnum(Status.failed)] + counts[@intFromEnum(Status.blocked)] + counts[@intFromEnum(Status.not_started)];
    const stopped = !engine.interrupted and engine.fatal == null and counts[@intFromEnum(Status.failed)] == 0 and counts[@intFromEnum(Status.cancelled)] > 0;
    const outcome: Outcome = if (engine.interrupted) .interrupted else if (failed > 0 or engine.fatal != null) .failed else .ok;
    var failures: std.ArrayList(Failure) = .empty;
    for (engine.tasks, 0..) |t, i| switch (t.status) {
        .failed, .blocked, .cancelled => try failures.append(a, .{
            .rule = engine.rule(i).name,
            .status = @tagName(t.status),
            .reason = t.reason,
            .stderr = if (t.dir.len > 0) try std.fmt.allocPrint(a, "{s}/stderr.log", .{t.dir}) else null,
            .diagnostics = try records.diagnosticPaths(a, t.dir, t.diagnostics),
        }),
        else => {},
    };
    const elapsed = @as(f64, @floatFromInt(sys.monoNs() - t0)) / 1e9;
    const summary: Summary = .{
        .engine = engine_id,
        .launch = launch.id,
        .status = if (stopped) "stopped" else switch (outcome) {
            .ok => "completed",
            .interrupted => "interrupted",
            else => "failed",
        },
        .counts = .{
            .completed = counts[@intFromEnum(Status.completed)],
            .reused = counts[@intFromEnum(Status.reused)],
            .failed = counts[@intFromEnum(Status.failed)],
            .blocked = counts[@intFromEnum(Status.blocked)],
            .cancelled = counts[@intFromEnum(Status.cancelled)],
            .not_started = counts[@intFromEnum(Status.not_started)],
        },
        .selected = selected,
        .elapsed_s = elapsed,
        .finished = try records.timeText(a, sys.realNs()),
        .@"error" = engine.fatal,
        .previous_bytes = engine.previous_bytes,
        .engine_cost = engineCost(),
        .launch_dir = launch.dir,
        .failures = failures.items,
    };
    try writeSummary(gpa, a, &events, summary);
    engine.drawPage();
    var source: summary_text.Source = undefined;
    const read = source.load(gpa, launch.dir);
    defer if (read) |_| source.deinit() else |_| {};
    if (engine.log.sinks[1]) |file| {
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try text.writer.writeAll("\n");
        if (read) |_| summary_text.render(&source, &text.writer, .{ .marks = file.style.marks }) catch {} else |_| {}
        engine.log.raw(1, text.written());
    }
    engine.endLog();
    if (!opts.json) {
        try read;
        const tty = term.isTerminal(1);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        if (tty and engine.finished > 0 and !opts.quiet) try out.writer.writeAll("\n");
        try summary_text.render(&source, &out.writer, .{ .color = opts.color and term.colorOn(1, environ), .marks = logging.marksFor(environ), .cols = if (tty) term.size(1).cols else 0 });
        try sys.writeAll(1, out.written());
        return outcome;
    }
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.print("{f}\n", .{std.json.fmt(summary, .{})});
    try sys.writeAll(1, w.written());
    return outcome;
}

pub const ManifestCheck = struct { ok: bool, usable: bool = true, files: usize = 0, read: usize = 0, bytes_read: u64 = 0, seconds: f64 = 0 };

pub fn checkManifest(gpa: Allocator, st: *state.State, ids: *state.Identities, mpath: []const u8, save: bool, notes: *std.Io.Writer) !ManifestCheck {
    const t0 = sys.monoNs();
    var res: ManifestCheck = .{ .ok = true };
    const bytes = sys.readFile(gpa, mpath, 256 << 20) catch |err| {
        try notes.print("kanit: cannot read input manifest {s}: {s}\n", .{ mpath, sys.errorText(err) });
        return .{ .ok = false, .usable = false };
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch {
        try notes.print("kanit: input manifest {s} must be a JSON object of absolute paths\n", .{mpath});
        return .{ .ok = false, .usable = false };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try notes.print("kanit: input manifest {s} must be a JSON object of absolute paths\n", .{mpath});
        return .{ .ok = false, .usable = false };
    }
    const sa = st.allocator();
    var hashed_any = false;
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        const path = e.key_ptr.*;
        res.files += 1;
        var want: []const u8 = "";
        var stamp: ?std.json.ObjectMap = null;
        switch (e.value_ptr.*) {
            .string => |s| want = s,
            .object => |o| {
                if (o.get("sha256")) |v| if (v == .string) {
                    want = v.string;
                };
                if (o.get("stamp")) |v| if (v == .object) {
                    stamp = v.object;
                };
            },
            else => {},
        }
        if (!std.fs.path.isAbsolute(path) or !std.mem.startsWith(u8, want, "sha256:") or want.len != 71) {
            try notes.print("kanit: invalid input manifest entry {s}\n", .{path});
            res.ok = false;
            continue;
        }
        if (sys.stat(gpa, path) catch null) |id| if (!id.isReg()) {
            try notes.print("kanit: input manifest entry is not a regular file: {s}\n", .{path});
            res.ok = false;
            continue;
        };
        const id_text = (ids.get(path) catch |err| switch (err) {
            error.Unreadable => {
                try notes.print("kanit: {s}\n", .{ids.problem});
                res.ok = false;
                continue;
            },
            else => return err,
        }) orelse {
            try notes.print("kanit: input manifest file is missing: {s}\n", .{path});
            res.ok = false;
            continue;
        };
        const cached = st.data.manifest.map.get(path);
        var digest: []const u8 = undefined;
        if (cached != null and std.mem.eql(u8, cached.?.id, id_text)) {
            digest = cached.?.sha256;
        } else if (stamp != null and stampMatches(stamp.?, (try sys.stat(gpa, path)).?)) {
            digest = try sa.dupe(u8, want);
            try st.data.manifest.map.put(sa, try sa.dupe(u8, path), .{ .id = try sa.dupe(u8, id_text), .sha256 = digest });
            hashed_any = true;
        } else {
            const id = (try sys.stat(gpa, path)).?;
            res.read += 1;
            res.bytes_read += id.size;
            const d = try sys.sha256File(gpa, path);
            digest = try std.fmt.allocPrint(sa, "sha256:{s}", .{&d});
            try st.data.manifest.map.put(sa, try sa.dupe(u8, path), .{ .id = try sa.dupe(u8, id_text), .sha256 = digest });
            hashed_any = true;
        }
        if (!std.mem.eql(u8, digest, want)) {
            try notes.print("kanit: input does not match its manifest digest: {s}\n", .{path});
            res.ok = false;
        }
    }
    if (save and res.ok and hashed_any) try st.save(gpa);
    res.seconds = @as(f64, @floatFromInt(sys.monoNs() - t0)) / 1e9;
    return res;
}

fn stampMatches(stamp: std.json.ObjectMap, id: sys.Identity) bool {
    const field = struct {
        fn int(m: std.json.ObjectMap, k: []const u8) ?i128 {
            const v = m.get(k) orelse return null;
            return switch (v) {
                .integer => |x| x,
                .number_string => |s| std.fmt.parseInt(i128, s, 10) catch null,
                else => null,
            };
        }
    }.int;
    return field(stamp, "ino") == @as(i128, id.ino) and
        field(stamp, "size") == @as(i128, id.size) and field(stamp, "mtime_ns") == id.mtime_ns and field(stamp, "ctime_ns") == id.ctime_ns;
}
