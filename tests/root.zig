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
    testing.refAllDecls(workz.plan);
    testing.refAllDecls(workz.monitor);
    testing.refAllDecls(workz.report);
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

test "event times parse back to the epoch nanoseconds they were written from" {
    const ns: i128 = 1_792_782_446_812_000_000;
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try sys.formatTime(&w, ns);
    try testing.expectEqualStrings("2026-10-23T19:07:26.812Z", w.buffered());
    try testing.expectEqual(@as(?i128, ns), workz.monitor.parseTime(w.buffered()));
    try testing.expectEqual(@as(?i128, 0), workz.monitor.parseTime("1970-01-01T00:00:00.000Z"));
    try testing.expectEqual(@as(?i128, null), workz.monitor.parseTime("garbage"));
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

    fn dir(self: *Scratch, name: []const u8) ![]const u8 {
        const p = try std.fs.path.join(testing.allocator, &.{ self.path, name });
        try sys.mkdir(testing.allocator, p);
        try self.dirs.append(testing.allocator, p);
        return p;
    }

    /// A symlink `name` pointing at `target`.
    fn link(self: *Scratch, name: []const u8, target: []const u8) !void {
        const linux = std.os.linux;
        const p = try std.fs.path.join(testing.allocator, &.{ self.path, name });
        try self.files.append(testing.allocator, p);
        const pz = try testing.allocator.dupeZ(u8, p);
        defer testing.allocator.free(pz);
        const tz = try testing.allocator.dupeZ(u8, target);
        defer testing.allocator.free(tz);
        _ = try sys.check(linux.symlinkat(tz, linux.AT.FDCWD, pz));
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
        var i = self.dirs.items.len;
        while (i > 0) {
            i -= 1;
            sys.rmdir(testing.allocator, self.dirs.items[i]) catch {};
            testing.allocator.free(self.dirs.items[i]);
        }
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
    try testing.expectEqual(@as(u32, 2), wf.rules[1].threads);
    try testing.expectEqual(@as(u64, 1024), wf.rules[1].memory_mib);
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
    const base = (try state.computeKey(a, &ids, &wf.rules[0], "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    const same = (try state.computeKey(a, &ids, &wf.rules[0], "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expectEqualStrings(base.key, same.key);
    const other_path = (try state.computeKey(a, &ids, &wf.rules[0], "/usr/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, other_path.key));
    const other_engine = (try state.computeKey(a, &ids, &wf.rules[0], "/bin", &.{}, &.{}, "engine 2", null, "", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, other_engine.key));
    const with_parent = (try state.computeKey(a, &ids, &wf.rules[0], "/bin", &.{"p"}, &.{"k"}, "engine 1", null, "", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, with_parent.key));
    var changed = wf.rules[0];
    changed.threads = 2;
    const more_threads = (try state.computeKey(a, &ids, &changed, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expectEqualStrings("threads=2 memory=1M", more_threads.request);
    try testing.expect(!std.mem.eql(u8, base.key, more_threads.key));
    changed = wf.rules[0];
    changed.shell = "cat in.txt in.txt > x";
    const other_cmd = (try state.computeKey(a, &ids, &changed, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, other_cmd.key));

    // Rewriting the input changes its identity even with the same size.
    _ = try s.file("in.txt", "DATA");
    var fresh = state.Identities.init(testing.allocator);
    defer fresh.deinit();
    const rewritten = (try state.computeKey(a, &fresh, &wf.rules[0], "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
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

test "the key of a fixed rule matches its pinned value" {
    // A change here means the key encoding changed: raise state.engine_key.
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ "[[rules]]\nname = \"pinned\"\noutput = [\"out.txt\"]\nlog = \"l.log\"\nshell = \"echo pinned > out.txt\"\nmemory = \"1G\"\n[rules.resources]\nthreads = 2\n", &problem);
    defer wf.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    var missing: ?[]const u8 = null;
    const k = (try state.computeKey(arena.allocator(), &ids, &wf.rules[0], "PATH=/usr/bin\n", &.{"producer"}, &.{"abc"}, state.engine_key_text, null, "", &missing)).?;
    try testing.expectEqualStrings("workz-key 2", k.engine);
    try testing.expectEqualStrings("7d15b2e0e68740f40d5a9f9e3081ebc2563c64ef5783a077ec50bee62edf996e", k.key);
}

test "the keyed environment lists PATH, locale, time zone and passed names in order" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin");
    try env.put("TZ", "UTC");
    try env.put("HOME", "/home/x");
    try env.put("REF", "/data");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try state.envText(arena.allocator(), &env, &.{ "REF", "MISSING" });
    try testing.expectEqualStrings("PATH=/usr/bin\nLANG unset\nLC_ALL unset\nTZ=UTC\nMISSING unset\nREF=/data\n", text);
}

test "pressure totals are read from their some and full lines" {
    const text = "some avg10=0.00 avg60=0.10 avg300=0.00 total=1234\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=56\n";
    try testing.expectEqual(@as(?u64, 1234), workz.cgroup.pressureTotal(text, "some"));
    try testing.expectEqual(@as(?u64, 56), workz.cgroup.pressureTotal(text, "full"));
    try testing.expectEqual(@as(?u64, null), workz.cgroup.pressureTotal("garbage\n", "some"));
}

test "kinds of rules drop their sample part" {
    try testing.expectEqualStrings("STAR_ALIGN", workz.report.pattern("pool_01_baseline__STAR_ALIGN"));
    try testing.expectEqualStrings("classify", workz.report.pattern("classify_03JW"));
    try testing.expectEqualStrings("merge", workz.report.pattern("merge"));
    try testing.expectEqualStrings("_x", workz.report.pattern("_x"));
}

test "an attempt that ran but used almost none of its requests is delegated" {
    const base: workz.report.Attempt = .{ .rule = "r", .attempt = 1, .status = "completed", .reason = "", .wall_s = 30, .cpu_s = 29, .threads = 1, .request_mib = 3072, .peak_mib = 900, .rss_mib = 880, .oom_kill = 0, .limit_events = 0, .waited_s = 0, .wait_reason = "", .cpu_stall = null, .memory_stall = null, .io_stall = null, .uses_shared = false };
    try testing.expect(!base.delegated());
    var client = base;
    client.cpu_s = 0.04;
    client.peak_mib = 4;
    client.rss_mib = 4;
    try testing.expect(client.delegated());
    var quick = client;
    quick.wall_s = 0.3;
    try testing.expect(!quick.delegated());
    var failed = client;
    failed.status = "failed";
    try testing.expect(!failed.delegated());
}

test "container mounts list each directory once with the access it needs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rule: workflow.Rule = undefined;
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

const ev_start = "{\"v\":1,\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"selected\":3,\"max_threads\":8,\"max_memory_mib\":4096}\n";
const ev_rules =
    "{\"v\":1,\"time\":\"2026-01-01T00:00:01.000Z\",\"event\":\"task_started\",\"rule\":\"align_sample_with_a_long_name\",\"attempt\":1,\"directory\":\"\"}\n" ++
    "{\"v\":1,\"time\":\"2026-01-01T00:00:01.000Z\",\"event\":\"task_waiting\",\"rule\":\"merge\",\"reason\":\"memory\"}\n" ++
    "{\"v\":1,\"time\":\"2026-01-01T00:00:02.000Z\",\"event\":\"task_started\",\"rule\":\"trim\",\"attempt\":1,\"directory\":\"\"}\n" ++
    "{\"v\":1,\"time\":\"2026-01-01T00:00:04.000Z\",\"event\":\"task_finished\",\"rule\":\"trim\",\"attempt\":1,\"status\":\"failed\",\"reason\":\"exited with status 3\"}\n";

test "the watch tracker applies only complete lines and keeps reading where it stopped" {
    var s = try Scratch.init();
    defer s.deinit();
    // The last line is cut in the middle, as while the engine writes it.
    const cut = ev_rules.len - 30;
    _ = try s.file("events.jsonl", ev_start ++ ev_rules[0..cut]);
    var t = try workz.monitor.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    try testing.expect(try t.update());
    try testing.expectEqual(@as(u32, 3), t.selected);
    try testing.expectEqual(@as(usize, 3), t.rules.items.len);
    try testing.expectEqual(workz.monitor.Status.running, t.rules.items[2].status);
    try testing.expect(!try t.update());
    _ = try s.file("events.jsonl", ev_start ++ ev_rules);
    try testing.expect(try t.update());
    try testing.expectEqual(workz.monitor.Status.failed, t.rules.items[2].status);
    try testing.expectEqualStrings("exited with status 3", t.rules.items[2].reason);
    try testing.expectEqualStrings("memory", t.rules.items[1].reason);
}

test "watch keys decode from raw terminal input" {
    const tui = workz.tui;
    var used: usize = 0;
    try testing.expectEqual(tui.Key.up, tui.decode("\x1b[A", &used).?);
    try testing.expectEqual(@as(usize, 3), used);
    try testing.expectEqual(tui.Key.page_down, tui.decode("\x1b[6~j", &used).?);
    try testing.expectEqual(@as(usize, 4), used);
    try testing.expectEqual(tui.Key.end, tui.decode("\x1bOF", &used).?);
    try testing.expectEqual(tui.Key.interrupt, tui.decode("\x03", &used).?);
    try testing.expectEqual(tui.Key.escape, tui.decode("\x1b", &used).?);
    try testing.expectEqual(tui.Key{ .char = 'q' }, tui.decode("q", &used).?);
    // An unused sequence is skipped whole; an incomplete one waits.
    try testing.expectEqual(@as(?tui.Key, null), tui.decode("\x1b[1;5Pq", &used));
    try testing.expectEqual(@as(usize, 6), used);
    try testing.expectEqual(@as(?tui.Key, null), tui.decode("\x1b[1;", &used));
    try testing.expectEqual(@as(usize, 0), used);
}

test "the watch selection moves, scrolls and survives filters" {
    const tui = workz.tui;
    var ui: tui.Ui = .{};
    const rows = [_]usize{ 4, 0, 2, 7, 5 };
    ui.key(.down, &rows, 2);
    try testing.expectEqual(@as(?usize, 4), ui.selected);
    ui.key(.{ .char = 'G' }, &rows, 2);
    try testing.expectEqual(@as(?usize, 5), ui.selected);
    ui.settle(&rows, 2);
    try testing.expectEqual(@as(usize, 3), ui.top);
    ui.key(.page_up, &rows, 2);
    try testing.expectEqual(@as(?usize, 2), ui.selected);
    ui.key(.enter, &rows, 2);
    try testing.expectEqual(tui.Mode.log, ui.mode);
    ui.key(.{ .char = 'q' }, &rows, 2);
    try testing.expectEqual(tui.Mode.table, ui.mode);
    try testing.expect(!ui.quit);
    // A selected rule that left the view gives way to a visible one.
    const fewer = [_]usize{ 4, 0 };
    ui.settle(&fewer, 2);
    try testing.expect(ui.selected.? == 4 or ui.selected.? == 0);
    ui.key(.{ .char = 'q' }, &fewer, 2);
    try testing.expect(ui.quit);
}

test "a watch frame fits the terminal width and lists running rules first" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("events.jsonl", ev_start ++ ev_rules);
    var t = try workz.monitor.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    var ui: workz.tui.Ui = .{};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const now = workz.monitor.parseTime("2026-01-01T00:00:05.000Z").?;
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 40, 10, now, false);
    var lines = std.mem.splitSequence(u8, out.written(), "\r\n");
    var n: usize = 0;
    var order: [3]usize = undefined;
    var found: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        // Columns: everything outside escape sequences.
        var cols: usize = 0;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] == 0x1b) {
                i += 1;
                while (i < line.len and (line[i] < 0x40 or line[i] > 0x7e or line[i] == '[')) i += 1;
                continue;
            }
            cols += 1;
        }
        try testing.expect(cols <= 40);
        for ([_][]const u8{ "align_sample", "merge", "trim" }, 0..) |name, k| if (std.mem.indexOf(u8, line, name) != null) {
            order[found] = k;
            found += 1;
        };
    }
    try testing.expectEqual(@as(usize, 10), n);
    try testing.expectEqual(@as(usize, 3), found);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &order);

    ui.mode = .timeline;
    out.clearRetainingCapacity();
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 60, 10, now, false);
    // trim ran from 2 s to 4 s of a 5 s launch and failed.
    try testing.expect(std.mem.indexOf(u8, out.written(), "!!!!") != null);
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
    try testing.expectEqualStrings("rule b: declare the producer path instead of the symlink 'alias/x'", problem.message);
}
