//! Command-line entry point.
const std = @import("std");
const linux = std.os.linux;
const workz = @import("workz");
const sys = workz.sys;
const workflow = workz.workflow;
const graph = workz.graph;
const run = workz.run;
const plan = workz.plan;
const state = workz.state;
const monitor = workz.monitor;
const report = workz.report;

const usage =
    \\usage: workz <command> [options]
    \\
    \\commands:
    \\  validate WORKFLOW        check the workflow file and graph
    \\  plan WORKFLOW            show which rules would run or be reused (alias: dry-run)
    \\  explain WORKFLOW RULE    show why a rule would run (plan and explain accept --pass-env)
    \\  graph WORKFLOW           print the selected graph in DOT form
    \\  run WORKFLOW             run the selected rules
    \\  watch [WORKFLOW]         live view of the newest launch
    \\  status [WORKFLOW]        summary of the newest launch
    \\  verify WORKFLOW          check recorded outputs (--content hashes them)
    \\  report [WORKFLOW]        what each attempt of a launch used (--bottlenecks: what limited it)
    \\  version                  print the engine version
    \\
    \\common options:
    \\  -d, --workdir DIR        working directory (default: the workflow's directory)
    \\  -t, --target RULE        select RULE and its dependencies (repeatable)
    \\
    \\run options:
    \\  -j, --jobs N             at most N tasks at once (default: --max-threads)
    \\  --max-threads N          CPU budget in threads (default: online CPUs)
    \\  --max-memory SIZE        memory budget, e.g. 60G (default: 3/4 of RAM)
    \\  -k, --keep-going         keep running independent rules after a failure
    \\  -r, --retry N            retry failed attempts up to N times (0-3)
    \\  --timeout DURATION       per-attempt time limit, e.g. 2h (rules may set their own)
    \\  --rerun                  run the selected rules even when reusable
    \\  --input-manifest FILE    JSON of absolute paths to "sha256:<hex>" to check
    \\  --pass-env NAME          pass an extra environment variable to rules
    \\  --grace SECONDS          wait before killing a stopped task (default 10)
    \\  --no-isolation           no network namespace and no cgroup limits
    \\  -q, --quiet              no progress lines on stderr
    \\
    \\report options:
    \\  --launch ID              a launch other than the newest
    \\  --format tsv|json        attempt table format (default tsv)
    \\  --bottlenecks            critical path, waiting, request sizing, utilization
    \\
    \\watch options:
    \\  --once                   print one view and exit
    \\  --interval MS            refresh interval (default 1000)
    \\
;

const Exit = enum(u8) { ok = 0, failed = 1, usage = 2, interrupted = 130, _ };

fn fail(comptime fmt: []const u8, args: anytype) Exit {
    std.debug.print("workz: " ++ fmt ++ "\n", args);
    return .usage;
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    argv: []const [:0]const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return @intFromEnum(Exit.usage);
    }
    // Debug builds keep the leak-checking allocator; shipped builds use the
    // caching SMP allocator, which avoids a map and unmap per allocation.
    const gpa = if (@import("builtin").mode == .Debug) init.gpa else std.heap.smp_allocator;
    const ctx: Ctx = .{ .gpa = gpa, .a = a, .io = init.io, .env = init.environ_map, .argv = args };
    const cmd = args[1];
    const rest = args[2..];
    const eq = std.mem.eql;
    const code: Exit = if (eq(u8, cmd, "version") or eq(u8, cmd, "--version")) blk: {
        try out(init.io, "workz {s}\n", .{workz.version});
        break :blk .ok;
    } else if (eq(u8, cmd, "help") or eq(u8, cmd, "--help") or eq(u8, cmd, "-h")) blk: {
        try out(init.io, "{s}", .{usage});
        break :blk .ok;
    } else if (eq(u8, cmd, "validate")) try cmdValidate(ctx, rest, false) else if (eq(u8, cmd, "graph")) try cmdValidate(ctx, rest, true) else if (eq(u8, cmd, "plan") or eq(u8, cmd, "dry-run")) try cmdPlan(ctx, rest, null) else if (eq(u8, cmd, "explain")) try cmdExplain(ctx, rest) else if (eq(u8, cmd, "verify")) try cmdVerify(ctx, rest) else if (eq(u8, cmd, "run")) try cmdRun(ctx, rest) else if (eq(u8, cmd, "watch")) try cmdWatch(ctx, rest, false) else if (eq(u8, cmd, "status")) try cmdWatch(ctx, rest, true) else if (eq(u8, cmd, "report")) try cmdReport(ctx, rest) else if (eq(u8, cmd, "__hold")) hold(rest) else fail("unknown command '{s}'; run 'workz help'", .{cmd});
    return @intFromEnum(code);
}

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

const Common = struct {
    workflow: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    targets: std.ArrayList([]const u8) = .empty,
    positional: std.ArrayList([]const u8) = .empty,
};

/// Parses common options; `extra` handles command-specific options and
/// returns how many arguments it consumed (0 when not its option).
fn parseArgs(a: std.mem.Allocator, args: []const [:0]const u8, c: *Common, extra: anytype) !?Exit {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--workdir")) {
            c.workdir = value orelse return fail("{s} needs a value", .{arg});
            i += 1;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--target")) {
            try c.targets.append(a, value orelse return fail("{s} needs a value", .{arg}));
            i += 1;
        } else if (arg.len > 1 and arg[0] == '-') {
            const used = try extra.option(arg, value);
            if (used == 0) return fail("unknown option '{s}'", .{arg});
            if (used == std.math.maxInt(usize)) return .usage;
            i += used - 1;
        } else if (c.workflow == null) {
            c.workflow = arg;
        } else try c.positional.append(a, arg);
    }
    return null;
}

const NoExtra = struct {
    fn option(_: NoExtra, _: []const u8, _: ?[]const u8) !usize {
        return 0;
    }
};

const Loaded = struct {
    wf: workflow.Workflow,
    g: graph.Graph,
    mask: []bool,

    fn deinit(self: *Loaded) void {
        self.g.deinit();
        self.wf.deinit();
    }
};

fn rootOf(c: Ctx, common: *const Common) !?[]const u8 {
    const here = try sys.cwd(c.a);
    const given = if (common.workdir) |d| try sys.absolute(c.a, here, d) else if (common.workflow) |w| std.fs.path.dirname(try sys.absolute(c.a, here, w)) orelse "/" else here;
    return (try sys.realpath(c.a, given)) orelse {
        std.debug.print("workz: working directory does not exist: {s}\n", .{given});
        return null;
    };
}

/// Loads, checks and selects; prints the reason and returns null when invalid.
fn load(c: Ctx, common: *const Common) !?Loaded {
    const wpath = common.workflow orelse {
        std.debug.print("workz: missing workflow file\n", .{});
        return null;
    };
    const root = (try rootOf(c, common)) orelse return null;
    const wf_abs = try sys.absolute(c.a, try sys.cwd(c.a), wpath);
    var problem: workflow.Problem = .{};
    var wf = workflow.load(c.gpa, wf_abs, root, &problem) catch |err| switch (err) {
        error.Invalid => {
            std.debug.print("workz: {s}: {s}\n", .{ wpath, problem.message });
            c.gpa.free(problem.message);
            return null;
        },
        else => return err,
    };
    errdefer wf.deinit();
    var g = graph.build(c.gpa, &wf, &problem) catch |err| switch (err) {
        error.Cycle => {
            std.debug.print("workz: {s}: {s}\n", .{ wpath, problem.message });
            c.gpa.free(problem.message);
            wf.deinit();
            return null;
        },
        else => return err,
    };
    errdefer g.deinit();
    var unknown: ?[]const u8 = null;
    const mask = graph.select(c.a, &wf, &g, common.targets.items, &unknown) catch |err| switch (err) {
        error.UnknownTarget => {
            std.debug.print("workz: unknown target '{s}'\n", .{unknown.?});
            g.deinit();
            wf.deinit();
            return null;
        },
        else => return err,
    };
    return .{ .wf = wf, .g = g, .mask = mask };
}

fn cmdValidate(c: Ctx, args: []const [:0]const u8, dot: bool) !Exit {
    var common: Common = .{};
    if (try parseArgs(c.a, args, &common, NoExtra{})) |e| return e;
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    if (dot) {
        var buf: [8192]u8 = undefined;
        var w = std.Io.File.stdout().writer(c.io, &buf);
        try graph.writeDot(&w.interface, &l.wf, &l.g, l.mask);
        try w.interface.flush();
        return .ok;
    }
    var selected: usize = 0;
    for (l.mask) |m| selected += @intFromBool(m);
    try out(c.io, "valid: {s} ({d} rules, {d} selected, {d} groups, {d} shared)\n", .{ l.wf.name, l.wf.rules.len, selected, l.wf.groups.len, l.wf.shared.len });
    return .ok;
}

const PlanExtra = struct {
    rerun: *bool,
    pass: *std.ArrayList([]const u8),
    a: std.mem.Allocator,
    fn option(self: PlanExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--rerun")) {
            self.rerun.* = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--pass-env")) {
            try self.pass.append(self.a, value orelse return badValue(arg));
            return 2;
        }
        return 0;
    }
};

fn planContext(c: Ctx, l: *Loaded, st: *state.State, ids: *state.Identities, pass: []const []const u8) !plan.Context {
    return plan.Context.init(c.gpa, c.a, &l.wf, &l.g, st, ids, try state.envText(c.a, c.env, pass));
}

fn cmdPlan(c: Ctx, args: []const [:0]const u8, _: ?void) !Exit {
    var common: Common = .{};
    var rerun = false;
    var pass: std.ArrayList([]const u8) = .empty;
    if (try parseArgs(c.a, args, &common, PlanExtra{ .rerun = &rerun, .pass = &pass, .a = c.a })) |e| return e;
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    var st = try plan.loadState(c.gpa, l.wf.root, c.a);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var ctx = try planContext(c, &l, &st, &ids, pass.items);
    ctx.rerun = rerun;
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writer(c.io, &buf);
    try plan.printPlan(&w.interface, &ctx, l.mask);
    try w.interface.flush();
    return .ok;
}

fn cmdExplain(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var rerun = false;
    var pass: std.ArrayList([]const u8) = .empty;
    if (try parseArgs(c.a, args, &common, PlanExtra{ .rerun = &rerun, .pass = &pass, .a = c.a })) |e| return e;
    if (common.positional.items.len != 1) return fail("explain needs a workflow file and one rule name", .{});
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    var st = try plan.loadState(c.gpa, l.wf.root, c.a);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var ctx = try planContext(c, &l, &st, &ids, pass.items);
    ctx.rerun = rerun;
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writer(c.io, &buf);
    const found = try plan.explain(&w.interface, &ctx, l.mask, common.positional.items[0]);
    try w.interface.flush();
    if (!found) return fail("unknown rule '{s}'", .{common.positional.items[0]});
    return .ok;
}

const VerifyExtra = struct {
    content: *bool,
    fn option(self: VerifyExtra, arg: []const u8, _: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--content")) {
            self.content.* = true;
            return 1;
        }
        return 0;
    }
};

fn cmdVerify(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var content = false;
    if (try parseArgs(c.a, args, &common, VerifyExtra{ .content = &content })) |e| return e;
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    const rec = try workz.records.recordsDir(c.a, l.wf.root);
    try sys.mkdirAll(c.gpa, rec);
    const lock = workz.records.lock(c.gpa, rec) catch |err| switch (err) {
        error.Busy => return fail("a run is active in {s}", .{l.wf.root}),
        else => return err,
    };
    defer sys.close(lock);
    var st = try plan.loadState(c.gpa, l.wf.root, c.a);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writer(c.io, &buf);
    const ok = try plan.verify(&w.interface, c.gpa, &st, &ids, &l.wf, l.mask, content);
    try w.interface.flush();
    return if (ok) .ok else .failed;
}

const WatchExtra = struct {
    once: *bool,
    interval: *u64,
    fn option(self: WatchExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--once")) {
            self.once.* = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--interval")) {
            const v = value orelse return badValue(arg);
            self.interval.* = std.fmt.parseInt(u64, v, 10) catch return badValue(arg);
            return 2;
        }
        return 0;
    }
};

fn badValue(arg: []const u8) usize {
    std.debug.print("workz: {s} needs a valid value\n", .{arg});
    return std.math.maxInt(usize);
}

fn cmdWatch(c: Ctx, args: []const [:0]const u8, summary: bool) !Exit {
    var common: Common = .{};
    var once = summary;
    var interval: u64 = 1000;
    if (try parseArgs(c.a, args, &common, WatchExtra{ .once = &once, .interval = &interval })) |e| return e;
    const root = (try rootOf(c, &common)) orelse return .usage;
    const ok = if (summary) try monitor.status(c.gpa, c.io, root) else try monitor.watch(c.gpa, c.io, root, once, @max(interval, 100));
    return if (ok) .ok else .failed;
}

const ReportExtra = struct {
    launch: *?[]const u8,
    json: *bool,
    bottlenecks: *bool,
    fn option(self: ReportExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--bottlenecks")) {
            self.bottlenecks.* = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--launch")) {
            self.launch.* = value orelse return badValue(arg);
            return 2;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            const v = value orelse return badValue(arg);
            if (std.mem.eql(u8, v, "json")) self.json.* = true else if (!std.mem.eql(u8, v, "tsv")) return badValue(arg);
            return 2;
        }
        return 0;
    }
};

fn cmdReport(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var launch: ?[]const u8 = null;
    var json = false;
    var bottlenecks = false;
    if (try parseArgs(c.a, args, &common, ReportExtra{ .launch = &launch, .json = &json, .bottlenecks = &bottlenecks })) |e| return e;
    const root = (try rootOf(c, &common)) orelse return .usage;
    const rec = try workz.records.recordsDir(c.a, root);
    const dir = if (launch) |id| try std.fs.path.join(c.a, &.{ rec, "launches", id }) else (try workz.records.latestLaunch(c.gpa, c.a, rec)) orelse return fail("no launch recorded in {s}", .{rec});
    if (!sys.exists(c.gpa, dir)) return fail("no launch {s}", .{dir});
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writer(c.io, &buf);
    if (bottlenecks) {
        try report.writeBottlenecks(c.gpa, c.a, &w.interface, dir);
    } else {
        const rows = try report.attempts(c.gpa, c.a, dir);
        if (json) try report.writeJson(&w.interface, rows) else try report.writeTsv(&w.interface, rows);
    }
    try w.interface.flush();
    return .ok;
}

const RunExtra = struct {
    opts: *run.Options,
    pass: *std.ArrayList([]const u8),
    a: std.mem.Allocator,

    fn option(self: RunExtra, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        const o = self.opts;
        if (eq(u8, arg, "-k") or eq(u8, arg, "--keep-going")) {
            o.keep_going = true;
            return 1;
        }
        if (eq(u8, arg, "--rerun")) {
            o.rerun = true;
            return 1;
        }
        if (eq(u8, arg, "--no-isolation")) {
            o.isolation = false;
            return 1;
        }
        if (eq(u8, arg, "-q") or eq(u8, arg, "--quiet")) {
            o.quiet = true;
            return 1;
        }
        // Accepted for compatibility with oxo-local command lines.
        if (eq(u8, arg, "--resume-failed") or eq(u8, arg, "--provenance") or eq(u8, arg, "--json") or eq(u8, arg, "--no-color")) return 1;
        const v = value orelse return 0;
        if (eq(u8, arg, "-j") or eq(u8, arg, "--jobs")) {
            o.jobs = std.fmt.parseInt(u32, v, 10) catch return badValue(arg);
            if (o.jobs.? == 0) return badValue(arg);
        } else if (eq(u8, arg, "--max-threads")) {
            o.max_threads = std.fmt.parseInt(u32, v, 10) catch return badValue(arg);
            if (o.max_threads.? == 0) return badValue(arg);
        } else if (eq(u8, arg, "--max-memory")) {
            o.max_memory_mib = workflow.parseMemoryMib(v) orelse return badValue(arg);
        } else if (eq(u8, arg, "-r") or eq(u8, arg, "--retry")) {
            o.retry = std.fmt.parseInt(u32, v, 10) catch return badValue(arg);
            if (o.retry > 3) return badValue(arg);
        } else if (eq(u8, arg, "--timeout")) {
            o.timeout_s = workflow.parseDuration(v) orelse return badValue(arg);
        } else if (eq(u8, arg, "--grace")) {
            o.grace_s = std.fmt.parseInt(u64, v, 10) catch return badValue(arg);
        } else if (eq(u8, arg, "--input-manifest")) {
            o.input_manifest = v;
        } else if (eq(u8, arg, "--pass-env")) {
            try self.pass.append(self.a, v);
        } else return 0;
        return 2;
    }
};

fn cmdRun(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var opts: run.Options = .{};
    var pass: std.ArrayList([]const u8) = .empty;
    if (try parseArgs(c.a, args, &common, RunExtra{ .opts = &opts, .pass = &pass, .a = c.a })) |e| return e;
    opts.pass_env = pass.items;
    if (opts.input_manifest) |m| opts.input_manifest = try sys.absolute(c.a, try sys.cwd(c.a), m);
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    const inner = if (c.env.get("WORKZ_STAGE")) |s| std.mem.eql(u8, s, "inner") else false;
    if (opts.isolation and !inner) return isolate(c, &l, opts);
    const outcome = try run.execute(c.gpa, c.a, &l.wf, &l.g, l.mask, opts, c.env);
    return switch (outcome) {
        .ok => .ok,
        .failed => .failed,
        .invalid => .usage,
        .interrupted => .interrupted,
    };
}

fn findProgram(c: Ctx, name: []const u8) !?[]const u8 {
    const path = c.env.get("PATH") orelse "/usr/bin:/bin";
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const p = try std.fs.path.join(c.a, &.{ dir, name });
        if (try sys.stat(c.gpa, p)) |id| if (id.isReg()) return p;
    }
    return null;
}

/// Re-executes the run inside a delegated systemd user scope (cgroup limits
/// for the whole run, swap off) and a bubblewrap network namespace. Interrupt
/// signals are ignored by the launchers and handled by the engine itself.
fn isolate(c: Ctx, l: *Loaded, opts: run.Options) !Exit {
    const systemd_run = (try findProgram(c, "systemd-run")) orelse return fail("systemd-run not found; isolation needs a systemd user manager (or use --no-isolation)", .{});
    const bwrap = (try findProgram(c, "bwrap")) orelse return fail("bwrap not found; isolation needs bubblewrap (or use --no-isolation)", .{});
    const threads = opts.max_threads orelse run.defaultThreads();
    var memory = opts.max_memory_mib orelse run.defaultMemoryMib(c.gpa);
    var shared_mib: u64 = 0;
    for (l.wf.shared) |s| shared_mib += std.math.divCeil(u64, state.pageBytes(c.gpa, s.path_abs) catch 0, 1 << 20) catch 0;
    // The engine and its launchers need a little memory beside the tasks.
    memory += 256;
    const exe = try sys.selfExe(c.a);
    const here = try sys.cwd(c.a);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{
        systemd_run,       "--user",       "--scope",                                                                "--quiet",                                                "--expand-environment=no",
        "-p",              "Delegate=yes", "-p",                                                                     try std.fmt.allocPrint(c.a, "MemoryMax={d}M", .{memory}), "-p",
        "MemorySwapMax=0", "-p",           try std.fmt.allocPrint(c.a, "CPUQuota={d}%", .{@as(u64, threads) * 100}), "-p",                                                     try std.fmt.allocPrint(c.a, "MemoryLow={d}M", .{shared_mib}),
        "--",              bwrap,          "--unshare-net",                                                          "--die-with-parent",                                      "--dev-bind",
        "/",               "/",            "--proc",                                                                 "/proc",                                                  "--chdir",
        here,              "--",           exe,
    });
    for (c.argv[1..]) |arg| try argv.append(c.a, arg);
    var env: std.ArrayList([]const u8) = .empty;
    var it = c.env.iterator();
    while (it.next()) |e| try env.append(c.a, try std.fmt.allocPrint(c.a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
    try env.append(c.a, "WORKZ_STAGE=inner");
    const argv_z = try workz.process.Vec.init(c.a, argv.items);
    const env_z = try workz.process.Vec.init(c.a, env.items);
    const path_z = try c.a.dupeZ(u8, systemd_run);
    const pid_file = try std.fs.path.join(c.a, &.{ l.wf.root, ".workz", "engine.pid" });

    // The launchers ignore interrupt signals; this process stays as a
    // supervisor that forwards them to the engine and returns its status.
    var set = linux.sigemptyset();
    for ([_]linux.SIG{ .INT, .TERM, .HUP, .CHLD }) |s| linux.sigaddset(&set, s);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &set, null);
    const sigfd: i32 = @intCast(try sys.check(linux.signalfd(-1, &set, linux.SFD.CLOEXEC)));
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return fail("cannot start systemd-run: {s}", .{@tagName(linux.errno(rc))});
    if (rc == 0) {
        var ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
        for ([_]linux.SIG{ .INT, .TERM, .HUP }) |s| _ = linux.sigaction(s, &ign, null);
        const empty = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
        _ = linux.execve(path_z, argv_z.items.ptr, env_z.items.ptr);
        linux.exit_group(127);
    }
    const child: linux.pid_t = @intCast(rc);
    while (true) {
        var info: linux.signalfd_siginfo = undefined;
        const n = linux.read(sigfd, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
        if (linux.errno(n) != .SUCCESS) continue;
        const sig: linux.SIG = @enumFromInt(info.signo);
        if (sig == .CHLD) {
            var status: u32 = 0;
            const w = linux.wait4(child, &status, linux.W.NOHANG, null);
            if (linux.errno(w) != .SUCCESS or w == 0) continue;
            if (linux.W.IFEXITED(status)) return @enumFromInt(linux.W.EXITSTATUS(status));
            return .failed;
        }
        const text = sys.readFile(c.gpa, pid_file, 64) catch continue;
        defer c.gpa.free(text);
        const pid = std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, text, " \n"), 10) catch continue;
        // Forward only to a running workz engine, never to a reused process id.
        var link: [64]u8 = undefined;
        const proc = std.fmt.bufPrintZ(&link, "/proc/{d}/exe", .{pid}) catch continue;
        var target: [4096]u8 = undefined;
        const len = linux.readlinkat(linux.AT.FDCWD, proc, &target, target.len);
        if (linux.errno(len) != .SUCCESS or !std.mem.eql(u8, target[0..len], exe)) continue;
        _ = linux.kill(pid, sig);
    }
}

/// Internal: maps every file read-only, touches each page so the run's
/// holder group carries the page-cache charge, reports "ready" on stdout
/// and keeps the mappings until it is stopped.
fn hold(paths: []const [:0]const u8) Exit {
    var total: u64 = 0;
    for (paths) |p| {
        const fd_rc = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return fail("cannot open shared input {s}", .{p});
        const fd: i32 = @intCast(fd_rc);
        var s: linux.Statx = undefined;
        _ = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &s);
        if (s.size == 0) continue;
        const len: usize = @intCast(s.size);
        const m = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(m) != .SUCCESS) return fail("cannot map shared input {s}", .{p});
        const bytes: [*]const volatile u8 = @ptrFromInt(m);
        var sum: u8 = 0;
        var off: usize = 0;
        while (off < len) : (off += 4096) sum +%= bytes[off];
        std.mem.doNotOptimizeAway(sum);
        total += s.size;
    }
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "ready {d}\n", .{total}) catch unreachable;
    _ = linux.write(1, line.ptr, line.len);
    while (true) _ = linux.pause();
}
