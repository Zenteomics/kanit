//! The kanit command line: the commands and their help, and the parsing of
//! each command's arguments into its options.
//!
//! Parsing reads only the arguments. A wrong word writes one `kanit:` line to
//! the error writer the parser holds and gives exit status 2. Checks that need
//! the workflow file or the filesystem stay with the command that runs them.
const std = @import("std");
const workflow = @import("workflow.zig");
const views = @import("views.zig");
const logs = @import("logs.zig");
const clean = @import("clean.zig");
const run = @import("run.zig");
const term = @import("term.zig");
const version = @import("root.zig").version;
const Allocator = std.mem.Allocator;

pub const default_workflow = "workflow.toml";

// --- Help ---

pub const Group = enum { write, run, watch, maintain };

pub const CommonOptions = enum { none, workdir, all };

pub const Opt = struct { flag: []const u8, desc: []const u8 };

pub const Command = struct {
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

pub const commands = [_]Command{
    .{
        .name = "init",
        .args = "[FILE] [--template]",
        .summary = "write a commented starter workflow or pipeline template",
        .group = .write,
        .common = .none,
        .about =
        \\Writes a commented starter workflow to FILE (default: workflow.toml) in the
        \\current directory. With --template, writes a pipeline template instead
        \\(default: pipeline.toml) and a samples.tsv beside it, for kanit prepare. It
        \\never overwrites a file that exists.
        ,
        .options = &.{.{ .flag = "--template", .desc = "write a pipeline template and samples.tsv instead" }},
        .examples =
        \\kanit init
        \\kanit init rnaseq.toml
        \\kanit init --template
        ,
    },
    .{
        .name = "prepare",
        .args = "[TEMPLATE] [--params FILE] [-o WORKFLOW] [--check]",
        .summary = "write the workflow a pipeline template describes",
        .group = .write,
        .common = .none,
        .about =
        \\Compiles a pipeline template (default: pipeline.toml) into the explicit
        \\workflow the engine runs (default: workflow.toml beside it). Each [[steps]]
        \\entry is one rule, or with for_each = "sample" one rule per row of the
        \\sample sheet, named SAMPLE__STEP and labelled with its step and sample.
        \\{name} takes a sample-sheet column, a [params] value or the step name; in
        \\shell, {input}, {output} and {threads} name the rule's own, and {name:q}
        \\quotes the value for the shell. Other braces, and ${name}, stay as written.
        \\--params FILE is a run file: its [workflow] keys and [params] take the place
        \\of the template's, its [samples] replaces the template's with a sheet read
        \\beside it, and the workflow goes beside it. The result is checked as validate
        \\would before it replaces the workflow; --check prints the rules it would add,
        \\remove and change, and exits 1 if any, without writing.
        ,
        .options = &.{
            .{ .flag = "--params FILE", .desc = "a run file: the run's workflow keys, samples and params" },
            .{ .flag = "-o, --output FILE", .desc = "the workflow to write (default: workflow.toml)" },
            .{ .flag = "--check", .desc = "compare with the current workflow; write nothing" },
        },
        .examples =
        \\kanit prepare
        \\kanit prepare ../pipeline/pipeline.toml --params run.toml
        \\kanit prepare --check
        \\kanit prepare rnaseq.pipeline.toml -o rnaseq.toml
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
        .examples = "kanit schema > kanit.schema.json",
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
        \\kanit validate workflow.toml
        \\kanit validate --inputs
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
        \\the launch: a missing input, an output changed outside kanit, or an input
        \\that does not match --input-manifest.
        \\'dry-run' is another name for it.
        ,
        .options = &([_]Opt{ .{ .flag = "--rules", .desc = "one row per rule instead of one per step" }, .{ .flag = "--summary", .desc = "count the decisions by reason instead" }, .{ .flag = "--json", .desc = "every rule's decision as JSON" }, .{ .flag = "--budget", .desc = "check every request against the budget, as run does" }, .{ .flag = "--max-threads N", .desc = "the budget --budget checks (default: every online CPU)" }, .{ .flag = "--max-memory SIZE", .desc = "the budget --budget checks (default: 3/4 of RAM)" } } ++ rerun_opts),
        .examples =
        \\kanit plan workflow.toml
        \\kanit plan workflow.toml --rules
        \\kanit plan workflow.toml --summary
        \\kanit plan workflow.toml --rerun-rule align_s1
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
        .examples = "kanit explain workflow.toml align/S1",
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
        \\kanit graph --layer resources --by step
        \\kanit graph --users genome
        \\kanit graph --why trim_S1:report
        \\kanit graph --focus +report --format dot > report.dot
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
            .{ .flag = "-v, --verbose", .desc = "also a line for every rule that starts" },
            .{ .flag = "--json", .desc = "print the summary as JSON, also on a terminal" },
            .{ .flag = "--no-color", .desc = "no colors on a terminal (as does NO_COLOR)" },
        },
        .examples =
        \\kanit run workflow.toml --max-threads 16 --max-memory 60G
        \\kanit run workflow.toml --target align_s1 --keep-going
        \\kanit run workflow.toml --rerun-rule align_s1
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
        \\kanit control stop align/S3
        \\kanit control retry align_s3
        \\kanit control cancel
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
        \\kanit watch
        \\kanit watch path/to/workflow.toml
        ,
    },
    .{
        .name = "status",
        .args = "[WORKFLOW] [options]",
        .summary = "summarize the newest launch, or the recent ones",
        .group = .watch,
        .common = .workdir,
        .about =
        \\Prints the summary of the newest launch, or of --launch ID, while it runs
        \\or after it ended: its outcome and counts, a matrix of samples by steps or
        \\a list of steps, the failed and blocked rules, and what to type next. With
        \\--json it prints the launch's summary.json, or while the launch runs the
        \\counts so far with status "running".
        \\
        \\--history lists the recent launches with their rules COMPLETED, REUSED,
        \\FAILED, BLOCKED and CANCELLED (stopped or never started).
        \\
        \\status exits 0 for any outcome it shows, and 1 when it has none to show: no
        \\launch, a summary that cannot be read, or a launch whose engine died.
        ,
        .options = &.{
            .{ .flag = "--history [N]", .desc = "one line for each of the last N launches (default: 10)" },
            .{ .flag = "--launch ID", .desc = "a launch other than the newest" },
            .{ .flag = "--json", .desc = "summary.json, or with --history the launches, as JSON" },
            .{ .flag = "--no-color", .desc = "no colors on a terminal (as does NO_COLOR)" },
        },
        .examples =
        \\kanit status
        \\kanit status --history 5
        ,
    },
    .{
        .name = "logs",
        .args = "[WORKFLOW] [RULE] [options]",
        .summary = "print the output of a rule's newest attempt",
        .group = .watch,
        .common = .workdir,
        .about =
        \\Prints the standard output and error of RULE's newest attempt: in the newest
        \\launch that ran it, else the attempt recorded for it. Without RULE it prints
        \\the failed attempts of the newest launch. Each stream opens with a line that
        \\names the rule, the attempt, how it ended and the stream's size.
        ,
        .options = &.{
            .{ .flag = "--stdout", .desc = "standard output only" },
            .{ .flag = "--stderr", .desc = "standard error only" },
            .{ .flag = "-n, --lines N", .desc = "only the last N lines of each stream" },
            .{ .flag = "--attempt N", .desc = "attempt N instead of the newest" },
            .{ .flag = "--launch ID", .desc = "look in this launch" },
            .{ .flag = "-f, --follow", .desc = "print the output as it grows, until it ends" },
        },
        .examples =
        \\kanit logs
        \\kanit logs align/S1 -n 20
        \\kanit logs align_s1 --stderr --follow
        \\kanit logs trim_s4 --attempt 1
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
        \\kanit report --bottlenecks
        \\kanit report --format html -o report.html
        \\kanit report --compare 20261026T033653.780-bb9b10ee
        \\kanit report --methods -o methods.txt
        ,
    },
    .{
        .name = "verify",
        .args = "[WORKFLOW] [--content] [--json]",
        .summary = "check that recorded outputs are unchanged",
        .group = .maintain,
        .about =
        \\Checks that every recorded output of the selected rules still has the
        \\identity kanit recorded. With --content it also compares the bytes with
        \\stored digests, and stores a digest for every output that has none. It
        \\exits 1 on a difference, or when a selected rule has no record to check.
        ,
        .options = &.{ .{ .flag = "--content", .desc = "also compare and store content digests" }, .{ .flag = "--json", .desc = "every finding and the counts as JSON" } },
        .examples = "kanit verify workflow.toml --content",
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
        \\kanit clean --keep 5 --dry-run
        \\kanit clean --previous --dry-run
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
        \\in the current shell with: source <(kanit completion bash)
        ,
    },
    .{
        .name = "help",
        .args = "[COMMAND]",
        .summary = "show help for kanit or for one command",
        .group = .maintain,
        .common = .none,
        .about = "Shows the commands of kanit, or the options and examples of COMMAND.",
    },
    .{
        .name = "version",
        .args = "",
        .summary = "print the version",
        .group = .maintain,
        .common = .none,
        .about = "Prints the version of kanit.",
    },
};

const group_titles = [_][]const u8{ "Write and check a workflow", "Run", "Watch and inspect", "Maintain" };

pub fn command(name: []const u8) ?*const Command {
    const eql = std.mem.eql;
    const want = if (eql(u8, name, "dry-run")) "plan" else name;
    for (&commands) |*c| if (eql(u8, c.name, want)) return c;
    return null;
}

fn didYouMean(allowed: []const []const u8, word: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = @max(word.len / 3, 1) + 1;
    for (allowed) |cand| {
        if (word.len <= 2 and cand.len <= 2) continue;
        const d = workflow.editDistance(cand, word);
        if (d < best_d) {
            best_d = d;
            best = cand;
        }
    }
    return best;
}

pub fn optionNames(a: std.mem.Allocator, c: *const Command) ![]const []const u8 {
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

pub fn writeOverview(w: *std.Io.Writer, s: term.Style) !void {
    try w.print("{s}kanit {s}{s} runs a prepared graph of file-producing rules on one Linux\nworkstation.\n\n", .{ s.bold(), version, s.reset() });
    try w.print("{s}usage:{s} kanit <command> [options]\n", .{ s.bold(), s.reset() });
    for (group_titles, 0..) |title, gi| {
        try w.print("\n{s}{s}:{s}\n", .{ s.bold(), title, s.reset() });
        for (commands) |c| {
            if (@intFromEnum(c.group) != gi) continue;
            try w.print("  {s}{s:<12}{s}{s}\n", .{ s.cyan(), c.name, s.reset(), c.summary });
        }
    }
    try w.print("\nWORKFLOW, where a command takes one, defaults to {s} in the current\ndirectory. RULE is a rule's name, or its step and sample as STEP/SAMPLE,\nsuch as align/S2 for the rule S2__align.\n", .{default_workflow});
    try w.print("Run '{s}kanit help COMMAND{s}' for a command's usage, options and examples.\n", .{ s.bold(), s.reset() });
}

fn writeOptions(w: *std.Io.Writer, title: []const u8, list: []const Opt, s: term.Style) !void {
    if (list.len == 0) return;
    try w.print("\n{s}{s}:{s}\n", .{ s.bold(), title, s.reset() });
    for (list) |o| try w.print("  {s}{s:<23}{s}{s}\n", .{ s.cyan(), o.flag, s.reset(), o.desc });
}

pub fn writeCommandHelp(w: *std.Io.Writer, c: *const Command, s: term.Style) !void {
    try w.print("{s}usage:{s} kanit {s}{s}{s}\n\n{s}\n", .{ s.bold(), s.reset(), c.name, if (c.args.len > 0) " " else "", c.args, c.about });
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

// --- Parsing ---

pub const Exit = enum(u8) { ok = 0, failed = 1, usage = 2, interrupted = 130, _ };

pub const Args = []const [:0]const u8;

pub const Parser = struct {
    a: Allocator,
    err: *std.Io.Writer,
    name: []const u8,

    pub fn fail(p: Parser, comptime fmt: []const u8, args: anytype) Exit {
        p.err.print("kanit: " ++ fmt ++ "\n", args) catch {};
        p.err.flush() catch {};
        return .usage;
    }

    fn missing(p: Parser, arg: []const u8) usize {
        _ = p.fail("{s} needs a value", .{arg});
        return refused;
    }

    fn invalid(p: Parser, arg: []const u8, value: []const u8, hint: []const u8) usize {
        _ = p.fail("{s}: invalid value '{s}' ({s})", .{ arg, value, hint });
        return refused;
    }

    pub fn unknownCommand(p: Parser) Exit {
        var names: [commands.len + 1][]const u8 = undefined;
        for (commands, 0..) |c, i| names[i] = c.name;
        names[commands.len] = "dry-run";
        if (didYouMean(&names, p.name)) |hint| {
            p.err.print("kanit: unknown command '{s}'; did you mean '{s}'?\nRun 'kanit help' for the commands.\n", .{ p.name, hint }) catch {};
        } else p.err.print("kanit: unknown command '{s}'\nRun 'kanit help' for the commands.\n", .{p.name}) catch {};
        p.err.flush() catch {};
        return .usage;
    }

    pub fn unknownOption(p: Parser, arg: []const u8) !Exit {
        const cmd = command(p.name) orelse return p.fail("unknown option '{s}'", .{arg});
        if (didYouMean(try optionNames(p.a, cmd), arg)) |hint| {
            p.err.print("kanit: unknown option '{s}' for {s}; did you mean '{s}'?\n", .{ arg, cmd.name, hint }) catch {};
        } else p.err.print("kanit: unknown option '{s}' for {s}\n", .{ arg, cmd.name }) catch {};
        p.err.print("Run 'kanit help {s}' for its options.\n", .{cmd.name}) catch {};
        p.err.flush() catch {};
        return .usage;
    }

    fn takesTargets(p: Parser) bool {
        const cmd = command(p.name) orelse return true;
        return cmd.common == .all;
    }

    fn words(p: Parser, args: Args, c: *Common, extra: anytype) !?Exit {
        var i: usize = 0;
        var words_only = false;
        while (i < args.len) : (i += 1) {
            const word = args[i];
            if (!words_only and std.mem.eql(u8, word, "--")) {
                words_only = true;
                continue;
            }
            if (words_only or !(word.len > 1 and word[0] == '-')) {
                if (c.workflow == null) c.workflow = word else try c.positional.append(p.a, word);
                continue;
            }
            const eq_at = if (std.mem.startsWith(u8, word, "--")) std.mem.indexOfScalar(u8, word, '=') else null;
            const arg = if (eq_at) |k| word[0..k] else word;
            const next: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
            const value: ?[]const u8 = if (eq_at) |k|
                (if (word.len > k + 1) word[k + 1 ..] else null)
            else if (next) |n|
                (if (n.len == 0 or (n.len > 1 and n[0] == '-' and !std.ascii.isDigit(n[1]))) null else n)
            else
                null;
            var used: usize = 2;
            if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--workdir")) {
                c.workdir = value orelse return p.fail("{s} needs a value", .{arg});
            } else if ((std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--target")) and p.takesTargets()) {
                try c.targets.append(p.a, value orelse return p.fail("{s} needs a value", .{arg}));
            } else {
                used = try extra.option(p, arg, value);
                if (used == 0) return try p.unknownOption(arg);
                if (used == refused) return .usage;
            }
            if (eq_at == null) {
                i += used - 1;
            } else if (used == 1) return p.fail("{s} takes no value", .{arg});
        }
        return null;
    }

    fn extraArgs(p: Parser, common: *const Common) ?Exit {
        if (common.positional.items.len == 0) return null;
        return p.fail("unexpected argument '{s}'; run 'kanit help {s}' for the usage", .{ common.positional.items[0], p.name });
    }

    pub fn applyThreads(p: Parser, wf: *workflow.Workflow, overrides: []const []const u8) !?Exit {
        for (overrides) |o| {
            const eq = std.mem.lastIndexOfScalar(u8, o, '=') orelse return p.fail("--threads {s}: give a step and a thread count, such as align=16", .{o});
            const step = o[0..eq];
            const count = o[eq + 1 ..];
            if (step.len == 0) return p.fail("--threads {s}: give a step and a thread count, such as align=16", .{o});
            const n = threadCount(count) orelse return p.fail("--threads {s}: the thread count must be a whole number from 1 to 4096", .{o});
            if (wf.overrideThreads(step, n) == 0) {
                var steps: std.ArrayList([]const u8) = .empty;
                for (wf.rules) |r| try steps.append(p.a, r.labels.step);
                if (workflow.closest(steps.items, step)) |hint| return p.fail("--threads {s}: no rule has step '{s}'; did you mean '{s}'?", .{ o, step, hint });
                return p.fail("--threads {s}: no rule has step '{s}'", .{ o, step });
            }
        }
        return null;
    }

    pub fn unknownRule(p: Parser, wf: *const workflow.Workflow, prefix: []const u8, name: []const u8) !Exit {
        if (try closestRule(p.a, wf, name)) |hint| return p.fail("{s}{s}: no such rule; did you mean '{s}'?", .{ prefix, name, hint });
        return p.fail("{s}{s}: no such rule", .{ prefix, name });
    }

    pub fn knownRules(p: Parser, wf: *const workflow.Workflow, names: [][]const u8) !?Exit {
        for (names) |*n| n.* = wf.rules[wf.findRule(n.*) orelse return try p.unknownRule(wf, "--rerun-rule ", n.*)].name;
        return null;
    }
};

const refused = std.math.maxInt(usize);

fn threadCount(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    for (text) |ch| if (!std.ascii.isDigit(ch)) return null;
    const n = std.fmt.parseInt(u32, text, 10) catch return null;
    return if (n >= 1 and n <= 4096) n else null;
}

pub fn closestRule(a: Allocator, wf: *const workflow.Workflow, name: []const u8) !?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (wf.rules) |r| try names.append(a, r.name);
    return workflow.closest(names.items, name);
}

fn envName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

fn zeroDuration(text: []const u8) bool {
    const digits = if (text.len > 1 and std.mem.indexOfScalar(u8, "smhd", text[text.len - 1]) != null) text[0 .. text.len - 1] else text;
    if (digits.len == 0) return false;
    for (digits) |ch| if (ch != '0') return false;
    return true;
}

fn positiveCount(p: Parser, arg: []const u8, v: []const u8) ?u32 {
    const n = std.fmt.parseInt(u32, v, 10) catch 0;
    if (n == 0) {
        _ = p.invalid(arg, v, "use a whole number above 0");
        return null;
    }
    return n;
}

fn launchValue(p: Parser, arg: []const u8, value: ?[]const u8, launch: *?[]const u8) usize {
    const v = value orelse return p.missing(arg);
    if (std.mem.eql(u8, v, ".") or std.mem.eql(u8, v, "..") or std.mem.indexOfScalar(u8, v, '/') != null)
        return p.invalid(arg, v, "use a launch ID, as status --history lists them");
    launch.* = v;
    return 2;
}

pub const Common = struct {
    workflow: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    targets: std.ArrayList([]const u8) = .empty,
    positional: std.ArrayList([]const u8) = .empty,
};

const NoOptions = struct {
    fn option(_: NoOptions, _: Parser, _: []const u8, _: ?[]const u8) !usize {
        return 0;
    }
};

pub const Plain = struct {
    common: Common = .{},

    pub fn parse(self: *Plain, p: Parser, args: Args) !?Exit {
        return p.words(args, &self.common, NoOptions{});
    }
};

pub const Validate = struct {
    common: Common = .{},
    inputs: bool = false,

    pub fn parse(self: *Validate, p: Parser, args: Args) !?Exit {
        if (try p.words(args, &self.common, self)) |e| return e;
        return p.extraArgs(&self.common);
    }

    fn option(self: *Validate, _: Parser, arg: []const u8, _: ?[]const u8) !usize {
        if (!std.mem.eql(u8, arg, "--inputs")) return 0;
        self.inputs = true;
        return 1;
    }
};

pub const Verify = struct {
    common: Common = .{},
    content: bool = false,
    json: bool = false,

    pub fn parse(self: *Verify, p: Parser, args: Args) !?Exit {
        if (try p.words(args, &self.common, self)) |e| return e;
        return p.extraArgs(&self.common);
    }

    fn option(self: *Verify, _: Parser, arg: []const u8, _: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--json")) {
            self.json = true;
            return 1;
        }
        if (!std.mem.eql(u8, arg, "--content")) return 0;
        self.content = true;
        return 1;
    }
};

pub const Graph = struct {
    common: Common = .{},
    opts: views.Options = .{},
    format: ?views.Format = null,
    focus: ?[]const u8 = null,

    pub fn parse(self: *Graph, p: Parser, args: Args) !?Exit {
        if (try p.words(args, &self.common, self)) |e| return e;
        if (p.extraArgs(&self.common)) |e| return e;
        const o = self.opts;
        if (@as(u8, @intFromBool(o.focus != null)) + @intFromBool(o.why != null) + @intFromBool(o.users != null) > 1)
            return p.fail("choose one of --focus, --why and --users", .{});
        return null;
    }

    fn option(self: *Graph, p: Parser, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        if (eq(u8, arg, "--by")) {
            const v = value orelse return p.missing(arg);
            if (!eq(u8, v, "step")) return p.invalid(arg, v, "use step");
            self.opts.by_step = true;
            return 2;
        }
        if (eq(u8, arg, "--layer")) {
            const v = value orelse return p.missing(arg);
            self.opts.layer = std.meta.stringToEnum(views.Layer, v) orelse return p.invalid(arg, v, "use rules, files, resources or all");
            return 2;
        }
        if (eq(u8, arg, "--format")) {
            const v = value orelse return p.missing(arg);
            self.format = std.meta.stringToEnum(views.Format, v) orelse return p.invalid(arg, v, "use dot, json or text");
            return 2;
        }
        if (eq(u8, arg, "--focus")) {
            const v = value orelse return p.missing(arg);
            self.opts.focus = views.Focus.parse(v, null) orelse return p.invalid(arg, v, "use +RULE, RULE+, +RULE+, or a depth such as 2+RULE");
            self.focus = v;
            return 2;
        }
        if (eq(u8, arg, "--why")) {
            const v = value orelse return p.missing(arg);
            const colon = std.mem.indexOfScalar(u8, v, ':') orelse return p.invalid(arg, v, "use FROM:TO, two rule names");
            self.opts.why = .{ v[0..colon], v[colon + 1 ..] };
            return 2;
        }
        if (eq(u8, arg, "--users")) {
            self.opts.users = value orelse return p.missing(arg);
            return 2;
        }
        return 0;
    }
};

pub const Plan = struct {
    explain: bool = false,
    common: Common = .{},
    rerun: bool = false,
    summary: bool = false,
    rules: bool = false,
    json: bool = false,
    budget: bool = false,
    max_threads: ?u32 = null,
    max_memory: ?u64 = null,
    manifest: ?[]const u8 = null,
    pass: std.ArrayList([]const u8) = .empty,
    threads: std.ArrayList([]const u8) = .empty,
    reruns: std.ArrayList([]const u8) = .empty,
    rule: []const u8 = "",

    pub fn parse(self: *Plan, p: Parser, args: Args) !?Exit {
        if (try p.words(args, &self.common, self)) |e| return e;
        if (self.explain) {
            const c = &self.common;
            if (c.positional.items.len == 0) if (c.workflow) |name| {
                try c.positional.append(p.a, name);
                c.workflow = null;
            };
            if (c.positional.items.len == 0) return p.fail("explain needs a rule name", .{});
            if (c.positional.items.len > 1) return p.fail("explain takes one rule name", .{});
            self.rule = c.positional.items[0];
            return null;
        }
        if (!self.budget and (self.max_threads != null or self.max_memory != null))
            return p.fail("{s} sets the budget --budget checks; give --budget too", .{if (self.max_threads != null) "--max-threads" else "--max-memory"});
        if (self.json and (self.summary or self.budget or self.rules))
            return p.fail("--json prints every rule's decision; leave out {s}", .{if (self.summary) "--summary" else if (self.budget) "--budget" else "--rules"});
        return p.extraArgs(&self.common);
    }

    fn option(self: *Plan, p: Parser, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        if (eq(u8, arg, "--rerun")) {
            self.rerun = true;
            return 1;
        }
        if (eq(u8, arg, "--rerun-rule")) {
            try self.reruns.append(p.a, value orelse return p.missing(arg));
            return 2;
        }
        if (eq(u8, arg, "--threads")) {
            try self.threads.append(p.a, value orelse return p.missing(arg));
            return 2;
        }
        if (eq(u8, arg, "--input-manifest")) {
            self.manifest = value orelse return p.missing(arg);
            return 2;
        }
        if (eq(u8, arg, "--pass-env")) {
            const v = value orelse return p.missing(arg);
            if (!envName(v)) return p.invalid(arg, v, "use a variable name such as HOME");
            try self.pass.append(p.a, v);
            return 2;
        }
        if (self.explain) return 0;
        if (eq(u8, arg, "--summary")) {
            self.summary = true;
            return 1;
        }
        if (eq(u8, arg, "--rules")) {
            self.rules = true;
            return 1;
        }
        if (eq(u8, arg, "--json")) {
            self.json = true;
            return 1;
        }
        if (eq(u8, arg, "--budget")) {
            self.budget = true;
            return 1;
        }
        if (eq(u8, arg, "--max-threads")) {
            const v = value orelse return p.missing(arg);
            self.max_threads = positiveCount(p, arg, v) orelse return refused;
            return 2;
        }
        if (eq(u8, arg, "--max-memory")) {
            const v = value orelse return p.missing(arg);
            self.max_memory = workflow.parseMemoryMib(v) orelse return p.invalid(arg, v, "use a size from 1M to 1024T, such as 512M or 60G");
            return 2;
        }
        return 0;
    }
};

pub const Run = struct {
    common: Common = .{},
    opts: run.Options = .{},
    pass: std.ArrayList([]const u8) = .empty,
    threads: std.ArrayList([]const u8) = .empty,
    reruns: std.ArrayList([]const u8) = .empty,

    pub fn parse(self: *Run, p: Parser, args: Args) !?Exit {
        if (try p.words(args, &self.common, self)) |e| return e;
        if (p.extraArgs(&self.common)) |e| return e;
        self.opts.rerun_rules = self.reruns.items;
        self.opts.pass_env = self.pass.items;
        self.opts.thread_overrides = self.threads.items;
        if (self.opts.slice != null and !self.opts.isolation)
            return p.fail("--slice places the run's scope, which --no-isolation does not make; give one of them", .{});
        return null;
    }

    fn option(self: *Run, p: Parser, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        const o = &self.opts;
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
        if (eq(u8, arg, "-v") or eq(u8, arg, "--verbose")) {
            o.verbose = true;
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
        const takes_value = for ([_][]const u8{ "-j", "--jobs", "--max-threads", "--max-memory", "-r", "--retry", "--timeout", "--grace", "--input-manifest", "--slice", "--pass-env", "--threads", "--rerun-rule" }) |name| {
            if (eq(u8, arg, name)) break true;
        } else false;
        if (!takes_value) return 0;
        const v = value orelse return p.missing(arg);
        if (eq(u8, arg, "-j") or eq(u8, arg, "--jobs")) {
            o.jobs = positiveCount(p, arg, v) orelse return refused;
        } else if (eq(u8, arg, "--max-threads")) {
            o.max_threads = positiveCount(p, arg, v) orelse return refused;
        } else if (eq(u8, arg, "--max-memory")) {
            o.max_memory_mib = workflow.parseMemoryMib(v) orelse return p.invalid(arg, v, "use a size from 1M to 1024T, such as 512M or 60G");
        } else if (eq(u8, arg, "-r") or eq(u8, arg, "--retry")) {
            o.retry = std.fmt.parseInt(u32, v, 10) catch return p.invalid(arg, v, "use 0 to 3");
            if (o.retry > 3) return p.invalid(arg, v, "use 0 to 3");
        } else if (eq(u8, arg, "--timeout")) {
            o.timeout_s = workflow.parseDuration(v) orelse return p.invalid(arg, v, "use a duration such as 90s, 30m or 2h");
        } else if (eq(u8, arg, "--grace")) {
            o.grace_s = if (zeroDuration(v)) 0 else workflow.parseDuration(v) orelse return p.invalid(arg, v, "use a duration such as 10s or 1m, or 0");
        } else if (eq(u8, arg, "--input-manifest")) {
            o.input_manifest = v;
        } else if (eq(u8, arg, "--slice")) {
            if (!std.mem.endsWith(u8, v, ".slice") or v.len <= ".slice".len or std.mem.indexOfScalar(u8, v, '/') != null) return p.invalid(arg, v, "use a unit name ending in .slice, without /");
            o.slice = v;
        } else if (eq(u8, arg, "--pass-env")) {
            if (!envName(v)) return p.invalid(arg, v, "use a variable name such as HOME");
            try self.pass.append(p.a, v);
        } else if (eq(u8, arg, "--threads")) {
            try self.threads.append(p.a, v);
        } else if (eq(u8, arg, "--rerun-rule")) {
            try self.reruns.append(p.a, v);
        }
        return 2;
    }
};

pub const Watch = struct {
    summary: bool = false,
    common: Common = .{},
    once: bool = false,
    interval_ms: u64 = 1000,
    history: ?usize = null,
    json: bool = false,
    color: bool = true,
    launch: ?[]const u8 = null,

    pub fn parse(self: *Watch, p: Parser, args: Args) !?Exit {
        self.once = self.once or self.summary;
        if (try p.words(args, &self.common, self)) |e| return e;
        if (p.extraArgs(&self.common)) |e| return e;
        if (self.history != null and self.launch != null) return p.fail("--history lists the recent launches; --launch names one", .{});
        return null;
    }

    fn option(self: *Watch, p: Parser, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        if (eq(u8, arg, "--no-color")) {
            self.color = false;
            return 1;
        }
        if (eq(u8, arg, "--launch")) return launchValue(p, arg, value, &self.launch);
        if (self.summary) {
            if (eq(u8, arg, "--history")) {
                if (value) |v| if (v.len > 0 and std.ascii.isDigit(v[0])) {
                    self.history = std.fmt.parseInt(usize, v, 10) catch return p.invalid(arg, v, "use a whole number of launches");
                    return 2;
                };
                self.history = 10;
                return 1;
            }
            if (eq(u8, arg, "--json")) {
                self.json = true;
                return 1;
            }
            return 0;
        }
        if (eq(u8, arg, "--once")) {
            self.once = true;
            return 1;
        }
        if (eq(u8, arg, "--interval")) {
            const v = value orelse return p.missing(arg);
            const ms = std.fmt.parseInt(u64, v, 10) catch return p.invalid(arg, v, "use milliseconds as a whole number");
            if (ms < 100) return p.invalid(arg, v, "use 100 ms or more");
            self.interval_ms = ms;
            return 2;
        }
        return 0;
    }
};

pub const ReportFormat = enum { tsv, json, html };

pub const Report = struct {
    stdout_terminal: bool = false,
    common: Common = .{},
    launch: ?[]const u8 = null,
    format: ?ReportFormat = null,
    bottlenecks: bool = false,
    compare: ?[]const u8 = null,
    suggest: bool = false,
    methods: bool = false,
    output: ?[]const u8 = null,

    pub fn kind(self: *const Report) ReportFormat {
        return self.format orelse .tsv;
    }

    pub fn parse(self: *Report, p: Parser, args: Args) !?Exit {
        if (try p.words(args, &self.common, self)) |e| return e;
        if (p.extraArgs(&self.common)) |e| return e;
        if (@as(u8, @intFromBool(self.suggest)) + @intFromBool(self.compare != null) + @intFromBool(self.bottlenecks) + @intFromBool(self.methods) > 1)
            return p.fail("choose one of --suggest, --compare, --bottlenecks and --methods", .{});
        if (self.methods) {
            if (self.launch != null) return p.fail("--methods describes the results recorded in the working directory, whatever launch made them; drop --launch", .{});
            if (self.format != null and self.format.? != .json) return p.fail("--methods prints text, or JSON with --format json", .{});
        }
        if (self.format) |f| {
            if (self.bottlenecks or self.compare != null) return p.fail("--bottlenecks and --compare print text; --format applies to the attempt table and --suggest", .{});
            if (self.suggest and f == .html) return p.fail("--suggest prints tsv or json, not html", .{});
        }
        if (self.output == null and self.kind() == .html and !self.suggest and self.stdout_terminal)
            return p.fail("the HTML page is for a browser: write it with -o report.html, or redirect standard output", .{});
        return null;
    }

    fn setFormat(self: *Report, p: Parser, f: ReportFormat, used: usize) usize {
        if (self.format) |had| if (had != f) {
            _ = p.fail("give one format; --json is --format json", .{});
            return refused;
        };
        self.format = f;
        return used;
    }

    fn option(self: *Report, p: Parser, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        if (eq(u8, arg, "-o") or eq(u8, arg, "--output")) {
            self.output = value orelse return p.missing(arg);
            return 2;
        }
        if (eq(u8, arg, "--suggest")) {
            self.suggest = true;
            return 1;
        }
        if (eq(u8, arg, "--methods")) {
            self.methods = true;
            return 1;
        }
        if (eq(u8, arg, "--compare")) {
            self.compare = value orelse return p.missing(arg);
            return 2;
        }
        if (eq(u8, arg, "--bottlenecks")) {
            self.bottlenecks = true;
            return 1;
        }
        if (eq(u8, arg, "--launch")) return launchValue(p, arg, value, &self.launch);
        if (eq(u8, arg, "--format")) {
            const v = value orelse return p.missing(arg);
            return self.setFormat(p, std.meta.stringToEnum(ReportFormat, v) orelse return p.invalid(arg, v, "use tsv, json or html"), 2);
        }
        if (eq(u8, arg, "--json")) return self.setFormat(p, .json, 1);
        return 0;
    }
};

pub const Logs = struct {
    common: Common = .{},
    opts: logs.Options = .{},
    rule: []const u8 = "",

    pub fn parse(self: *Logs, p: Parser, args: Args) !?Exit {
        if (try p.words(args, &self.common, self)) |e| return e;
        const c = &self.common;
        switch (c.positional.items.len) {
            0 => if (c.workflow) |word| if (!std.mem.endsWith(u8, word, ".toml")) {
                self.rule = word;
                c.workflow = null;
            },
            1 => self.rule = c.positional.items[0],
            else => return p.fail("logs takes one rule name", .{}),
        }
        if (self.rule.len == 0 and (self.opts.follow or self.opts.attempt != null))
            return p.fail("{s} needs a rule name", .{if (self.opts.follow) "--follow" else "--attempt"});
        return null;
    }

    fn option(self: *Logs, p: Parser, arg: []const u8, value: ?[]const u8) !usize {
        const eq = std.mem.eql;
        if (eq(u8, arg, "--stdout") or eq(u8, arg, "--stderr")) {
            const want: @TypeOf(self.opts.stream) = if (eq(u8, arg, "--stdout")) .stdout else .stderr;
            if (self.opts.stream != .both and self.opts.stream != want) {
                _ = p.fail("give --stdout or --stderr; without either, logs prints both", .{});
                return refused;
            }
            self.opts.stream = want;
            return 1;
        }
        if (eq(u8, arg, "-f") or eq(u8, arg, "--follow")) {
            self.opts.follow = true;
            return 1;
        }
        if (eq(u8, arg, "-n") or eq(u8, arg, "--lines")) {
            const v = value orelse return p.missing(arg);
            self.opts.lines = std.fmt.parseInt(usize, v, 10) catch return p.invalid(arg, v, "use a whole number of lines");
            return 2;
        }
        if (eq(u8, arg, "--launch")) return launchValue(p, arg, value, &self.opts.launch);
        if (eq(u8, arg, "--attempt")) {
            const v = value orelse return p.missing(arg);
            self.opts.attempt = std.fmt.parseInt(u32, v, 10) catch return p.invalid(arg, v, "use a whole number");
            return 2;
        }
        return 0;
    }
};

pub const Clean = struct {
    common: Common = .{},
    opts: clean.Options = .{},

    pub fn parse(self: *Clean, p: Parser, args: Args) !?Exit {
        if (try p.words(args, &self.common, self)) |e| return e;
        return p.extraArgs(&self.common);
    }

    fn option(self: *Clean, p: Parser, arg: []const u8, value: ?[]const u8) !usize {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            self.opts.dry_run = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--previous")) {
            self.opts.previous = true;
            return 1;
        }
        if (std.mem.eql(u8, arg, "--keep")) {
            const v = value orelse return p.missing(arg);
            self.opts.keep = std.fmt.parseInt(usize, v, 10) catch return p.invalid(arg, v, "use a whole number");
            return 2;
        }
        return 0;
    }
};

pub const Control = struct {
    common: Common = .{},
    verb: []const u8 = "",
    rule: ?[]const u8 = null,

    pub fn parse(self: *Control, p: Parser, args: Args) !?Exit {
        if (try p.words(args, &self.common, NoOptions{})) |e| return e;
        var words: std.ArrayList([]const u8) = .empty;
        if (self.common.workflow) |w| if (isVerb(w)) {
            try words.append(p.a, w);
            self.common.workflow = null;
        };
        try words.appendSlice(p.a, self.common.positional.items);
        const w = words.items;
        const eq = std.mem.eql;
        const ok = w.len >= 1 and ((eq(u8, w[0], "cancel") and w.len == 1) or
            ((eq(u8, w[0], "stop") or eq(u8, w[0], "retry")) and w.len == 2));
        if (!ok) return p.fail("control needs: stop RULE, retry RULE, or cancel", .{});
        self.verb = w[0];
        if (w.len == 2) self.rule = w[1];
        return null;
    }

    fn isVerb(word: []const u8) bool {
        for ([_][]const u8{ "stop", "retry", "cancel" }) |v| if (std.mem.eql(u8, word, v)) return true;
        return false;
    }
};

pub const Init = struct {
    template: bool = false,
    file: ?[]const u8 = null,

    pub fn parse(self: *Init, p: Parser, args: Args) !?Exit {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--template")) {
                self.template = true;
            } else if (arg.len > 1 and arg[0] == '-') {
                return try p.unknownOption(arg);
            } else if (self.file == null) {
                if (arg.len == 0 or std.mem.eql(u8, arg, "-")) return p.fail("init needs a file name, not '{s}'", .{arg});
                self.file = arg;
            } else return p.fail("init takes at most one file name", .{});
        }
        return null;
    }
};

pub const Prepare = struct {
    template: ?[]const u8 = null,
    output: ?[]const u8 = null,
    params: ?[]const u8 = null,
    check: bool = false,

    pub fn parse(self: *Prepare, p: Parser, args: Args) !?Exit {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--check")) {
                self.check = true;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "--params")) {
                const next = if (i + 1 < args.len) args[i + 1] else "";
                if (next.len == 0 or (next.len > 1 and next[0] == '-')) return p.fail("{s} needs a value", .{arg});
                i += 1;
                if (std.mem.eql(u8, arg, "--params")) self.params = next else self.output = next;
            } else if (std.mem.startsWith(u8, arg, "--output=") or std.mem.startsWith(u8, arg, "--params=")) {
                const eq = std.mem.indexOfScalar(u8, arg, '=').?;
                const v = arg[eq + 1 ..];
                if (v.len == 0) return p.fail("{s} needs a value", .{arg[0..eq]});
                if (std.mem.eql(u8, arg[0..eq], "--params")) self.params = v else self.output = v;
            } else if (arg.len > 1 and arg[0] == '-') {
                return try p.unknownOption(arg);
            } else if (self.template == null) {
                self.template = arg;
            } else return p.fail("prepare takes one template file", .{});
        }
        return null;
    }
};

pub fn noArguments(p: Parser, args: Args) !?Exit {
    for (args) |arg| if (arg.len > 1 and arg[0] == '-') return try p.unknownOption(arg);
    if (args.len > 0) return p.fail("{s} takes no arguments", .{p.name});
    return null;
}

pub fn completionShell(p: Parser, args: Args) ?Exit {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "bash")) return p.fail("completion supports: bash", .{});
    return null;
}
