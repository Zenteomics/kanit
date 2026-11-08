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
const term = workz.term;
const cli = workz.cli;

fn cmdHelp(c: Ctx, args: []const []const u8) !Exit {
    const s: term.Style = .{ .on = term.colorOn(1, c.env) };
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    if (args.len == 0) {
        try cli.writeOverview(&w.interface, s);
    } else {
        const cmd = cli.command(args[0]) orelse return (cli.Parser{ .a = c.a, .err = c.err, .name = args[0] }).unknownCommand();
        try cli.writeCommandHelp(&w.interface, cmd, s);
    }
    try w.interface.flush();
    return .ok;
}

// --- Errors ---

const Exit = cli.Exit;

fn fail(comptime fmt: []const u8, args: anytype) Exit {
    std.debug.print("kanit: " ++ fmt ++ "\n", args);
    return .usage;
}

fn failed(comptime fmt: []const u8, args: anytype) Exit {
    std.debug.print("kanit: " ++ fmt ++ "\n", args);
    return .failed;
}

fn stateFailed(c: Ctx, err: anyerror, root: []const u8) !Exit {
    const path = try std.fs.path.join(c.a, &.{ root, ".workz", "state.json" });
    const why = (try state.loadErrorText(c.a, err, path)) orelse return err;
    return failed("{s}", .{why});
}

fn unreadable(err: anyerror, ids: *const state.Identities) !Exit {
    if (err == error.Unreadable) return fail("{s}", .{ids.problem});
    return err;
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    argv: []const [:0]const u8,
    err: *std.Io.Writer,

    fn parser(c: Ctx) cli.Parser {
        return .{ .a = c.a, .err = c.err, .name = c.argv[1] };
    }
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) {
        var buf: [8192]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(init.io, &buf);
        try cli.writeOverview(&w.interface, .{ .on = false });
        try w.interface.flush();
        return @intFromEnum(Exit.usage);
    }
    const gpa = if (@import("builtin").mode == .Debug) init.gpa else std.heap.smp_allocator;
    var err_buf: [4096]u8 = undefined;
    var err_w = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
    const ctx: Ctx = .{ .gpa = gpa, .a = a, .io = init.io, .env = init.environ_map, .argv = args, .err = &err_w.interface };
    const cmd = args[1];
    const rest = args[2..];
    const eq = std.mem.eql;
    if (cli.command(cmd) != null) for (rest) |arg| {
        if (eq(u8, arg, "--help") or eq(u8, arg, "-h")) return @intFromEnum(try cmdHelp(ctx, &.{cmd}));
    };
    const code: Exit = if ((eq(u8, cmd, "version") or eq(u8, cmd, "--version")) and rest.len > 0) fail("version takes no arguments; run kanit version", .{}) else if (eq(u8, cmd, "version") or eq(u8, cmd, "--version")) blk: {
        try out(init.io, "kanit {s}\n", .{workz.version});
        break :blk .ok;
    } else if (eq(u8, cmd, "help") or eq(u8, cmd, "--help") or eq(u8, cmd, "-h")) try cmdHelp(ctx, rest) else if (eq(u8, cmd, "validate")) try cmdValidate(ctx, rest) else if (eq(u8, cmd, "graph")) try cmdGraph(ctx, rest) else if (eq(u8, cmd, "plan") or eq(u8, cmd, "dry-run")) try cmdPlan(ctx, rest, null) else if (eq(u8, cmd, "explain")) try cmdExplain(ctx, rest) else if (eq(u8, cmd, "verify")) try cmdVerify(ctx, rest) else if (eq(u8, cmd, "run")) try cmdRun(ctx, rest) else if (eq(u8, cmd, "watch")) try cmdWatch(ctx, rest, false) else if (eq(u8, cmd, "status")) try cmdWatch(ctx, rest, true) else if (eq(u8, cmd, "report")) try cmdReport(ctx, rest) else if (eq(u8, cmd, "clean")) try cmdClean(ctx, rest) else if (eq(u8, cmd, "logs")) try cmdLogs(ctx, rest) else if (eq(u8, cmd, "init")) try cmdInit(ctx, rest) else if (eq(u8, cmd, "schema")) try cmdSchema(ctx, rest) else if (eq(u8, cmd, "prepare")) try cmdPrepare(ctx, rest) else if (eq(u8, cmd, "control")) try cmdControl(ctx, rest) else if (eq(u8, cmd, "completion")) try cmdCompletion(ctx, rest) else if (eq(u8, cmd, "__rules")) try cmdRules(ctx, rest) else if (eq(u8, cmd, "__hold")) hold(rest) else if (eq(u8, cmd, "__netns")) netns(rest) else if (eq(u8, cmd, "__guard")) guard() else ctx.parser().unknownCommand();
    return @intFromEnum(code);
}

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

const Loaded = struct {
    wf: workflow.Workflow,
    g: graph.Graph,
    mask: []bool,

    fn deinit(self: *Loaded) void {
        self.g.deinit();
        self.wf.deinit();
    }
};

fn rootOf(c: Ctx, common: *const cli.Common) !?[]const u8 {
    const here = try sys.cwd(c.a);
    if (common.workflow) |w| {
        const id = (try sys.stat(c.gpa, w)) orelse {
            if (common.workdir == null) {
                std.debug.print("kanit: no workflow file {s}; -d DIR names a working directory\n", .{w});
                return null;
            }
            return try workdirOf(c, here, common.workdir.?);
        };
        if (id.isDir()) {
            std.debug.print("kanit: {s} is a directory; name the workflow file in it, or give -d {s} to work there\n", .{ w, w });
            return null;
        }
    }
    if (common.workdir) |d| return try workdirOf(c, here, d);
    const given = if (common.workflow) |w| std.fs.path.dirname(try sys.absolute(c.a, here, w)) orelse "/" else here;
    return (try sys.realpath(c.a, given)) orelse {
        std.debug.print("kanit: working directory does not exist: {s}\n", .{given});
        return null;
    };
}

fn workdirOf(c: Ctx, here: []const u8, dir: []const u8) !?[]const u8 {
    const given = try sys.absolute(c.a, here, dir);
    const real = (try sys.realpath(c.a, given)) orelse {
        std.debug.print("kanit: working directory does not exist: {s}\n", .{given});
        return null;
    };
    if (!((try sys.stat(c.gpa, real)) orelse return null).isDir()) {
        std.debug.print("kanit: -d names a file, not a directory: {s}\n", .{given});
        return null;
    }
    return real;
}

fn showSnippet(c: Ctx, path: []const u8, problem: workflow.Problem) void {
    if (problem.line == 0) return;
    const source = sys.readFile(c.gpa, path, 64 << 20) catch return;
    defer c.gpa.free(source);
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(c.io, &buf);
    workflow.snippet(&w.interface, source, problem.line, problem.col) catch return;
    w.interface.flush() catch {};
}

fn printProblems(c: Ctx, wpath: []const u8, wf_abs: []const u8, problem: workflow.Problem) void {
    if (problem.count <= 1) {
        std.debug.print("kanit: {s}: {s}\n", .{ wpath, problem.message });
    } else {
        std.debug.print("kanit: {s}: {d} problems\n", .{ wpath, problem.count });
        var lines = std.mem.splitScalar(u8, problem.message, '\n');
        while (lines.next()) |line| std.debug.print("  {s}\n", .{line});
        if (problem.count > workflow.Problem.max_listed) std.debug.print("  and {d} more\n", .{problem.count - workflow.Problem.max_listed});
    }
    showSnippet(c, wf_abs, problem);
}

fn load(c: Ctx, common: *const cli.Common) !?Loaded {
    const wpath = common.workflow orelse default: {
        if (sys.exists(c.gpa, default_workflow)) break :default default_workflow;
        std.debug.print("kanit: no workflow file given, and no {s} in this directory\n", .{default_workflow});
        return null;
    };
    const root = (try rootOf(c, common)) orelse return null;
    const wf_abs = try sys.absolute(c.a, try sys.cwd(c.a), wpath);
    var problem: workflow.Problem = .{};
    var wf = workflow.load(c.gpa, wf_abs, root, &problem) catch |err| switch (err) {
        error.Invalid => {
            printProblems(c, wpath, wf_abs, problem);
            c.gpa.free(problem.message);
            return null;
        },
        else => return err,
    };
    errdefer wf.deinit();
    var g = graph.build(c.gpa, &wf, &problem) catch |err| switch (err) {
        error.Cycle, error.Invalid => {
            const lined = try graphProblem(c, wf_abs, root, problem);
            printProblems(c, wpath, wf_abs, lined);
            c.gpa.free(lined.message);
            wf.deinit();
            return null;
        },
        else => return err,
    };
    errdefer g.deinit();
    var unknown: ?[]const u8 = null;
    const mask = graph.select(c.a, &wf, &g, common.targets.items, &unknown) catch |err| switch (err) {
        error.UnknownTarget => {
            var names: std.ArrayList([]const u8) = .empty;
            for (wf.rules) |r| try names.append(c.a, r.name);
            if (workflow.closest(names.items, unknown.?)) |hint| {
                std.debug.print("kanit: unknown target '{s}'; did you mean '{s}'?\n", .{ unknown.?, hint });
            } else std.debug.print("kanit: unknown target '{s}': no rule of {s} has that name\n", .{ unknown.?, wpath });
            g.deinit();
            wf.deinit();
            return null;
        },
        else => return err,
    };
    return .{ .wf = wf, .g = g, .mask = mask };
}

fn cmdValidate(c: Ctx, args: []const [:0]const u8) !Exit {
    var v: cli.Validate = .{};
    if (try v.parse(c.parser(), args)) |e| return e;
    var l = (try load(c, &v.common)) orelse return .usage;
    defer l.deinit();
    var selected: usize = 0;
    for (l.mask) |m| selected += @intFromBool(m);
    var text: std.Io.Writer.Allocating = .init(c.gpa);
    defer text.deinit();
    const w = &text.writer;
    try w.print("valid: {s} ({d} rules, {d} selected, {d} groups, {d} shared)\n", .{ l.wf.name, l.wf.rules.len, selected, l.wf.groups.len, l.wf.shared.len });
    try workz.lint.notes(c.a, w, &l.wf, l.mask);
    var missing: usize = 0;
    if (v.inputs) missing = try workz.lint.missingInputs(c.gpa, w, &l.wf, &l.g, l.mask);
    try sys.writeAll(1, text.written());
    return if (missing > 0) .failed else .ok;
}

fn cmdGraph(c: Ctx, args: []const [:0]const u8) !Exit {
    var ga: cli.Graph = .{};
    if (try ga.parse(c.parser(), args)) |e| return e;
    var opts = ga.opts;
    var l = (try load(c, &ga.common)) orelse return .usage;
    defer l.deinit();
    if (ga.focus) |text| opts.focus = workz.views.Focus.parse(text, &l.wf);
    const kind = ga.format orelse if (term.isTerminal(1)) workz.views.Format.text else .dot;
    var text: std.Io.Writer.Allocating = .init(c.gpa);
    defer text.deinit();
    const v = workz.views.build(c.a, &l.wf, &l.g, l.mask, opts) catch |err| switch (err) {
        error.UnknownRule => return fail("no rule named {s} in {s}", .{ if (opts.focus) |f| f.rule else if (opts.why) |p| if (l.wf.findRule(p[0]) == null) p[0] else p[1] else "?", l.wf.path }),
        error.UnknownShared => return fail("no shared input named {s} in {s}", .{ opts.users.?, l.wf.path }),
        error.NoPath => return failed("{s} does not lead to {s}: no rule between them reads what the one before writes", .{ opts.why.?[0], opts.why.?[1] }),
        error.NotSelected => return fail("{s} is not among the rules --target selects", .{if (!l.mask[l.wf.findRule(opts.why.?[0]).?]) opts.why.?[0] else opts.why.?[1]}),
        else => return err,
    };
    switch (kind) {
        .dot => try workz.views.writeDot(c.a, &text.writer, l.wf.name, v),
        .json => try workz.views.writeJson(&text.writer, v),
        .text => if (opts.why) |p|
            try workz.views.writeWhy(&text.writer, &l.wf, &l.g, try workz.views.whyPath(c.a, &l.wf, &l.g, l.mask, p[0], p[1]))
        else
            try workz.views.writeText(c.a, &text.writer, v),
    }
    try sys.writeAll(1, text.written());
    return .ok;
}

fn checkPlanManifest(c: Ctx, st: *state.State, ids: *state.Identities, manifest: ?[]const u8) !?bool {
    const m = manifest orelse return true;
    const check = try run.checkManifest(c.gpa, st, ids, try sys.absolute(c.a, try sys.cwd(c.a), m), false, c.err);
    try c.err.flush();
    return if (check.usable) check.ok else null;
}

fn noteLiveLaunch(c: Ctx, root: []const u8) !void {
    const rec = try workz.records.recordsDir(c.a, root);
    if (workz.records.running(c.gpa, rec)) std.debug.print("kanit: a launch is running in {s}; rules it has not finished show their earlier records\n", .{root});
}

fn planContext(c: Ctx, l: *Loaded, st: *state.State, ids: *state.Identities, pass: []const []const u8) !plan.Context {
    var ctx = try plan.Context.init(c.gpa, c.a, &l.wf, &l.g, st, ids, try state.envText(c.a, c.env, pass), c.env);
    ctx.pass_env = pass;
    return ctx;
}

fn cmdPlan(c: Ctx, args: []const [:0]const u8, _: ?void) !Exit {
    var pa: cli.Plan = .{};
    if (try pa.parse(c.parser(), args)) |e| return e;
    var l = (try load(c, &pa.common)) orelse return .usage;
    defer l.deinit();
    if (try c.parser().applyThreads(&l.wf, pa.threads.items)) |e| return e;
    var st = plan.loadState(c.gpa, l.wf.root, c.a) catch |err| return stateFailed(c, err, l.wf.root);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var ctx = planContext(c, &l, &st, &ids, pa.pass.items) catch |err| return unreadable(err, &ids);
    try noteLiveLaunch(c, l.wf.root);
    ctx.rerun = pa.rerun;
    ctx.rerun_rules = pa.reruns.items;
    if (try c.parser().knownRules(&l.wf, pa.reruns.items)) |e| return e;
    const manifest_ok = (try checkPlanManifest(c, &st, &ids, pa.manifest)) orelse return .usage;
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const ds = ctx.decideAll(l.mask) catch |err| return unreadable(err, &ids);
    try (if (pa.summary) plan.printSummary(&w.interface, &ctx, ds, l.mask) else plan.printPlan(&w.interface, &ctx, ds, l.mask));
    var refused: usize = 0;
    var missing: usize = 0;
    var changed: usize = 0;
    for (ds, l.mask) |d, m| if (m and d.run) {
        if (std.mem.startsWith(u8, d.reason, "input missing")) missing += 1;
        if (std.mem.startsWith(u8, d.reason, "output changed")) changed += 1;
    };
    if (missing + changed > 0) {
        refused += missing + changed;
        std.debug.print("kanit: run would refuse this launch: {d} {s} with a missing input, {d} with an output changed outside kanit\n", .{ missing, if (missing == 1) "rule" else "rules", changed });
    }
    if (!manifest_ok) {
        refused += 1;
        std.debug.print("kanit: run would refuse this launch: inputs do not match the input manifest\n", .{});
    }
    if (pa.budget) {
        const runs = try c.a.alloc(bool, l.wf.rules.len);
        var reused: usize = 0;
        for (runs, ds, l.mask) |*r, d, m| {
            r.* = m and d.run;
            reused += @intFromBool(m and !d.run);
        }
        refused += try plan.printBudget(c.gpa, c.a, &w.interface, &l.wf, runs, reused, .{
            .threads = pa.max_threads orelse run.defaultThreads(),
            .memory_mib = pa.max_memory orelse run.defaultMemoryMib(c.gpa),
            .defaults = pa.max_threads == null and pa.max_memory == null,
        });
    }
    try w.interface.flush();
    return if (refused > 0) .failed else .ok;
}

fn cmdExplain(c: Ctx, args: []const [:0]const u8) !Exit {
    var pa: cli.Plan = .{ .explain = true };
    if (try pa.parse(c.parser(), args)) |e| return e;
    var l = (try load(c, &pa.common)) orelse return .usage;
    defer l.deinit();
    if (try c.parser().applyThreads(&l.wf, pa.threads.items)) |e| return e;
    var st = plan.loadState(c.gpa, l.wf.root, c.a) catch |err| return stateFailed(c, err, l.wf.root);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var ctx = planContext(c, &l, &st, &ids, pa.pass.items) catch |err| return unreadable(err, &ids);
    try noteLiveLaunch(c, l.wf.root);
    ctx.rerun = pa.rerun;
    ctx.rerun_rules = pa.reruns.items;
    if (try c.parser().knownRules(&l.wf, pa.reruns.items)) |e| return e;
    if (!((try checkPlanManifest(c, &st, &ids, pa.manifest)) orelse return .usage)) std.debug.print("kanit: run would refuse this launch: inputs do not match the input manifest\n", .{});
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const found = plan.explain(&w.interface, &ctx, l.mask, pa.rule) catch |err| return unreadable(err, &ids);
    try w.interface.flush();
    if (!found) {
        if (try cli.closestRule(c.a, &l.wf, pa.rule)) |hint| return fail("unknown rule '{s}'; did you mean '{s}'?", .{ pa.rule, hint });
        return fail("unknown rule '{s}'", .{pa.rule});
    }
    return .ok;
}

fn cmdVerify(c: Ctx, args: []const [:0]const u8) !Exit {
    var va: cli.Verify = .{};
    if (try va.parse(c.parser(), args)) |e| return e;
    var l = (try load(c, &va.common)) orelse return .usage;
    defer l.deinit();
    const rec = try workz.records.recordsDir(c.a, l.wf.root);
    const lock: ?sys.Fd = if (!sys.exists(c.gpa, rec)) null else workz.records.lock(c.gpa, rec) catch |err| switch (err) {
        error.Busy => return failed("a launch is running in {s}; verify after it ends", .{l.wf.root}),
        else => return err,
    };
    defer if (lock) |fd| sys.close(fd);
    var st = plan.loadState(c.gpa, l.wf.root, c.a) catch |err| return stateFailed(c, err, l.wf.root);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const ok = try plan.verify(&w.interface, c.gpa, &st, &ids, &l.wf, l.mask, va.content);
    try w.interface.flush();
    return if (ok) .ok else .failed;
}

fn cmdControl(c: Ctx, args: []const [:0]const u8) !Exit {
    var ca: cli.Control = .{};
    if (try ca.parse(c.parser(), args)) |e| return e;
    const root = (try rootOf(c, &ca.common)) orelse return .usage;
    const rec = try workz.records.recordsDir(c.a, root);
    const dir = (try workz.records.latestLaunch(c.gpa, c.a, rec)) orelse return failed("no launch recorded in {s}; kanit run starts one", .{rec});
    if (sys.exists(c.gpa, try std.fs.path.join(c.a, &.{ dir, "summary.json" }))) return failed("the newest launch has ended: {s}; kanit run starts another", .{dir});
    if (!workz.records.launchActive(c.gpa, dir)) return failed("the newest launch did not finish, and no engine runs it: {s}; its engine ended without recording its end", .{dir});
    var tr = try workz.tracker.Tracker.init(c.gpa, dir);
    defer tr.deinit();
    _ = try tr.update();
    if (tr.ending) return failed("the newest launch is ending and applies no more commands: {s}", .{dir});
    const rule: ?[]const u8 = if (ca.rule) |token| workz.names.resolve(c.gpa, c.a, dir, token) orelse token else null;
    if (rule) |name| if (!tr.index.contains(name)) return failed("rule {s} is not part of the running launch", .{ca.rule.?});
    const line = if (rule) |name| try std.fmt.allocPrint(c.a, "{s} {s}\n", .{ ca.verb, name }) else "cancel\n";
    const fd = try sys.openWrite(c.gpa, try std.fs.path.join(c.a, &.{ dir, "control" }), .append);
    defer sys.close(fd);
    try sys.writeAll(fd, line);
    try out(c.io, "sent: {s}", .{line});
    return .ok;
}

const default_workflow = cli.default_workflow;
const starter_workflow = @embedFile("templates/workflow.toml");
const starter_pipeline = @embedFile("templates/pipeline.toml");
const bash_completion = @embedFile("templates/completion.bash");

fn cmdInit(c: Ctx, args: []const [:0]const u8) !Exit {
    var ia: cli.Init = .{};
    if (try ia.parse(c.parser(), args)) |e| return e;
    const file = ia.file;
    if (ia.template) {
        const path = file orelse "pipeline.toml";
        const sheet = if (std.fs.path.dirname(path)) |d| try std.fs.path.join(c.a, &.{ d, "samples.tsv" }) else "samples.tsv";
        for ([_][]const u8{ path, sheet }) |p| if (sys.exists(c.gpa, p)) return fail("{s} exists; init does not overwrite", .{p});
        sys.writeFile(c.gpa, path, starter_pipeline) catch |err| return failed("cannot write {s}: {s}", .{ path, sys.errorText(err) });
        sys.writeFile(c.gpa, sheet, "sample\treads\nS1\tdata/S1.txt\nS2\tdata/S2.txt\n") catch |err| return failed("cannot write {s}: {s}", .{ sheet, sys.errorText(err) });
        try out(c.io, "wrote {s} and {s}; its steps read data/S1.txt and data/S2.txt, which it does not create. Edit them, then: kanit prepare\n", .{ path, sheet });
        return .ok;
    }
    const path = file orelse default_workflow;
    if (sys.exists(c.gpa, path)) return fail("{s} exists; init does not overwrite", .{path});
    sys.writeFile(c.gpa, path, starter_workflow) catch |err| return failed("cannot write {s}: {s}", .{ path, sys.errorText(err) });
    try out(c.io, "wrote {s}; its example rules read data/S1.txt, which it does not create. Edit it, then: kanit validate {s}\n", .{ path, path });
    return .ok;
}

fn cmdPrepare(c: Ctx, args: []const [:0]const u8) !Exit {
    var pa: cli.Prepare = .{};
    if (try pa.parse(c.parser(), args)) |e| return e;
    const output = pa.output;
    const run_file = pa.params;
    const check = pa.check;
    const cwd = try sys.cwd(c.a);
    const shown = pa.template orelse "pipeline.toml";
    const path = try sys.absolute(c.a, cwd, shown);
    if (!sys.exists(c.gpa, path)) return fail("no template {s}; a template is a pipeline file with [[steps]] (see kanit help prepare)", .{shown});
    const run_spec: ?workz.prepare.RunFile = if (run_file) |r| .{ .path = try sys.absolute(c.a, cwd, r), .shown = r } else null;
    if (run_spec) |r| if (!sys.exists(c.gpa, r.path)) return fail("no run file {s}", .{r.shown});
    const beside = if (run_spec) |r| r.path else path;
    const out_path = if (output) |o| try sys.absolute(c.a, cwd, o) else try std.fs.path.join(c.a, &.{ std.fs.path.dirname(beside) orelse ".", default_workflow });
    if (std.mem.eql(u8, out_path, path)) return fail("the template and the workflow it prepares are the same file: give another with -o", .{});
    var problem: workz.prepare.Problem = .{};
    const text = workz.prepare.compileWith(c.gpa, c.a, path, shown, run_spec, &problem) catch |err| switch (err) {
        error.Invalid => return fail("{s}", .{problem.message}),
        else => return err,
    };
    for (problem.notes.items) |note| std.debug.print("kanit: note: {s}\n", .{note});
    const tmp = if (check) name: {
        var rnd: [8]u8 = undefined;
        sys.randomBytes(&rnd);
        break :name try std.fmt.allocPrint(c.a, "{s}/workz-prepare-{s}.toml", .{ c.env.get("TMPDIR") orelse "/tmp", &std.fmt.bytesToHex(rnd, .lower) });
    } else try std.fmt.allocPrint(c.a, "{s}.prepare-tmp", .{out_path});
    if (check) {
        const fd = sys.openWrite(c.gpa, tmp, .exclusive) catch |err| return failed("cannot write {s}: {s}", .{ tmp, sys.errorText(err) });
        defer sys.close(fd);
        sys.writeAll(fd, text) catch |err| return failed("cannot write {s}: {s}", .{ tmp, sys.errorText(err) });
    } else sys.writeFile(c.gpa, tmp, text) catch |err| return failed("cannot write {s}: {s}", .{ tmp, sys.errorText(err) });
    var keep_tmp = false;
    defer if (!keep_tmp) sys.unlink(c.gpa, tmp) catch {};
    const root = std.fs.path.dirname(out_path) orelse ".";
    var wproblem: workflow.Problem = .{};
    var wf = workflow.load(c.gpa, tmp, root, &wproblem) catch |err| switch (err) {
        error.Invalid => {
            notValid(c, shown, tmp, check, &keep_tmp, wproblem);
            return .usage;
        },
        else => return err,
    };
    defer wf.deinit();
    var g = graph.build(c.gpa, &wf, &wproblem) catch |err| switch (err) {
        error.Cycle, error.Invalid => {
            notValid(c, shown, tmp, check, &keep_tmp, try graphProblem(c, tmp, root, wproblem));
            return .usage;
        },
        else => return err,
    };
    defer g.deinit();
    var steps: std.StringHashMapUnmanaged(void) = .empty;
    for (wf.rules) |r| try steps.put(c.a, r.labels.step, {});
    if (check) {
        const old = sys.readFile(c.gpa, out_path, 64 << 20) catch |err| switch (err) {
            error.FileNotFound => {
                try out(c.io, "{s} does not exist: prepare would write {d} {s} from {d} {s}\n", .{ out_path, wf.rules.len, if (wf.rules.len == 1) "rule" else "rules", steps.count(), if (steps.count() == 1) "step" else "steps" });
                return .failed;
            },
            else => return err,
        };
        defer c.gpa.free(old);
        var text_out: std.Io.Writer.Allocating = .init(c.gpa);
        defer text_out.deinit();
        const differs = try workz.prepare.writeDiff(c.a, &text_out.writer, old, text);
        try sys.writeAll(1, text_out.written());
        return if (differs) .failed else .ok;
    }
    try sys.rename(c.gpa, tmp, out_path);
    keep_tmp = true;
    try out(c.io, "wrote {s}: {d} {s} from {d} {s}. Next: kanit graph --by step, then kanit plan\n", .{ out_path, wf.rules.len, if (wf.rules.len == 1) "rule" else "rules", steps.count(), if (steps.count() == 1) "step" else "steps" });
    return .ok;
}

fn notValid(c: Ctx, shown: []const u8, tmp: []const u8, check: bool, keep_tmp: *bool, problem: workflow.Problem) void {
    if (check) {
        std.debug.print("kanit: the workflow {s} prepares is not valid\n", .{shown});
    } else {
        keep_tmp.* = true;
        std.debug.print("kanit: the workflow {s} prepares is not valid; it is kept as {s} to read\n", .{ shown, tmp });
    }
    printProblems(c, if (check) "the prepared workflow" else tmp, tmp, problem);
    c.gpa.free(problem.message);
}

fn cmdSchema(c: Ctx, args: []const [:0]const u8) !Exit {
    if (try cli.noArguments(c.parser(), args)) |e| return e;
    var text: std.Io.Writer.Allocating = .init(c.gpa);
    defer text.deinit();
    try workz.schema.write(&text.writer);
    try sys.writeAll(1, text.written());
    return .ok;
}

fn cmdCompletion(c: Ctx, args: []const [:0]const u8) !Exit {
    if (cli.completionShell(c.parser(), args)) |e| return e;
    try out(c.io, "{s}", .{bash_completion});
    return .ok;
}

fn cmdRules(c: Ctx, args: []const [:0]const u8) !Exit {
    var ra: cli.Plain = .{};
    if (try ra.parse(c.parser(), args)) |e| return e;
    const common = &ra.common;
    if (common.workflow == null) common.workflow = default_workflow;
    var problem: workflow.Problem = .{};
    const root = (try rootOf(c, common)) orelse return .usage;
    var wf = workflow.load(c.gpa, try sys.absolute(c.a, try sys.cwd(c.a), common.workflow.?), root, &problem) catch return .failed;
    defer wf.deinit();
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const n = try workz.names.Names.init(c.a, wf.rules);
    for (wf.rules, n.word) |r, word| {
        try w.interface.print("{s}\n", .{r.name});
        if (!std.mem.eql(u8, word, r.name)) try w.interface.print("{s}\n", .{word});
    }
    try w.interface.flush();
    return .ok;
}

fn cmdLogs(c: Ctx, args: []const [:0]const u8) !Exit {
    var la: cli.Logs = .{};
    if (try la.parse(c.parser(), args)) |e| return e;
    const opts = la.opts;
    const root = (try rootOf(c, &la.common)) orelse return .usage;
    const rec = try workz.records.recordsDir(c.a, root);
    if (opts.launch) |id| if (!sys.exists(c.gpa, try std.fs.path.join(c.a, &.{ rec, "launches", id }))) return failed("no launch {s} recorded in {s}", .{ id, rec });
    const named = if (opts.launch) |id| try std.fs.path.join(c.a, &.{ rec, "launches", id }) else try workz.records.latestLaunch(c.gpa, c.a, rec);
    const rule = workz.names.resolve(c.gpa, c.a, named, la.rule) orelse return failed("no rule {s} in the newest launch's workflow", .{la.rule});
    const fresh = if (opts.follow and opts.launch == null and opts.attempt == null) try workz.logs.awaitAttempt(c.gpa, c.a, root, rule) else null;
    const dir = fresh orelse (try workz.logs.find(c.gpa, c.a, root, rule, opts)) orelse {
        if (opts.attempt) |n| return failed("no attempt {d} of rule {s} recorded in {s}", .{ n, rule, rec });
        if (opts.launch) |id| return failed("rule {s} did not run in launch {s}", .{ rule, id });
        return failed("no attempt of rule {s} recorded in {s}", .{ rule, rec });
    };
    var buf: [65536]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    try workz.logs.show(c.gpa, c.a, &w.interface, dir, opts);
    try w.interface.flush();
    return .ok;
}

fn cmdClean(c: Ctx, args: []const [:0]const u8) !Exit {
    var ca: cli.Clean = .{};
    if (try ca.parse(c.parser(), args)) |e| return e;
    const opts = ca.opts;
    const root = (try rootOf(c, &ca.common)) orelse return .usage;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const r = workz.clean.run(c.gpa, c.a, root, opts, c.env, &w.interface) catch |err| switch (err) {
        error.Busy => return failed("a launch is running in {s}; clean after it ends", .{root}),
        error.OutOfMemory => return err,
        error.CorruptState, error.UnsupportedState => {
            std.debug.print("kanit: clean --keep cannot tell which launches hold recorded results\n", .{});
            return stateFailed(c, err, root);
        },
        else => return failed("cannot clean {s}: {s}", .{ root, sys.errorText(err) }),
    };
    const verb = if (opts.dry_run) "would remove" else "removed";
    try w.interface.print("{s} {d} container(s) and {d} launch(es), {d:.1} MiB", .{ verb, r.containers, r.launches, @as(f64, @floatFromInt(r.bytes)) / 1048576.0 });
    if (r.kept_for_records > 0) try w.interface.print("; kept {d} older launch(es) that hold recorded attempts", .{r.kept_for_records});
    if (r.kept_for_recovery > 0) try w.interface.print("; kept {d} that hold outputs a killed launch moved aside, which the next launch puts back", .{r.kept_for_recovery});
    if (opts.previous) try w.interface.print("; previous/ of {d} attempt(s), {d:.1} MiB", .{ r.previous, @as(f64, @floatFromInt(r.previous_bytes)) / 1048576.0 });
    if (r.failed > 0) try w.interface.print("; {d} could not be removed", .{r.failed});
    try w.interface.writeAll("\n");
    try w.interface.flush();
    return if (r.failed > 0) .failed else .ok;
}

fn cmdWatch(c: Ctx, args: []const [:0]const u8, summary: bool) !Exit {
    var wa: cli.Watch = .{ .summary = summary };
    if (try wa.parse(c.parser(), args)) |e| return e;
    const history = wa.history;
    const json = wa.json;
    const once = wa.once;
    const interval = wa.interval_ms;
    const launch = wa.launch;
    const color = wa.color and term.colorOn(1, c.env);
    const common = &wa.common;
    if (history != null and common.workdir == null) if (common.workflow) |w| if (!sys.exists(c.gpa, w))
        return fail("--history takes a whole number of launches, and no workflow file {s} exists", .{w});
    const root = (try rootOf(c, common)) orelse return .usage;
    if (history) |n| {
        const rec = try workz.records.recordsDir(c.a, root);
        if (try workz.records.latestLaunch(c.gpa, c.a, rec) == null) return failed("no launch recorded in {s}; kanit run starts one", .{rec});
        var buf: [16384]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
        try monitor.history(c.gpa, &w.interface, root, n);
        try w.interface.flush();
        return .ok;
    }
    const dir = (try monitor.findLaunch(c.gpa, c.a, root, launch)) orelse return .failed;
    const style: workz.log.Style = .{ .color = color, .marks = workz.log.marksFor(c.env), .cols = if (term.isTerminal(1)) term.size(1).cols else 0 };
    const ok = if (summary) try monitor.status(c.gpa, c.io, dir, !json and term.isTerminal(1), style) else try monitor.watch(c.gpa, c.io, dir, once, interval, color);
    return if (ok) .ok else .failed;
}

fn resolveLaunch(c: Ctx, rec: []const u8, name: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') == null) {
        const dir = try std.fs.path.join(c.a, &.{ rec, "launches", name });
        if (sys.exists(c.gpa, try std.fs.path.join(c.a, &.{ dir, "events.jsonl" }))) return dir;
    }
    const path = (try sys.realpath(c.a, name)) orelse return null;
    if (sys.exists(c.gpa, try std.fs.path.join(c.a, &.{ path, "events.jsonl" }))) return path;
    return workz.records.latestLaunch(c.gpa, c.a, try workz.records.recordsDir(c.a, path));
}

fn cmdReport(c: Ctx, args: []const [:0]const u8) !Exit {
    var ra: cli.Report = .{ .stdout_terminal = term.isTerminal(1) };
    if (try ra.parse(c.parser(), args)) |e| return e;
    const launch = ra.launch;
    const format = ra.format;
    const bottlenecks = ra.bottlenecks;
    const compare = ra.compare;
    const suggest = ra.suggest;
    const methods = ra.methods;
    const output = ra.output;
    const kind = ra.kind();
    const root = (try rootOf(c, &ra.common)) orelse return .usage;
    const rec = try workz.records.recordsDir(c.a, root);
    if (methods) {
        if (!sys.exists(c.gpa, rec)) return failed("no launch recorded in {s}; kanit run starts one", .{rec});
        const m = workz.methods.collect(c.gpa, c.a, root) catch |err| switch (err) {
            error.CorruptState, error.UnsupportedState => return stateFailed(c, err, root),
            else => return err,
        };
        if (m.rules == 0) return failed("no rule has completed in {s}; there are no results to describe", .{root});
        var text: std.Io.Writer.Allocating = .init(c.gpa);
        defer text.deinit();
        if (format != null and format.? == .json) try workz.methods.writeJson(&text.writer, m) else try workz.methods.writeText(&text.writer, m);
        if (output) |path| {
            sys.writeFileReplace(c.gpa, path, text.written()) catch |err| return failed("cannot write {s}: {s}", .{ path, sys.errorText(err) });
        } else try sys.writeAll(1, text.written());
        return .ok;
    }
    const dir = if (launch) |id| try std.fs.path.join(c.a, &.{ rec, "launches", id }) else (try workz.records.latestLaunch(c.gpa, c.a, rec)) orelse return failed("no launch recorded in {s}; kanit run starts one", .{rec});
    if (!sys.exists(c.gpa, dir)) return failed("no launch {s}", .{dir});
    if ((kind != .html or suggest) and workz.records.launchActive(c.gpa, dir))
        std.debug.print("kanit: launch {s} is still running; its attempts that have not ended have no record yet and are left out\n", .{std.fs.path.basename(dir)});
    if (kind == .html) if (output) |path| {
        var unread: std.ArrayList([]const u8) = .empty;
        workz.html.writeFile(c.gpa, c.a, path, dir, &unread) catch |err| return failed("cannot write {s}: {s}", .{ path, sys.errorText(err) });
        for (unread.items) |p| std.debug.print("kanit: {s} is not valid JSON; the report leaves it out\n", .{p});
        return if (unread.items.len > 0) .failed else .ok;
    };
    var text: std.Io.Writer.Allocating = .init(c.gpa);
    defer text.deinit();
    const w = &text.writer;
    var unread: std.ArrayList([]const u8) = .empty;
    if (suggest) {
        var l = try workz.model.load(c.gpa, c.a, dir);
        defer l.deinit();
        unread = l.unreadable;
        const table = kind == .tsv and output == null and term.isTerminal(1);
        try report.writeSuggestions(w, &l, if (kind == .json) .json else if (table) .table else .tsv);
    } else if (compare) |other| {
        const base = (try resolveLaunch(c, rec, other)) orelse return failed("no launch found for {s}", .{other});
        try report.writeCompare(c.gpa, c.a, w, base, dir, &unread);
    } else if (bottlenecks) {
        try report.writeBottlenecks(c.gpa, c.a, w, dir, &unread);
    } else switch (kind) {
        .html => try workz.html.write(c.gpa, c.a, w, dir, &unread),
        .json, .tsv => {
            const rows = try workz.model.attempts(c.gpa, c.a, dir, &unread);
            if (kind == .json) try report.writeJson(c.a, w, rows) else try report.writeTsv(w, rows);
            if (rows.len == 0 and unread.items.len == 0) try noAttempts(c, rec, dir, launch == null);
        },
    }
    for (unread.items) |p| std.debug.print("kanit: {s} is not valid JSON; the report leaves it out\n", .{p});
    const done: Exit = if (unread.items.len > 0) .failed else .ok;
    if (output) |path| {
        sys.writeFileReplace(c.gpa, path, text.written()) catch |err| return failed("cannot write {s}: {s}", .{ path, sys.errorText(err) });
        return done;
    }
    try sys.writeAll(1, text.written());
    return done;
}

fn cmdRun(c: Ctx, args: []const [:0]const u8) !Exit {
    var ra: cli.Run = .{};
    if (try ra.parse(c.parser(), args)) |e| return e;
    var opts = ra.opts;
    if (opts.input_manifest) |m| opts.input_manifest = try sys.absolute(c.a, try sys.cwd(c.a), m);
    if (opts.isolation and !try insideOwnScope(c)) return isolate(c, opts);
    var l = (try load(c, &ra.common)) orelse return .usage;
    defer l.deinit();
    if (try c.parser().applyThreads(&l.wf, ra.threads.items)) |e| return e;
    if (try c.parser().knownRules(&l.wf, ra.reruns.items)) |e| return e;
    const outcome = try run.execute(c.gpa, c.a, &l.wf, &l.g, l.mask, opts, c.env);
    return switch (outcome) {
        .ok => .ok,
        .failed => .failed,
        .invalid => .usage,
        .interrupted => .interrupted,
    };
}

fn insideOwnScope(c: Ctx) !bool {
    const stage = c.env.get("WORKZ_STAGE") orelse return false;
    if (!std.mem.startsWith(u8, stage, "inner:")) return false;
    const unit = stage["inner:".len..];
    const text = sys.readFile(c.gpa, "/proc/self/cgroup", 1 << 16) catch return false;
    defer c.gpa.free(text);
    const line = std.mem.trimEnd(u8, text, "\n");
    const scope = try std.fmt.allocPrint(c.a, "/{s}.scope", .{unit});
    return std.mem.startsWith(u8, line, "0::") and std.mem.endsWith(u8, line, scope);
}

fn isolate(c: Ctx, opts: run.Options) !Exit {
    const systemd_run = (try workz.process.findProgram(c.gpa, c.a, c.env.get("PATH") orelse "/usr/bin:/bin", "systemd-run")) orelse return fail("systemd-run not found; isolation needs a systemd user manager (or use --no-isolation)", .{});
    const threads = opts.max_threads orelse run.defaultThreads();
    var memory = opts.max_memory_mib orelse run.defaultMemoryMib(c.gpa);
    memory += 256;
    const exe = try sys.selfExe(c.a);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ systemd_run, "--user", "--scope", "--quiet" });
    const dollar = std.mem.indexOfScalar(u8, exe, '$') != null or for (c.argv[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '$') != null) break true;
    } else false;
    if (dollar) try argv.append(c.a, "--expand-environment=no");
    const unit = try std.fmt.allocPrint(c.a, "workz-{d}-{x}", .{ linux.getpid(), sys.realNs() });
    try argv.append(c.a, try std.fmt.allocPrint(c.a, "--unit={s}", .{unit}));
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
    while (it.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, "WORKZ_STAGE")) try env.append(c.a, try std.fmt.allocPrint(c.a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
    try env.append(c.a, try std.fmt.allocPrint(c.a, "WORKZ_STAGE=inner:{s}", .{unit}));
    const argv_z = try workz.process.Vec.init(c.a, argv.items);
    const env_z = try workz.process.Vec.init(c.a, env.items);
    const rc = linux.execve(try c.a.dupeZ(u8, systemd_run), argv_z.items.ptr, env_z.items.ptr);
    return fail("cannot start systemd-run: {s}", .{@tagName(linux.errno(rc))});
}

fn netns(args: []const [:0]const u8) Exit {
    const uid = linux.getuid();
    const gid = linux.getgid();
    var kill_fd: i32 = -1;
    if (args.len == 1) {
        const rc = linux.openat(linux.AT.FDCWD, args[0], .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return fail("cannot open {s}", .{args[0]});
        kill_fd = @intCast(rc);
    }
    var ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .INT, .TERM, .HUP }) |sig| _ = linux.sigaction(sig, &ignore, null);
    if (linux.errno(linux.unshare(linux.CLONE.NEWUSER | linux.CLONE.NEWNET)) != .SUCCESS) return fail("cannot create the run's network namespace", .{});
    var buf: [64]u8 = undefined;
    writeProc("/proc/self/setgroups", "deny") catch return fail("cannot deny setgroups", .{});
    writeProc("/proc/self/uid_map", std.fmt.bufPrint(&buf, "{d} {d} 1", .{ uid, uid }) catch unreachable) catch return fail("cannot map the user id", .{});
    writeProc("/proc/self/gid_map", std.fmt.bufPrint(&buf, "{d} {d} 1", .{ gid, gid }) catch unreachable) catch return fail("cannot map the group id", .{});
    const IfReq = extern struct { name: [16]u8, flags: i16, pad: [22]u8 };
    const sock = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(sock) == .SUCCESS) {
        var req: IfReq = std.mem.zeroes(IfReq);
        @memcpy(req.name[0..2], "lo");
        const fd: i32 = @intCast(sock);
        if (linux.errno(linux.ioctl(fd, linux.SIOCGIFFLAGS, @intFromPtr(&req))) == .SUCCESS) {
            const iff_up: i16 = 1;
            req.flags |= iff_up;
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

fn hold(paths: []const [:0]const u8) Exit {
    const gpa = std.heap.page_allocator;
    var files: std.ArrayList([]u8) = .empty;
    var entry: ?[]u8 = null;
    for (paths) |p| workz.state.listFiles(gpa, p, &files, &entry) catch return fail("cannot list shared input {s}", .{entry orelse p});
    var total: u64 = 0;
    for (files.items) |file| {
        const p = gpa.dupeZ(u8, file) catch return fail("out of memory listing shared input {s}", .{file});
        const fd_rc = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return fail("cannot open shared input {s}", .{p});
        const fd: i32 = @intCast(fd_rc);
        var s: linux.Statx = undefined;
        if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &s)) != .SUCCESS) return fail("cannot read shared input {s}", .{p});
        if (s.mode & linux.S.IFMT != linux.S.IFREG) return fail("shared input {s} is not a regular file", .{p});
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

fn noAttempts(c: Ctx, rec: []const u8, dir: []const u8, newest: bool) !void {
    const id = std.fs.path.basename(dir);
    var why: []const u8 = if (workz.records.launchActive(c.gpa, dir)) "none has ended yet" else "it ran no rule";
    if (sys.readFile(c.gpa, try std.fs.path.join(c.a, &.{ dir, "summary.json" }), workz.records.launch_record_max)) |text| {
        defer c.gpa.free(text);
        if (std.json.parseFromSliceLeaky(std.json.Value, c.a, text, .{ .allocate = .alloc_always })) |v| {
            if (workz.fields.str(v, "error")) |e| why = try std.fmt.allocPrint(c.a, "it was {s}: {s}", .{ workz.fields.str(v, "status") orelse "stopped", e });
        } else |_| {}
    } else |_| {}
    std.debug.print("kanit: launch {s} has no attempts; {s}\n", .{ id, why });
    if (!newest) return;
    const names = try workz.records.launchNames(c.gpa, c.a, rec);
    var k = names.len;
    while (k > 0) {
        k -= 1;
        const attempts = try std.fs.path.join(c.a, &.{ rec, "launches", names[k], "attempts" });
        const inside = (try sys.dirNames(c.gpa, c.a, attempts)) orelse continue;
        if (inside.len == 0) continue;
        std.debug.print("kanit: the newest launch that ran attempts is {s}: kanit report --launch {s}\n", .{ names[k], names[k] });
        return;
    }
}

fn graphProblem(c: Ctx, path: []const u8, root: []const u8, first: workflow.Problem) !workflow.Problem {
    var problem: workflow.Problem = .{};
    var wf = workflow.loadWithLines(c.gpa, path, root, &problem) catch |err| switch (err) {
        error.Invalid => {
            c.gpa.free(first.message);
            return problem;
        },
        else => return err,
    };
    defer wf.deinit();
    var g = graph.build(c.gpa, &wf, &problem) catch |err| switch (err) {
        error.Cycle, error.Invalid => {
            c.gpa.free(first.message);
            return problem;
        },
        else => return err,
    };
    g.deinit();
    c.gpa.free(problem.message);
    return first;
}
