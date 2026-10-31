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

// --- Help ---

const Group = enum { write, run, watch, maintain };

/// Which common options a command takes: the working directory, and the
/// target selection that only commands reading the workflow use.
const CommonOptions = enum { none, workdir, all };

/// One option as `help` lists it: its spellings and argument, and what it
/// does. The spellings before the argument also serve typo hints.
const Opt = struct { flag: []const u8, desc: []const u8 };

/// One command as `help` shows it; `examples` holds one command per line.
const Command = struct {
    name: []const u8,
    args: []const u8,
    summary: []const u8,
    group: Group,
    about: []const u8,
    options: []const Opt = &.{},
    examples: []const u8 = "",
    common: CommonOptions = .all,
};

const workdir_opt: Opt = .{ .flag = "-d, --workdir DIR", .desc = "working directory (default: the workflow's directory)" };
const target_opt: Opt = .{ .flag = "-t, --target RULE", .desc = "select RULE and the rules it depends on (repeatable)" };
const rerun_opts = [_]Opt{
    .{ .flag = "--rerun", .desc = "decide as 'run --rerun' would" },
    .{ .flag = "--rerun-rule RULE", .desc = "decide as 'run --rerun-rule RULE' would (repeatable)" },
    .{ .flag = "--input-manifest FILE", .desc = "decide as 'run --input-manifest FILE' would" },
    .{ .flag = "--pass-env NAME", .desc = "decide as 'run --pass-env NAME' would (repeatable)" },
    .{ .flag = "--threads STEP=N", .desc = "decide as 'run --threads STEP=N' would (repeatable)" },
};

const commands = [_]Command{
    .{
        .name = "init",
        .args = "[FILE] [--template]",
        .summary = "write a commented starter workflow or pipeline template",
        .group = .write,
        .common = .none,
        .about =
        \\Writes a commented starter workflow to FILE (default: workflow.toml) in the
        \\current directory. With --template, writes a pipeline template instead
        \\(default: pipeline.toml) and a samples.tsv beside it, for workz prepare. It
        \\never overwrites a file that exists.
        ,
        .options = &.{.{ .flag = "--template", .desc = "write a pipeline template and samples.tsv instead" }},
        .examples =
        \\workz init
        \\workz init rnaseq.toml
        \\workz init --template
        ,
    },
    .{
        .name = "prepare",
        .args = "[TEMPLATE] [-o WORKFLOW] [--check]",
        .summary = "write the workflow a pipeline template describes",
        .group = .write,
        .common = .none,
        .about =
        \\Compiles a pipeline template (default: pipeline.toml) into the explicit
        \\workflow the engine runs (default: workflow.toml beside it). Each [[steps]]
        \\entry is one rule, or with for_each = "sample" one rule per row of the
        \\sample sheet, named SAMPLE__STEP and labelled with its step and sample.
        \\{name} takes a sample-sheet column, a [params] value or the step name; in
        \\shell, {input}, {output} and {threads} name the rule's own. Other braces stay
        \\as written. The result is checked as validate would before it replaces the
        \\workflow; --check prints the rules it would add, remove and change, and
        \\exits 1 if any, without writing.
        ,
        .options = &.{
            .{ .flag = "-o, --output FILE", .desc = "the workflow to write (default: workflow.toml)" },
            .{ .flag = "--check", .desc = "compare with the current workflow; write nothing" },
        },
        .examples =
        \\workz prepare
        \\workz prepare --check
        \\workz prepare rnaseq.pipeline.toml -o rnaseq.toml
        ,
    },
    .{
        .name = "schema",
        .args = "",
        .summary = "print a JSON Schema of the workflow format, for editors",
        .group = .write,
        .common = .none,
        .about =
        \\Prints a JSON Schema of the workflow format: every table and key validate
        \\accepts, with its type and a line of help, and no other key. Editors that
        \\check TOML against a schema, such as Taplo and the Even Better TOML
        \\extension, then complete keys and mark mistakes as you type.
        ,
        .examples = "workz schema > workz.schema.json",
    },
    .{
        .name = "validate",
        .args = "[WORKFLOW]",
        .summary = "check a workflow: every key, every value and the graph",
        .group = .write,
        .about =
        \\Checks every key and value of WORKFLOW, the rule names, the declared outputs
        \\and the graph, lists every problem at once, and prints a one-line summary
        \\with notes on what is valid but likely a mistake. With --inputs it also lists
        \\the inputs that no rule writes and that do not exist; plan --budget checks
        \\the requests against the budget.
        ,
        .options = &.{.{ .flag = "--inputs", .desc = "also list inputs that exist nowhere; exit 1 if any" }},
        .examples =
        \\workz validate workflow.toml
        \\workz validate --inputs
        ,
    },
    .{
        .name = "plan",
        .args = "[WORKFLOW] [options]",
        .summary = "show which rules a run would run or reuse, and why",
        .group = .write,
        .about =
        \\Prints, for every selected rule, whether a run would run it or reuse it and
        \\why, then how many of each. Nothing runs. It exits 1 when run would refuse
        \\the launch: a missing input, an output changed outside workz, or an input
        \\that does not match --input-manifest.
        \\'dry-run' is another name for it.
        ,
        .options = &([_]Opt{ .{ .flag = "--summary", .desc = "count the decisions by reason instead" }, .{ .flag = "--budget", .desc = "check every request against the budget, as run does" }, .{ .flag = "--max-threads N", .desc = "the budget --budget checks (default: every online CPU)" }, .{ .flag = "--max-memory SIZE", .desc = "the budget --budget checks (default: 3/4 of RAM)" } } ++ rerun_opts),
        .examples =
        \\workz plan workflow.toml
        \\workz plan workflow.toml --summary
        \\workz plan workflow.toml --rerun-rule align_s1
        ,
    },
    .{
        .name = "explain",
        .args = "[WORKFLOW] RULE [options]",
        .summary = "show why one rule would run, part by part",
        .group = .write,
        .about =
        \\Shows the decision for RULE. For a rule with a record whose producers do not
        \\run, it also compares each part of its key with the record (command,
        \\environment, request, writes, inputs, producers, engine key) and says what
        \\changed.
        ,
        .options = &rerun_opts,
        .examples = "workz explain workflow.toml align_s1",
    },
    .{
        .name = "graph",
        .args = "[WORKFLOW] [options]",
        .summary = "show the rule graph in layers: rules, files, resources",
        .group = .write,
        .about =
        \\Shows the selected rules and what links them: as text on a terminal, as
        \\Graphviz DOT otherwise, or as JSON. The rules layer shows which rule feeds
        \\which and through what file; the files layer puts the files between them; the
        \\resources layer adds each shared input, held once, with the rules that write
        \\what it loads and the rules that use it, and the resource groups.
        ,
        .options = &.{
            .{ .flag = "--layer LAYER", .desc = "rules, files, resources or all (default: rules)" },
            .{ .flag = "--by step", .desc = "one node per step instead of per rule" },
            .{ .flag = "--focus EXPR", .desc = "+RULE up, RULE+ down, +RULE+ both, 2+RULE two levels" },
            .{ .flag = "--why FROM:TO", .desc = "one path of rules from FROM to TO" },
            .{ .flag = "--users NAME", .desc = "a shared input, what writes it and what uses it" },
            .{ .flag = "--format FORMAT", .desc = "text, dot or json (default: text on a terminal)" },
        },
        .examples =
        \\workz graph --layer resources --by step
        \\workz graph --users genome
        \\workz graph --why trim_S1:report
        \\workz graph --focus +report --format dot > report.dot
        ,
    },
    .{
        .name = "run",
        .args = "[WORKFLOW] [options]",
        .summary = "run the rules that need to run",
        .group = .run,
        .about =
        \\Runs the selected rules that are not reusable, within a budget of threads,
        \\memory and jobs, each attempt in its own cgroup inside a systemd user scope.
        \\Progress goes to standard error and the summary to standard output, as text
        \\on a terminal and as JSON otherwise. Every attempt is recorded in .workz/ in
        \\the working directory.
        ,
        .options = &.{
            .{ .flag = "--max-threads N", .desc = "CPU budget in threads (default: every online CPU)" },
            .{ .flag = "--max-memory SIZE", .desc = "memory budget, such as 60G (default: 3/4 of RAM)" },
            .{ .flag = "-j, --jobs N", .desc = "at most N rules at once (default: --max-threads)" },
            .{ .flag = "-k, --keep-going", .desc = "keep running independent rules after a failure" },
            .{ .flag = "-r, --retry N", .desc = "retries of rules that set none, 0 to 3 (default: 0)" },
            .{ .flag = "--timeout DURATION", .desc = "time limit of rules that set none, such as 2h" },
            .{ .flag = "--rerun", .desc = "run every selected rule, even when reusable" },
            .{ .flag = "--rerun-rule RULE", .desc = "run RULE even when reusable (repeatable)" },
            .{ .flag = "--input-manifest FILE", .desc = "check external inputs against digests first" },
            .{ .flag = "--pass-env NAME", .desc = "pass and key a variable; recorded, so not for secrets" },
            .{ .flag = "--threads STEP=N", .desc = "N threads for STEP's rules, this launch (repeatable)" },
            .{ .flag = "--grace DURATION", .desc = "wait before killing a stopped rule (default: 10s)" },
            .{ .flag = "--slice NAME.slice", .desc = "place the run's scope in this systemd slice" },
            .{ .flag = "--no-isolation", .desc = "no scope, cgroups or network namespace" },
            .{ .flag = "-q, --quiet", .desc = "no progress lines; failures still print" },
            .{ .flag = "--json", .desc = "print the summary as JSON, also on a terminal" },
            .{ .flag = "--no-color", .desc = "no colors on a terminal (as does NO_COLOR)" },
        },
        .examples =
        \\workz run workflow.toml --max-threads 16 --max-memory 60G
        \\workz run workflow.toml --target align_s1 --keep-going
        \\workz run workflow.toml --rerun-rule align_s1
        ,
    },
    .{
        .name = "control",
        .args = "[WORKFLOW] stop RULE | retry RULE | cancel",
        .summary = "stop or retry a rule, or cancel, in the running launch",
        .group = .run,
        .common = .workdir,
        .about =
        \\Sends a command to the newest launch of the working directory while it runs.
        \\'stop' cancels RULE and blocks the rules that depend on it; 'retry' runs a
        \\failed or stopped RULE again with its blocked dependents; 'cancel' stops the
        \\launch like an interrupt.
        ,
        .examples =
        \\workz control stop align_s3
        \\workz control retry align_s3
        \\workz control cancel
        ,
    },
    .{
        .name = "watch",
        .args = "[WORKFLOW] [options]",
        .summary = "follow the newest launch in a live view",
        .group = .watch,
        .common = .workdir,
        .about =
        \\Shows the newest launch of the working directory, or --launch ID, while it
        \\runs and after it ends. On a terminal the view is interactive; press ? there
        \\for its keys.
        \\Elsewhere it prints a plain view every --interval until the launch ends;
        \\with --once it prints one and exits.
        ,
        .options = &.{
            .{ .flag = "--once", .desc = "print one plain view and exit" },
            .{ .flag = "--launch ID", .desc = "a launch other than the newest" },
            .{ .flag = "--interval MS", .desc = "refresh period in ms, at least 100 (default: 1000)" },
            .{ .flag = "--no-color", .desc = "no colors on a terminal (as does NO_COLOR)" },
        },
        .examples =
        \\workz watch
        \\workz watch path/to/workflow.toml
        ,
    },
    .{
        .name = "status",
        .args = "[WORKFLOW] [options]",
        .summary = "summarize the newest launch, or the recent ones",
        .group = .watch,
        .common = .workdir,
        .about =
        \\Prints the summary of the newest launch, or of --launch ID, once it has
        \\ended. On a terminal the summary is a short readable report; elsewhere,
        \\and with --json, it is the launch's summary.json. While the launch runs, it
        \\prints a plain view, or as JSON the counts so far with status "running".
        \\
        \\--history counts, per launch, the rules DONE (completed or reused),
        \\FAILED (failed or blocked) and CANCELLED (stopped or never started).
        \\
        \\status exits 0 for any outcome it shows, and 1 when it has none to show: no
        \\launch, a summary that cannot be read, or a launch whose engine died.
        ,
        .options = &.{
            .{ .flag = "--history [N]", .desc = "one line for each of the last N launches (default: 10)" },
            .{ .flag = "--launch ID", .desc = "a launch other than the newest" },
            .{ .flag = "--json", .desc = "print summary.json, also on a terminal" },
            .{ .flag = "--no-color", .desc = "no colors on a terminal (as does NO_COLOR)" },
        },
        .examples =
        \\workz status
        \\workz status --history 5
        ,
    },
    .{
        .name = "logs",
        .args = "[WORKFLOW] RULE [options]",
        .summary = "print the output of a rule's newest attempt",
        .group = .watch,
        .common = .workdir,
        .about =
        \\Prints the standard output and error of RULE's newest attempt: in the newest
        \\launch that ran it, else the attempt recorded for it.
        ,
        .options = &.{
            .{ .flag = "--stdout", .desc = "standard output only" },
            .{ .flag = "--stderr", .desc = "standard error only" },
            .{ .flag = "--attempt N", .desc = "attempt N instead of the newest" },
            .{ .flag = "--launch ID", .desc = "look in this launch" },
            .{ .flag = "-f, --follow", .desc = "keep printing until the attempt ends" },
        },
        .examples =
        \\workz logs align_s1
        \\workz logs align_s1 --stderr --follow
        \\workz logs trim_s4 --attempt 1
        ,
    },
    .{
        .name = "report",
        .args = "[WORKFLOW] [options]",
        .summary = "show what each attempt used and what limited a launch",
        .group = .watch,
        .common = .workdir,
        .about =
        \\Reports on the newest launch, or on --launch ID. Without a report option it
        \\prints one row per attempt: TSV by default, JSON with --format json, or the
        \\launch as one self-contained HTML page with --format html. --suggest prints
        \\a table on a terminal, TSV to a file or a pipe, or JSON; --bottlenecks and
        \\--compare print text. --methods describes the results recorded in the
        \\working directory, across the launches that made them: workflow, engine,
        \\each tool with its version and image, and each step's request and command;
        \\text, or JSON with --format json.
        ,
        .options = &.{
            .{ .flag = "--bottlenecks", .desc = "critical path, waiting, request sizing, utilization" },
            .{ .flag = "--suggest", .desc = "suggested threads and memory per step" },
            .{ .flag = "--compare OTHER", .desc = "compare with a launch ID, launch directory or workdir" },
            .{ .flag = "--methods", .desc = "tools, versions, images and commands of the results" },
            .{ .flag = "--format FORMAT", .desc = "tsv, json or html, a self-contained page (default: tsv)" },
            .{ .flag = "--json", .desc = "the same as --format json" },
            .{ .flag = "--launch ID", .desc = "a launch other than the newest" },
            .{ .flag = "-o, --output FILE", .desc = "write to FILE instead of standard output" },
        },
        .examples =
        \\workz report --bottlenecks
        \\workz report --format html -o report.html
        \\workz report --compare 20261026T033653.780-bb9b10ee
        \\workz report --methods -o methods.txt
        ,
    },
    .{
        .name = "verify",
        .args = "[WORKFLOW] [--content]",
        .summary = "check that recorded outputs are unchanged",
        .group = .maintain,
        .about =
        \\Checks that every recorded output of the selected rules still has the
        \\identity workz recorded. With --content it also compares the bytes with
        \\stored digests, and stores a digest for every output that has none. It
        \\exits 1 on a difference, or when a selected rule has no record to check.
        ,
        .options = &.{.{ .flag = "--content", .desc = "also compare and store content digests" }},
        .examples = "workz verify workflow.toml --content",
    },
    .{
        .name = "clean",
        .args = "[WORKFLOW] [options]",
        .summary = "remove leftover containers, old launches and replaced outputs",
        .group = .maintain,
        .common = .workdir,
        .about =
        \\Removes the containers that earlier launches of the working directory left
        \\behind. With --keep N it also removes all but the newest N launch
        \\directories, keeping every launch that holds a rule's recorded attempt.
        \\With --previous it removes the earlier outputs that reruns moved into
        \\previous/, the only copy of those bytes.
        ,
        .options = &.{
            .{ .flag = "--keep N", .desc = "keep the newest N launches and the recorded ones" },
            .{ .flag = "--previous", .desc = "remove the replaced outputs kept in previous/" },
            .{ .flag = "--dry-run", .desc = "show what would be removed" },
        },
        .examples =
        \\workz clean --keep 5 --dry-run
        \\workz clean --previous --dry-run
        ,
    },
    .{
        .name = "completion",
        .args = "bash",
        .summary = "print a bash completion script",
        .group = .maintain,
        .common = .none,
        .about =
        \\Prints a bash completion script for commands, options and rule names. Load it
        \\in the current shell with: source <(workz completion bash)
        ,
    },
    .{
        .name = "help",
        .args = "[COMMAND]",
        .summary = "show help for workz or for one command",
        .group = .maintain,
        .common = .none,
        .about = "Shows the commands of workz, or the options and examples of COMMAND.",
    },
    .{
        .name = "version",
        .args = "",
        .summary = "print the version",
        .group = .maintain,
        .common = .none,
        .about = "Prints the version of workz.",
    },
};

const group_titles = [_][]const u8{ "Write and check a workflow", "Run", "Watch and inspect", "Maintain" };

fn command(name: []const u8) ?*const Command {
    const eql = std.mem.eql;
    const want = if (eql(u8, name, "dry-run")) "plan" else name;
    for (&commands) |*c| if (eql(u8, c.name, want)) return c;
    return null;
}

/// The closest of `allowed` to a mistyped `word`, if it is close enough to
/// be the one meant: at most a third of the word's letters differ.
fn didYouMean(allowed: []const []const u8, word: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = @max(word.len / 3, 1) + 1;
    for (allowed) |cand| {
        // One-letter flags are too short for a typo to point anywhere.
        if (word.len <= 2 and cand.len <= 2) continue;
        const d = workflow.editDistance(cand, word);
        if (d < best_d) {
            best_d = d;
            best = cand;
        }
    }
    return best;
}

/// The option spellings of a command, with the common ones it takes.
fn optionNames(a: std.mem.Allocator, c: *const Command) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const common: []const Opt = switch (c.common) {
        .none => &.{},
        .workdir => &.{workdir_opt},
        .all => &.{ workdir_opt, target_opt },
    };
    for ([_][]const Opt{ c.options, common }) |list| for (list) |o| {
        var it = std.mem.tokenizeAny(u8, o.flag, ", ");
        while (it.next()) |word| if (word[0] == '-') try names.append(a, word);
    };
    return names.items;
}

/// The list of commands, grouped by job.
fn writeOverview(w: *std.Io.Writer, s: term.Style) !void {
    try w.print("{s}workz {s}{s} runs a prepared graph of file-producing rules on one Linux\nworkstation.\n\n", .{ s.bold(), workz.version, s.reset() });
    try w.print("{s}usage:{s} workz <command> [options]\n", .{ s.bold(), s.reset() });
    for (group_titles, 0..) |title, gi| {
        try w.print("\n{s}{s}:{s}\n", .{ s.bold(), title, s.reset() });
        for (commands) |c| {
            if (@intFromEnum(c.group) != gi) continue;
            try w.print("  {s}{s:<12}{s}{s}\n", .{ s.cyan(), c.name, s.reset(), c.summary });
        }
    }
    try w.print("\nWORKFLOW, where a command takes one, defaults to {s} in the current\ndirectory.\n", .{default_workflow});
    try w.print("Run '{s}workz help COMMAND{s}' for a command's usage, options and examples.\n", .{ s.bold(), s.reset() });
}

fn writeOptions(w: *std.Io.Writer, title: []const u8, list: []const Opt, s: term.Style) !void {
    if (list.len == 0) return;
    try w.print("\n{s}{s}:{s}\n", .{ s.bold(), title, s.reset() });
    for (list) |o| try w.print("  {s}{s:<23}{s}{s}\n", .{ s.cyan(), o.flag, s.reset(), o.desc });
}

/// The usage, options and examples of one command.
fn writeCommandHelp(w: *std.Io.Writer, c: *const Command, s: term.Style) !void {
    try w.print("{s}usage:{s} workz {s}{s}{s}\n\n{s}\n", .{ s.bold(), s.reset(), c.name, if (c.args.len > 0) " " else "", c.args, c.about });
    try writeOptions(w, "options", c.options, s);
    try writeOptions(w, "common options", switch (c.common) {
        .none => &.{},
        .workdir => &.{workdir_opt},
        .all => &.{ workdir_opt, target_opt },
    }, s);
    if (c.examples.len > 0) {
        try w.print("\n{s}examples:{s}\n", .{ s.bold(), s.reset() });
        var it = std.mem.splitScalar(u8, c.examples, '\n');
        while (it.next()) |line| try w.print("  {s}\n", .{line});
    }
}

fn cmdHelp(c: Ctx, args: []const []const u8) !Exit {
    const s: term.Style = .{ .on = term.colorOn(1, c.env) };
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    if (args.len == 0) {
        try writeOverview(&w.interface, s);
    } else {
        const cmd = command(args[0]) orelse return unknownCommand(args[0]);
        try writeCommandHelp(&w.interface, cmd, s);
    }
    try w.interface.flush();
    return .ok;
}

fn unknownCommand(name: []const u8) Exit {
    var names: [commands.len + 1][]const u8 = undefined;
    for (commands, 0..) |c, i| names[i] = c.name;
    names[commands.len] = "dry-run";
    if (didYouMean(&names, name)) |hint| {
        std.debug.print("workz: unknown command '{s}'; did you mean '{s}'?\nRun 'workz help' for the commands.\n", .{ name, hint });
    } else std.debug.print("workz: unknown command '{s}'\nRun 'workz help' for the commands.\n", .{name});
    return .usage;
}

// --- Errors ---

const Exit = enum(u8) { ok = 0, failed = 1, usage = 2, interrupted = 130, _ };

/// An invalid command line or workflow: exit status 2.
fn fail(comptime fmt: []const u8, args: anytype) Exit {
    std.debug.print("workz: " ++ fmt ++ "\n", args);
    return .usage;
}

/// Nothing to show or act on, or a state that stops the command: exit
/// status 1.
fn failed(comptime fmt: []const u8, args: anytype) Exit {
    std.debug.print("workz: " ++ fmt ++ "\n", args);
    return .failed;
}

/// A `state.json` that cannot be used stops the command with what to do,
/// exit status 1; any other error goes on.
fn stateFailed(c: Ctx, err: anyerror, root: []const u8) !Exit {
    const path = try std.fs.path.join(c.a, &.{ root, ".workz", "state.json" });
    const why = (try state.loadErrorText(c.a, err, path)) orelse return err;
    return failed("{s}", .{why});
}

/// An input whose identity cannot be read is a workflow problem, exit
/// status 2; any other error goes on.
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
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) {
        var buf: [8192]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(init.io, &buf);
        try writeOverview(&w.interface, .{ .on = false });
        try w.interface.flush();
        return @intFromEnum(Exit.usage);
    }
    // Debug builds keep the leak-checking allocator; shipped builds use the
    // caching SMP allocator, which avoids a map and unmap per allocation.
    const gpa = if (@import("builtin").mode == .Debug) init.gpa else std.heap.smp_allocator;
    const ctx: Ctx = .{ .gpa = gpa, .a = a, .io = init.io, .env = init.environ_map, .argv = args };
    const cmd = args[1];
    const rest = args[2..];
    const eq = std.mem.eql;
    // `COMMAND --help` and `COMMAND -h` show that command's help.
    if (command(cmd) != null) for (rest) |arg| {
        if (eq(u8, arg, "--help") or eq(u8, arg, "-h")) return @intFromEnum(try cmdHelp(ctx, &.{cmd}));
    };
    const code: Exit = if ((eq(u8, cmd, "version") or eq(u8, cmd, "--version")) and rest.len > 0) fail("version takes no arguments; run workz version", .{}) else if (eq(u8, cmd, "version") or eq(u8, cmd, "--version")) blk: {
        try out(init.io, "workz {s}\n", .{workz.version});
        break :blk .ok;
    } else if (eq(u8, cmd, "help") or eq(u8, cmd, "--help") or eq(u8, cmd, "-h")) try cmdHelp(ctx, rest) else if (eq(u8, cmd, "validate")) try cmdValidate(ctx, rest) else if (eq(u8, cmd, "graph")) try cmdGraph(ctx, rest) else if (eq(u8, cmd, "plan") or eq(u8, cmd, "dry-run")) try cmdPlan(ctx, rest, null) else if (eq(u8, cmd, "explain")) try cmdExplain(ctx, rest) else if (eq(u8, cmd, "verify")) try cmdVerify(ctx, rest) else if (eq(u8, cmd, "run")) try cmdRun(ctx, rest) else if (eq(u8, cmd, "watch")) try cmdWatch(ctx, rest, false) else if (eq(u8, cmd, "status")) try cmdWatch(ctx, rest, true) else if (eq(u8, cmd, "report")) try cmdReport(ctx, rest) else if (eq(u8, cmd, "clean")) try cmdClean(ctx, rest) else if (eq(u8, cmd, "logs")) try cmdLogs(ctx, rest) else if (eq(u8, cmd, "init")) try cmdInit(ctx, rest) else if (eq(u8, cmd, "schema")) try cmdSchema(ctx, rest) else if (eq(u8, cmd, "prepare")) try cmdPrepare(ctx, rest) else if (eq(u8, cmd, "control")) try cmdControl(ctx, rest) else if (eq(u8, cmd, "completion")) try cmdCompletion(ctx, rest) else if (eq(u8, cmd, "__rules")) try cmdRules(ctx, rest) else if (eq(u8, cmd, "__hold")) hold(rest) else if (eq(u8, cmd, "__netns")) netns(rest) else if (eq(u8, cmd, "__guard")) guard() else unknownCommand(cmd);
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
fn parseArgs(ctx: Ctx, args: []const [:0]const u8, c: *Common, extra: anytype) !?Exit {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // The next word is this option's value unless it is an option
        // itself: `--launch --format html` lacks the launch. A lone `-` and a
        // negative number are values.
        const next: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        const value: ?[]const u8 = if (next) |n| (if (n.len > 1 and n[0] == '-' and !std.ascii.isDigit(n[1])) null else n) else null;
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--workdir")) {
            c.workdir = value orelse return fail("{s} needs a value", .{arg});
            i += 1;
        } else if ((std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--target")) and takesTargets(ctx)) {
            try c.targets.append(ctx.a, value orelse return fail("{s} needs a value", .{arg}));
            i += 1;
        } else if (arg.len > 1 and arg[0] == '-') {
            const used = try extra.option(arg, value);
            if (used == 0) return try unknownOption(ctx, arg);
            if (used == std.math.maxInt(usize)) return .usage;
            i += used - 1;
        } else if (c.workflow == null) {
            c.workflow = arg;
        } else try c.positional.append(ctx.a, arg);
    }
    return null;
}

/// Whether the command selects rules with `--target`.
fn takesTargets(ctx: Ctx) bool {
    const cmd = command(ctx.argv[1]) orelse return true;
    return cmd.common == .all;
}

/// An option the command does not take, with the one probably meant.
fn unknownOption(ctx: Ctx, arg: []const u8) !Exit {
    const name = ctx.argv[1];
    const cmd = command(name) orelse return fail("unknown option '{s}'", .{arg});
    if (didYouMean(try optionNames(ctx.a, cmd), arg)) |hint| {
        std.debug.print("workz: unknown option '{s}' for {s}; did you mean '{s}'?\n", .{ arg, cmd.name, hint });
    } else std.debug.print("workz: unknown option '{s}' for {s}\n", .{ arg, cmd.name });
    std.debug.print("Run 'workz help {s}' for its options.\n", .{cmd.name});
    return .usage;
}

/// A word left after a command that takes no more than WORKFLOW.
fn extraArgs(ctx: Ctx, common: *const Common) ?Exit {
    if (common.positional.items.len == 0) return null;
    return fail("unexpected argument '{s}'; run 'workz help {s}' for the usage", .{ common.positional.items[0], ctx.argv[1] });
}

/// A name `--pass-env` can pass: a letter or `_`, then letters, digits and `_`.
fn envName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

/// An option given without the value it takes.
fn missingValue(arg: []const u8) usize {
    std.debug.print("workz: {s} needs a value\n", .{arg});
    return std.math.maxInt(usize);
}

/// An option value that does not parse; `hint` says what is expected.
fn invalidValue(arg: []const u8, value: []const u8, hint: []const u8) usize {
    std.debug.print("workz: {s}: invalid value '{s}' ({s})\n", .{ arg, value, hint });
    return std.math.maxInt(usize);
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
    // A WORKFLOW names its working directory, so it must exist.
    if (common.workdir == null) if (common.workflow) |w| if (!sys.exists(c.gpa, w)) {
        std.debug.print("workz: no workflow file {s}; -d DIR names a working directory\n", .{w});
        return null;
    };
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

/// Prints what is wrong with a workflow: one problem as one line, several
/// under their count, then the source line of the first.
fn printProblems(c: Ctx, wpath: []const u8, wf_abs: []const u8, problem: workflow.Problem) void {
    if (problem.count <= 1) {
        std.debug.print("workz: {s}: {s}\n", .{ wpath, problem.message });
    } else {
        std.debug.print("workz: {s}: {d} problems\n", .{ wpath, problem.count });
        var lines = std.mem.splitScalar(u8, problem.message, '\n');
        while (lines.next()) |line| std.debug.print("  {s}\n", .{line});
        if (problem.count > workflow.Problem.max_listed) std.debug.print("  and {d} more\n", .{problem.count - workflow.Problem.max_listed});
    }
    showSnippet(c, wf_abs, problem);
}

/// Loads, checks and selects; prints the reason and returns null when invalid.
fn load(c: Ctx, common: *const Common) !?Loaded {
    const wpath = common.workflow orelse default: {
        if (sys.exists(c.gpa, default_workflow)) break :default default_workflow;
        std.debug.print("workz: no workflow file given, and no {s} in this directory\n", .{default_workflow});
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
            printProblems(c, wpath, wf_abs, problem);
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
            var names: std.ArrayList([]const u8) = .empty;
            for (wf.rules) |r| try names.append(c.a, r.name);
            if (workflow.closest(names.items, unknown.?)) |hint| {
                std.debug.print("workz: unknown target '{s}'; did you mean '{s}'?\n", .{ unknown.?, hint });
            } else std.debug.print("workz: unknown target '{s}': no rule of {s} has that name\n", .{ unknown.?, wpath });
            g.deinit();
            wf.deinit();
            return null;
        },
        else => return err,
    };
    return .{ .wf = wf, .g = g, .mask = mask };
}

const ValidateExtra = struct {
    inputs: *bool,
    fn option(self: ValidateExtra, arg: []const u8, _: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--inputs")) {
            self.inputs.* = true;
            return 1;
        }
        return 0;
    }
};

fn cmdValidate(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var inputs = false;
    if (try parseArgs(c, args, &common, ValidateExtra{ .inputs = &inputs })) |e| return e;
    if (extraArgs(c, &common)) |e| return e;
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    var selected: usize = 0;
    for (l.mask) |m| selected += @intFromBool(m);
    var text: std.Io.Writer.Allocating = .init(c.gpa);
    defer text.deinit();
    const w = &text.writer;
    try w.print("valid: {s} ({d} rules, {d} selected, {d} groups, {d} shared)\n", .{ l.wf.name, l.wf.rules.len, selected, l.wf.groups.len, l.wf.shared.len });
    try workz.lint.notes(c.a, w, &l.wf, l.mask);
    var missing: usize = 0;
    if (inputs) missing = try workz.lint.missingInputs(c.gpa, w, &l.wf, &l.g, l.mask);
    try sys.writeAll(1, text.written());
    return if (missing > 0) .failed else .ok;
}

const GraphExtra = struct {
    opts: *workz.views.Options,
    format: *?workz.views.Format,
    fn option(self: GraphExtra, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        if (eq(u8, arg, "--by")) {
            const v = value orelse return missingValue(arg);
            if (!eq(u8, v, "step")) return invalidValue(arg, v, "use step");
            self.opts.by_step = true;
            return 2;
        }
        if (eq(u8, arg, "--layer")) {
            const v = value orelse return missingValue(arg);
            self.opts.layer = std.meta.stringToEnum(workz.views.Layer, v) orelse return invalidValue(arg, v, "use rules, files, resources or all");
            return 2;
        }
        if (eq(u8, arg, "--format")) {
            const v = value orelse return missingValue(arg);
            self.format.* = std.meta.stringToEnum(workz.views.Format, v) orelse return invalidValue(arg, v, "use dot, json or text");
            return 2;
        }
        if (eq(u8, arg, "--focus")) {
            const v = value orelse return missingValue(arg);
            self.opts.focus = workz.views.Focus.parse(v) orelse return invalidValue(arg, v, "use +RULE, RULE+, +RULE+, or a depth such as 2+RULE");
            return 2;
        }
        if (eq(u8, arg, "--why")) {
            const v = value orelse return missingValue(arg);
            const colon = std.mem.indexOfScalar(u8, v, ':') orelse return invalidValue(arg, v, "use FROM:TO, two rule names");
            self.opts.why = .{ v[0..colon], v[colon + 1 ..] };
            return 2;
        }
        if (eq(u8, arg, "--users")) {
            self.opts.users = value orelse return missingValue(arg);
            return 2;
        }
        return 0;
    }
};

fn cmdGraph(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var opts: workz.views.Options = .{};
    var format: ?workz.views.Format = null;
    if (try parseArgs(c, args, &common, GraphExtra{ .opts = &opts, .format = &format })) |e| return e;
    if (extraArgs(c, &common)) |e| return e;
    if (@as(u8, @intFromBool(opts.focus != null)) + @intFromBool(opts.why != null) + @intFromBool(opts.users != null) > 1)
        return fail("choose one of --focus, --why and --users", .{});
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    // A terminal gets text; a file or a pipe gets DOT, for Graphviz.
    const kind = format orelse if (term.isTerminal(1)) workz.views.Format.text else .dot;
    var text: std.Io.Writer.Allocating = .init(c.gpa);
    defer text.deinit();
    const v = workz.views.build(c.a, &l.wf, &l.g, l.mask, opts) catch |err| switch (err) {
        error.UnknownRule => return fail("no rule named {s} in {s}", .{ if (opts.focus) |f| f.rule else if (opts.why) |p| if (l.wf.ruleIndex(p[0]) == null) p[0] else p[1] else "?", l.wf.path }),
        error.UnknownShared => return fail("no shared input named {s} in {s}", .{ opts.users.?, l.wf.path }),
        error.NoPath => return failed("{s} does not lead to {s}: no rule between them reads what the one before writes", .{ opts.why.?[0], opts.why.?[1] }),
        else => return err,
    };
    switch (kind) {
        .dot => try workz.views.writeDot(c.a, &text.writer, l.wf.name, v),
        .json => try workz.views.writeJson(&text.writer, v),
        .text => if (opts.why) |p|
            try workz.views.writeWhy(&text.writer, &l.wf, &l.g, try workz.views.whyPath(c.a, &l.wf, &l.g, p[0], p[1]))
        else
            try workz.views.writeText(c.a, &text.writer, v),
    }
    try sys.writeAll(1, text.written());
    return .ok;
}

const PlanExtra = struct {
    rerun: *bool,
    summary: ?*bool = null,
    /// `--budget` and the budget it checks, for `plan` only.
    budget: ?*bool = null,
    max_threads: ?*?u32 = null,
    max_memory: ?*?u64 = null,
    /// `--input-manifest`, for `plan` only.
    manifest: ?*?[]const u8 = null,
    pass: *std.ArrayList([]const u8),
    threads: *std.ArrayList([]const u8),
    reruns: *std.ArrayList([]const u8),
    a: std.mem.Allocator,
    fn option(self: PlanExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--rerun-rule")) {
            try self.reruns.append(self.a, value orelse return missingValue(arg));
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
        if (std.mem.eql(u8, arg, "--threads")) {
            try self.threads.append(self.a, value orelse return missingValue(arg));
            return 2;
        }
        if (self.budget) |b| if (std.mem.eql(u8, arg, "--budget")) {
            b.* = true;
            return 1;
        };
        if (self.max_threads) |t| if (std.mem.eql(u8, arg, "--max-threads")) {
            const v = value orelse return missingValue(arg);
            t.* = std.fmt.parseInt(u32, v, 10) catch return invalidValue(arg, v, "use a whole number above 0");
            if (t.*.? == 0) return invalidValue(arg, v, "use a whole number above 0");
            return 2;
        };
        if (self.max_memory) |m| if (std.mem.eql(u8, arg, "--max-memory")) {
            const v = value orelse return missingValue(arg);
            m.* = workflow.parseMemoryMib(v) orelse return invalidValue(arg, v, "use a size such as 512M or 60G, at most 1024T");
            return 2;
        };
        if (self.manifest) |m| if (std.mem.eql(u8, arg, "--input-manifest")) {
            m.* = value orelse return missingValue(arg);
            return 2;
        };
        if (std.mem.eql(u8, arg, "--pass-env")) {
            const v = value orelse return missingValue(arg);
            if (!envName(v)) return invalidValue(arg, v, "use a variable name such as HOME");
            try self.pass.append(self.a, v);
            return 2;
        }
        return 0;
    }
};

/// Checks `--input-manifest` as `run` would, without writing the digests it
/// computes: they decide the keys of the inputs they cover. Whether every
/// input matches; null when the manifest cannot be used.
fn checkPlanManifest(c: Ctx, st: *state.State, ids: *state.Identities, manifest: ?[]const u8) !?bool {
    const m = manifest orelse return true;
    const check = try run.checkManifest(c.gpa, st, ids, try sys.absolute(c.a, try sys.cwd(c.a), m), false);
    return if (check.usable) check.ok else null;
}

/// Decisions read the records as they are; a launch still running records
/// each rule only once it ends.
fn noteLiveLaunch(c: Ctx, root: []const u8) !void {
    const rec = try workz.records.recordsDir(c.a, root);
    if (workz.records.running(c.gpa, rec)) std.debug.print("workz: a launch is running in {s}; rules it has not finished show their earlier records\n", .{root});
}

fn planContext(c: Ctx, l: *Loaded, st: *state.State, ids: *state.Identities, pass: []const []const u8) !plan.Context {
    var ctx = try plan.Context.init(c.gpa, c.a, &l.wf, &l.g, st, ids, try state.envText(c.a, c.env, pass), c.env);
    ctx.pass_env = pass;
    return ctx;
}

fn cmdPlan(c: Ctx, args: []const [:0]const u8, _: ?void) !Exit {
    var common: Common = .{};
    var rerun = false;
    var pass: std.ArrayList([]const u8) = .empty;
    var reruns: std.ArrayList([]const u8) = .empty;
    var summary = false;
    var threads: std.ArrayList([]const u8) = .empty;
    var budget = false;
    var max_threads: ?u32 = null;
    var max_memory: ?u64 = null;
    var manifest: ?[]const u8 = null;
    if (try parseArgs(c, args, &common, PlanExtra{ .rerun = &rerun, .summary = &summary, .pass = &pass, .threads = &threads, .reruns = &reruns, .a = c.a, .budget = &budget, .max_threads = &max_threads, .max_memory = &max_memory, .manifest = &manifest })) |e| return e;
    if (!budget and (max_threads != null or max_memory != null))
        return fail("{s} sets the budget --budget checks; give --budget too", .{if (max_threads != null) "--max-threads" else "--max-memory"});
    if (extraArgs(c, &common)) |e| return e;
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    if (applyThreads(&l.wf, threads.items)) |e| return e;
    var st = plan.loadState(c.gpa, l.wf.root, c.a) catch |err| return stateFailed(c, err, l.wf.root);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var ctx = planContext(c, &l, &st, &ids, pass.items) catch |err| return unreadable(err, &ids);
    try noteLiveLaunch(c, l.wf.root);
    ctx.rerun = rerun;
    ctx.rerun_rules = reruns.items;
    if (!try knownRules(c.a, &l.wf, reruns.items)) return .usage;
    const manifest_ok = (try checkPlanManifest(c, &st, &ids, manifest)) orelse return .usage;
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const ds = ctx.decideAll(l.mask) catch |err| return unreadable(err, &ids);
    try (if (summary) plan.printSummary(&w.interface, &ctx, ds, l.mask) else plan.printPlan(&w.interface, &ctx, ds, l.mask));
    var refused: usize = 0;
    // What `run` would refuse makes the plan fail too, so `plan && run`
    // stops at the plan.
    var missing: usize = 0;
    var changed: usize = 0;
    for (ds, l.mask) |d, m| if (m and d.run) {
        if (std.mem.startsWith(u8, d.reason, "input missing")) missing += 1;
        if (std.mem.startsWith(u8, d.reason, "output changed")) changed += 1;
    };
    if (missing + changed > 0) {
        refused += missing + changed;
        std.debug.print("workz: run would refuse this launch: {d} {s} with a missing input, {d} with an output changed outside workz\n", .{ missing, if (missing == 1) "rule" else "rules", changed });
    }
    if (!manifest_ok) {
        refused += 1;
        std.debug.print("workz: run would refuse this launch: inputs do not match the input manifest\n", .{});
    }
    if (budget) {
        const runs = try c.a.alloc(bool, l.wf.rules.len);
        var reused: usize = 0;
        for (runs, ds, l.mask) |*r, d, m| {
            r.* = m and d.run;
            reused += @intFromBool(m and !d.run);
        }
        refused += try plan.printBudget(c.gpa, c.a, &w.interface, &l.wf, runs, reused, .{
            .threads = max_threads orelse run.defaultThreads(),
            .memory_mib = max_memory orelse run.defaultMemoryMib(c.gpa),
            .defaults = max_threads == null and max_memory == null,
        });
    }
    try w.interface.flush();
    return if (refused > 0) .failed else .ok;
}

fn cmdExplain(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var rerun = false;
    var pass: std.ArrayList([]const u8) = .empty;
    var reruns: std.ArrayList([]const u8) = .empty;
    var threads: std.ArrayList([]const u8) = .empty;
    var manifest: ?[]const u8 = null;
    if (try parseArgs(c, args, &common, PlanExtra{ .rerun = &rerun, .pass = &pass, .threads = &threads, .reruns = &reruns, .a = c.a, .manifest = &manifest })) |e| return e;
    // `explain RULE` reads workflow.toml; `explain WORKFLOW RULE` names the file.
    if (common.positional.items.len == 0) if (common.workflow) |name| {
        try common.positional.append(c.a, name);
        common.workflow = null;
    };
    if (common.positional.items.len == 0) return fail("explain needs a rule name", .{});
    if (common.positional.items.len > 1) return fail("explain takes one rule name", .{});
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    if (applyThreads(&l.wf, threads.items)) |e| return e;
    var st = plan.loadState(c.gpa, l.wf.root, c.a) catch |err| return stateFailed(c, err, l.wf.root);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var ctx = planContext(c, &l, &st, &ids, pass.items) catch |err| return unreadable(err, &ids);
    try noteLiveLaunch(c, l.wf.root);
    ctx.rerun = rerun;
    ctx.rerun_rules = reruns.items;
    if (!try knownRules(c.a, &l.wf, reruns.items)) return .usage;
    if (!((try checkPlanManifest(c, &st, &ids, manifest)) orelse return .usage)) std.debug.print("workz: run would refuse this launch: inputs do not match the input manifest\n", .{});
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const found = plan.explain(&w.interface, &ctx, l.mask, common.positional.items[0]) catch |err| return unreadable(err, &ids);
    try w.interface.flush();
    if (!found) {
        const name = common.positional.items[0];
        if (try closestRule(c.a, &l.wf, name)) |hint| return fail("unknown rule '{s}'; did you mean '{s}'?", .{ name, hint });
        return fail("unknown rule '{s}'", .{name});
    }
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
    if (try parseArgs(c, args, &common, VerifyExtra{ .content = &content })) |e| return e;
    if (extraArgs(c, &common)) |e| return e;
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    const rec = try workz.records.recordsDir(c.a, l.wf.root);
    try workz.records.makeRecordsDir(c.gpa, rec);
    const lock = workz.records.lock(c.gpa, rec) catch |err| switch (err) {
        error.Busy => return failed("a launch is running in {s}; verify after it ends", .{l.wf.root}),
        else => return err,
    };
    defer sys.close(lock);
    var st = plan.loadState(c.gpa, l.wf.root, c.a) catch |err| return stateFailed(c, err, l.wf.root);
    defer st.deinit();
    var ids = state.Identities.init(c.gpa);
    defer ids.deinit();
    var buf: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const ok = try plan.verify(&w.interface, c.gpa, &st, &ids, &l.wf, l.mask, content);
    try w.interface.flush();
    return if (ok) .ok else .failed;
}

/// Appends a command to the running launch's control file; the engine
/// applies it and records the result as a `control` event.
fn cmdControl(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    if (try parseArgs(c, args, &common, NoExtra{})) |e| return e;
    // The first word is a workflow file only when it is not a command.
    var words: std.ArrayList([]const u8) = .empty;
    if (common.workflow) |wfp| {
        if (std.mem.eql(u8, wfp, "stop") or std.mem.eql(u8, wfp, "retry") or std.mem.eql(u8, wfp, "cancel")) {
            try words.append(c.a, wfp);
            common.workflow = null;
        }
    }
    try words.appendSlice(c.a, common.positional.items);
    const ok = words.items.len >= 1 and ((std.mem.eql(u8, words.items[0], "cancel") and words.items.len == 1) or
        ((std.mem.eql(u8, words.items[0], "stop") or std.mem.eql(u8, words.items[0], "retry")) and words.items.len == 2));
    if (!ok) return fail("control needs: stop RULE, retry RULE, or cancel", .{});
    const root = (try rootOf(c, &common)) orelse return .usage;
    const rec = try workz.records.recordsDir(c.a, root);
    const dir = (try workz.records.latestLaunch(c.gpa, c.a, rec)) orelse return failed("no launch recorded in {s}; workz run starts one", .{rec});
    if (sys.exists(c.gpa, try std.fs.path.join(c.a, &.{ dir, "summary.json" }))) return failed("the newest launch has ended: {s}; workz run starts another", .{dir});
    if (!workz.records.launchActive(c.gpa, dir)) return failed("the newest launch did not finish, and no engine runs it: {s}; its engine ended without recording its end", .{dir});
    var tr = try workz.tracker.Tracker.init(c.gpa, dir);
    defer tr.deinit();
    _ = try tr.update();
    if (tr.ending) return failed("the newest launch is ending and applies no more commands: {s}", .{dir});
    if (words.items.len == 2 and !tr.index.contains(words.items[1])) return failed("rule {s} is not part of the running launch", .{words.items[1]});
    const line = if (words.items.len == 2) try std.fmt.allocPrint(c.a, "{s} {s}\n", .{ words.items[0], words.items[1] }) else "cancel\n";
    const fd = try sys.openWrite(c.gpa, try std.fs.path.join(c.a, &.{ dir, "control" }), .append);
    defer sys.close(fd);
    try sys.writeAll(fd, line);
    try out(c.io, "sent: {s}", .{line});
    return .ok;
}

/// The workflow file of commands given none, and the file `init` writes.
const default_workflow = "workflow.toml";
const starter_workflow = @embedFile("templates/workflow.toml");
const starter_pipeline = @embedFile("templates/pipeline.toml");
const bash_completion = @embedFile("templates/completion.bash");

fn cmdInit(c: Ctx, args: []const [:0]const u8) !Exit {
    var template = false;
    var file: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--template")) {
            template = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            return try unknownOption(c, arg);
        } else if (file == null) {
            file = arg;
        } else return fail("init takes at most one file name", .{});
    }
    if (template) {
        const path = file orelse "pipeline.toml";
        const sheet = if (std.fs.path.dirname(path)) |d| try std.fs.path.join(c.a, &.{ d, "samples.tsv" }) else "samples.tsv";
        for ([_][]const u8{ path, sheet }) |p| if (sys.exists(c.gpa, p)) return fail("{s} exists; init does not overwrite", .{p});
        sys.writeFile(c.gpa, path, starter_pipeline) catch |err| return failed("cannot write {s}: {s}", .{ path, sys.errorText(err) });
        sys.writeFile(c.gpa, sheet, "sample\treads\nS1\tdata/S1.txt\nS2\tdata/S2.txt\n") catch |err| return failed("cannot write {s}: {s}", .{ sheet, sys.errorText(err) });
        try out(c.io, "wrote {s} and {s}; its steps read data/S1.txt and data/S2.txt, which it does not create. Edit them, then: workz prepare\n", .{ path, sheet });
        return .ok;
    }
    const path = file orelse default_workflow;
    if (sys.exists(c.gpa, path)) return fail("{s} exists; init does not overwrite", .{path});
    sys.writeFile(c.gpa, path, starter_workflow) catch |err| return failed("cannot write {s}: {s}", .{ path, sys.errorText(err) });
    try out(c.io, "wrote {s}; its example rules read data/S1.txt, which it does not create. Edit it, then: workz validate {s}\n", .{ path, path });
    return .ok;
}

fn cmdPrepare(c: Ctx, args: []const [:0]const u8) !Exit {
    var template: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var check = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return fail("{s} needs a value", .{arg});
            i += 1;
            output = args[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            return try unknownOption(c, arg);
        } else if (template == null) {
            template = arg;
        } else return fail("prepare takes one template file", .{});
    }
    const cwd = try sys.cwd(c.a);
    const shown = template orelse "pipeline.toml";
    const path = try sys.absolute(c.a, cwd, shown);
    if (!sys.exists(c.gpa, path)) return fail("no template {s}; a template is a pipeline file with [[steps]] (see workz help prepare)", .{shown});
    const out_path = if (output) |o| try sys.absolute(c.a, cwd, o) else try std.fs.path.join(c.a, &.{ std.fs.path.dirname(path) orelse ".", default_workflow });
    if (std.mem.eql(u8, out_path, path)) return fail("the template and the workflow it prepares are the same file: give another with -o", .{});
    var problem: workz.prepare.Problem = .{};
    const text = workz.prepare.compile(c.gpa, c.a, path, shown, &problem) catch |err| switch (err) {
        error.Invalid => return fail("{s}", .{problem.message}),
        else => return err,
    };
    // The prepared workflow passes the same checks as any other before it
    // replaces the current one.
    // A check leaves the directory alone: its copy goes to the temporary
    // directory, so it also works where the workflow cannot be written.
    const tmp = if (check) name: {
        var rnd: [8]u8 = undefined;
        sys.randomBytes(&rnd);
        break :name try std.fmt.allocPrint(c.a, "{s}/workz-prepare-{s}.toml", .{ c.env.get("TMPDIR") orelse "/tmp", &std.fmt.bytesToHex(rnd, .lower) });
    } else try std.fmt.allocPrint(c.a, "{s}.prepare-tmp", .{out_path});
    if (check) {
        // A shared temporary directory: the file is created anew under a
        // random name, so a file or symlink planted there is refused, not
        // followed.
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
            notValid(c, shown, tmp, check, &keep_tmp, wproblem);
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
    try out(c.io, "wrote {s}: {d} {s} from {d} {s}. Next: workz graph --by step, then workz plan\n", .{ out_path, wf.rules.len, if (wf.rules.len == 1) "rule" else "rules", steps.count(), if (steps.count() == 1) "step" else "steps" });
    return .ok;
}

/// Reports a prepared workflow that is not valid. With `--check` the
/// file is removed, as a check writes nothing; otherwise it is kept to read.
fn notValid(c: Ctx, shown: []const u8, tmp: []const u8, check: bool, keep_tmp: *bool, problem: workflow.Problem) void {
    if (check) {
        std.debug.print("workz: the workflow {s} prepares is not valid\n", .{shown});
    } else {
        keep_tmp.* = true;
        std.debug.print("workz: the workflow {s} prepares is not valid; it is kept as {s} to read\n", .{ shown, tmp });
    }
    printProblems(c, if (check) "the prepared workflow" else tmp, tmp, problem);
    c.gpa.free(problem.message);
}

fn cmdSchema(c: Ctx, args: []const [:0]const u8) !Exit {
    for (args) |arg| if (arg.len > 1 and arg[0] == '-') return try unknownOption(c, arg);
    if (args.len > 0) return fail("schema takes no arguments", .{});
    var text: std.Io.Writer.Allocating = .init(c.gpa);
    defer text.deinit();
    try workz.schema.write(&text.writer);
    try sys.writeAll(1, text.written());
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
    if (try parseArgs(c, args, &common, NoExtra{})) |e| return e;
    if (common.workflow == null) common.workflow = default_workflow;
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
        if (eq(u8, arg, "--stdout") or eq(u8, arg, "--stderr")) {
            const want: @TypeOf(self.opts.stream) = if (eq(u8, arg, "--stdout")) .stdout else .stderr;
            if (self.opts.stream != .both and self.opts.stream != want) {
                std.debug.print("workz: give --stdout or --stderr; without either, logs prints both\n", .{});
                return std.math.maxInt(usize);
            }
            self.opts.stream = want;
            return 1;
        }
        if (eq(u8, arg, "-f") or eq(u8, arg, "--follow")) {
            self.opts.follow = true;
            return 1;
        }
        if (eq(u8, arg, "--launch")) {
            self.opts.launch = value orelse return missingValue(arg);
            return 2;
        }
        if (eq(u8, arg, "--attempt")) {
            const v = value orelse return missingValue(arg);
            self.opts.attempt = std.fmt.parseInt(u32, v, 10) catch return invalidValue(arg, v, "use a whole number");
            return 2;
        }
        return 0;
    }
};

fn cmdLogs(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var opts: workz.logs.Options = .{};
    if (try parseArgs(c, args, &common, LogsExtra{ .opts = &opts })) |e| return e;
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
    const rec = try workz.records.recordsDir(c.a, root);
    if (opts.launch) |id| if (!sys.exists(c.gpa, try std.fs.path.join(c.a, &.{ rec, "launches", id }))) return failed("no launch {s} recorded in {s}", .{ id, rec });
    const dir = (try workz.logs.find(c.gpa, c.a, root, rule, opts)) orelse {
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

const CleanExtra = struct {
    opts: *workz.clean.Options,
    fn option(self: CleanExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            self.opts.dry_run = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--previous")) {
            self.opts.previous = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--keep")) {
            const v = value orelse return missingValue(arg);
            self.opts.keep = std.fmt.parseInt(usize, v, 10) catch return invalidValue(arg, v, "use a whole number");
            return 2;
        }
        return 0;
    }
};

fn cmdClean(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var opts: workz.clean.Options = .{};
    if (try parseArgs(c, args, &common, CleanExtra{ .opts = &opts })) |e| return e;
    if (extraArgs(c, &common)) |e| return e;
    const root = (try rootOf(c, &common)) orelse return .usage;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
    const r = workz.clean.run(c.gpa, c.a, root, opts, c.env, &w.interface) catch |err| switch (err) {
        error.Busy => return failed("a launch is running in {s}; clean after it ends", .{root}),
        error.OutOfMemory => return err,
        error.CorruptState, error.UnsupportedState => {
            std.debug.print("workz: clean --keep cannot tell which launches hold recorded results\n", .{});
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

/// Options of `watch` (once, interval) or of `status` (history, json); both
/// take --launch and --no-color.
const WatchExtra = struct {
    once: ?*bool = null,
    interval: ?*u64 = null,
    history: ?*?usize = null,
    json: ?*bool = null,
    color: *bool,
    launch: *?[]const u8,
    fn option(self: WatchExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (self.history) |h| if (std.mem.eql(u8, arg, "--history")) {
            // An optional count follows; a word that is not a number is the
            // next argument.
            if (value) |v| if (v.len > 0 and std.ascii.isDigit(v[0])) {
                h.* = std.fmt.parseInt(usize, v, 10) catch return invalidValue(arg, v, "use a whole number of launches");
                return 2;
            };
            h.* = 10;
            return 1;
        };
        if (self.json) |j| if (std.mem.eql(u8, arg, "--json")) {
            j.* = true;
            return 1;
        };
        if (self.once) |o| if (std.mem.eql(u8, arg, "--once")) {
            o.* = true;
            return 1;
        };
        if (self.interval) |iv| if (std.mem.eql(u8, arg, "--interval")) {
            const v = value orelse return missingValue(arg);
            const ms = std.fmt.parseInt(u64, v, 10) catch return invalidValue(arg, v, "use milliseconds as a whole number");
            if (ms < 100) return invalidValue(arg, v, "use 100 ms or more");
            iv.* = ms;
            return 2;
        };
        if (std.mem.eql(u8, arg, "--no-color")) {
            self.color.* = false;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--launch")) {
            self.launch.* = value orelse return missingValue(arg);
            return 2;
        }
        return 0;
    }
};

fn cmdWatch(c: Ctx, args: []const [:0]const u8, summary: bool) !Exit {
    var common: Common = .{};
    var once = summary;
    var interval: u64 = 1000;
    var history: ?usize = null;
    var json = false;
    var color = true;
    var launch: ?[]const u8 = null;
    const extra: WatchExtra = if (summary) .{ .history = &history, .json = &json, .color = &color, .launch = &launch } else .{ .once = &once, .interval = &interval, .color = &color, .launch = &launch };
    if (try parseArgs(c, args, &common, extra)) |e| return e;
    if (extraArgs(c, &common)) |e| return e;
    if (history != null and json) return fail("--history prints text; --json applies to the summary", .{});
    if (history != null and launch != null) return fail("--history lists the recent launches; --launch names one", .{});
    color = color and term.colorOn(1, c.env);
    const root = (try rootOf(c, &common)) orelse return .usage;
    if (history) |n| {
        const rec = try workz.records.recordsDir(c.a, root);
        if (try workz.records.latestLaunch(c.gpa, c.a, rec) == null) return failed("no launch recorded in {s}; workz run starts one", .{rec});
        var buf: [16384]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(c.io, &buf);
        try monitor.history(c.gpa, &w.interface, root, n);
        try w.interface.flush();
        return .ok;
    }
    const dir = (try monitor.findLaunch(c.gpa, c.a, root, launch)) orelse return .failed;
    const ok = if (summary) try monitor.status(c.gpa, c.io, dir, !json and term.isTerminal(1), color) else try monitor.watch(c.gpa, c.io, dir, once, interval, color);
    return if (ok) .ok else .failed;
}

const ReportFormat = enum { tsv, json, html };

const ReportExtra = struct {
    launch: *?[]const u8,
    format: *?ReportFormat,
    bottlenecks: *bool,
    compare: *?[]const u8,
    suggest: *bool,
    methods: *bool,
    output: *?[]const u8,
    fn option(self: ReportExtra, arg: []const u8, value: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            self.output.* = value orelse return missingValue(arg);
            return 2;
        }
        if (std.mem.eql(u8, arg, "--suggest")) {
            self.suggest.* = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--methods")) {
            self.methods.* = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--compare")) {
            self.compare.* = value orelse return missingValue(arg);
            return 2;
        }
        if (std.mem.eql(u8, arg, "--bottlenecks")) {
            self.bottlenecks.* = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--launch")) {
            self.launch.* = value orelse return missingValue(arg);
            return 2;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            const v = value orelse return missingValue(arg);
            self.format.* = std.meta.stringToEnum(ReportFormat, v) orelse return invalidValue(arg, v, "use tsv, json or html");
            return 2;
        }
        // As `run --json` and `status --json` print JSON.
        if (std.mem.eql(u8, arg, "--json")) {
            self.format.* = .json;
            return 1;
        }
        return 0;
    }
};

/// A launch named by ID (in `rec`), by its directory, or by a working
/// directory, meaning its newest launch.
fn resolveLaunch(c: Ctx, rec: []const u8, name: []const u8) !?[]const u8 {
    // A launch ID names a launch with events; any other word is a path, so
    // `.` and a relative working directory work too.
    if (std.mem.indexOfScalar(u8, name, '/') == null) {
        const dir = try std.fs.path.join(c.a, &.{ rec, "launches", name });
        if (sys.exists(c.gpa, try std.fs.path.join(c.a, &.{ dir, "events.jsonl" }))) return dir;
    }
    const path = (try sys.realpath(c.a, name)) orelse return null;
    if (sys.exists(c.gpa, try std.fs.path.join(c.a, &.{ path, "events.jsonl" }))) return path;
    return workz.records.latestLaunch(c.gpa, c.a, try workz.records.recordsDir(c.a, path));
}

fn cmdReport(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var launch: ?[]const u8 = null;
    var format: ?ReportFormat = null;
    var bottlenecks = false;
    var compare: ?[]const u8 = null;
    var suggest = false;
    var methods = false;
    var output: ?[]const u8 = null;
    if (try parseArgs(c, args, &common, ReportExtra{ .launch = &launch, .format = &format, .bottlenecks = &bottlenecks, .compare = &compare, .suggest = &suggest, .methods = &methods, .output = &output })) |e| return e;
    if (extraArgs(c, &common)) |e| return e;
    // One report at a time, in a format it has.
    if (@as(u8, @intFromBool(suggest)) + @intFromBool(compare != null) + @intFromBool(bottlenecks) + @intFromBool(methods) > 1)
        return fail("choose one of --suggest, --compare, --bottlenecks and --methods", .{});
    if (methods) {
        if (launch != null) return fail("--methods describes the results recorded in the working directory, whatever launch made them; drop --launch", .{});
        if (format != null and format.? != .json) return fail("--methods prints text, or JSON with --format json", .{});
    }
    if (format) |f| {
        if (bottlenecks or compare != null) return fail("--bottlenecks and --compare print text; --format applies to the attempt table and --suggest", .{});
        if (suggest and f == .html) return fail("--suggest prints tsv or json, not html", .{});
    }
    const kind = format orelse .tsv;
    if (output == null and kind == .html and !suggest and term.isTerminal(1))
        return fail("the HTML page is for a browser: write it with -o report.html, or redirect standard output", .{});
    const root = (try rootOf(c, &common)) orelse return .usage;
    const rec = try workz.records.recordsDir(c.a, root);
    if (methods) {
        if (!sys.exists(c.gpa, rec)) return failed("no launch recorded in {s}; workz run starts one", .{rec});
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
    const dir = if (launch) |id| try std.fs.path.join(c.a, &.{ rec, "launches", id }) else (try workz.records.latestLaunch(c.gpa, c.a, rec)) orelse return failed("no launch recorded in {s}; workz run starts one", .{rec});
    if (!sys.exists(c.gpa, dir)) return failed("no launch {s}", .{dir});
    var text: std.Io.Writer.Allocating = .init(c.gpa);
    defer text.deinit();
    const w = &text.writer;
    // Records that exist but do not parse are left out and named; the
    // report exits 1.
    var unread: std.ArrayList([]const u8) = .empty;
    if (suggest) {
        var l = try workz.model.load(c.gpa, c.a, dir);
        defer l.deinit();
        unread = l.unreadable;
        // A terminal gets a table; a file or a pipe gets the TSV.
        const table = kind == .tsv and output == null and term.isTerminal(1);
        try report.writeSuggestions(w, &l, if (kind == .json) .json else if (table) .table else .tsv);
    } else if (compare) |other| {
        const base = (try resolveLaunch(c, rec, other)) orelse return failed("no launch found for {s}", .{other});
        try report.writeCompare(c.gpa, c.a, w, base, dir);
    } else if (bottlenecks) {
        try report.writeBottlenecks(c.gpa, c.a, w, dir);
    } else switch (kind) {
        .html => try workz.html.write(c.gpa, c.a, w, dir),
        .json, .tsv => {
            const rows = try workz.model.attempts(c.gpa, c.a, dir, &unread);
            if (kind == .json) try report.writeJson(c.a, w, rows) else try report.writeTsv(w, rows);
            if (rows.len == 0 and unread.items.len == 0) try noAttempts(c, rec, dir, launch == null);
        },
    }
    for (unread.items) |p| std.debug.print("workz: {s} is not valid JSON; the report leaves it out\n", .{p});
    const done: Exit = if (unread.items.len > 0) .failed else .ok;
    if (output) |path| {
        sys.writeFileReplace(c.gpa, path, text.written()) catch |err| return failed("cannot write {s}: {s}", .{ path, sys.errorText(err) });
        return done;
    }
    try sys.writeAll(1, text.written());
    return done;
}

const RunExtra = struct {
    opts: *run.Options,
    pass: *std.ArrayList([]const u8),
    threads: *std.ArrayList([]const u8),
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
            try self.reruns.append(self.a, value orelse return missingValue(arg));
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
        if (eq(u8, arg, "--json")) {
            o.json = true;
            return 1;
        }
        if (eq(u8, arg, "--no-color")) {
            o.color = false;
            return 1;
        }
        const takes_value = for ([_][]const u8{ "-j", "--jobs", "--max-threads", "--max-memory", "-r", "--retry", "--timeout", "--grace", "--input-manifest", "--slice", "--pass-env", "--threads" }) |name| {
            if (eq(u8, arg, name)) break true;
        } else false;
        if (!takes_value) return 0;
        const v = value orelse return missingValue(arg);
        if (eq(u8, arg, "-j") or eq(u8, arg, "--jobs")) {
            o.jobs = std.fmt.parseInt(u32, v, 10) catch return invalidValue(arg, v, "use a whole number above 0");
            if (o.jobs.? == 0) return invalidValue(arg, v, "use a whole number above 0");
        } else if (eq(u8, arg, "--max-threads")) {
            o.max_threads = std.fmt.parseInt(u32, v, 10) catch return invalidValue(arg, v, "use a whole number above 0");
            if (o.max_threads.? == 0) return invalidValue(arg, v, "use a whole number above 0");
        } else if (eq(u8, arg, "--max-memory")) {
            o.max_memory_mib = workflow.parseMemoryMib(v) orelse return invalidValue(arg, v, "use a size such as 512M or 60G, at most 1024T");
        } else if (eq(u8, arg, "-r") or eq(u8, arg, "--retry")) {
            o.retry = std.fmt.parseInt(u32, v, 10) catch return invalidValue(arg, v, "use 0 to 3");
            if (o.retry > 3) return invalidValue(arg, v, "use 0 to 3");
        } else if (eq(u8, arg, "--timeout")) {
            o.timeout_s = workflow.parseDuration(v) orelse return invalidValue(arg, v, "use a duration such as 90s, 30m or 2h");
        } else if (eq(u8, arg, "--grace")) {
            o.grace_s = if (std.mem.eql(u8, v, "0")) 0 else workflow.parseDuration(v) orelse return invalidValue(arg, v, "use a duration such as 10s or 1m, or 0");
        } else if (eq(u8, arg, "--input-manifest")) {
            o.input_manifest = v;
        } else if (eq(u8, arg, "--slice")) {
            if (!std.mem.endsWith(u8, v, ".slice") or v.len <= ".slice".len or std.mem.indexOfScalar(u8, v, '/') != null) return invalidValue(arg, v, "use a unit name ending in .slice, without /");
            o.slice = v;
        } else if (eq(u8, arg, "--pass-env")) {
            if (!envName(v)) return invalidValue(arg, v, "use a variable name such as HOME");
            try self.pass.append(self.a, v);
        } else if (eq(u8, arg, "--threads")) {
            try self.threads.append(self.a, v);
        } else return 0;
        return 2;
    }
};

fn cmdRun(c: Ctx, args: []const [:0]const u8) !Exit {
    var common: Common = .{};
    var opts: run.Options = .{};
    var pass: std.ArrayList([]const u8) = .empty;
    var reruns: std.ArrayList([]const u8) = .empty;
    var threads: std.ArrayList([]const u8) = .empty;
    if (try parseArgs(c, args, &common, RunExtra{ .opts = &opts, .pass = &pass, .threads = &threads, .reruns = &reruns, .a = c.a })) |e| return e;
    if (extraArgs(c, &common)) |e| return e;
    opts.rerun_rules = reruns.items;
    opts.pass_env = pass.items;
    opts.thread_overrides = threads.items;
    if (opts.input_manifest) |m| opts.input_manifest = try sys.absolute(c.a, try sys.cwd(c.a), m);
    // The launcher only starts the scope; the engine inside reads the workflow.
    if (opts.slice != null and !opts.isolation) return fail("--slice places the run's scope, which --no-isolation does not make; give one of them", .{});
    if (opts.isolation and !try insideOwnScope(c)) return isolate(c, opts);
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    if (applyThreads(&l.wf, threads.items)) |e| return e;
    if (!try knownRules(c.a, &l.wf, opts.rerun_rules)) return .usage;
    const outcome = try run.execute(c.gpa, c.a, &l.wf, &l.g, l.mask, opts, c.env);
    return switch (outcome) {
        .ok => .ok,
        .failed => .failed,
        .invalid => .usage,
        .interrupted => .interrupted,
    };
}

/// Applies each `--threads STEP=N` to the loaded workflow: the rules of STEP
/// request N threads in this launch, and their keys change with it.
fn applyThreads(wf: *workflow.Workflow, overrides: []const []const u8) ?Exit {
    for (overrides) |o| {
        // The count follows the last '=', so a step name may hold one.
        const eq = std.mem.lastIndexOfScalar(u8, o, '=') orelse return fail("--threads {s}: give a step and a thread count, such as align=16", .{o});
        const step = o[0..eq];
        const count = o[eq + 1 ..];
        if (step.len == 0) return fail("--threads {s}: give a step and a thread count, such as align=16", .{o});
        for (count) |ch| if (!std.ascii.isDigit(ch)) return fail("--threads {s}: the thread count must be a whole number from 1 to 4096", .{o});
        const n = std.fmt.parseInt(u32, count, 10) catch return fail("--threads {s}: the thread count must be a whole number from 1 to 4096", .{o});
        if (n < 1 or n > 4096) return fail("--threads {s}: the thread count must be a whole number from 1 to 4096", .{o});
        if (wf.overrideThreads(step, n) == 0) {
            var steps: std.ArrayList([]const u8) = .empty;
            defer steps.deinit(std.heap.page_allocator);
            for (wf.rules) |r| steps.append(std.heap.page_allocator, r.labels.step) catch {};
            if (workflow.closest(steps.items, step)) |hint| return fail("--threads {s}: no rule has step '{s}'; did you mean '{s}'?", .{ o, step, hint });
            return fail("--threads {s}: no rule has step '{s}'", .{ o, step });
        }
    }
    return null;
}

/// The rule of the workflow whose name is closest to `name`, if any is close.
fn closestRule(a: std.mem.Allocator, wf: *const workflow.Workflow, name: []const u8) !?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (wf.rules) |r| try names.append(a, r.name);
    return workflow.closest(names.items, name);
}

/// Reports a name given to --rerun-rule that is not a rule of the workflow.
fn knownRules(a: std.mem.Allocator, wf: *const workflow.Workflow, names: []const []const u8) !bool {
    for (names) |n| if (wf.ruleIndex(n) == null) {
        if (try closestRule(a, wf, n)) |hint| {
            std.debug.print("workz: --rerun-rule {s}: no such rule; did you mean '{s}'?\n", .{ n, hint });
        } else std.debug.print("workz: --rerun-rule {s}: no such rule\n", .{n});
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
/// Whether this process is the engine `isolate` started: `WORKZ_STAGE` names
/// the scope it made, and this process runs in that scope. A marker
/// inherited from elsewhere fails the second test, so the launch isolates.
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
    const systemd_run = (try findProgram(c, "systemd-run")) orelse return fail("systemd-run not found; isolation needs a systemd user manager (or use --no-isolation)", .{});
    const threads = opts.max_threads orelse run.defaultThreads();
    var memory = opts.max_memory_mib orelse run.defaultMemoryMib(c.gpa);
    // The engine and its network holder need a little memory beside the tasks.
    memory += 256;
    const exe = try sys.selfExe(c.a);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ systemd_run, "--user", "--scope", "--quiet", "--expand-environment=no" });
    // systemd-run names a scope after its own pid. When workz itself was
    // started by `systemd-run --scope`, that pid is ours and its scope is still
    // loaded, so the run's scope gets a name of its own.
    const unit = try std.fmt.allocPrint(c.a, "workz-{d}-{x}", .{ linux.getpid(), sys.realNs() });
    try argv.append(c.a, try std.fmt.allocPrint(c.a, "--unit={s}", .{unit}));
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
    while (it.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, "WORKZ_STAGE")) try env.append(c.a, try std.fmt.allocPrint(c.a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
    try env.append(c.a, try std.fmt.allocPrint(c.a, "WORKZ_STAGE=inner:{s}", .{unit}));
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
/// `__hold PATH...`: maps every file at or below each path, touches each
/// page once, says `ready BYTES` and keeps the mappings until killed.
fn hold(paths: []const [:0]const u8) Exit {
    const gpa = std.heap.page_allocator;
    var files: std.ArrayList([]u8) = .empty;
    var entry: ?[]u8 = null;
    for (paths) |p| workz.state.listFiles(gpa, p, &files, &entry) catch return fail("cannot list shared input {s}", .{entry orelse p});
    var total: u64 = 0;
    for (files.items) |file| {
        const p = gpa.dupeZ(u8, file) catch return fail("out of memory listing shared input {s}", .{file});
        // Without O_NONBLOCK, opening a FIFO waits for a writer forever.
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

/// Says on standard error why a launch has no attempts to report, and, for
/// the newest launch, which launch last ran some.
fn noAttempts(c: Ctx, rec: []const u8, dir: []const u8, newest: bool) !void {
    const id = std.fs.path.basename(dir);
    var why: []const u8 = "it ran no rule";
    if (sys.readFile(c.gpa, try std.fs.path.join(c.a, &.{ dir, "summary.json" }), 1 << 20)) |text| {
        defer c.gpa.free(text);
        if (std.json.parseFromSliceLeaky(std.json.Value, c.a, text, .{ .allocate = .alloc_always })) |v| {
            if (workz.fields.str(v, "error")) |e| why = try std.fmt.allocPrint(c.a, "it was {s}: {s}", .{ workz.fields.str(v, "status") orelse "stopped", e });
        } else |_| {}
    } else |_| {}
    std.debug.print("workz: launch {s} has no attempts; {s}\n", .{ id, why });
    if (!newest) return;
    const names = try workz.records.launchNames(c.gpa, c.a, rec);
    var k = names.len;
    while (k > 0) {
        k -= 1;
        const attempts = try std.fs.path.join(c.a, &.{ rec, "launches", names[k], "attempts" });
        const inside = (try sys.dirNames(c.gpa, c.a, attempts)) orelse continue;
        if (inside.len == 0) continue;
        std.debug.print("workz: the newest launch that ran attempts is {s}: workz report --launch {s}\n", .{ names[k], names[k] });
        return;
    }
}
