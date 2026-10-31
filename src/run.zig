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
const container = @import("container.zig");
const plan = @import("plan.zig");
const model = @import("model.zig");
const html = @import("html.zig");
const monitor = @import("monitor.zig");
const units = @import("units.zig");
const term = @import("term.zig");
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
    /// Rules to run even when reusable (`--rerun-rule`); their consumers
    /// follow when their outputs change.
    rerun_rules: []const []const u8 = &.{},

    input_manifest: ?[]const u8 = null,
    isolation: bool = true,
    pass_env: []const []const u8 = &.{},
    /// `--threads STEP=N` as given, applied to the workflow before the run.
    thread_overrides: []const []const u8 = &.{},
    grace_s: u64 = 10,
    quiet: bool = false,
    /// The summary as JSON even when standard output is a terminal.
    json: bool = false,
    /// Colors on a terminal; `NO_COLOR` and `TERM=dumb` also turn them off.
    color: bool = true,
    /// systemd slice the isolated run's scope is placed in.
    slice: ?[]const u8 = null,

    pub fn forced(self: Options, name: []const u8) bool {
        if (self.rerun) return true;
        for (self.rerun_rules) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

pub const Outcome = enum(u8) { ok = 0, failed = 1, invalid = 2, interrupted = 130 };

const Status = enum { pending, ready, staging, running, completed, reused, failed, blocked, cancelled, not_started, excluded };

/// The run's progress on a terminal: event lines scroll above one status
/// line, drawn again about once a second. Off a terminal, or with --quiet,
/// the engine prints plain lines and no status line.
const Console = struct {
    on: bool = false,
    color: bool = false,
    /// A status line is on screen and must be cleared before other output.
    shown: bool = false,
    next_ns: i128 = 0,
};

const Task = struct {
    status: Status = .pending,
    ready_seq: u64 = 0,
    attempts: u32 = 0,
    max_attempts: u32 = 1,
    key: ?state.Key = null,
    pid: linux.pid_t = 0,
    cg: ?[]const u8 = null,
    /// The largest anonymous memory sampled while the attempt runs.
    anon_peak: ?u64 = null,
    /// Why a cancelled attempt was stopped.
    stop_why: []const u8 = "cancelled",
    dir: []const u8 = "",
    started_ns: i128 = 0,
    started_real: i128 = 0,
    deadline_ns: ?i128 = null,
    kill_at: ?i128 = null,
    /// The exit of a stopped attempt's shell, kept while processes it
    /// started still run: they get the rest of the grace period to end.
    ended: ?process.Reaped = null,
    timed_out: bool = false,
    cancelled: bool = false,
    /// Why the shared service the attempt joined failed while it ran; the
    /// attempt is stopped and fails without a retry.
    lost_service: ?[]const u8 = null,
    /// The current attempt's process started: what is at its output paths
    /// after it ends may be its own.
    spawned: bool = false,
    reason: []const u8 = "",
    /// The diagnostics kept from the last attempt, as the rule wrote them.
    diagnostics: []const []const u8 = &.{},
    /// When the current attempt became ready (monotonic).
    ready_ns: i128 = 0,
    /// What keeps the ready attempt from starting, and since when.
    wait_reason: ?[]const u8 = null,
    wait_since: i128 = 0,
    waits: std.ArrayList(Wait) = .empty,
    /// Seconds from ready to start of the current attempt.
    queued_s: f64 = 0,
    /// Podman container name of the current attempt of a container rule.
    container_name: ?[]const u8 = null,
};

/// Time a ready attempt spent waiting for one reason.
const Wait = struct { reason: []const u8, seconds: f64 };

/// A tool's version command, run once per launch beside the rules: in the
/// rule's image for a container rule, else on the host.
const Version = struct {
    command: []const u8,
    /// Image reference and ID, or null for a host rule.
    container: ?[]const u8,
    image: ?[]const u8,
    /// Its standard output and error.
    file: []const u8,
    pid: linux.pid_t = 0,
    started: bool = false,
    /// Exit status, 128 + N for signal N; null until it ends.
    exit_code: ?u32 = null,
    /// Killed when the launch ended before it did.
    stopped: bool = false,
};

/// The keys this launch gives its rules, for `state.ruleKey`.
const TaskKeys = struct {
    tasks: []const Task,
    pub fn get(self: TaskKeys, p: usize) ?[]const u8 {
        return if (self.tasks[p].key) |k| k.key else null;
    }
};

/// Without isolation: the `__guard` child that kills the process groups of
/// running tasks if the engine dies (see `guard` in main).
const Guard = struct {
    pid: linux.pid_t,
    fd: sys.Fd,

    fn start(a: Allocator, envp: *const process.Vec, devnull: sys.Fd) !Guard {
        var pipe: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
        defer sys.close(pipe[0]);
        errdefer sys.close(pipe[1]);
        const exe = try sys.childExe(a);
        const argv = try process.Vec.init(a, &.{ "workz", "__guard" });
        const spec: process.Spec = .{ .path = exe.ptr, .argv = argv.items.ptr, .envp = envp.items.ptr, .cwd = "/", .stdin = pipe[0], .stdout = devnull, .stderr = 2 };
        return .{ .pid = try process.spawn(&spec), .fd = pipe[1] };
    }

    fn note(self: Guard, sign: u8, pgid: linux.pid_t) void {
        var buf: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{c}{d}\n", .{ sign, pgid }) catch return;
        sys.writeAll(self.fd, text) catch {};
    }

    /// Ends the guard; it kills the process groups of tasks still noted.
    fn stop(self: Guard) void {
        sys.close(self.fd);
        var status: u32 = 0;
        _ = linux.wait4(self.pid, &status, 0, null);
    }
};

/// The run's user and network namespaces, held by a `__netns` child that
/// also kills the run's cgroup if the engine dies (see `netns` in main).
const Network = struct {
    pid: linux.pid_t,
    userns: sys.Fd,
    netns: sys.Fd,
    /// Write end of the holder's stdin, held only by the engine.
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
        const argv = try process.Vec.init(a, &.{ "workz", "__netns", try std.fmt.allocPrint(a, "{s}/cgroup.kill", .{run_cgroup}) });
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

    /// Kills the holder before closing its stdin, so it never acts.
    fn stop(self: Network) void {
        sys.close(self.userns);
        sys.close(self.netns);
        process.signalPid(self.pid, .KILL);
        var status: u32 = 0;
        _ = linux.wait4(self.pid, &status, 0, null);
        sys.close(self.alive);
    }
};

const HolderState = enum { idle, loading, ready, stopping, failed };

const Holder = struct {
    bytes: u64,
    /// What it holds: a service's declared memory, its limit, or the pages
    /// of mapped files.
    mib: u64,
    /// What it takes from the budget: `mib`, and a service's Podman client.
    reserve_mib: u64,
    users: u32 = 0,
    st: HolderState = .idle,
    pid: linux.pid_t = 0,
    pipe: sys.Fd = -1,
    cg: ?[]const u8 = null,
    /// A service's container name and the engine's end of its stop FIFO,
    /// which the engine closes to stop it.
    container_name: ?[]const u8 = null,
    stop_fd: sys.Fd = -1,
    /// Starts of this holder in the launch, which name its containers.
    starts: u32 = 0,
    /// Attempts that started using it since it last started, and when
    /// that was (monotonic).
    served: u32 = 0,
    started_ns: i128 = 0,
    /// When a stopping holder is killed.
    kill_at: ?i128 = null,
    /// Why the holder failed; rules that need it fail with this reason.
    failure: ?[]const u8 = null,
    /// Starts that failed before ready and were retried.
    failed_starts: u32 = 0,
    /// Its memory is counted against the budget: from its first user's
    /// admission until no rule left to run needs it.
    held: bool = false,
    /// When a loading service is given up on, and whether it was.
    ready_deadline: ?i128 = null,
    timed_out: bool = false,
};

/// Default budget: every online CPU and three quarters of physical memory.
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
    max_threads: u32,
    max_memory: u64,
    max_jobs: u32,

    tasks: []Task,
    holders: []Holder,
    group_used: []u32,
    /// "group:NAME" per resource group, the wait reason it reports.
    group_reasons: []const []const u8,
    threads_used: u32 = 0,
    memory_used: u64 = 0,
    jobs_used: u32 = 0,
    ready_counter: u64 = 0,

    st: *state.State,
    ids: *state.Identities,
    cut: *state.Cutoff,
    events: *records.Events,
    journal: *records.Journal,
    launch_dir: []const u8,
    launch_id: []const u8,
    /// Engine part of every rule key (state.engine_key_text).
    engine_id: []const u8,
    /// Environment part of rule keys (state.envText).
    env_text: []const u8,
    envp: process.Vec,
    bash: [:0]const u8,
    devnull: sys.Fd,
    tree: ?cgroup.Tree,
    /// The run's network for shell rules, when isolated.
    network: ?Network,
    /// The guard of a run without isolation.
    guard: ?Guard = null,
    /// Critical-path rank per rule (computeRanks), empty until needed.
    ranks: []const f64 = &.{},
    /// The launch's `control` file, watched through inotify, and how much
    /// of it has been read.
    control_path: []const u8 = "",
    control_watch: sys.Fd = -1,
    control_offset: u64 = 0,
    /// Inside a control line too long to be a command, skipped to its end.
    control_skip: bool = false,
    /// Podman, when the selected rules use containers.
    podman: ?[]const u8 = null,
    /// cgroup of the podman clients and conmon processes, when isolated.
    containers_cg: ?[]const u8 = null,
    images: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Per rule: key text beyond the command (image ID, joined service).
    extras: []const []const u8 = &.{},
    sigfd: sys.Fd,

    stopping: bool = false,
    /// No rule starts or stops any more: the launch writes its records, and
    /// control commands are answered without being applied.
    ending: bool = false,
    interrupted: bool = false,
    interrupted_at: i128 = 0,
    /// When the first INT, TERM or HUP arrived; a `control cancel` is not one.
    signalled_at: ?i128 = null,
    fatal: ?[]const u8 = null,
    dirty: bool = false,
    pending_done: std.ArrayList([]const u8) = .empty,
    last_save_ns: i128 = 0,
    /// When the budget last got something back: an attempt ended, or a
    /// shared input's memory was returned.
    freed_ns: i128 = 0,
    /// Run samples: the next sample time and the CPU counter at the last one.
    next_sample_ns: i128 = 0,
    last_sample_ns: i128 = 0,
    last_cpu_us: ?u64 = null,
    /// The launch's page, drawn again while it runs; null once it cannot
    /// be written.
    page_path: ?[]const u8 = null,
    next_page_ns: i128 = 0,
    leftover_cgroups: std.ArrayList([]const u8) = .empty,
    /// Podman commands started without waiting (`stop`, `rm`); reaped like
    /// every child, and waited for before the launch ends.
    helpers: std.ArrayList(linux.pid_t) = .empty,
    finished: usize = 0,
    selected: usize = 0,
    /// Bytes of earlier outputs moved into attempts' `previous/`.
    previous_bytes: u64 = 0,
    /// The version commands of this launch, and the one running.
    versions: std.ArrayList(Version) = .empty,
    version_running: ?usize = null,
    console: Console = .{},
    /// Monotonic time the launch opened, for the elapsed time on the console.
    start_mono: i128 = 0,

    fn progress(self: *Engine, comptime verb: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (self.opts.quiet) return;
        self.event(verb, fmt, args);
    }

    /// Failures are printed even in quiet mode.
    fn alert(self: *Engine, comptime verb: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.event(verb, fmt, args);
    }

    /// One event line, `[finished/selected] verb details`. On a terminal the
    /// verb is colored and the status line is drawn again below the line; a
    /// start shows only in the status line.
    fn event(self: *Engine, comptime verb: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!self.console.on) {
            std.debug.print("[{d}/{d}] " ++ verb ++ " " ++ fmt ++ "\n", .{ self.finished, self.selected } ++ args);
            return;
        }
        if (comptime std.mem.eql(u8, verb, "started")) return self.drawStatus(true);
        const s: term.Style = .{ .on = self.console.color };
        const tint = comptime if (std.mem.eql(u8, verb, "completed"))
            "\x1b[32m"
        else if (std.mem.eql(u8, verb, "failed"))
            "\x1b[31;1m"
        else if (std.mem.eql(u8, verb, "blocked"))
            "\x1b[31m"
        else if (std.mem.eql(u8, verb, "cancelled"))
            "\x1b[35m"
        else if (std.mem.eql(u8, verb, "retrying") or std.mem.eql(u8, verb, "restarting"))
            "\x1b[33m"
        else
            "\x1b[36m";
        self.clearStatus();
        std.debug.print("{s}{d:>5}/{d}{s}  {s}{s:<10}{s} " ++ fmt ++ "\n", .{ s.dim(), self.finished, self.selected, s.reset(), if (s.on) tint else "", verb, s.reset() } ++ args);
        self.drawStatus(true);
    }

    /// On a terminal, the last `n` lines of an attempt's standard error under
    /// its event line, aligned with the event's text.
    fn showTail(self: *Engine, dir: []const u8, n: usize) void {
        const path = std.fmt.allocPrint(self.a, "{s}/stderr.log", .{dir}) catch return;
        self.showLines(path, n, null);
    }

    /// On a terminal, the last `n` lines of file `path`, indented under the
    /// rule's line, after `title` when given.
    fn showLines(self: *Engine, path: []const u8, n: usize, title: ?[]const u8) void {
        if (!self.console.on) return;
        var digits: usize = 1;
        var v = self.selected;
        while (v >= 10) : (v /= 10) digits += 1;
        const indent = 19 + digits;
        const lines = monitor.lastLines(self.gpa, self.a, path, n, term.size(2).cols -| (indent + 3));
        if (lines.len == 0) return;
        const s: term.Style = .{ .on = self.console.color };
        self.clearStatus();
        if (title) |t| {
            for (0..indent) |_| std.debug.print(" ", .{});
            std.debug.print("{s}{s}:{s}\n", .{ s.dim(), t, s.reset() });
        }
        for (lines) |line| {
            for (0..indent) |_| std.debug.print(" ", .{});
            std.debug.print("{s}| {s}{s}\n", .{ s.dim(), line, s.reset() });
        }
        self.drawStatus(true);
    }

    /// On a terminal, one line for the rules a pass found blocked: up to
    /// three names and how many more.
    fn showBlocked(self: *Engine, names: []const []const u8, count: usize) void {
        if (!self.console.on or count == 0) return;
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (names, 0..) |name, k| w.print("{s}{s}", .{ if (k == 0) "" else ", ", name }) catch {};
        if (count > names.len) w.print(" and {d} more", .{count - names.len}) catch {};
        w.print(": {s} a rule that did not complete", .{if (count == 1) "it needs" else "they need"}) catch {};
        self.event("blocked", "{s}", .{w.buffered()});
    }

    /// A message of its own on the console, such as the interrupt notice.
    fn note(self: *Engine, text: []const u8) void {
        self.clearStatus();
        std.debug.print("{s}\n", .{text});
        self.drawStatus(true);
    }

    fn clearStatus(self: *Engine) void {
        if (!self.console.shown) return;
        std.debug.print("\r\x1b[K", .{});
        self.console.shown = false;
    }

    /// Draws the status line: a bar of the rules done, running and waiting,
    /// the counts, the elapsed time and the rules running, cut to the
    /// terminal's width. It is drawn at most once a second unless `force`.
    fn drawStatus(self: *Engine, force: bool) void {
        if (!self.console.on) return;
        const now = sys.monoNs();
        if (!force and now < self.console.next_ns) return;
        self.console.next_ns = now + std.time.ns_per_s;
        var done: usize = 0;
        var active: usize = 0;
        var waiting: usize = 0;
        var failed: usize = 0;
        var blocked: usize = 0;
        for (self.tasks, 0..) |t, i| {
            if (!self.mask[i]) continue;
            switch (t.status) {
                .completed, .reused => done += 1,
                .running, .staging => active += 1,
                .ready => waiting += 1,
                .failed => failed += 1,
                .blocked => blocked += 1,
                else => {},
            }
        }
        const cols = term.size(2).cols -| 1;
        const s: term.Style = .{ .on = self.console.color };
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var used: usize = 0;
        const width: usize = if (cols >= 80) 24 else 12;
        const total = @max(self.selected, 1);
        const parts = [_]struct { n: usize, bg: []const u8, ch: u8 }{
            .{ .n = done, .bg = "\x1b[42m", .ch = '#' },
            .{ .n = active, .bg = "\x1b[46m", .ch = '>' },
            .{ .n = failed + blocked, .bg = "\x1b[41m", .ch = '!' },
            .{ .n = waiting, .bg = "\x1b[43m", .ch = '~' },
        };
        if (!s.on) w.writeAll("[") catch {};
        var filled: usize = 0;
        for (parts) |p| {
            var n = p.n * width / total;
            if (n == 0 and p.n > 0) n = 1;
            n = @min(n, width - filled);
            if (n == 0) continue;
            if (s.on) w.writeAll(p.bg) catch {};
            for (0..n) |_| w.writeByte(if (s.on) ' ' else p.ch) catch {};
            if (s.on) w.writeAll("\x1b[0m") catch {};
            filled += n;
        }
        if (s.on) w.writeAll("\x1b[100m") catch {};
        for (0..width - filled) |_| w.writeByte(if (s.on) ' ' else '.') catch {};
        w.writeAll(if (s.on) "\x1b[0m" else "]") catch {};
        used += width + @as(usize, if (s.on) 0 else 2);
        var text: [160]u8 = undefined;
        var tw: std.Io.Writer = .fixed(&text);
        tw.print(" {d}/{d}  {d} running  {d} waiting  {d} failed", .{ done, self.selected, active, waiting, failed }) catch {};
        if (blocked > 0) tw.print("  {d} blocked", .{blocked}) catch {};
        tw.writeAll("  ") catch {};
        units.duration(&tw, @as(f64, @floatFromInt(now - self.start_mono)) / 1e9) catch {};
        const counts = tw.buffered();
        const shown = counts[0..@min(counts.len, cols -| used)];
        w.print("{s}{s}{s}", .{ s.bold(), shown, s.reset() }) catch {};
        used += shown.len;
        // The rules running, as many as fit.
        var first = true;
        var left: usize = 0;
        for (self.tasks, 0..) |t, i| {
            if (t.status != .running) continue;
            const name = self.rule(i).name;
            const sep: []const u8 = if (first) "  " else ", ";
            if (used + sep.len + name.len + 8 > cols) {
                left += 1;
                continue;
            }
            w.print("{s}{s}{s}{s}", .{ sep, s.cyan(), name, s.reset() }) catch {};
            used += sep.len + name.len;
            first = false;
        }
        if (left > 0 and used + 8 <= cols) w.print(" +{d}", .{left}) catch {};
        std.debug.print("\r{s}\x1b[K", .{w.buffered()});
        self.console.shown = true;
    }

    fn rule(self: *Engine, i: usize) *const workflow.Rule {
        return &self.wf.rules[i];
    }

    // ---- readiness and reuse ----

    fn updateReadiness(self: *Engine) !void {
        var names: [3][]const u8 = undefined;
        var newly_blocked: usize = 0;
        defer self.showBlocked(names[0..@min(newly_blocked, names.len)], newly_blocked);
        for (self.g.order) |i| {
            const t = &self.tasks[i];
            if (t.status != .pending) continue;
            var all_done = true;
            var blocked = false;
            for (self.g.parents[i]) |p| switch (self.tasks[p].status) {
                .completed, .reused, .excluded => {},
                .failed, .blocked, .cancelled, .not_started => blocked = true,
                else => all_done = false,
            };
            if (blocked) {
                t.status = .blocked;
                t.reason = "it needs a rule that did not complete";
                self.finished += 1;
                self.events.emit("task_blocked", .{ .rule = self.rule(i).name });
                if (newly_blocked < names.len) names[newly_blocked] = self.rule(i).name;
                newly_blocked += 1;
                continue;
            }
            if (!all_done or self.stopping) continue;
            try self.makeReady(i);
        }
    }

    fn makeReady(self: *Engine, i: usize) !void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        var missing: ?[]const u8 = null;
        // An input a producer left unreadable fails the rule like a missing one.
        var unreadable = false;
        const key = state.ruleKey(self.a, self.ids, self.wf, self.g.parents[i], i, self.st, self.cut, TaskKeys{ .tasks = self.tasks }, self.env_text, self.engine_id, self.extras[i], &missing) catch |err| switch (err) {
            error.Unreadable => blk: {
                unreadable = true;
                break :blk null;
            },
            else => return err,
        };
        if (key == null) {
            t.status = .failed;
            t.reason = if (unreadable) self.ids.problem else try std.fmt.allocPrint(self.a, "missing input {s}", .{missing.?});
            self.finished += 1;
            self.events.emit("task_failed", .{ .rule = r.name, .attempt = @as(?u32, null), .reason = t.reason });
            self.alert("failed", "{s}: {s}", .{ r.name, t.reason });
            if (!self.opts.keep_going) self.beginStop();
            return;
        }
        t.key = key.?;
        if (!self.opts.forced(r.name)) if (self.st.data.rules.map.get(r.name)) |e| {
            if (try state.reuseCheck(self.gpa, self.ids, &e, &key.?) == .reuse) {
                // A state from before environments were recorded gains this one.
                if (!self.st.data.envs.map.contains(e.env)) {
                    const sa = self.st.allocator();
                    try self.st.data.envs.map.put(sa, try sa.dupe(u8, e.env), try sa.dupe(u8, self.env_text));
                    self.dirty = true;
                }
                t.status = .reused;
                self.finished += 1;
                self.events.emit("task_reused", .{ .rule = r.name });
                return;
            }
        };
        t.status = .ready;
        self.ready_counter += 1;
        t.ready_seq = self.ready_counter;
        t.ready_ns = sys.monoNs();
    }

    // ---- admission ----

    /// Why rule i cannot start even on an idle budget, or null.
    fn neverFits(self: *Engine, i: usize) ?[]const u8 {
        const r = self.rule(i);
        var need = reservedMib(r);
        for (r.shared_index) |hi| need += self.holders[hi].reserve_mib;
        if (r.threads <= self.max_threads and need <= self.max_memory) return null;
        return std.fmt.allocPrint(self.a, "it needs {d} threads and {d} MiB; the run allows {d} threads and {d} MiB", .{ r.threads, need, self.max_threads, self.max_memory }) catch "it needs more than the run allows";
    }

    /// The first resource that keeps a ready rule from starting, or null
    /// when it fits: "jobs", "threads", "memory" or "group:NAME".
    fn blocker(self: *Engine, i: usize) ?[]const u8 {
        return self.blockerFreeing(i, 0);
    }

    /// `blocker` as if `freed_mib` of reserved memory were returned.
    fn blockerFreeing(self: *Engine, i: usize, freed_mib: u64) ?[]const u8 {
        const r = self.rule(i);
        // Threads and memory first: when they and the job count are full
        // together, as with one-thread rules and the default --jobs, the
        // reason names the resource.
        if (self.threads_used + r.threads > self.max_threads) return "threads";
        var mem = reservedMib(r);
        for (r.shared_index) |hi| {
            const h = &self.holders[hi];
            if (!h.held) mem += h.reserve_mib;
        }
        if (self.memory_used - freed_mib + mem > self.max_memory) return "memory";
        if (self.jobs_used + 1 > self.max_jobs) return "jobs";
        for (r.groups) |gu| {
            const gi = groupIndex(self.wf, gu.name);
            if (self.group_used[gi] + gu.count > self.wf.groups[gi].max) return self.group_reasons[gi];
        }
        return null;
    }

    /// Starts, changes or ends the current wait of a ready attempt.
    fn setWait(self: *Engine, i: usize, reason: ?[]const u8) !void {
        const t = &self.tasks[i];
        if (t.wait_reason) |cur| {
            if (reason != null and std.mem.eql(u8, cur, reason.?)) return;
            try self.closeWait(t, cur);
        }
        t.wait_reason = reason;
        t.wait_since = sys.monoNs();
        if (reason) |why| self.events.emit("task_waiting", .{ .rule = self.rule(i).name, .reason = why });
    }

    /// Ends the wait of a rule that starts. A wait for a part of the budget
    /// lasted until the budget last got something back; the time after it
    /// went to the engine itself, recording the attempts that ended and
    /// starting the rules before this one, and counts as `starting`.
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
        const r = self.rule(i);
        if (take) {
            self.jobs_used += 1;
            self.threads_used += r.threads;
            self.memory_used += reservedMib(r);
        } else {
            self.jobs_used -= 1;
            self.threads_used -= r.threads;
            self.memory_used -= reservedMib(r);
            self.freed_ns = sys.monoNs();
        }
        for (r.groups) |gu| {
            const gi = groupIndex(self.wf, gu.name);
            if (take) self.group_used[gi] += gu.count else self.group_used[gi] -= gu.count;
        }
    }

    fn admit(self: *Engine) !void {
        if (self.stopping) return;
        var ready: std.ArrayList(usize) = .empty;
        defer ready.deinit(self.gpa);
        for (self.tasks, 0..) |t, i| if (t.status == .ready) try ready.append(self.gpa, i);
        if (ready.items.len > 1 and self.ranks.len == 0) try self.computeRanks();
        std.mem.sort(usize, ready.items, self, readyBefore);
        for (ready.items) |i| {
            if (self.stopping) break;
            // The launch checked the rules it expected to run; one that runs
            // anyway and can never fit fails instead of waiting.
            if (self.neverFits(i)) |why| {
                try self.setWait(i, null);
                self.endUnstarted(i, false, null, .failed, why);
                continue;
            }
            if (self.blocker(i)) |why| {
                // Idle holders kept for later rules give way to a rule that
                // fits once their memory is returned, which happens when
                // they have exited; the rule waits until then.
                const idle = self.idleMib(i);
                if (std.mem.eql(u8, why, "memory") and idle > 0 and self.blockerFreeing(i, idle) == null) self.releaseIdle(i);
                try self.setWait(i, why);
                continue;
            }
            self.reserve(i, true);
            // Staged from here, so a stop releases what it holds even if
            // starting a holder or the attempt fails.
            self.tasks[i].status = .staging;
            const r = self.rule(i);
            var waiting = false;
            var failure: ?[]const u8 = null;
            // Every holder is taken before any starts: a holder that fails to
            // start fails this rule, which releases all of them.
            for (r.shared_index) |hi| {
                const h = &self.holders[hi];
                if (!h.held) self.memory_used += h.reserve_mib;
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
                // A shared input that failed in this launch is not retried.
                try self.setWait(i, null);
                self.failStaged(i, why);
            } else if (waiting) {
                // Named by the first input not ready, as a group names itself.
                const name = for (r.shared_index) |hi| {
                    if (self.holders[hi].st != .ready) break self.wf.shared[hi].name;
                } else unreachable;
                try self.setWait(i, try std.fmt.allocPrint(self.a, "loading shared:{s}", .{name}));
            } else try self.start(i);
        }
    }

    /// Rank of each rule: its estimated wall time plus the largest rank of
    /// its consumers, so the rules heading the longest remaining chain rank
    /// highest. Estimates are each rule's last recorded wall time, else the
    /// median of the recorded wall times of its step, else 1 s.
    fn computeRanks(self: *Engine) !void {
        const n = self.wf.rules.len;
        const est = try self.a.alloc(f64, n);
        var by_step: std.StringHashMapUnmanaged(std.ArrayList(f64)) = .empty;
        for (self.wf.rules, 0..) |r, i| {
            est[i] = 0;
            const e = self.st.data.rules.map.get(r.name) orelse continue;
            if (e.wall_s <= 0) continue;
            est[i] = e.wall_s;
            const gop = try by_step.getOrPut(self.a, r.labels.step);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.a, e.wall_s);
        }
        for (self.wf.rules, 0..) |r, i| if (est[i] == 0) {
            est[i] = 1;
            if (by_step.get(r.labels.step)) |list| {
                std.mem.sort(f64, list.items, {}, std.sort.asc(f64));
                est[i] = model.median(list.items);
            }
        };
        const ranks = try self.a.alloc(f64, n);
        var k = self.g.order.len;
        while (k > 0) {
            k -= 1;
            const i = self.g.order[k];
            var after: f64 = 0;
            for (self.g.children[i]) |c| after = @max(after, ranks[c]);
            ranks[i] = est[i] + after;
        }
        self.ranks = ranks;
    }

    fn readyBefore(self: *Engine, x: usize, y: usize) bool {
        const rx = self.rule(x);
        const ry = self.rule(y);
        if (rx.priority != ry.priority) return rx.priority > ry.priority;
        // Among equal priorities, the rule with the longest estimated work
        // after it first: the critical path starts as early as it can.
        if (self.ranks.len > 0 and self.ranks[x] != self.ranks[y]) return self.ranks[x] > self.ranks[y];
        const sx = self.tasks[x].ready_seq;
        const sy = self.tasks[y].ready_seq;
        if (sx != sy) return sx < sy;
        return x < y;
    }

    // ---- starting attempts ----

    /// Starts an attempt of rule i. What stops one attempt from being
    /// prepared, such as a full disk or a cgroup limit that cannot be set,
    /// fails that attempt with the reason; --keep-going decides the rest.
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

        const script = try std.fmt.allocPrint(self.a, "{s}/command.sh", .{t.dir});
        const body = if (r.container != null)
            try container.script(self.a, r.shell)
        else
            try std.fmt.allocPrint(self.a, "#!/usr/bin/env bash\nset -euo pipefail\n{s}\n", .{r.shell});
        try sys.writeFile(self.gpa, script, body);
        try records.writeJson(self.gpa, try std.fmt.allocPrint(self.a, "{s}/request.json", .{t.dir}), .{
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

        // The rule's record stays until an attempt replaces it: a failed
        // attempt gives the outputs back, and the journal drops the record
        // if the engine dies while the attempt runs. The mark comes before
        // any output moves, so a killed engine leaves no moved output that
        // the next launch would not look for.
        try self.journal.mark(self.gpa, "dispatch", r.name);

        // Keep earlier bytes of every output: move them into previous/.
        for (r.output_abs, 0..) |o, k| {
            if (try sys.lstat(self.gpa, o)) |id| {
                const prev = try std.fmt.allocPrint(self.a, "{s}/previous", .{t.dir});
                try sys.mkdir(self.gpa, prev);
                const dest = try std.fmt.allocPrint(self.a, "{s}/{d}-{s}", .{ prev, k, std.fs.path.basename(o) });
                sys.rename(self.gpa, o, dest) catch |err|
                    return self.failToStart(i, try std.fmt.allocPrint(self.a, "cannot move its earlier output {s} into previous/: {s}", .{ r.output[k], sys.errorText(err) }));
                self.events.emit("output_preserved", .{ .rule = r.name, .path = r.output[k], .moved_to = dest, .bytes = id.size });
                self.previous_bytes += id.size;
            }
            self.ids.forget(o);
            if (std.fs.path.dirname(o)) |d| try sys.mkdirAll(self.gpa, d);
        }

        if (r.workdir_abs) |d| if (try self.prepareWorkdir(r, d)) |why| return self.failToStart(i, why);

        const out_fd = try sys.openWrite(self.gpa, try std.fmt.allocPrint(self.a, "{s}/stdout.log", .{t.dir}), .truncate);
        defer sys.close(out_fd);
        const err_fd = try sys.openWrite(self.gpa, try std.fmt.allocPrint(self.a, "{s}/stderr.log", .{t.dir}), .truncate);
        defer sys.close(err_fd);

        var procs: sys.Fd = -1;
        t.cg = null;
        if (self.tree) |tree| {
            const name = try std.fmt.allocPrint(self.a, "task-{d}-{d}", .{ i, t.attempts });
            t.cg = try cgroup.create(self.gpa, self.a, tree, name, .{ .memory_bytes = r.memory_mib * 1024 * 1024, .threads = r.threads, .oom_group = true });
            // A container rule's podman client and conmon run in the run's
            // shared containers group; only the container joins the attempt's.
            procs = try cgroup.openProcs(self.gpa, if (r.container != null) self.containers_cg.? else t.cg.?);
        }
        defer if (procs >= 0) sys.close(procs);

        var spec: process.Spec = undefined;
        t.container_name = null;
        if (r.container) |img| {
            // The attempt process is `podman run`, outside the run network;
            // the container alone goes into the attempt's cgroup.
            const name = try std.fmt.allocPrint(self.a, "workz-{s}-{d}-{d}", .{ self.launch_id, i, t.attempts });
            var extra_ro: std.ArrayList([]const u8) = .empty;
            for (r.shared_index) |hi| if (self.wf.shared[hi].path_abs) |p| try extra_ro.append(self.a, p);
            const argv = try container.runArgv(self.a, .{
                .podman = self.podman.?,
                .name = name,
                .image_id = self.images.get(img).?,
                .root = self.wf.root,
                .launch = self.launch_id,
                .cgroup_parent = if (t.cg) |cg| cg["/sys/fs/cgroup".len..] else null,
                .mounts = try container.mounts(self.a, self.wf.root, r, extra_ro.items),
                .env = try self.containerEnv(&try self.ruleVars(r, t.dir)),
                .ipc_service = self.serviceOf(r),
                .image_mounts = r.mounts,
                .workdir = r.workdir_abs,
                .script = script,
            });
            t.container_name = name;
            spec = .{
                .path = (try self.a.dupeZ(u8, self.podman.?)).ptr,
                .argv = (try process.Vec.init(self.a, argv)).items.ptr,
                .envp = self.envp.items.ptr,
                .cwd = (try self.a.dupeZ(u8, r.workdir_abs orelse self.wf.root)).ptr,
                .stdin = self.devnull,
                .stdout = out_fd,
                .stderr = err_fd,
                .cgroup_procs = procs,
            };
        } else {
            const env = try self.taskEnv(r, t.dir);
            const argv = try process.Vec.init(self.a, &.{ "bash", "-euo", "pipefail", script });
            spec = .{
                .path = self.bash.ptr,
                .argv = argv.items.ptr,
                .envp = env.items.ptr,
                .cwd = (try self.a.dupeZ(u8, r.workdir_abs orelse self.wf.root)).ptr,
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
        t.status = .running;
        if (self.guard) |gd| gd.note('+', t.pid);
        self.queueVersion(r) catch {};
        for (r.shared_index) |hi| self.holders[hi].served += 1;
        t.started_ns = sys.monoNs();
        t.started_real = sys.realNs();
        t.deadline_ns = if (self.timeoutOf(r)) |s| t.started_ns + @as(i128, s) * std.time.ns_per_s else null;
        self.events.emit("task_started", .{ .rule = r.name, .attempt = t.attempts, .pid = t.pid, .cgroup = t.cg, .directory = t.dir, .threads = r.threads, .memory_mib = r.memory_mib, .waited_s = t.queued_s, .shared = r.shared });
        self.progress("started", "{s} (attempt {d})", .{ r.name, t.attempts });
    }

    fn timeoutOf(self: *Engine, r: *const workflow.Rule) ?u64 {
        return r.timeout_s orelse self.opts.timeout_s;
    }

    /// An attempt that could not start: it fails, gives back what it held,
    /// and puts back the outputs it moved aside.
    fn failToStart(self: *Engine, i: usize, reason: []const u8) void {
        self.restorePrevious(i) catch {};
        const t = &self.tasks[i];
        // A failure to prepare, such as a full disk, can pass: it uses the
        // rule's retries as a failed command does.
        if (!self.stopping and t.attempts < t.max_attempts) {
            const r = self.rule(i);
            self.writeUnstartedRecord(i, t.attempts, .failed, reason);
            if (t.cg) |cg| cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg) catch {};
            t.cg = null;
            self.reserve(i, false);
            // Ready before its shared inputs are given back, so their holders
            // stay loaded for the next attempt.
            t.status = .ready;
            self.releaseShared(i);
            self.ready_counter += 1;
            t.ready_seq = self.ready_counter;
            t.ready_ns = sys.monoNs();
            t.waits = .empty;
            t.wait_reason = null;
            self.events.emit("task_finished", .{ .rule = r.name, .attempt = t.attempts, .status = "failed", .reason = reason });
            self.events.emit("task_retry", .{ .rule = r.name, .next_attempt = t.attempts + 1 });
            self.alert("retrying", "{s}: {s}", .{ r.name, reason });
            return;
        }
        self.endUnstarted(i, true, t.attempts, .failed, reason);
    }

    /// The record of numbered attempt `n` of rule i that never started: a
    /// numbered attempt directory always ends with one.
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

    /// After an attempt that did not complete, moves each output it moved
    /// into previous/ back to its path, so the last result stays where its
    /// record says. What the attempt left at that path moves to the
    /// attempt's failed/. The record's identity of a restored output is
    /// refreshed: the move changes its change time, not its bytes.
    fn restorePrevious(self: *Engine, i: usize) !void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        const entry = self.st.data.rules.map.getPtr(r.name);
        for (r.output_abs, r.output, 0..) |o, written, k| {
            const name = try std.fmt.allocPrint(self.a, "{d}-{s}", .{ k, std.fs.path.basename(o) });
            const prev = try std.fs.path.join(self.a, &.{ t.dir, "previous", name });
            const kept = try sys.lstat(self.gpa, prev);
            // What the attempt left at the path goes to failed/, also when no
            // earlier output comes back: left there, a partial file would
            // read as the rule's output, changed outside workz. Before the
            // process started, a file at the path is the earlier output.
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

    /// Ends a rule whose attempt never ran. An admitted rule gives back its
    /// reservation and shared inputs. A failure is recorded as `task_failed`
    /// and stops the launch unless --keep-going; a cancellation is recorded
    /// as `task_finished` with status `cancelled`, as for a running attempt.
    fn endUnstarted(self: *Engine, i: usize, admitted: bool, attempt: ?u32, status: Status, reason: []const u8) void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        if (t.cg) |cg| cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg) catch {};
        t.cg = null;
        if (admitted) {
            self.reserve(i, false);
            self.releaseShared(i);
        }
        t.status = status;
        t.reason = reason;
        self.finished += 1;
        if (attempt) |n| self.writeUnstartedRecord(i, n, status, reason);
        if (status == .failed) {
            self.events.emit("task_failed", .{ .rule = r.name, .attempt = attempt, .reason = reason });
            self.alert("failed", "{s}: {s}", .{ r.name, reason });
            if (!self.opts.keep_going) self.beginStop();
        } else self.events.emit("task_finished", .{ .rule = r.name, .attempt = attempt, .status = "cancelled", .reason = reason });
    }

    /// Makes a rule's work directory and its links; the reason it cannot,
    /// or null. A link replaces an earlier symlink, never another file.
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

    /// A container's environment: TZ, LANG, LC_ALL and --pass-env names from
    /// the engine's, then `extra`.
    fn containerEnv(self: *Engine, extra: []const []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.envp.items) |e| {
            const kv = std.mem.span(e.?);
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const name = kv[0..eq];
            // The keyed variables but PATH, which the image sets. A passed
            // variable goes by name alone: Podman takes its value from its own
            // environment, so the value stays out of the argument vector.
            const keyed = for (state.keyed_env) |k| {
                if (std.mem.eql(u8, k, "PATH")) continue;
                if (std.mem.eql(u8, k, name)) break true;
            } else false;
            const passed = for (self.opts.pass_env) |k| {
                if (std.mem.eql(u8, k, name)) break true;
            } else false;
            if (passed) try list.append(self.a, name) else if (keyed) try list.append(self.a, kv);
        }
        try list.appendSlice(self.a, extra);
        return list.items;
    }

    fn taskEnv(self: *Engine, r: *const workflow.Rule, dir: []const u8) !process.Vec {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.envp.items) |e| try list.append(self.a, std.mem.span(e.?));
        try list.appendSlice(self.a, &try self.ruleVars(r, dir));
        return process.Vec.init(self.a, list.items);
    }

    /// The `WORKZ_*` variables of an attempt of rule `r`.
    fn ruleVars(self: *Engine, r: *const workflow.Rule, dir: []const u8) ![4][]const u8 {
        return .{
            try std.fmt.allocPrint(self.a, "WORKZ_RULE={s}", .{r.name}),
            try std.fmt.allocPrint(self.a, "WORKZ_ATTEMPT_DIR={s}", .{dir}),
            try std.fmt.allocPrint(self.a, "WORKZ_THREADS={d}", .{r.threads}),
            try std.fmt.allocPrint(self.a, "WORKZ_MEMORY_MIB={d}", .{r.memory_mib}),
        };
    }

    // ---- shared input holders ----

    fn startHolder(self: *Engine, hi: usize) !void {
        self.holders[hi].starts += 1;
        self.holders[hi].started_ns = sys.monoNs();
        if (self.wf.shared[hi].isService()) return self.startService(hi);
        const h = &self.holders[hi];
        const s = self.wf.shared[hi];
        // The holder walks a directory itself, so the command line stays one
        // path long however many files the index has.
        const argv = try process.Vec.init(self.a, &.{ "workz", "__hold", s.path_abs.? });
        const exe = try sys.childExe(self.a);

        var pipe: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
        defer sys.close(pipe[1]);
        errdefer sys.close(pipe[0]);
        var procs: sys.Fd = -1;
        errdefer if (h.cg) |cg| {
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg) catch {};
            h.cg = null;
        };
        if (self.tree) |tree| {
            h.cg = try cgroup.create(self.gpa, self.a, tree, try std.fmt.allocPrint(self.a, "shared-{s}-{d}", .{ s.name, h.starts }), .{});
            procs = try cgroup.openProcs(self.gpa, h.cg.?);
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
        // Without isolation the guard ends the holder if the engine dies.
        if (self.guard) |gd| gd.note('+', h.pid);
        h.pipe = pipe[0];
        h.st = .loading;
        self.events.emit("shared_loading", .{ .name = s.name, .path = s.path, .bytes = h.bytes, .pid = h.pid, .cgroup = h.cg });
        self.progress("loading", "shared input {s} ({d} MiB)", .{ s.name, h.mib });
    }

    /// Starts a service container: the client in the containers group, the
    /// container in the service's own group, limited to its declared memory.
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
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg) catch {};
            h.cg = null;
        };
        if (self.tree) |tree| {
            h.cg = try cgroup.create(self.gpa, self.a, tree, try std.fmt.allocPrint(self.a, "shared-{s}-{d}", .{ s.name, h.starts }), .{ .memory_bytes = h.mib * 1024 * 1024, .oom_group = true });
            procs = try cgroup.openProcs(self.gpa, self.containers_cg.?);
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
            .cgroup_parent = if (h.cg) |cg| cg["/sys/fs/cgroup".len..] else null,
            .mounts = ro.items,
            .env = try self.containerEnv(&.{
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
        self.events.emit("shared_loading", .{ .name = s.name, .container = name, .memory_mib = h.mib, .reserved_mib = h.reserve_mib, .pid = h.pid, .cgroup = h.cg });
        self.progress("starting", "shared service {s} ({d} MiB)", .{ s.name, h.mib });
    }

    /// Asks a holder to end: a service by closing its stop FIFO, and
    /// with `podman stop` while it still loads; a file holder by SIGTERM. It
    /// is killed if it has not ended after the grace period and ten seconds.
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
        // A service given up on stays failed even if it reports ready late,
        // and one being stopped stays stopping: its exit is a release.
        if (h.timed_out or h.st == .stopping) return;
        h.ready_deadline = null;
        if (n == 0 or !std.mem.startsWith(u8, buf[0..n], "ready")) {
            // The holder ends; its exit fails the rules waiting for it.
            if (h.pid > 0) self.stopHolder(h);
            h.st = .failed;
            return;
        }
        h.st = .ready;
        const file = if (h.cg) |cg| cgroup.read(self.gpa, cg).file else null;
        self.events.emit("shared_loaded", .{ .name = self.wf.shared[hi].name, .bytes = h.bytes, .holder_file_bytes = file });
        for (self.tasks, 0..) |*t, i| {
            if (t.status != .staging) continue;
            if (self.sharedReady(i)) try self.start(i);
        }
    }

    /// Container name of the service a rule joins, if any.
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
            // A holder outlives a gap between its users, so it is not
            // loaded again for rules that become ready later.
            if (h.users == 0 and (self.stopping or !self.holderNeeded(hi))) self.releaseHolder(hi);
        }
    }

    /// Whether a rule that has yet to start needs a shared input.
    fn holderNeeded(self: *Engine, hi: usize) bool {
        for (self.tasks, 0..) |t, i| {
            if (t.status != .pending and t.status != .ready) continue;
            if (std.mem.indexOfScalar(usize, self.rule(i).shared_index, hi) != null) return true;
        }
        return false;
    }

    /// Stops a holder. Its memory returns to the budget when it has exited,
    /// not when it is asked to stop.
    fn releaseHolder(self: *Engine, hi: usize) void {
        const h = &self.holders[hi];
        if (h.pid > 0 and (h.st == .loading or h.st == .ready)) {
            self.stopHolder(h);
        } else if (h.pid == 0 and h.held) {
            self.memory_used -= h.reserve_mib;
            self.freed_ns = sys.monoNs();
            h.held = false;
        }
    }

    /// Memory of the holders without users that rule `i` does not use.
    fn idleMib(self: *Engine, i: usize) u64 {
        var mib: u64 = 0;
        for (self.holders, 0..) |h, hi| {
            if (h.users > 0 or !h.held or h.st == .stopping) continue;
            const uses = std.mem.indexOfScalar(usize, self.rule(i).shared_index, hi) != null;
            if (!uses) mib += h.reserve_mib;
        }
        return mib;
    }

    /// Releases holders without users that rule `i` does not use, or every
    /// one without users when `i` is null and none is needed any longer.
    /// True when one was released.
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
            counters = cgroup.read(self.gpa, cg);
            cgroup.kill(self.gpa, cg);
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg) catch {};
            h.cg = null;
        }
        const code = reaped.exitCode();
        if (h.container_name) |name| {
            // A service ends with status 0 when stopped; otherwise its
            // container may remain.
            if (code == null or code.? != 0) self.helper(container.removeAsync(self.a, self.podman.?, name, &self.envp, self.devnull));
            h.container_name = null;
        }
        const peak = if (counters) |c| c.memory_peak else null;
        if (h.held and h.users == 0) {
            self.memory_used -= h.reserve_mib;
            self.freed_ns = sys.monoNs();
            h.held = false;
        }
        if (was == .stopping) {
            h.st = .idle;
            self.events.emit("shared_released", .{ .name = s.name, .memory_peak = peak, .cpu_s = taskCpu(counters, reaped), .users = h.served, .held_s = @as(f64, @floatFromInt(sys.monoNs() - h.started_ns)) / 1e9 });
            h.served = 0;
            // A rule admitted while the holder stopped needs it again.
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
        // A service that failed before it was ready starts again while it
        // has retries left and rules still wait for it.
        if (was != .ready and h.failed_starts < s.retries and h.users > 0 and !self.stopping) {
            h.failed_starts += 1;
            self.events.emit("shared_retry", .{ .name = s.name, .reason = why, .next_start = h.starts + 1 });
            self.alert("restarting", "shared service {s}: {s}", .{ s.name, why });
            try self.startHolderOrFail(hi);
            return;
        }
        try self.failHolder(hi, why, peak);
    }

    /// Starts a holder; one that cannot start fails as if it had ended.
    fn startHolderOrFail(self: *Engine, hi: usize) !void {
        self.startHolder(hi) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try self.failHolder(hi, try std.fmt.allocPrint(self.a, "could not start: {s}", .{sys.errorText(err)}), null),
        };
    }

    /// Marks a shared input failed for the rest of the launch and fails the
    /// rules admitted to use it. Rules running against a service stop and
    /// fail too: the memory or index they read may be gone. A mapped file
    /// stays in the page cache, so its running users go on.
    fn failHolder(self: *Engine, hi: usize, why: []const u8, peak: ?u64) !void {
        const h = &self.holders[hi];
        const s = self.wf.shared[hi];
        h.st = .failed;
        h.failure = try std.fmt.allocPrint(self.a, "shared input {s} could not be loaded: {s}", .{ s.name, why });
        self.events.emit("shared_failed", .{ .name = s.name, .reason = why, .memory_peak = peak });
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

    /// Fails an admitted rule that cannot start because a shared input failed.
    fn failStaged(self: *Engine, i: usize, reason: []const u8) void {
        self.endUnstarted(i, true, null, .failed, reason);
    }

    // ---- finishing attempts ----

    fn finish(self: *Engine, i: usize, reaped: process.Reaped) !void {
        const t = &self.tasks[i];
        if (self.guard) |gd| gd.note('-', t.pid);
        const r = self.rule(i);
        const now_real = sys.realNs();
        const wall_s = @as(f64, @floatFromInt(sys.monoNs() - t.started_ns)) / 1e9;
        var counters: ?cgroup.Counters = null;
        if (t.cg) |cg| {
            counters = cgroup.read(self.gpa, cg);
            counters.?.anon_peak = t.anon_peak;
            // Descendants left behind by the command end with it.
            if (cgroup.populated(self.gpa, cg)) cgroup.kill(self.gpa, cg);
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg) catch {};
        } else process.signalGroup(t.pid, .KILL);
        self.reserve(i, false);
        // Shared inputs are released once the attempt's fate is known, so
        // a retry keeps its holder. An error while recording still ends the
        // task, so the engine does not wait for it.
        var released = false;
        errdefer if (!released) {
            t.status = .failed;
            t.reason = "the engine could not record the attempt";
            self.releaseShared(i);
            self.finished += 1;
        };

        var ok = false;
        var reason: []const u8 = "";
        // The last line of standard error, for a command that failed.
        var said: []const u8 = "";
        // Quote stderr's last line, else a diagnostic's, for a command that
        // exited with a status of its own.
        var quote = false;
        const code = reaped.exitCode();
        const sig = reaped.signal();
        if (t.lost_service) |why| {
            reason = why;
        } else if (t.cancelled) {
            reason = t.stop_why;
        } else if (t.timed_out) {
            reason = try std.fmt.allocPrint(self.a, "timed out after {d} s", .{self.timeoutOf(r).?});
        } else if (counters != null and counters.?.oom_kill > 0) {
            reason = try std.fmt.allocPrint(self.a, "out of memory: could not stay within its {d} MiB request", .{r.memory_mib});
        } else if (code) |c| {
            if (c == 0) {
                ok = true;
                // The same rule as validation: an output is a regular file,
                // not a symlink to one.
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
            } else if (r.container != null and c == 125) {
                reason = try std.fmt.allocPrint(self.a, "status 125: the container engine failed, or the command exited 125: {s}", .{try self.lastLine(t.dir)});
            } else if (r.container != null and (c == 126 or c == 127)) {
                reason = try std.fmt.allocPrint(self.a, "the command could not run in the container (status {d}): {s}", .{ c, try self.lastLine(t.dir) });
            } else {
                reason = try std.fmt.allocPrint(self.a, "exited with status {d}", .{c});
                said = try self.errorLine(t.dir);
                quote = true;
            }
        } else if (sig) |s| {
            reason = try std.fmt.allocPrint(self.a, "killed by signal {d}", .{s});
        }
        // The rule's log and benchmark files are part of what it asked for: one
        // that cannot be written fails the attempt, not the launch.
        self.writeSideFiles(r, t, ok, wall_s, reaped, counters) catch |err| {
            ok = false;
            reason = try std.fmt.allocPrint(self.a, "cannot write its log or benchmark file: {s}", .{sys.errorText(err)});
        };
        // A failed attempt keeps the tails of the files the rule names for
        // its own failures; one that cannot be kept fails nothing else.
        t.diagnostics = if (!ok and !t.cancelled) self.keepDiagnostics(r, t.dir) catch &.{} else &.{};
        if (quote and said.len == 0) for (t.diagnostics) |d| {
            said = try self.errorLineOf(try std.fs.path.join(self.a, &.{ t.dir, "diagnostics", d }));
            if (said.len > 0) break;
        };
        // The recorded reason quotes that line; a terminal shows the error
        // lines themselves under the brief reason.
        const brief = reason;
        if (said.len > 0) reason = try std.fmt.allocPrint(self.a, "{s}: {s}", .{ reason, said });
        // `--rm` removes a container that ran to its end; one whose client
        // failed, was stopped or was killed, possibly before the container
        // started, may remain.
        if (t.container_name) |name| if (!ok)
            self.helper(container.removeAsync(self.a, self.podman.?, name, &self.envp, self.devnull));

        var outputs: std.ArrayList(state.Output) = .empty;
        if (ok) for (r.output_abs) |o| {
            const sa = self.st.allocator();
            const id = (try self.ids.get(o)) orelse "";
            // Cutoff rules keep a content digest beside the identity.
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
            t.status = .completed;
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
            if (!self.st.data.envs.map.contains(k.env))
                try self.st.data.envs.map.put(sa, try sa.dupe(u8, k.env), try sa.dupe(u8, self.env_text));
            try self.recordFiles(r);
            self.dirty = true;
            try self.pending_done.append(self.gpa, r.name);
            self.finished += 1;
            self.events.emit("task_finished", .{ .rule = r.name, .attempt = t.attempts, .status = "completed", .wall_s = wall_s, .cpu_s = taskCpu(counters, reaped), .maxrss_kib = reaped.usage.maxrss, .memory_peak = if (counters) |c| c.memory_peak else null });
            var took: [32]u8 = undefined;
            var tw: std.Io.Writer = .fixed(&took);
            units.duration(&tw, wall_s) catch {};
            self.progress("completed", "{s} ({s})", .{ r.name, tw.buffered() });
            return;
        }
        t.reason = reason;
        self.events.emit("task_finished", .{ .rule = r.name, .attempt = t.attempts, .status = status, .reason = reason, .exit_code = code, .signal = sig, .wall_s = wall_s });
        self.restorePrevious(i) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => self.alert("warning", "{s}: cannot put its earlier outputs back from {s}/previous: {s}", .{ r.name, monitor.shownPath(self.a, t.dir), sys.errorText(err) }),
        };
        if (!t.cancelled and !self.stopping and t.lost_service == null and t.attempts < t.max_attempts) {
            t.status = .ready;
            self.releaseShared(i);
            released = true;
            self.ready_counter += 1;
            t.ready_seq = self.ready_counter;
            t.ready_ns = sys.monoNs();
            t.waits = .empty;
            t.wait_reason = null;
            self.events.emit("task_retry", .{ .rule = r.name, .next_attempt = t.attempts + 1 });
            self.alert("retrying", "{s}: {s}", .{ r.name, brief });
            self.showTail(t.dir, 1);
            return;
        }
        t.status = if (t.cancelled) .cancelled else .failed;
        self.releaseShared(i);
        released = true;
        self.finished += 1;
        // A terminal shows the error lines themselves; `workz logs` has the rest.
        if (self.console.on) {
            if (t.cancelled) self.alert("cancelled", "{s}: {s}", .{ r.name, brief }) else {
                self.alert("failed", "{s}: {s}", .{ r.name, brief });
                self.showTail(t.dir, 3);
                for (t.diagnostics) |d|
                    self.showLines(try std.fs.path.join(self.a, &.{ t.dir, "diagnostics", d }), 3, d);
            }
        } else {
            const log = monitor.shownPath(self.a, t.dir);
            if (t.cancelled)
                self.alert("cancelled", "{s}: {s} (see {s}/stderr.log)", .{ r.name, reason, log })
            else if (t.diagnostics.len > 0)
                self.alert("failed", "{s}: {s} (see {s}/stderr.log and {s}/diagnostics)", .{ r.name, reason, log, log })
            else
                self.alert("failed", "{s}: {s} (see {s}/stderr.log)", .{ r.name, reason, log });
        }
        if (!t.cancelled and !self.opts.keep_going) self.beginStop();
    }

    /// The rule's combined log and benchmark files, written after the attempt.
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

    /// The last non-empty line of an attempt's stderr, for failure reasons.
    fn lastLine(self: *Engine, dir: []const u8) ![]const u8 {
        return self.lastLineOf(try std.fmt.allocPrint(self.a, "{s}/stderr.log", .{dir}));
    }

    /// The last line of an attempt's standard error for its recorded
    /// reason: control characters blanked, cut to 200 bytes.
    fn errorLine(self: *Engine, dir: []const u8) ![]const u8 {
        return self.errorLineOf(try std.fmt.allocPrint(self.a, "{s}/stderr.log", .{dir}));
    }

    /// The last line of file `path`, made fit for a recorded reason.
    fn errorLineOf(self: *Engine, path: []const u8) ![]const u8 {
        const line = try self.lastLineOf(path);
        var end = @min(line.len, 200);
        // Cut before a UTF-8 continuation byte, never inside a character.
        while (end < line.len and end > 0 and line[end] & 0xc0 == 0x80) end -= 1;
        const out = try self.a.dupe(u8, line[0..end]);
        for (out) |*ch| if (ch.* < 0x20 or ch.* == 0x7f) {
            ch.* = ' ';
        };
        return if (end < line.len) std.fmt.allocPrint(self.a, "{s}...", .{out}) else out;
    }

    fn lastLineOf(self: *Engine, path: []const u8) ![]const u8 {
        const tail = sys.readTail(self.gpa, path, 2048) catch return "";
        defer self.gpa.free(tail);
        const trimmed = std.mem.trimEnd(u8, tail, " \r\n");
        const begin = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |k| k + 1 else 0;
        return self.a.dupe(u8, trimmed[begin..]);
    }

    /// Keeps the last `diagnostics_max` bytes of each of the rule's
    /// diagnostics files that exists, in the attempt's `diagnostics/` under
    /// the path as written, and returns the paths kept. Only regular files
    /// that resolve inside the working directory and outside `.workz/` are
    /// read, so a symlink cannot copy a file from elsewhere into the records.
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
        };
    }

    // ---- control ----

    /// Applies the lines appended to the control file: `stop RULE`,
    /// `retry RULE` and `cancel` (see `workz control`).
    fn readControl(self: *Engine) !void {
        var drain: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        _ = linux.read(self.control_watch, &drain, drain.len);
        const fd = sys.openRead(self.gpa, self.control_path) catch return;
        defer sys.close(fd);
        var buf: [4096]u8 = undefined;
        // Every complete line is applied; a partial last one waits.
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
                // A line longer than the buffer cannot be a command.
                if (n < buf.len) return;
                self.alert("control", "ignored a line of over {d} bytes", .{buf.len});
                self.control_offset += n;
                self.control_skip = true;
                continue;
            }) + 1;
            self.control_offset += end;
            var it = std.mem.splitScalar(u8, buf[0..end], '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                var words = std.mem.tokenizeScalar(u8, line, ' ');
                const cmd = words.next() orelse continue;
                const name = words.next() orelse "";
                const result = try self.control(cmd, name);
                self.events.emit("control", .{ .command = cmd, .rule = name, .result = result });
                if (name.len == 0) {
                    self.alert("control", "{s}: {s}", .{ cmd, result });
                } else self.alert("control", "{s} {s}: {s}", .{ cmd, name, result });
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
        const i = self.wf.ruleIndex(name) orelse return "no such rule";
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
                // A staged rule holds its reservation and its shared inputs.
                self.endUnstarted(i, t.status == .staging, null, .cancelled, "stopped on request");
                return "cancelled before it started";
            },
            else => return "not running",
        };
        if (eql(u8, cmd, "retry")) {
            if (self.stopping) return "the launch is stopping";
            if (t.status != .failed and t.status != .cancelled) return "not failed";
            t.status = .pending;
            t.reason = "";
            t.cancelled = false;
            t.max_attempts = t.attempts + 1;
            self.finished -= 1;
            // Rules blocked behind it may run again.
            var queue: std.ArrayList(usize) = .empty;
            defer queue.deinit(self.gpa);
            try queue.append(self.gpa, i);
            while (queue.pop()) |q| for (self.g.children[q]) |c| if (self.tasks[c].status == .blocked) {
                self.tasks[c].status = .pending;
                self.tasks[c].reason = "";
                self.finished -= 1;
                try queue.append(self.gpa, c);
            };
            return "retrying";
        }
        return "unknown command";
    }

    // ---- stopping ----

    /// Marks the end of the run loop in the event stream, which `workz
    /// control` reads to refuse commands that would not be applied.
    fn beginEnding(self: *Engine) void {
        if (self.ending) return;
        self.ending = true;
        self.events.emit("launch_ending", .{});
    }

    fn beginStop(self: *Engine) void {
        if (self.stopping) return;
        self.stopping = true;
        const grace = @as(i128, self.opts.grace_s) * std.time.ns_per_s;
        const why = if (self.interrupted) "cancelled: the launch was interrupted" else "cancelled: the launch stopped after a failure";
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

    /// Asks a running attempt to stop: SIGTERM to its process group, and for
    /// a container `podman stop`, which kills every container process after
    /// the grace period. The group is killed later if the attempt is still
    /// running: after the grace period, or ten seconds more for a container.
    /// An attempt already stopping keeps its first deadline.
    fn terminate(self: *Engine, t: *Task, grace: i128) void {
        if (t.kill_at != null) return;
        // A stopped attempt can no longer time out.
        t.deadline_ns = null;
        process.signalGroup(t.pid, .TERM);
        if (t.container_name) |name| {
            self.helper(container.stopAsync(self.a, self.podman.?, name, self.opts.grace_s, &self.envp, self.devnull));
            t.kill_at = sys.monoNs() + grace + 10 * std.time.ns_per_s;
        } else t.kill_at = sys.monoNs() + grace;
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
                // It ends as failed, not released: its users cannot start.
                h.st = .loading;
            }
        };
        for (self.holders) |*h| if (h.kill_at) |k| if (now >= k) {
            process.signalPid(h.pid, .KILL);
            if (h.cg) |cg| cgroup.kill(self.gpa, cg);
            h.kill_at = null;
        };
        for (self.tasks, 0..) |*t, i| {
            if (t.status != .running) continue;
            if (t.kill_at) |k| if (now >= k) {
                process.signalGroup(t.pid, .KILL);
                if (t.cg) |cg| cgroup.kill(self.gpa, cg);
                t.kill_at = null;
                continue;
            };
            if (t.deadline_ns) |d| if (now >= d and !t.timed_out) {
                t.timed_out = true;
                self.terminate(t, grace);
                self.events.emit("task_timeout", .{ .rule = self.rule(i).name, .attempt = t.attempts });
            };
        }
    }

    /// Whether processes of a running attempt remain: its cgroup is
    /// populated, or without one, its process group has a member.
    fn stillRuns(self: *Engine, t: *const Task) bool {
        if (t.cg) |cg| return cgroup.populated(self.gpa, cg);
        return process.groupAlive(t.pid);
    }

    /// Ends each stopped attempt whose shell has exited once the processes
    /// it left have ended too, or have been killed after the grace period.
    fn finishEnded(self: *Engine) !void {
        for (self.tasks, 0..) |*t, i| {
            if (t.status != .running) continue;
            const rp = t.ended orelse continue;
            if (t.kill_at != null and self.stillRuns(t)) continue;
            t.ended = null;
            try self.finish(i, rp);
        }
    }

    fn nextDeadline(self: *Engine) ?i128 {
        var best: ?i128 = null;
        for (self.holders) |h| for ([_]?i128{ h.kill_at, h.ready_deadline }) |d| if (d) |v| {
            best = if (best) |b| @min(b, v) else v;
        };
        for (self.tasks) |t| {
            if (t.status != .running) continue;
            // The processes a stopped attempt's shell left have no event for
            // their end: they are checked every 20 ms.
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
        if (self.console.on) best = @min(best.?, self.console.next_ns);
        return best;
    }

    /// Appends a `sample` event: what is running and waiting, what is
    /// reserved, and, inside the run's cgroup, the memory and CPU in use.
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
            for (self.tasks) |*t| if (t.status == .running) if (t.cg) |cg| if (cgroup.anon(self.gpa, cg)) |b| {
                t.anon_peak = @max(t.anon_peak orelse 0, b);
            };
            const cpu = cgroup.cpuUsage(self.gpa, tree.root);
            if (cpu != null and self.last_cpu_us != null and now > self.last_sample_ns)
                cpu_cores = @as(f64, @floatFromInt(cpu.? -| self.last_cpu_us.?)) / (@as(f64, @floatFromInt(now - self.last_sample_ns)) / 1e3);
            self.last_cpu_us = cpu;
        }
        // The part of the reserved memory that shared inputs hold once.
        var shared_mib: u64 = 0;
        for (self.holders) |h| if (h.held) {
            shared_mib += h.reserve_mib;
        };
        self.events.emit("sample", .{
            .running = running_n,
            .ready = ready_n,
            .threads_reserved = self.threads_used,
            .memory_reserved_mib = self.memory_used,
            .shared_reserved_mib = shared_mib,
            .memory_current = memory_current,
            .cpu_cores_used = cpu_cores,
        });
        self.last_sample_ns = now;
        self.next_sample_ns = now + sample_interval_ns;
    }

    /// Draws the launch's page from the records written so far. Drawing
    /// reads every attempt record, so the next page waits at least twenty
    /// times as long as this one took: the page costs at most a twentieth of
    /// the engine's time.
    fn drawPage(self: *Engine) void {
        const path = self.page_path orelse return;
        const t0 = sys.monoNs();
        writePage(self.gpa, path, self.launch_dir) catch |err| {
            std.debug.print("workz: cannot write {s} ({s}); the page stops updating\n", .{ path, sys.errorText(err) });
            self.page_path = null;
            return;
        };
        const now = sys.monoNs();
        self.next_page_ns = now + @max(sample_interval_ns, (now - t0) * 20);
    }

    fn saveState(self: *Engine, force: bool) !void {
        if (!self.dirty) return;
        const now = sys.monoNs();
        if (!force and now - self.last_save_ns < std.time.ns_per_s) return;
        try self.st.save(self.gpa);
        for (self.pending_done.items) |name| try self.journal.mark(self.gpa, "done", name);
        self.pending_done.clearRetainingCapacity();
        self.dirty = false;
        self.last_save_ns = now;
    }

    fn running(self: *Engine) usize {
        var n: usize = 0;
        for (self.tasks) |t| n += @intFromBool(t.status == .running or t.status == .staging);
        for (self.holders) |h| n += @intFromBool(h.pid > 0);
        return n;
    }

    // ---- tool versions ----

    /// Queues the version command of rule `r`, once per launch for each
    /// image and command, and starts it when no other one runs. They are
    /// not counted in the budget: one at a time keeps the memory they take
    /// beside it to one short command and, for an image, its Podman client.
    fn queueVersion(self: *Engine, r: *const workflow.Rule) !void {
        const command = r.version orelse return;
        const image: ?[]const u8 = if (r.container) |img| self.images.get(img) else null;
        for (self.versions.items) |v| {
            const same_image = if (v.image) |x| (image != null and std.mem.eql(u8, x, image.?)) else image == null;
            if (same_image and std.mem.eql(u8, v.command, command)) return;
        }
        const dir = try std.fs.path.join(self.a, &.{ self.launch_dir, "versions" });
        try sys.mkdirAll(self.gpa, dir);
        try self.versions.append(self.a, .{
            .command = command,
            .container = r.container,
            .image = image,
            .file = try std.fmt.allocPrint(self.a, "{s}/{d}.log", .{ dir, self.versions.items.len + 1 }),
        });
        self.startVersion();
    }

    /// Starts the next queued version command unless one runs or the
    /// launch was interrupted.
    fn startVersion(self: *Engine) void {
        if (self.version_running != null or self.interrupted) return;
        for (self.versions.items, 0..) |*v, vi| {
            if (v.started) continue;
            v.started = true;
            v.pid = self.spawnVersion(v) catch |err| {
                const text = std.fmt.allocPrint(self.a, "workz: cannot start the version command: {s}\n", .{sys.errorText(err)}) catch continue;
                sys.writeFile(self.gpa, v.file, text) catch {};
                continue;
            };
            self.version_running = vi;
            return;
        }
    }

    fn spawnVersion(self: *Engine, v: *const Version) !linux.pid_t {
        const fd = try sys.openWrite(self.gpa, v.file, .truncate);
        defer sys.close(fd);
        var spec: process.Spec = undefined;
        if (v.image) |id| {
            // The isolation of a container rule, without its mounts: a
            // version command reads nothing of the working directory.
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

    /// The process of the running version command, or 0.
    fn versionPid(self: *const Engine) linux.pid_t {
        const vi = self.version_running orelse return 0;
        return self.versions.items[vi].pid;
    }

    fn versionExited(self: *Engine, rp: process.Reaped) void {
        const v = &self.versions.items[self.version_running.?];
        if (self.guard) |gd| gd.note('-', v.pid);
        v.exit_code = rp.exitCode() orelse if (rp.signal()) |s| 128 + @as(u32, @intCast(s)) else null;
        self.version_running = null;
        self.startVersion();
    }

    /// Writes `versions.json`: each version command with the start of its
    /// output. A command still running is killed first.
    fn writeVersions(self: *Engine) !void {
        if (self.versions.items.len == 0) return;
        if (self.version_running) |vi| {
            // Its whole process group, as for an attempt.
            process.signalGroup(self.versions.items[vi].pid, .KILL);
            self.versions.items[vi].stopped = true;
        }
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
                .output = try self.a.dupe(u8, std.mem.trim(u8, head, " \t\r\n")),
            });
        }
        try records.writeJson(self.gpa, try std.fs.path.join(self.a, &.{ self.launch_dir, "versions.json" }), .{ .v = records.record_version, .commands = entries.items });
    }

    fn helper(self: *Engine, pid: ?linux.pid_t) void {
        if (pid) |p| self.helpers.append(self.gpa, p) catch {};
    }

    /// Waits up to `limit_s` for the Podman commands still running, so a
    /// launch ends with the containers it removed gone.
    /// Lets the version commands still queued or running finish, for at most
    /// `limit_s` seconds in all. An interrupted launch, or a signal while
    /// waiting, ends the wait: they must not hold the launch open.
    fn awaitVersions(self: *Engine, limit_s: u64) void {
        const until = sys.monoNs() + @as(i128, limit_s) * std.time.ns_per_s;
        while (self.version_running != null and !self.interrupted and sys.monoNs() < until) {
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
            for (self.tasks, 0..) |*t, i| {
                if (t.status == .running and t.ended == null and t.pid == rp.pid) {
                    // A stopped attempt's shell often dies at SIGTERM before
                    // the tool it ran: the tool keeps its grace period.
                    if (t.kill_at != null and self.stillRuns(t)) t.ended = rp else try self.finish(i, rp);
                    break;
                }
            } else for (self.holders, 0..) |*h, hi| {
                if (h.pid == rp.pid) {
                    try self.holderExited(hi, rp);
                    break;
                }
            } else if (rp.pid == self.versionPid()) {
                self.versionExited(rp);
            } else for (self.helpers.items, 0..) |pid, k| {
                if (pid == rp.pid) {
                    _ = self.helpers.swapRemove(k);
                    break;
                }
            }
        }
    }

    fn loop(self: *Engine) !void {
        var idle_passes: u32 = 0;
        // `workz control` may append before the file is watched: those
        // commands apply before the first rule starts.
        if (self.control_watch >= 0) try self.readControl();
        while (true) {
            try self.updateReadiness();
            // Holders kept for rules that can no longer run are released.
            self.releaseIdle(null);
            try self.admit();
            try self.saveState(false);
            if (self.running() == 0) {
                var any_ready = false;
                for (self.tasks) |t| any_ready = any_ready or t.status == .ready or t.status == .pending;
                if (!any_ready or self.stopping) break;
                // With nothing running, readiness settles in one pass; a
                // second pass that still starts nothing would wait forever.
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
            const seen = process.readSignals(self.sigfd);
            if (process.has(seen, .INT) or process.has(seen, .TERM) or process.has(seen, .HUP)) {
                // A repeated interrupt kills at once; one arriving within a second of
                // the first is the same request delivered twice (terminal and launcher).
                const now = sys.monoNs();
                if (self.signalled_at) |at| {
                    if (now - at >= std.time.ns_per_s) {
                        if (!self.opts.quiet) self.note("workz: interrupted again; killing running tasks");
                        for (self.tasks) |*t| if (t.status == .running) {
                            t.kill_at = now;
                        };
                        for (self.holders) |*h| if (h.pid > 0) {
                            h.kill_at = now;
                        };
                    }
                } else {
                    self.signalled_at = now;
                    self.events.emit("cancel_requested", .{ .signal = if (process.has(seen, .INT)) "SIGINT" else if (process.has(seen, .TERM)) "SIGTERM" else "SIGHUP" });
                    if (self.interrupted) {
                        // `control cancel` already stops the launch with its grace period.
                        if (!self.opts.quiet) self.note("workz: interrupted; the launch is already stopping (interrupt again to kill)");
                    } else {
                        self.interrupted = true;
                        self.interrupted_at = now;
                        if (!self.opts.quiet) self.note("workz: interrupted; stopping running tasks (interrupt again to kill)");
                        self.beginStop();
                    }
                }
            }
            for (fds.items[1..]) |f| if (f.revents != 0) {
                if (f.fd == self.control_watch) try self.readControl();
                for (self.holders, 0..) |h, hi| if (h.pipe == f.fd) try self.holderReady(hi);
            };
            try self.reapAll();
            self.checkTimers();
            try self.finishEnded();
            self.sample();
            if (self.page_path != null and sys.monoNs() >= self.next_page_ns) self.drawPage();
            self.drawStatus(false);
        }
    }
};

/// Whether `--threads` set the request of step `step`.
fn overridden(overrides: []const []const u8, step: []const u8) bool {
    for (overrides) |o| {
        const eq = std.mem.lastIndexOfScalar(u8, o, '=') orelse continue;
        if (std.mem.eql(u8, o[0..eq], step)) return true;
    }
    return false;
}

/// Memory a container rule or service needs beside its request: its
/// `podman run` client and conmon, which run in the launch's shared
/// containers cgroup and take about 20 MiB together.
pub const container_client_mib: u64 = 32;

/// What admission reserves for rule `r`: its request, and for a container
/// rule its Podman client's memory.
pub fn reservedMib(r: *const workflow.Rule) u64 {
    return r.memory_mib + if (r.container != null) container_client_mib else 0;
}

/// Moves the outputs of every attempt a killed launch left unfinished
/// (`records.pendingAttempts`) back from its `previous/`, and what that
/// attempt left at their paths into its `failed/`, as a failed attempt does
/// in its own launch.
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

/// What one shared input holds and takes from the budget, as `Holder`.
pub const SharedSize = struct { bytes: u64, mib: u64, reserve_mib: u64 };

/// The sizes of the shared inputs that the rules marked in `runs` use, each
/// measured once; null for one that no such rule uses, which is not
/// measured. A service holds its declared memory beside its Podman client;
/// mapped files hold their pages. A mapped path that cannot be measured
/// returns `error.Unmeasurable` and sets `failure`.
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

/// What rule `r` needs of the budget to start: `reservedMib` and each of its
/// shared inputs, held once.
pub fn neededMib(r: *const workflow.Rule, sizes: []const ?SharedSize) u64 {
    var need = reservedMib(r);
    for (r.shared_index) |hi| need += if (sizes[hi]) |z| z.reserve_mib else 0;
    return need;
}

/// A wait for a part of the budget, which ends when the budget gets it back.
fn budgetReason(reason: []const u8) bool {
    for ([_][]const u8{ "jobs", "threads", "memory" }) |r| if (std.mem.eql(u8, reason, r)) return true;
    return std.mem.startsWith(u8, reason, "group:");
}

/// How much of the start of a version command's output `versions.json` keeps.
const version_output_max = 4096;

/// How much of the end of each diagnostics file a failed attempt keeps.
const diagnostics_max = 64 * 1024;

/// Interval between run samples.
const sample_interval_ns: i128 = 5 * std.time.ns_per_s;

fn groupIndex(wf: *const workflow.Workflow, name: []const u8) usize {
    for (wf.groups, 0..) |g, i| if (std.mem.eql(u8, g.name, name)) return i;
    unreachable;
}

/// Sets memory.low on the run's scope through systemd, which owns the
/// scope's own control files; false when that fails. The protection is
/// advisory, so a failure does not stop the run.
fn protectScope(gpa: Allocator, a: Allocator, tree: cgroup.Tree, mib: u64, path_env: []const u8, envp: *const process.Vec, devnull: sys.Fd) bool {
    const systemctl = (process.findProgram(gpa, a, path_env, "systemctl") catch return false) orelse return false;
    const unit = std.fs.path.basename(tree.root);
    const prop = std.fmt.allocPrint(a, "MemoryLow={d}M", .{mib}) catch return false;
    var status: u32 = 0;
    _ = process.capture(gpa, a, &.{ systemctl, "--user", "set-property", "--runtime", unit, prop }, envp, devnull, &status) catch return false;
    return true;
}

/// CPU seconds of an attempt: its cgroup's usage when it has one, which
/// includes containers and processes that left the task; otherwise the
/// `wait4` usage of the command and its waited children.
/// CPU seconds of an attempt: its cgroup's usage, which covers every
/// process of the task, else the rusage of the processes it waited for.
fn taskCpu(counters: ?cgroup.Counters, reaped: process.Reaped) f64 {
    return cgroupCpu(counters) orelse reaped.cpuSeconds();
}

fn cgroupCpu(counters: ?cgroup.Counters) ?f64 {
    const c = counters orelse return null;
    const us = c.cpu_usage_usec orelse return null;
    return @as(f64, @floatFromInt(us)) / 1e6;
}

/// The engine's own CPU time and peak memory, without its tasks.
const EngineCost = struct { cpu_s: f64, max_rss_mib: f64 };

/// `summary.json`, the record of how a launch ended.
const Summary = struct {
    v: u32 = records.record_version,
    engine: []const u8,
    engine_key: u32 = state.engine_key,
    launch: []const u8,
    status: []const u8,
    /// The rules by outcome; `running`, `waiting` and `pending` stay 0 once
    /// the launch has ended and count only in a running launch's status.
    counts: struct { completed: usize = 0, reused: usize = 0, failed: usize = 0, blocked: usize = 0, cancelled: usize = 0, not_started: usize = 0, running: usize = 0, waiting: usize = 0, pending: usize = 0 },
    selected: usize,
    elapsed_s: f64,
    finished: []const u8,
    @"error": ?[]const u8,
    engine_cost: EngineCost,
    launch_dir: []const u8,
    /// Each rule that failed, was blocked or was cancelled, with its reason
    /// and the standard error of its last attempt; empty when none did.
    failures: []const Failure = &.{},
    /// For a launch refused because recorded outputs changed: each such
    /// output and the rule that wrote it.
    changed_outputs: []const ChangedOutput = &.{},
    /// Bytes of earlier outputs the launch moved into `previous/`, kept
    /// until `workz clean --previous` removes them.
    previous_bytes: u64 = 0,
};

const Failure = struct { rule: []const u8, status: []const u8, reason: []const u8, stderr: ?[]const u8, diagnostics: []const []const u8 };
const ChangedOutput = struct { rule: []const u8, path: []const u8 };

/// Writes a launch's page, replacing the file in one step so a browser
/// never reads half of it.
fn writePage(gpa: Allocator, path: []const u8, launch_dir: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try html.write(gpa, arena.allocator(), &out.writer, launch_dir);
    try sys.writeFileReplace(gpa, path, out.written());
}

/// Ends a launch's records: the `launch_finished` event and `summary.json`.
fn writeSummary(gpa: Allocator, a: Allocator, events: *records.Events, s: Summary) !void {
    events.emit("launch_finished", .{ .status = s.status, .counts = s.counts, .elapsed_s = s.elapsed_s, .@"error" = s.@"error" });
    try records.writeJson(gpa, try std.fs.path.join(a, &.{ s.launch_dir, "summary.json" }), s);
}

fn engineCost() EngineCost {
    var ru: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &ru);
    const cpu = @as(f64, @floatFromInt(ru.utime.sec + ru.stime.sec)) + @as(f64, @floatFromInt(ru.utime.usec + ru.stime.usec)) / 1e6;
    return .{ .cpu_s = cpu, .max_rss_mib = @as(f64, @floatFromInt(ru.maxrss)) / 1024.0 };
}

/// Ends a launch before any rule ran: records why, in the event stream and
/// a summary with status "refused", so `status` shows the attempt.
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
    /// Recorded outputs that changed outside workz, when that refused it.
    changed: []const ChangedOutput = &.{},

    fn refuse(self: Refusal, outcome: Outcome, reason: []const u8) !Outcome {
        std.debug.print("workz: {s}\n", .{reason});
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
        if (self.json or !term.isTerminal(1)) try sys.writeAll(1, w.written());
        return outcome;
    }
};

fn findBash(gpa: Allocator) ?[:0]const u8 {
    for ([_][:0]const u8{ "/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash" }) |p| {
        if (sys.exists(gpa, p)) return p;
    }
    return null;
}

/// Runs the selected rules. `environ` is the engine's environment; tasks get
/// only the allowlisted and passed-through variables.
pub fn execute(gpa: Allocator, a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, mask: []const bool, opts: Options, environ: *const std.process.Environ.Map) !Outcome {
    const max_threads = opts.max_threads orelse defaultThreads();
    const max_memory = opts.max_memory_mib orelse defaultMemoryMib(gpa);
    const max_jobs = opts.jobs orelse max_threads;

    const rec = try records.recordsDir(a, wf.root);
    try records.makeRecordsDir(gpa, rec);
    const lock_fd = records.lock(gpa, rec) catch |err| switch (err) {
        error.Busy => {
            std.debug.print("workz: another launch is running in {s}; watch it with workz watch, or run again after it ends\n", .{wf.root});
            return .failed;
        },
        else => return err,
    };
    defer sys.close(lock_fd);

    // Every launch past the lock leaves a record, refused ones included.
    const t_open = sys.monoNs();
    const launch = try records.newLaunch(gpa, a, rec);
    try sys.writeFile(gpa, try std.fs.path.join(a, &.{ launch.dir, "workflow" }), wf.source);
    var events = try records.Events.open(gpa, launch.dir);
    defer events.close();
    const exe = sys.self_exe;
    const exe_digest = try sys.sha256File(gpa, exe);
    const engine_id = try std.fmt.allocPrint(a, "workz {s} sha256:{s}", .{ version, &exe_digest });
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

    // One identity memo for the launch: the input check below fills it for
    // the key computation.
    var ids = state.Identities.init(gpa);
    defer ids.deinit();
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        for (r.input_abs, r.input) |in, written| {
            // A selected rule's producers are selected too.
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
    // A launch killed during an attempt left that attempt's earlier outputs
    // in its previous/: they go back to their paths before anything runs.
    recoverPrevious(gpa, a, wf, rec, launch.id, &events) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => std.debug.print("workz: cannot put back the earlier outputs a killed launch moved aside: {s}\n", .{sys.errorText(err)}),
    };

    // A recorded output that changed outside the engine is refused unless
    // --rerun, except when it has a stored digest and its bytes still match:
    // then its identity is refreshed and it stays reusable.
    var changed: usize = 0;
    var first_changed: []const u8 = "";
    var changed_outputs: std.ArrayList(ChangedOutput) = .empty;
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        const e = st.data.rules.map.getPtr(r.name) orelse continue;
        for (e.outputs, 0..) |o, k| {
            switch (try state.checkOutput(gpa, &ids, o)) {
                // A missing output makes its rule run again.
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
            // A rule run on request keeps its changed outputs in previous/.
            if (opts.forced(r.name)) continue;
            changed += 1;
            if (first_changed.len == 0) first_changed = o.path;
            try changed_outputs.append(a, .{ .rule = r.name, .path = o.path });
            {
                std.debug.print("workz: output of completed rule {s} changed since it was recorded: {s}\n", .{ r.name, o.path });
                events.emit("output_changed", .{ .rule = r.name, .path = o.path });
            }
        }
    }
    if (changed > 0) {
        var refused = refusal;
        refused.changed = changed_outputs.items;
        const which = if (changed == 1) "a recorded output" else try std.fmt.allocPrint(a, "{d} recorded outputs", .{changed});
        // The options that rerun exactly the rules whose outputs changed.
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
        return refused.refuse(.failed, try std.fmt.allocPrint(a, "{s} changed outside workz ({s}{s}); to run {s} again, keeping the earlier bytes in previous/, run with {s}, or with --rerun for every rule", .{ which, if (changed == 1) "" else "first ", first_changed, if (changed == 1) "the rule that wrote it" else "the rules that wrote them", opts_text.written() }));
    }

    // Input manifest: authoritative digests for external inputs.
    if (opts.input_manifest) |mpath| {
        const m = try checkManifest(gpa, &st, &ids, mpath);
        events.emit("inputs_checked", .{ .manifest = mpath, .files = m.files, .files_read = m.read, .bytes_read = m.bytes_read, .seconds = m.seconds, .ok = m.ok });
        if (!m.usable) return refusal.refuse(.invalid, "the input manifest cannot be used");
        if (!m.ok) return refusal.refuse(.failed, "inputs do not match the input manifest");
    }
    // Content digests valid for this launch: cutoff outputs and manifest inputs.
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

    // Container rules: Podman, local images resolved to IDs, leftovers removed.
    var podman: ?[]const u8 = null;
    var images: std.StringHashMapUnmanaged([]const u8) = .empty;
    const refs = try container.imageRefs(a, wf, mask);
    if (refs.len > 0) {
        const tc = sys.monoNs();
        podman = (try container.findPodman(gpa, a, environ.get("PATH") orelse "/usr/bin:/bin")) orelse
            return refusal.refuse(.invalid, "the workflow has container rules but podman is not on PATH");
        var missing: ?[]const u8 = null;
        images = try container.resolveImages(gpa, a, podman.?, refs, &host_envp, devnull, &missing);
        if (missing) |m| return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "container image {s} is not available locally; workz does not pull images", .{m}));
        const removed = try container.removeLeftovers(gpa, a, podman.?, wf.root, &host_envp, devnull);
        events.emit("containers_checked", .{ .images = images.count(), .leftovers_removed = removed, .seconds = @as(f64, @floatFromInt(sys.monoNs() - tc)) / 1e9 });
    }
    const extras = try container.ruleExtras(a, wf, &images);

    // Budget: the rules that will run, decided as `plan` decides them, must
    // each fit, with the shared inputs they use; a rule reused needs nothing.
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
    // The shared inputs of selected rules expected to be reused are measured
    // too where they can be, in case one of them runs after all.
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
    // A shared input that no rule that runs uses is never held.
    const holders = try a.alloc(Holder, wf.shared.len);
    for (holders, sizes) |*h, z| h.* = if (z) |s| .{ .bytes = s.bytes, .mib = s.mib, .reserve_mib = s.reserve_mib } else .{ .bytes = 0, .mib = 0, .reserve_mib = 0 };
    const shared_info = try a.alloc(struct { name: []const u8, path: ?[]const u8, container: ?[]const u8, bytes: u64 }, wf.shared.len);
    for (wf.shared, holders, 0..) |s, h, i| shared_info[i] = .{ .name = s.name, .path = s.path_abs, .container = s.container, .bytes = h.bytes };

    // Shared inputs are protected from reclaim by other work on the machine:
    // the run's scope gets a memory.low of their size.
    if (tree) |t| {
        var shared_mib: u64 = 0;
        for (holders) |h| shared_mib += h.mib;
        if (shared_mib > 0) {
            const ok = protectScope(gpa, a, t, shared_mib, environ.get("PATH") orelse "/usr/bin:/bin", &host_envp, devnull);
            events.emit("memory_protected", .{ .memory_low_mib = shared_mib, .ok = ok });
        }
    }
    var containers_cg: ?[]const u8 = null;
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
        .max_threads = max_threads,
        .max_memory = max_memory,
        .max_jobs = max_jobs,
        .tasks = try a.alloc(Task, wf.rules.len),
        .holders = holders,
        .group_used = try a.alloc(u32, wf.groups.len),
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
            std.debug.print("workz: bash not found\n", .{});
            return .invalid;
        },
        .devnull = devnull,
        .tree = tree,
        .network = null,
        .sigfd = sigfd,
        .selected = selected,
    };
    if (tree != null) {
        engine.network = Network.start(gpa, a, &engine.envp, tree.?.root) catch |err|
            return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "cannot create the run's network namespace: {s} ({s})", .{ sys.errorText(err), sys.errnoName() }));
    }
    defer if (engine.network) |n| n.stop();
    if (tree == null) engine.guard = Guard.start(a, &engine.envp, devnull) catch |err| guard: {
        std.debug.print("workz: cannot start the guard of --no-isolation attempts ({s}); they may outlive a killed engine\n", .{sys.errorText(err)});
        break :guard null;
    };
    defer if (engine.guard) |gd| gd.stop();
    defer engine.pending_done.deinit(gpa);
    defer engine.leftover_cgroups.deinit(gpa);
    defer engine.helpers.deinit(gpa);
    @memset(engine.group_used, 0);
    for (engine.tasks, 0..) |*t, i| {
        t.* = .{};
        if (!mask[i]) t.status = .excluded;
        t.max_attempts = 1 + (wf.rules[i].retries orelse opts.retry);
    }
    engine.last_save_ns = sys.monoNs();
    // The control file of this launch, watched for appended commands. It is
    // created without truncating: a command appended while the launch was
    // being set up is kept.
    engine.control_path = try std.fs.path.join(a, &.{ launch.dir, "control" });
    control: {
        const cfd = sys.openWrite(gpa, engine.control_path, .append) catch |err| {
            std.debug.print("workz: cannot create {s} ({s}); `workz control` will not reach this launch\n", .{ engine.control_path, sys.errorText(err) });
            break :control;
        };
        sys.close(cfd);
        const ifd = sys.check(linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK)) catch |err| {
            std.debug.print("workz: cannot watch the control file ({s}); `workz control` will not reach this launch\n", .{sys.errorText(err)});
            break :control;
        };
        const pz = try a.dupeZ(u8, engine.control_path);
        if (sys.check(linux.inotify_add_watch(@intCast(ifd), pz, linux.IN.MODIFY))) |_| {
            engine.control_watch = @intCast(ifd);
        } else |err| {
            std.debug.print("workz: cannot watch the control file ({s}); `workz control` will not reach this launch\n", .{sys.errorText(err)});
            sys.close(@intCast(ifd));
        }
    }
    defer if (engine.control_watch >= 0) sys.close(engine.control_watch);
    engine.next_sample_ns = engine.last_save_ns + sample_interval_ns;
    engine.last_sample_ns = engine.last_save_ns;
    if (engine.tree) |run_tree| engine.last_cpu_us = cgroup.cpuUsage(gpa, run_tree.root);
    engine.console = .{ .on = !opts.quiet and term.isTerminal(2), .color = opts.color and term.colorOn(2, environ) };
    engine.start_mono = t_open;
    const t0 = t_open;
    // The selected rules, so a view can list those that have yet to start.
    var selected_names: std.ArrayList([]const u8) = .empty;
    for (wf.rules, 0..) |r, ri| if (mask[ri]) try selected_names.append(a, r.name);
    events.emit("launch_started", .{ .launch = launch.id, .selected = selected, .rules = selected_names.items, .max_threads = max_threads, .max_memory_mib = max_memory, .jobs = max_jobs, .isolation = opts.isolation, .cgroup = if (tree) |t| t.root else null, .shared = shared_info, .checks_s = @as(f64, @floatFromInt(sys.monoNs() - t_open)) / 1e9 });
    // The launch's page, drawn now, again while the launch runs, and once
    // more when it ends.
    engine.page_path = try std.fs.path.join(a, &.{ launch.dir, "report.html" });
    {
        // The budget first: on a shared workstation, what this launch may take.
        var mem: std.Io.Writer.Allocating = .init(a);
        try units.size(&mem.writer, @floatFromInt(max_memory));
        const defaults = opts.max_threads == null and opts.max_memory_mib == null;
        engine.progress("budget", "{d} threads, {s}, {d} jobs{s}", .{ max_threads, mem.written(), max_jobs, if (defaults) " (the defaults: every CPU and 3/4 of the memory; set --max-threads and --max-memory to share the machine)" else "" });
    }
    engine.drawPage();
    if (engine.page_path) |p| engine.progress("page", "{s}, drawn again every 5 s while the launch runs", .{monitor.shownPath(a, p)});

    engine.loop() catch |err| {
        engine.fatal = sys.errorText(err);
        engine.beginStop();
        engine.beginEnding();
        // Wait for running tasks to end before writing the final records.
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
    engine.writeVersions() catch |err| std.debug.print("workz: cannot write versions.json: {s}\n", .{sys.errorText(err)});

    // Inputs of rules that ran must not have changed while the run went on:
    // their outputs would not match the inputs recorded in their key. A
    // reused rule keeps its earlier record, which the next launch checks.
    var ran = false;
    for (engine.tasks) |t| ran = ran or t.status == .completed;
    var post = state.Identities.init(gpa);
    defer post.deinit();
    var post_cut = if (ran) try state.Cutoff.init(a, gpa, wf, engine.st, &post, false) else undefined;
    if (ran) for (wf.rules, 0..) |*r, i| {
        const t = &engine.tasks[i];
        if (t.status != .completed) continue;
        const k = t.key orelse continue;
        var missing: ?[]const u8 = null;
        const again = state.ruleKey(a, &post, wf, g.parents[i], i, engine.st, &post_cut, TaskKeys{ .tasks = engine.tasks }, env_text, state.engine_key_text, engine.extras[i], &missing) catch |err| switch (err) {
            error.Unreadable => null,
            else => return err,
        };
        // Its attempt completed, but the result does not match its inputs:
        // the rule fails, and nothing records it as reusable.
        if (again == null or !std.mem.eql(u8, again.?.inputs, k.inputs)) {
            engine.fatal = try std.fmt.allocPrint(a, "inputs of rule {s} changed during the run", .{r.name});
            t.status = .failed;
            t.reason = "its inputs changed while the launch ran; run it again";
            engine.events.emit("task_failed", .{ .rule = r.name, .attempt = t.attempts, .reason = t.reason });
            _ = engine.st.data.rules.map.swapRemove(r.name);
            engine.dirty = true;
        }
    };

    for (engine.tasks) |*t| if (t.status == .pending or t.status == .ready) {
        t.status = if (engine.interrupted) .cancelled else .not_started;
    };
    engine.dirty = true;
    try engine.saveState(true);
    try records.Journal.reset(gpa, rec);
    for (engine.leftover_cgroups.items) |cg| cgroup.remove(gpa, cg) catch {};
    // Commands sent while the launch ended are answered in its events.
    if (engine.control_watch >= 0) engine.readControl() catch {};

    var counts: [@typeInfo(Status).@"enum".fields.len]usize = @splat(0);
    for (engine.tasks) |t| counts[@intFromEnum(t.status)] += 1;
    const failed = counts[@intFromEnum(Status.failed)] + counts[@intFromEnum(Status.blocked)] + counts[@intFromEnum(Status.not_started)];
    // Rules stopped on request, and nothing failed: the launch did not
    // complete, and says it was stopped; it exits 1 only if the stop left
    // rules blocked or unstarted.
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
    engine.clearStatus();
    // A person at a terminal gets the readable summary; scripts get JSON.
    if (!opts.json and term.isTerminal(1)) {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        // A blank line sets the summary apart from the event lines above it.
        if (engine.finished > 0 and !opts.quiet) try out.writer.writeAll("\n");
        try monitor.writeSummary(gpa, a, &out.writer, launch.dir, opts.color and term.colorOn(1, environ));
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

/// Checks an input manifest: absolute paths to "sha256:<hex>", or to
/// {"sha256": "sha256:<hex>", "stamp": {dev, ino, size, mtime_ns, ctime_ns}}.
/// A file is read only when neither the cached identity nor the stamp equals
/// its current identity; a matching stamp is trusted as the identity the
/// manifest's writer hashed.
fn checkManifest(gpa: Allocator, st: *state.State, ids: *state.Identities, mpath: []const u8) !ManifestCheck {
    const t0 = sys.monoNs();
    var res: ManifestCheck = .{ .ok = true };
    const bytes = sys.readFile(gpa, mpath, 256 << 20) catch |err| {
        std.debug.print("workz: cannot read input manifest {s}: {s}\n", .{ mpath, sys.errorText(err) });
        return .{ .ok = false, .usable = false };
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch {
        std.debug.print("workz: input manifest {s} must be a JSON object of absolute paths\n", .{mpath});
        return .{ .ok = false, .usable = false };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        std.debug.print("workz: input manifest {s} must be a JSON object of absolute paths\n", .{mpath});
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
            std.debug.print("workz: invalid input manifest entry {s}\n", .{path});
            res.ok = false;
            continue;
        }
        // A digest covers one regular file's bytes.
        if (sys.stat(gpa, path) catch null) |id| if (!id.isReg()) {
            std.debug.print("workz: input manifest entry is not a regular file: {s}\n", .{path});
            res.ok = false;
            continue;
        };
        const id_text = (ids.get(path) catch |err| switch (err) {
            error.Unreadable => {
                std.debug.print("workz: {s}\n", .{ids.problem});
                res.ok = false;
                continue;
            },
            else => return err,
        }) orelse {
            std.debug.print("workz: input manifest file is missing: {s}\n", .{path});
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
            std.debug.print("workz: input does not match its manifest digest: {s}\n", .{path});
            res.ok = false;
        }
    }
    if (res.ok and hashed_any) try st.save(gpa);
    res.seconds = @as(f64, @floatFromInt(sys.monoNs() - t0)) / 1e9;
    return res;
}

/// A preparer's stamp still describes the file: same inode, size and
/// modification and change times. The device number is not compared, since
/// btrfs numbers it anew at each mount.
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
