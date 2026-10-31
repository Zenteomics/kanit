//! Unit tests of the engine's parts: containers and services, cgroup
//! pressure, and removing launch records.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const workflow = workz.workflow;
const sys = workz.sys;
const helpers = @import("helpers.zig");
const Scratch = helpers.Scratch;
const loadText = helpers.loadText;
const head = helpers.head;

test "pressure totals are read from their some and full lines" {
    const text = "some avg10=0.00 avg60=0.10 avg300=0.00 total=1234\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=56\n";
    try testing.expectEqual(@as(?u64, 1234), workz.cgroup.pressureTotal(text, "some"));
    try testing.expectEqual(@as(?u64, 56), workz.cgroup.pressureTotal(text, "full"));
    try testing.expectEqual(@as(?u64, null), workz.cgroup.pressureTotal("garbage\n", "some"));
}

test "container mounts list each directory once with the access it needs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rule: workflow.Rule = undefined;
    rule.workdir_abs = null;
    rule.input_abs = &.{ "/w/in.txt", "/data/ref/genome.fa", "/data/ref/sub/index", "/data/reads/r1.fq" };
    rule.output_abs = &.{ "/w/out/a.txt", "/w/out/b.txt", "/w/top.txt" };
    const ms = try workz.container.mounts(a, "/w", &rule, &.{"/data/ref"});
    // /w must be writable for top.txt, which also covers /w/out; the
    // records below it stay read-only.
    try testing.expectEqual(@as(usize, 4), ms.len);
    try testing.expectEqualStrings("/data/reads", ms[0].dir);
    try testing.expect(!ms[0].write);
    try testing.expectEqualStrings("/data/ref", ms[1].dir);
    try testing.expect(!ms[1].write);
    try testing.expectEqualStrings("/w", ms[2].dir);
    try testing.expect(ms[2].write);
    try testing.expectEqualStrings("/w/.workz", ms[3].dir);
    try testing.expect(!ms[3].write);

    rule.output_abs = &.{ "/w/out/a.txt", "/w/out/sub/b.txt" };
    const nested = try workz.container.mounts(a, "/w", &rule, &.{});
    try testing.expectEqualStrings("/w", nested[2].dir);
    try testing.expect(!nested[2].write);
    try testing.expectEqualStrings("/w/out", nested[3].dir);
    try testing.expect(nested[3].write);
    try testing.expectEqual(@as(usize, 4), nested.len);
}

test "a rule that joins a service depends on the rules writing what the service loads" {
    const svc = "[shared.idx]\npath = \"idx\"\ncontainer = \"img\"\ncommand = \"load idx\"\nmemory = \"1G\"\n\n" ++
        "[[rules]]\nname = \"build\"\noutput = [\"idx/SA\"]\nshell = \"true\"\nmemory = \"1M\"\n";
    const user = "[[rules]]\nname = \"use\"\noutput = [\"u\"]\ncontainer = \"img\"\nshell = \"true\"\n[rules.resources]\nmemory = \"1M\"\nshared = [\"idx\"]\n";
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ svc ++ user, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    try testing.expectEqualSlices(usize, &.{0}, g.parents[1]);
    try testing.expect(g.produces(wf.rules[1].input_abs[0]));

    // A rule joining the service cannot write what it loads.
    var s2 = try Scratch.init();
    defer s2.deinit();
    const writes = "[[rules]]\nname = \"use\"\noutput = [\"idx/extra\"]\ncontainer = \"img\"\nshell = \"true\"\n[rules.resources]\nmemory = \"1M\"\nshared = [\"idx\"]\n";
    var wf2 = try loadText(&s2, head ++ svc ++ writes, &problem);
    defer wf2.deinit();
    try testing.expectError(error.Invalid, workz.graph.build(testing.allocator, &wf2, &problem));
    defer testing.allocator.free(problem.message);
    try testing.expect(std.mem.endsWith(u8, problem.message, ": rule use joins service 'idx' and writes idx/extra, which the service loads; the service would start before the file exists"));
}

test "[regression] - [workflow]: a file mounted into a service is an input of every rule that joins it" {
    const text = "[shared.idx]\ncontainer = \"img\"\ncommand = \"load\"\nmemory = \"1G\"\nmounts = { \"conf/load.cfg\" = \"/cfg\" }\n\n" ++
        "[[rules]]\nname = \"conf\"\noutput = [\"conf/load.cfg\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"use\"\noutput = [\"u\"]\ncontainer = \"img\"\nshell = \"true\"\n[rules.resources]\nmemory = \"1M\"\nshared = [\"idx\"]\n";
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ text, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();

    try testing.expectEqual(@as(usize, 1), wf.rules[1].input.len);
    try testing.expectEqualStrings("conf/load.cfg", wf.rules[1].input[0]);
    try testing.expectEqualSlices(usize, &.{0}, g.parents[1]);
}

test "a directory input depends on every rule writing inside it, and not on a sibling" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        "[[rules]]\nname = \"w1\"\noutput = [\"d/a.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"w2\"\noutput = [\"d/sub/b.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"sib\"\noutput = [\"d-x/c.txt\", \"d.y\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"read\"\ninput = [\"d\"]\noutput = [\"n.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, g.parents[3]);
    try testing.expect(g.produces(wf.rules[3].input_abs[0]));
}

test "a service runs in a shareable IPC namespace in its own /tmp and waits on its stop FIFO" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try workz.container.runArgv(a, .{ .podman = "podman", .name = "n", .image_id = "id", .root = "/w", .launch = "l", .cgroup_parent = null, .mounts = &.{}, .env = &.{}, .service = true, .script = "/w/s.sh" });
    var ipc = false;
    for (argv, 0..) |arg, i| {
        ipc = ipc or std.mem.eql(u8, arg, "--ipc=shareable");
        if (std.mem.eql(u8, arg, "--workdir")) try testing.expectEqualStrings("/tmp", argv[i + 1]);
    }
    try testing.expect(ipc);
    const script = try workz.container.serviceScript(a, "load");
    try testing.expect(std.mem.indexOf(u8, script, "{\nload\n} </dev/null >&2\necho ready\nread -r _ < \"$WORKZ_SERVICE_STOP\" || true\n") != null);
}

test "an image mount becomes a read-only volume at its target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = [_]workflow.ImageMount{.{ .source = "p/report.py", .source_abs = "/w/p/report.py", .target = "/opt/lib/report.py" }};
    const argv = try workz.container.runArgv(a, .{ .podman = "podman", .name = "n", .image_id = "id", .root = "/w", .launch = "l", .cgroup_parent = null, .mounts = &.{}, .env = &.{}, .image_mounts = &m, .script = "/w/s.sh" });
    var found = false;
    for (argv) |arg| found = found or std.mem.eql(u8, arg, "/w/p/report.py:/opt/lib/report.py:ro");
    try testing.expect(found);
}

test "removing a launch directory does not follow symlinks out of it" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.dir("keep");
    _ = try s.file("keep/precious", "data");
    // `gone` is removed below; the scratch cleanup then finds nothing.
    const gone = try std.fs.path.join(testing.allocator, &.{ s.path, "gone" });
    defer testing.allocator.free(gone);
    try sys.mkdir(testing.allocator, gone);
    const inner = try std.fs.path.join(testing.allocator, &.{ gone, "sub" });
    defer testing.allocator.free(inner);
    try sys.mkdir(testing.allocator, inner);
    try sys.writeFile(testing.allocator, try std.fs.path.join(a, &.{ inner, "f" }), "12345");
    try s.link("gone/sub/to-keep", "../../keep");
    const fd = try sys.openRead(testing.allocator, s.path);
    defer sys.close(fd);
    const bytes = try workz.clean.removeAt(testing.allocator, fd, "gone", false, 0);
    try testing.expect(bytes >= 5);
    try testing.expect(!sys.exists(testing.allocator, gone));
    try testing.expect(sys.exists(testing.allocator, try std.fs.path.join(a, &.{ s.path, "keep/precious" })));
}

test "[unit] - [views]: focus expressions name a rule and its depths" {
    const Focus = workz.views.Focus;
    const up = Focus.parse("+align", null).?;
    try testing.expectEqualStrings("align", up.rule);
    try testing.expectEqual(@as(?u32, Focus.all), up.up);
    try testing.expectEqual(@as(?u32, null), up.down);
    const down = Focus.parse("align+2", null).?;
    try testing.expectEqual(@as(?u32, 2), down.down);
    try testing.expectEqual(@as(?u32, null), down.up);
    const both = Focus.parse("1+align+", null).?;
    try testing.expectEqual(@as(?u32, 1), both.up);
    try testing.expectEqual(@as(?u32, Focus.all), both.down);
    try testing.expect(Focus.parse("align", null) == null);
    try testing.expect(Focus.parse("+", null) == null);
}

test "[unit] - [views]: steps collapse samples, and a shared input shows what loads and joins it" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        "[shared.genome]\npath = \"ref\"\ncontainer = \"img\"\ncommand = \"load\"\nmemory = \"1G\"\n\n" ++
        "[[rules]]\nname = \"index\"\noutput = [\"ref/SA\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"S1__align\"\noutput = [\"S1.bam\"]\ncontainer = \"img\"\nshell = \"true\"\nmemory = \"1M\"\n[rules.resources]\nshared = [\"genome\"]\n" ++
        "[[rules]]\nname = \"S2__align\"\noutput = [\"S2.bam\"]\ncontainer = \"img\"\nshell = \"true\"\nmemory = \"1M\"\n[rules.resources]\nshared = [\"genome\"]\n" ++
        "[[rules]]\nname = \"report\"\ninput = [\"S1.bam\", \"S2.bam\"]\noutput = [\"r.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);

    const steps = try workz.views.build(a, &wf, &g, mask, .{ .layer = .resources, .by_step = true });
    var kinds = [_]usize{0} ** 5;
    for (steps.nodes) |n| kinds[@intFromEnum(n.kind)] += 1;
    try testing.expectEqual(@as(usize, 3), kinds[@intFromEnum(workz.views.NodeKind.step)]);
    try testing.expectEqual(@as(usize, 1), kinds[@intFromEnum(workz.views.NodeKind.shared)]);
    var loads: usize = 0;
    var joins: usize = 0;
    for (steps.edges) |e| switch (e.kind) {
        .loads => loads += 1,
        .joins => joins += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), loads);
    try testing.expectEqual(@as(usize, 1), joins);

    const users = try workz.views.build(a, &wf, &g, mask, .{ .users = "genome" });
    try testing.expectEqual(@as(usize, 4), users.nodes.len);

    const path = try workz.views.whyPath(a, &wf, &g, mask, "index", "report");
    try testing.expectEqual(@as(usize, 3), path.len);
    try testing.expectEqualStrings("report", wf.rules[path[2]].name);
    try testing.expectError(error.NoPath, workz.views.whyPath(a, &wf, &g, mask, "report", "index"));
    // A path runs through the selected rules only.
    const narrow = try a.dupe(bool, mask);
    narrow[wf.ruleIndex("report").?] = false;
    try testing.expectError(error.NotSelected, workz.views.whyPath(a, &wf, &g, narrow, "index", "report"));
}

test "[unit] - [run]: a rule's budget need counts its request, its client and each shared input once" {
    var s = try Scratch.init();
    defer s.deinit();
    // 5000 bytes take two 4 KiB pages: 1 MiB once rounded up.
    _ = try s.file("ref.fa", "x" ** 5000);
    const text = head ++ "[shared.ref]\npath = \"ref.fa\"\n\n[shared.svc]\ncontainer = \"img\"\ncommand = \"load\"\nmemory = \"100M\"\n\n[shared.gone]\npath = \"missing-ref\"\n\n" ++
        "[[rules]]\nname = \"host\"\noutput = [\"h\"]\nshell = \"true\"\n[rules.resources]\nmemory = \"10M\"\nshared = [\"ref\"]\n" ++
        "[[rules]]\nname = \"box\"\noutput = [\"b\"]\ncontainer = \"img\"\nshell = \"true\"\n[rules.resources]\nmemory = \"10M\"\nshared = [\"ref\", \"svc\"]\n" ++
        "[[rules]]\nname = \"far\"\noutput = [\"f\"]\nshell = \"true\"\n[rules.resources]\nmemory = \"10M\"\nshared = [\"gone\"]\n";
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    var wf = try loadText(&s, text, &problem);
    defer wf.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failure: []const u8 = "";

    // `far` does not run, so its missing shared input is never measured.
    const sizes = try workz.run.sharedSizes(testing.allocator, a, &wf, &.{ true, true, false }, &failure);

    try testing.expectEqual(@as(u64, 1), sizes[0].?.mib);
    try testing.expectEqual(@as(u64, 100 + workz.run.container_client_mib), sizes[1].?.reserve_mib);
    try testing.expect(sizes[2] == null);
    try testing.expectEqual(@as(u64, 10 + 1), workz.run.neededMib(&wf.rules[0], sizes));
    try testing.expectEqual(@as(u64, 10 + workz.run.container_client_mib + 1 + 100 + workz.run.container_client_mib), workz.run.neededMib(&wf.rules[1], sizes));
    try testing.expectError(error.Unmeasurable, workz.run.sharedSizes(testing.allocator, a, &wf, &.{ false, false, true }, &failure));
    try testing.expectEqualStrings("shared input gone (missing-ref): no such file or directory", failure);
}

test "[unit] - [cgroup]: counters are read from the cgroup files, and a missing file reads as unknown" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("memory.peak", "314572800\n");
    _ = try s.file("memory.events", "low 0\nhigh 0\nmax 3\noom 1\noom_kill 1\noom_group_kill 0\n");
    _ = try s.file("cpu.stat", "usage_usec 2500000\nuser_usec 2000000\nsystem_usec 500000\n");
    _ = try s.file("memory.pressure", "some avg10=0.00 avg60=0.00 avg300=0.00 total=77\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=5\n");
    _ = try s.file("memory.stat", "anon 1000\nfile 4096\n");

    const c = workz.cgroup.read(testing.allocator, s.path);

    try testing.expectEqual(@as(?u64, 314572800), c.memory_peak);
    try testing.expectEqual(@as(?u64, null), c.memory_current);
    try testing.expectEqual(@as(u64, 1), c.oom_kill);
    try testing.expectEqual(@as(u64, 3), c.memory_max_events);
    try testing.expectEqual(@as(?u64, 2500000), c.cpu_usage_usec);
    try testing.expectEqual(@as(?u64, 77), c.memory_some_us);
    try testing.expectEqual(@as(?u64, 5), c.memory_full_us);
    try testing.expectEqual(@as(?u64, null), c.io_some_us);
    try testing.expectEqual(@as(?u64, 4096), c.file);
}

test "[unit] - [views]: a service whose path is one rule's output shows that rule as what it loads" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        "[shared.idx]\npath = \"idx.bin\"\ncontainer = \"img\"\ncommand = \"load\"\nmemory = \"1G\"\n\n" ++
        "[[rules]]\nname = \"make\"\noutput = [\"idx.bin\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"use\"\noutput = [\"u.txt\"]\ncontainer = \"img\"\nshell = \"true\"\nmemory = \"1M\"\n[rules.resources]\nshared = [\"idx\"]\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);
    const v = try workz.views.build(a, &wf, &g, mask, .{ .users = "idx" });
    var loads: usize = 0;
    for (v.edges) |e| loads += @intFromBool(e.kind == .loads);
    try testing.expectEqual(@as(usize, 1), loads);
}

test "[unit] - [views]: a focus on a rule named with digits reads as that rule" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        "[[rules]]\nname = \"12\"\noutput = [\"a.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"b\"\ninput = [\"a.txt\"]\noutput = [\"b.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    const Focus = workz.views.Focus;
    const down = Focus.parse("12+", &wf).?;
    try testing.expectEqualStrings("12", down.rule);
    try testing.expectEqual(@as(?u32, Focus.all), down.down);
    try testing.expectEqual(@as(?u32, null), down.up);
    const up = Focus.parse("1+b", &wf).?;
    try testing.expectEqualStrings("b", up.rule);
    try testing.expectEqual(@as(?u32, 1), up.up);
}
