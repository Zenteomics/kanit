//! Unit tests of the workflow format: values, keys, labels, validation and
//! the graph.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const workflow = workz.workflow;
const state = workz.state;
const helpers = @import("helpers.zig");
const Scratch = helpers.Scratch;
const loadText = helpers.loadText;
const expectInvalid = helpers.expectInvalid;
const head = helpers.head;

test "memory requests use K, M, G and T suffixes and default to MiB" {
    try testing.expectEqual(@as(?u64, 64), workflow.parseMemoryMib("64M"));
    try testing.expectEqual(@as(?u64, 64), workflow.parseMemoryMib("64"));
    try testing.expectEqual(@as(?u64, 2048), workflow.parseMemoryMib("2G"));
    try testing.expectEqual(@as(?u64, 2048), workflow.parseMemoryMib("2g"));
    try testing.expectEqual(@as(?u64, 1024 * 1024), workflow.parseMemoryMib("1T"));
    try testing.expectEqual(@as(?u64, 2), workflow.parseMemoryMib("2048K"));
    try testing.expectEqual(@as(?u64, null), workflow.parseMemoryMib("512K"));
    try testing.expectEqual(@as(?u64, null), workflow.parseMemoryMib("0"));
    try testing.expectEqual(@as(?u64, null), workflow.parseMemoryMib(""));
    try testing.expectEqual(@as(?u64, null), workflow.parseMemoryMib("lots"));
    try testing.expectEqual(@as(?u64, null), workflow.parseMemoryMib("99999999999999999999G"));
}

test "durations accept bare seconds and unit sequences" {
    try testing.expectEqual(@as(?u64, 90), workflow.parseDuration("90"));
    try testing.expectEqual(@as(?u64, 90), workflow.parseDuration("90s"));
    try testing.expectEqual(@as(?u64, 5400), workflow.parseDuration("1h30m"));
    try testing.expectEqual(@as(?u64, 86400), workflow.parseDuration("1d"));
    try testing.expectEqual(@as(?u64, null), workflow.parseDuration("0"));
    try testing.expectEqual(@as(?u64, null), workflow.parseDuration("1x"));
    try testing.expectEqual(@as(?u64, null), workflow.parseDuration("h"));
    try testing.expectEqual(@as(?u64, null), workflow.parseDuration("10m5"));
}

test "closest key hint uses edit distance" {
    const keys = [_][]const u8{ "input", "output", "shell", "memory" };
    try testing.expectEqualStrings("output", workflow.closest(&keys, "outptu").?);
    try testing.expectEqualStrings("shell", workflow.closest(&keys, "shel").?);
    try testing.expectEqual(@as(?[]const u8, null), workflow.closest(&keys, "container"));
    try testing.expectEqual(@as(usize, 3), workflow.editDistance("kitten", "sitting"));
    try testing.expectEqual(@as(usize, 0), workflow.editDistance("", ""));
}

test "within accepts only a path at or below the root" {
    try testing.expect(workflow.within("/w", "/w"));
    try testing.expect(workflow.within("/w", "/w/a/b"));
    try testing.expect(!workflow.within("/w", "/work/a"));
    try testing.expect(!workflow.within("/w/a", "/w"));
}

test "[unit] - [workflow]: format 1 accepts every rule field and every table" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        \\[defaults]
        \\threads = 2
        \\memory = "1G"
        \\
        \\[resource_groups.disk]
        \\max = 2
        \\
        \\[shared.ref]
        \\path = "ref"
        \\
        \\[[rules]]
        \\name = "a.b-c_1"
        \\input = ["in.txt", "/abs/in.txt"]
        \\output = ["out/a.txt"]
        \\shell = "true"
        \\priority = -5
        \\log = "logs/a.log"
        \\benchmark = "bench/a.json"
        \\diagnostics = ["out/a/Log.out"]
        \\version = "tool --version"
        \\retries = 2
        \\timeout = "1h30m"
        \\cutoff = true
        \\[rules.resources]
        \\threads = 4
        \\memory = "512M"
        \\groups = { disk = 1 }
        \\shared = ["ref"]
        \\
        \\[[rules]]
        \\name = "defaults"
        \\output = ["d.txt"]
        \\shell = "true"
        \\
    , &problem);
    defer wf.deinit();
    const r = wf.rules[0];
    try testing.expectEqual(@as(u32, 4), r.threads);
    try testing.expectEqual(@as(u64, 512), r.memory_mib);
    try testing.expectEqual(@as(i64, -5), r.priority);
    try testing.expectEqual(@as(?u32, 2), r.retries);
    try testing.expectEqual(@as(?u64, 5400), r.timeout_s);
    try testing.expect(r.cutoff);
    try testing.expect(!wf.rules[1].cutoff);
    try testing.expectEqualStrings("disk", r.groups[0].name);
    try testing.expectEqualStrings("ref", r.shared[0]);
    try testing.expectEqualStrings("/abs/in.txt", r.input_abs[1]);
    try testing.expect(std.mem.endsWith(u8, r.output_abs[0], "/out/a.txt"));
    try testing.expectEqualStrings("out/a/Log.out", r.diagnostics[0]);
    try testing.expectEqualStrings("tool --version", r.version.?);
    try testing.expect(wf.rules[1].version == null);
    try testing.expect(std.mem.endsWith(u8, r.diagnostics_abs[0], "/out/a/Log.out"));
    try testing.expectEqual(@as(u32, 2), wf.rules[1].threads);
    try testing.expectEqual(@as(u64, 1024), wf.rules[1].memory_mib);
}

test "[unit] - [workflow]: a shared input's path is an input of the rules that use it" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        \\[shared.index]
        \\path = "ref/index"
        \\
        \\[shared.genome]
        \\path = "ref/star"
        \\container = "img"
        \\command = "true"
        \\memory = "1G"
        \\
        \\[[rules]]
        \\name = "uses"
        \\input = ["reads.fq"]
        \\output = ["a.bam"]
        \\shell = "true"
        \\memory = "1M"
        \\[rules.resources]
        \\shared = ["index"]
        \\
        \\[[rules]]
        \\name = "lists"
        \\input = ["./ref/index", "reads.fq"]
        \\output = ["b.bam"]
        \\shell = "true"
        \\memory = "1M"
        \\[rules.resources]
        \\shared = ["index"]
        \\
        \\[[rules]]
        \\name = "joins"
        \\output = ["c.bam"]
        \\container = "img"
        \\shell = "true"
        \\memory = "1M"
        \\[rules.resources]
        \\shared = ["genome"]
        \\
    , &problem);
    defer wf.deinit();
    const r = wf.rules[0];
    try testing.expectEqual(@as(usize, 2), r.input.len);
    try testing.expectEqualStrings("ref/index", r.input[1]);
    try testing.expect(std.mem.endsWith(u8, r.input_abs[1], "/ref/index"));
    try testing.expectEqual(@as(usize, 2), wf.rules[1].input.len);
    // A service's index too: a rebuilt one reruns the rules that join it.
    try testing.expectEqual(@as(usize, 1), wf.rules[2].input.len);
    try testing.expectEqualStrings("ref/star", wf.rules[2].input[0]);
}

test "format 1 rejects unknown keys, bad values and unsafe paths" {
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\nimage = \"img\"\n", "unknown key 'image'");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemroy = \"1M\"\n", "did you mean 'memory'?");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\n", "must declare memory");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nmemory = \"1M\"\n", "needs a shell command");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = []\nshell = \"true\"\nmemory = \"1M\"\n", "must declare output");
    try expectInvalid(head ++ "[[rules]]\nname = \"-x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "invalid rule name");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\nretries = 9\n", "retries must be between 0 and 3");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\ntimeout = \"soon\"\n", "invalid timeout");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\ncutoff = \"yes\"\n", "cutoff must be true or false");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\ninput = [\"*.bam\"]\n", "explicit local path");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"/tmp/x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "relative path inside the working directory");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\".workz/x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "engine record directory");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\ndiagnostics = [\"/var/log/x\"]\n", "diagnostics '/var/log/x' must be a relative path");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\nversion = \" \"\n", "version must be a command");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n[rules.resources]\ngroups = { disk = 1 }\n", "undeclared resource group");
    try expectInvalid(head ++ "[resource_groups.disk]\nmax = 1\nwait = \"queue\"\n[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "unknown key 'wait' in a resource group");
    try expectInvalid(head ++ "[shared.ref]\npath = \"r\"\n[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n[rules.resources]\nshared = [\"rfe\"]\n", "did you mean 'ref'?");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n[[rules]]\nname = \"x\"\noutput = [\"y\"]\nshell = \"true\"\nmemory = \"1M\"\n", "duplicate rule name");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\ninput = [\"x\"]\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "cannot overwrite its own input");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nlog = \"x\"\nshell = \"true\"\nmemory = \"1M\"\n", "overlaps a declared output");
    try expectInvalid("[workflow]\nname = \"t\"\nformat_version = 7\n[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "format_version 7 is not supported");
    try expectInvalid("[workflow\nname = 1\n", "line 1");
}

test "graph order puts producers first and detects cycles" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        "[[rules]]\nname = \"c\"\ninput = [\"b\"]\noutput = [\"c\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"a\"\noutput = [\"a\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"b\"\ninput = [\"a\", \"a\"]\noutput = [\"b\"]\nshell = \"true\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, g.order);
    try testing.expectEqualSlices(usize, &.{1}, g.parents[2]);
    var unknown: ?[]const u8 = null;
    const mask = try workz.graph.select(testing.allocator, &wf, &g, &.{"b"}, &unknown);
    defer testing.allocator.free(mask);
    try testing.expectEqualSlices(bool, &.{ false, true, true }, mask);
    try testing.expectError(error.UnknownTarget, workz.graph.select(testing.allocator, &wf, &g, &.{"zz"}, &unknown));

    var s2 = try Scratch.init();
    defer s2.deinit();
    var wf2 = try loadText(&s2, head ++
        "[[rules]]\nname = \"p\"\ninput = [\"q\"]\noutput = [\"p\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"q\"\ninput = [\"p\"]\noutput = [\"q\"]\nshell = \"true\"\nmemory = \"1M\"\n", &problem);
    defer wf2.deinit();
    try testing.expectError(error.Cycle, workz.graph.build(testing.allocator, &wf2, &problem));
    testing.allocator.free(problem.message);
}

test "[failure] - [graph]: a cycle error names the rules on the cycle in order" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    // `after` depends on the cycle without being on it; `x` and `y` are on it.
    var wf = try loadText(&s, head ++
        "[[rules]]\nname = \"after\"\ninput = [\"y\"]\noutput = [\"after\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"x\"\ninput = [\"z\"]\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"y\"\ninput = [\"x\"]\noutput = [\"y\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"z\"\ninput = [\"y\"]\noutput = [\"z\"]\nshell = \"true\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    try testing.expectError(error.Cycle, workz.graph.build(testing.allocator, &wf, &problem));
    defer testing.allocator.free(problem.message);
    try testing.expect(std.mem.indexOf(u8, problem.message, "x -> y -> z -> x") != null or
        std.mem.indexOf(u8, problem.message, "y -> z -> x -> y") != null or
        std.mem.indexOf(u8, problem.message, "z -> x -> y -> z") != null);
    try testing.expect(std.mem.indexOf(u8, problem.message, "after") == null);
    try testing.expect(problem.line > 0);
}

test "[unit] - [workflow]: undeclared labels are derived from the rule name and image" {
    const derive = workz.workflow.deriveLabels;
    const nf = derive("pool_01_baseline__STAR_ALIGN", null);
    try testing.expectEqualStrings("STAR_ALIGN", nf.step);
    try testing.expectEqualStrings("pool_01_baseline", nf.sample.?);
    // A single "_" names the step only: the rest is too ambiguous for a sample.
    const one = derive("classify_03JW", null);
    try testing.expectEqualStrings("classify", one.step);
    try testing.expect(one.sample == null);
    try testing.expectEqualStrings("merge", derive("merge", null).step);
    try testing.expectEqualStrings("_x", derive("_x", null).step);
    try testing.expectEqualStrings("star", derive("align_s1", "quay.io/biocontainers/star:2.7.11b--h5ca1c30_8").tool.?);
    try testing.expectEqualStrings("multiqc", derive("report", "multiqc@sha256:0123").tool.?);
    try testing.expect(derive("report", null).tool == null);
    try testing.expect(derive("report", null).category == null);
}

test "[unit] - [workflow]: declared labels replace the derived ones and are not part of the rule key" {
    var s = try Scratch.init();
    defer s.deinit();
    const rule = "[[rules]]\nname = \"s1__align\"\noutput = [\"a.txt\"]\nshell = \"touch a.txt\"\nmemory = \"64M\"\n";
    var problem: workflow.Problem = .{};
    var plain = try loadText(&s, head ++ rule, &problem);
    defer plain.deinit();
    var labelled = try loadText(&s, head ++ rule ++ "step = \"STAR_ALIGN\"\ncategory = \"alignment\"\ntool = \"STAR 2.7.11b\"\n", &problem);
    defer labelled.deinit();
    const l = labelled.rules[0].labels;
    try testing.expectEqualStrings("STAR_ALIGN", l.step);
    try testing.expectEqualStrings("alignment", l.category.?);
    try testing.expectEqualStrings("STAR 2.7.11b", l.tool.?);
    try testing.expectEqualStrings("s1", l.sample.?);
    try testing.expect(l.declared.step and l.declared.category and l.declared.tool and !l.declared.sample);
    try testing.expectEqualStrings("align", plain.rules[0].labels.step);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    var missing: ?[]const u8 = null;
    const ka = (try state.computeKey(arena.allocator(), &ids, &plain.rules[0], plain.root, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    const kb = (try state.computeKey(arena.allocator(), &ids, &labelled.rules[0], labelled.root, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expectEqualStrings(ka.key, kb.key);
}

test "[failure] - [workflow]: a label must be a short string without control characters" {
    const rule = head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n";
    try expectInvalid(rule ++ "step = \"\"\n", "step must be 1 to 200 characters");
    try expectInvalid(rule ++ "tool = \"a\\tb\"\n", "tool must be 1 to 200 characters without control characters");
    try expectInvalid(rule ++ "sample = 3\n", "sample must be a string");
    try expectInvalid(rule ++ "categry = \"qc\"\n", "did you mean 'category'?");
}

test "rule line numbers stay right across many rules" {
    const rule = "[[rules]]\nname = \"r\"\noutput = [\"o\"]\nshell = \"true\"\nmemory = \"1M\"\n";
    // head is lines 1-4; each rule is 5 lines, so the fourth starts at line 20.
    try expectInvalid(head ++ rule ++ "[[rules]]\nname = \"s\"\noutput = [\"p\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"t\"\noutput = [\"q\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++ rule, "line 20: duplicate rule name 'r'");
}

test "an input reaching a declared output through a symlinked directory is refused" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.dir("real");
    _ = try s.file("real/x", "x");
    try s.link("alias", "real");
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    const text = head ++ "[[rules]]\nname = \"a\"\noutput = [\"real/x\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"b\"\ninput = [\"alias/x\"]\noutput = [\"y\"]\nshell = \"true\"\nmemory = \"1M\"\n";
    try testing.expectError(error.Invalid, loadText(&s, text, &problem));
    try testing.expect(std.mem.endsWith(u8, problem.message, ": rule b: declare the producer path instead of the symlink 'alias/x'"));
}

test "a shared timeout belongs to a service" {
    try expectInvalid(head ++ "[shared.ref]\npath = \"ref\"\ntimeout = \"1m\"\n", "timeout limits a service's loading");
    try expectInvalid(head ++ "[shared.svc]\ncontainer = \"img\"\ncommand = \"load\"\nmemory = \"1G\"\ntimeout = \"soon\"\n", "invalid timeout 'soon'");
}

test "a workflow error shows its source line, with a caret under a known column" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workflow.snippet(&out.writer, "a = 1\noutput = [\"a\" \"b\"]\n", 2, 15);
    try testing.expectEqualStrings("  2 | output = [\"a\" \"b\"]\n    |               ^\n", out.written());
    out.clearRetainingCapacity();
    try workflow.snippet(&out.writer, "x\ny\n", 1, 0);
    try testing.expectEqualStrings("  1 | x\n", out.written());
}

test "[failure] - [workflow]: a bad comment after an array element or inline-table entry frees each value once" {
    try expectInvalid(head ++ "a = [\"x\" # c\x01\n]\n", "control character U+0001 not allowed in comment");
    try expectInvalid(head ++ "a = { b = \"x\" # c\x01\n}\n", "control character U+0001 not allowed in comment");
}

test "service retries and mounts need a service" {
    try expectInvalid(head ++ "[shared.svc]\ncontainer = \"img\"\ncommand = \"load\"\nmemory = \"1G\"\nretries = 4\n", "retries must be between 0 and 3");
    try expectInvalid(head ++ "[shared.ref]\npath = \"ref\"\nretries = 1\n", "retries start a service again");
    try expectInvalid(head ++ "[shared.ref]\npath = \"ref\"\nmounts = { \"a\" = \"/b\" }\n", "mounts place host files inside a service's image");
}

test "[unit] - [workflow]: a thread override sets every rule of its step and no other" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        \\[[rules]]
        \\name = "align_s1"
        \\output = ["a1"]
        \\shell = "true"
        \\memory = "1M"
        \\[[rules]]
        \\name = "align_s2"
        \\output = ["a2"]
        \\shell = "true"
        \\memory = "1M"
        \\[[rules]]
        \\name = "count"
        \\output = ["c"]
        \\shell = "true"
        \\memory = "1M"
        \\
    , &problem);
    defer wf.deinit();
    try testing.expectEqual(@as(usize, 2), wf.overrideThreads("align", 16));
    try testing.expectEqual(@as(u32, 16), wf.rules[0].threads);
    try testing.expectEqual(@as(u32, 16), wf.rules[1].threads);
    try testing.expectEqual(@as(u32, 1), wf.rules[2].threads);
    try testing.expectEqual(@as(usize, 0), wf.overrideThreads("algn", 2));
}

test "[unit] - [workflow]: validation reports every problem, each with its line" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    try testing.expectError(error.Invalid, loadText(&s, head ++
        \\[resource_groups.disk]
        \\max = 0
        \\
        \\[[rules]]
        \\name = "a"
        \\outputs = ["a"]
        \\output = ["a"]
        \\shell = "true"
        \\memory = "1M"
        \\
        \\[[rules]]
        \\name = "b"
        \\output = ["b"]
        \\shell = "true"
        \\memory = "lots"
        \\
    , &problem));
    try testing.expectEqual(@as(u32, 3), problem.count);
    try testing.expect(std.mem.indexOf(u8, problem.message, "resource_groups.disk.max must be between 1 and 1000000") != null);
    try testing.expect(std.mem.indexOf(u8, problem.message, "unknown key 'outputs' in a rule; did you mean 'output'?") != null);
    try testing.expect(std.mem.indexOf(u8, problem.message, "invalid memory") != null or std.mem.indexOf(u8, problem.message, "'lots'") != null);
    var lines = std.mem.splitScalar(u8, problem.message, '\n');
    while (lines.next()) |line| try testing.expect(std.mem.startsWith(u8, line, "line "));
}

test "[unit] - [workflow]: checks across rules report every rule at fault" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    try testing.expectError(error.Invalid, loadText(&s, head ++
        \\[[rules]]
        \\name = "a"
        \\output = ["x"]
        \\shell = "true"
        \\memory = "1M"
        \\[[rules]]
        \\name = "b"
        \\output = ["x"]
        \\shell = "true"
        \\memory = "1M"
        \\[[rules]]
        \\name = "c"
        \\output = ["c"]
        \\shell = "true"
        \\memory = "1M"
        \\[rules.resources]
        \\groups = { disk = 1 }
        \\
    , &problem));
    try testing.expectEqual(@as(u32, 2), problem.count);
    try testing.expect(std.mem.indexOf(u8, problem.message, "rules a and b both produce 'x'") != null);
    try testing.expect(std.mem.indexOf(u8, problem.message, "rule c uses undeclared resource group 'disk'") != null);
}

test "[unit] - [workflow]: every unknown key and the problems around them are reported" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    try testing.expectError(error.Invalid, loadText(&s,
        \\[workflow]
        \\version = "1"
        \\
        \\[[rules]]
        \\name = "a"
        \\outptu = ["a"]
        \\shel = "true"
        \\output = ["a"]
        \\shell = "true"
        \\memory = "1M"
        \\
    , &problem));
    try testing.expectEqual(@as(u32, 3), problem.count);
    try testing.expect(std.mem.indexOf(u8, problem.message, "workflow.name is required") != null);
    try testing.expect(std.mem.indexOf(u8, problem.message, "unknown key 'outptu'") != null);
    try testing.expect(std.mem.indexOf(u8, problem.message, "unknown key 'shel'") != null);
}

test "[unit] - [workflow]: a bad output does not hide a conflict with the rule's next output" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    try testing.expectError(error.Invalid, loadText(&s, head ++
        \\[[rules]]
        \\name = "a"
        \\output = ["../bad", "shared.txt"]
        \\shell = "true"
        \\memory = "1M"
        \\diagnostics = ["log.txt", "./log.txt"]
        \\[[rules]]
        \\name = "b"
        \\output = ["shared.txt"]
        \\shell = "true"
        \\memory = "1M"
        \\
    , &problem));
    try testing.expectEqual(@as(u32, 3), problem.count);
    try testing.expect(std.mem.indexOf(u8, problem.message, "'../bad' must be a relative path") != null);
    try testing.expect(std.mem.indexOf(u8, problem.message, "rule a lists diagnostics './log.txt' twice") != null);
    try testing.expect(std.mem.indexOf(u8, problem.message, "rules a and b both produce 'shared.txt'") != null);
}

test "[unit] - [schema]: every key the parser accepts has a type in the schema" {
    for (workz.schema.tables) |t| for (t.keys) |name| {
        if (workz.schema.find(t.types, name) == null) {
            std.debug.print("no schema type for key '{s}'\n", .{name});
            return error.TestUnexpectedResult;
        }
    };
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try workz.schema.write(&text.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("properties").?.object.get("rules") != null);
}

test "[unit] - [prepare]: a template becomes one rule per sample, with labels, gathers and literal braces" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("samples.tsv", "sample\tr1\n# a comment\nS1\treads/a.fq\nS2\treads/b.fq\n");
    const path = try s.file("pipeline.toml",
        \\[workflow]
        \\name = "p"
        \\[params]
        \\ref = "ref/idx"
        \\[samples]
        \\sheet = "samples.tsv"
        \\[[steps]]
        \\name = "count"
        \\for_each = "sample"
        \\input = ["{r1}", "{ref}"]
        \\output = ["counts/{sample}.txt"]
        \\shell = "awk '{print $1}' {r1} > counts/{sample}.txt -t {threads}"
        \\threads = 2
        \\memory = "1M"
        \\[[steps]]
        \\name = "merge"
        \\input = ["counts/{sample}.txt"]
        \\output = ["all.txt"]
        \\shell = "cat {input} > {output}"
        \\memory = "1M"
        \\
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problem: workz.prepare.Problem = .{};
    const text = try workz.prepare.compile(testing.allocator, arena.allocator(), path, "pipeline.toml", &problem);
    for ([_][]const u8{
        "name = \"S1__count\"\nstep = \"count\"\nsample = \"S1\"\ninput = [\"reads/a.fq\", \"ref/idx\"]",
        "shell = \"awk '{print $1}' reads/b.fq > counts/S2.txt -t 2\"",
        "input = [\"counts/S1.txt\", \"counts/S2.txt\"]",
        "shell = \"cat counts/S1.txt counts/S2.txt > all.txt\"",
    }) |want| if (std.mem.indexOf(u8, text, want) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ want, text });
        return error.TestUnexpectedResult;
    };
}

test "[unit] - [prepare]: mistakes in a template are named" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("dup.tsv", "sample\nS1\nS1\n");
    const Case = struct { text: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .text = "[workflow]\nname = \"p\"\n[[steps]]\nname = \"a\"\noutput = [\"{x}.txt\"]\nshell = \"true\"\n", .want = "output names {x}, which is no sample-sheet column, param or placeholder" },
        .{ .text = "[workflow]\nname = \"p\"\n[samples]\nnames = [\"s1\"]\n[[steps]]\nname = \"a\"\noutput = [\"a.txt\"]\nshell = \"echo {sample}\"\n", .want = "a column of the sample sheet, but the step has no for_each" },
        .{ .text = "[workflow]\nname = \"p\"\n[samples]\nsheet = \"dup.tsv\"\n[[steps]]\nname = \"a\"\noutput = [\"a.txt\"]\nshell = \"true\"\n", .want = "lists sample S1 twice" },
        .{ .text = "[workflow]\nname = \"p\"\n[[steps]]\nname = \"a\"\noutputs = [\"a.txt\"]\nshell = \"true\"\n", .want = "unknown key 'outputs'; did you mean 'output'?" },
        .{ .text = "[workflow]\nname = \"p\"\n[[rules]]\nname = \"a\"\n", .want = "write rules as [[steps]]" },
    }, 0..) |c, k| {
        var name_buf: [16]u8 = undefined;
        const path = try s.file(try std.fmt.bufPrint(&name_buf, "t{d}.toml", .{k}), c.text);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var problem: workz.prepare.Problem = .{};
        try testing.expectError(error.Invalid, workz.prepare.compile(testing.allocator, arena.allocator(), path, "t.toml", &problem));
        if (std.mem.indexOf(u8, problem.message, c.want) == null) {
            std.debug.print("message: {s}\nexpected: {s}\n", .{ problem.message, c.want });
            return error.TestUnexpectedResult;
        }
    }
}

test "[unit] - [prepare]: --check reads rule names that a comment follows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    const old = "[workflow]\nname = \"p\"\n\n[[rules]]\nname = \"S1__count\"   # SAMPLE__STEP\nshell = \"true\"\n";
    const new = "[workflow]\nname = \"p\"\n\n[[rules]]\nname = \"S1__count\"\nshell = \"true\"\n";
    try testing.expect(try workz.prepare.writeDiff(arena.allocator(), &text.writer, old, new));
    try testing.expectEqualStrings("change 1: S1__count\n", text.written());
}
