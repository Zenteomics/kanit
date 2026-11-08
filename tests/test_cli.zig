//! Unit tests of the command line: options and their values, words after the
//! options, conflicting options, the help, and the checks against a loaded
//! workflow.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const cli = workz.cli;
const workflow = workz.workflow;
const helpers = @import("helpers.zig");

const Outcome = struct {
    exit: ?cli.Exit,
    err: []const u8,
};

const Line = struct {
    arena: std.heap.ArenaAllocator,
    err: std.Io.Writer.Allocating,

    fn init() Line {
        return .{ .arena = .init(testing.allocator), .err = .init(testing.allocator) };
    }

    fn deinit(self: *Line) void {
        self.err.deinit();
        self.arena.deinit();
    }

    fn parser(self: *Line, name: []const u8) cli.Parser {
        return .{ .a = self.arena.allocator(), .err = &self.err.writer, .name = name };
    }

    fn parse(self: *Line, args: cli.Args) !Outcome {
        const name = std.mem.sliceTo(args[0], 0);
        const rest = args[1..];
        const p = self.parser(name);
        const eq = std.mem.eql;
        const exit: ?cli.Exit = if (eq(u8, name, "validate")) blk: {
            var v: cli.Validate = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "verify")) blk: {
            var v: cli.Verify = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "graph")) blk: {
            var v: cli.Graph = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "plan") or eq(u8, name, "dry-run")) blk: {
            var v: cli.Plan = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "explain")) blk: {
            var v: cli.Plan = .{ .explain = true };
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "run")) blk: {
            var v: cli.Run = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "watch") or eq(u8, name, "status")) blk: {
            var v: cli.Watch = .{ .summary = eq(u8, name, "status") };
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "report")) blk: {
            var v: cli.Report = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "logs")) blk: {
            var v: cli.Logs = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "clean")) blk: {
            var v: cli.Clean = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "control")) blk: {
            var v: cli.Control = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "init")) blk: {
            var v: cli.Init = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "prepare")) blk: {
            var v: cli.Prepare = .{};
            break :blk try v.parse(p, rest);
        } else if (eq(u8, name, "schema")) try cli.noArguments(p, rest) else if (eq(u8, name, "completion")) cli.completionShell(p, rest) else return error.UnknownCommandInTest;
        return .{ .exit = exit, .err = self.err.written() };
    }
};

fn expectRefused(words: cli.Args, want: []const u8) !void {
    var l = Line.init();
    defer l.deinit();
    const got = try l.parse(words);
    if (got.exit != cli.Exit.usage or !std.mem.eql(u8, got.err, want)) {
        for (words) |w| std.debug.print("{s} ", .{w});
        std.debug.print("\nexit: {any}\nstderr: {s}\nwanted: {s}\n", .{ got.exit, got.err, want });
        return error.TestUnexpectedResult;
    }
}

fn expectAccepted(words: cli.Args) !void {
    var l = Line.init();
    defer l.deinit();
    const got = try l.parse(words);
    if (got.exit != null or got.err.len > 0) {
        for (words) |w| std.debug.print("{s} ", .{w});
        std.debug.print("\nexit: {any}\nstderr: {s}\n", .{ got.exit, got.err });
        return error.TestUnexpectedResult;
    }
}

test "[unit] - [command line]: run options set the launch options" {
    var l = Line.init();
    defer l.deinit();
    var r: cli.Run = .{};
    const a = &.{ "wf.toml", "-j", "4", "--max-threads=16", "--max-memory", "2G", "-r", "3", "--timeout", "1h30m", "--grace", "0s", "-k", "--rerun", "--rerun-rule", "b", "--no-isolation", "-q", "--json", "--no-color", "--pass-env", "HOME", "--threads", "align=8", "--input-manifest", "m.json", "-t", "c", "-d", "work" };
    try testing.expectEqual(@as(?cli.Exit, null), try r.parse(l.parser("run"), a));
    const o = r.opts;
    try testing.expectEqualStrings("wf.toml", r.common.workflow.?);
    try testing.expectEqualStrings("work", r.common.workdir.?);
    try testing.expectEqualStrings("c", r.common.targets.items[0]);
    try testing.expectEqual(@as(?u32, 4), o.jobs);
    try testing.expectEqual(@as(?u32, 16), o.max_threads);
    try testing.expectEqual(@as(?u64, 2048), o.max_memory_mib);
    try testing.expectEqual(@as(u32, 3), o.retry);
    try testing.expectEqual(@as(?u64, 5400), o.timeout_s);
    try testing.expectEqual(@as(u64, 0), o.grace_s);
    try testing.expect(o.keep_going and o.rerun and !o.isolation and o.quiet and o.json and !o.color);
    try testing.expectEqualStrings("b", o.rerun_rules[0]);
    try testing.expectEqualStrings("HOME", o.pass_env[0]);
    try testing.expectEqualStrings("align=8", o.thread_overrides[0]);
    try testing.expectEqualStrings("m.json", o.input_manifest.?);
    try testing.expectEqualStrings("", l.err.written());
}

test "[failure] - [command line]: a wrong value is refused with its option, the value and a hint" {
    try expectRefused(&.{ "run", "-j", "0" }, "kanit: -j: invalid value '0' (use a whole number above 0)\n");
    try expectRefused(&.{ "run", "--jobs=x" }, "kanit: --jobs: invalid value 'x' (use a whole number above 0)\n");
    try expectRefused(&.{ "run", "--max-threads", "0" }, "kanit: --max-threads: invalid value '0' (use a whole number above 0)\n");
    try expectRefused(&.{ "run", "--max-memory", "1025T" }, "kanit: --max-memory: invalid value '1025T' (use a size from 1M to 1024T, such as 512M or 60G)\n");
    try expectRefused(&.{ "run", "-r", "4" }, "kanit: -r: invalid value '4' (use 0 to 3)\n");
    try expectRefused(&.{ "run", "--timeout", "0" }, "kanit: --timeout: invalid value '0' (use a duration such as 90s, 30m or 2h)\n");
    try expectRefused(&.{ "run", "--grace", "soon" }, "kanit: --grace: invalid value 'soon' (use a duration such as 10s or 1m, or 0)\n");
    try expectRefused(&.{ "run", "--slice", "work" }, "kanit: --slice: invalid value 'work' (use a unit name ending in .slice, without /)\n");
    try expectRefused(&.{ "run", "--slice", "a/b.slice" }, "kanit: --slice: invalid value 'a/b.slice' (use a unit name ending in .slice, without /)\n");
    try expectRefused(&.{ "run", "--slice", ".slice" }, "kanit: --slice: invalid value '.slice' (use a unit name ending in .slice, without /)\n");
    try expectRefused(&.{ "run", "--pass-env", "1X" }, "kanit: --pass-env: invalid value '1X' (use a variable name such as HOME)\n");
    try expectRefused(&.{ "plan", "--budget", "--max-threads", "0" }, "kanit: --max-threads: invalid value '0' (use a whole number above 0)\n");
    try expectRefused(&.{ "plan", "--pass-env", "A-B" }, "kanit: --pass-env: invalid value 'A-B' (use a variable name such as HOME)\n");
    try expectRefused(&.{ "graph", "--by", "rule" }, "kanit: --by: invalid value 'rule' (use step)\n");
    try expectRefused(&.{ "graph", "--layer", "edges" }, "kanit: --layer: invalid value 'edges' (use rules, files, resources or all)\n");
    try expectRefused(&.{ "graph", "--format", "svg" }, "kanit: --format: invalid value 'svg' (use dot, json or text)\n");
    try expectRefused(&.{ "graph", "--why", "ab" }, "kanit: --why: invalid value 'ab' (use FROM:TO, two rule names)\n");
    try expectRefused(&.{ "watch", "--interval", "99" }, "kanit: --interval: invalid value '99' (use 100 ms or more)\n");
    try expectRefused(&.{ "watch", "--interval", "1s" }, "kanit: --interval: invalid value '1s' (use milliseconds as a whole number)\n");
    try expectRefused(&.{ "logs", "a", "--attempt", "x" }, "kanit: --attempt: invalid value 'x' (use a whole number)\n");
    try expectRefused(&.{ "logs", "a", "--launch", ".." }, "kanit: --launch: invalid value '..' (use a launch ID, as status --history lists them)\n");
    try expectRefused(&.{ "report", "--launch", "a/b" }, "kanit: --launch: invalid value 'a/b' (use a launch ID, as status --history lists them)\n");
    try expectRefused(&.{ "report", "--format", "pdf" }, "kanit: --format: invalid value 'pdf' (use tsv, json or html)\n");
    try expectRefused(&.{ "clean", "--keep", "-1" }, "kanit: --keep: invalid value '-1' (use a whole number)\n");
}

test "[edge] - [command line]: a zero grace period is written as 0 with or without a unit" {
    inline for (.{ "0", "0s", "00m" }) |text| {
        var l = Line.init();
        defer l.deinit();
        var r: cli.Run = .{};
        try testing.expectEqual(@as(?cli.Exit, null), try r.parse(l.parser("run"), &.{ "--grace", text }));
        try testing.expectEqual(@as(u64, 0), r.opts.grace_s);
    }
}

test "[failure] - [command line]: an option needs its value, refuses one it does not take, and names a close option" {
    try expectRefused(&.{ "run", "-j" }, "kanit: -j needs a value\n");
    try expectRefused(&.{ "run", "-j", "-q" }, "kanit: -j needs a value\n");
    try expectRefused(&.{ "run", "--jobs=" }, "kanit: --jobs needs a value\n");
    try expectRefused(&.{ "run", "-d" }, "kanit: -d needs a value\n");
    try expectRefused(&.{ "run", "--target" }, "kanit: --target needs a value\n");
    try expectRefused(&.{ "run", "--keep-going=yes" }, "kanit: --keep-going takes no value\n");
    try expectRefused(&.{ "run", "--jbos", "2" }, "kanit: unknown option '--jbos' for run; did you mean '--jobs'?\nRun 'kanit help run' for its options.\n");
    try expectRefused(&.{ "run", "--zzzz" }, "kanit: unknown option '--zzzz' for run\nRun 'kanit help run' for its options.\n");
    try expectRefused(&.{ "status", "-t", "a" }, "kanit: unknown option '-t' for status\nRun 'kanit help status' for its options.\n");
    try expectRefused(&.{ "explain", "--summary", "a" }, "kanit: unknown option '--summary' for explain\nRun 'kanit help explain' for its options.\n");
    try expectRefused(&.{ "watch", "--json" }, "kanit: unknown option '--json' for watch\nRun 'kanit help watch' for its options.\n");
    try expectRefused(&.{ "status", "--once" }, "kanit: unknown option '--once' for status\nRun 'kanit help status' for its options.\n");
    try expectRefused(&.{ "logs", "a", "--stdout", "--stderr" }, "kanit: give --stdout or --stderr; without either, logs prints both\n");
    try expectRefused(&.{ "report", "--format", "tsv", "--json" }, "kanit: give one format; --json is --format json\n");
}

test "[edge] - [command line]: words after -- are not options, and a negative number is a value" {
    var l = Line.init();
    defer l.deinit();
    var r: cli.Run = .{};
    try testing.expectEqual(@as(?cli.Exit, null), try r.parse(l.parser("run"), &.{ "--", "-k" }));
    try testing.expectEqualStrings("-k", r.common.workflow.?);
    try testing.expect(!r.opts.keep_going);
    try expectRefused(&.{ "run", "-j", "-4" }, "kanit: -j: invalid value '-4' (use a whole number above 0)\n");
    try expectAccepted(&.{ "run", "--", "wf.toml" });
}

test "[failure] - [command line]: options that cannot go together are refused before any file is read" {
    try expectRefused(&.{ "graph", "--focus", "a+", "--why", "a:b" }, "kanit: choose one of --focus, --why and --users\n");
    try expectRefused(&.{ "graph", "--users", "ref", "--why", "a:b" }, "kanit: choose one of --focus, --why and --users\n");
    try expectRefused(&.{ "report", "--suggest", "--methods" }, "kanit: choose one of --suggest, --compare, --bottlenecks and --methods\n");
    try expectRefused(&.{ "report", "--methods", "--launch", "x" }, "kanit: --methods describes the results recorded in the working directory, whatever launch made them; drop --launch\n");
    try expectRefused(&.{ "report", "--methods", "--format", "tsv" }, "kanit: --methods prints text, or JSON with --format json\n");
    try expectRefused(&.{ "report", "--bottlenecks", "--json" }, "kanit: --bottlenecks and --compare print text; --format applies to the attempt table and --suggest\n");
    try expectRefused(&.{ "report", "--suggest", "--format", "html" }, "kanit: --suggest prints tsv or json, not html\n");
    try expectRefused(&.{ "status", "--history", "--json" }, "kanit: --history prints text; --json applies to the summary\n");
    try expectRefused(&.{ "status", "--history", "3", "--launch", "x" }, "kanit: --history lists the recent launches; --launch names one\n");
    try expectRefused(&.{ "plan", "--max-threads", "2" }, "kanit: --max-threads sets the budget --budget checks; give --budget too\n");
    try expectRefused(&.{ "plan", "--max-memory", "2G" }, "kanit: --max-memory sets the budget --budget checks; give --budget too\n");
    try expectRefused(&.{ "run", "--slice", "a.slice", "--no-isolation" }, "kanit: --slice places the run's scope, which --no-isolation does not make; give one of them\n");
    try expectAccepted(&.{ "plan", "--budget", "--max-threads", "2", "--max-memory", "2G" });
    try expectAccepted(&.{ "report", "--methods", "--json" });
    try expectAccepted(&.{ "report", "--suggest", "--format", "json" });
}

test "[unit] - [command line]: the HTML report goes to a file or a pipe, not to a terminal" {
    var l = Line.init();
    defer l.deinit();
    var to_terminal: cli.Report = .{ .stdout_terminal = true };
    try testing.expectEqual(@as(?cli.Exit, .usage), try to_terminal.parse(l.parser("report"), &.{ "--format", "html" }));
    try testing.expectEqualStrings("kanit: the HTML page is for a browser: write it with -o report.html, or redirect standard output\n", l.err.written());
    var to_file: cli.Report = .{ .stdout_terminal = true };
    try testing.expectEqual(@as(?cli.Exit, null), try to_file.parse(l.parser("report"), &.{ "--format", "html", "-o", "r.html" }));
    var to_pipe: cli.Report = .{};
    try testing.expectEqual(@as(?cli.Exit, null), try to_pipe.parse(l.parser("report"), &.{ "--format", "html" }));
    try testing.expectEqual(cli.ReportFormat.html, to_pipe.kind());
}

test "[failure] - [command line]: each command takes the words its usage names and refuses the rest" {
    try expectRefused(&.{ "validate", "a.toml", "b.toml" }, "kanit: unexpected argument 'b.toml'; run 'kanit help validate' for the usage\n");
    try expectRefused(&.{"explain"}, "kanit: explain needs a rule name\n");
    try expectRefused(&.{ "explain", "wf.toml", "a", "b" }, "kanit: explain takes one rule name\n");
    try expectRefused(&.{"logs"}, "kanit: logs needs a rule name\n");
    try expectRefused(&.{ "logs", "wf.toml", "a", "b" }, "kanit: logs takes one rule name\n");
    try expectRefused(&.{ "control", "stop" }, "kanit: control needs: stop RULE, retry RULE, or cancel\n");
    try expectRefused(&.{ "control", "cancel", "a" }, "kanit: control needs: stop RULE, retry RULE, or cancel\n");
    try expectRefused(&.{ "control", "pause", "a" }, "kanit: control needs: stop RULE, retry RULE, or cancel\n");
    try expectRefused(&.{ "init", "a.toml", "b.toml" }, "kanit: init takes at most one file name\n");
    try expectRefused(&.{ "init", "-" }, "kanit: init needs a file name, not '-'\n");
    try expectRefused(&.{ "init", "--force" }, "kanit: unknown option '--force' for init\nRun 'kanit help init' for its options.\n");
    try expectRefused(&.{ "prepare", "a.toml", "b.toml" }, "kanit: prepare takes one template file\n");
    try expectRefused(&.{ "prepare", "-o" }, "kanit: -o needs a value\n");
    try expectRefused(&.{ "prepare", "--output=" }, "kanit: --output needs a value\n");
    try expectRefused(&.{ "prepare", "--params", "-x" }, "kanit: --params needs a value\n");
    try expectRefused(&.{ "schema", "x" }, "kanit: schema takes no arguments\n");
    try expectRefused(&.{ "schema", "--json" }, "kanit: unknown option '--json' for schema\nRun 'kanit help schema' for its options.\n");
    try expectRefused(&.{ "completion", "zsh" }, "kanit: completion supports: bash\n");
    try expectAccepted(&.{ "completion", "bash" });
    try expectAccepted(&.{ "init", "--template", "p.toml" });
    try expectAccepted(&.{ "prepare", "p.toml", "--params=run.toml", "--output", "w.toml", "--check" });
}

test "[unit] - [command line]: the rule and verb of explain, logs and control come from the words given" {
    var l = Line.init();
    defer l.deinit();
    var e: cli.Plan = .{ .explain = true };
    _ = try e.parse(l.parser("explain"), &.{"align"});
    try testing.expectEqualStrings("align", e.rule);
    try testing.expectEqual(@as(?[]const u8, null), e.common.workflow);
    var e2: cli.Plan = .{ .explain = true };
    _ = try e2.parse(l.parser("explain"), &.{ "wf.toml", "align" });
    try testing.expectEqualStrings("align", e2.rule);
    try testing.expectEqualStrings("wf.toml", e2.common.workflow.?);
    var lg: cli.Logs = .{};
    _ = try lg.parse(l.parser("logs"), &.{ "wf.toml", "align", "--stderr", "--attempt", "2" });
    try testing.expectEqualStrings("align", lg.rule);
    try testing.expectEqual(@as(?u32, 2), lg.opts.attempt);
    var c1: cli.Control = .{};
    _ = try c1.parse(l.parser("control"), &.{ "stop", "align" });
    try testing.expectEqualStrings("stop", c1.verb);
    try testing.expectEqualStrings("align", c1.rule.?);
    try testing.expectEqual(@as(?[]const u8, null), c1.common.workflow);
    var c2: cli.Control = .{};
    _ = try c2.parse(l.parser("control"), &.{ "wf.toml", "cancel" });
    try testing.expectEqualStrings("cancel", c2.verb);
    try testing.expectEqual(@as(?[]const u8, null), c2.rule);
    try testing.expectEqualStrings("wf.toml", c2.common.workflow.?);
    var st: cli.Watch = .{ .summary = true };
    _ = try st.parse(l.parser("status"), &.{"--history"});
    try testing.expectEqual(@as(?usize, 10), st.history);
    try testing.expect(st.once);
    try testing.expectEqualStrings("", l.err.written());
}

test "[unit] - [command line]: an unknown command names the closest one" {
    var l = Line.init();
    defer l.deinit();
    try testing.expectEqual(cli.Exit.usage, l.parser("valdate").unknownCommand());
    try testing.expectEqualStrings("kanit: unknown command 'valdate'; did you mean 'validate'?\nRun 'kanit help' for the commands.\n", l.err.written());
    var l2 = Line.init();
    defer l2.deinit();
    _ = l2.parser("zzz").unknownCommand();
    try testing.expectEqualStrings("kanit: unknown command 'zzz'\nRun 'kanit help' for the commands.\n", l2.err.written());
}

test "[property] - [command line]: every option the help lists is one its command parses" {
    for (cli.commands) |c| {
        if (std.mem.eql(u8, c.name, "help") or std.mem.eql(u8, c.name, "version")) continue;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        for (try cli.optionNames(arena.allocator(), &c)) |flag| {
            var l = Line.init();
            defer l.deinit();
            const word = try l.arena.allocator().dupeZ(u8, flag);
            const name = try l.arena.allocator().dupeZ(u8, c.name);
            const a = [_][:0]const u8{ name, word };
            const got = try l.parse(&a);
            if (std.mem.indexOf(u8, got.err, "unknown option") != null) {
                std.debug.print("{s} lists {s}, which it does not parse\n", .{ c.name, flag });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "[unit] - [command line]: the help lists every command, and each command's help starts with its usage" {
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try cli.writeOverview(&text.writer, .{ .on = false });
    for (cli.commands) |c| try testing.expect(std.mem.indexOf(u8, text.written(), c.name) != null);
    for (cli.commands) |c| {
        text.clearRetainingCapacity();
        try cli.writeCommandHelp(&text.writer, &c, .{ .on = false });
        const usage = try std.fmt.allocPrint(testing.allocator, "usage: kanit {s}", .{c.name});
        defer testing.allocator.free(usage);
        try testing.expect(std.mem.startsWith(u8, text.written(), usage));
    }
    try testing.expect(cli.command("dry-run") == cli.command("plan"));
}

test "[failure] - [command line]: thread overrides and rerun rules are checked against the workflow" {
    var s = try helpers.Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    const rules = "[[rules]]\nname = \"align_s1\"\noutput = [\"a.txt\"]\nshell = \"touch a.txt\"\nmemory = \"64M\"\nstep = \"align\"\n\n" ++
        "[[rules]]\nname = \"count_s1\"\ninput = [\"a.txt\"]\noutput = [\"b.txt\"]\nshell = \"touch b.txt\"\nmemory = \"64M\"\nstep = \"count\"\n";
    var wf = try helpers.loadText(&s, helpers.head ++ rules, &problem);
    defer wf.deinit();
    const Case = struct { overrides: []const []const u8, err: []const u8 };
    const cases = [_]Case{
        .{ .overrides = &.{"align"}, .err = "kanit: --threads align: give a step and a thread count, such as align=16\n" },
        .{ .overrides = &.{"=4"}, .err = "kanit: --threads =4: give a step and a thread count, such as align=16\n" },
        .{ .overrides = &.{"align=0"}, .err = "kanit: --threads align=0: the thread count must be a whole number from 1 to 4096\n" },
        .{ .overrides = &.{"align=4097"}, .err = "kanit: --threads align=4097: the thread count must be a whole number from 1 to 4096\n" },
        .{ .overrides = &.{"align=+4"}, .err = "kanit: --threads align=+4: the thread count must be a whole number from 1 to 4096\n" },
        .{ .overrides = &.{"align="}, .err = "kanit: --threads align=: the thread count must be a whole number from 1 to 4096\n" },
        .{ .overrides = &.{"alin=4"}, .err = "kanit: --threads alin=4: no rule has step 'alin'; did you mean 'align'?\n" },
        .{ .overrides = &.{"qqqqqq=4"}, .err = "kanit: --threads qqqqqq=4: no rule has step 'qqqqqq'\n" },
    };
    for (cases) |c| {
        var l = Line.init();
        defer l.deinit();
        try testing.expectEqual(@as(?cli.Exit, .usage), try l.parser("run").applyThreads(&wf, c.overrides));
        try testing.expectEqualStrings(c.err, l.err.written());
    }
    var l = Line.init();
    defer l.deinit();
    try testing.expectEqual(@as(?cli.Exit, null), try l.parser("run").applyThreads(&wf, &.{ "align=8", "count=2" }));
    try testing.expectEqual(@as(u32, 8), wf.rules[0].threads);
    try testing.expectEqual(@as(u32, 2), wf.rules[1].threads);
    try testing.expectEqual(@as(?cli.Exit, null), try l.parser("run").knownRules(&wf, &.{"count_s1"}));
    try testing.expectEqual(@as(?cli.Exit, .usage), try l.parser("run").knownRules(&wf, &.{"count_s2"}));
    try testing.expectEqualStrings("kanit: --rerun-rule count_s2: no such rule; did you mean 'count_s1'?\n", l.err.written());
}

test "[property] - [command line]: every help text fits in 80 columns" {
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try cli.writeOverview(&text.writer, .{ .on = false });
    for (cli.commands) |c| try cli.writeCommandHelp(&text.writer, &c, .{ .on = false });
    var lines = std.mem.splitScalar(u8, text.written(), '\n');
    while (lines.next()) |line| {
        if (try std.unicode.utf8CountCodepoints(line) > 80) {
            std.debug.print("too wide: {s}\n", .{line});
            return error.TestUnexpectedResult;
        }
    }
}
