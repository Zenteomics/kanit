//! Unit tests of how text output names rules: step and sample columns, the
//! STEP/SAMPLE word, the fallback to rule names, steps with their tools,
//! samples, column widths and the lookup commands use.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const workflow = workz.workflow;
const names = workz.names;
const helpers = @import("helpers.zig");
const Scratch = helpers.Scratch;

const pipeline = helpers.head ++
    "[[rules]]\nname = \"S1__trim\"\noutput = [\"t1\"]\nshell = \"true\"\nmemory = \"1M\"\ntool = \"fastp\"\n" ++
    "[[rules]]\nname = \"S2__trim\"\noutput = [\"t2\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"S1__align\"\ninput = [\"t1\"]\noutput = [\"a1\"]\nshell = \"true\"\nmemory = \"1M\"\ncontainer = \"quay.io/biocontainers/star:2.7.11b\"\n" ++
    "[[rules]]\nname = \"S2__align\"\ninput = [\"t2\"]\noutput = [\"a2\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"matrix\"\ninput = [\"a1\", \"a2\"]\noutput = [\"m\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"make_index\"\noutput = [\"i\"]\nshell = \"true\"\nmemory = \"1M\"\n";

fn withNames(text: []const u8, check: fn (*const workflow.Workflow, *const names.Names) anyerror!void) !void {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    var wf = try helpers.loadText(&s, text, &problem);
    defer wf.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try names.Names.init(arena.allocator(), wf.rules);
    try check(&wf, &n);
}

test "[unit] - [names]: a rule with a sample shows its step and sample, and any other rule its name" {
    try withNames(pipeline, struct {
        fn check(_: *const workflow.Workflow, n: *const names.Names) !void {
            try testing.expectEqualStrings("trim", n.step[0]);
            try testing.expectEqualStrings("S1", n.sample[0]);
            try testing.expectEqualStrings("trim/S1", n.word[0]);
            try testing.expectEqualStrings("align/S2", n.word[3]);
            try testing.expectEqualStrings("matrix", n.step[4]);
            try testing.expectEqualStrings("", n.sample[4]);
            try testing.expectEqualStrings("make_index", n.word[5]);
            try testing.expectEqualStrings("make_index", n.step[5]);
        }
    }.check);
}

test "[unit] - [names]: steps keep the order of their first rule and the first tool their rules name" {
    try withNames(pipeline, struct {
        fn check(_: *const workflow.Workflow, n: *const names.Names) !void {
            try testing.expectEqual(@as(usize, 4), n.steps.len);
            try testing.expectEqualStrings("trim", n.steps[0].name);
            try testing.expectEqualStrings("fastp", n.steps[0].tool.?);
            try testing.expectEqualStrings("align", n.steps[1].name);
            try testing.expectEqualStrings("star", n.steps[1].tool.?);
            try testing.expectEqualStrings("matrix", n.steps[2].name);
            try testing.expect(n.steps[2].tool == null);
            try testing.expectEqualStrings("make", n.steps[3].name);
            try testing.expectEqual(@as(usize, 2), n.samples.len);
            try testing.expectEqualStrings("S2", n.samples[1]);
            try testing.expectEqual(@as(?u32, 1), n.sample_of[3]);
            try testing.expectEqual(@as(?u32, null), n.sample_of[4]);
            try testing.expectEqual(@as(u32, 1), n.step_of[2]);
        }
    }.check);
}

test "[unit] - [names]: a step and sample two rules share falls back to both rule names" {
    const text = helpers.head ++
        "[[rules]]\nname = \"S1__trim\"\noutput = [\"t1\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"again\"\noutput = [\"t2\"]\nshell = \"true\"\nmemory = \"1M\"\nstep = \"trim\"\nsample = \"S1\"\n";
    try withNames(text, struct {
        fn check(wf: *const workflow.Workflow, n: *const names.Names) !void {
            try testing.expectEqualStrings("S1__trim", n.word[0]);
            try testing.expectEqualStrings("again", n.step[1]);
            try testing.expectEqual(@as(?usize, null), n.find("trim/S1"));
            try testing.expectEqual(@as(?usize, null), wf.findRule("trim/S1"));
            try testing.expectEqual(@as(?usize, 1), n.find("again"));
        }
    }.check);
}

test "[unit] - [names]: a rule is found by its name or by STEP/SAMPLE, by the names and by the workflow alike" {
    try withNames(pipeline, struct {
        fn check(wf: *const workflow.Workflow, n: *const names.Names) !void {
            for ([_][]const u8{ "align/S2", "S2__align", "trim/S1", "matrix" }) |token|
                try testing.expectEqual(wf.findRule(token), n.find(token));
            try testing.expectEqual(@as(?usize, 3), wf.findRule("align/S2"));
            try testing.expectEqual(@as(?usize, null), wf.findRule("align/S3"));
            try testing.expectEqual(@as(?usize, null), wf.findRule("align/"));
            try testing.expectEqual(@as(?usize, null), wf.findRule("/S2"));
        }
    }.check);
}

test "[unit] - [names]: column widths cover the selected rules only, within their limits" {
    const long = helpers.head ++
        "[[rules]]\nname = \"S1__trim\"\noutput = [\"t1\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"a_very_long_sample_name_beyond_twenty__an_even_longer_step_name_beyond_24\"\noutput = [\"t2\"]\nshell = \"true\"\nmemory = \"1M\"\n";
    try withNames(long, struct {
        fn check(_: *const workflow.Workflow, n: *const names.Names) !void {
            const all = n.widths(null);
            try testing.expectEqual(@as(usize, names.step_max), all.step);
            try testing.expectEqual(@as(usize, names.sample_max), all.sample);
            const first = n.widths(&.{ true, false });
            try testing.expectEqual(@as(usize, 4), first.step);
            try testing.expectEqual(@as(usize, 2), first.sample);
        }
    }.check);
}

test "[unit] - [names]: --rerun-rule and --target take STEP/SAMPLE for the rule it names" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    var wf = try helpers.loadText(&s, pipeline, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const p: workz.cli.Parser = .{ .a = arena.allocator(), .err = &err.writer, .name = "run" };
    var reruns = [_][]const u8{ "align/S2", "matrix" };
    try testing.expectEqual(@as(?workz.cli.Exit, null), try p.knownRules(&wf, &reruns));
    try testing.expectEqualStrings("S2__align", reruns[0]);
    try testing.expectEqualStrings("matrix", reruns[1]);
    var unknown: ?[]const u8 = null;
    const mask = try workz.graph.select(testing.allocator, &wf, &g, &.{"align/S1"}, &unknown);
    defer testing.allocator.free(mask);
    try testing.expectEqualSlices(bool, &.{ true, false, true, false, false, false }, mask);
}

test "[unit] - [names]: a rule without a tool label or image is named by its version command's program" {
    for ([_]struct { command: []const u8, tool: ?[]const u8 }{
        .{ .command = "STAR --version", .tool = "STAR" },
        .{ .command = "bowtie2 --version | head -1", .tool = "bowtie2" },
        .{ .command = "/opt/tools/bin/samtools --version", .tool = "samtools" },
        .{ .command = "env LC_ALL=C sort --version", .tool = "sort" },
        .{ .command = "JAVA_OPTS=-Xmx1g java -version", .tool = "java" },
        .{ .command = "$(which fastp) --version", .tool = null },
    }) |c| {
        const got = workflow.commandTool(c.command);
        if (c.tool) |want| try testing.expectEqualStrings(want, got.?) else try testing.expect(got == null);
    }
    const text = helpers.head ++
        "[[rules]]\nname = \"a\"\noutput = [\"a\"]\nshell = \"true\"\nmemory = \"1M\"\nversion = \"STAR --version\"\n" ++
        "[[rules]]\nname = \"b\"\noutput = [\"b\"]\nshell = \"true\"\nmemory = \"1M\"\nversion = \"STAR --version\"\ncontainer = \"quay.io/biocontainers/star:2.7.11b\"\n" ++
        "[[rules]]\nname = \"c\"\noutput = [\"c\"]\nshell = \"true\"\nmemory = \"1M\"\nversion = \"STAR --version\"\ntool = \"star-aligner\"\n";
    try withNames(text, struct {
        fn check(_: *const workflow.Workflow, n: *const names.Names) !void {
            try testing.expectEqualStrings("STAR", n.tool[0]);
            try testing.expectEqualStrings("star", n.tool[1]);
            try testing.expectEqualStrings("star-aligner", n.tool[2]);
        }
    }.check);
}
