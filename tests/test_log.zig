//! Unit tests of the run log's text: lines and their columns, quoted output,
//! hints, the header, the footer and the heartbeat, failure details and
//! resource use, and the local time the lines carry.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const log = workz.log;
const clock = workz.clock;

const table = log.Table.of(10, .{ .step = 5, .sample = 2, .tool = 5 }, &.{ 2500, 512, 256 }, 2);
const plain: log.Style = .{ .table = table };

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

test "[unit] - [log]: the column header names every column at the width its values take" {
    try expectText("TIME      RULES  STATUS  TOOL   STEP   SAMPLE     TOOK               MEMORY      CPU  NOTE\n", log.columnHeader, .{plain});
}

test "[unit] - [log]: a rule's event is one row of the table: a status tag, its tool, step and sample, and figures right-aligned under their headers" {
    try expectText("03:18:55   0/10  START   fastp  trim   S1                      - /  2.4 GiB    - / 1\n", log.line, .{ plain, "03:18:55", 0, .started, log.Who{ .step = "trim", .sample = "S1", .tool = "fastp" }, log.Figures{ .request_mib = 2500, .threads = 1 }, "" });
    try expectText("03:18:59   1/10  DONE    fastp  trim   S1        3.9 s   1.0 GiB /  2.4 GiB  0.9 / 1\n", log.line, .{ plain, "03:18:59", 1, .completed, log.Who{ .step = "trim", .sample = "S1", .tool = "fastp" }, log.Figures{ .took_s = 3.9, .used_mib = 1024, .request_mib = 2500, .cores = 0.9, .threads = 1 }, "" });
    try expectText("03:19:00   3/10  DONE    awk    count  S1        12 ms         - /  256 MiB    - / 1\n", log.line, .{ plain, "03:19:00", 3, .completed, log.Who{ .step = "count", .sample = "S1", .tool = "awk" }, log.Figures{ .took_s = 0.012, .request_mib = 256, .threads = 1 }, "" });
    try expectText("03:19:04   4/10  FAIL    star   align  S2        0.5 s   261 MiB /  512 MiB  0.8 / 2  exit 2\n", log.line, .{ plain, "03:19:04", 4, .failed, log.Who{ .step = "align", .sample = "S2", .tool = "star" }, log.Figures{ .took_s = 0.5, .used_mib = 261, .request_mib = 512, .cores = 0.8, .threads = 2 }, "exit 2" });
}

test "[unit] - [log]: a blocked rule leaves the figures blank and keeps the note in its column" {
    try expectText("03:19:04   5/10  BLOCK          count  S2                                             after align/S2 failed\n", log.line, .{ plain, "03:19:04", 5, .blocked, log.Who{ .step = "count", .sample = "S2" }, log.Figures{}, "after align/S2 failed" });
    try expectText("03:19:04   6/10  STOP    star   align  S1                                             stopped by an interrupt\n", log.line, .{ plain, "03:19:04", 6, .cancelled, log.Who{ .step = "align", .sample = "S1", .tool = "star" }, log.Figures{}, "stopped by an interrupt" });
}

test "[unit] - [log]: shared inputs, control commands and warnings are rows tagged INFO and WARN" {
    try expectText("03:19:03   0/10  INFO           genome                          - /  1.0 GiB           starting the service\n", log.line, .{ stepped, "03:19:03", 0, .shared, log.Who{ .step = "genome" }, log.Figures{ .request_mib = 1024 }, "starting the service" });
    try expectText("03:19:04   0/10  INFO           genome            0.3 s                                ready\n", log.line, .{ stepped, "03:19:04", 0, .shared, log.Who{ .step = "genome" }, log.Figures{ .took_s = 0.3 }, "ready" });
    try expectText("03:19:05   3/10  INFO    star   align   S2                                             control stop: stopping\n", log.line, .{ stepped, "03:19:05", 3, .control, log.Who{ .step = "align", .sample = "S2", .tool = "star" }, log.Figures{}, "control stop: stopping" });
    try expectText("03:19:06   3/10  WARN                                                                  cannot write report.html\n", log.line, .{ stepped, "03:19:06", 3, .warning, log.Who{}, log.Figures{}, "cannot write report.html" });
}

test "[unit] - [log]: without samples, tools or figures the table drops their columns" {
    var t = log.Table.of(4, .{ .step = 9, .sample = 0 }, &.{64}, 1);
    try expectText("TIME      RULES  STATUS  STEP          TOOK             MEMORY      CPU  NOTE\n", log.columnHeader, .{log.Style{ .table = t }});
    try expectText("03:37:59    1/4  FAIL    exits         4 ms        - /  64 MiB    - / 1  exit 2\n", log.line, .{ log.Style{ .table = t }, "03:37:59", 1, .failed, log.Who{ .step = "exits" }, log.Figures{ .took_s = 0.004, .request_mib = 64, .threads = 1 }, "exit 2" });
    t.figures = false;
    try expectText("03:37:59    1/4  FAIL    exits         4 ms  exit 2\n", log.line, .{ log.Style{ .table = t }, "03:37:59", 1, .failed, log.Who{ .step = "exits" }, log.Figures{ .took_s = 0.004, .request_mib = 64, .threads = 1 }, "exit 2" });
}

test "[unit] - [log]: a name longer than its column is cut with a mark, and the columns after it stay in place" {
    const t = log.Table.of(4, .{ .step = 5, .sample = 6, .tool = 4 }, &.{64}, 1);
    var nofig = t;
    nofig.figures = false;
    const long: log.Who = .{ .step = "dedupe_umi", .sample = "patient_07", .tool = "picard" };
    try expectText("03:37:59    1/4  DONE    sort  trim   S1         4 ms\n", log.line, .{ log.Style{ .table = nofig }, "03:37:59", 1, .completed, log.Who{ .step = "trim", .sample = "S1", .tool = "sort" }, log.Figures{ .took_s = 0.004 }, "" });
    try expectText("03:37:59    2/4  DONE    pic~  dedu~  patie~     4 ms\n", log.line, .{ log.Style{ .table = nofig }, "03:37:59", 2, .completed, long, log.Figures{ .took_s = 0.004 }, "" });
    try expectText("03:37:59    2/4  DONE    pic…  dedu…  patie…     4 ms\n", log.line, .{ log.Style{ .table = nofig, .marks = &log.unicode }, "03:37:59", 2, .completed, long, log.Figures{ .took_s = 0.004 }, "" });
}

test "[unit] - [log]: ten minutes or more, a peak of 1000 MiB to 99.9 GiB and cores past the threads keep the note in its column" {
    const t = log.Table.of(2, .{ .step = 4, .sample = 0 }, &.{2500}, 1).unbounded();
    const s: log.Style = .{ .table = t };
    const small = try render(log.line, .{ s, "05:00:00", 1, .completed, log.Who{ .step = "a" }, log.Figures{ .took_s = 0.004, .used_mib = 12, .request_mib = 64, .cores = 0.5, .threads = 1 }, "note" });
    defer testing.allocator.free(small);
    const wide = try render(log.line, .{ s, "05:12:05", 2, .completed, log.Who{ .step = "b" }, log.Figures{ .took_s = 36000 + 725, .used_mib = 1010, .request_mib = 2500, .cores = 12.3, .threads = 1 }, "note" });
    defer testing.allocator.free(wide);
    try testing.expect(std.mem.indexOf(u8, wide, "10h 12m") != null and std.mem.indexOf(u8, wide, "1010 MiB") != null and std.mem.indexOf(u8, wide, "12.3 / 1") != null);
    try testing.expectEqual(std.mem.indexOf(u8, small, "note").?, std.mem.indexOf(u8, wide, "note").?);
}

test "[unit] - [log]: a terminal narrows the name columns to fit, and cuts a row that is still too long with a mark" {
    var t = log.Table.of(2, .{ .step = 30, .sample = 20 }, &.{64}, 1);
    t.figures = false;
    const f = t.fitted(60);
    try testing.expect(f.width() + 1 <= 60);
    try testing.expect(f.step >= 8 and f.sample >= 8);
    const s: log.Style = .{ .table = f, .cols = 60 };
    const got = try render(log.line, .{ s, "05:00:00", 1, .failed, log.Who{ .step = "align_reads_with_star", .sample = "patient_07_tumor" }, log.Figures{}, "exited with status 2 after a long time of trying" });
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 59), workz.names.columns(got) - 1);
    try testing.expect(std.mem.endsWith(u8, got, "~\n"));
}

test "[unit] - [log]: wide characters take two columns and combining marks none, so names cut and pad to their column" {
    try testing.expectEqual(@as(usize, 4), workz.names.columns("患者"));
    try testing.expectEqual(@as(usize, 1), workz.names.columns("e\u{301}"));
    try testing.expectEqualStrings("患", log.cut("患者A", 3));
    var t = log.Table.of(2, .{ .step = 5, .sample = 6 }, &.{64}, 1);
    t.figures = false;
    const s: log.Style = .{ .table = t };
    const plain_row = try render(log.line, .{ s, "05:00:00", 1, .completed, log.Who{ .step = "trim", .sample = "S1" }, log.Figures{}, "note" });
    defer testing.allocator.free(plain_row);
    const wide_row = try render(log.line, .{ s, "05:00:00", 1, .completed, log.Who{ .step = "trim", .sample = "患者番号七" }, log.Figures{}, "note" });
    defer testing.allocator.free(wide_row);
    try testing.expect(std.mem.indexOf(u8, wide_row, "患者~ ") != null);
    try testing.expectEqual(workz.names.columns(plain_row), workz.names.columns(wide_row));
}

test "[unit] - [log]: a terminal under six rows keeps only the counts line in the footer" {
    var tiny = stepped;
    tiny.cols = 120;
    tiny.rows = 4;
    var lines: usize = 0;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    lines = try log.footer(&out.writer, tiny, progress);
    try testing.expectEqual(@as(usize, 1), lines);
    try testing.expect(std.mem.indexOfScalar(u8, out.written(), '\n') == null);
}

test "[unit] - [log]: a terminal cuts a hint to its width, and the header's rule counts take the room their thousands need" {
    var narrow = plain;
    narrow.cols = 50;
    const got = try render(log.hint, .{ narrow, "kanit logs align/S2", ".workz/latest/attempts/S2__align/001/" });
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 49), workz.names.columns(got) - 1);
    const steps = [_]log.StepLine{ .{ .name = "call", .rules = 12000 }, .{ .name = "merge", .rules = 1 } };
    const head = try render(log.header, .{ plain, log.Header{ .version = "0.7.0", .workflow = "w", .launch = "L", .rules = 12001, .samples = 12000, .steps = &steps, .budget = "b", .isolated = true, .records = "r", .page = false } });
    defer testing.allocator.free(head);
    try testing.expect(std.mem.endsWith(u8, head, "          STEP    RULES\n          call   12,000\n          merge       1\n"));
}

test "[unit] - [log]: color marks the time, the status tag and the tool only" {
    const t = log.Table.of(1, .{ .step = 4, .sample = 0 }, &.{64}, 1);
    var nofig = t;
    nofig.figures = false;
    try expectText("\x1b[2m14:03:21  \x1b[0m  1/1  \x1b[31;1mFAIL  \x1b[0m  trim           exit 1\n", log.line, .{ log.Style{ .color = true, .table = nofig }, "14:03:21", 1, .failed, log.Who{ .step = "trim" }, log.Figures{}, "exit 1" });
}

test "[unit] - [log]: quoted output and hints start at the name column, and a terminal cuts quotes to its width" {
    try expectText("                         | STAR: genome index is incomplete\n", log.quote, .{ plain, "STAR: genome index is incomplete" });
    var narrow = plain;
    narrow.cols = 46;
    try expectText("                         | STAR: genome inde~\n", log.quote, .{ narrow, "STAR: genome index is incomplete" });
    var marked = plain;
    marked.marks = &log.unicode;
    try expectText("                         │ ok\n", log.quote, .{ marked, "ok" });
    try expectText("                         kanit logs align/S2   .workz/latest/attempts/S2__align/001/\n", log.hint, .{ plain, "kanit logs align/S2", ".workz/latest/attempts/S2__align/001/" });
}

test "[unit] - [log]: the header shows the launch, its budget and records, then one row per step with its tool, version and rules" {
    const steps = [_]log.StepLine{
        .{ .name = "trim", .rules = 2, .tool = "fastp", .version = "1.4.0" },
        .{ .name = "index", .rules = 1, .tool = "STAR", .version = "2.7.11b" },
        .{ .name = "align", .rules = 2, .tool = "STAR", .version = "2.7.11b" },
        .{ .name = "sort", .rules = 2, .tool = "samtools", .version = "1.21" },
        .{ .name = "matrix", .rules = 1 },
    };
    try expectText(
        \\kanit 0.7.0   rnaseq   launch 20261108T101855.266-41e7e452
        \\          plan         8 rules: 5 steps for 2 samples
        \\          budget       8 threads, 16 GiB, 8 jobs, isolated
        \\          records      .workz/latest/   log launch.log   page report.html
        \\
        \\          TOOL      VERSION  STEP    RULES
        \\          fastp     1.4.0    trim        2
        \\          STAR      2.7.11b  index       1
        \\          STAR      2.7.11b  align       2
        \\          samtools  1.21     sort        2
        \\          -         -        matrix      1
        \\
    , log.header, .{ plain, log.Header{ .version = "0.7.0", .workflow = "rnaseq", .launch = "20261108T101855.266-41e7e452", .rules = 8, .samples = 2, .steps = &steps, .budget = "8 threads, 16 GiB, 8 jobs", .isolated = true, .records = ".workz/latest/", .page = true } });
}

test "[unit] - [log]: a header of rules that are their own steps without tools has no step table, and a long one is cut" {
    const solo = [_]log.StepLine{ .{ .name = "a", .rules = 1 }, .{ .name = "b", .rules = 1 } };
    try expectText(
        \\kanit 0.7.0   w   launch L
        \\          plan         2 rules
        \\          budget       1 threads, 1.0 GiB, 1 jobs, no isolation
        \\          records      .workz/latest/   log launch.log
        \\
    , log.header, .{ plain, log.Header{ .version = "0.7.0", .workflow = "w", .launch = "L", .rules = 2, .samples = 0, .steps = &solo, .budget = "1 threads, 1.0 GiB, 1 jobs", .isolated = false, .records = ".workz/latest/", .page = false } });
    var many: [50]log.StepLine = undefined;
    var name_buf: [50][8]u8 = undefined;
    for (&many, 0..) |*st, k| st.* = .{ .name = std.fmt.bufPrint(&name_buf[k], "step{d:0>2}", .{k}) catch unreachable, .rules = 20 };
    const got = try render(log.header, .{ plain, log.Header{ .version = "0.7.0", .workflow = "w", .launch = "L", .rules = 1000, .samples = 20, .steps = &many, .budget = "b", .isolated = true, .records = "r", .page = false } });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "          step39     20\n          +10 more steps; kanit plan lists them\n") != null);
}

test "[unit] - [log]: a step name of any length keeps the header and the column header whole" {
    const long = "s" ** 900;
    const steps = [_]log.StepLine{ .{ .name = long, .rules = 2, .tool = "t" }, .{ .name = "b", .rules = 1 } };
    const got = try render(log.header, .{ plain, log.Header{ .version = "0.7.0", .workflow = "w", .launch = "L", .rules = 3, .samples = 0, .steps = &steps, .budget = "b", .isolated = true, .records = "r", .page = false } });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.endsWith(u8, got, "          t     " ++ long ++ "      2\n          -     b" ++ " " ** 899 ++ "      1\n"));
    const t = log.Table.of(3, .{ .step = 900, .sample = 0 }, &.{64}, 1);
    const head = try render(log.columnHeader, .{log.Style{ .table = t }});
    defer testing.allocator.free(head);
    try testing.expectEqual(t.width() + "NOTE\n".len, head.len);
}

const progress_steps = [_]log.StepProgress{
    .{ .name = "trim", .tool = "fastp", .selected = 3, .done = 3, .failed = 0, .running = 0, .ended = true },
    .{ .name = "align", .tool = "star", .selected = 3, .done = 1, .failed = 1, .running = 1, .ended = false },
    .{ .name = "count", .tool = "awk", .selected = 3, .done = 1, .failed = 0, .running = 1, .ended = false },
    .{ .name = "matrix", .tool = "sort", .selected = 1, .done = 0, .failed = 0, .blocked = 1, .running = 0, .ended = true },
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
    .grouped = true,
    .running_list = &.{ .{ .word = "align/S1", .seconds = 2 }, .{ .word = "count/S3", .seconds = 0.3 } },
};

const stepped: log.Style = .{ .table = log.Table.of(10, .{ .step = 6, .sample = 2, .tool = 5 }, &.{ 2500, 512, 256 }, 2) };

const step_rows =
    "                         fastp  trim    ################  3/3  +\n" ++
    "                         star   align   #####-----------  1/3  x 1 failed, 1 running\n" ++
    "                         awk    count   #####-----------  1/3  1 running\n" ++
    "                         sort   matrix  ----------------  0/1  1 blocked\n";

test "[unit] - [log]: the footer is a table of the steps under the rows' tool and step columns, then the counts and the running rules" {
    var wide = stepped;
    wide.cols = 120;
    try expectText("\n" ++ step_rows ++
        "                         6 of 10 rules   2 running   1 failed   2 blocked   3m 41s   align/S1 2.0 s   +1", log.footer, .{ wide, progress });
}

test "[unit] - [log]: a short terminal folds the steps that are done into one row, and a narrow one never wraps a line" {
    var short = stepped;
    short.cols = 120;
    short.rows = 8;
    try expectText("\n" ++
        "                         star   align   #####-----------  1/3  x 1 failed, 1 running\n" ++
        "                         +3 more steps, 1 done +\n" ++
        "                         6 of 10 rules   2 running   1 failed   2 blocked   3m 41s   align/S1 2.0 s   +1", log.footer, .{ short, progress });
    var narrow = stepped;
    narrow.cols = 50;
    const got = try render(log.footer, .{ narrow, progress });
    defer testing.allocator.free(got);
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |l| try testing.expect(workz.names.columns(l) <= 49);
}

test "[unit] - [log]: the heartbeat is an INFO row with the counts, then the step table and the running rules" {
    var nofig = stepped;
    nofig.table.figures = false;
    try expectText("14:10:00   9/10  INFO                                    6 of 10 rules   2 running   1 failed   2 blocked   3m 41s\n" ++ step_rows ++
        "                         running   align/S1 2.0 s   count/S3 0.3 s\n", log.heartbeat, .{ nofig, "14:10:00", 9, progress });
}

test "[unit] - [log]: a failure's details name the reason in few words and say what to quote" {
    const cases = [_]struct { end: workz.schedule.End, text: []const u8, block: log.Block }{
        .{ .end = .{ .exit_code = 2 }, .text = "exit 2", .block = .stderr },
        .{ .end = .{ .exit_code = 127 }, .text = "exit 127: command not found", .block = .stderr },
        .{ .end = .{ .exit_code = 125, .container = true }, .text = "exit 125: the container engine failed, or the command exited 125", .block = .stderr },
        .{ .end = .{ .oom_kills = 1, .memory_mib = 64, .exit_code = 137 }, .text = "out of memory", .block = .memory },
        .{ .end = .{ .timed_out = true, .timeout_s = 7200, .signal = 15 }, .text = "timed out at 2h 00m", .block = .stderr },
        .{ .end = .{ .signal = 11 }, .text = "killed by SIGSEGV", .block = .stderr },
        .{ .end = .{ .signal = 40 }, .text = "killed by signal 40", .block = .stderr },
        .{ .end = .{ .lost_service = "its shared service genome stopped" }, .text = "its shared service genome stopped", .block = .none },
        .{ .end = .{ .exit_code = 0 }, .text = "", .block = .none },
    };
    for (cases) |c| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectEqual(c.block, try log.ending(&out.writer, c.end));
        try testing.expectEqualStrings(c.text, out.written());
    }
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
