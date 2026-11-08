//! Unit tests of the run log's text: lines and their columns, quoted output,
//! hints, the header, the footer and the heartbeat, failure details and
//! resource use, and the local time the lines carry.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const log = workz.log;
const clock = workz.clock;

const plain: log.Style = .{ .widths = .{ .step = 6, .sample = 3 } };

fn render(comptime f: anytype, args: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    _ = try @call(.auto, f, .{&out.writer} ++ args);
    return out.toOwnedSlice();
}

fn expectText(expected: []const u8, comptime f: anytype, args: anytype) !void {
    const got = try render(f, args);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "[unit] - [log]: a line puts time, status word, step, sample and details in fixed columns" {
    try expectText("14:03:21  completed  trim    S1   1.0 s\n", log.line, .{ plain, "14:03:21", .completed, log.Who{ .step = "trim", .sample = "S1" }, "1.0 s" });
    try expectText("14:03:23  failed     align   S2   exit 2 after 0.5 s\n", log.line, .{ plain, "14:03:23", .failed, log.Who{ .step = "align", .sample = "S2" }, "exit 2 after 0.5 s" });
    try expectText("14:03:26  step       count        2 of 3 completed\n", log.line, .{ plain, "14:03:26", .step, log.Who{ .step = "count" }, "2 of 3 completed" });
    try expectText("14:03:25  sample             S1   all 3 steps completed\n", log.line, .{ plain, "14:03:25", .sample, log.Who{ .sample = "S1" }, "all 3 steps completed" });
}

test "[unit] - [log]: a line ends at its last value, and without samples there is no sample column" {
    try expectText("14:03:21  blocked    matrix\n", log.line, .{ plain, "14:03:21", .blocked, log.Who{ .step = "matrix" }, "" });
    const no_samples: log.Style = .{ .widths = .{ .step = 6, .sample = 0 } };
    try expectText("14:03:21  completed  matrix  0.3 s\n", log.line, .{ no_samples, "14:03:21", .completed, log.Who{ .step = "matrix" }, "0.3 s" });
    try expectText("14:03:21  completed  a_much_longer_name  0.3 s\n", log.line, .{ no_samples, "14:03:21", .completed, log.Who{ .step = "a_much_longer_name" }, "0.3 s" });
}

test "[unit] - [log]: color marks the time and the status word only" {
    const colored: log.Style = .{ .color = true, .widths = .{ .step = 4, .sample = 0 } };
    try expectText("\x1b[2m14:03:21\x1b[0m  \x1b[31;1mfailed   \x1b[0m  trim  exit 1 after 0.0 s\n", log.line, .{ colored, "14:03:21", .failed, log.Who{ .step = "trim" }, "exit 1 after 0.0 s" });
}

test "[unit] - [log]: quoted output and hints start at the detail column, and a terminal cuts quotes to its width" {
    try expectText("                                  | STAR: genome index is incomplete\n", log.quote, .{ plain, "STAR: genome index is incomplete" });
    var narrow = plain;
    narrow.cols = 50;
    try expectText("                                  | STAR: genome...\n", log.quote, .{ narrow, "STAR: genome index is incomplete" });
    var marked = plain;
    marked.marks = &log.unicode;
    try expectText("                                  │ ok\n", log.quote, .{ marked, "ok" });
    try expectText("                                  kanit logs align/S2   .workz/latest/attempts/S2__align/001/\n", log.hint, .{ plain, "kanit logs align/S2", ".workz/latest/attempts/S2__align/001/" });
}

test "[unit] - [log]: the header shows the launch's shape, budget, tools with their versions and records in the status-word column" {
    const steps = [_]log.StepLine{
        .{ .name = "trim", .rules = 3 },
        .{ .name = "align", .rules = 3 },
        .{ .name = "count", .rules = 3 },
        .{ .name = "matrix", .rules = 1 },
    };
    const tools = [_]log.ToolLine{
        .{ .name = "fastp", .version = "1.4.0", .steps = "trim" },
        .{ .name = "STAR", .version = "2.7.11b", .steps = "align" },
        .{ .name = "awk", .steps = "count, matrix" },
    };
    try expectText(
        \\kanit 0.7.0   rnaseq-demo   launch 20261108T142320.410-8c1d
        \\          plan       10 rules in 4 steps for 3 samples
        \\          budget     4 threads, 2.0 GiB, 4 jobs, isolated
        \\          steps      trim 3   align 3   count 3   matrix 1
        \\          tools      fastp   1.4.0     trim
        \\                     STAR    2.7.11b   align
        \\                     awk     -         count, matrix
        \\          records    .workz/latest/   log launch.log   page report.html
        \\
    , log.header, .{ plain, log.Header{ .version = "0.7.0", .workflow = "rnaseq-demo", .launch = "20261108T142320.410-8c1d", .rules = 10, .samples = 3, .steps = &steps, .tools = &tools, .budget = "4 threads, 2.0 GiB, 4 jobs", .isolated = true, .records = ".workz/latest/", .page = true } });
}

test "[unit] - [log]: a tool column follows the sample, and lines without a tool keep the details in line" {
    const with_tools: log.Style = .{ .widths = .{ .step = 5, .sample = 2, .tool = 5 } };
    try expectText("03:11:44  completed  align  S1  STAR     0.5 s\n", log.line, .{ with_tools, "03:11:44", .completed, log.Who{ .step = "align", .sample = "S1", .tool = "STAR" }, "  0.5 s" });
    try expectText("03:11:48  completed  count  S2           12 ms\n", log.line, .{ with_tools, "03:11:48", .completed, log.Who{ .step = "count", .sample = "S2" }, "  12 ms" });
    try expectText("03:11:40  tool       trim       fastp  1.4.0\n", log.line, .{ with_tools, "03:11:40", .tool, log.Who{ .step = "trim", .tool = "fastp" }, "1.4.0" });
}

test "[unit] - [log]: a header of rules that are their own steps leaves the steps out and wraps a long step list" {
    const solo = [_]log.StepLine{ .{ .name = "a", .rules = 1 }, .{ .name = "b", .rules = 1 } };
    try expectText(
        \\kanit 0.7.0   w   launch L
        \\          plan       2 rules
        \\          budget     1 threads, 1.0 GiB, 1 jobs, no isolation
        \\          records    .workz/latest/   log launch.log
        \\
    , log.header, .{ plain, log.Header{ .version = "0.7.0", .workflow = "w", .launch = "L", .rules = 2, .samples = 0, .steps = &solo, .budget = "1 threads, 1.0 GiB, 1 jobs", .isolated = false, .records = ".workz/latest/", .page = false } });
    var many: [40]log.StepLine = undefined;
    var name_buf: [40][8]u8 = undefined;
    for (&many, 0..) |*st, k| st.* = .{ .name = std.fmt.bufPrint(&name_buf[k], "step{d:0>2}", .{k}) catch unreachable, .rules = 20 };
    var narrow = plain;
    narrow.cols = 60;
    const got = try render(log.header, .{ narrow, log.Header{ .version = "0.7.0", .workflow = "w", .launch = "L", .rules = 800, .samples = 20, .steps = &many, .budget = "b", .isolated = true, .records = "r", .page = false } });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "                     step03 20   step04 20") != null);
    try testing.expect(std.mem.indexOf(u8, got, "more\n") != null);
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |l| try testing.expect(workz.names.columns(l) <= 60);
}

const progress_steps = [_]log.StepProgress{
    .{ .name = "trim", .selected = 3, .done = 3, .failed = 0, .running = 0, .ended = true },
    .{ .name = "align", .selected = 3, .done = 1, .failed = 1, .running = 1, .ended = false },
    .{ .name = "count", .selected = 3, .done = 1, .failed = 0, .running = 1, .ended = false },
    .{ .name = "matrix", .selected = 1, .done = 0, .failed = 0, .blocked = 1, .running = 0, .ended = true },
};

const progress: log.Progress = .{
    .selected = 10,
    .done = 6,
    .running = 2,
    .failed = 1,
    .blocked = 2,
    .cancelled = 0,
    .elapsed_s = 221,
    .steps = &progress_steps,
    .steps_ok = 1,
    .grouped = true,
    .running_list = &.{ .{ .word = "align/S1", .seconds = 2 }, .{ .word = "count/S3", .seconds = 0.3 } },
};

test "[unit] - [log]: the footer shows the bar and counts, each step's progress and the running rules" {
    var wide = plain;
    wide.cols = 120;
    try expectText("##############----------  6 of 10 rules   2 running   1 failed   2 blocked   3m 41s\n" ++
        "trim + 3/3   align x 1/3, 1 running   count 1/3, 1 running   matrix 0/1, 1 blocked\n" ++
        "running   align/S1 2.0 s   count/S3 0.3 s", log.footer, .{ wide, progress });
}

test "[unit] - [log]: a narrow footer folds the steps that ended into a count and counts the rest it cannot show" {
    var narrow = plain;
    narrow.cols = 50;
    const got = try render(log.footer, .{ narrow, progress });
    defer testing.allocator.free(got);
    var it = std.mem.splitScalar(u8, got, '\n');
    _ = it.next();
    try testing.expectEqualStrings("1 step +   align x 1/3, 1 running   +2", it.next().?);
}

test "[unit] - [log]: the heartbeat carries the footer's progress as log lines" {
    try expectText("14:10:00  progress   6 of 10 rules   2 running   1 failed   2 blocked   3m 41s\n" ++
        "                     trim + 3/3   align x 1/3, 1 running   count 1/3, 1 running   matrix 0/1, 1 blocked\n" ++
        "                     running   align/S1 2.0 s   count/S3 0.3 s\n", log.heartbeat, .{ plain, "14:10:00", progress });
}

test "[unit] - [log]: a failure's details name the reason in few words and say what to quote" {
    const cases = [_]struct { end: workz.schedule.End, text: []const u8, block: log.Block }{
        .{ .end = .{ .exit_code = 2 }, .text = "exit 2 after 0.5 s", .block = .stderr },
        .{ .end = .{ .exit_code = 127 }, .text = "exit 127: command not found after 0.5 s", .block = .stderr },
        .{ .end = .{ .exit_code = 125, .container = true }, .text = "exit 125: the container engine failed, or the command exited 125 after 0.5 s", .block = .stderr },
        .{ .end = .{ .oom_kills = 1, .memory_mib = 64, .exit_code = 137 }, .text = "out of memory at its 64 MiB", .block = .memory },
        .{ .end = .{ .timed_out = true, .timeout_s = 7200, .signal = 15 }, .text = "timed out at 2h 00m", .block = .stderr },
        .{ .end = .{ .signal = 11 }, .text = "killed by SIGSEGV after 0.5 s", .block = .stderr },
        .{ .end = .{ .signal = 40 }, .text = "killed by signal 40 after 0.5 s", .block = .stderr },
        .{ .end = .{ .lost_service = "its shared service genome stopped" }, .text = "its shared service genome stopped", .block = .none },
        .{ .end = .{ .exit_code = 0 }, .text = "", .block = .none },
    };
    for (cases) |c| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectEqual(c.block, try log.ending(&out.writer, c.end, 0.5));
        try testing.expectEqualStrings(c.text, out.written());
    }
}

test "[unit] - [log]: resource use fills fixed columns, so time, memory and CPU line up, and leaves out what was not measured" {
    try expectText(" 1.0 s   mem   12 MiB of   32 MiB   cpu  0.9 of 1", log.usage, .{log.Use{ .wall_s = 1, .memory_mib = 12, .request_mib = 32, .cpu_s = 0.9, .threads = 1 }});
    try expectText("2m 05s   mem  1.0 GiB of  2.4 GiB   cpu 12.5 of 16", log.usage, .{log.Use{ .wall_s = 125, .memory_mib = 1024, .request_mib = 2500, .cpu_s = 1562.5, .threads = 16 }});
    try expectText(" 20 ms", log.usage, .{log.Use{ .wall_s = 0.02, .request_mib = 32, .cpu_s = 0.01, .threads = 1 }});
    try expectText("2m 05s                              cpu  3.5 of 4   after 2 attempts", log.usage, .{log.Use{ .wall_s = 125, .request_mib = 32, .cpu_s = 437.5, .threads = 4, .attempts = 2 }});
    try expectText(" 1 thread      32 MiB", log.request, .{ 1, 32 });
    try expectText("16 threads    2.4 GiB", log.request, .{ 16, 2500 });
}

test "[unit] - [log]: a version is the number a tool prints, or its line up to that number" {
    try testing.expectEqualStrings("1.4.0", log.versionText("fastp", "fastp 1.4.0"));
    try testing.expectEqualStrings("2.7.11b", log.versionText("star", "2.7.11b"));
    try testing.expectEqualStrings("5.3.2", log.versionText("awk", "GNU Awk 5.3.2, API 4.0, PMA Avon 8-g1"));
    try testing.expectEqualStrings("9.10", log.versionText("sort", "sort (GNU coreutils) 9.10"));
    try testing.expectEqualStrings("3.14.0", log.versionText("python", "Python 3.14.0"));
    try testing.expectEqualStrings("samtools 1.21", log.versionText("", "samtools 1.21"));
    try testing.expectEqualStrings("release seven", log.versionText("tool", "release seven"));
}

test "[unit] - [log]: counts of thousands are grouped, and a UTF-8 locale chooses the Unicode marks" {
    try expectText("20,000", log.thousands, .{20000});
    try expectText("1,000,001", log.thousands, .{1000001});
    try expectText("999", log.thousands, .{999});
    try testing.expect(log.utf8Locale("en_US.UTF-8"));
    try testing.expect(log.utf8Locale("C.utf8"));
    try testing.expect(!log.utf8Locale("C"));
    try testing.expect(!log.utf8Locale("POSIX"));
}

test "[unit] - [clock]: a POSIX rule gives daylight time between its dates, also south of the equator" {
    const ny = clock.Rule.parse("EST5EDT,M3.2.0,M11.1.0").?;
    try testing.expectEqual(@as(i32, -5 * 3600), ny.offset(1768478400));
    try testing.expectEqual(@as(i32, -5 * 3600), ny.offset(1772953199));
    try testing.expectEqual(@as(i32, -4 * 3600), ny.offset(1772953200));
    try testing.expectEqual(@as(i32, -4 * 3600), ny.offset(1793512799));
    try testing.expectEqual(@as(i32, -5 * 3600), ny.offset(1793512800));
    const syd = clock.Rule.parse("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    try testing.expectEqual(@as(i32, 11 * 3600), syd.offset(1775318399));
    try testing.expectEqual(@as(i32, 10 * 3600), syd.offset(1775318400));
    try testing.expectEqual(@as(i32, 10 * 3600), syd.offset(1791043199));
    try testing.expectEqual(@as(i32, 11 * 3600), syd.offset(1791043200));
}

test "[unit] - [clock]: a rule without daylight time, a quoted name and minutes are read" {
    try testing.expectEqual(@as(i32, -7 * 3600), clock.Rule.parse("MST7").?.offset(1783000000));
    try testing.expectEqual(@as(i32, 0), clock.Rule.parse("UTC0").?.offset(1783000000));
    try testing.expectEqual(@as(i32, 3 * 3600 + 1800), clock.Rule.parse("<+0330>-3:30").?.offset(1783000000));
    try testing.expect(clock.Rule.parse("America/Vancouver") == null);
    try testing.expect(clock.Rule.parse("EST5EDT,M3.2.0") == null);
    try testing.expect(clock.Rule.parse("EST5EDT,M13.2.0,M11.1.0") == null);
}

test "[unit] - [clock]: an empty TZ is UTC, and the civil time of an instant is its date and time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const z = clock.Zone.load(testing.allocator, arena.allocator(), "");
    try testing.expectEqual(@as(i32, 0), z.offset(1783000000));
    const c = clock.Civil.of(951782400 + 3 * 3600 + 4 * 60 + 5);
    try testing.expectEqual(clock.Civil{ .year = 2000, .month = 2, .day = 29, .hour = 3, .minute = 4, .second = 5 }, c);
    try testing.expectEqual(clock.Civil{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 }, clock.Civil.of(-1));
    const ny = clock.Zone.load(testing.allocator, arena.allocator(), "EST5EDT,M3.2.0,M11.1.0");
    const local = ny.local(@as(i128, 1772953200) * std.time.ns_per_s);
    try testing.expectEqual(@as(u8, 3), local.hour);
}

test "[unit] - [clock]: a TZif zone uses its transitions, and its footer rule after the last one" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    const a = testing.allocator;
    const be = struct {
        fn int(list: *std.ArrayList(u8), al: std.mem.Allocator, comptime T: type, v: T) !void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .big);
            try list.appendSlice(al, &b);
        }
    };
    for (0..2) |version| {
        try bytes.appendSlice(a, "TZif2");
        try bytes.appendNTimes(a, 0, 15);
        for ([_]u32{ 0, 0, 0, 1, 2, 8 }) |n| try be.int(&bytes, a, u32, n);
        if (version == 0) try be.int(&bytes, a, i32, 1000) else try be.int(&bytes, a, i64, 1000);
        try bytes.append(a, 1);
        try be.int(&bytes, a, i32, -3600);
        try bytes.appendSlice(a, &.{ 0, 0 });
        try be.int(&bytes, a, i32, 7200);
        try bytes.appendSlice(a, &.{ 0, 4 });
        try bytes.appendSlice(a, "ONE\x00TWO\x00");
    }
    try bytes.appendSlice(a, "\nUTC0\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const z = try clock.Zone.fromBytes(arena.allocator(), bytes.items);
    try testing.expectEqual(@as(i32, -3600), z.offset(999));
    try testing.expectEqual(@as(i32, 7200), z.offset(1000));
    try testing.expectEqual(@as(i32, 0), z.offset(1001));
}
