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
    // /w must be writable for top.txt, which also covers /w/out.
    try testing.expectEqual(@as(usize, 3), ms.len);
    try testing.expectEqualStrings("/data/reads", ms[0].dir);
    try testing.expect(!ms[0].write);
    try testing.expectEqualStrings("/data/ref", ms[1].dir);
    try testing.expect(!ms[1].write);
    try testing.expectEqualStrings("/w", ms[2].dir);
    try testing.expect(ms[2].write);

    rule.output_abs = &.{ "/w/out/a.txt", "/w/out/sub/b.txt" };
    const nested = try workz.container.mounts(a, "/w", &rule, &.{});
    try testing.expectEqualStrings("/w", nested[2].dir);
    try testing.expect(!nested[2].write);
    try testing.expectEqualStrings("/w/out", nested[3].dir);
    try testing.expect(nested[3].write);
    try testing.expectEqual(@as(usize, 4), nested.len);
}

test "a service may load produced files only for rules that depend on their producer" {
    const svc = "[shared.idx]\npath = \"idx\"\ncontainer = \"img\"\ncommand = \"load idx\"\nmemory = \"1G\"\n\n" ++
        "[[rules]]\nname = \"build\"\noutput = [\"idx/SA\"]\nshell = \"true\"\nmemory = \"1M\"\n";
    const user = "[[rules]]\nname = \"use\"\noutput = [\"u\"]\ncontainer = \"img\"\nshell = \"true\"\n[rules.resources]\nmemory = \"1M\"\nshared = [\"idx\"]\n";
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ svc ++ user, &problem);
    defer wf.deinit();
    try testing.expectError(error.Invalid, workz.graph.build(testing.allocator, &wf, &problem));
    defer testing.allocator.free(problem.message);
    try testing.expectEqualStrings("rule use joins service 'idx', which loads idx/SA from rule build; make an output of build an input of use", problem.message);

    var s2 = try Scratch.init();
    defer s2.deinit();
    const ordered = "[[rules]]\nname = \"use\"\ninput = [\"idx/SA\"]\noutput = [\"u\"]\ncontainer = \"img\"\nshell = \"true\"\n[rules.resources]\nmemory = \"1M\"\nshared = [\"idx\"]\n";
    var wf2 = try loadText(&s2, head ++ svc ++ ordered, &problem);
    defer wf2.deinit();
    var g = try workz.graph.build(testing.allocator, &wf2, &problem);
    g.deinit();
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
