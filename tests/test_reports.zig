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
        \\{"workdir":"/data/rnaseq","started":"2026-01-01T00:00:00.000Z","engine":"kanit 9.9.9 sha256:ab"}
    );
    _ = try s.file("launch/summary.json",
        \\{"status":"failed","elapsed_s":12.0,"selected":2,"engine":"kanit 9.9.9 sha256:ab","counts":{"completed":1,"failed":1},"engine_cost":{"cpu_s":0.1,"max_rss_mib":5}}
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
    try workz.html.write(testing.allocator, arena.allocator(), &out.writer, launch, null);
    const page = out.written();
    const has = struct {
        fn f(text: []const u8, part: []const u8) bool {
            return std.mem.indexOf(u8, text, part) != null;
        }
    }.f;
    try testing.expect(!has(page, "<script") and !has(page, "<boom"));
    try testing.expect(has(page, "<h1>rnaseq</h1>") and has(page, "<span class=\"stamp s-fail\">failed</span>"));
    try testing.expect(has(page, "<span class=\"k\">started</span>2026-01-01 00:00:00 UTC</div>") and has(page, "<span class=\"k\">engine</span>kanit 9.9.9</div>"));
    try testing.expect(has(page, ">align_sample_...3_paired_end</text>"));
    try testing.expect(has(page, "<td class=\"name\"><i class=\"g1\"></i>" ++ long ++ "</td><td>align</td><td>s42</td>"));
    try testing.expect(has(page, "&lt;boom &amp; stuff&gt;"));
    try testing.expect(has(page, "Failures (1)") and has(page, "Attempts (2)"));
    try testing.expect(has(page, "id=\"pipeline\"") and has(page, "class=\"st-failed\""));
    try testing.expect(has(page, "<div class=\"big\">1 &times; 2</div><div class=\"sub\">samples by steps, 2 categories</div>"));
    try testing.expect(has(page, "<li><i class=\"g1\"></i><b>alignment</b>&nbsp; 17.0 s, 100%</li>"));
    try testing.expect(has(page, "<td class=\"row\">s42</td>") and has(page, "whole run</span></td>"));
    try testing.expect(has(page, "<td class=\"name\"><i class=\"g1\"></i>align<small>alignment &middot; star &middot; 1 sample</small></td>"));
    try testing.expect(has(page, "<td class=\"n\">1.7 of 2</td>"));
    try testing.expect(has(page, ">1.0 GiB</text>") and has(page, "<td class=\"n\">512 MiB</td>"));
    try testing.expect(has(page, "<td>threads</td>") and has(page, "<span>1.0 s</span>"));
    try testing.expect(has(page, "prefers-color-scheme:dark") and has(page, "@media print"));
    const pick = std.mem.indexOf(u8, page, "<input class=\"pick\" type=\"radio\" name=\"theme\" id=\"theme-dark\"").?;
    try testing.expect(pick < std.mem.indexOf(u8, page, "<div class=\"page\">").?);
    try testing.expect(has(page, "id=\"theme-auto\" aria-label=\"auto theme\" checked>"));
    try testing.expect(has(page, "<label for=\"theme-light\">light</label>") and has(page, "#theme-dark:checked~.page{color-scheme:dark;"));
    try testing.expect(!has(page, "http-equiv=\"refresh\""));
    for (page) |c| try testing.expect(c < 0x80);

    const streamed = try s.file("report.html", "previous page");
    try workz.html.writeFile(testing.allocator, testing.allocator, streamed, launch, null);
    const saved = try workz.sys.readFile(testing.allocator, streamed, 1 << 20);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings(page, saved);
    const pending = try std.fmt.allocPrint(arena.allocator(), "{s}.tmp", .{streamed});
    try testing.expect(!workz.sys.exists(testing.allocator, pending));
    const failed_page = try s.file("failed.html", "last complete page");
    try s.link("failed.html.tmp", "/dev/full");
    try testing.expectError(error.NoSpace, workz.html.writeFile(testing.allocator, testing.allocator, failed_page, launch, null));
    const prior_page = try workz.sys.readFile(testing.allocator, failed_page, 1024);
    defer testing.allocator.free(prior_page);
    try testing.expectEqualStrings("last complete page", prior_page);
    try testing.expect(!workz.sys.exists(testing.allocator, try std.fmt.allocPrint(arena.allocator(), "{s}.tmp", .{failed_page})));

    out.clearRetainingCapacity();
    try workz.html.write(testing.allocator, testing.allocator, &out.writer, launch, null);
    var live = try workz.model.load(testing.allocator, arena.allocator(), launch);
    defer live.deinit();
    live.finished = false;
    live.status = "running";
    out.clearRetainingCapacity();
    try workz.html.writeLaunch(arena.allocator(), &out.writer, &live);
    try testing.expect(has(out.written(), "<meta http-equiv=\"refresh\" content=\"15\">"));
    try testing.expect(!has(out.written(), "@keyframes") and !has(out.written(), "animation:"));
    try testing.expect(!has(out.written(), "<script"));
    for (0..3) |_| {
        out.clearRetainingCapacity();
        try workz.html.writeLaunch(testing.allocator, &out.writer, &live);
    }
    var tiny: [64]u8 = undefined;
    var full = std.Io.Writer.fixed(&tiny);
    try testing.expectError(error.WriteFailed, workz.html.writeLaunch(testing.allocator, &full, &live));
    try testing.checkAllAllocationFailures(testing.allocator, renderOnce, .{&live});
}

fn renderOnce(a: std.mem.Allocator, l: *const workz.model.Launch) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&buffer);
    try workz.html.writeLaunch(a, &out.writer, l);
}

test "[regression] - [report]: a launch that reused rules shows them with the run that made their outputs" {
    var s = try Scratch.init();
    defer s.deinit();
    const first = ".workz/launches/20260101T000000.000-aaaaaaaa";
    const second = ".workz/launches/20260102T000000.000-bbbbbbbb";
    for ([_][]const u8{ ".workz", ".workz/launches", first, first ++ "/attempts", first ++ "/attempts/s1__ALIGN", first ++ "/attempts/s1__ALIGN/001", first ++ "/attempts/s1__ALIGN/002", second, second ++ "/attempts", second ++ "/attempts/merge", second ++ "/attempts/merge/001" }) |d| _ = try s.dir(d);
    _ = try s.file(first ++ "/attempts/s1__ALIGN/001/record.json",
        \\{"rule":"s1__ALIGN","attempt":1,"status":"failed","reason":"exited with status 1","wall_s":2.0,"cpu_s":1.0,"request":{"threads":2,"memory_mib":512}}
    );
    _ = try s.file(first ++ "/attempts/s1__ALIGN/002/record.json",
        \\{"rule":"s1__ALIGN","attempt":2,"status":"completed","reason":"","wall_s":30.0,"cpu_s":50.0,"started":"2026-01-01T00:00:01.000Z","request":{"threads":2,"memory_mib":512}}
    );
    _ = try s.file(second ++ "/launch.json",
        \\{"workdir":"/data/rnaseq","started":"2026-01-02T00:00:00.000Z","engine":"kanit 9.9.9 sha256:ab"}
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
    const reused = try workz.model.reusedAttempts(testing.allocator, arena.allocator(), launch, &.{"s1__ALIGN"}, null);
    try testing.expectEqual(@as(usize, 1), reused.len);
    try testing.expectEqualStrings("s1__ALIGN", reused[0].rule);
    try testing.expectEqual(@as(i64, 2), reused[0].attempt);
    try testing.expectEqualStrings("20260101T000000.000-aaaaaaaa", reused[0].reused_from.?);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.write(testing.allocator, arena.allocator(), &out.writer, launch, null);
    const page = out.written();
    const has = struct {
        fn f(text: []const u8, part: []const u8) bool {
            return std.mem.indexOf(u8, text, part) != null;
        }
    }.f;
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
    const reused = try workz.model.reusedAttempts(testing.allocator, a, launch, &.{"sort"}, null);
    try testing.expectEqual(@as(usize, 1), reused.len);
    try testing.expectEqual(@as(i64, 5), reused[0].attempt);
    const rows = try workz.model.attempts(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, first }), null);
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

test "[regression] - [report]: memory sizes and bounds follow what was held and reserved, and an unreadable record is counted" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/sort", "launch/attempts/sort/001", "launch/attempts/c1", "launch/attempts/c1/001", "launch/attempts/c2", "launch/attempts/c2/001", "launch/attempts/bad", "launch/attempts/bad/001" }) |d| _ = try s.dir(d);
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","max_threads":4,"max_memory_mib":96}
        \\
    );
    _ = try s.file("launch/attempts/sort/001/record.json",
        \\{"rule":"sort","attempt":1,"status":"completed","reason":"","wall_s":1.0,"cpu_s":1.0,"request":{"threads":1,"memory_mib":512},
        \\"rusage":{"maxrss_kib":65536},"cgroup":{"memory_peak":314572800,"anon_peak":268435456,"oom_kill":0}}
    );
    for ([_][]const u8{ "launch/attempts/c1/001/record.json", "launch/attempts/c2/001/record.json" }, [_][]const u8{ "c1", "c2" }) |p, name| {
        const text = try std.fmt.allocPrint(testing.allocator, "{{\"rule\":\"{s}\",\"attempt\":1,\"status\":\"completed\",\"reason\":\"\",\"wall_s\":3.0,\"cpu_s\":0.0,\"request\":{{\"threads\":1,\"memory_mib\":64,\"reserved_mib\":96}},\"rusage\":{{\"maxrss_kib\":1024}}}}", .{name});
        defer testing.allocator.free(text);
        _ = try s.file(p, text);
    }
    _ = try s.file("launch/attempts/bad/001/record.json", "{\"rule\":");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, "launch" }));
    defer l.deinit();

    try testing.expectEqual(@as(usize, 1), l.unreadable.items.len);
    try testing.expect(std.mem.endsWith(u8, l.unreadable.items[0], "/attempts/bad/001/record.json"));
    for (l.steps) |st| if (std.mem.eql(u8, st.name, "sort")) {
        try testing.expect(st.used_is_peak);
        try testing.expectEqual(@as(f64, 256), st.used_mib);
        try testing.expect(st.sizing.memory_mib >= 256);
    };
    const memory = for (l.bounds) |b| {
        if (b.kind == .memory) break b;
    } else return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f64, (2.0 * 96.0 * 3.0 + 512.0) / 96.0), memory.seconds, 1e-6);
}

const Chain = struct { threads: u32 = 1, memory_mib: u32 = 1024, elapsed_s: f64 = 5.0, reused_p1: bool = false };

fn chainLaunch(s: *Scratch, a: std.mem.Allocator, name: []const u8, threads: u32) !void {
    try chainWith(s, a, name, .{ .threads = threads });
}

fn chainWith(s: *Scratch, a: std.mem.Allocator, name: []const u8, c: Chain) !void {
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
    _ = try s.file(try sub(a, name, "launch.json"), try std.fmt.allocPrint(a, "{{\"workdir\":\"{s}\",\"max_threads\":{d},\"max_memory_mib\":{d}}}", .{ s.path, c.threads, c.memory_mib }));
    _ = try s.file(try sub(a, name, "summary.json"), try std.fmt.allocPrint(a, "{{\"status\":\"completed\",\"elapsed_s\":{d:.1},\"selected\":3,\"counts\":{{\"completed\":3}},\"engine_cost\":{{\"cpu_s\":0.5,\"max_rss_mib\":5}}}}", .{c.elapsed_s}));
    const reuse = if (c.reused_p1) "{\"time\":\"2026-01-01T00:00:00.500Z\",\"event\":\"task_reused\",\"rule\":\"p1\"}\n" else "";
    _ = try s.file(try sub(a, name, "events.jsonl"), try std.fmt.allocPrint(a, "{{\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"selected\":3,\"max_threads\":{d},\"max_memory_mib\":{d},\"jobs\":{d},\"rules\":[\"p1\",\"p2\",\"join\"]}}\n{s}", .{ c.threads, c.memory_mib, c.threads, reuse }));
    _ = try s.file(try sub(a, name, "attempts/p2/001/record.json"),
        \\{"rule":"p2","attempt":1,"status":"completed","wall_s":3.0,"cpu_s":3.0,"started":"2026-01-01T00:00:00.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
    if (!c.reused_p1) _ = try s.file(try sub(a, name, "attempts/p1/001/record.json"),
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
    try testing.expectApproxEqAbs(@as(f64, 1.0), l.path[1].held_s, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), l.path_waited_s, 1e-6);
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
    try testing.expectEqual(@as(usize, 1), l.rules.len);
    try testing.expect(std.mem.indexOf(u8, l.snapshot_problem.?, "memory") != null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, dir, null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "the workflow snapshot cannot be read: line") != null);
    try workz.report.writeTsv(&out.writer, l.rows);
    try workz.report.writeSuggestions(&out.writer, &l, .tsv);
    try workz.report.writeSuggestions(&out.writer, &l, .table);
    try workz.html.write(testing.allocator, a, &out.writer, dir, null);
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
    try testing.expectEqualStrings("5124095576030431h 00m", w.buffered());
    w = .fixed(&buf);
    try workz.units.size(&w, std.math.nan(f64));
    try testing.expectEqualStrings("-", w.buffered());
}

fn diskLaunch(s: *Scratch, a: std.mem.Allocator, samples: usize) !void {
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/a", "launch/attempts/a/001", "launch/attempts/b", "launch/attempts/b/001", "launch/attempts/c", "launch/attempts/c/001" }) |d| _ = try s.dir(d);
    var wf: std.Io.Writer.Allocating = .init(a);
    try wf.writer.writeAll("[workflow]\nname = \"t\"\nversion = \"1\"\n\n[resource_groups.disk]\nmax = 1\n\n");
    for ([_][]const u8{ "a", "b", "c" }) |r| try wf.writer.print("[[rules]]\nname = \"{s}\"\noutput = [\"{s}.txt\"]\nshell = \"true\"\n[rules.resources]\nmemory = \"64M\"\ngroups = {{ disk = 1 }}\n\n", .{ r, r });
    _ = try s.file("launch/workflow", wf.written());
    _ = try s.file("launch/launch.json", try std.fmt.allocPrint(a, "{{\"workdir\":\"{s}\",\"max_threads\":4,\"max_memory_mib\":1024}}", .{s.path}));
    _ = try s.file("launch/summary.json",
        \\{"status":"completed","elapsed_s":6.0,"selected":3,"counts":{"completed":3}}
    );
    var ev: std.Io.Writer.Allocating = .init(a);
    try ev.writer.writeAll(
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","selected":3,"max_threads":4,"max_memory_mib":1024,"rules":["a","b","c"]}
        \\{"time":"2026-01-01T00:00:00.000Z","event":"task_started","rule":"a","attempt":1,"threads":1,"memory_mib":64}
        \\{"time":"2026-01-01T00:00:00.000Z","event":"task_waiting","rule":"b","reason":"group:disk"}
        \\{"time":"2026-01-01T00:00:00.000Z","event":"task_waiting","rule":"c","reason":"group:disk"}
        \\
    );
    for (1..samples + 1) |k| try ev.writer.print("{{\"time\":\"2026-01-01T00:00:0{d}.000Z\",\"event\":\"sample\",\"threads_reserved\":1,\"memory_reserved_mib\":64}}\n", .{k});
    try ev.writer.writeAll(
        \\{"time":"2026-01-01T00:00:04.000Z","event":"task_finished","rule":"a","attempt":1,"status":"completed"}
        \\{"time":"2026-01-01T00:00:04.000Z","event":"task_started","rule":"b","attempt":1,"threads":1,"memory_mib":64}
        \\{"time":"2026-01-01T00:00:05.000Z","event":"task_finished","rule":"b","attempt":1,"status":"completed"}
        \\{"time":"2026-01-01T00:00:05.000Z","event":"task_started","rule":"c","attempt":1,"threads":1,"memory_mib":64}
        \\{"time":"2026-01-01T00:00:06.000Z","event":"task_finished","rule":"c","attempt":1,"status":"completed"}
        \\
    );
    _ = try s.file("launch/events.jsonl", ev.written());
    _ = try s.file("launch/attempts/a/001/record.json",
        \\{"rule":"a","attempt":1,"status":"completed","wall_s":4.0,"cpu_s":4.0,"started":"2026-01-01T00:00:00.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
    _ = try s.file("launch/attempts/b/001/record.json",
        \\{"rule":"b","attempt":1,"status":"completed","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:04.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":4.0,"reasons":[{"reason":"group:disk","seconds":4.0}]}}
    );
    _ = try s.file("launch/attempts/c/001/record.json",
        \\{"rule":"c","attempt":1,"status":"completed","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:05.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":5.0,"reasons":[{"reason":"group:disk","seconds":5.0}]}}
    );
}

test "[unit] - [report]: a group's run samples count once however many rules waited" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try diskLaunch(&s, a, 3);
    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, "launch" }));
    defer l.deinit();
    try testing.expectEqual(@as(usize, 1), l.groups.len);
    try testing.expectEqual(@as(usize, 3), l.groups[0].samples);
    try testing.expectApproxEqAbs(@as(f64, 1.0), l.groups[0].fit.?, 1e-9);
}

test "[edge] - [report]: a resource group judged from one or two run samples says too few to judge" {
    const cases = [_]struct { samples: usize, text: []const u8 }{
        .{ .samples = 1, .text = "waited; 1 run sample while they waited, too few to judge\n" },
        .{ .samples = 2, .text = "waited; 2 run samples while they waited, too few to judge\n" },
    };
    for (cases) |c| {
        var s = try Scratch.init();
        defer s.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try diskLaunch(&s, a, c.samples);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, "launch" }), null);
        const row = lineStarting(out.written(), "  disk ") orelse return error.TestUnexpectedResult;
        try testing.expect(std.mem.endsWith(u8, row, c.text[0 .. c.text.len - 1]));
    }
}

fn lineStarting(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) return line;
    return null;
}

test "[unit] - [report]: a long name keeps its start and end, cut between characters" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("align_sam...ule_name", workz.units.middle(&buf, "align_sample_with_a_long_rule_name", 20));
    try testing.expectEqualStrings("short", workz.units.middle(&buf, "short", 20));
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
    const rows = try workz.model.attempts(testing.allocator, a, dir, null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeTsv(&out.writer, rows);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "rule\tattempt\tstatus\twall_s\tcpu_s\tcpu_efficiency\t"));
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        try testing.expect(std.mem.indexOf(u8, line, "\t\t") == null);
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(std.mem.indexOf(u8, out.written(), "p2\t1\tcompleted\t3.000\t3.000\t1.0000\t1\t64\tNA\t") != null);

    out.clearRetainingCapacity();
    try workz.report.writeJson(a, &out.writer, rows);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
    try testing.expectEqual(@as(usize, 3), v.array.items.len);
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
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, one, null);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    _ = lines.next();
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "the thread budget limited this launch: it took 5.0 s"));
    for ([_][]const u8{ "\nwhat limited the launch", "\ncritical path", "\nwaiting for resources", "\nsteps" }) |section|
        try testing.expect(std.mem.indexOf(u8, out.written(), section) != null);

    out.clearRetainingCapacity();
    try workz.report.writeCompare(testing.allocator, a, &out.writer, one, two, null);
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

test "[failure] - [report]: a record or event of a newer format is left out and counted, never misread" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/a", "launch/attempts/a/001", "launch/attempts/b", "launch/attempts/b/001" }) |d| _ = try s.dir(d);
    _ = try s.file("launch/events.jsonl",
        \\{"v":1,"time":"2026-01-01T00:00:00.000Z","event":"launch_started","max_threads":4,"max_memory_mib":96}
        \\{"v":2,"time":"2026-01-01T00:00:01.000Z","event":"task_started","rule":"a","attempt":1}
        \\
    );
    _ = try s.file("launch/attempts/a/001/record.json",
        \\{"v":2,"rule":"a","attempt":1,"status":"completed","reason":"","wall_s":1.0,"request":{"threads":1,"memory_mib":1}}
    );
    _ = try s.file("launch/attempts/b/001/record.json",
        \\{"rule":"b","attempt":1,"status":"completed","reason":"","wall_s":1.0,"request":{"threads":1,"memory_mib":1}}
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, "launch" }));
    defer l.deinit();

    try testing.expectEqual(@as(usize, 1), l.tracker.unreadable_lines);
    try testing.expectEqual(@as(usize, 1), l.unreadable.items.len);
    try testing.expect(std.mem.endsWith(u8, l.unreadable.items[0], "/attempts/a/001/record.json"));
    try testing.expectEqual(@as(usize, 1), l.rows.len);
    try testing.expectEqualStrings("b", l.rows[0].rule);
}

test "[failure] - [report]: the bottleneck report, a comparison and the page name the records they leave out" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainLaunch(&s, a, "good", 1);
    for ([_][]const u8{ "bad", "bad/attempts", "bad/attempts/r", "bad/attempts/r/001" }) |d| _ = try s.dir(d);
    _ = try s.file("bad/events.jsonl", "{\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"max_threads\":1,\"max_memory_mib\":64}\n");
    _ = try s.file("bad/attempts/r/001/record.json", "{\"rule\":");
    const good = try std.fs.path.join(a, &.{ s.path, "good" });
    const bad = try std.fs.path.join(a, &.{ s.path, "bad" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var unread: std.ArrayList([]const u8) = .empty;
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, bad, &unread);
    try testing.expectEqual(@as(usize, 1), unread.items.len);
    try testing.expect(std.mem.endsWith(u8, unread.items[0], "/bad/attempts/r/001/record.json"));

    unread = .empty;
    try workz.report.writeCompare(testing.allocator, a, &out.writer, good, bad, &unread);
    try testing.expectEqual(@as(usize, 1), unread.items.len);

    unread = .empty;
    try workz.html.write(testing.allocator, a, &out.writer, bad, &unread);
    try testing.expectEqual(@as(usize, 1), unread.items.len);
}

test "[edge] - [report]: a summary over a mebibyte, as of a large interrupted launch, is read" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.dir("big");
    _ = try s.file("big/events.jsonl", "{\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"max_threads\":1,\"max_memory_mib\":64}\n");
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try text.writer.writeAll("{\"v\":1,\"status\":\"interrupted\",\"elapsed_s\":9.5,\"selected\":12000,\"failures\":[");
    for (0..12000) |k| try text.writer.print("{s}{{\"rule\":\"S{d:0>5}__align\",\"status\":\"cancelled\",\"reason\":\"cancelled: the launch was interrupted\",\"stderr\":null,\"diagnostics\":[]}}", .{ if (k == 0) "" else ",", k });
    try text.writer.writeAll("]}\n");
    try testing.expect(text.written().len > 1 << 20);
    _ = try s.file("big/summary.json", text.written());

    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, "big" }));
    defer l.deinit();

    try testing.expect(l.finished);
    try testing.expectEqualStrings("interrupted", l.status);
    try testing.expectEqual(@as(usize, 0), l.unreadable.items.len);
}

test "[failure] - [report]: an attempt's status from its record is escaped on the page" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/r", "launch/attempts/r/001" }) |d| _ = try s.dir(d);
    _ = try s.file("launch/events.jsonl", "{\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"max_threads\":1,\"max_memory_mib\":64}\n");
    _ = try s.file("launch/attempts/r/001/record.json",
        \\{"rule":"r","attempt":1,"status":"<x-odd>","reason":"","wall_s":1.0,"cpu_s":0.0,"started":"2026-01-01T00:00:01.000Z","request":{"threads":1,"memory_mib":64}}
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try workz.html.write(testing.allocator, arena.allocator(), &out.writer, try std.fs.path.join(arena.allocator(), &.{ s.path, "launch" }), null);

    try testing.expect(std.mem.indexOf(u8, out.written(), "<x-odd") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "&lt;x-odd&gt;") != null);
}

test "[unit] - [report]: a launch without a summary and without its engine reads as unfinished, as of its last event" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ ".workz", ".workz/launches", ".workz/launches/L1" }) |d| _ = try s.dir(d);
    _ = try s.file(".workz/launches/L1/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","max_threads":1,"max_memory_mib":64}
        \\{"time":"2026-01-01T00:00:04.000Z","event":"task_started","rule":"r","attempt":1,"directory":""}
        \\
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, ".workz/launches/L1" }));
    defer l.deinit();

    try testing.expect(l.finished);
    try testing.expectEqualStrings("unfinished", l.status);
    try testing.expectEqual(@as(f64, 4), l.elapsed_s);
}

test "[edge] - [report]: a --threads override of a step whose name holds '=' reaches the report" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.dir("launch");
    _ = try s.file("launch/launch.json", try std.fmt.allocPrint(a, "{{\"workdir\":\"{s}\",\"thread_overrides\":[\"k=v=4\"]}}", .{s.path}));
    _ = try s.file("launch/events.jsonl", "{\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"max_threads\":8,\"max_memory_mib\":64,\"rules\":[\"a\"]}\n");
    _ = try s.file("launch/workflow", "[workflow]\nname = \"w\"\n\n[[rules]]\nname = \"a\"\nstep = \"k=v\"\noutput = [\"a.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n");

    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, "launch" }));
    defer l.deinit();

    try testing.expectEqual(@as(u32, 4), l.wf.?.rules[0].threads);
}

test "[unit] - [report]: budget use from run samples says it covers the time rules ran" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.dir("launch");
    _ = try s.file("launch/summary.json", "{\"status\":\"completed\",\"elapsed_s\":20.0,\"selected\":1}");
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","max_threads":4,"max_memory_mib":1024}
        \\{"time":"2026-01-01T00:00:05.000Z","event":"sample","running":1,"threads_reserved":2,"memory_reserved_mib":256,"cpu_cores_used":1.5}
        \\{"time":"2026-01-01T00:00:10.000Z","event":"sample","running":1,"threads_reserved":2,"memory_reserved_mib":256,"cpu_cores_used":1.5}
        \\
    );
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, "launch" }), null);

    try testing.expect(std.mem.indexOf(u8, out.written(), "\nuse of the budget while rules ran (run samples every 5 s)\n  threads reserved 2.0 of 4 on average; CPU cores in use 1.5 on average\n") != null);
}

test "[unit] - [report]: the checks before the first rule are a term of the elapsed time, not time after the path" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/r", "launch/attempts/r/001" }) |d| _ = try s.dir(d);
    _ = try s.file("launch/launch.json", try std.fmt.allocPrint(a, "{{\"workdir\":\"{s}\"}}", .{s.path}));
    _ = try s.file("launch/workflow", "[workflow]\nname = \"w\"\n\n[[rules]]\nname = \"r\"\noutput = [\"r.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n");
    _ = try s.file("launch/summary.json", "{\"status\":\"completed\",\"elapsed_s\":5.0,\"selected\":1}");
    _ = try s.file("launch/events.jsonl", "{\"time\":\"2026-01-01T00:00:02.000Z\",\"event\":\"launch_started\",\"max_threads\":1,\"max_memory_mib\":64,\"rules\":[\"r\"],\"checks_s\":2.0}\n");
    _ = try s.file("launch/attempts/r/001/record.json",
        \\{"rule":"r","attempt":1,"status":"completed","wall_s":3.0,"cpu_s":3.0,"started":"2026-01-01T00:00:02.000Z","request":{"threads":1,"memory_mib":1}}
    );

    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, "launch" }));
    defer l.deinit();

    try testing.expectEqual(@as(f64, 2), l.path_checks_s);
    try testing.expectEqual(@as(f64, 0), l.path_after_s);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, "launch" }), null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "2.0 s of checks before the first rule") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "after the path did") == null);
}

test "[unit] - [report]: a process figure no larger than the engine's memory is shown as at most that" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/small", "launch/attempts/small/001", "launch/attempts/large", "launch/attempts/large/001" }) |d| _ = try s.dir(d);
    _ = try s.file("launch/summary.json", "{\"status\":\"completed\",\"elapsed_s\":2.0,\"selected\":2}");
    _ = try s.file("launch/events.jsonl", "{\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"max_threads\":2,\"max_memory_mib\":1024}\n");
    _ = try s.file("launch/attempts/small/001/record.json",
        \\{"rule":"small","attempt":1,"status":"completed","wall_s":1.0,"cpu_s":1.0,"request":{"threads":1,"memory_mib":256},"rusage":{"maxrss_kib":14000,"engine_maxrss_kib":14336}}
    );
    _ = try s.file("launch/attempts/large/001/record.json",
        \\{"rule":"large","attempt":1,"status":"completed","wall_s":1.0,"cpu_s":1.0,"request":{"threads":1,"memory_mib":1024},"rusage":{"maxrss_kib":614400,"engine_maxrss_kib":14336}}
    );

    var l = try workz.model.load(testing.allocator, a, try std.fs.path.join(a, &.{ s.path, "launch" }));
    defer l.deinit();
    for (l.steps) |st| try testing.expectEqual(std.mem.eql(u8, st.name, "small"), st.used_bound);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeSuggestions(&out.writer, &l, .table);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<=14 MiB") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<=600 MiB") == null);
    out.clearRetainingCapacity();
    try workz.report.writeSuggestions(&out.writer, &l, .tsv);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\tengine_bound\t") != null);
}

test "[unit] - [report]: a live model reads each record once and ends as a fresh load of the launch" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainLaunch(&s, a, "done", 1);
    for ([_][]const u8{ ".workz", ".workz/launches", ".workz/launches/L1", ".workz/launches/L1/attempts", ".workz/launches/L1/attempts/p1", ".workz/launches/L1/attempts/p1/001", ".workz/launches/L1/attempts/p2", ".workz/launches/L1/attempts/p2/001", ".workz/launches/L1/attempts/join", ".workz/launches/L1/attempts/join/001" }) |d| _ = try s.dir(d);
    for ([_][]const u8{ "workflow", "launch.json" }) |name| {
        const bytes = try workz.sys.readFile(a, try std.fs.path.join(a, &.{ s.path, "done", name }), 1 << 20);
        _ = try s.file(try std.fs.path.join(a, &.{ ".workz/launches/L1", name }), bytes);
    }
    const started =
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","selected":3,"max_threads":1,"max_memory_mib":1024,"jobs":1,"rules":["p1","p2","join"]}
        \\{"time":"2026-01-01T00:00:00.000Z","event":"task_started","rule":"p2","attempt":1,"directory":""}
        \\
    ;
    _ = try s.file(".workz/launches/L1/events.jsonl", started);
    const dir = try std.fs.path.join(a, &.{ s.path, ".workz/launches/L1" });
    _ = try s.file(".workz/lock", "");
    const lock = try workz.records.lock(testing.allocator, try std.fs.path.join(a, &.{ s.path, ".workz" }));
    defer workz.sys.close(lock);

    var live = try workz.model.Live.open(testing.allocator, dir);
    defer live.deinit();
    try testing.expect(!live.launch.finished);
    try testing.expectEqual(@as(usize, 0), live.launch.rows.len);
    try testing.expectEqual(@as(usize, 1), live.launch.counts.running);

    const record = struct {
        fn copy(sc: *Scratch, al: std.mem.Allocator, rule: []const u8) !void {
            const rel = try std.fmt.allocPrint(al, "attempts/{s}/001/record.json", .{rule});
            const bytes = try workz.sys.readFile(al, try std.fs.path.join(al, &.{ sc.path, "done", rel }), 1 << 20);
            _ = try sc.file(try std.fs.path.join(al, &.{ ".workz/launches/L1", rel }), bytes);
        }
    }.copy;
    try record(&s, a, "p2");
    const p2_done = started ++
        \\{"time":"2026-01-01T00:00:03.000Z","event":"task_finished","rule":"p2","attempt":1,"status":"completed"}
        \\{"time":"2026-01-01T00:00:03.000Z","event":"task_started","rule":"p1","attempt":1,"directory":""}
        \\
    ;
    _ = try s.file(".workz/launches/L1/events.jsonl", p2_done);
    try testing.expect(try live.refresh());
    try testing.expectEqual(@as(usize, 1), live.launch.rows.len);
    try testing.expectEqual(workz.model.State.completed, live.launch.ruleOf("p2").?.state);
    try testing.expect(!try live.refresh());

    try record(&s, a, "p1");
    try record(&s, a, "join");
    _ = try s.file(".workz/launches/L1/events.jsonl", p2_done ++
        \\{"time":"2026-01-01T00:00:04.000Z","event":"task_finished","rule":"p1","attempt":1,"status":"completed"}
        \\{"time":"2026-01-01T00:00:04.000Z","event":"task_started","rule":"join","attempt":1,"directory":""}
        \\{"time":"2026-01-01T00:00:05.000Z","event":"task_finished","rule":"join","attempt":1,"status":"completed"}
        \\{"time":"2026-01-01T00:00:05.000Z","event":"launch_finished","status":"completed"}
        \\
    );
    const summary = try workz.sys.readFile(a, try std.fs.path.join(a, &.{ s.path, "done", "summary.json" }), 1 << 20);
    _ = try s.file(".workz/launches/L1/summary.json", summary);
    try testing.expect(try live.refresh());

    var fresh = try workz.model.load(testing.allocator, a, dir);
    defer fresh.deinit();
    const l = &live.launch;
    try testing.expect(l.finished);
    try testing.expectEqualStrings(fresh.status, l.status);
    try testing.expectEqual(fresh.elapsed_s, l.elapsed_s);
    try testing.expectEqual(fresh.counts, l.counts);
    try testing.expectEqual(fresh.rows.len, l.rows.len);
    for (fresh.rows, l.rows) |x, y| {
        try testing.expectEqualStrings(x.rule, y.rule);
        try testing.expectEqual(x.wall_s, y.wall_s);
    }
    try testing.expectEqual(fresh.steps.len, l.steps.len);
    try testing.expectEqual(fresh.path.len, l.path.len);
    try testing.expectEqual(fresh.path_ran_s, l.path_ran_s);
    try testing.expectEqual(fresh.path_after_s, l.path_after_s);
    try testing.expectEqual(fresh.bounds[fresh.binding.?].kind, l.bounds[l.binding.?].kind);
    try testing.expectEqual(fresh.waits.count(), l.waits.count());
}

test "[failure] - [report]: a live model finds records the events do not name, and names a damaged one once" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainLaunch(&s, a, "launch", 1);
    for ([_][]const u8{ "launch/attempts/odd", "launch/attempts/odd/001" }) |d| _ = try s.dir(d);
    _ = try s.file("launch/attempts/odd/001/record.json", "{\"rule\":");

    var live = try workz.model.Live.open(testing.allocator, try std.fs.path.join(a, &.{ s.path, "launch" }));
    defer live.deinit();
    try testing.expectEqual(@as(usize, 3), live.launch.rows.len);
    try testing.expectEqual(@as(usize, 1), live.launch.unreadable.items.len);
    try testing.expect(std.mem.endsWith(u8, live.launch.unreadable.items[0], "/attempts/odd/001/record.json"));
    try testing.expect(!try live.refresh());
    try testing.expect(!try live.refresh());
    try testing.expectEqual(@as(usize, 1), live.launch.unreadable.items.len);
    try testing.expectEqual(@as(usize, 2), live.launch.path.len);
}

test "[unit] - [report]: resource drawings retain plateau endpoints and every spike" {
    var s = try Scratch.init();
    defer s.deinit();
    var l: workz.model.Launch = .{
        .gpa = testing.allocator,
        .dir = s.path,
        .id = "samples",
        .tracker = try workz.tracker.Tracker.init(testing.allocator, s.path),
        .elapsed_s = 8,
        .max_threads = 2,
        .max_memory_mib = 128,
        .finished = true,
    };
    defer l.deinit();
    for (0..9) |i| try l.tracker.samples.append(l.tracker.arena.allocator(), .{
        .ns = @as(i128, @intCast(i)) * std.time.ns_per_s,
        .threads_reserved = 1,
        .memory_reserved_mib = 64,
        .shared_reserved_mib = 32,
        .memory_current = 32 * 1024 * 1024,
        .cpu_cores = if (i == 3) 2 else 1,
    });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.writeLaunch(testing.allocator, &out.writer, &l);
    const marker = "<polyline style=\"fill:none;stroke:var(--ink);stroke-width:2;stroke-linejoin:round\" points=\"";
    const start = std.mem.indexOf(u8, out.written(), marker).? + marker.len;
    const end = std.mem.indexOfScalarPos(u8, out.written(), start, '"').?;
    try testing.expectEqualStrings("70.0,103.0 189.5,103.0 249.3,14.0 309.0,103.0 548.0,103.0", out.written()[start..end]);
    try testing.expectEqual(@as(usize, 9), l.usage().len);
    try testing.expect(std.mem.indexOf(u8, out.written(), "class=\"drawing\" style=\"aspect-ratio:560/220\"") != null);
    l.tracker.samples.items[2].ns = 0;
    out.clearRetainingCapacity();
    try workz.html.writeLaunch(testing.allocator, &out.writer, &l);
    const reversed_start = std.mem.indexOf(u8, out.written(), marker).? + marker.len;
    const reversed_end = std.mem.indexOfScalarPos(u8, out.written(), reversed_start, '"').?;
    try testing.expectEqualStrings("70.0,103.0 129.8,103.0 70.0,103.0 249.3,14.0 309.0,103.0 548.0,103.0", out.written()[reversed_start..reversed_end]);
}

test "[edge] - [report]: a sample cell keeps the longest run and the first equal run" {
    var s = try Scratch.init();
    defer s.deinit();
    const dir = try s.dir("launch");
    _ = try s.dir("launch/attempts");
    _ = try s.file("launch/summary.json", "{\"status\":\"completed\",\"elapsed_s\":10}");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "a", "b", "whole" }, [_]u32{ 3, 7, 5 }) |name, cpu| {
        _ = try s.dir(try std.fmt.allocPrint(a, "launch/attempts/{s}", .{name}));
        _ = try s.dir(try std.fmt.allocPrint(a, "launch/attempts/{s}/001", .{name}));
        _ = try s.file(try std.fmt.allocPrint(a, "launch/attempts/{s}/001/record.json", .{name}), try std.fmt.allocPrint(a, "{{\"rule\":\"{s}\",\"attempt\":1,\"status\":\"completed\",\"wall_s\":10,\"cpu_s\":{d},\"labels\":{{\"step\":\"align\"{s}}}}}", .{ name, cpu, if (std.mem.eql(u8, name, "whole")) "" else ",\"sample\":\"same\"" }));
    }
    var l = try workz.model.load(testing.allocator, a, dir);
    defer l.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.writeLaunch(testing.allocator, &out.writer, &l);
    try testing.expect(std.mem.indexOf(u8, out.written(), "same &middot; align: completed, 10.0 s wall, 3.0 s CPU") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "whole run &middot; align: completed, 10.0 s wall, 5.0 s CPU") != null);
    const bi = l.rule_index.get("b").?;
    var longer = l.rules[bi].run.?.*;
    longer.wall_s = 20;
    l.rules[bi].run = &longer;
    out.clearRetainingCapacity();
    try workz.html.writeLaunch(testing.allocator, &out.writer, &l);
    try testing.expect(std.mem.indexOf(u8, out.written(), "same &middot; align: completed, 20.0 s wall, 7.0 s CPU") != null);
}

test "[unit] - [report]: the html page of a refused launch says why and that no rule ran" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try s.dir("launch");
    _ = try s.file("launch/summary.json",
        \\{"status":"refused","elapsed_s":0.1,"selected":2,"counts":{"not_started":2},"error":"a recorded output changed","changed_outputs":[{"rule":"a","path":"/data/a.txt"}]}
    );
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","selected":2,"max_threads":1,"max_memory_mib":64,"rules":["a","b"]}
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_refused","reason":"a recorded output changed"}
        \\
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.write(testing.allocator, arena.allocator(), &out.writer, launch, null);
    const page = out.written();
    try testing.expect(std.mem.indexOf(u8, page, "<span class=\"stamp s-fail\">refused</span><div class=\"sub why\">a recorded output changed</div>") != null);
    try testing.expect(std.mem.indexOf(u8, page, "; the launch was refused, so none ran") != null);
    try testing.expect(std.mem.indexOf(u8, page, "No attempt ran in this launch.") != null);
}

test "[unit] - [report]: the html page of a failed launch names its first failure and shows that attempt's diagnostics" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try s.dir("launch");
    _ = try s.dir("launch/attempts");
    _ = try s.dir("launch/attempts/align");
    _ = try s.dir("launch/attempts/align/001");
    _ = try s.dir("launch/attempts/align/001/diagnostics");
    _ = try s.dir("launch/attempts/align/001/diagnostics/a");
    _ = try s.dir("launch/attempts/align/001/diagnostics/a/s1");
    _ = try s.file("launch/summary.json",
        \\{"status":"failed","elapsed_s":3.0,"selected":1,"counts":{"failed":1},"failures":[{"rule":"align","status":"failed","reason":"exited with status 4: FATAL ERROR: genome too large"}]}
    );
    _ = try s.file("launch/events.jsonl", "{\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"max_threads\":1,\"max_memory_mib\":64,\"rules\":[\"align\"]}\n");
    _ = try s.file("launch/attempts/align/001/record.json",
        \\{"rule":"align","attempt":1,"status":"failed","reason":"exited with status 4: FATAL ERROR: genome too large","wall_s":2.0,"cpu_s":1.0,"started":"2026-01-01T00:00:01.000Z","request":{"threads":1,"memory_mib":64},"diagnostics":["a/s1/Log.out"]}
    );
    _ = try s.file("launch/attempts/align/001/stdout.log", "");
    _ = try s.file("launch/attempts/align/001/stderr.log", "");
    _ = try s.file("launch/attempts/align/001/diagnostics/a/s1/Log.out", "loaded\nFATAL ERROR: genome too large\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.write(testing.allocator, a, &out.writer, launch, null);
    const page = out.written();
    try testing.expect(std.mem.indexOf(u8, page, "<div class=\"sub why\"><span class=\"mono\">align</span>: exited with status 4: FATAL ERROR: genome too large</div>") != null);
    try testing.expect(std.mem.indexOf(u8, page, "<p class=\"diag mono\">a/s1/Log.out</p>") != null);

    var logs: std.Io.Writer.Allocating = .init(testing.allocator);
    defer logs.deinit();
    try workz.logs.show(testing.allocator, a, &logs.writer, try std.fs.path.join(a, &.{ s.path, "launch/attempts/align/001" }), .{}, .{ .word = "align" });
    try testing.expect(std.mem.indexOf(u8, logs.written(), "diagnostics a/s1/Log.out  align  attempt 1  failed  ") != null);
    try testing.expect(std.mem.indexOf(u8, logs.written(), "\nloaded\nFATAL ERROR: genome too large\n") != null);
}

test "[unit] - [report]: the bottleneck report lists a service with the requests it served and the memory it held" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try s.dir("launch");
    _ = try s.dir("launch/attempts");
    _ = try s.dir("launch/attempts/u1");
    _ = try s.dir("launch/attempts/u1/001");
    _ = try s.file("launch/summary.json",
        \\{"status":"completed","elapsed_s":5.0,"selected":1,"counts":{"completed":1}}
    );
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","selected":1,"max_threads":4,"max_memory_mib":1024,"rules":["u1"]}
        \\{"time":"2026-01-01T00:00:00.100Z","event":"shared_loading","name":"seg","memory_mib":64}
        \\{"time":"2026-01-01T00:00:01.000Z","event":"shared_loaded","name":"seg"}
        \\{"time":"2026-01-01T00:00:01.100Z","event":"task_started","rule":"u1","attempt":1,"directory":"","shared":["seg"],"threads":1,"memory_mib":64}
        \\{"time":"2026-01-01T00:00:02.100Z","event":"task_finished","rule":"u1","attempt":1,"status":"completed"}
        \\{"time":"2026-01-01T00:00:02.200Z","event":"shared_released","name":"seg","memory_peak":41943040}
        \\
    );
    _ = try s.file("launch/attempts/u1/001/record.json",
        \\{"rule":"u1","attempt":1,"status":"completed","reason":"","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:01.100Z","request":{"threads":1,"memory_mib":64}}
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, launch, null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\nshared inputs\n") != null);
    const row = lineStarting(out.written(), "  seg ") orelse return error.TestUnexpectedResult;
    var tokens = std.mem.tokenizeScalar(u8, row, ' ');
    try testing.expectEqualStrings("seg", tokens.next().?);
    try testing.expectEqualStrings("service", tokens.next().?);
    try testing.expectEqualStrings("1", tokens.next().?);
    try testing.expectEqualStrings("1", tokens.next().?);
    try testing.expect(std.mem.indexOf(u8, row, "64 MiB") != null);
}

test "[unit] - [report]: the html page draws each shared input under the pipeline, with its memory and its users" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try s.dir("launch");
    _ = try s.dir("launch/attempts");
    _ = try s.dir("launch/attempts/build");
    _ = try s.dir("launch/attempts/build/001");
    _ = try s.dir("launch/attempts/use");
    _ = try s.dir("launch/attempts/use/001");
    _ = try s.file("launch/workflow",
        \\[workflow]
        \\name = "service"
        \\version = "1"
        \\
        \\[shared.ix]
        \\path = "idx"
        \\container = "img"
        \\command = "cat idx/data"
        \\memory = "64M"
        \\
        \\[[rules]]
        \\name = "build"
        \\output = ["idx/data"]
        \\shell = "true"
        \\memory = "1M"
        \\
        \\[[rules]]
        \\name = "use"
        \\input = ["idx"]
        \\output = ["u.txt"]
        \\container = "img"
        \\shell = "true"
        \\memory = "1M"
        \\[rules.resources]
        \\shared = ["ix"]
        \\
    );
    var info: [256]u8 = undefined;
    _ = try s.file("launch/launch.json", try std.fmt.bufPrint(&info, "{{\"workdir\":\"{s}\",\"max_threads\":4,\"max_memory_mib\":1024}}", .{s.path}));
    _ = try s.file("launch/summary.json",
        \\{"status":"completed","elapsed_s":3.0,"selected":2,"counts":{"completed":2}}
    );
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","selected":2,"max_threads":4,"max_memory_mib":1024,"rules":["build","use"]}
        \\{"time":"2026-01-01T00:00:01.000Z","event":"task_started","rule":"use","attempt":1,"directory":"","shared":["ix"],"threads":1,"memory_mib":64}
        \\
    );
    _ = try s.file("launch/attempts/build/001/record.json",
        \\{"rule":"build","attempt":1,"status":"completed","reason":"","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:00.000Z","request":{"threads":1,"memory_mib":1}}
    );
    _ = try s.file("launch/attempts/use/001/record.json",
        \\{"rule":"use","attempt":1,"status":"completed","reason":"","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:01.000Z","request":{"threads":1,"memory_mib":1}}
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.write(testing.allocator, arena.allocator(), &out.writer, launch, null);
    const page = out.written();
    try testing.expect(std.mem.indexOf(u8, page, "id=\"layer-shared\" checked") != null);
    try testing.expect(std.mem.indexOf(u8, page, "service &middot; 64 MiB once &middot; 1 user") != null);
    try testing.expect(std.mem.indexOf(u8, page, "class=\"wire wire-loads\"") != null);
}

test "[unit] - [methods]: the methods text and JSON name the workflow, the tools with their versions and each step's command" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ ".workz", ".workz/launches", ".workz/launches/L1", ".workz/launches/L1/attempts", ".workz/launches/L1/attempts/up_s1", ".workz/launches/L1/attempts/up_s1/001", ".workz/launches/L1/attempts/up_s2", ".workz/launches/L1/attempts/up_s2/001", ".workz/launches/L2", ".workz/launches/L2/attempts", ".workz/launches/L2/attempts/join", ".workz/launches/L2/attempts/join/001" }) |d| _ = try s.dir(d);
    _ = try s.file(".workz/state.json",
        \\{"format_version": 4, "files": {}, "manifest": {}, "envs": {}, "rules": {
        \\"up_s1": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "kanit 9.9.9", "outputs": [],
        \\  "attempt": ".workz/launches/L1/attempts/up_s1/001", "finished": "2026-01-01T00:00:01.000Z"},
        \\"up_s2": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "kanit 9.9.9", "outputs": [],
        \\  "attempt": ".workz/launches/L1/attempts/up_s2/001", "finished": "2026-01-01T00:00:02.000Z"},
        \\"join": {"key": "k", "command": "c", "env": "e", "request": "r", "writes": "w", "inputs": "i", "parents": "p", "engine": "kanit 9.9.9", "outputs": [],
        \\  "attempt": ".workz/launches/L2/attempts/join/001", "finished": "2026-01-01T00:00:03.000Z"}}}
    );
    const launch_info =
        \\{"engine":"kanit 9.9.9","workflow_name":"methods","workflow_version":"2.1","workflow_sha256":"ab12"}
    ;
    _ = try s.file(".workz/launches/L1/launch.json", launch_info);
    _ = try s.file(".workz/launches/L2/launch.json", launch_info);
    _ = try s.file(".workz/launches/L1/versions.json",
        \\{"commands":[{"command":"echo upper 1.4.2","output":"upper 1.4.2\n","exit_code":0}]}
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "up_s1", "up_s2" }, [_][]const u8{ "echo one > s1.txt", "echo two > s2.txt" }) |name, shell| {
        _ = try s.file(try std.fmt.allocPrint(a, ".workz/launches/L1/attempts/{s}/001/record.json", .{name}), try std.fmt.allocPrint(a, "{{\"rule\":\"{s}\",\"attempt\":1,\"status\":\"completed\",\"reason\":\"\",\"wall_s\":1.0,\"cpu_s\":1.0,\"version\":\"echo upper 1.4.2\",\"labels\":{{\"step\":\"up\",\"tool\":\"upper\"}},\"request\":{{\"threads\":1,\"memory_mib\":64}}}}", .{name}));
        _ = try s.file(try std.fmt.allocPrint(a, ".workz/launches/L1/attempts/{s}/001/request.json", .{name}), try std.fmt.allocPrint(a, "{{\"shell\":\"{s}\"}}", .{shell}));
    }
    _ = try s.file(".workz/launches/L2/attempts/join/001/record.json",
        \\{"rule":"join","attempt":1,"status":"completed","reason":"","wall_s":1.0,"cpu_s":1.0,"request":{"threads":1,"memory_mib":64}}
    );
    _ = try s.file(".workz/launches/L2/attempts/join/001/request.json", "{\"shell\":\"cat s1.txt s2.txt > all.txt\"}");
    const m = try workz.methods.collect(testing.allocator, a, s.path);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.methods.writeText(&out.writer, m);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "\n  methods 2.1, file sha256:ab12\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n  upper: upper 1.4.2\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    up_s1: echo one > s1.txt\n") != null);

    out.clearRetainingCapacity();
    try workz.methods.writeJson(&out.writer, m);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
    try testing.expectEqual(@as(i64, 3), v.object.get("rules").?.integer);
    try testing.expectEqual(@as(usize, 2), v.object.get("launches").?.array.items.len);
    const first_step = v.object.get("steps").?.array.items[0].object;
    try testing.expectEqualStrings("up", first_step.get("step").?.string);
    try testing.expectEqual(@as(i64, 2), first_step.get("rules").?.integer);
}

test "[unit] - [report]: a comparison of equal budgets prints no budget note and a row per step" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainLaunch(&s, a, "one", 1);
    try chainLaunch(&s, a, "two", 1);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeCompare(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, "one" }), try std.fs.path.join(a, &.{ s.path, "two" }), null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\nbudget   1 threads, 1.0 GiB, 1 jobs against 1 threads, 1.0 GiB, 1 jobs\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "note: the budgets differ") == null);
    try testing.expect(lineStarting(out.written(), "  elapsed s ") != null);
    const row = lineStarting(out.written(), "  p1 ") orelse return error.TestUnexpectedResult;
    var tokens = std.mem.tokenizeScalar(u8, row, ' ');
    try testing.expectEqualStrings("p1", tokens.next().?);
    try testing.expectEqualStrings("1", tokens.next().?);
}

test "[unit] - [report]: a comparison marks a step with no completed run in the launch, and gives no change for it" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainLaunch(&s, a, "one", 1);
    try chainLaunch(&s, a, "two", 1);
    _ = try s.file("two/attempts/p2/001/record.json",
        \\{"rule":"p2","attempt":1,"status":"failed","reason":"exited with status 1","wall_s":3.0,"cpu_s":3.0,"started":"2026-01-01T00:00:00.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeCompare(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, "one" }), try std.fs.path.join(a, &.{ s.path, "two" }), null);
    const row = lineStarting(out.written(), "  p2 ") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.endsWith(u8, row, "no completed run in the launch"));
    try testing.expect(std.mem.indexOf(u8, row, "%") == null);
}

test "[unit] - [report]: a comparison names a step the launch reused, with the run it reused" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.dir(".workz");
    _ = try s.dir(".workz/launches");
    const first = ".workz/launches/20260101T000000.000-aaaaaaaa";
    const second = ".workz/launches/20260102T000000.000-bbbbbbbb";
    try chainWith(&s, a, first, .{});
    try chainWith(&s, a, second, .{ .reused_p1 = true });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeCompare(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, first }), try std.fs.path.join(a, &.{ s.path, second }), null);
    const row = lineStarting(out.written(), "  p1 ") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.endsWith(u8, row, "%  reused in the launch"));
    try testing.expect(std.mem.indexOf(u8, row, "%") != null);
}

test "[edge] - [report]: a launch shorter than two seconds says too short to say what limited it, and lists the engine" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainWith(&s, a, "launch", .{ .elapsed_s = 1.0 });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, "launch" }), null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "too short to say what limited it: it took 1.0 s") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\n    engine ") != null);
}

test "[unit] - [report]: a launch whose memory budget set its length says the memory budget limited it" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainWith(&s, a, "launch", .{ .threads = 4, .memory_mib = 64 });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, "launch" }), null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "the memory budget limited this launch: it took 5.0 s, 0% more than") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\n  > memory ") != null);
}

fn labelsLaunch(s: *Scratch, a: std.mem.Allocator) !void {
    for ([_][]const u8{ "launch", "launch/attempts", "launch/attempts/s1__ALIGN", "launch/attempts/s1__ALIGN/001", "launch/attempts/s2__ALIGN", "launch/attempts/s2__ALIGN/001", "launch/attempts/merge_all", "launch/attempts/merge_all/001" }) |d| _ = try s.dir(d);
    _ = try s.file("launch/workflow",
        \\[workflow]
        \\name = "labels"
        \\version = "1"
        \\
        \\[[rules]]
        \\name = "s1__ALIGN"
        \\output = ["s1.txt"]
        \\shell = "true"
        \\memory = "1M"
        \\
        \\[[rules]]
        \\name = "s2__ALIGN"
        \\output = ["s2.txt"]
        \\shell = "true"
        \\memory = "1M"
        \\
        \\[[rules]]
        \\name = "merge_all"
        \\input = ["s1.txt", "s2.txt"]
        \\output = ["all.txt"]
        \\shell = "true"
        \\memory = "1M"
        \\step = "MERGE"
        \\category = "report"
        \\tool = "coreutils"
        \\
    );
    _ = try s.file("launch/launch.json", try std.fmt.allocPrint(a, "{{\"workdir\":\"{s}\",\"max_threads\":4,\"max_memory_mib\":1024}}", .{s.path}));
    _ = try s.file("launch/summary.json",
        \\{"status":"completed","elapsed_s":3.0,"selected":3,"counts":{"completed":3}}
    );
    _ = try s.file("launch/events.jsonl",
        \\{"time":"2026-01-01T00:00:00.000Z","event":"launch_started","selected":3,"max_threads":4,"max_memory_mib":1024,"rules":["s1__ALIGN","s2__ALIGN","merge_all"]}
        \\
    );
    _ = try s.file("launch/attempts/s1__ALIGN/001/record.json",
        \\{"rule":"s1__ALIGN","attempt":1,"status":"completed","wall_s":2.0,"cpu_s":2.0,"started":"2026-01-01T00:00:00.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
    _ = try s.file("launch/attempts/s2__ALIGN/001/record.json",
        \\{"rule":"s2__ALIGN","attempt":1,"status":"completed","wall_s":2.0,"cpu_s":2.0,"started":"2026-01-01T00:00:00.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
    _ = try s.file("launch/attempts/merge_all/001/record.json",
        \\{"rule":"merge_all","attempt":1,"status":"completed","wall_s":1.0,"cpu_s":1.0,"started":"2026-01-01T00:00:02.000Z","request":{"threads":1,"memory_mib":64},"queue":{"waited_s":0,"reasons":[]}}
    );
}

test "[unit] - [report]: the bottleneck report adds up time per category and per sample" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try labelsLaunch(&s, a);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.report.writeBottlenecks(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, "launch" }), null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\ntime per category (the latest run of every rule)\n") != null);
    const category = lineStarting(out.written(), "  report ") orelse return error.TestUnexpectedResult;
    var tokens = std.mem.tokenizeScalar(u8, category, ' ');
    try testing.expectEqualStrings("report", tokens.next().?);
    try testing.expectEqualStrings("1", tokens.next().?);
    try testing.expectEqualStrings("1", tokens.next().?);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\nsamples (the latest run of every rule)") != null);
    const sample = lineStarting(out.written(), "  s1 ") orelse return error.TestUnexpectedResult;
    var sample_tokens = std.mem.tokenizeScalar(u8, sample, ' ');
    try testing.expectEqualStrings("s1", sample_tokens.next().?);
    try testing.expectEqualStrings("1", sample_tokens.next().?);
    try testing.expectEqualStrings("1", sample_tokens.next().?);
    try testing.expect(std.mem.indexOf(u8, sample, "ALIGN ") != null);
}

test "[unit] - [report]: the html page draws samples by step, with a column for each step" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try labelsLaunch(&s, a);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.html.write(testing.allocator, a, &out.writer, try std.fs.path.join(a, &.{ s.path, "launch" }), null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Samples by step") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<td class=\"row\">s1</td>") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), ">MERGE</th>") != null);
}

test "[regression] - [report]: a launch whose start line selects none of the rules that ran still draws its page" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try chainLaunch(&s, a, "l", 1);
    const dir = try std.fs.path.join(a, &.{ s.path, "l" });
    const events = try std.fs.path.join(a, &.{ dir, "events.jsonl" });
    const bytes = try workz.sys.readFile(a, events, 1 << 20);
    const cut = try std.mem.replaceOwned(u8, a, bytes, "\"rules\":[\"p1\",\"p2\",\"join\"]", "\"rules\":[]");
    try testing.expect(!std.mem.eql(u8, bytes, cut));
    try workz.sys.writeFile(testing.allocator, events, cut);
    var page: std.Io.Writer.Allocating = .init(testing.allocator);
    defer page.deinit();
    var unread: std.ArrayList([]const u8) = .empty;
    try workz.html.write(testing.allocator, a, &page.writer, dir, &unread);
    try testing.expect(std.mem.indexOf(u8, page.written(), "</html>") != null);
}
