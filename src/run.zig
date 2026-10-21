//! The run loop: admission, dispatch, reaping, timeouts, retries,
//! cancellation, shared-input holders and records.
//!
//! One thread waits in ppoll on a signalfd and the shared holders' pipes, with
//! the nearest timeout as its deadline. Ready rules are tried in priority
//! order, then by the time they became ready, then by file order; every rule
//! whose CPU, memory, group, shared-input and job requests fit starts.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const state = @import("state.zig");
const records = @import("records.zig");
const process = @import("process.zig");
const cgroup = @import("cgroup.zig");
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
    input_manifest: ?[]const u8 = null,
    isolation: bool = true,
    pass_env: []const []const u8 = &.{},
    grace_s: u64 = 10,
    quiet: bool = false,
    /// systemd slice the isolated run's scope is placed in.
    slice: ?[]const u8 = null,
};

pub const Outcome = enum(u8) { ok = 0, failed = 1, invalid = 2, interrupted = 130 };

const Status = enum { pending, ready, staging, running, completed, reused, failed, blocked, cancelled, not_started, excluded };

const Task = struct {
    status: Status = .pending,
    ready_seq: u64 = 0,
    attempts: u32 = 0,
    max_attempts: u32 = 1,
    key: ?state.Key = null,
    pid: linux.pid_t = 0,
    cg: ?[]const u8 = null,
    dir: []const u8 = "",
    started_ns: i128 = 0,
    started_real: i128 = 0,
    deadline_ns: ?i128 = null,
    kill_at: ?i128 = null,
    timed_out: bool = false,
    cancelled: bool = false,
    reason: []const u8 = "",
    /// When the current attempt became ready (monotonic).
    ready_ns: i128 = 0,
    /// What keeps the ready attempt from starting, and since when.
    wait_reason: ?[]const u8 = null,
    wait_since: i128 = 0,
    waits: std.ArrayList(Wait) = .empty,
    /// Seconds from ready to start of the current attempt.
    queued_s: f64 = 0,
};

/// Time a ready attempt spent waiting for one reason.
const Wait = struct { reason: []const u8, seconds: f64 };

/// The run's user and network namespaces, held by a `__netns` child.
const Network = struct {
    pid: linux.pid_t,
    userns: sys.Fd,
    netns: sys.Fd,

    fn start(gpa: Allocator, a: Allocator, envp: *const process.Vec, devnull: sys.Fd) !Network {
        var pipe: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
        defer sys.close(pipe[0]);
        const exe = try a.dupeZ(u8, try sys.selfExe(a));
        const argv = try process.Vec.init(a, &.{ "workz", "__netns" });
        const spec: process.Spec = .{ .path = exe.ptr, .argv = argv.items.ptr, .envp = envp.items.ptr, .cwd = "/", .stdin = devnull, .stdout = pipe[1], .stderr = 2 };
        const pid = process.spawn(&spec) catch |err| {
            sys.close(pipe[1]);
            return err;
        };
        sys.close(pipe[1]);
        var buf: [16]u8 = undefined;
        const n = sys.read(pipe[0], &buf) catch 0;
        if (n < 5 or !std.mem.startsWith(u8, buf[0..n], "ready")) {
            process.signalPid(pid, .KILL);
            return error.NetworkNotReady;
        }
        const user_path = try std.fmt.allocPrint(gpa, "/proc/{d}/ns/user", .{pid});
        defer gpa.free(user_path);
        const net_path = try std.fmt.allocPrint(gpa, "/proc/{d}/ns/net", .{pid});
        defer gpa.free(net_path);
        return .{ .pid = pid, .userns = try sys.openRead(gpa, user_path), .netns = try sys.openRead(gpa, net_path) };
    }

    fn stop(self: Network) void {
        sys.close(self.userns);
        sys.close(self.netns);
        process.signalPid(self.pid, .KILL);
        var status: u32 = 0;
        _ = linux.wait4(self.pid, &status, 0, null);
    }
};

const HolderState = enum { idle, loading, ready, stopping, failed };

const Holder = struct {
    bytes: u64,
    mib: u64,
    users: u32 = 0,
    st: HolderState = .idle,
    pid: linux.pid_t = 0,
    pipe: sys.Fd = -1,
    cg: ?[]const u8 = null,
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
    records: []const u8,
    launch_dir: []const u8,
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
    sigfd: sys.Fd,

    stopping: bool = false,
    interrupted: bool = false,
    interrupted_at: i128 = 0,
    fatal: ?[]const u8 = null,
    dirty: bool = false,
    pending_done: std.ArrayList([]const u8) = .empty,
    last_save_ns: i128 = 0,
    /// Run samples: the next sample time and the CPU counter at the last one.
    next_sample_ns: i128 = 0,
    last_sample_ns: i128 = 0,
    last_cpu_us: ?u64 = null,
    leftover_cgroups: std.ArrayList([]const u8) = .empty,
    finished: usize = 0,
    selected: usize = 0,

    fn progress(self: *Engine, comptime fmt: []const u8, args: anytype) void {
        if (self.opts.quiet) return;
        std.debug.print("[{d}/{d}] " ++ fmt ++ "\n", .{ self.finished, self.selected } ++ args);
    }

    /// Failures are printed even in quiet mode.
    fn alert(self: *Engine, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[{d}/{d}] " ++ fmt ++ "\n", .{ self.finished, self.selected } ++ args);
    }

    fn rule(self: *Engine, i: usize) *const workflow.Rule {
        return &self.wf.rules[i];
    }

    // ---- readiness and reuse ----

    fn updateReadiness(self: *Engine) !void {
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
                t.reason = "a producing rule did not complete";
                self.finished += 1;
                self.events.emit("task_blocked", .{ .rule = self.rule(i).name });
                continue;
            }
            if (!all_done or self.stopping) continue;
            try self.makeReady(i);
        }
    }

    fn makeReady(self: *Engine, i: usize) !void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        // Rules not produced by this launch keep their recorded keys.
        var names: std.ArrayList([]const u8) = .empty;
        var keys: std.ArrayList([]const u8) = .empty;
        for (self.g.parents[i]) |p| {
            try names.append(self.a, self.rule(p).name);
            const pk = if (self.tasks[p].key) |k| k.key else if (self.st.data.rules.map.get(self.rule(p).name)) |e| e.key else "none";
            try keys.append(self.a, self.cut.parentKey(p, pk));
        }
        var missing: ?[]const u8 = null;
        const key = try state.computeKey(self.a, self.ids, r, self.env_text, names.items, keys.items, self.engine_id, self.cut, &missing);
        if (key == null) {
            t.status = .failed;
            t.reason = try std.fmt.allocPrint(self.a, "missing input {s}", .{missing.?});
            self.finished += 1;
            self.events.emit("task_failed", .{ .rule = r.name, .reason = t.reason });
            self.alert("failed {s}: {s}", .{ r.name, t.reason });
            if (!self.opts.keep_going) self.beginStop();
            return;
        }
        t.key = key.?;
        if (!self.opts.rerun) if (self.st.data.rules.map.get(r.name)) |e| {
            if (std.mem.eql(u8, e.key, key.?.key) and try self.outputsIntact(&e)) {
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

    fn outputsIntact(self: *Engine, e: *const state.Entry) !bool {
        for (e.outputs) |o| {
            const id = (try self.ids.get(o.path)) orelse return false;
            if (!std.mem.eql(u8, id, o.id)) return false;
        }
        return true;
    }

    // ---- admission ----

    /// The first resource that keeps a ready rule from starting, or null
    /// when it fits: "jobs", "threads", "memory" or "group:NAME".
    fn blocker(self: *Engine, i: usize) ?[]const u8 {
        const r = self.rule(i);
        if (self.jobs_used + 1 > self.max_jobs) return "jobs";
        if (self.threads_used + r.threads > self.max_threads) return "threads";
        var mem = r.memory_mib;
        for (r.shared) |s| {
            const h = &self.holders[self.wf.sharedIndex(s).?];
            if (h.users == 0) mem += h.mib;
        }
        if (self.memory_used + mem > self.max_memory) return "memory";
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

    fn closeWait(self: *Engine, t: *Task, reason: []const u8) !void {
        const s = @as(f64, @floatFromInt(sys.monoNs() - t.wait_since)) / 1e9;
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
            self.memory_used += r.memory_mib;
        } else {
            self.jobs_used -= 1;
            self.threads_used -= r.threads;
            self.memory_used -= r.memory_mib;
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
        std.mem.sort(usize, ready.items, self, readyBefore);
        for (ready.items) |i| {
            if (self.blocker(i)) |why| {
                try self.setWait(i, why);
                continue;
            }
            self.reserve(i, true);
            const r = self.rule(i);
            var waiting = false;
            for (r.shared) |s| {
                const hi = self.wf.sharedIndex(s).?;
                const h = &self.holders[hi];
                if (h.users == 0) self.memory_used += h.mib;
                h.users += 1;
                if (h.st == .idle) try self.startHolder(hi);
                if (h.st != .ready) waiting = true;
            }
            if (waiting) {
                self.tasks[i].status = .staging;
                try self.setWait(i, "loading shared inputs");
            } else try self.start(i);
        }
    }

    fn readyBefore(self: *Engine, x: usize, y: usize) bool {
        const rx = self.rule(x);
        const ry = self.rule(y);
        if (rx.priority != ry.priority) return rx.priority > ry.priority;
        const sx = self.tasks[x].ready_seq;
        const sy = self.tasks[y].ready_seq;
        if (sx != sy) return sx < sy;
        return x < y;
    }

    // ---- starting attempts ----

    fn start(self: *Engine, i: usize) !void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        t.attempts += 1;
        t.dir = try std.fmt.allocPrint(self.a, "{s}/attempts/{s}/{d:0>3}", .{ self.launch_dir, r.name, t.attempts });
        try sys.mkdirAll(self.gpa, t.dir);
        t.timed_out = false;
        t.cancelled = false;
        t.kill_at = null;
        try self.setWait(i, null);
        t.queued_s = @as(f64, @floatFromInt(sys.monoNs() - t.ready_ns)) / 1e9;

        const script = try std.fmt.allocPrint(self.a, "{s}/command.sh", .{t.dir});
        const body = try std.fmt.allocPrint(self.gpa, "#!/usr/bin/env bash\nset -euo pipefail\n{s}\n", .{r.shell});
        defer self.gpa.free(body);
        try sys.writeFile(self.gpa, script, body);
        try records.writeJson(self.gpa, try std.fmt.allocPrint(self.a, "{s}/request.json", .{t.dir}), .{
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

        // Keep earlier bytes of every output: move them into previous/.
        for (r.output_abs, 0..) |o, k| {
            if (try sys.lstat(self.gpa, o)) |_| {
                const prev = try std.fmt.allocPrint(self.a, "{s}/previous", .{t.dir});
                try sys.mkdir(self.gpa, prev);
                const dest = try std.fmt.allocPrint(self.a, "{s}/{d}-{s}", .{ prev, k, std.fs.path.basename(o) });
                try sys.rename(self.gpa, o, dest);
                self.events.emit("output_preserved", .{ .rule = r.name, .path = r.output[k], .moved_to = dest });
            }
            self.ids.forget(o);
            if (std.fs.path.dirname(o)) |d| try sys.mkdirAll(self.gpa, d);
        }

        try self.journal.mark(self.gpa, "dispatch", r.name);
        if (self.st.data.rules.map.fetchSwapRemove(r.name) != null) self.dirty = true;

        const out_fd = try sys.openWrite(self.gpa, try std.fmt.allocPrint(self.a, "{s}/stdout.log", .{t.dir}), .truncate);
        defer sys.close(out_fd);
        const err_fd = try sys.openWrite(self.gpa, try std.fmt.allocPrint(self.a, "{s}/stderr.log", .{t.dir}), .truncate);
        defer sys.close(err_fd);

        var procs: sys.Fd = -1;
        t.cg = null;
        if (self.tree) |tree| {
            const name = try std.fmt.allocPrint(self.a, "task-{d}-{d}", .{ i, t.attempts });
            t.cg = try cgroup.create(self.gpa, self.a, tree, name, .{ .memory_bytes = r.memory_mib * 1024 * 1024, .threads = r.threads, .oom_group = true });
            procs = try cgroup.openProcs(self.gpa, t.cg.?);
        }
        defer if (procs >= 0) sys.close(procs);

        const env = try self.taskEnv(r, t.dir);
        const argv = try process.Vec.init(self.a, &.{ "bash", "-euo", "pipefail", script });
        const spec: process.Spec = .{
            .path = self.bash.ptr,
            .argv = argv.items.ptr,
            .envp = env.items.ptr,
            .cwd = (try self.a.dupeZ(u8, self.wf.root)).ptr,
            .stdin = self.devnull,
            .stdout = out_fd,
            .stderr = err_fd,
            .cgroup_procs = procs,
            .userns = if (self.network) |n| n.userns else -1,
            .netns = if (self.network) |n| n.netns else -1,
        };
        t.pid = process.spawn(&spec) catch |err| {
            t.status = .failed;
            t.reason = try std.fmt.allocPrint(self.a, "cannot start: {s} ({s})", .{ @errorName(err), sys.errnoName() });
            self.reserve(i, false);
            self.releaseShared(i);
            self.finished += 1;
            self.events.emit("task_failed", .{ .rule = r.name, .attempt = t.attempts, .reason = t.reason });
            self.alert("failed {s}: {s}", .{ r.name, t.reason });
            if (!self.opts.keep_going) self.beginStop();
            return;
        };
        t.status = .running;
        t.started_ns = sys.monoNs();
        t.started_real = sys.realNs();
        t.deadline_ns = if (self.timeoutOf(r)) |s| t.started_ns + @as(i128, s) * std.time.ns_per_s else null;
        self.events.emit("task_started", .{ .rule = r.name, .attempt = t.attempts, .pid = t.pid, .cgroup = t.cg, .directory = t.dir, .threads = r.threads, .memory_mib = r.memory_mib, .waited_s = t.queued_s });
        self.progress("started {s} (attempt {d})", .{ r.name, t.attempts });
    }

    fn timeoutOf(self: *Engine, r: *const workflow.Rule) ?u64 {
        return r.timeout_s orelse self.opts.timeout_s;
    }

    fn taskEnv(self: *Engine, r: *const workflow.Rule, dir: []const u8) !process.Vec {
        var list: std.ArrayList([]const u8) = .empty;
        for (self.envp.items) |e| try list.append(self.a, std.mem.span(e.?));
        try list.append(self.a, try std.fmt.allocPrint(self.a, "WORKZ_RULE={s}", .{r.name}));
        try list.append(self.a, try std.fmt.allocPrint(self.a, "WORKZ_ATTEMPT_DIR={s}", .{dir}));
        try list.append(self.a, try std.fmt.allocPrint(self.a, "WORKZ_THREADS={d}", .{r.threads}));
        try list.append(self.a, try std.fmt.allocPrint(self.a, "WORKZ_MEMORY_MIB={d}", .{r.memory_mib}));
        return process.Vec.init(self.a, list.items);
    }

    // ---- shared input holders ----

    fn startHolder(self: *Engine, hi: usize) !void {
        const h = &self.holders[hi];
        const s = self.wf.shared[hi];
        var files: std.ArrayList([]u8) = .empty;
        defer {
            for (files.items) |f| self.gpa.free(f);
            files.deinit(self.gpa);
        }
        try state.listFiles(self.gpa, s.path_abs, &files);
        var argv_list: std.ArrayList([]const u8) = .empty;
        try argv_list.append(self.a, "workz");
        try argv_list.append(self.a, "__hold");
        for (files.items) |f| try argv_list.append(self.a, try self.a.dupe(u8, f));
        const argv = try process.Vec.init(self.a, argv_list.items);
        const exe = try sys.selfExe(self.a);

        var pipe: [2]i32 = undefined;
        _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
        defer sys.close(pipe[1]);
        var procs: sys.Fd = -1;
        if (self.tree) |tree| {
            h.cg = try cgroup.create(self.gpa, self.a, tree, try std.fmt.allocPrint(self.a, "shared-{s}", .{s.name}), .{});
            procs = try cgroup.openProcs(self.gpa, h.cg.?);
        }
        defer if (procs >= 0) sys.close(procs);
        const spec: process.Spec = .{
            .path = (try self.a.dupeZ(u8, exe)).ptr,
            .argv = argv.items.ptr,
            .envp = self.envp.items.ptr,
            .cwd = "/",
            .stdin = self.devnull,
            .stdout = pipe[1],
            .stderr = 2,
            .cgroup_procs = procs,
        };
        h.pid = try process.spawn(&spec);
        h.pipe = pipe[0];
        h.st = .loading;
        self.events.emit("shared_loading", .{ .name = s.name, .path = s.path, .bytes = h.bytes, .pid = h.pid });
        self.progress("loading shared input {s} ({d} MiB)", .{ s.name, h.mib });
    }

    fn holderReady(self: *Engine, hi: usize) !void {
        const h = &self.holders[hi];
        var buf: [128]u8 = undefined;
        const n = sys.read(h.pipe, &buf) catch 0;
        sys.close(h.pipe);
        h.pipe = -1;
        if (n == 0 or !std.mem.startsWith(u8, buf[0..n], "ready")) {
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

    fn sharedReady(self: *Engine, i: usize) bool {
        for (self.rule(i).shared) |s| if (self.holders[self.wf.sharedIndex(s).?].st != .ready) return false;
        return true;
    }

    fn releaseShared(self: *Engine, i: usize) void {
        for (self.rule(i).shared) |s| {
            const hi = self.wf.sharedIndex(s).?;
            const h = &self.holders[hi];
            h.users -= 1;
            if (h.users > 0) continue;
            self.memory_used -= h.mib;
            if (h.pid > 0 and (h.st == .loading or h.st == .ready)) {
                process.signalPid(h.pid, .TERM);
                h.st = .stopping;
            }
        }
    }

    fn holderExited(self: *Engine, hi: usize) void {
        const h = &self.holders[hi];
        const was = h.st;
        h.pid = 0;
        if (h.pipe >= 0) {
            sys.close(h.pipe);
            h.pipe = -1;
        }
        if (h.cg) |cg| {
            cgroup.kill(self.gpa, cg);
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg) catch {};
            h.cg = null;
        }
        if (was == .stopping) {
            h.st = .idle;
            self.events.emit("shared_released", .{ .name = self.wf.shared[hi].name });
            return;
        }
        h.st = .failed;
        self.events.emit("shared_failed", .{ .name = self.wf.shared[hi].name });
        // Rules waiting on this input cannot start.
        for (self.tasks, 0..) |*t, i| {
            if (t.status != .staging) continue;
            for (self.rule(i).shared) |s| if (self.wf.sharedIndex(s).? == hi) {
                t.status = .failed;
                t.reason = "shared input could not be loaded";
                self.reserve(i, false);
                self.releaseShared(i);
                self.finished += 1;
                self.events.emit("task_failed", .{ .rule = self.rule(i).name, .reason = t.reason });
                if (!self.opts.keep_going) self.beginStop();
                break;
            };
        }
    }

    // ---- finishing attempts ----

    fn finish(self: *Engine, i: usize, reaped: process.Reaped) !void {
        const t = &self.tasks[i];
        const r = self.rule(i);
        const now_real = sys.realNs();
        const wall_s = @as(f64, @floatFromInt(sys.monoNs() - t.started_ns)) / 1e9;
        var counters: ?cgroup.Counters = null;
        if (t.cg) |cg| {
            counters = cgroup.read(self.gpa, cg);
            // Descendants left behind by the command end with it.
            if (cgroup.populated(self.gpa, cg)) cgroup.kill(self.gpa, cg);
            cgroup.remove(self.gpa, cg) catch self.leftover_cgroups.append(self.gpa, cg) catch {};
        } else process.signalGroup(t.pid, .KILL);
        self.reserve(i, false);
        self.releaseShared(i);

        var ok = false;
        var reason: []const u8 = "";
        const code = reaped.exitCode();
        const sig = reaped.signal();
        if (t.cancelled) {
            reason = "cancelled";
        } else if (t.timed_out) {
            reason = try std.fmt.allocPrint(self.a, "timed out after {d} s", .{self.timeoutOf(r).?});
        } else if (counters != null and counters.?.oom_kill > 0) {
            reason = try std.fmt.allocPrint(self.a, "out of memory: could not stay within its {d} MiB request", .{r.memory_mib});
        } else if (code) |c| {
            if (c == 0) {
                ok = true;
                for (r.output_abs, r.output) |o, written| {
                    self.ids.forget(o);
                    const id = try sys.stat(self.gpa, o);
                    if (id == null or !id.?.isReg()) {
                        ok = false;
                        reason = try std.fmt.allocPrint(self.a, "exited 0 without output {s}", .{written});
                        break;
                    }
                }
            } else reason = try std.fmt.allocPrint(self.a, "exited with status {d}", .{c});
        } else if (sig) |s| {
            reason = try std.fmt.allocPrint(self.a, "killed by signal {d}", .{s});
        }

        var outputs: std.ArrayList(state.Output) = .empty;
        if (ok) for (r.output_abs) |o| {
            const sa = self.st.allocator();
            const id = (try self.ids.get(o)) orelse "";
            // Cutoff rules keep a content digest beside the identity.
            const digest: ?[]const u8 = if (r.cutoff) try sa.dupe(u8, &try sys.sha256File(self.gpa, o)) else null;
            try outputs.append(sa, .{ .path = try sa.dupe(u8, o), .id = try sa.dupe(u8, id), .sha256 = digest });
        };
        if (ok and r.cutoff) try self.cut.record(self.a, i, outputs.items);

        try self.writeSideFiles(r, t, ok, wall_s, reaped, counters);
        const status: []const u8 = if (ok) "completed" else if (t.cancelled) "cancelled" else "failed";
        const finished_text = try records.timeText(self.a, now_real);
        try records.writeJson(self.gpa, try std.fmt.allocPrint(self.a, "{s}/record.json", .{t.dir}), .{
            .v = 1,
            .rule = r.name,
            .attempt = t.attempts,
            .status = status,
            .reason = reason,
            .exit_code = code,
            .signal = sig,
            .started = try records.timeText(self.a, t.started_real),
            .finished = finished_text,
            .wall_s = wall_s,
            .rusage = .{
                .cpu_s = reaped.cpuSeconds(),
                .maxrss_kib = reaped.usage.maxrss,
            },
            .cgroup = counters,
            .request = .{ .threads = r.threads, .memory_mib = r.memory_mib, .groups = r.groups, .shared = r.shared },
            .outputs = outputs.items,
            .queue = .{ .waited_s = t.queued_s, .reasons = t.waits.items },
            .key = if (t.key) |k| k.key else null,
        });

        if (ok) {
            t.status = .completed;
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
            });
            try self.recordFiles(r);
            self.dirty = true;
            try self.pending_done.append(self.gpa, r.name);
            self.finished += 1;
            self.events.emit("task_finished", .{ .rule = r.name, .attempt = t.attempts, .status = "completed", .wall_s = wall_s, .cpu_s = reaped.cpuSeconds(), .maxrss_kib = reaped.usage.maxrss, .memory_peak = if (counters) |c| c.memory_peak else null });
            self.progress("completed {s} ({d:.1} s)", .{ r.name, wall_s });
            return;
        }
        t.reason = reason;
        self.events.emit("task_finished", .{ .rule = r.name, .attempt = t.attempts, .status = status, .reason = reason, .exit_code = code, .signal = sig, .wall_s = wall_s });
        if (!t.cancelled and !self.stopping and t.attempts < t.max_attempts) {
            t.status = .ready;
            self.ready_counter += 1;
            t.ready_seq = self.ready_counter;
            t.ready_ns = sys.monoNs();
            t.waits = .empty;
            t.wait_reason = null;
            self.events.emit("task_retry", .{ .rule = r.name, .next_attempt = t.attempts + 1 });
            self.alert("retrying {s}: {s}", .{ r.name, reason });
            return;
        }
        t.status = if (t.cancelled) .cancelled else .failed;
        self.finished += 1;
        self.alert("{s} {s}: {s} (see {s}/stderr.log)", .{ status, r.name, reason, t.dir });
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
                .cpu_seconds = reaped.cpuSeconds(),
                .max_rss_mb = @as(f64, @floatFromInt(reaped.usage.maxrss)) / 1024.0,
                .memory_peak_mb = if (counters) |c| if (c.memory_peak) |p| @as(f64, @floatFromInt(p)) / 1048576.0 else null else null,
                .memory_limit_mb = r.memory_mib,
                .retries = t.attempts - 1,
            });
        };
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

    // ---- stopping ----

    fn beginStop(self: *Engine) void {
        if (self.stopping) return;
        self.stopping = true;
        const grace = @as(i128, self.opts.grace_s) * std.time.ns_per_s;
        for (self.tasks, 0..) |*t, i| switch (t.status) {
            .running => {
                t.cancelled = true;
                process.signalGroup(t.pid, .TERM);
                t.kill_at = sys.monoNs() + grace;
                self.events.emit("task_cancelling", .{ .rule = self.rule(i).name });
            },
            .staging => {
                t.status = .cancelled;
                t.reason = "cancelled before start";
                self.reserve(i, false);
                self.releaseShared(i);
                self.finished += 1;
            },
            else => {},
        };
    }

    fn checkTimers(self: *Engine) void {
        const now = sys.monoNs();
        const grace = @as(i128, self.opts.grace_s) * std.time.ns_per_s;
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
                process.signalGroup(t.pid, .TERM);
                t.kill_at = now + grace;
                t.deadline_ns = null;
                self.events.emit("task_timeout", .{ .rule = self.rule(i).name, .attempt = t.attempts });
            };
        }
    }

    fn nextDeadline(self: *Engine) ?i128 {
        var best: ?i128 = null;
        for (self.tasks) |t| {
            if (t.status != .running) continue;
            for ([_]?i128{ t.deadline_ns, t.kill_at }) |d| if (d) |v| {
                best = if (best) |b| @min(b, v) else v;
            };
        }
        if (self.dirty) {
            const save_at = self.last_save_ns + std.time.ns_per_s;
            best = if (best) |b| @min(b, save_at) else save_at;
        }
        best = if (best) |b| @min(b, self.next_sample_ns) else self.next_sample_ns;
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
            const cpu = cgroup.cpuUsage(self.gpa, tree.root);
            if (cpu != null and self.last_cpu_us != null and now > self.last_sample_ns)
                cpu_cores = @as(f64, @floatFromInt(cpu.? -| self.last_cpu_us.?)) / (@as(f64, @floatFromInt(now - self.last_sample_ns)) / 1e3);
            self.last_cpu_us = cpu;
        }
        self.events.emit("sample", .{
            .running = running_n,
            .ready = ready_n,
            .threads_reserved = self.threads_used,
            .memory_reserved_mib = self.memory_used,
            .memory_current = memory_current,
            .cpu_cores_used = cpu_cores,
        });
        self.last_sample_ns = now;
        self.next_sample_ns = now + sample_interval_ns;
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

    fn reapAll(self: *Engine) !void {
        while (process.reap()) |rp| {
            for (self.tasks, 0..) |*t, i| {
                if (t.status == .running and t.pid == rp.pid) {
                    try self.finish(i, rp);
                    break;
                }
            } else for (self.holders, 0..) |*h, hi| {
                if (h.pid == rp.pid) {
                    self.holderExited(hi);
                    break;
                }
            }
        }
    }

    fn loop(self: *Engine) !void {
        while (true) {
            try self.updateReadiness();
            try self.admit();
            try self.saveState(false);
            if (self.running() == 0) {
                var any_ready = false;
                for (self.tasks) |t| any_ready = any_ready or t.status == .ready or t.status == .pending;
                if (!any_ready or self.stopping) break;
                // Ready work that cannot fit any longer would wait forever.
                var stuck = true;
                for (self.tasks) |t| if (t.status == .pending) {
                    stuck = false;
                };
                if (stuck) {
                    self.fatal = "ready rules cannot fit the budget";
                    break;
                }
                continue;
            }
            var fds: std.ArrayList(linux.pollfd) = .empty;
            defer fds.deinit(self.gpa);
            try fds.append(self.gpa, .{ .fd = self.sigfd, .events = linux.POLL.IN, .revents = 0 });
            for (self.holders) |h| if (h.st == .loading and h.pipe >= 0) try fds.append(self.gpa, .{ .fd = h.pipe, .events = linux.POLL.IN, .revents = 0 });
            process.wait(fds.items, self.nextDeadline());
            const seen = process.readSignals(self.sigfd);
            if (process.has(seen, .INT) or process.has(seen, .TERM) or process.has(seen, .HUP)) {
                // A repeated interrupt kills at once; one arriving within a second of
                // the first is the same request delivered twice (terminal and launcher).
                if (self.interrupted) {
                    if (sys.monoNs() - self.interrupted_at >= std.time.ns_per_s) for (self.tasks) |*t| if (t.status == .running) {
                        t.kill_at = sys.monoNs();
                    };
                } else {
                    self.interrupted = true;
                    self.interrupted_at = sys.monoNs();
                    self.events.emit("cancel_requested", .{ .signal = if (process.has(seen, .INT)) "SIGINT" else if (process.has(seen, .TERM)) "SIGTERM" else "SIGHUP" });
                    if (!self.opts.quiet) std.debug.print("workz: interrupted; stopping running tasks (interrupt again to kill)\n", .{});
                    self.beginStop();
                }
            }
            for (fds.items[1..]) |f| if (f.revents != 0) {
                for (self.holders, 0..) |h, hi| if (h.pipe == f.fd) try self.holderReady(hi);
            };
            try self.reapAll();
            self.checkTimers();
            self.sample();
        }
    }
};

/// Interval between run samples.
const sample_interval_ns: i128 = 5 * std.time.ns_per_s;

fn groupIndex(wf: *const workflow.Workflow, name: []const u8) usize {
    for (wf.groups, 0..) |g, i| if (std.mem.eql(u8, g.name, name)) return i;
    unreachable;
}

/// The engine's own CPU time and peak memory, without its tasks.
fn engineCost() struct { cpu_s: f64, max_rss_mib: f64 } {
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

    fn refuse(self: Refusal, outcome: Outcome, reason: []const u8) !Outcome {
        std.debug.print("workz: {s}\n", .{reason});
        const elapsed = @as(f64, @floatFromInt(sys.monoNs() - self.t0)) / 1e9;
        self.events.emit("launch_refused", .{ .reason = reason });
        const summary = .{
            .engine = self.engine,
            .launch = self.launch,
            .status = "refused",
            .counts = .{ .completed = 0, .reused = 0, .failed = 0, .blocked = 0, .cancelled = 0, .not_started = self.selected },
            .selected = self.selected,
            .elapsed_s = elapsed,
            .finished = try records.timeText(self.a, sys.realNs()),
            .@"error" = reason,
            .launch_dir = self.dir,
        };
        self.events.emit("launch_finished", .{ .status = "refused", .elapsed_s = elapsed, .@"error" = reason });
        try records.writeJson(self.gpa, try std.fs.path.join(self.a, &.{ self.dir, "summary.json" }), summary);
        var w: std.Io.Writer.Allocating = .init(self.gpa);
        defer w.deinit();
        try w.writer.print("{f}\n", .{std.json.fmt(summary, .{})});
        try sys.writeAll(1, w.written());
        return outcome;
    }
};

const env_allow = [_][]const u8{ "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TZ", "TMPDIR", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "TERM" };

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
    try sys.mkdirAll(gpa, rec);
    const lock_fd = records.lock(gpa, rec) catch |err| switch (err) {
        error.Busy => {
            std.debug.print("workz: another run holds {s}/lock\n", .{rec});
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
    const exe = try sys.selfExe(a);
    const exe_digest = try sys.sha256File(gpa, exe);
    const engine_id = try std.fmt.allocPrint(a, "workz {s} sha256:{s}", .{ version, &exe_digest });
    var selected: usize = 0;
    for (mask) |m| selected += @intFromBool(m);
    try records.writeJson(gpa, try std.fs.path.join(a, &.{ launch.dir, "launch.json" }), .{
        .engine = engine_id,
        .engine_key = state.engine_key,
        .launch = launch.id,
        .workflow = wf.path,
        .workflow_sha256 = &sys.sha256Bytes(wf.source),
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
        .slice = opts.slice,
        .selected = selected,
    });
    const refusal: Refusal = .{ .gpa = gpa, .a = a, .events = &events, .launch = launch.id, .dir = launch.dir, .engine = engine_id, .selected = selected, .t0 = t_open };

    // Budget and input checks.
    var holders = try a.alloc(Holder, wf.shared.len);
    for (wf.shared, 0..) |s, i| {
        const bytes = state.pageBytes(gpa, s.path_abs) catch |err|
            return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "shared input {s} ({s}): {s}", .{ s.name, s.path, @errorName(err) }));
        holders[i] = .{ .bytes = bytes, .mib = std.math.divCeil(u64, bytes, 1024 * 1024) catch unreachable };
    }
    var produced: std.StringHashMapUnmanaged(void) = .empty;
    defer produced.deinit(gpa);
    for (wf.rules, 0..) |r, i| if (mask[i]) for (r.output_abs) |o| try produced.put(gpa, o, {});
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        var need = r.memory_mib;
        for (r.shared) |s| need += holders[wf.sharedIndex(s).?].mib;
        if (r.threads > max_threads)
            return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "rule {s} requests {d} threads; the run allows {d}", .{ r.name, r.threads, max_threads }));
        if (need > max_memory)
            return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "rule {s} needs {d} MiB with its shared inputs; the run allows {d} MiB", .{ r.name, need, max_memory }));
        for (r.input_abs, r.input) |in, written| {
            if (produced.contains(in)) continue;
            if (!sys.exists(gpa, in)) return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "missing input of rule {s}: {s}", .{ r.name, written }));
        }
    }

    var st = state.load(gpa, rec) catch |err| switch (err) {
        error.UnsupportedState => return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "{s}/state.json has an unsupported format version", .{rec})),
        error.CorruptState => return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "{s}/state.json cannot be read", .{rec})),
        else => return err,
    };
    defer st.deinit();
    // Rules dispatched by an interrupted launch without a saved result run again.
    for (try records.Journal.unfinished(gpa, a, rec)) |name| _ = st.data.rules.map.swapRemove(name);

    var ids = state.Identities.init(gpa);
    defer ids.deinit();
    // A recorded output that changed outside the engine is refused unless
    // --rerun, except when it has a stored digest and its bytes still match:
    // then its identity is refreshed and it stays reusable.
    var changed: usize = 0;
    var first_changed: []const u8 = "";
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        const e = st.data.rules.map.getPtr(r.name) orelse continue;
        for (e.outputs, 0..) |o, k| {
            const now = (try ids.get(o.path)) orelse continue;
            if (std.mem.eql(u8, now, o.id)) continue;
            if (o.sha256) |want| {
                const d = try sys.sha256File(gpa, o.path);
                if (std.mem.eql(u8, want, &d)) {
                    const outs = try st.allocator().dupe(state.Output, e.outputs);
                    outs[k].id = try st.allocator().dupe(u8, now);
                    e.outputs = outs;
                    events.emit("output_identity_refreshed", .{ .rule = r.name, .path = o.path });
                    continue;
                }
            }
            changed += 1;
            if (first_changed.len == 0) first_changed = o.path;
            if (!opts.rerun) {
                std.debug.print("workz: output of completed rule {s} changed since it was recorded: {s}\n", .{ r.name, o.path });
                events.emit("output_changed", .{ .rule = r.name, .path = o.path });
            }
        }
    }
    if (changed > 0 and !opts.rerun) {
        std.debug.print("workz: refusing to reuse changed outputs; use --rerun to run the affected rules again (earlier bytes are kept in previous/)\n", .{});
        return refusal.refuse(.failed, try std.fmt.allocPrint(a, "{d} recorded outputs changed outside workz, first {s}; use --rerun", .{ changed, first_changed }));
    }

    // Input manifest: authoritative digests for external inputs.
    if (opts.input_manifest) |mpath| {
        const m = try checkManifest(gpa, &st, &ids, mpath);
        events.emit("inputs_checked", .{ .manifest = mpath, .files = m.files, .files_read = m.read, .bytes_read = m.bytes_read, .seconds = m.seconds, .ok = m.ok });
        if (!m.ok) return refusal.refuse(.failed, "inputs do not match the input manifest");
    }
    // Content digests valid for this launch: cutoff outputs and manifest inputs.
    var cut = try state.Cutoff.init(a, gpa, wf, &st, &ids, true);

    var journal = try records.Journal.open(gpa, rec);
    defer journal.close();

    var tree: ?cgroup.Tree = null;
    if (opts.isolation) {
        tree = cgroup.setup(gpa, a) catch
            return refusal.refuse(.invalid, "the run's cgroup is not delegated; start workz without WORKZ_STAGE set, or use --no-isolation");
    }

    var env_list: std.ArrayList([]const u8) = .empty;
    const env_text = try state.envText(a, environ, opts.pass_env);
    for (env_allow) |name| if (environ.get(name)) |v| {
        try env_list.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ name, v }));
    };
    for (opts.pass_env) |name| if (environ.get(name)) |v| {
        try env_list.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ name, v }));
    };

    const shared_info = try a.alloc(struct { name: []const u8, path: []const u8, bytes: u64 }, wf.shared.len);
    for (wf.shared, holders, 0..) |s, h, i| shared_info[i] = .{ .name = s.name, .path = s.path_abs, .bytes = h.bytes };

    const devnull = try sys.openRead(gpa, "/dev/null");
    defer sys.close(devnull);
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
        .records = rec,
        .launch_dir = launch.dir,
        .engine_id = state.engine_key_text,
        .env_text = env_text,
        .envp = try process.Vec.init(a, env_list.items),
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
        engine.network = Network.start(gpa, a, &engine.envp, devnull) catch |err|
            return refusal.refuse(.invalid, try std.fmt.allocPrint(a, "cannot create the run's network namespace: {s} ({s})", .{ @errorName(err), sys.errnoName() }));
    }
    defer if (engine.network) |n| n.stop();
    defer engine.pending_done.deinit(gpa);
    defer engine.leftover_cgroups.deinit(gpa);
    @memset(engine.group_used, 0);
    for (engine.tasks, 0..) |*t, i| {
        t.* = .{};
        if (!mask[i]) t.status = .excluded;
        t.max_attempts = 1 + (wf.rules[i].retries orelse opts.retry);
    }
    engine.last_save_ns = sys.monoNs();
    engine.next_sample_ns = engine.last_save_ns + sample_interval_ns;
    engine.last_sample_ns = engine.last_save_ns;
    if (engine.tree) |run_tree| engine.last_cpu_us = cgroup.cpuUsage(gpa, run_tree.root);
    const t0 = t_open;
    events.emit("launch_started", .{ .launch = launch.id, .selected = selected, .max_threads = max_threads, .max_memory_mib = max_memory, .jobs = max_jobs, .isolation = opts.isolation, .cgroup = if (tree) |t| t.root else null, .shared = shared_info, .checks_s = @as(f64, @floatFromInt(sys.monoNs() - t_open)) / 1e9 });

    engine.loop() catch |err| {
        engine.fatal = @errorName(err);
        engine.beginStop();
        // Wait for running tasks to end before writing the final records.
        while (engine.running() > 0) {
            var fds = [_]linux.pollfd{.{ .fd = sigfd, .events = linux.POLL.IN, .revents = 0 }};
            process.wait(&fds, engine.nextDeadline());
            _ = process.readSignals(sigfd);
            engine.reapAll() catch {};
            engine.checkTimers();
        }
    };

    // Inputs of finished rules must not have changed while the run went on.
    var post = state.Identities.init(gpa);
    defer post.deinit();
    var post_cut = try state.Cutoff.init(a, gpa, wf, engine.st, &post, false);
    for (wf.rules, 0..) |*r, i| {
        const t = &engine.tasks[i];
        if (t.status != .completed and t.status != .reused) continue;
        const k = t.key orelse continue;
        var names: std.ArrayList([]const u8) = .empty;
        var keys: std.ArrayList([]const u8) = .empty;
        for (g.parents[i]) |p| {
            try names.append(a, wf.rules[p].name);
            try keys.append(a, post_cut.parentKey(p, if (engine.tasks[p].key) |pk| pk.key else "none"));
        }
        var missing: ?[]const u8 = null;
        const again = try state.computeKey(a, &post, r, env_text, names.items, keys.items, state.engine_key_text, &post_cut, &missing);
        if (again == null or !std.mem.eql(u8, again.?.inputs, k.inputs)) {
            engine.fatal = try std.fmt.allocPrint(a, "inputs of rule {s} changed during the run", .{r.name});
            _ = engine.st.data.rules.map.swapRemove(r.name);
            engine.dirty = true;
        }
    }

    for (engine.tasks) |*t| if (t.status == .pending or t.status == .ready) {
        t.status = if (engine.interrupted) .cancelled else .not_started;
    };
    engine.dirty = true;
    try engine.saveState(true);
    try records.Journal.reset(gpa, rec);
    for (engine.leftover_cgroups.items) |cg| cgroup.remove(gpa, cg) catch {};

    var counts: [@typeInfo(Status).@"enum".fields.len]usize = @splat(0);
    for (engine.tasks) |t| counts[@intFromEnum(t.status)] += 1;
    const failed = counts[@intFromEnum(Status.failed)] + counts[@intFromEnum(Status.blocked)] + counts[@intFromEnum(Status.not_started)];
    const outcome: Outcome = if (engine.interrupted) .interrupted else if (failed > 0 or engine.fatal != null) .failed else .ok;
    const elapsed = @as(f64, @floatFromInt(sys.monoNs() - t0)) / 1e9;
    const summary = .{
        .engine = engine_id,
        .engine_key = state.engine_key,
        .launch = launch.id,
        .status = switch (outcome) {
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
        .engine_cost = engineCost(),
        .launch_dir = launch.dir,
    };
    events.emit("launch_finished", .{ .status = summary.status, .counts = summary.counts, .elapsed_s = elapsed, .@"error" = engine.fatal });
    try records.writeJson(gpa, try std.fs.path.join(a, &.{ launch.dir, "summary.json" }), summary);
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.print("{f}\n", .{std.json.fmt(summary, .{})});
    try sys.writeAll(1, w.written());
    return outcome;
}

pub const ManifestCheck = struct { ok: bool, files: usize = 0, read: usize = 0, bytes_read: u64 = 0, seconds: f64 = 0 };

/// Checks an input manifest: absolute paths to "sha256:<hex>", or to
/// {"sha256": "sha256:<hex>", "stamp": {dev, ino, size, mtime_ns, ctime_ns}}.
/// A file is read only when neither the cached identity nor the stamp equals
/// its current identity; a matching stamp is trusted as the identity the
/// manifest's writer hashed.
fn checkManifest(gpa: Allocator, st: *state.State, ids: *state.Identities, mpath: []const u8) !ManifestCheck {
    const t0 = sys.monoNs();
    var res: ManifestCheck = .{ .ok = true };
    const bytes = sys.readFile(gpa, mpath, 256 << 20) catch |err| {
        std.debug.print("workz: cannot read input manifest {s}: {s}\n", .{ mpath, @errorName(err) });
        return .{ .ok = false };
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch {
        std.debug.print("workz: input manifest {s} must be a JSON object of absolute paths\n", .{mpath});
        return .{ .ok = false };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        std.debug.print("workz: input manifest {s} must be a JSON object of absolute paths\n", .{mpath});
        return .{ .ok = false };
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
        const id_text = (try ids.get(path)) orelse {
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
    return field(stamp, "dev") == @as(i128, id.stDev()) and field(stamp, "ino") == @as(i128, id.ino) and
        field(stamp, "size") == @as(i128, id.size) and field(stamp, "mtime_ns") == id.mtime_ns and field(stamp, "ctime_ns") == id.ctime_ns;
}
