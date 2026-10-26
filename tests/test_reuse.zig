//! Unit tests of reuse: rule keys, the keyed environment, file identities
//! and the state file.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const workflow = workz.workflow;
const state = workz.state;
const sys = workz.sys;
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

    // Environments no recorded rule refers to are dropped on save.
    try again.data.envs.map.put(again.allocator(), "e", "PATH=/bin\n");
    try again.data.envs.map.put(again.allocator(), "unused", "PATH=/x\n");
    try again.save(testing.allocator);
    var third = try state.load(testing.allocator, s.path);
    defer third.deinit();
    try testing.expectEqual(@as(usize, 1), third.data.envs.map.count());
    try testing.expectEqualStrings("PATH=/bin\n", third.data.envs.map.get("e").?);

    // A format 1 file has no recorded environments and is still read.
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
    try testing.expect(std.mem.startsWith(u8, text, "{\"format_version\":3,"));
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
    // A directory's old identity cannot be compared, so its rule runs again.
    try testing.expect(old.data.rules.map.get("index") == null);
    try testing.expectEqualStrings("52:7:3:100:200", old.data.files.map.get("/w/x").?);
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
