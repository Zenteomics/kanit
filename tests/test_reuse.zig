//! Unit tests of reuse: rule keys, the keyed environment, file identities
//! and the state file.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const workflow = workz.workflow;
const state = workz.state;
const sys = workz.sys;
const plan = workz.plan;
const graph = workz.graph;
const container = workz.container;
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const Scratch = helpers.Scratch;
const loadText = helpers.loadText;
const head = helpers.head;

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
    const base = (try state.computeKey(a, &ids, &wf.rules[0], wf.root, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    const same = (try state.computeKey(a, &ids, &wf.rules[0], wf.root, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expectEqualStrings(base.key, same.key);
    const other_path = (try state.computeKey(a, &ids, &wf.rules[0], wf.root, "/usr/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, other_path.key));
    const other_engine = (try state.computeKey(a, &ids, &wf.rules[0], wf.root, "/bin", &.{}, &.{}, "engine 2", null, "", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, other_engine.key));
    const with_parent = (try state.computeKey(a, &ids, &wf.rules[0], wf.root, "/bin", &.{"p"}, &.{"k"}, "engine 1", null, "", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, with_parent.key));
    var changed = wf.rules[0];
    changed.threads = 2;
    const more_threads = (try state.computeKey(a, &ids, &changed, wf.root, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expectEqualStrings("threads=2 memory=1M", more_threads.request);
    try testing.expect(!std.mem.eql(u8, base.key, more_threads.key));
    changed = wf.rules[0];
    changed.shell = "cat in.txt in.txt > x";
    const other_cmd = (try state.computeKey(a, &ids, &changed, wf.root, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.key, other_cmd.key));

    _ = try s.file("in.txt", "DATA");
    var fresh = state.Identities.init(testing.allocator);
    defer fresh.deinit();
    const rewritten = (try state.computeKey(a, &fresh, &wf.rules[0], wf.root, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expect(!std.mem.eql(u8, base.inputs, rewritten.inputs));
    try testing.expectEqualStrings(base.command, rewritten.command);
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

    try again.data.envs.map.put(again.allocator(), "e", "PATH=/bin\n");
    try again.data.envs.map.put(again.allocator(), "unused", "PATH=/x\n");
    try again.save(testing.allocator);
    var third = try state.load(testing.allocator, s.path);
    defer third.deinit();
    try testing.expectEqual(@as(usize, 1), third.data.envs.map.count());
    try testing.expectEqualStrings("PATH=/bin\n", third.data.envs.map.get("e").?);

    _ = try s.file("state.json", "{\"format_version\": 1, \"rules\": {}, \"files\": {}, \"manifest\": {}}");
    var old = try state.load(testing.allocator, s.path);
    defer old.deinit();
    try testing.expectEqual(@as(usize, 0), old.data.envs.map.count());

    _ = try s.file("state.json", "{\"format_version\": 9}");
    try testing.expectError(error.UnsupportedState, state.load(testing.allocator, s.path));
    _ = try s.file("state.json", "not json");
    try testing.expectError(error.CorruptState, state.load(testing.allocator, s.path));
}

test "[regression] - [state]: a format 1 file is saved as the current format" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("state.json", "{\"format_version\": 1, \"rules\": {}, \"files\": {}, \"manifest\": {}}");
    var old = try state.load(testing.allocator, s.path);
    defer old.deinit();
    try old.save(testing.allocator);
    const text = try sys.readFile(testing.allocator, try std.fs.path.join(old.allocator(), &.{ s.path, "state.json" }), 1 << 20);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "{\"format_version\":4,"));
}

test "[regression] - [state]: identities recorded with the device number match without it" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("state.json",
        \\{"format_version": 2, "files": {"/w/x": "52:7:3:100:200"},
        \\"manifest": {"/in/a.fq": {"id": "52:9:5:300:400", "sha256": "ab"}},
        \\"rules": {
        \\"x": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "g",
        \\  "outputs": [{"path": "/w/x", "id": "52:7:3:100:200"}], "attempt": "a", "finished": "f"},
        \\"index": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "g",
        \\  "outputs": [{"path": "/w/idx", "id": "dir:00"}], "attempt": "a", "finished": "f"}}}
    );
    var old = try state.load(testing.allocator, s.path);
    defer old.deinit();
    try testing.expectEqualStrings("7:3:100:200", old.data.rules.map.get("x").?.outputs[0].id);
    try testing.expectEqualStrings("9:5:300:400", old.data.manifest.map.get("/in/a.fq").?.id);
    try testing.expect(old.data.rules.map.get("index") == null);
    try testing.expectEqualStrings("52:7:3:100:200", old.data.files.map.get("/w/x").?);
}

test "the key of a fixed rule matches its pinned value" {
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
    const k = (try state.computeKey(arena.allocator(), &ids, &wf.rules[0], wf.root, "PATH=/usr/bin\n", &.{"producer"}, &.{"abc"}, state.engine_key_text, null, "", &missing)).?;
    try testing.expectEqualStrings("workz-key 4", k.engine);
    try testing.expectEqualStrings("6afec408f376515d3223d573bc55b4311397cd1c83257333f8e1a512b007af46", k.key);
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

test "environment changes name each variable and describe list entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changes = try state.envChanges(a, "PATH=/a:/b:/c\nLANG=C\nTZ unset\n", "PATH=/z:/a:/c\nLANG=C\nTZ=UTC\n");
    try testing.expectEqual(@as(usize, 2), changes.len);
    var w: std.Io.Writer.Allocating = .init(a);
    try state.describeEnvChange(&w.writer, changes[0]);
    try testing.expectEqualStrings("added /z, removed /b", w.written());
    w.clearRetainingCapacity();
    try state.describeEnvChange(&w.writer, changes[1]);
    try testing.expectEqualStrings("TZ", changes[1].name);
    try testing.expectEqualStrings("was unset, now 'UTC'", w.written());
    const reordered = try state.envChanges(a, "PATH=/a:/b\n", "PATH=/b:/a\n");
    w.clearRetainingCapacity();
    try state.describeEnvChange(&w.writer, reordered[0]);
    try testing.expectEqualStrings("same entries in another order", w.written());
    const passed = try state.envChanges(a, "PATH=/a\n", "PATH=/a\nNEWVAR unset\n");
    w.clearRetainingCapacity();
    try state.describeEnvChange(&w.writer, passed[0]);
    try testing.expectEqualStrings("now passed, unset", w.written());
}

test "[regression] - [sys]: a recorded file identity does not change when only the device number does" {
    const a: sys.Identity = .{ .dev = 52, .ino = 148455540, .size = 21511621, .mtime_ns = 1793000094563445142, .ctime_ns = 1793000094576445205, .mode = 0o100644 };
    var b = a;
    b.dev = 49;
    var x: [96]u8 = undefined;
    var y: [96]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&x, "{f}", .{a}), try std.fmt.bufPrint(&y, "{f}", .{b}));
    try testing.expectEqualStrings("148455540:21511621:1793000094563445142:1793000094576445205", try std.fmt.bufPrint(&x, "{f}", .{a}));
}

test "[unit] - [state]: a rule keeps its key when its project directory moves" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.dir("p1");
    _ = try s.file("p1/in.txt", "data");
    const text = head ++ "[[rules]]\nname = \"x\"\ninput = [\"in.txt\"]\noutput = [\"x\"]\nshell = \"cat in.txt > x\"\nmemory = \"1M\"\n";
    const wf_path = try s.file("p1/wf.toml", text);
    const p1 = try std.fs.path.join(testing.allocator, &.{ s.path, "p1" });
    defer testing.allocator.free(p1);
    const p2 = try std.fs.path.join(testing.allocator, &.{ s.path, "p2" });
    defer testing.allocator.free(p2);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var missing: ?[]const u8 = null;
    var problem: workflow.Problem = .{};

    var ids1 = state.Identities.init(testing.allocator);
    defer ids1.deinit();
    var wf1 = try workflow.load(testing.allocator, wf_path, p1, &problem);
    defer wf1.deinit();
    const before = (try state.computeKey(a, &ids1, &wf1.rules[0], wf1.root, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;

    try sys.rename(testing.allocator, p1, p2);
    defer sys.rename(testing.allocator, p2, p1) catch {};
    var ids2 = state.Identities.init(testing.allocator);
    defer ids2.deinit();
    var wf2 = try workflow.load(testing.allocator, try std.fs.path.join(a, &.{ p2, "wf.toml" }), p2, &problem);
    defer wf2.deinit();
    const after = (try state.computeKey(a, &ids2, &wf2.rules[0], wf2.root, "/bin", &.{}, &.{}, "engine 1", null, "", &missing)).?;
    try testing.expectEqualStrings(before.key, after.key);
}

test "[unit] - [state]: paths inside the working directory are saved relative to it" {
    var s = try Scratch.init();
    defer s.deinit();
    const rec = try s.dir(".workz");
    _ = try s.file(".workz/state.json",
        \\{"format_version": 4, "files": {"out.txt": "7:3:100:200", "/data/ref.fa": "9:5:300:400"},
        \\"manifest": {}, "envs": {},
        \\"rules": {"x": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "g",
        \\  "outputs": [{"path": "out.txt", "id": "7:3:100:200"}], "attempt": ".workz/launches/L/attempts/x/001", "finished": "f",
        \\  "input_ids": [{"path": "/data/ref.fa", "id": "9:5:300:400"}]}}}
    );
    var st = try state.load(testing.allocator, rec);
    defer st.deinit();
    const e = st.data.rules.map.get("x").?;
    const out = try std.fs.path.join(st.allocator(), &.{ s.path, "out.txt" });
    try testing.expectEqualStrings(out, e.outputs[0].path);
    try testing.expectEqualStrings(try std.fs.path.join(st.allocator(), &.{ s.path, ".workz/launches/L/attempts/x/001" }), e.attempt);
    try testing.expectEqualStrings("/data/ref.fa", e.input_ids[0].path);
    try testing.expect(st.data.files.map.get(out) != null);
    try st.save(testing.allocator);
    const saved = try sys.readFile(testing.allocator, try std.fs.path.join(st.allocator(), &.{ rec, "state.json" }), 1 << 20);
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"path\":\"out.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"attempt\":\".workz/launches/L/attempts/x/001\"") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"/data/ref.fa\"") != null);
}

test "[unit] - [state]: key paths are relative only inside the working directory" {
    try testing.expectEqualStrings("a/b.txt", workflow.keyPath("/w", "/w/a/b.txt"));
    try testing.expectEqualStrings(".", workflow.keyPath("/w", "/w"));
    try testing.expectEqualStrings("/work/a", workflow.keyPath("/w", "/work/a"));
    try testing.expectEqualStrings("/data/ref.fa", workflow.keyPath("/w", "/data/ref.fa"));
    try testing.expectEqualStrings("/w/x", workflow.keyPath("/", "/w/x"));
}

test "[unit] - [state]: manifest entries round-trip relative to the working directory" {
    var s = try Scratch.init();
    defer s.deinit();
    const rec = try s.dir(".workz");
    _ = try s.file(".workz/state.json",
        \\{"format_version": 4, "files": {}, "envs": {}, "rules": {},
        \\"manifest": {"in/r1.fq": {"id": "9:5:300:400", "sha256": "ab"}, "/data/r2.fq": {"id": "1:2:3:4", "sha256": "cd"}}}
    );
    var st = try state.load(testing.allocator, rec);
    defer st.deinit();
    try testing.expect(st.data.manifest.map.get(try std.fs.path.join(st.allocator(), &.{ s.path, "in/r1.fq" })) != null);
    try testing.expect(st.data.manifest.map.get("/data/r2.fq") != null);
    try st.save(testing.allocator);
    const saved = try sys.readFile(testing.allocator, try std.fs.path.join(st.allocator(), &.{ rec, "state.json" }), 1 << 20);
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"in/r1.fq\"") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"/data/r2.fq\"") != null);
}

fn freshIdentity(path: []const u8) ![]u8 {
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    return testing.allocator.dupe(u8, (try ids.get(path)).?);
}

test "[regression] - [state]: a directory identity changes when an empty subdirectory is created, renamed or removed" {
    var s = try Scratch.init();
    defer s.deinit();
    const d = try s.dir("d");
    _ = try s.file("d/f", "x");
    const empty = try std.fs.path.join(testing.allocator, &.{ d, "empty" });
    defer testing.allocator.free(empty);
    const other = try std.fs.path.join(testing.allocator, &.{ d, "other" });
    defer testing.allocator.free(other);

    const before = try freshIdentity(d);
    defer testing.allocator.free(before);
    try sys.mkdir(testing.allocator, empty);
    const created = try freshIdentity(d);
    defer testing.allocator.free(created);
    try sys.rename(testing.allocator, empty, other);
    const renamed = try freshIdentity(d);
    defer testing.allocator.free(renamed);
    try sys.rmdir(testing.allocator, other);
    const removed = try freshIdentity(d);
    defer testing.allocator.free(removed);

    try testing.expect(!std.mem.eql(u8, before, created));
    try testing.expect(!std.mem.eql(u8, created, renamed));
    try testing.expectEqualStrings(before, removed);
}

test "[edge] - [state]: a dangling symlink in a directory input changes its identity when its target appears" {
    var s = try Scratch.init();
    defer s.deinit();
    const d = try s.dir("d");
    try s.link("d/link", "../target");

    const dangling = try freshIdentity(d);
    defer testing.allocator.free(dangling);
    _ = try s.file("target", "x");
    const resolved = try freshIdentity(d);
    defer testing.allocator.free(resolved);

    try testing.expect(!std.mem.eql(u8, dangling, resolved));
}

test "[unit] - [state]: a directory identity leaves out record directories" {
    var s = try Scratch.init();
    defer s.deinit();
    const d = try s.dir("d");
    _ = try s.file("d/f", "x");
    _ = try s.dir("d/.workz");

    const before = try freshIdentity(d);
    defer testing.allocator.free(before);
    _ = try s.file("d/.workz/events.jsonl", "{}\n");
    const after = try freshIdentity(d);
    defer testing.allocator.free(after);

    try testing.expectEqualStrings(before, after);
}

test "[failure] - [state]: a symlink to a directory inside a directory input is refused and named" {
    var s = try Scratch.init();
    defer s.deinit();
    const d = try s.dir("d");
    _ = try s.dir("target");
    _ = try s.file("target/input", "old");
    try s.link("d/link", "../target");
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();

    try testing.expectError(error.Unreadable, ids.get(d));
    const want = try std.fmt.allocPrint(testing.allocator, "cannot read input {s}: {s}/link is a symlink to a directory; declare the directory it names as an input of its own", .{ d, d });
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, ids.problem);
}

test "[failure] - [sys]: an exclusive write refuses a file or symlink planted at its path" {
    var s = try Scratch.init();
    defer s.deinit();
    const target = try s.file("target", "keep");
    try s.link("planted", target);
    const planted = try std.fs.path.join(testing.allocator, &.{ s.path, "planted" });
    defer testing.allocator.free(planted);

    try testing.expectError(error.PathAlreadyExists, sys.openWrite(testing.allocator, planted, .exclusive));
    try testing.expectError(error.PathAlreadyExists, sys.openWrite(testing.allocator, target, .exclusive));

    const kept = try sys.readFile(testing.allocator, target, 64);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("keep", kept);
}

test "[property] - [state]: a record is reused only with its key and every output as recorded" {
    var s = try Scratch.init();
    defer s.deinit();
    const out = try s.file("o.txt", "A");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = try freshIdentity(out);
    defer testing.allocator.free(id);
    const digest = sys.sha256Bytes("A");
    const base: state.Entry = .{ .key = "k", .command = "c", .env = "e", .request = "r", .writes = "w", .inputs = "i", .parents = "p", .engine = "g", .outputs = &.{.{ .path = out, .id = id }}, .attempt = "", .finished = "" };
    const key: state.Key = .{ .command = "c", .env = "e", .request = "r", .writes = "w", .inputs = "i", .input_ids = &.{}, .parents = "p", .engine = "g", .key = "k" };
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();

    try testing.expect(try state.reuseCheck(testing.allocator, &ids, &base, &key) == .reuse);

    const Part = struct { field: []const u8, name: []const u8 };
    inline for ([_]Part{
        .{ .field = "command", .name = "command" },
        .{ .field = "env", .name = "environment" },
        .{ .field = "request", .name = "resource request" },
        .{ .field = "writes", .name = "declared outputs, log or benchmark" },
        .{ .field = "inputs", .name = "inputs" },
        .{ .field = "parents", .name = "a producing rule" },
        .{ .field = "engine", .name = "engine key" },
    }) |part| {
        var k = key;
        @field(k, part.field) = "other";
        const r = try state.reuseCheck(testing.allocator, &ids, &base, &k);
        try testing.expectEqualStrings(part.name, r.key);
    }

    var e = base;
    e.outputs = &.{.{ .path = try std.fs.path.join(a, &.{ s.path, "gone" }), .id = id }};
    try testing.expect(try state.reuseCheck(testing.allocator, &ids, &e, &key) == .output_missing);
    e.outputs = &.{.{ .path = out, .id = "1:1:1:1" }};
    try testing.expect(try state.reuseCheck(testing.allocator, &ids, &e, &key) == .output_changed);
    e.outputs = &.{.{ .path = out, .id = "1:1:1:1", .sha256 = &digest }};
    try testing.expect(try state.reuseCheck(testing.allocator, &ids, &e, &key) == .reuse);
    try testing.expect(try state.checkOutput(testing.allocator, &ids, e.outputs[0]) == .refreshed);
    const other = sys.sha256Bytes("B");
    e.outputs = &.{.{ .path = out, .id = "1:1:1:1", .sha256 = &other }};
    try testing.expect(try state.reuseCheck(testing.allocator, &ids, &e, &key) == .output_changed);
}

test "[unit] - [records]: the journal reopens exactly the rules dispatched and not finished" {
    var s = try Scratch.init();
    defer s.deinit();
    const rec = try s.dir(".workz");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Case = struct { text: []const u8, open: []const []const u8 };
    for ([_]Case{
        .{ .text = "", .open = &.{} },
        .{ .text = "dispatch\ta\n", .open = &.{"a"} },
        .{ .text = "dispatch\ta\ndone\ta\n", .open = &.{} },
        .{ .text = "done\tb\n", .open = &.{} },
        .{ .text = "dispatch\ta\ndispatch\ta\n", .open = &.{"a"} },
        .{ .text = "dispatch\ta\ndone\ta\ndispatch\ta\n", .open = &.{"a"} },
        .{ .text = "dispatch\ta\ndispatch\tb\ndone\ta\n", .open = &.{"b"} },
        .{ .text = "dispatch\ta\ndisp", .open = &.{"a"} },
    }) |c| {
        _ = try s.file(".workz/journal", c.text);
        const open = try workz.records.Journal.unfinished(testing.allocator, arena.allocator(), rec);
        try testing.expectEqual(c.open.len, open.len);
        for (c.open, open) |want, got| try testing.expectEqualStrings(want, got);
    }

    _ = try s.file(".workz/state.json",
        \\{"format_version": 4, "files": {}, "envs": {}, "manifest": {}, "rules": {
        \\"a": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "g", "outputs": [], "attempt": "x", "finished": "f"},
        \\"b": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "g", "outputs": [], "attempt": "x", "finished": "f"}}}
    );
    _ = try s.file(".workz/journal", "dispatch\ta\n");
    var st = try state.loadRecorded(testing.allocator, arena.allocator(), rec);
    defer st.deinit();
    try testing.expect(st.data.rules.map.get("a") == null);
    try testing.expect(st.data.rules.map.get("b") != null);
}

test "[failure] - [state]: every truncation of a state file and every unknown version is refused" {
    var s = try Scratch.init();
    defer s.deinit();
    const rec = try s.dir(".workz");
    const full =
        \\{"format_version": 4, "files": {"in.txt": "1:2:3:4"}, "envs": {}, "manifest": {}, "rules": {
        \\"a": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "g", "outputs": [{"path": "o.txt", "id": "5:6:7:8"}], "attempt": "x", "finished": "f"}}}
    ;
    var n: usize = 0;
    while (n < full.len) : (n += 1) {
        _ = try s.file(".workz/state.json", full[0..n]);
        if (state.load(testing.allocator, rec)) |st| {
            var held = st;
            held.deinit();
            std.debug.print("a state cut at byte {d} was accepted\n", .{n});
            return error.TestUnexpectedResult;
        } else |err| try testing.expect(err == error.CorruptState);
    }
    _ = try s.file(".workz/state.json", full);
    var st = try state.load(testing.allocator, rec);
    st.deinit();
    for ([_][]const u8{ "0", "5", "-1" }) |v| {
        const text = try std.fmt.allocPrint(testing.allocator, "{{\"format_version\": {s}, \"files\": {{}}, \"envs\": {{}}, \"manifest\": {{}}, \"rules\": {{}}}}", .{v});
        defer testing.allocator.free(text);
        _ = try s.file(".workz/state.json", text);
        try testing.expectError(error.UnsupportedState, state.load(testing.allocator, rec));
    }
}

fn loadWorkflowOnce(gpa: std.mem.Allocator, path: []const u8, root: []const u8) !void {
    var problem: workflow.Problem = .{};
    defer gpa.free(problem.message);
    var wf = workflow.load(gpa, path, root, &problem) catch |err| switch (err) {
        error.Invalid => return,
        else => return err,
    };
    wf.deinit();
}

fn loadStateOnce(gpa: std.mem.Allocator, rec: []const u8) !void {
    var st = state.load(gpa, rec) catch |err| switch (err) {
        error.CorruptState, error.UnsupportedState => return,
        else => return err,
    };
    st.deinit();
}

test "[failure] - [workflow]: loading a workflow or a state frees everything when an allocation fails" {
    var s = try Scratch.init();
    defer s.deinit();
    const good = try s.file("good.toml", head ++ "[shared.ref]\npath = \"ref\"\n\n[[rules]]\nname = \"a\"\ninput = [\"in.txt\"]\noutput = [\"a.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n[rules.resources]\nshared = [\"ref\"]\n");
    const bad = try s.file("bad.toml", head ++ "[[rules]]\nname = \"a\"\noutput = [\"a\", \"a/b\"]\nshell = \"\"\nmemory = \"lots\"\n");
    try testing.checkAllAllocationFailures(testing.allocator, loadWorkflowOnce, .{ good, s.path });
    try testing.checkAllAllocationFailures(testing.allocator, loadWorkflowOnce, .{ bad, s.path });
    const rec = try s.dir(".workz");
    _ = try s.file(".workz/state.json",
        \\{"format_version": 4, "files": {"in.txt": "1:2:3:4"}, "envs": {"e": "PATH=/bin\n"}, "manifest": {}, "rules": {
        \\"a": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "g", "outputs": [{"path": "o.txt", "id": "5:6:7:8"}], "attempt": "x", "finished": "f"}}}
    );
    try testing.checkAllAllocationFailures(testing.allocator, loadStateOnce, .{rec});
}

test "[unit] - [state]: the state file keeps its bytes for a fixed record" {
    var s = try Scratch.init();
    defer s.deinit();
    const rec = try s.dir(".workz");
    _ = try s.file(".workz/state.json",
        \\{"format_version": 4, "files": {"in.txt": "1:2:3:4"}, "envs": {"e": "PATH=/bin\n"}, "manifest": {}, "rules": {
        \\"a": {"key": "k", "command": "c", "env": "e", "request": "threads=1 memory=1M", "writes": "w", "inputs": "i", "parents": "p", "engine": "workz-key 4", "outputs": [{"path": "o.txt", "id": "5:6:7:8", "sha256": null}], "attempt": ".workz/launches/L/attempts/a/001", "finished": "2026-01-01T00:00:00.000Z", "wall_s": 1.5, "input_ids": [{"path": "in.txt", "id": "1:2:3:4"}]}}}
    );
    var st = try state.load(testing.allocator, rec);
    defer st.deinit();

    try st.save(testing.allocator);

    const saved = try sys.readFile(testing.allocator, try std.fs.path.join(st.allocator(), &.{ rec, "state.json" }), 1 << 20);
    defer testing.allocator.free(saved);
    const golden =
        \\{"format_version":4,"rules":{"a":{"key":"k","command":"c","env":"e","request":"threads=1 memory=1M","writes":"w","inputs":"i","parents":"p","engine":"workz-key 4","outputs":[{"path":"o.txt","id":"5:6:7:8","sha256":null}],"attempt":".workz/launches/L/attempts/a/001","finished":"2026-01-01T00:00:00.000Z","wall_s":1.5,"input_ids":[{"path":"in.txt","id":"1:2:3:4"}]}},"files":{"in.txt":"1:2:3:4"},"manifest":{},"envs":{"e":"PATH=/bin\n"}}
        \\
    ;
    if (!std.mem.eql(u8, golden, saved)) {
        std.debug.print("saved:\n{s}\n", .{saved});
        return error.TestUnexpectedResult;
    }
}

test "[unit] - [records]: a killed launch's unfinished attempt is the newest one, numbered past 999" {
    var s = try Scratch.init();
    defer s.deinit();
    const rec = try s.dir(".workz");
    for ([_][]const u8{ ".workz/launches", ".workz/launches/A", ".workz/launches/A/attempts", ".workz/launches/A/attempts/r", ".workz/launches/A/attempts/r/999", ".workz/launches/A/attempts/r/1000", ".workz/launches/B" }) |d| _ = try s.dir(d);
    _ = try s.file(".workz/journal", "dispatch\tr\ndispatch\tq\ndone\tq\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pending = try workz.records.pendingAttempts(testing.allocator, a, rec, "B");

    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings("r", pending[0].rule);
    try testing.expectEqualStrings("A", pending[0].launch);
    try testing.expect(std.mem.endsWith(u8, pending[0].dir, "/attempts/r/1000"));
}

test "[unit] - [records]: logs and reports take attempt 1000 as the one after 999" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ ".workz", ".workz/launches", ".workz/launches/A", ".workz/launches/A/attempts", ".workz/launches/A/attempts/r", ".workz/launches/A/attempts/r/999", ".workz/launches/A/attempts/r/1000" }) |d| _ = try s.dir(d);
    const tail = ",\"status\":\"failed\",\"started\":\"2026-01-01T00:00:00.000Z\",\"request\":{\"threads\":1,\"memory_mib\":64}}";
    _ = try s.file(".workz/launches/A/attempts/r/999/record.json", "{\"rule\":\"r\",\"attempt\":999" ++ tail);
    _ = try s.file(".workz/launches/A/attempts/r/1000/record.json", "{\"rule\":\"r\",\"attempt\":1000" ++ tail);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir = (try workz.logs.find(testing.allocator, a, s.path, "r", .{})).?;
    try testing.expect(std.mem.endsWith(u8, dir, "/attempts/r/1000"));

    const list = try workz.model.attempts(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, ".workz/launches/A" }), null);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(i64, 1000), list[1].attempt);
}

const Keys = struct {
    keys: []const ?state.Key,

    pub fn get(self: Keys, p: usize) ?[]const u8 {
        return if (self.keys[p]) |k| k.key else null;
    }
};

const no_images: std.StringHashMapUnmanaged([]const u8) = .empty;
const env_plain = "PATH=/bin\nLANG unset\n";
const env_locale = "PATH=/bin\nLANG=C\n";

const chain = "[[rules]]\nname = \"a\"\ninput = [\"in.txt\"]\noutput = [\"a.txt\"]\nshell = \"cat in.txt > a.txt\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"b\"\ninput = [\"a.txt\"]\noutput = [\"b.txt\"]\nshell = \"cat a.txt > b.txt\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"c\"\ninput = [\"b.txt\"]\noutput = [\"c.txt\"]\nshell = \"cat b.txt > c.txt\"\nmemory = \"1M\"\n";

const chain_b_changed = "[[rules]]\nname = \"a\"\ninput = [\"in.txt\"]\noutput = [\"a.txt\"]\nshell = \"cat in.txt > a.txt\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"b\"\ninput = [\"a.txt\"]\noutput = [\"b.txt\"]\nshell = \"cat a.txt a.txt > b.txt\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"c\"\ninput = [\"b.txt\"]\noutput = [\"c.txt\"]\nshell = \"cat b.txt > c.txt\"\nmemory = \"1M\"\n";

const apart = "[[rules]]\nname = \"a\"\ninput = [\"in.txt\"]\noutput = [\"a.txt\"]\nshell = \"cat in.txt > a.txt\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"b\"\ninput = [\"a.txt\"]\noutput = [\"b.txt\"]\nshell = \"cat a.txt > b.txt\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"c\"\ninput = [\"other.txt\"]\noutput = [\"c.txt\"]\nshell = \"cat other.txt > c.txt\"\nmemory = \"1M\"\n";

fn writeFiles(s: *Scratch, names: []const []const u8) !void {
    for (names) |n| _ = try s.file(n, "data");
}

fn cutFlow(a: Allocator, shell: []const u8, up_flag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, head ++ "[[rules]]\nname = \"up\"\ninput = [\"in.txt\"]\noutput = [\"up.txt\"]\nshell = \"{s}\"\nmemory = \"1M\"\n{s}" ++
        "[[rules]]\nname = \"down\"\ninput = [\"up.txt\"]\noutput = [\"down.txt\"]\nshell = \"cat up.txt up.txt > down.txt\"\nmemory = \"1M\"\n", .{ shell, up_flag });
}

fn record(a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, st: *state.State, env_text: []const u8) ![]const ?state.Key {
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    var cut = try state.Cutoff.init(a, testing.allocator, wf, st, &ids, false);
    const extras = try container.ruleExtras(a, wf, &no_images);
    const keys = try a.alloc(?state.Key, wf.rules.len);
    @memset(keys, null);
    for (g.order) |i| {
        const r = &wf.rules[i];
        var missing: ?[]const u8 = null;
        const k = (try state.ruleKey(a, &ids, wf, g.parents[i], i, st, &cut, Keys{ .keys = keys }, env_text, state.engine_key_text, extras[i], &missing)) orelse return error.InputMissing;
        keys[i] = k;
        const outs = try a.alloc(state.Output, r.output_abs.len);
        for (r.output_abs, outs) |p, *o| o.* = .{
            .path = p,
            .id = (try ids.get(p)) orelse return error.OutputMissing,
            .sha256 = if (r.cutoff) try a.dupe(u8, &(try sys.sha256File(testing.allocator, p))) else null,
        };
        try st.data.rules.map.put(st.allocator(), try a.dupe(u8, r.name), .{
            .key = k.key,
            .command = k.command,
            .env = k.env,
            .request = k.request,
            .writes = k.writes,
            .inputs = k.inputs,
            .parents = k.parents,
            .engine = k.engine,
            .outputs = outs,
            .attempt = "attempts",
            .finished = "2026-01-01T00:00:00.000Z",
            .input_ids = k.input_ids,
        });
        try st.data.envs.map.put(st.allocator(), k.env, env_text);
        if (r.cutoff) try cut.record(a, i, outs);
    }
    return keys;
}

fn planText(a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, st: *state.State, env_text: []const u8, rerun: []const []const u8, summary: bool) ![]const u8 {
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var ctx = try plan.Context.init(testing.allocator, a, wf, g, st, &ids, env_text, &environ);
    ctx.rerun_rules = rerun;
    ctx.extras = try container.ruleExtras(a, wf, &no_images);
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);
    const ds = try ctx.decideAll(mask);
    var w: std.Io.Writer.Allocating = .init(a);
    if (summary) {
        try plan.printSummary(&w.writer, &ctx, ds, mask);
        return w.written();
    }
    var runs: usize = 0;
    for (g.order) |i| {
        runs += @intFromBool(ds[i].run);
        try w.writer.print("{s:<5} {s}  ({s})\n", .{ if (ds[i].run) "run" else "reuse", wf.rules[i].name, ds[i].reason });
    }
    try w.writer.print("{d} to run, {d} to reuse\n", .{ runs, wf.rules.len - runs });
    return w.written();
}

fn explainText(a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, st: *state.State, env_text: []const u8, name: []const u8) ![]const u8 {
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var ctx = try plan.Context.init(testing.allocator, a, wf, g, st, &ids, env_text, &environ);
    ctx.extras = try container.ruleExtras(a, wf, &no_images);
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);
    var w: std.Io.Writer.Allocating = .init(a);
    if (!try plan.explain(&w.writer, &ctx, mask, name)) return error.TestUnexpectedResult;
    return w.written();
}

test "[unit] - [plan]: a rule whose record still matches is reused" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "in.txt", "a.txt", "b.txt", "c.txt" });
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ chain, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);

    try testing.expectEqualStrings("reuse a  (unchanged)\nreuse b  (unchanged)\nreuse c  (unchanged)\n0 to run, 3 to reuse\n", try planText(a, &wf, &g, &st, env_plain, &.{}, false));
}

test "[unit] - [plan]: a changed command reruns its rule and the consumers after it" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "in.txt", "a.txt", "b.txt", "c.txt" });
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ chain, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);
    var changed = try loadText(&s, head ++ chain_b_changed, &problem);
    defer changed.deinit();
    var gc = try workz.graph.build(testing.allocator, &changed, &problem);
    defer gc.deinit();

    try testing.expectEqualStrings("reuse a  (unchanged)\nrun   b  (command changed)\nrun   c  (producer b runs)\n2 to run, 1 to reuse\n", try planText(a, &changed, &gc, &st, env_plain, &.{}, false));
}

test "[unit] - [plan]: a rerun request runs the rule and the consumers after it" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "in.txt", "a.txt", "b.txt", "c.txt" });
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ chain, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);

    try testing.expectEqualStrings("reuse a  (unchanged)\nrun   b  (rerun requested)\nrun   c  (producer b runs)\n2 to run, 1 to reuse\n", try planText(a, &wf, &g, &st, env_plain, &.{"b"}, false));
}

test "[unit] - [plan]: a changed environment variable names it, and the summary counts the reasons" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "in.txt", "other.txt", "a.txt", "b.txt", "c.txt" });
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ apart, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);

    try testing.expectEqualStrings("run   a  (environment changed: LANG)\nrun   b  (producer a runs)\nrun   c  (environment changed: LANG)\n3 to run, 0 to reuse\n", try planText(a, &wf, &g, &st, env_locale, &.{}, false));
    try testing.expectEqualStrings("     2 run   environment changed: LANG\n     1 run   a producer runs\n3 to run, 0 to reuse\n", try planText(a, &wf, &g, &st, env_locale, &.{}, true));
}

test "[unit] - [plan]: a changed input reruns its rule and the rules that follow it" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "in.txt", "a.txt", "b.txt", "c.txt" });
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ chain, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);
    _ = try s.file("in.txt", "data changed");

    try testing.expectEqualStrings("run   a  (inputs changed)\nrun   b  (producer a runs)\nrun   c  (producer b runs)\n3 to run, 0 to reuse\n", try planText(a, &wf, &g, &st, env_plain, &.{}, false));
}

test "[unit] - [plan]: a changed or missing output names the output as the reason to run" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "in.txt", "a.txt", "b.txt", "c.txt" });
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ chain, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);
    const c_path = try std.fs.path.join(a, &.{ s.path, "c.txt" });

    _ = try s.file("c.txt", "data changed");
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "reuse a  (unchanged)\nreuse b  (unchanged)\nrun   c  (output changed: {s} (run refuses without --rerun-rule or --rerun))\n1 to run, 2 to reuse\n", .{c_path}), try planText(a, &wf, &g, &st, env_plain, &.{}, false));

    try sys.unlink(testing.allocator, c_path);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "reuse a  (unchanged)\nreuse b  (unchanged)\nrun   c  (output missing: {s})\n1 to run, 2 to reuse\n", .{c_path}), try planText(a, &wf, &g, &st, env_plain, &.{}, false));
}

test "[unit] - [plan]: an input that no rule makes and no file holds is named" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ "[[rules]]\nname = \"count\"\ninput = [\"reads/s9.txt\"]\noutput = [\"c.txt\"]\nshell = \"wc -l reads/s9.txt > c.txt\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();

    try testing.expectEqualStrings("run   count  (input missing: reads/s9.txt)\n1 to run, 0 to reuse\n", try planText(a, &wf, &g, &st, env_plain, &.{}, false));
}

test "[unit] - [plan]: explain names a changed input with the identity it had and the one it has" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "in.txt", "a.txt", "b.txt", "c.txt" });
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ chain, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);
    _ = try s.file("in.txt", "data changed");
    const in_path = try std.fs.path.join(a, &.{ s.path, "in.txt" });

    const text = try explainText(a, &wf, &g, &st, env_plain, "a");

    try testing.expect(std.mem.startsWith(u8, text, "rule a: runs (inputs changed)\n  recorded: 2026-01-01T00:00:00.000Z, attempt attempts\n  command    same\n  environment same\n  request    same\n  writes     same\n  inputs     changed\n  producers  same\n  engine key same\n"));
    try testing.expect(std.mem.indexOf(u8, text, try std.fmt.allocPrint(a, "  input changed: {s}\n    was ", .{in_path})) != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    now ") != null);
}

test "[unit] - [plan]: verify matches recorded outputs and names a selected rule with no record" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "in.txt", "a.txt", "b.txt", "c.txt" });
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ chain, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    var out: std.Io.Writer.Allocating = .init(a);

    try testing.expect(try plan.verify(&out.writer, testing.allocator, &st, &ids, &wf, mask, false, false));
    try testing.expectEqualStrings("3 outputs checked: all match\n", out.written());

    _ = st.data.rules.map.swapRemove("c");
    out.clearRetainingCapacity();
    try testing.expect(!try plan.verify(&out.writer, testing.allocator, &st, &ids, &wf, mask, false, false));
    try testing.expectEqualStrings("unrecorded  c\n2 outputs checked: all match; 1 selected rule has no record to check\n", out.written());
    out.clearRetainingCapacity();
    try testing.expect(!try plan.verify(&out.writer, testing.allocator, &st, &ids, &wf, mask, false, true));
    try testing.expectEqualStrings("{\"v\":1,\"checked\":2,\"by_content\":false,\"digests_stored\":0,\"unrecorded\":1,\"ok\":false,\"findings\":[{\"rule\":\"c\",\"step\":\"c\",\"sample\":null,\"finding\":\"unrecorded\",\"path\":null}]}\n", out.written());
}

test "[unit] - [plan]: a budget names each rule that does not fit and counts them" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ "[[rules]]\nname = \"write\"\noutput = [\"w.txt\"]\nshell = \"touch w.txt\"\nmemory = \"64M\"\n" ++
        "[[rules]]\nname = \"read\"\ninput = [\"w.txt\"]\noutput = [\"r.txt\"]\nshell = \"cat w.txt > r.txt\"\nmemory = \"64M\"\n", &problem);
    defer wf.deinit();
    var out: std.Io.Writer.Allocating = .init(a);

    const refused = try plan.printBudget(testing.allocator, a, &out.writer, &wf, &.{ true, true }, 0, .{ .threads = 2, .memory_mib = 32, .defaults = false });

    try testing.expectEqual(@as(usize, 2), refused);
    try testing.expectEqualStrings("\nbudget: 2 threads, 32 MiB\ndoes not fit: write needs 1 thread and 64 MiB\ndoes not fit: read needs 1 thread and 64 MiB\nlargest: write needs 1 thread and 64 MiB with its shared inputs\n2 rules do not fit: run would refuse the launch\n", out.written());
    out.clearRetainingCapacity();
    const fits = try plan.printBudget(testing.allocator, a, &out.writer, &wf, &.{ false, false }, 1, .{ .threads = 1, .memory_mib = 100, .defaults = false });
    try testing.expectEqual(@as(usize, 0), fits);
    try testing.expectEqualStrings("\nbudget: 1 thread, 100 MiB\n1 reused rule needs no budget\nevery rule fits\n", out.written());
}

test "[failure] - [plan]: a budget names a shared input it cannot measure and refuses the launch" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ "[shared.ref]\npath = \"missing-ref\"\n\n[[rules]]\nname = \"r\"\noutput = [\"r.txt\"]\nshell = \"touch r.txt\"\nmemory = \"1M\"\n[rules.resources]\nshared = [\"ref\"]\n", &problem);
    defer wf.deinit();
    var out: std.Io.Writer.Allocating = .init(a);

    const refused = try plan.printBudget(testing.allocator, a, &out.writer, &wf, &.{true}, 0, .{ .threads = 2, .memory_mib = 100, .defaults = false });

    try testing.expectEqual(@as(usize, 1), refused);
    try testing.expectEqualStrings("\nbudget: 2 threads, 100 MiB\ncannot measure shared input ref (missing-ref): no such file or directory: run would refuse the launch\n", out.written());
}

test "[failure] - [plan]: an input directory nested past 64 levels stops planning and names the directory" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rel: []const u8 = "deep";
    _ = try s.dir(rel);
    for (0..70) |_| {
        rel = try std.fmt.allocPrint(a, "{s}/d", .{rel});
        _ = try s.dir(rel);
    }
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ "[[rules]]\nname = \"r\"\ninput = [\"deep\"]\noutput = [\"r.txt\"]\nshell = \"touch r.txt\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var ctx = try plan.Context.init(testing.allocator, a, &wf, &g, &st, &ids, env_plain, &environ);
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);

    try testing.expectError(error.Unreadable, ctx.decideAll(mask));
    const want = try std.fmt.allocPrint(a, "cannot read input {s}/deep: ", .{s.path});
    try testing.expect(std.mem.startsWith(u8, ids.problem, want));
    try testing.expect(std.mem.indexOf(u8, ids.problem, "nests directories more than 64 levels deep") != null);
}

test "[unit] - [plan]: a regenerated cutoff output with the same bytes keeps its consumer reused" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.file("in.txt", "data");
    _ = try s.file("up.txt", "DATA");
    _ = try s.file("down.txt", "DATA DATA");
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, try cutFlow(a, "tr a-z A-Z < in.txt > up.txt", "cutoff = true\n"), &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);
    var up = st.data.rules.map.get("up").?;
    const stale = try a.dupe(state.Output, up.outputs);
    stale[0].id = "0:0:0:0";
    up.outputs = stale;
    try st.data.rules.map.put(st.allocator(), "up", up);

    try testing.expectEqualStrings("reuse up  (unchanged)\nreuse down  (unchanged)\n0 to run, 2 to reuse\n", try planText(a, &wf, &g, &st, env_plain, &.{}, false));

    _ = try s.file("up.txt", "other bytes");
    const up_path = try std.fs.path.join(a, &.{ s.path, "up.txt" });
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "run   up  (output changed: {s} (run refuses without --rerun-rule or --rerun))\nrun   down  (producer up runs; reused if its outputs repeat)\n2 to run, 0 to reuse\n", .{up_path}), try planText(a, &wf, &g, &st, env_plain, &.{}, false));
}

test "[unit] - [state]: a consumer of a cutoff output keeps its key while the output's bytes repeat" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.file("in.txt", "data");
    _ = try s.file("up.txt", "DATA");
    _ = try s.file("down.txt", "DATA DATA");
    var problem: workflow.Problem = .{};
    var wf1 = try loadText(&s, try cutFlow(a, "tr a-z A-Z < in.txt > up.txt", "cutoff = true\n"), &problem);
    defer wf1.deinit();
    var g1 = try workz.graph.build(testing.allocator, &wf1, &problem);
    defer g1.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    const run1 = try record(a, &wf1, &g1, &st, env_plain);
    const down1 = st.data.rules.map.get("down").?;

    const up_path = try std.fs.path.join(a, &.{ s.path, "up.txt" });
    const old_id = (try sys.stat(testing.allocator, up_path)).?;
    _ = try s.file("up.new", "DATA");
    try sys.rename(testing.allocator, try std.fs.path.join(a, &.{ s.path, "up.new" }), up_path);
    try testing.expect((try sys.stat(testing.allocator, up_path)).?.ino != old_id.ino);

    var wf2 = try loadText(&s, try cutFlow(a, "cat in.txt | tr a-z A-Z > up.txt", "cutoff = true\n"), &problem);
    defer wf2.deinit();
    var g2 = try workz.graph.build(testing.allocator, &wf2, &problem);
    defer g2.deinit();
    const run2 = try record(a, &wf2, &g2, &st, env_plain);
    const down_key2 = run2[1].?;
    try testing.expect(!std.mem.eql(u8, run1[0].?.key, run2[0].?.key));
    try testing.expectEqualStrings(run1[1].?.key, down_key2.key);
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    try testing.expect(try state.reuseCheck(testing.allocator, &ids, &down1, &down_key2) == .reuse);

    _ = try s.file("up.txt", "changed bytes");
    const run3 = try record(a, &wf2, &g2, &st, env_plain);
    const down_key3 = run3[1].?;
    try testing.expect(!std.mem.eql(u8, down_key2.key, down_key3.key));
    try testing.expectEqualStrings("inputs", (try state.reuseCheck(testing.allocator, &ids, &down1, &down_key3)).key);
}

test "[unit] - [state]: a cutoff consumer reruns only when an output it reads changes" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "in.txt", "a.txt", "ra.txt", "rb.txt" });
    _ = try s.file("b.txt", "one\n");
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        "[[rules]]\nname = \"two\"\ninput = [\"in.txt\"]\noutput = [\"a.txt\", \"b.txt\"]\nshell = \"cp in.txt a.txt; echo one > b.txt\"\nmemory = \"1M\"\ncutoff = true\n" ++
        "[[rules]]\nname = \"ra\"\ninput = [\"a.txt\"]\noutput = [\"ra.txt\"]\nshell = \"cat a.txt > ra.txt\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"rb\"\ninput = [\"b.txt\"]\noutput = [\"rb.txt\"]\nshell = \"cat b.txt > rb.txt\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    const first = try record(a, &wf, &g, &st, env_plain);
    const ra1 = st.data.rules.map.get("ra").?;
    const rb1 = st.data.rules.map.get("rb").?;

    _ = try s.file("b.txt", "two\n");
    const second = try record(a, &wf, &g, &st, env_plain);
    const ra_key = second[1].?;
    const rb_key = second[2].?;
    try testing.expectEqualStrings(first[1].?.key, ra_key.key);
    try testing.expect(!std.mem.eql(u8, first[2].?.key, rb_key.key));
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    try testing.expect(try state.reuseCheck(testing.allocator, &ids, &ra1, &ra_key) == .reuse);
    try testing.expectEqualStrings("inputs", (try state.reuseCheck(testing.allocator, &ids, &rb1, &rb_key)).key);
}

test "[unit] - [state]: turning cutoff on changes a consumer's key once, and the key stays while the bytes repeat" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.file("in.txt", "data");
    _ = try s.file("up.txt", "DATA");
    _ = try s.file("down.txt", "DATA DATA");
    var problem: workflow.Problem = .{};
    var off = try loadText(&s, try cutFlow(a, "tr a-z A-Z < in.txt > up.txt", ""), &problem);
    defer off.deinit();
    var g_off = try workz.graph.build(testing.allocator, &off, &problem);
    defer g_off.deinit();
    var on = try loadText(&s, try cutFlow(a, "tr a-z A-Z < in.txt > up.txt", "cutoff = true\n"), &problem);
    defer on.deinit();
    var g_on = try workz.graph.build(testing.allocator, &on, &problem);
    defer g_on.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();

    const before = try record(a, &off, &g_off, &st, env_plain);
    const turned = try record(a, &on, &g_on, &st, env_plain);
    const again = try record(a, &on, &g_on, &st, env_plain);

    try testing.expect(!std.mem.eql(u8, before[1].?.key, turned[1].?.key));
    try testing.expectEqualStrings(turned[1].?.key, again[1].?.key);
}

test "[unit] - [run]: a manifest stamp that matches the file is trusted without reading it, and a stale one reads it" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try s.file("st.txt", "stamped");
    const id = (try sys.stat(testing.allocator, path)).?;
    const digest = try sys.sha256File(testing.allocator, path);
    const manifest = try std.fmt.allocPrint(a, "{{\"{s}\": {{\"sha256\": \"sha256:{s}\", \"stamp\": {{\"ino\": {d}, \"size\": {d}, \"mtime_ns\": {d}, \"ctime_ns\": {d}}}}}}}", .{ path, &digest, id.ino, id.size, id.mtime_ns, id.ctime_ns });
    const mpath = try s.file("manifest.json", manifest);
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();

    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    const trusted = try workz.run.checkManifest(testing.allocator, &st, &ids, mpath, false, &notes.writer);
    try testing.expect(trusted.ok);
    try testing.expectEqual(@as(usize, 1), trusted.files);
    try testing.expectEqual(@as(usize, 0), trusted.read);

    _ = try s.file("st.txt", "changed content");
    var st2 = try state.load(testing.allocator, s.path);
    defer st2.deinit();
    var ids2 = state.Identities.init(testing.allocator);
    defer ids2.deinit();
    const stale = try workz.run.checkManifest(testing.allocator, &st2, &ids2, mpath, false, &notes.writer);
    try testing.expect(!stale.ok);
    try testing.expectEqual(@as(usize, 1), stale.read);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "kanit: input does not match its manifest digest: {s}\n", .{path}), notes.written());
}

test "[failure] - [run]: an input whose digest differs from its manifest entry fails the manifest check" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try s.file("ext.txt", "data");
    const digest = try sys.sha256File(testing.allocator, path);
    const good = try s.file("good.json", try std.fmt.allocPrint(a, "{{\"{s}\": \"sha256:{s}\"}}", .{ path, &digest }));
    const bad = try s.file("bad.json", try std.fmt.allocPrint(a, "{{\"{s}\": \"sha256:{s}\"}}", .{ path, "0" ** 64 }));
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();

    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    const ok = try workz.run.checkManifest(testing.allocator, &st, &ids, good, false, &notes.writer);
    try testing.expect(ok.ok and ok.usable);
    try testing.expectEqual(@as(usize, 1), ok.read);

    var st2 = try state.load(testing.allocator, s.path);
    defer st2.deinit();
    var ids2 = state.Identities.init(testing.allocator);
    defer ids2.deinit();
    try testing.expectEqualStrings("", notes.written());
    const wrong = try workz.run.checkManifest(testing.allocator, &st2, &ids2, bad, false, &notes.writer);
    try testing.expect(!wrong.ok and wrong.usable);
    try testing.expectEqual(@as(usize, 1), wrong.read);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "kanit: input does not match its manifest digest: {s}\n", .{path}), notes.written());
}

test "[failure] - [run]: an input manifest entry that is a directory fails the check without reading it" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.dir("mdir");
    const dir = try std.fs.path.join(a, &.{ s.path, "mdir" });
    const mpath = try s.file("dir.json", try std.fmt.allocPrint(a, "{{\"{s}\": \"sha256:{s}\"}}", .{ dir, "0" ** 64 }));
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();

    const res = try workz.run.checkManifest(testing.allocator, &st, &ids, mpath, false, &notes.writer);

    try testing.expect(!res.ok);
    try testing.expectEqual(@as(usize, 0), res.read);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "kanit: input manifest entry is not a regular file: {s}\n", .{dir}), notes.written());
}

test "[unit] - [plan]: an input manifest is checked as a run checks it, and planning saves no digest" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ext = try s.file("ext.txt", "data");
    const digest = try sys.sha256File(testing.allocator, ext);
    const good = try s.file("good.json", try std.fmt.allocPrint(a, "{{\"{s}\": \"sha256:{s}\"}}", .{ ext, &digest }));
    var notes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer notes.deinit();
    _ = try s.file("m.txt", "data");
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ "[[rules]]\nname = \"m\"\ninput = [\"ext.txt\"]\noutput = [\"m.txt\"]\nshell = \"cat ext.txt > m.txt\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    _ = try workz.run.checkManifest(testing.allocator, &st, &ids, good, false, &notes.writer);
    _ = try record(a, &wf, &g, &st, env_plain);
    st.data.manifest.map.getPtr(ext).?.id = "0:0:0:0";

    try testing.expectEqualStrings("run   m  (inputs changed)\n1 to run, 0 to reuse\n", try planText(a, &wf, &g, &st, env_plain, &.{}, false));
    var ids2 = state.Identities.init(testing.allocator);
    defer ids2.deinit();
    const checked = try workz.run.checkManifest(testing.allocator, &st, &ids2, good, false, &notes.writer);
    try testing.expect(checked.ok);
    try testing.expectEqual(@as(usize, 1), checked.read);
    try testing.expectEqualStrings("reuse m  (unchanged)\n0 to run, 1 to reuse\n", try planText(a, &wf, &g, &st, env_plain, &.{}, false));

    const bad = try s.file("bad.json", try std.fmt.allocPrint(a, "{{\"{s}\": \"sha256:{s}\"}}", .{ ext, "0" ** 64 }));
    var ids3 = state.Identities.init(testing.allocator);
    defer ids3.deinit();
    const refused = try workz.run.checkManifest(testing.allocator, &st, &ids3, bad, false, &notes.writer);
    try testing.expect(!refused.ok and refused.usable);
    try testing.expect(!sys.exists(testing.allocator, try std.fs.path.join(a, &.{ s.path, ".workz", "state.json" })));
}

test "[unit] - [plan]: a changed mount source reruns its container rule" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.file("os-release", "workz-check release");
    _ = try s.file("m.txt", "data");
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ "[[rules]]\nname = \"m\"\noutput = [\"m.txt\"]\ncontainer = \"img\"\nshell = \"cat os-release > m.txt\"\nmemory = \"1M\"\n" ++
        "mounts = { \"os-release\" = \"/etc/os-release\" }\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);
    try testing.expectEqualStrings("reuse m  (unchanged)\n0 to run, 1 to reuse\n", try planText(a, &wf, &g, &st, env_plain, &.{}, false));

    _ = try s.file("os-release", "changed");
    try testing.expectEqualStrings("run   m  (inputs changed)\n1 to run, 0 to reuse\n", try planText(a, &wf, &g, &st, env_plain, &.{}, false));
}

test "[unit] - [plan]: a changed service command reruns the rules that join it" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeFiles(&s, &.{ "u1.txt", "u2.txt" });
    const joins = "[[rules]]\nname = \"u1\"\noutput = [\"u1.txt\"]\ncontainer = \"img\"\nshell = \"true\"\n[rules.resources]\nmemory = \"1M\"\nshared = [\"seg\"]\n" ++
        "[[rules]]\nname = \"u2\"\noutput = [\"u2.txt\"]\ncontainer = \"img\"\nshell = \"true\"\n[rules.resources]\nmemory = \"1M\"\nshared = [\"seg\"]\n";
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++ "[shared.seg]\ncontainer = \"img\"\ncommand = \"echo loaded\"\nmemory = \"1G\"\n\n" ++ joins, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    _ = try record(a, &wf, &g, &st, env_plain);
    var changed = try loadText(&s, head ++ "[shared.seg]\ncontainer = \"img\"\ncommand = \"echo loaded again\"\nmemory = \"1G\"\n\n" ++ joins, &problem);
    defer changed.deinit();
    var gc = try workz.graph.build(testing.allocator, &changed, &problem);
    defer gc.deinit();

    try testing.expectEqualStrings("run   u1  (command changed)\nrun   u2  (command changed)\n2 to run, 0 to reuse\n", try planText(a, &changed, &gc, &st, env_plain, &.{}, false));
}

test "[unit] - [records]: the records directory is made private to its owner" {
    var s = try Scratch.init();
    defer s.deinit();
    const rec = try s.dir(".workz");

    try workz.records.makeRecordsDir(testing.allocator, rec);

    const id = (try sys.stat(testing.allocator, rec)).?;
    try testing.expectEqual(@as(u32, 0o700), id.mode & 0o777);
}

fn logEntry(key: []const u8) state.Entry {
    return .{
        .key = key,
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
    };
}

test "[unit] - [state log]: a save during a launch appends the completed rules, which loading applies" {
    var s = try Scratch.init();
    defer s.deinit();
    const log = try std.fs.path.join(testing.allocator, &.{ s.path, "state.log" });
    try s.files.append(testing.allocator, log);
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    const sa = st.allocator();
    try st.data.rules.map.put(sa, "x", logEntry("k1"));
    try st.data.envs.map.put(sa, "e", "PATH=/bin\n");
    try st.data.files.map.put(sa, "/w/x", "1:2:3:4:5");
    try st.appendLog(testing.allocator, &.{"x"}, &.{"/w/x"}, &.{"e"});
    const bytes = try sys.readFile(testing.allocator, log, 1 << 20);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        \\{"v":1,"base":"none"}
        \\{"env":"e","text":"PATH=/bin\n"}
        \\{"file":"/w/x","id":"1:2:3:4:5"}
        \\{"rule":"x","entry":{"key":"k1","command":"c","env":"e","request":"threads=1 memory=1M","writes":"w","inputs":"i","parents":"p","engine":"workz","outputs":[{"path":"/w/x","id":"1:2:3:4:5"}],"attempt":"dir","finished":"now","wall_s":0,"input_ids":[]}}
        \\
    , bytes);
    var again = try state.load(testing.allocator, s.path);
    defer again.deinit();
    try testing.expectEqualStrings("k1", again.data.rules.map.get("x").?.key);
    try testing.expectEqual(@as(?[]const u8, null), again.data.rules.map.get("x").?.outputs[0].sha256);
    try testing.expectEqualStrings("PATH=/bin\n", again.data.envs.map.get("e").?);
    try testing.expectEqualStrings("1:2:3:4:5", again.data.files.map.get("/w/x").?);
    try testing.expectEqual(@as(u64, bytes.len), again.log_bytes);
}

test "[edge] - [state log]: a torn last line is ignored, and the next save writes over it" {
    var s = try Scratch.init();
    defer s.deinit();
    const log = try std.fs.path.join(testing.allocator, &.{ s.path, "state.log" });
    try s.files.append(testing.allocator, log);
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    try st.data.rules.map.put(st.allocator(), "x", logEntry("k1"));
    try st.appendLog(testing.allocator, &.{"x"}, &.{}, &.{});
    const whole = try sys.readFile(testing.allocator, log, 1 << 20);
    defer testing.allocator.free(whole);
    const fd = try sys.openWrite(testing.allocator, log, .append);
    try sys.writeAll(fd, "{\"rule\":\"y\",\"ent");
    sys.close(fd);
    var torn = try state.load(testing.allocator, s.path);
    defer torn.deinit();
    try testing.expectEqual(@as(usize, 1), torn.data.rules.map.count());
    try torn.data.rules.map.put(torn.allocator(), "z", logEntry("k2"));
    try torn.appendLog(testing.allocator, &.{"z"}, &.{}, &.{});
    const after = try sys.readFile(testing.allocator, log, 1 << 20);
    defer testing.allocator.free(after);
    try testing.expect(std.mem.startsWith(u8, after, whole));
    try testing.expect(std.mem.indexOf(u8, after, "{\"rule\":\"y\"") == null);
    var both = try state.load(testing.allocator, s.path);
    defer both.deinit();
    try testing.expectEqualStrings("k1", both.data.rules.map.get("x").?.key);
    try testing.expectEqualStrings("k2", both.data.rules.map.get("z").?.key);
    try testing.expectEqual(@as(?state.Entry, null), both.data.rules.map.get("y"));
}

test "[failure] - [state log]: a newer log version is refused and a corrupt line is a corrupt state" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("state.log", "{\"v\":2,\"base\":\"none\",\"more\":true}\n");
    try testing.expectError(error.UnsupportedState, state.load(testing.allocator, s.path));
    _ = try s.file("state.log", "{\"v\":1,\"base\":\"none\"}\nnot json\n");
    try testing.expectError(error.CorruptState, state.load(testing.allocator, s.path));
    _ = try s.file("state.log", "{\"v\":1,\"base\":\"none\"}\n{\"rule\":\"x\"}\n");
    try testing.expectError(error.CorruptState, state.load(testing.allocator, s.path));
}

test "[unit] - [state log]: a full save removes the log, and a log written for another state.json is ignored" {
    var s = try Scratch.init();
    defer s.deinit();
    const log = try std.fs.path.join(testing.allocator, &.{ s.path, "state.log" });
    try s.files.append(testing.allocator, log);
    try s.files.append(testing.allocator, try std.fs.path.join(testing.allocator, &.{ s.path, "state.json" }));
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    try st.data.rules.map.put(st.allocator(), "x", logEntry("k1"));
    try st.appendLog(testing.allocator, &.{"x"}, &.{}, &.{});
    try st.save(testing.allocator);
    try testing.expect(!sys.exists(testing.allocator, log));
    try testing.expectEqual(@as(u64, 0), st.log_bytes);
    const stale = "{\"v\":1,\"base\":\"none\"}\n{\"rule\":\"old\",\"entry\":{\"key\":\"k0\",\"command\":\"c\",\"env\":\"e\",\"request\":\"r\",\"writes\":\"w\",\"inputs\":\"i\",\"parents\":\"p\",\"engine\":\"workz\",\"outputs\":[],\"attempt\":\"dir\",\"finished\":\"now\"}}\n";
    try sys.writeFile(testing.allocator, log, stale);
    var loaded = try state.load(testing.allocator, s.path);
    defer loaded.deinit();
    try testing.expectEqualStrings("k1", loaded.data.rules.map.get("x").?.key);
    try testing.expectEqual(@as(?state.Entry, null), loaded.data.rules.map.get("old"));
    try testing.expectEqual(@as(u64, 0), loaded.log_bytes);
}

test "[unit] - [state log]: the log is compacted once it outgrows the state" {
    var s = try Scratch.init();
    defer s.deinit();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    st.log_bytes = 1 << 20;
    try testing.expect(!st.logIsLarge());
    st.log_bytes = (1 << 20) + 1;
    try testing.expect(st.logIsLarge());
    st.json_bytes = 4 << 20;
    try testing.expect(!st.logIsLarge());
    st.log_bytes = (8 << 20) + 1;
    try testing.expect(st.logIsLarge());
}

test "[unit] - [plan]: plan shows a row per step, --rules a row per rule by step and sample, and --json every decision" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    var wf = try helpers.loadText(&s, helpers.head ++
        "[[rules]]\nname = \"S1__trim\"\noutput = [\"t1\"]\nshell = \"true\"\nmemory = \"1M\"\ntool = \"fastp\"\n" ++
        "[[rules]]\nname = \"S2__trim\"\noutput = [\"t2\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"S1__align\"\ninput = [\"t1\"]\noutput = [\"a1\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"merge\"\ninput = [\"a1\", \"t2\"]\noutput = [\"m\"]\nshell = \"true\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st = try state.load(testing.allocator, s.path);
    defer st.deinit();
    var ids = state.Identities.init(testing.allocator);
    defer ids.deinit();
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var ctx = try plan.Context.init(testing.allocator, a, &wf, &g, &st, &ids, env_plain, &environ);
    ctx.extras = try container.ruleExtras(a, &wf, &no_images);
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);
    const ds = try ctx.decideAll(mask);
    var by_step: std.Io.Writer.Allocating = .init(a);
    try plan.printPlan(&by_step.writer, &ctx, ds, mask);
    try testing.expectEqualStrings(
        \\STEP   TOOL   RULES    RUN  REUSE  WHY
        \\trim   fastp      2      2      0  no completed record
        \\align             1      1      0  S1: producer trim/S1 runs
        \\merge             1      1      0  producer trim/S2 runs
        \\4 to run, 0 to reuse
        \\
    , by_step.written());
    var by_rule: std.Io.Writer.Allocating = .init(a);
    try plan.printRules(&by_rule.writer, &ctx, ds, mask);
    try testing.expectEqualStrings(
        \\STEP   SAMPLE  DECISION  WHY
        \\trim   S1      run       no completed record
        \\trim   S2      run       no completed record
        \\align  S1      run       producer trim/S1 runs
        \\merge          run       producer trim/S2 runs
        \\4 to run, 0 to reuse
        \\
    , by_rule.written());
    var json: std.Io.Writer.Allocating = .init(a);
    try plan.printJson(&json.writer, &ctx, ds, mask);
    try testing.expect(std.mem.startsWith(u8, json.written(), "{\"v\":1,\"run\":4,\"reuse\":0,\"rules\":[{\"rule\":\"S1__trim\",\"step\":\"trim\",\"sample\":\"S1\",\"run\":true,\"reason\":\"no completed record\"}"));
}
