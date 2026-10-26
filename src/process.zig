//! Child processes: signals, fork and exec into a process group and cgroup,
//! non-blocking reaping with resource usage, and group termination.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

const handled = [_]linux.SIG{ .INT, .TERM, .HUP, .CHLD };

fn defaultAction(sig: linux.SIG) void {
    var act: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(sig, &act, null);
}

/// Blocks the signals the engine handles and returns a signalfd that reports
/// them. Ignored dispositions inherited from a launcher are reset first, since
/// an ignored signal is discarded even while blocked. The engine also becomes
/// a subreaper, so descendants that leave their task are reaped here.
pub fn setupSignals() !sys.Fd {
    for (handled) |s| defaultAction(s);
    var set = linux.sigemptyset();
    for (handled) |s| linux.sigaddset(&set, s);
    _ = try sys.check(linux.sigprocmask(linux.SIG.BLOCK, &set, null));
    const fd = try sys.check(linux.signalfd(-1, &set, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK));
    _ = try sys.check(linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0));
    return @intCast(fd);
}

/// Drains pending signals; returns a bit per signal number seen.
pub fn readSignals(fd: sys.Fd) u64 {
    var seen: u64 = 0;
    var info: linux.signalfd_siginfo = undefined;
    while (true) {
        const n = linux.read(fd, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
        if (linux.errno(n) != .SUCCESS or n != @sizeOf(linux.signalfd_siginfo)) break;
        if (info.signo < 64) seen |= @as(u64, 1) << @intCast(info.signo);
    }
    return seen;
}

pub fn has(seen: u64, sig: linux.SIG) bool {
    return seen & (@as(u64, 1) << @intCast(@intFromEnum(sig))) != 0;
}

pub const Spec = struct {
    /// Executable path and argument vector, prepared before fork.
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: [*:0]const u8,
    stdin: sys.Fd,
    stdout: sys.Fd,
    stderr: sys.Fd,
    /// Open `cgroup.procs` of the task's cgroup, or -1.
    cgroup_procs: sys.Fd = -1,
    /// Run the child in a new process group led by itself.
    new_group: bool = true,
    /// User and network namespaces to join before exec, or -1.
    userns: sys.Fd = -1,
    netns: sys.Fd = -1,
};

/// Starts a child. The child joins its process group and cgroup, restores
/// default signal handling and an empty signal mask, and execs. An exec
/// failure is reported through a close-on-exec pipe as error.ExecFailed.
pub fn spawn(spec: *const Spec) !linux.pid_t {
    var pipe: [2]i32 = undefined;
    _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
    defer sys.close(pipe[0]);

    // The child shares the engine's memory until it execs (CLONE_VM with
    // CLONE_VFORK, as posix_spawn does), so starting a task does not copy the
    // engine's page tables. It runs on its own stack and makes only system calls.
    var arg: ChildArg = .{ .spec = spec, .err_pipe = pipe[1] };
    const flags: u32 = linux.CLONE.VM | linux.CLONE.VFORK | @intFromEnum(linux.SIG.CHLD);
    const rc = linux.clone(childEntry, @intFromPtr(&child_stack) + child_stack.len, flags, @intFromPtr(&arg), null, 0, null);
    if (linux.errno(rc) != .SUCCESS) {
        sys.close(pipe[1]);
        _ = try sys.check(rc);
        unreachable;
    }
    sys.close(pipe[1]);
    const pid: linux.pid_t = @intCast(rc);
    var code: u32 = 0;
    const n = sys.read(pipe[0], std.mem.asBytes(&code)) catch 0;
    if (n == @sizeOf(u32)) {
        var status: u32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
        sys.last_errno = @enumFromInt(code);
        return error.ExecFailed;
    }
    return pid;
}

const ChildArg = struct { spec: *const Spec, err_pipe: i32 };

/// Stack for the child between clone and exec. The engine starts one child
/// at a time and waits for its exec, so one stack suffices.
var child_stack: [64 * 1024]u8 align(16) = undefined;

fn childEntry(arg: usize) callconv(.c) u8 {
    const a: *const ChildArg = @ptrFromInt(arg);
    child(a.spec, a.err_pipe);
}

fn child(spec: *const Spec, err_pipe: i32) noreturn {
    if (spec.new_group) _ = linux.setpgid(0, 0);
    if (spec.cgroup_procs >= 0) step(err_pipe, linux.write(spec.cgroup_procs, "0", 1));
    if (spec.userns >= 0) step(err_pipe, linux.setns(spec.userns, linux.CLONE.NEWUSER));
    if (spec.netns >= 0) step(err_pipe, linux.setns(spec.netns, linux.CLONE.NEWNET));
    for ([_]linux.SIG{ .INT, .TERM, .HUP, .CHLD, .PIPE, .QUIT, .TSTP, .TTIN, .TTOU }) |s| defaultAction(s);
    const empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
    step(err_pipe, linux.chdir(spec.cwd));
    step(err_pipe, linux.dup2(spec.stdin, 0));
    step(err_pipe, linux.dup2(spec.stdout, 1));
    step(err_pipe, linux.dup2(spec.stderr, 2));
    step(err_pipe, linux.execve(spec.path, spec.argv, spec.envp));
    linux.exit_group(127);
}

/// In the child: on a failed call, sends its errno to the parent and exits.
fn step(err_pipe: i32, rc: usize) void {
    const e = linux.errno(rc);
    if (e == .SUCCESS) return;
    const code: u32 = @intFromEnum(e);
    _ = linux.write(err_pipe, std.mem.asBytes(&code), @sizeOf(u32));
    linux.exit_group(127);
}

pub const Reaped = struct {
    pid: linux.pid_t,
    status: u32,
    usage: linux.rusage,

    pub fn exitCode(self: Reaped) ?u8 {
        return if (linux.W.IFEXITED(self.status)) linux.W.EXITSTATUS(self.status) else null;
    }
    pub fn signal(self: Reaped) ?u32 {
        return if (linux.W.IFSIGNALED(self.status)) @intFromEnum(linux.W.TERMSIG(self.status)) else null;
    }
    pub fn cpuSeconds(self: Reaped) f64 {
        const u = self.usage.utime;
        const s = self.usage.stime;
        return @as(f64, @floatFromInt(u.sec + s.sec)) + @as(f64, @floatFromInt(u.usec + s.usec)) / 1e6;
    }
};

/// Reaps one exited child without blocking; null when none is waiting.
pub fn reap() ?Reaped {
    var status: u32 = 0;
    var usage: linux.rusage = undefined;
    const rc = linux.wait4(-1, &status, linux.W.NOHANG, &usage);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
    return .{ .pid = @intCast(rc), .status = status, .usage = usage };
}

pub fn signalGroup(pgid: linux.pid_t, sig: linux.SIG) void {
    _ = linux.kill(-pgid, sig);
}

pub fn signalPid(pid: linux.pid_t, sig: linux.SIG) void {
    _ = linux.kill(pid, sig);
}

/// Waits for readable signals or file descriptors until `deadline_ns`
/// (monotonic), or indefinitely when null.
pub fn wait(fds: []linux.pollfd, deadline_ns: ?i128) void {
    var ts: linux.timespec = undefined;
    var tsp: ?*linux.timespec = null;
    if (deadline_ns) |d| {
        const left = @max(d - sys.monoNs(), 0);
        ts = .{ .sec = @intCast(@divFloor(left, std.time.ns_per_s)), .nsec = @intCast(@mod(left, std.time.ns_per_s)) };
        tsp = &ts;
    }
    _ = linux.ppoll(fds.ptr, fds.len, tsp, null);
}

/// A null-terminated argument or environment vector built before fork.
pub const Vec = struct {
    items: [:null]?[*:0]const u8,

    pub fn init(a: Allocator, strings: []const []const u8) !Vec {
        const items = try a.allocSentinel(?[*:0]const u8, strings.len, null);
        for (strings, 0..) |s, i| items[i] = (try a.dupeZ(u8, s)).ptr;
        return .{ .items = items };
    }
};

/// The executable `name` on PATH, or null.
pub fn findProgram(gpa: Allocator, a: Allocator, path_env: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const p = try std.fs.path.join(a, &.{ dir, name });
        if (try sys.stat(gpa, p)) |id| if (id.isReg()) return p;
    }
    return null;
}

/// Runs a short command and returns its standard output; error.CommandFailed
/// with `status` set when it does not exit 0.
pub fn capture(gpa: Allocator, a: Allocator, argv: []const []const u8, envp: *const Vec, devnull: sys.Fd, status: *u32) ![]u8 {
    var pipe: [2]i32 = undefined;
    _ = try sys.check(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
    defer sys.close(pipe[0]);
    const v = try Vec.init(a, argv);
    const spec: Spec = .{ .path = (try a.dupeZ(u8, argv[0])).ptr, .argv = v.items.ptr, .envp = envp.items.ptr, .cwd = "/", .stdin = devnull, .stdout = pipe[1], .stderr = devnull, .new_group = false };
    const pid = spawn(&spec) catch |err| {
        sys.close(pipe[1]);
        return err;
    };
    sys.close(pipe[1]);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(pipe[0], &buf) catch break;
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    status.* = 0;
    while (true) {
        const rc = linux.wait4(pid, status, 0, null);
        if (linux.errno(rc) == .INTR) continue;
        break;
    }
    _ = gpa;
    if (!linux.W.IFEXITED(status.*) or linux.W.EXITSTATUS(status.*) != 0) return error.CommandFailed;
    return out.items;
}
