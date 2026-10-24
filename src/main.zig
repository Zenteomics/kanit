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
    \\  plan WORKFLOW            show which rules would run or be reused (alias: dry-run;
    \\                           --summary: counts by reason)
    \\  explain WORKFLOW RULE    show why a rule would run (plan and explain accept --pass-env)
    \\  graph WORKFLOW           print the selected graph in DOT form
    \\  run WORKFLOW             run the selected rules
    \\  watch [WORKFLOW]         live view of the newest launch
    \\  status [WORKFLOW]        summary of the newest launch
    \\  verify WORKFLOW          check recorded outputs (--content hashes them)
    \\  report [WORKFLOW]        what each attempt of a launch used (--bottlenecks: what limited it)
    \\  logs [WORKFLOW] RULE     standard output and error of a rule's newest attempt
    \\  clean [WORKFLOW]         remove leftover containers (--keep N: and all but the newest N launches)
    \\  init [FILE]              write a commented starter workflow (default workflow.toml)
    \\  completion bash          print a bash completion script
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
    \\  --rerun-rule RULE        run RULE even when reusable; its consumers follow (repeatable;
    \\                           plan and explain accept it too)
    \\  --input-manifest FILE    JSON of absolute paths to "sha256:<hex>" to check
    \\  --pass-env NAME          pass an extra environment variable to rules
    \\  --grace SECONDS          wait before killing a stopped task (default 10)
    \\  --slice NAME             place the run's scope in this systemd slice (NAME.slice)
    \\  --no-isolation           no network namespace and no cgroup limits
    \\  -q, --quiet              no progress lines on stderr; failures still print
    \\
    \\report options:
    \\  --launch ID              a launch other than the newest
    \\  --format tsv|json|html   attempt table, or a self-contained HTML page (default tsv)
    \\  --bottlenecks            critical path, waiting, request sizing, utilization
    \\
    \\logs options:
    \\  --launch ID, --attempt N an earlier launch or attempt
    \\  --stdout, --stderr       one stream only (default both)
    \\  -f, --follow             keep printing until the attempt ends
    \\
    \\clean options:
    \\  --keep N                 keep the newest N launches and those holding a recorded attempt
    \\  --dry-run                show what would be removed
    \\
    \\status options:
    \\  --history [N]            one line for each of the last N launches (default 10)
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
    } else if (eq(u8, cmd, "validate")) try cmdValidate(ctx, rest, false) else if (eq(u8, cmd, "graph")) try cmdValidate(ctx, rest, true) else if (eq(u8, cmd, "plan") or eq(u8, cmd, "dry-run")) try cmdPlan(ctx, rest, null) else if (eq(u8, cmd, "explain")) try cmdExplain(ctx, rest) else if (eq(u8, cmd, "verify")) try cmdVerify(ctx, rest) else if (eq(u8, cmd, "run")) try cmdRun(ctx, rest) else if (eq(u8, cmd, "watch")) try cmdWatch(ctx, rest, false) else if (eq(u8, cmd, "status")) try cmdWatch(ctx, rest, true) else if (eq(u8, cmd, "report")) try cmdReport(ctx, rest) else if (eq(u8, cmd, "clean")) try cmdClean(ctx, rest) else if (eq(u8, cmd, "logs")) try cmdLogs(ctx, rest) else if (eq(u8, cmd, "init")) try cmdInit(ctx, rest) else if (eq(u8, cmd, "completion")) try cmdCompletion(ctx, rest) else if (eq(u8, cmd, "__rules")) try cmdRules(ctx, rest) else if (eq(u8, cmd, "__hold")) hold(rest) else if (eq(u8, cmd, "__netns")) netns(rest) else if (eq(u8, cmd, "__guard")) guard() else fail("unknown command '{s}'; run 'workz help'", .{cmd});
    return @intFromEnum(code);
}

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
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

/// Shows the source line of a rejected workflow on stderr.
fn showSnippet(c: Ctx, path: []const u8, problem: workflow.Problem) void {
    if (problem.line == 0) return;
    const source = sys.readFile(c.gpa, path, 64 << 20) catch return;
    defer c.gpa.free(source);
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(c.io, &buf);
    workflow.snippet(&w.interface, source, problem.line, problem.col) catch return;
    w.interface.flush() catch {};
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
            showSnippet(c, wf_abs, problem);
            c.gpa.free(problem.message);
            return null;
        },
        else => return err,
    };
    errdefer wf.deinit();
    var g = graph.build(c.gpa, &wf, &problem) catch |err| switch (err) {
        error.Cycle, error.Invalid => {
            std.debug.print("workz: {s}: {s}\n", .{ wpath, problem.message });
            showSnippet(c, wf_abs, problem);
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
        var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
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
    summary: ?*bool = null,
    pass: *std.ArrayList([]const u8),
    reruns: *std.ArrayList([]const u8),
    a: std.mem.Allocator,
    fn option(self: PlanExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--rerun-rule")) {
            try self.reruns.append(self.a, value orelse return badValue(arg));
            return 2;
        }
        if (self.summary) |s| if (std.mem.eql(u8, arg, "--summary")) {
            s.* = true;
            return 1;
        };
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
    return plan.Context.init(c.gpa, c.a, &l.wf, &l.g, st, ids, try state.envText(c.a, c.env, pass), c.env);
}

fn cmdPlan(c: Ctx, args: []const [:0]const u8, _: ?void) !Exit {
    var common: Common = .{};
    var rerun = false;
    var pass: std.ArrayList([]const u8) = .empty;
    var reruns: std.ArrayList([]const u8) = .empty;
    var summary = false;
    if (try parseArgs(c.a, args, &common, PlanExtra{ .rerun = &rerun, .summary = &summary, .pass = &pass, .reruns = &reruns, .a = c.a })) |e| return e;
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    var st = try plan.loadState(c.gpa, l.wf.root, c.a);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var ctx = try planContext(c, &l, &st, &ids, pass.items);
    ctx.rerun = rerun;
    ctx.rerun_rules = reruns.items;
    if (!try knownRules(&l.wf, reruns.items)) return .usage;
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    if (summary) try plan.printSummary(&w.interface, &ctx, l.mask) else try plan.printPlan(&w.interface, &ctx, l.mask);
    try w.interface.flush();
    return .ok;
}

fn cmdExplain(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var rerun = false;
    var pass: std.ArrayList([]const u8) = .empty;
    var reruns: std.ArrayList([]const u8) = .empty;
    if (try parseArgs(c.a, args, &common, PlanExtra{ .rerun = &rerun, .pass = &pass, .reruns = &reruns, .a = c.a })) |e| return e;
    if (common.positional.items.len != 1) return fail("explain needs a workflow file and one rule name", .{});
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    var st = try plan.loadState(c.gpa, l.wf.root, c.a);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var ctx = try planContext(c, &l, &st, &ids, pass.items);
    ctx.rerun = rerun;
    ctx.rerun_rules = reruns.items;
    if (!try knownRules(&l.wf, reruns.items)) return .usage;
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
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
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const ok = try plan.verify(&w.interface, c.gpa, &st, &ids, &l.wf, l.mask, content);
    try w.interface.flush();
    return if (ok) .ok else .failed;
}

const starter_workflow = @embedFile("templates/workflow.toml");
const bash_completion = @embedFile("templates/completion.bash");

fn cmdInit(c: Ctx, args: []const [:0]const u8) !Exit {
    if (args.len > 1) return fail("init takes at most one file name", .{});
    const path = if (args.len == 1) args[0] else "workflow.toml";
    if (sys.exists(c.gpa, path)) return fail("{s} exists; init does not overwrite", .{path});
    try sys.writeFile(c.gpa, path, starter_workflow);
    try out(c.io, "wrote {s}; edit it, then: workz validate {s}\n", .{ path, path });
    return .ok;
}

fn cmdCompletion(c: Ctx, args: []const [:0]const u8) !Exit {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "bash")) return fail("completion supports: bash", .{});
    try out(c.io, "{s}", .{bash_completion});
    return .ok;
}

/// Internal, for completion: the rule names of a workflow, one per line.
fn cmdRules(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    if (try parseArgs(c.a, args, &common, NoExtra{})) |e| return e;
    if (common.workflow == null) common.workflow = "workflow.toml";
    var problem: workflow.Problem = .{};
    const root = (try rootOf(c, &common)) orelse return .usage;
    var wf = workflow.load(c.gpa, try sys.absolute(c.a, try sys.cwd(c.a), common.workflow.?), root, &problem) catch return .failed;
    defer wf.deinit();
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    for (wf.rules) |r| try w.interface.print("{s}\n", .{r.name});
    try w.interface.flush();
    return .ok;
}

const LogsExtra = struct {
    opts: *workz.logs.Options,
    fn option(self: LogsExtra, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        if (eq(u8, arg, "--stdout")) {
            self.opts.stream = .stdout;
            return 1;
        }
        if (eq(u8, arg, "--stderr")) {
            self.opts.stream = .stderr;
            return 1;
        }
        if (eq(u8, arg, "-f") or eq(u8, arg, "--follow")) {
            self.opts.follow = true;
            return 1;
        }
        if (eq(u8, arg, "--launch")) {
            self.opts.launch = value orelse return badValue(arg);
            return 2;
        }
        if (eq(u8, arg, "--attempt")) {
            const v = value orelse return badValue(arg);
            self.opts.attempt = std.fmt.parseInt(u32, v, 10) catch return badValue(arg);
            return 2;
        }
        return 0;
    }
};

fn cmdLogs(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var opts: workz.logs.Options = .{};
    if (try parseArgs(c.a, args, &common, LogsExtra{ .opts = &opts })) |e| return e;
    // `logs RULE` in the working directory (or -d DIR), or `logs WORKFLOW RULE`.
    const rule = switch (common.positional.items.len) {
        0 => blk: {
            const r = common.workflow orelse return fail("logs needs a rule name", .{});
            common.workflow = null;
            break :blk r;
        },
        1 => common.positional.items[0],
        else => return fail("logs takes one rule name", .{}),
    };
    const root = (try rootOf(c, &common)) orelse return .usage;
    const dir = (try workz.logs.find(c.gpa, c.a, root, rule, opts)) orelse return fail("no attempt of rule {s} recorded in {s}/.workz", .{ rule, root });
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    try workz.logs.show(c.gpa, c.a, &w.interface, dir, opts);
    try w.interface.flush();
    return .ok;
}

const CleanExtra = struct {
    opts: *workz.clean.Options,
    fn option(self: CleanExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            self.opts.dry_run = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--keep")) {
            const v = value orelse return badValue(arg);
            self.opts.keep = std.fmt.parseInt(usize, v, 10) catch return badValue(arg);
            return 2;
        }
        return 0;
    }
};

fn cmdClean(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var opts: workz.clean.Options = .{};
    if (try parseArgs(c.a, args, &common, CleanExtra{ .opts = &opts })) |e| return e;
    const root = (try rootOf(c, &common)) orelse return .usage;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const r = workz.clean.run(c.gpa, c.a, root, opts, c.env, &w.interface) catch |err| switch (err) {
        error.Busy => return fail("a run holds {s}/.workz/lock; clean after it ends", .{root}),
        else => return err,
    };
    const verb = if (opts.dry_run) "would remove" else "removed";
    try w.interface.print("{s} {d} container(s) and {d} launch(es), {d:.1} MiB", .{ verb, r.containers, r.launches, @as(f64, @floatFromInt(r.bytes)) / 1048576.0 });
    if (r.kept_for_records > 0) try w.interface.print("; kept {d} older launch(es) that hold recorded attempts", .{r.kept_for_records});
    try w.interface.writeAll("\n");
    try w.interface.flush();
    return .ok;
}

const WatchExtra = struct {
    once: *bool,
    interval: *u64,
    history: ?*?usize = null,
    fn option(self: WatchExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (self.history) |h| if (std.mem.eql(u8, arg, "--history")) {
            // An optional count follows.
            if (value) |v| if (std.fmt.parseInt(usize, v, 10)) |n| {
                h.* = n;
                return 2;
            } else |_| {};
            h.* = 10;
            return 1;
        };
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
    var history: ?usize = null;
    if (try parseArgs(c.a, args, &common, WatchExtra{ .once = &once, .interval = &interval, .history = if (summary) &history else null })) |e| return e;
    const root = (try rootOf(c, &common)) orelse return .usage;
    if (history) |n| {
        var buf: [16384]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
        try monitor.history(c.gpa, &w.interface, root, n);
        try w.interface.flush();
        return .ok;
    }
    const ok = if (summary) try monitor.status(c.gpa, c.io, root) else try monitor.watch(c.gpa, c.io, root, once, @max(interval, 100));
    return if (ok) .ok else .failed;
}

const ReportFormat = enum { tsv, json, html };

const ReportExtra = struct {
    launch: *?[]const u8,
    format: *ReportFormat,
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
            self.format.* = std.meta.stringToEnum(ReportFormat, v) orelse return badValue(arg);
            return 2;
        }
        return 0;
    }
};

fn cmdReport(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var launch: ?[]const u8 = null;
    var format: ReportFormat = .tsv;
    var bottlenecks = false;
    if (try parseArgs(c.a, args, &common, ReportExtra{ .launch = &launch, .format = &format, .bottlenecks = &bottlenecks })) |e| return e;
    const root = (try rootOf(c, &common)) orelse return .usage;
    const rec = try workz.records.recordsDir(c.a, root);
    const dir = if (launch) |id| try std.fs.path.join(c.a, &.{ rec, "launches", id }) else (try workz.records.latestLaunch(c.gpa, c.a, rec)) orelse return fail("no launch recorded in {s}", .{rec});
    if (!sys.exists(c.gpa, dir)) return fail("no launch {s}", .{dir});
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    if (bottlenecks) {
        try report.writeBottlenecks(c.gpa, c.a, &w.interface, dir);
    } else switch (format) {
        .html => try workz.html.write(c.gpa, c.a, &w.interface, dir),
        .json => try report.writeJson(&w.interface, try report.attempts(c.gpa, c.a, dir)),
        .tsv => try report.writeTsv(&w.interface, try report.attempts(c.gpa, c.a, dir)),
    }
    try w.interface.flush();
    return .ok;
}

const RunExtra = struct {
    opts: *run.Options,
    pass: *std.ArrayList([]const u8),
    reruns: *std.ArrayList([]const u8),
    a: std.mem.Allocator,

    fn option(self: RunExtra, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        const o = self.opts;
        if (eq(u8, arg, "-k") or eq(u8, arg, "--keep-going")) {
            o.keep_going = true;
            return 1;
        }
        if (eq(u8, arg, "--rerun-rule")) {
            try self.reruns.append(self.a, value orelse return badValue(arg));
            return 2;
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
        } else if (eq(u8, arg, "--slice")) {
            if (!std.mem.endsWith(u8, v, ".slice") or v.len <= ".slice".len or std.mem.indexOfScalar(u8, v, '/') != null) return badValue(arg);
            o.slice = v;
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
    var reruns: std.ArrayList([]const u8) = .empty;
    if (try parseArgs(c.a, args, &common, RunExtra{ .opts = &opts, .pass = &pass, .reruns = &reruns, .a = c.a })) |e| return e;
    opts.rerun_rules = reruns.items;
    opts.pass_env = pass.items;
    if (opts.input_manifest) |m| opts.input_manifest = try sys.absolute(c.a, try sys.cwd(c.a), m);
    // The launcher only starts the scope; the engine inside reads the workflow.
    const inner = if (c.env.get("WORKZ_STAGE")) |s| std.mem.eql(u8, s, "inner") else false;
    if (opts.isolation and !inner) return isolate(c, opts);
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    if (!try knownRules(&l.wf, opts.rerun_rules)) return .usage;
    const outcome = try run.execute(c.gpa, c.a, &l.wf, &l.g, l.mask, opts, c.env);
    return switch (outcome) {
        .ok => .ok,
        .failed => .failed,
        .invalid => .usage,
        .interrupted => .interrupted,
    };
}

/// Reports a name given to --rerun-rule that is not a rule of the workflow.
fn knownRules(wf: *const workflow.Workflow, names: []const []const u8) !bool {
    for (names) |n| if (wf.ruleIndex(n) == null) {
        std.debug.print("workz: --rerun-rule {s}: no such rule\n", .{n});
        return false;
    };
    return true;
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

/// Re-executes the run inside a delegated systemd user scope: cgroup limits
/// for the whole run, swap off. `systemd-run --scope` execs the engine in this
/// same process, so interrupt signals reach the engine directly.
fn isolate(c: Ctx, opts: run.Options) !Exit {
    const systemd_run = (try findProgram(c, "systemd-run")) orelse return fail("systemd-run not found; isolation needs a systemd user manager (or use --no-isolation)", .{});
    const threads = opts.max_threads orelse run.defaultThreads();
    var memory = opts.max_memory_mib orelse run.defaultMemoryMib(c.gpa);
    // The engine and its network holder need a little memory beside the tasks.
    memory += 256;
    const exe = try sys.selfExe(c.a);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ systemd_run, "--user", "--scope", "--quiet", "--expand-environment=no" });
    // With --slice the scope becomes a child of the caller's slice, inside its limits.
    if (opts.slice) |slice| try argv.append(c.a, try std.fmt.allocPrint(c.a, "--slice={s}", .{slice}));
    try argv.appendSlice(c.a, &.{
        "-p", "Delegate=yes",
        "-p", try std.fmt.allocPrint(c.a, "MemoryMax={d}M", .{memory}),
        "-p", "MemorySwapMax=0",
        "-p", try std.fmt.allocPrint(c.a, "CPUQuota={d}%", .{@as(u64, threads) * 100}),
        "--", exe,
    });
    for (c.argv[1..]) |arg| try argv.append(c.a, arg);
    var env: std.ArrayList([]const u8) = .empty;
    var it = c.env.iterator();
    while (it.next()) |e| try env.append(c.a, try std.fmt.allocPrint(c.a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
    try env.append(c.a, "WORKZ_STAGE=inner");
    const argv_z = try workz.process.Vec.init(c.a, argv.items);
    const env_z = try workz.process.Vec.init(c.a, env.items);
    const rc = linux.execve(try c.a.dupeZ(u8, systemd_run), argv_z.items.ptr, env_z.items.ptr);
    return fail("cannot start systemd-run: {s}", .{@tagName(linux.errno(rc))});
}

/// Internal: creates the run's network: a new user namespace mapping the
/// caller's own uid and gid, and a new network namespace with only loopback,
/// brought up. Reports "ready" on stdout and waits for end of file on stdin,
/// a pipe whose only writer is the engine; shell rules join both namespaces.
/// The engine stops it with SIGKILL. End of file means the engine died: the
/// holder then kills the run's cgroup (`cgroup.kill` named by the argument),
/// so no task, container or service outlives its engine.
fn netns(args: []const [:0]const u8) Exit {
    const uid = linux.getuid();
    const gid = linux.getgid();
    var kill_fd: i32 = -1;
    if (args.len == 1) {
        const rc = linux.openat(linux.AT.FDCWD, args[0], .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return fail("cannot open {s}", .{args[0]});
        kill_fd = @intCast(rc);
    }
    // Stopping the run's scope signals every process in it; the engine
    // handles that and stops this holder itself.
    var ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .INT, .TERM, .HUP }) |sig| _ = linux.sigaction(sig, &ignore, null);
    if (linux.errno(linux.unshare(linux.CLONE.NEWUSER | linux.CLONE.NEWNET)) != .SUCCESS) return fail("cannot create the run's network namespace", .{});
    var buf: [64]u8 = undefined;
    writeProc("/proc/self/setgroups", "deny") catch return fail("cannot deny setgroups", .{});
    writeProc("/proc/self/uid_map", std.fmt.bufPrint(&buf, "{d} {d} 1", .{ uid, uid }) catch unreachable) catch return fail("cannot map the user id", .{});
    writeProc("/proc/self/gid_map", std.fmt.bufPrint(&buf, "{d} {d} 1", .{ gid, gid }) catch unreachable) catch return fail("cannot map the group id", .{});
    // Bring loopback up so rules can use 127.0.0.1 among themselves.
    const IfReq = extern struct { name: [16]u8, flags: i16, pad: [22]u8 };
    const sock = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(sock) == .SUCCESS) {
        var req: IfReq = std.mem.zeroes(IfReq);
        @memcpy(req.name[0..2], "lo");
        const fd: i32 = @intCast(sock);
        if (linux.errno(linux.ioctl(fd, linux.SIOCGIFFLAGS, @intFromPtr(&req))) == .SUCCESS) {
            req.flags |= 1; // IFF_UP
            _ = linux.ioctl(fd, linux.SIOCSIFFLAGS, @intFromPtr(&req));
        }
        _ = linux.close(fd);
    }
    _ = linux.write(1, "ready\n", 6);
    var byte: [1]u8 = undefined;
    while (true) {
        const rc = linux.read(0, &byte, 1);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) == .SUCCESS and rc > 0) continue;
        break;
    }
    if (kill_fd >= 0) _ = linux.write(kill_fd, "1", 1);
    return .ok;
}

/// Internal: guards a run without isolation. It reads "+PGID" and "-PGID"
/// lines on stdin, a pipe whose only writer is the engine, as tasks start
/// and end. At end of file, also when the engine died, it kills the process
/// groups still listed, so no task outlives its engine.
fn guard() Exit {
    var ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .INT, .TERM, .HUP }) |sig| _ = linux.sigaction(sig, &ignore, null);
    var live: std.AutoArrayHashMapUnmanaged(i32, void) = .empty;
    var buf: [4096]u8 = undefined;
    var line: [32]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const rc = linux.read(0, &buf, buf.len);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
        for (buf[0..rc]) |c| {
            if (c != '\n') {
                if (len < line.len) line[len] = c;
                len += 1;
                continue;
            }
            defer len = 0;
            if (len < 2 or len > line.len) continue;
            const pgid = std.fmt.parseInt(i32, line[1..len], 10) catch continue;
            if (line[0] == '+') live.put(std.heap.page_allocator, pgid, {}) catch {} else _ = live.swapRemove(pgid);
        }
    }
    for (live.keys()) |pgid| _ = linux.kill(-pgid, .KILL);
    return .ok;
}

fn writeProc(path: [*:0]const u8, text: []const u8) !void {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    _ = try sys.check(rc);
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    _ = try sys.check(linux.write(fd, text.ptr, text.len));
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
