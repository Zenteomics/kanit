//! Unit tests of the reports: the launch model, the text reports and the
//! HTML page.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const helpers = @import("helpers.zig");
const Scratch = helpers.Scratch;

test "[edge] - [report]: the median of an even count averages the middle values" {
    try testing.expectEqual(@as(f64, 0), workz.model.median(&.{}));
    try testing.expectEqual(@as(f64, 3), workz.model.median(&.{ 1, 3, 9 }));
    try testing.expectEqual(@as(f64, 2.5), workz.model.median(&.{ 1, 2, 3, 40 }));
}

test "an attempt that ran but used almost none of its requests is idle" {
    const base: workz.model.Attempt = .{ .rule = "r", .attempt = 1, .status = "completed", .reason = "", .wall_s = 30, .cpu_s = 29, .threads = 1, .request_mib = 3072, .peak_mib = 900, .rss_mib = 880, .oom_kill = 0, .limit_events = 0, .waited_s = 0, .wait_reason = "", .cpu_stall = null, .memory_stall = null, .io_stall = null, .uses_shared = false };
    try testing.expect(!base.idle());
    var client = base;
    client.cpu_s = 0.04;
    client.peak_mib = 4;
    client.rss_mib = 4;
    try testing.expect(client.idle());
    var quick = client;
    quick.wall_s = 0.3;
    try testing.expect(!quick.idle());
    var failed = client;
    failed.status = "failed";
    try testing.expect(!failed.idle());
}

test "html report text is escaped" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.escape(&out.writer, "a<b> & \"c\" 'd'");
    try testing.expectEqualStrings("a&lt;b&gt; &amp; &quot;c&quot; &#39;d&#39;", out.written());
}

test "[unit] - [report]: the html page labels every attempt, escapes its records and needs no scripts" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try s.dir("launch");
    _ = try s.dir("launch/attempts");
    const long = "align_sample_0042_lane_3_paired_end";
    _ = try s.dir("launch/attempts/" ++ long);
    _ = try s.dir("launch/attempts/" ++ long ++ "/001");
    _ = try s.dir("launch/attempts/bad");
    _ = try s.dir("launch/attempts/bad/001");
    _ = try s.file("launch/launch.json",
        \\{"workdir":"/data/rnaseq","started":"2026-01-01T00:00:00.000Z","engine":"workz 9.9.9 sha256:ab"}
    );
    _ = try s.file("launch/summary.json",
        \\{"status":"failed","elapsed_s":12.0,"selected":2,"engine":"workz 9.9.9 sha256:ab","counts":{"completed":1,"failed":1},"engine_cost":{"cpu_s":0.1,"max_rss_mib":5}}
    );
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","max_threads":4,"max_memory_mib":1024}
        \\{"time":"2026-01-01T00:00:05.000Z","event":"sample","threads_reserved":2,"cpu_cores_used":1.5,"memory_current":104857600,"memory_reserved_mib":512}
        \\{"time":"2026-01-01T00:00:10.000Z","event":"sample","threads_reserved":2,"cpu_cores_used":1.8,"memory_current":209715200,"memory_reserved_mib":512}
        \\
    );
    _ = try s.file("launch/attempts/" ++ long ++ "/001/record.json",
        \\{"rule":"align_sample_0042_lane_3_paired_end","attempt":1,"status":"completed","reason":"","wall_s":10.0,"cpu_s":17.0,
        \\"started":"2026-01-01T00:00:02.000Z","request":{"threads":2,"memory_mib":512},"cgroup":{"memory_peak":209715200},
        \\"labels":{"step":"align","category":"alignment","tool":"star","sample":"s42"},
        \\"queue":{"waited_s":1.0,"reasons":[{"reason":"threads","seconds":1.0}]}}
    );
    _ = try s.file("launch/attempts/bad/001/record.json",
        \\{"rule":"bad","attempt":1,"status":"failed","reason":"exited with status 4","wall_s":0.5,"cpu_s":0.0,
        \\"started":"2026-01-01T00:00:01.000Z","request":{"threads":1,"memory_mib":64}}
    );
    _ = try s.file("launch/attempts/bad/001/stderr.log", "<boom & stuff>\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.write(testing.allocator, arena.allocator(), &out.writer, launch);
    const page = out.written();
    const has = struct {
        fn f(text: []const u8, part: []const u8) bool {
            return std.mem.indexOf(u8, text, part) != null;
        }
    }.f;
    try testing.expect(!has(page, "<script") and !has(page, "<boom"));
    try testing.expect(has(page, "<h1>rnaseq</h1>") and has(page, "<span class=\"stamp s-fail\">failed</span>"));
    try testing.expect(has(page, "<span class=\"k\">started</span>2026-01-01 00:00:00 UTC</div>") and has(page, "<span class=\"k\">engine</span>workz 9.9.9</div>"));
    // A long rule name keeps both ends in the timeline; the table has it whole.
    try testing.expect(has(page, ">align_sample_...3_paired_end</text>"));
    try testing.expect(has(page, "<td class=\"name\"><i class=\"g1\"></i>" ++ long ++ "</td><td>align</td><td>s42</td>"));
    try testing.expect(has(page, "&lt;boom &amp; stuff&gt;"));
    try testing.expect(has(page, "Failures (1)") and has(page, "Attempts (2)"));
    // Without a workflow snapshot the steps come from the records. Colors go
    // to categories in pipeline order, and the rule without a sample gets
    // the whole-run row of the matrix.
    try testing.expect(has(page, "id=\"pipeline\"") and has(page, "class=\"st-failed\""));
    try testing.expect(has(page, "<div class=\"big\">1 &times; 2</div><div class=\"sub\">samples by steps, 2 categories</div>"));
    try testing.expect(has(page, "<li><i class=\"g1\"></i><b>alignment</b>&nbsp; 17.0 s, 100%</li>"));
    try testing.expect(has(page, "<td class=\"row\">s42</td>") and has(page, "whole run</span></td>"));
    try testing.expect(has(page, "<td class=\"name\"><i class=\"g1\"></i>align<small>alignment &middot; star &middot; 1 sample</small></td>"));
    try testing.expect(has(page, "<td class=\"n\">1.7 of 2</td>"));
    try testing.expect(has(page, ">1.0 GiB</text>") and has(page, "<td class=\"n\">512 MiB</td>"));
    try testing.expect(has(page, "<td>threads</td>") and has(page, "<span>1.0 s</span>"));
    try testing.expect(has(page, "prefers-color-scheme:dark") and has(page, "@media print"));
    // The theme switch: its buttons come before the sheet they restyle, with
    // auto picked, and its labels sit in the sheet.
    const pick = std.mem.indexOf(u8, page, "<input class=\"pick\" type=\"radio\" name=\"theme\" id=\"theme-dark\"").?;
    try testing.expect(pick < std.mem.indexOf(u8, page, "<div class=\"page\">").?);
    try testing.expect(has(page, "id=\"theme-auto\" aria-label=\"auto theme\" checked>"));
    try testing.expect(has(page, "<label for=\"theme-light\">light</label>") and has(page, "#theme-dark:checked~.page{color-scheme:dark;"));
    // A finished launch's page does not reload itself.
    try testing.expect(!has(page, "http-equiv=\"refresh\""));
    for (page) |c| try testing.expect(c < 0x80);
}

test "[regression] - [report]: a launch that reused rules shows them with the run that made their outputs" {
    var s = try Scratch.init();
    defer s.deinit();
    const first = ".workz/launches/20260101T000000.000-aaaaaaaa";
    const second = ".workz/launches/20260102T000000.000-bbbbbbbb";
    for ([_][]const u8{ ".workz", ".workz/launches", first, first ++ "/attempts", first ++ "/attempts/s1__ALIGN", first ++ "/attempts/s1__ALIGN/001", first ++ "/attempts/s1__ALIGN/002", second, second ++ "/attempts", second ++ "/attempts/merge", second ++ "/attempts/merge/001" }) |d| _ = try s.dir(d);
    // The first launch completed the alignment on its second attempt.
    _ = try s.file(first ++ "/attempts/s1__ALIGN/001/record.json",
        \\{"rule":"s1__ALIGN","attempt":1,"status":"failed","reason":"exited with status 1","wall_s":2.0,"cpu_s":1.0,"request":{"threads":2,"memory_mib":512}}
    );
    _ = try s.file(first ++ "/attempts/s1__ALIGN/002/record.json",
        \\{"rule":"s1__ALIGN","attempt":2,"status":"completed","reason":"","wall_s":30.0,"cpu_s":50.0,"started":"2026-01-01T00:00:01.000Z","request":{"threads":2,"memory_mib":512}}
    );
    // The second launch reused it and ran only the merge.
    _ = try s.file(second ++ "/launch.json",
        \\{"workdir":"/data/rnaseq","started":"2026-01-02T00:00:00.000Z","engine":"workz 9.9.9 sha256:ab"}
    );
    _ = try s.file(second ++ "/summary.json",
        \\{"status":"completed","elapsed_s":1.5,"selected":2,"counts":{"completed":1,"reused":1}}
    );
    _ = try s.file(second ++ "/events.jsonl",
        \\{"time":"2026-01-02T00:00:00.000Z","event":"launch_started","max_threads":4,"max_memory_mib":1024}
        \\{"time":"2026-01-02T00:00:00.100Z","event":"task_reused","rule":"s1__ALIGN"}
        \\
    );
    _ = try s.file(second ++ "/attempts/merge/001/record.json",
        \\{"rule":"merge","attempt":1,"status":"completed","reason":"","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-02T00:00:00.200Z","request":{"threads":1,"memory_mib":64}}
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const launch = try std.fs.path.join(arena.allocator(), &.{ s.path, second });
    const reused = try workz.model.reusedAttempts(testing.allocator, arena.allocator(), launch, &.{"s1__ALIGN"});
    try testing.expectEqual(@as(usize, 1), reused.len);
    try testing.expectEqualStrings("s1__ALIGN", reused[0].rule);
    try testing.expectEqual(@as(i64, 2), reused[0].attempt);
    try testing.expectEqualStrings("20260101T000000.000-aaaaaaaa", reused[0].reused_from.?);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.write(testing.allocator, arena.allocator(), &out.writer, launch);
    const page = out.written();
    const has = struct {
        fn f(text: []const u8, part: []const u8) bool {
            return std.mem.indexOf(u8, text, part) != null;
        }
    }.f;
    // The pipeline sections show both rules; the attempt table only the merge.
    try testing.expect(has(page, "<td class=\"row\">s1</td><td class=\"cell solo reused\""));
    try testing.expect(has(page, ", reused from launch 20260101T000000.000-aaaaaaaa"));
    try testing.expect(has(page, "<small class=\"sub\">1 reused</small>"));
    try testing.expect(has(page, "of which this launch ran 1.0 s;"));
    try testing.expect(has(page, "Attempts (1)"));
}

test "[regression] - [report]: a reused rule's run may be a retry beyond its declared retries" {
    var s = try Scratch.init();
    defer s.deinit();
    const first = ".workz/launches/20260101T000000.000-aaaaaaaa";
    const second = ".workz/launches/20260102T000000.000-bbbbbbbb";
    for ([_][]const u8{ ".workz", ".workz/launches", first, first ++ "/attempts", first ++ "/attempts/sort", second }) |d| _ = try s.dir(d);
    // Four failed attempts, then `workz control retry` asked for a fifth.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (1..6) |n| {
        const dir = try std.fmt.allocPrint(a, first ++ "/attempts/sort/{d:0>3}", .{n});
        _ = try s.dir(dir);
        const status = if (n == 5) "completed" else "failed";
        _ = try s.file(try std.fmt.allocPrint(a, "{s}/record.json", .{dir}), try std.fmt.allocPrint(a, "{{\"rule\":\"sort\",\"attempt\":{d},\"status\":\"{s}\",\"wall_s\":1.0,\"cpu_s\":1.0,\"request\":{{\"threads\":1,\"memory_mib\":64}}}}", .{ n, status }));
    }
    const launch = try std.fs.path.join(a, &.{ s.path, second });
    const reused = try workz.model.reusedAttempts(testing.allocator, a, launch, &.{"sort"});
    try testing.expectEqual(@as(usize, 1), reused.len);
    try testing.expectEqual(@as(i64, 5), reused[0].attempt);
    // The launch that made it lists all five, in order.
    const rows = try workz.model.attempts(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, first }));
    try testing.expectEqual(@as(usize, 5), rows.len);
    for (rows, 1..) |r, n| try testing.expectEqual(@as(i64, @intCast(n)), r.attempt);
}

test "[regression] - [report]: a step killed for its memory is sized above the request it exceeded" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/index", "launch/attempts/index/001", "launch/attempts/count", "launch/attempts/count/001" }) |d| _ = try s.dir(d);
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","max_threads":4,"max_memory_mib":4096}
        \\
    );
    _ = try s.file("launch/attempts/index/001/record.json",
        \\{"rule":"index","attempt":1,"status":"failed","reason":"out of memory","wall_s":3.0,"cpu_s":2.0,"request":{"threads":1,"memory_mib":256},
        \\"rusage":{"maxrss_kib":262144},"cgroup":{"memory_peak":268435456,"oom_kill":1}}
    );
    // 100 MiB of process memory and 200 MiB of page cache in the cgroup.
    _ = try s.file("launch/attempts/count/001/record.json",
        \\{"rule":"count","attempt":1,"status":"completed","reason":"","wall_s":10.0,"cpu_s":9.0,"request":{"threads":1,"memory_mib":2048},
        \\"rusage":{"maxrss_kib":102400},"cgroup":{"memory_peak":314572800,"oom_kill":0}}
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var l = try workz.model.load(testing.allocator, arena.allocator(), try std.fs.path.join(arena.allocator(), &.{ s.path, "launch" }));
    defer l.deinit();
    try testing.expectEqual(@as(usize, 2), l.steps.len);
    for (l.steps) |st| {
        if (std.mem.eql(u8, st.name, "index")) {
            // Half again the 256 MiB it exceeded, never the memory it reached.
            try testing.expect(st.sizing.note == .out_of_memory);
            try testing.expectEqual(@as(f64, 384), st.sizing.memory_mib);
        } else {
            try testing.expect(st.sizing.note == .measured);
            try testing.expect(!st.used_is_peak);
            try testing.expectEqual(@as(f64, 100), st.used_mib);
            try testing.expectEqual(@as(f64, 300), st.peak_mib);
            try testing.expectEqual(@as(f64, 128), st.sizing.memory_mib);
        }
    }
}

/// Writes a launch of three rules into `name`: p1 and p2 make the inputs
/// of join. On `threads` threads p2 runs first, p1 waits for the thread,
/// and join follows p1, which is not on the longest chain.
fn chainLaunch(s: *Scratch, a: std.mem.Allocator, name: []const u8, threads: u32) !void {
    const sub = struct {
        fn path(al: std.mem.Allocator, dir: []const u8, rest: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ dir, rest });
        }
    }.path;
    for ([_][]const u8{ "", "/attempts", "/attempts/p1", "/attempts/p1/001", "/attempts/p2", "/attempts/p2/001", "/attempts/join", "/attempts/join/001" }) |d| _ = try s.dir(try std.fmt.allocPrint(a, "{s}{s}", .{ name, d }));
    _ = try s.file(try sub(a, name, "workflow"),
        \\[workflow]
        \\name = "t"
        \\version = "1"
        \\
        \\[[rules]]
        \\name = "p1"
        \\output = ["p1.txt"]
        \\shell = "true"
        \\[rules.resources]
        \\memory = "64M"
        \\
        \\[[rules]]
        \\name = "p2"
        \\output = ["p2.txt"]
        \\shell = "true"
        \\[rules.resources]
        \\memory = "64M"
        \\
        \\[[rules]]
        \\name = "join"
        \\input = ["p1.txt", "p2.txt"]
        \\output = ["j.txt"]
        \\shell = "true"
        \\[rules.resources]
        \\memory = "64M"
        \\
    );
    _ = try s.file(try sub(a, name, "launch.json"), try std.fmt.allocPrint(a, "{{\"workdir\":\"{s}\",\"max_threads\":{d},\"max_memory_mib\":1024}}", .{ s.path, threads }));
    _ = try s.file(try sub(a, name, "summary.json"),
        \\{"status":"completed","elapsed_s":5.0,"selected":3,"counts":{"completed":3}}
    );
    _ = try s.file(try sub(a, name, "events.jsonl"), try std.fmt.allocPrint(a, "{{\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"selected\":3,\"max_threads\":{d},\"max_memory_mib\":1024,\"jobs\":{d},\"rules\":[\"p1\",\"p2\",\"join\"]}}\n", .{ threads, threads }));
    _ = try s.file(try sub(a, name, "attempts/p2/001/record.json"),
        \\{"rule":"p2","attempt":1,"status":"completed","wall_s":3.0,"cpu_s":3.0,"started":"2026-01-01T00:00:00.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
    _ = try s.file(try sub(a, name, "attempts/p1/001/record.json"),
        \\{"rule":"p1","attempt":1,"status":"completed","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:03.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":3.0,"reasons":[{"reason":"threads","seconds":3.0}]}}
    );
    _ = try s.file(try sub(a, name, "attempts/join/001/record.json"),
        \\{"rule":"join","attempt":1,"status":"completed","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:04.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
}

test "[unit] - [report]: the critical path is the longest chain of work, and the largest bound limited the launch" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainLaunch(&s, a, "launch", 1);
    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, "launch" }));
    defer l.deinit();
    try testing.expectEqual(@as(usize, 2), l.path.len);
    try testing.expectEqualStrings("p2", l.rules[l.path[0].rule].name);
    try testing.expectEqualStrings("join", l.rules[l.path[1].rule].name);
    try testing.expectApproxEqAbs(@as(f64, 4.0), l.path_ran_s, 1e-6);
    // join became ready when p1 ended, a second after p2 did.
    try testing.expectApproxEqAbs(@as(f64, 1.0), l.path[1].held_s, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), l.path_waited_s, 1e-6);
    // Work, waits, holds, the time between attempts and after the path make
    // up the elapsed time.
    try testing.expectApproxEqAbs(l.elapsed_s, l.path_ran_s + l.path_waited_s + l.path_held_s + l.path_between_s + l.path_after_s, 1e-6);
    const b = l.bounds[l.binding.?];
    try testing.expect(b.kind == .threads);
    try testing.expectApproxEqAbs(@as(f64, 5.0), b.seconds, 1e-6);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeVerdict(&out.writer, &l);
    try testing.expectEqualStrings("the thread budget limited this launch: it took 5.0 s, 0% more than its rules' thread requests need at that limit", out.written());
}

test "[edge] - [report]: values that cannot be true read as missing, never as a crash" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/a", "launch/attempts/a/001" }) |d| _ = try s.dir(d);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A snapshot that no longer validates: the rule declares no memory.
    _ = try s.file("launch/workflow",
        \\[workflow]
        \\name = "t"
        \\version = "1"
        \\
        \\[[rules]]
        \\name = "a"
        \\output = ["a.txt"]
        \\shell = "true"
        \\
    );
    _ = try s.file("launch/launch.json", try std.fmt.allocPrint(a, "{{\"workdir\":\"{s}\",\"max_threads\":1,\"max_memory_mib\":1024}}", .{s.path}));
    _ = try s.file("launch/summary.json",
        \\{"status":"completed","elapsed_s":1e25,"selected":-1,"counts":{"completed":1}}
    );
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","selected":4294967296,"max_threads":4294967296,"max_memory_mib":1024,"jobs":-3,"rules":["a"]}
        \\{"time":"2026-01-01T00:00:00.000Z","event":"task_started","rule":"a","attempt":4294967296,"threads":4294967296,"memory_mib":64}
        \\{"time":"2026-01-01T00:00:01.000Z","event":"output_preserved","rule":"ghost","path":"g.txt"}
        \\{"time":"2026-01-01T00:00:01.000Z","event":"task_finished","rule":"a","attempt":1,"status":"completed","wall_s":1e999,"memory_peak":67108864}
        \\
    );
    _ = try s.file("launch/attempts/a/001/record.json",
        \\{"rule":"a","attempt":1e30,"status":"completed","wall_s":1e999,"cpu_s":1e300,"started":"2026-01-01T00:00:00.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
    const dir = try std.fs.path.join(a, &.{ s.path, "launch" });
    var l = try workz.model.load(testing.allocator, a, dir);
    defer l.deinit();
    // Only task events name the launch's rules.
    try testing.expectEqual(@as(usize, 1), l.rules.len);
    try testing.expect(std.mem.indexOf(u8, l.snapshot_problem.?, "memory") != null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, dir);
    try testing.expect(std.mem.indexOf(u8, out.written(), "the workflow snapshot cannot be read: line") != null);
    try workz.report.writeTsv(&out.writer, l.rows);
    try workz.report.writeSuggestions(&out.writer, &l, .tsv);
    try workz.report.writeSuggestions(&out.writer, &l, .table);
    try workz.html.write(testing.allocator, a, &out.writer, dir);
}

test "[edge] - [report]: durations and sizes print for any number" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try workz.units.duration(&w, 59.96);
    try testing.expectEqualStrings("1m 00s", w.buffered());
    w = .fixed(&buf);
    try workz.units.duration(&w, 0.042);
    try testing.expectEqualStrings("42 ms", w.buffered());
    w = .fixed(&buf);
    try workz.units.duration(&w, std.math.inf(f64));
    try testing.expectEqualStrings("-", w.buffered());
    w = .fixed(&buf);
    try workz.units.duration(&w, 1e25);
    w = .fixed(&buf);
    try workz.units.size(&w, std.math.nan(f64));
    try testing.expectEqualStrings("-", w.buffered());
}

test "[unit] - [report]: a group's run samples count once however many rules waited" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/a", "launch/attempts/a/001", "launch/attempts/b", "launch/attempts/b/001", "launch/attempts/c", "launch/attempts/c/001" }) |d| _ = try s.dir(d);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wf: std.Io.Writer.Allocating = .init(a);
    try wf.writer.writeAll("[workflow]\nname = \"t\"\nversion = \"1\"\n\n[resource_groups.disk]\nmax = 1\n\n");
    for ([_][]const u8{ "a", "b", "c" }) |r| try wf.writer.print("[[rules]]\nname = \"{s}\"\noutput = [\"{s}.txt\"]\nshell = \"true\"\n[rules.resources]\nmemory = \"64M\"\ngroups = {{ disk = 1 }}\n\n", .{ r, r });
    _ = try s.file("launch/workflow", wf.written());
    _ = try s.file("launch/launch.json", try std.fmt.allocPrint(a, "{{\"workdir\":\"{s}\",\"max_threads\":4,\"max_memory_mib\":1024}}", .{s.path}));
    _ = try s.file("launch/summary.json",
        \\{"status":"completed","elapsed_s":6.0,"selected":3,"counts":{"completed":3}}
    );
    // b and c wait for the group while a runs; three samples see one thread
    // of four reserved, so a higher max would have started them.
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","selected":3,"max_threads":4,"max_memory_mib":1024,"rules":["a","b","c"]}
        \\{"time":"2026-01-01T00:00:00.000Z","event":"task_started","rule":"a","attempt":1,"threads":1,"memory_mib":64}
        \\{"time":"2026-01-01T00:00:00.000Z","event":"task_waiting","rule":"b","reason":"group:disk"}
        \\{"time":"2026-01-01T00:00:00.000Z","event":"task_waiting","rule":"c","reason":"group:disk"}
        \\{"time":"2026-01-01T00:00:01.000Z","event":"sample","threads_reserved":1,"memory_reserved_mib":64}
        \\{"time":"2026-01-01T00:00:02.000Z","event":"sample","threads_reserved":1,"memory_reserved_mib":64}
        \\{"time":"2026-01-01T00:00:03.000Z","event":"sample","threads_reserved":1,"memory_reserved_mib":64}
        \\{"time":"2026-01-01T00:00:04.000Z","event":"task_finished","rule":"a","attempt":1,"status":"completed"}
        \\{"time":"2026-01-01T00:00:04.000Z","event":"task_started","rule":"b","attempt":1,"threads":1,"memory_mib":64}
        \\{"time":"2026-01-01T00:00:05.000Z","event":"task_finished","rule":"b","attempt":1,"status":"completed"}
        \\{"time":"2026-01-01T00:00:05.000Z","event":"task_started","rule":"c","attempt":1,"threads":1,"memory_mib":64}
        \\{"time":"2026-01-01T00:00:06.000Z","event":"task_finished","rule":"c","attempt":1,"status":"completed"}
        \\
    );
    _ = try s.file("launch/attempts/a/001/record.json",
        \\{"rule":"a","attempt":1,"status":"completed","wall_s":4.0,"cpu_s":4.0,"started":"2026-01-01T00:00:00.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
    _ = try s.file("launch/attempts/b/001/record.json",
        \\{"rule":"b","attempt":1,"status":"completed","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:04.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":4.0,"reasons":[{"reason":"group:disk","seconds":4.0}]}}
    );
    _ = try s.file("launch/attempts/c/001/record.json",
        \\{"rule":"c","attempt":1,"status":"completed","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:05.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":5.0,"reasons":[{"reason":"group:disk","seconds":5.0}]}}
    );
    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, "launch" }));
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.groups.len);
    try testing.expectEqual(@as(usize, 3), l.groups[0].samples);
    try testing.expectApproxEqAbs(@as(f64, 1.0), l.groups[0].fit.?, 1e-9);
}

test "[unit] - [report]: a long name keeps its start and end, cut between characters" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("align_sam...ule_name", workz.units.middle(&buf, "align_sample_with_a_long_rule_name", 20));
    try testing.expectEqualStrings("short", workz.units.middle(&buf, "short", 20));
    // "é" is two bytes: no cut falls inside it.
    const cut = workz.units.middle(&buf, "ééééééééééééé", 9);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expect(cut.len <= 9);
}

test "[unit] - [report]: the attempt table, its JSON and the suggestions keep their fields" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainLaunch(&s, a, "launch", 1);
    const dir = try std.fs.path.join(a, &.{ s.path, "launch" });
    const rows = try workz.model.attempts(testing.allocator, a, dir);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeTsv(&out.writer, rows);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "rule\tattempt\tstatus\twall_s\tcpu_s\tcpu_efficiency\t"));
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        // A missing number reads NA, never an empty field.
        try testing.expect(std.mem.indexOf(u8, line, "\t\t") == null);
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(std.mem.indexOf(u8, out.written(), "p2\t1\tcompleted\t3.000\t3.000\t1.0000\t1\t64\tNA\t") != null);

    out.clearRetainingCapacity();
    try workz.report.writeJson(a, &out.writer, rows);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
    try testing.expectEqual(@as(usize, 3), v.array.items.len);
    // Rows come in rule order.
    try testing.expectEqualStrings("join", v.array.items[0].object.get("rule").?.string);

    var l = try workz.model.load(testing.allocator, a, dir);
    defer l.deinit();
    out.clearRetainingCapacity();
    try workz.report.writeSuggestions(&out.writer, &l, .tsv);
    try testing.expect(std.mem.startsWith(u8, out.written(), "step\truns\tthreads\tthreads_used\tsuggest_threads\tmemory_mib\tused_mib\tused_basis\tpeak_mib\tsuggest_mib\tnote\tat_thread_limit\n"));
}

test "[unit] - [report]: the bottleneck report leads with its verdict, and a comparison names both budgets" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainLaunch(&s, a, "one", 1);
    try chainLaunch(&s, a, "two", 2);
    const one = try std.fs.path.join(a, &.{ s.path, "one" });
    const two = try std.fs.path.join(a, &.{ s.path, "two" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, one);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    _ = lines.next();
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "the thread budget limited this launch: it took 5.0 s"));
    for ([_][]const u8{ "\nwhat limited the launch", "\ncritical path", "\nwaiting for resources", "\nsteps" }) |section|
        try testing.expect(std.mem.indexOf(u8, out.written(), section) != null);

    out.clearRetainingCapacity();
    try workz.report.writeCompare(testing.allocator, a, &out.writer, one, two);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\nbudget   1 threads, 1.0 GiB, 1 jobs against 2 threads, 1.0 GiB, 2 jobs\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "note: the budgets differ") != null);
}

test "[edge] - [report]: record fields that do not fit their type read as missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"big\":300,\"neg\":-1,\"huge\":1e999,\"ok\":2.5,\"text\":\"x\"}", .{});
    try testing.expectEqual(@as(?u8, null), workz.fields.whole(u8, v, "big"));
    try testing.expectEqual(@as(?u32, 300), workz.fields.whole(u32, v, "big"));
    try testing.expectEqual(@as(?i64, null), workz.fields.int(v, "neg"));
    try testing.expectEqual(@as(?f64, null), workz.fields.float(v, "huge"));
    try testing.expectEqual(@as(?f64, 2.5), workz.fields.float(v, "ok"));
    try testing.expectEqual(@as(?f64, null), workz.fields.float(v, "text"));
    try testing.expectEqual(@as(?f64, null), workz.fields.float(v, "missing"));
}
