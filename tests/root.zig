//! Unit tests for workz modules. Process behaviour is checked separately by
//! validation/process.sh with real children, cgroups and signals.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const workflow = workz.workflow;
const state = workz.state;
const sys = workz.sys;

test {
    testing.refAllDecls(workz);
    testing.refAllDecls(workz.workflow);
    testing.refAllDecls(workz.graph);
    testing.refAllDecls(workz.state);
    testing.refAllDecls(workz.records);
    testing.refAllDecls(workz.process);
    testing.refAllDecls(workz.cgroup);
    testing.refAllDecls(workz.sys);
}

test "the version is a semantic version" {
    var it = std.mem.splitScalar(u8, workz.version, '.');
    var parts: usize = 0;
    while (it.next()) |p| : (parts += 1) _ = try std.fmt.parseInt(u32, p, 10);
    try std.testing.expectEqual(@as(usize, 3), parts);
}

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

/// A temporary working directory under /var/tmp, removed file by file.
const Scratch = struct {
    path: []u8,
    files: std.ArrayList([]u8) = .empty,
    dirs: std.ArrayList([]u8) = .empty,

    fn init() !Scratch {
        var rnd: [6]u8 = undefined;
        sys.randomBytes(&rnd);
        const path = try std.fmt.allocPrint(testing.allocator, "/var/tmp/workz-test-{s}", .{&std.fmt.bytesToHex(rnd, .lower)});
        try sys.mkdir(testing.allocator, path);
        return .{ .path = path };
    }

    fn file(self: *Scratch, name: []const u8, bytes: []const u8) ![]const u8 {
        const p = try std.fs.path.join(testing.allocator, &.{ self.path, name });
        try sys.writeFile(testing.allocator, p, bytes);
        try self.files.append(testing.allocator, p);
        return p;
    }

    fn deinit(self: *Scratch) void {
        const linux = std.os.linux;
        for (self.files.items) |f| {
            const z = testing.allocator.dupeZ(u8, f) catch unreachable;
            _ = linux.unlinkat(linux.AT.FDCWD, z, 0);
            testing.allocator.free(z);
            testing.allocator.free(f);
        }
        self.files.deinit(testing.allocator);
        self.dirs.deinit(testing.allocator);
        sys.rmdir(testing.allocator, self.path) catch {};
        testing.allocator.free(self.path);
    }
};

fn loadText(s: *Scratch, text: []const u8, problem: *workflow.Problem) !workflow.Workflow {
    const p = try s.file("wf.toml", text);
    return workflow.load(testing.allocator, p, s.path, problem);
}

fn expectInvalid(text: []const u8, needle: []const u8) !void {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    var wf = loadText(&s, text, &problem) catch |err| {
        try testing.expectEqual(error.Invalid, err);
        if (std.mem.indexOf(u8, problem.message, needle) == null) {
            std.debug.print("message: {s}\nexpected to contain: {s}\n", .{ problem.message, needle });
            return error.TestUnexpectedResult;
        }
        return;
    };
    wf.deinit();
    return error.TestExpectedInvalid;
}

const head = "[workflow]\nname = \"t\"\nversion = \"1\"\n\n";

test "format 1 accepts every rule field and the oxo-local resource tables" {
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
        \\wait = "queue"
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
        \\retries = 2
        \\timeout = "1h30m"
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
    try testing.expectEqualStrings("disk", r.groups[0].name);
    try testing.expectEqualStrings("ref", r.shared[0]);
    try testing.expectEqualStrings("/abs/in.txt", r.input_abs[1]);
    try testing.expect(std.mem.endsWith(u8, r.output_abs[0], "/out/a.txt"));
    try testing.expectEqual(@as(u32, 2), wf.rules[1].threads);
    try testing.expectEqual(@as(u64, 1024), wf.rules[1].memory_mib);
}

test "format 1 rejects unknown keys, bad values and unsafe paths" {
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\ncontainer = \"img\"\n", "unknown key 'container'");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemroy = \"1M\"\n", "did you mean 'memory'?");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\n", "must declare memory");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nmemory = \"1M\"\n", "needs a shell command");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = []\nshell = \"true\"\nmemory = \"1M\"\n", "must declare output");
    try expectInvalid(head ++ "[[rules]]\nname = \"-x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "invalid rule name");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\nretries = 9\n", "retries must be between 0 and 3");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\ntimeout = \"soon\"\n", "invalid timeout");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\ninput = [\"*.bam\"]\n", "explicit local path");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"/tmp/x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "relative path inside the working directory");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\".workz/x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "engine record directory");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n[rules.resources]\ngroups = { disk = 1 }\n", "undeclared resource group");
    try expectInvalid(head ++ "[resource_groups.disk]\nmax = 1\nwait = \"skip\"\n[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "must be \"queue\"");
    try expectInvalid(head ++ "[shared.ref]\npath = \"r\"\n[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n[rules.resources]\nshared = [\"rfe\"]\n", "did you mean 'ref'?");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n[[rules]]\nname = \"x\"\noutput = [\"y\"]\nshell = \"true\"\nmemory = \"1M\"\n", "duplicate rule name");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\ninput = [\"x\"]\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "cannot overwrite its own input");
    try expectInvalid(head ++ "[[rules]]\nname = \"x\"\noutput = [\"x\"]\nlog = \"x\"\nshell = \"true\"\nmemory = \"1M\"\n", "overlaps a declared output");
    try expectInvalid("[workflow]\nname = \"t\"\nformat_version = 7\n[[rules]]\nname = \"x\"\noutput = [\"x\"]\nshell = \"true\"\nmemory = \"1M\"\n", "format_version 7 is not supported");
    try expectInvalid("[workflow\nname = 1\n", "line 1");
}

test "the rule key changes with each of its parts" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("in.txt", "data");
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ "[[rules]]\nname = \"x\"\ninput = [\"in.txt\"]\noutput = [\"x\"]\nshell = \"cat in.txt > x\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    var missing: ?[]const u8 = null;
    const base = (try state.computeKey(a, &ids, &wf.rules[0], "/bin", &.{}, &.{}, "engine 1", &missing)).?;
    const same = (try state.computeKey(a, &ids, &wf.rules[0], "/bin", &.{}, &.{}, "engine 1", &missing)).?;
    try testing.expectEqualStrings(base.key, same.key);
    const other_path = (try state.computeKey(a, &ids, &wf.rules[0], "/usr/bin", &.{}, &.{}, "engine 1", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, other_path.key));
    const other_engine = (try state.computeKey(a, &ids, &wf.rules[0], "/bin", &.{}, &.{}, "engine 2", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, other_engine.key));
    const with_parent = (try state.computeKey(a, &ids, &wf.rules[0], "/bin", &.{"p"}, &.{"k"}, "engine 1", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, with_parent.key));
    var changed = wf.rules[0];
    changed.threads = 2;
    const more_threads = (try state.computeKey(a, &ids, &changed, "/bin", &.{}, &.{}, "engine 1", &missing)).?;
    try testing.expectEqualStrings("threads=2 memory=1M", more_threads.request);
    try testing.expect(!std.mem.eql(u8, base.key, more_threads.key));
    changed = wf.rules[0];
    changed.shell = "cat in.txt in.txt > x";
    const other_cmd = (try state.computeKey(a, &ids, &changed, "/bin", &.{}, &.{}, "engine 1", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, other_cmd.key));

    // Rewriting the input changes its identity even with the same size.
    _ = try s.file("in.txt", "DATA");
    var fresh = state.Identities.init(testing.allocator);
    defer fresh.deinit();
    const rewritten = (try state.computeKey(a, &fresh, &wf.rules[0], "/bin", &.{}, &.{}, "engine 1", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.inputs, rewritten.inputs));
    try testing.expectEqualStrings(base.command, rewritten.command);
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

test "state round-trips through its file and refuses other versions" {
    var s = try Scratch.init();
    defer s.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    const a = st.allocator();
    try st.data.rules.map.put(a, "x", .{
        .key = "k",
        .command = "c",
        .env = "e",
        .request = "threads=1 memory=1M",
        .writes = "w",
        .inputs = "i",
        .parents = "p",
        .engine = "workz",
        .outputs = &.{.{ .path = "/w/x", .id = "1:2:3:4:5" }},
        .attempt = "dir",
        .finished = "now",
    });
    try st.save(testing.allocator);
    try s.files.append(testing.allocator, try std.fs.path.join(testing.allocator, &.{ s.path, "state.json" }));
    var again = try state.load(testing.allocator, s.path);
    defer again.deinit();
    const e = again.data.rules.map.get("x").?;
    try testing.expectEqualStrings("k", e.key);
    try testing.expectEqualStrings("1:2:3:4:5", e.outputs[0].id);

    _ = try s.file("state.json", "{\"format_version\": 9}");
    try testing.expectError(error.UnsupportedState, state.load(testing.allocator, s.path));
    _ = try s.file("state.json", "not json");
    try testing.expectError(error.CorruptState, state.load(testing.allocator, s.path));
}
