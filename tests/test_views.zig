//! Unit tests of the views of a launch: the event tracker, the interactive
//! view and the summary.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const workflow = workz.workflow;
const sys = workz.sys;
const helpers = @import("helpers.zig");
const Scratch = helpers.Scratch;
const loadText = helpers.loadText;
const head = helpers.head;

test "event times parse back to the epoch nanoseconds they were written from" {
    const ns: i128 = 1_792_782_446_812_000_000;
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try sys.formatTime(&w, ns);
    try testing.expectEqualStrings("2026-10-23T19:07:26.812Z", w.buffered());
    try testing.expectEqual(@as(?i128, ns), workz.tracker.parseTime(w.buffered()));
    try testing.expectEqual(@as(?i128, 0), workz.tracker.parseTime("1970-01-01T00:00:00.000Z"));
    try testing.expectEqual(@as(?i128, null), workz.tracker.parseTime("garbage"));
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
    const cut = ev_rules.len - 30;
    _ = try s.file("events.jsonl", ev_start ++ ev_rules[0..cut]);
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    try testing.expect(try t.update());
    try testing.expectEqual(@as(u32, 3), t.selected);
    try testing.expectEqual(@as(usize, 3), t.rules.items.len);
    try testing.expectEqual(workz.tracker.Status.running, t.rules.items[2].status);
    try testing.expect(!try t.update());
    _ = try s.file("events.jsonl", ev_start ++ ev_rules);
    try testing.expect(try t.update());
    try testing.expectEqual(workz.tracker.Status.failed, t.rules.items[2].status);
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
    const fewer = [_]usize{ 4, 0 };
    ui.settle(&fewer, 2);
    try testing.expectEqual(@as(?usize, 0), ui.selected);
    ui.key(.{ .char = 'q' }, &fewer, 2);
    try testing.expect(ui.quit);
}

test "[regression] - [watch]: S then R act on the same rule after its row moves" {
    const tui = workz.tui;
    var ui: tui.Ui = .{};
    const running = [_]usize{ 0, 1 };
    ui.settle(&running, 10);
    try testing.expectEqual(@as(?usize, 0), ui.selected);

    ui.key(.{ .char = 'S' }, &running, 10);
    try testing.expectEqualStrings("stop", ui.action.?.cmd);
    try testing.expectEqual(@as(?usize, 0), ui.action.?.rule);
    const after = [_]usize{ 1, 0 };
    ui.settle(&after, 10);
    ui.key(.{ .char = 'R' }, &after, 10);

    try testing.expectEqualStrings("retry", ui.action.?.cmd);
    try testing.expectEqual(@as(?usize, 0), ui.action.?.rule);
}

test "[unit] - [watch]: a frame fits the terminal width, shortens long names in the middle and lists running rules first" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("events.jsonl", ev_start ++ ev_rules);
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    var ui: workz.tui.Ui = .{};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const now = workz.tracker.parseTime("2026-01-01T00:00:05.000Z").?;
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 40, 10, now, false);
    var lines = std.mem.splitSequence(u8, out.written(), "\r\n");
    var n: usize = 0;
    var order: [3]usize = undefined;
    var found: usize = 0;
    while (lines.next()) |line| : (n += 1) {
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
        for ([_][]const u8{ "align...name", "merge", "trim" }, 0..) |name, k| if (std.mem.indexOf(u8, line, name) != null) {
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
    try testing.expect(std.mem.indexOf(u8, out.written(), "!!!!") != null);
}

test "the watch lists every selected rule and searches and sorts them" {
    var s = try Scratch.init();
    defer s.deinit();
    const ev = "{\"v\":1,\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"selected\":3,\"rules\":[\"zeta\",\"alpha_1\",\"alpha_2\"]}\n" ++
        "{\"v\":1,\"time\":\"2026-01-01T00:00:01.000Z\",\"event\":\"task_started\",\"rule\":\"alpha_2\",\"attempt\":1,\"directory\":\"\"}\n";
    _ = try s.file("events.jsonl", ev);
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    try testing.expectEqual(@as(usize, 3), t.rules.items.len);
    try testing.expectEqual(workz.tracker.Status.pending, t.rules.items[0].status);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tui = workz.tui;
    const now = workz.tracker.parseTime("2026-01-01T00:00:05.000Z").?;
    try testing.expectEqualSlices(usize, &.{ 2, 0, 1 }, try tui.visible(arena.allocator(), &t, .all, .status, "", now));
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, try tui.visible(arena.allocator(), &t, .all, .name, "", now));
    try testing.expectEqualSlices(usize, &.{ 2, 1 }, try tui.visible(arena.allocator(), &t, .all, .status, "alpha", now));

    var ui: tui.Ui = .{};
    const rows = [_]usize{ 2, 0, 1 };
    ui.key(.{ .char = '/' }, &rows, 10);
    for ("alp") |c| ui.key(.{ .char = c }, &rows, 10);
    ui.key(.{ .char = 127 }, &rows, 10);
    ui.key(.enter, &rows, 10);
    try testing.expectEqualStrings("al", ui.queryText());
    try testing.expect(!ui.typing);
    ui.key(.{ .char = 's' }, &rows, 10);
    try testing.expectEqual(tui.Sort.elapsed, ui.sort);
    ui.key(.down, &rows, 10);
    ui.key(.{ .char = 'S' }, &rows, 10);
    try testing.expectEqualStrings("stop", ui.action.?.cmd);
    try testing.expectEqual(@as(?usize, 2), ui.action.?.rule);
    ui.key(.{ .char = 'i' }, &rows, 10);
    try testing.expectEqual(tui.Mode.details, ui.mode);
}

fn visibleColumns(line: []const u8) usize {
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
    return cols;
}

test "[unit] - [watch]: without color a frame has no SGR sequences and draws bars with characters" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("events.jsonl", ev_start ++ ev_rules);
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    var ui: workz.tui.Ui = .{};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const now = workz.tracker.parseTime("2026-01-01T00:00:05.000Z").?;
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 120, 20, now, false);
    const frame = out.written();
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, frame, i, 0x1b)) |at| : (i = at + 1) {
        var j = at + 2;
        while (j < frame.len and (frame[j] < 0x40 or frame[j] > 0x7e)) j += 1;
        try testing.expect(frame[j] != 'm');
    }
    try testing.expect(std.mem.indexOf(u8, frame, " progress  [") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "!") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "1 failed") != null);
}

test "[unit] - [watch]: with color a frame keeps its width and shows sampled memory against the request" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("events.jsonl", ev_start ++ ev_rules);
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    const r = &t.rules.items[0];
    r.memory_mib = 1536;
    r.threads = 3;
    r.live_memory = 202 << 20;
    r.live_cores = 2.9;
    var ui: workz.tui.Ui = .{ .color = true };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const now = workz.tracker.parseTime("2026-01-01T00:00:05.000Z").?;
    for ([_]usize{ 50, 80, 120, 200 }) |width| {
        out.clearRetainingCapacity();
        try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, width, 20, now, false);
        var lines = std.mem.splitSequence(u8, out.written(), "\r\n");
        while (lines.next()) |line| try testing.expect(visibleColumns(line) <= width);
        if (width >= 120) {
            try testing.expect(std.mem.indexOf(u8, out.written(), "202M/1.5G") != null);
            try testing.expect(std.mem.indexOf(u8, out.written(), "2.9/3") != null);
        }
    }
}

test "[unit] - [watch]: X cancels the launch only when pressed again within three seconds" {
    const tui = workz.tui;
    var ui: tui.Ui = .{};
    const rows = [_]usize{0};
    ui.clock_ns = 100 * std.time.ns_per_s;
    ui.key(.{ .char = 'X' }, &rows, 5);
    try testing.expectEqual(@as(?tui.Action, null), ui.action);
    try testing.expect(std.mem.indexOf(u8, ui.message[0..ui.message_len], "again") != null);
    ui.clock_ns += 4 * std.time.ns_per_s;
    ui.key(.{ .char = 'X' }, &rows, 5);
    try testing.expectEqual(@as(?tui.Action, null), ui.action);
    ui.clock_ns += std.time.ns_per_s;
    ui.key(.{ .char = 'X' }, &rows, 5);
    try testing.expectEqualStrings("cancel", ui.action.?.cmd);
}

test "[unit] - [watch]: ? shows the keys and returns to the view it was opened from" {
    const tui = workz.tui;
    var ui: tui.Ui = .{ .mode = .timeline };
    const rows = [_]usize{0};
    ui.key(.{ .char = '?' }, &rows, 5);
    try testing.expectEqual(tui.Mode.help, ui.mode);
    ui.key(.{ .char = 'j' }, &rows, 5);
    try testing.expectEqual(tui.Mode.help, ui.mode);
    ui.key(.{ .char = 'q' }, &rows, 5);
    try testing.expectEqual(tui.Mode.timeline, ui.mode);
    try testing.expect(!ui.quit);
}

test "[unit] - [watch]: the selection follows the top row until a key moves it" {
    const tui = workz.tui;
    var ui: tui.Ui = .{};
    ui.settle(&.{ 3, 1, 2 }, 5);
    try testing.expectEqual(@as(?usize, 3), ui.selected);
    ui.settle(&.{ 1, 2, 3 }, 5);
    try testing.expectEqual(@as(?usize, 1), ui.selected);
    ui.key(.down, &.{ 1, 2, 3 }, 5);
    try testing.expectEqual(@as(?usize, 2), ui.selected);
    ui.settle(&.{ 2, 3, 1 }, 5);
    try testing.expectEqual(@as(?usize, 2), ui.selected);
    ui.settle(&.{ 3, 1, 2 }, 5);
    try testing.expectEqual(@as(?usize, 2), ui.selected);
}

test "[unit] - [run]: the text view of a launch whose engine died says it did not finish and shows nothing running" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("events.jsonl", ev_start ++ ev_rules);
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.monitor.render(testing.allocator, &out.writer, &t, 0, false);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "unfinished: its engine ended without recording its end") != null);
    try testing.expect(std.mem.indexOf(u8, text, "running for") == null);
    try testing.expect(std.mem.indexOf(u8, text, "RUNNING") == null);
}

fn summaryLaunch(s: *Scratch, events: []const u8, summary: ?[]const u8) ![]const u8 {
    const launch = try s.dir("launch");
    _ = try s.file("launch/events.jsonl", events);
    if (summary) |text| _ = try s.file("launch/summary.json", text);
    const wf = try s.file("launch/workflow", helpers.head ++
        "[[rules]]\nname = \"S1__trim\"\noutput = [\"t1\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"S2__trim\"\noutput = [\"t2\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"S1__align\"\ninput = [\"t1\"]\noutput = [\"a1\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"S2__align\"\ninput = [\"t2\"]\noutput = [\"a2\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"merge\"\ninput = [\"a1\", \"a2\"]\noutput = [\"m\"]\nshell = \"true\"\nmemory = \"1M\"\n");
    _ = wf;
    var buf: [512]u8 = undefined;
    _ = try s.file("launch/launch.json", try std.fmt.bufPrint(&buf, "{{\"workdir\":\"{s}\",\"workflow\":\"{s}/workflow.toml\"}}", .{ s.path, s.path }));
    return launch;
}

fn event(comptime at: []const u8, comptime body: []const u8) *const [41 + at.len + body.len:0]u8 {
    return "{\"v\":1,\"time\":\"2026-01-01T00:00:" ++ at ++ ".000Z\"," ++ body ++ "}\n";
}

const summary_events = event("00", "\"event\":\"launch_started\",\"selected\":5,\"rules\":[\"S1__trim\",\"S2__trim\",\"S1__align\",\"S2__align\",\"merge\"]") ++
    event("01", "\"event\":\"task_started\",\"rule\":\"S1__trim\",\"attempt\":1,\"directory\":\"\"") ++
    event("02", "\"event\":\"task_finished\",\"rule\":\"S1__trim\",\"attempt\":1,\"status\":\"completed\"") ++
    event("01", "\"event\":\"task_reused\",\"rule\":\"S2__trim\"") ++
    event("02", "\"event\":\"task_started\",\"rule\":\"S1__align\",\"attempt\":1,\"directory\":\"\"") ++
    event("05", "\"event\":\"task_finished\",\"rule\":\"S1__align\",\"attempt\":1,\"status\":\"completed\"") ++
    event("02", "\"event\":\"task_started\",\"rule\":\"S2__align\",\"attempt\":1,\"directory\":\"\"") ++
    event("03", "\"event\":\"task_finished\",\"rule\":\"S2__align\",\"attempt\":1,\"status\":\"failed\",\"reason\":\"exited with status 2: index is incomplete\"") ++
    event("03", "\"event\":\"task_blocked\",\"rule\":\"merge\"");

test "[unit] - [summary]: an ended launch shows its counts, a sample matrix, its failure, what it blocked and what to type next" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try summaryLaunch(&s, summary_events ++ event("06", "\"event\":\"launch_finished\",\"status\":\"failed\""), "{\"status\":\"failed\",\"elapsed_s\":6.0}");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.summary.write(testing.allocator, &out.writer, launch, .{});
    try testing.expectEqualStrings(
        \\          failed       3 of 5 rules done in 6.0 s: 1 reused, 1 failed, 1 blocked
        \\          samples      trim  align  merge
        \\          S1           +     +
        \\          S2           +     x
        \\          all                       .
        \\                       + done   x failed   . blocked or stopped
        \\          failed       align  S2  exited with status 2: index is incomplete
        \\          blocked      merge      after align/S2 failed
        \\          slowest      align/S1 3.0 s   trim/S1 1.0 s
        \\
    , out.written()[0..std.mem.indexOf(u8, out.written(), "          records").?]);
    try testing.expect(std.mem.indexOf(u8, out.written(), "          next         kanit logs align/S2 ") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "run again; 3 rules are reused\n") != null);
}

test "[unit] - [summary]: a launch whose engine ended without recording its end reads as unfinished" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try summaryLaunch(&s, summary_events, null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.summary.write(testing.allocator, &out.writer, launch, .{});
    const text = out.written();
    try testing.expect(std.mem.startsWith(u8, text, "          unfinished   3 of 5 rules done in 5.0 s: 1 reused, 1 failed, 1 blocked\n"));
    try testing.expect(std.mem.indexOf(u8, text, "          next         kanit logs align/S2") != null);
}

test "[failure] - [run]: status --history keeps a row for a launch whose summary cannot be read" {
    var s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ ".workz", ".workz/launches", ".workz/launches/A", ".workz/launches/B", ".workz/launches/C" }) |d| _ = try s.dir(d);
    _ = try s.file(".workz/launches/A/summary.json", "{\"status\":\"completed\",\"elapsed_s\":1,\"counts\":{\"completed\":1}}");
    _ = try s.file(".workz/launches/B/summary.json", "[1, 2]");
    _ = try s.file(".workz/launches/C/summary.json", "{not json");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.monitor.history(testing.allocator, &out.writer, s.path, 10, false);
    try testing.expectEqualStrings(
        \\LAUNCH                         STATUS         ELAPSED  COMPLETED  REUSED  FAILED  BLOCKED  CANCELLED
        \\C                              unreadable
        \\B                              unreadable
        \\A                              completed        1.0 s          1       0       0        0          0
        \\
    , out.written());
    var json: std.Io.Writer.Allocating = .init(testing.allocator);
    defer json.deinit();
    try workz.monitor.history(testing.allocator, &json.writer, s.path, 1, true);
    try testing.expectEqualStrings("[{\"launch\":\"C\",\"status\":\"unreadable\",\"elapsed_s\":null,\"completed\":0,\"reused\":0,\"failed\":0,\"blocked\":0,\"cancelled\":0,\"error\":null}]\n", json.written());
}

test "[edge] - [run]: program output becomes valid UTF-8 and cuts never split a character" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ok \u{FFFD} done \u{FFFD}\u{FFFD}", try sys.utf8Text(a, "ok \xff done \xe2\x82"));
    const valid = "caf\u{e9}";
    try testing.expect((try sys.utf8Text(a, valid)).ptr == valid.ptr);
    try testing.expectEqualStrings("caf", sys.utf8Prefix("caf\u{e9}", 4));
    try testing.expectEqualStrings("caf\u{e9}", sys.utf8Prefix("caf\u{e9}", 5));
    const name = "\u{e9}" ** 30;
    const short = workz.html.middle(a, name, 20);
    try testing.expect(std.unicode.utf8ValidateSlice(short));
    try testing.expectEqual(@as(usize, 20), try std.unicode.utf8CountCodepoints(short));
}

test "[failure] - [run]: the text view of a running launch whose events cannot be read shows an unknown start, not 1970" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("events.jsonl", "garbage\n");
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.monitor.render(testing.allocator, &out.writer, &t, 0, true);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "running, started at an unknown time") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1 line of events.jsonl could not be read and is left out") != null);
}

test "[unit] - [watch]: a launch whose engine died reads as unfinished in the interactive view, ended at its last event" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.file("events.jsonl", ev_start ++ ev_rules);
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();

    t.markUnfinished();

    try testing.expect(t.finished);
    try testing.expectEqual(workz.tracker.parseTime("2026-01-01T00:00:04.000Z").?, t.finished_ns);
    var ui: workz.tui.Ui = .{};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const hour_later = workz.tracker.parseTime("2026-01-01T01:00:00.000Z").?;
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 100, 12, hour_later, false);
    try testing.expect(std.mem.indexOf(u8, out.written(), "unfinished") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "1h") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "running") == null);
    try testing.expectEqual(workz.tracker.Status.cancelled, t.rules.items[0].status);
}

test "[edge] - [watch]: an Alt key is no key of the view, and two escapes are two" {
    const tui = workz.tui;
    var used: usize = 0;
    try testing.expectEqual(@as(?tui.Key, null), tui.decode("\x1bq", &used));
    try testing.expectEqual(@as(usize, 2), used);
    try testing.expectEqual(tui.Key.escape, tui.decode("\x1b\x1b", &used).?);
    try testing.expectEqual(@as(usize, 1), used);
}

test "[failure] - [watch]: the interactive view of a launch with no readable event shows an unknown start, not 1970" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try s.dir("launch");
    _ = try s.file("launch/events.jsonl", "garbage\n");
    var t = try workz.tracker.Tracker.init(testing.allocator, launch);
    defer t.deinit();
    _ = try t.update();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const now = workz.tracker.parseTime("2026-01-01T00:00:05.000Z").?;
    for ([_]workz.tui.Mode{ .table, .timeline }) |mode| {
        var ui: workz.tui.Ui = .{ .mode = mode };
        out.clearRetainingCapacity();
        try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 100, 12, now, false);
        try testing.expect(std.mem.indexOf(u8, out.written(), "-:--") != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), "49") == null);
    }
}

test "[failure] - [watch]: C1 control characters in a log line or a reason reach the terminal as spaces" {
    var s = try Scratch.init();
    defer s.deinit();
    const log = try s.file("stderr.log", "red \xc2\x9b31mtext\xc2\xa0end \xe2\x82\xac\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const lines = workz.monitor.lastLines(testing.allocator, arena.allocator(), log, 1, 200);

    try testing.expectEqualStrings("red  31mtext\xc2\xa0end \xe2\x82\xac", lines[0]);

    _ = try s.file("events.jsonl", ev_start ++ "{\"v\":1,\"time\":\"2026-01-01T00:00:01.000Z\",\"event\":\"task_finished\",\"rule\":\"r\",\"attempt\":1,\"status\":\"failed\",\"reason\":\"bad \\u009b31m news\"}\n");
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    var ui: workz.tui.Ui = .{ .mode = .details };
    ui.selected = 0;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 100, 14, workz.tracker.parseTime("2026-01-01T00:00:05.000Z").?, false);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\xc2\x9b") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "31m news") != null);
}

test "[unit] - [views]: graph --why prints one path with the file each rule reads" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, head ++
        "[[rules]]\nname = \"write\"\noutput = [\"d/x.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
        "[[rules]]\nname = \"read\"\ninput = [\"d\"]\noutput = [\"n.txt\"]\nshell = \"true\"\nmemory = \"1M\"\n", &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);
    const path = try workz.views.whyPath(a, &wf, &g, mask, "write", "read");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.views.writeWhy(&out.writer, &wf, &g, path);
    try testing.expectEqualStrings("write\n  -> read  (reads d)\n", out.written());
}

const service_graph = head ++
    "[shared.ix]\npath = \"idx\"\ncontainer = \"img\"\ncommand = \"cat idx/data\"\nmemory = \"64M\"\n\n" ++
    "[[rules]]\nname = \"build\"\noutput = [\"idx/data\"]\nshell = \"true\"\nmemory = \"1M\"\n" ++
    "[[rules]]\nname = \"use\"\ninput = [\"idx\"]\noutput = [\"u.txt\"]\ncontainer = \"img\"\nshell = \"true\"\nmemory = \"1M\"\n[rules.resources]\nshared = [\"ix\"]\n";

test "[unit] - [views]: graph --users prints a shared input with the rule that loads it and the rules that use it" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, service_graph, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);
    const v = try workz.views.build(a, &wf, &g, mask, .{ .users = "ix" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.views.writeText(a, &out.writer, v);
    try testing.expect(std.mem.indexOf(u8, out.written(), "shared ix  service, 64 MiB held once, idx\n  loaded from build\n  used by use\n") != null);
}

test "[unit] - [views]: graph --layer all as JSON has the edge kinds of a shared input and its files, and no others" {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    var wf = try loadText(&s, service_graph, &problem);
    defer wf.deinit();
    var g = try workz.graph.build(testing.allocator, &wf, &problem);
    defer g.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mask = try a.alloc(bool, wf.rules.len);
    @memset(mask, true);
    const v = try workz.views.build(a, &wf, &g, mask, .{ .layer = .all });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.views.writeJson(&out.writer, v);
    const want = [_][]const u8{ "consumes", "joins", "loads", "produces", "within" };
    inline for (std.meta.fields(workz.views.EdgeKind)) |f| {
        var expected = false;
        for (want) |k| expected = expected or std.mem.eql(u8, k, f.name);
        try testing.expectEqual(expected, std.mem.indexOf(u8, out.written(), "\"kind\":\"" ++ f.name ++ "\"") != null);
    }
}

fn lineWith(text: []const u8, part: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, text, "\r\n");
    while (lines.next()) |line| if (std.mem.indexOf(u8, line, part) != null) return line;
    return null;
}

fn startedLaunch(s: *Scratch, a: std.mem.Allocator) !void {
    const dir = try s.dir("slow");
    _ = try s.file("slow/stderr.log", "to-stderr\n");
    _ = try s.file("slow/stdout.log", "to-stdout\n");
    _ = try s.file("events.jsonl", try std.fmt.allocPrint(a, "{{\"v\":1,\"time\":\"2026-01-01T00:00:00.000Z\",\"event\":\"launch_started\",\"selected\":2,\"max_threads\":4,\"max_memory_mib\":2048,\"rules\":[\"slow\",\"quick\"]}}\n" ++
        "{{\"v\":1,\"time\":\"2026-01-01T00:00:01.000Z\",\"event\":\"task_started\",\"rule\":\"slow\",\"attempt\":1,\"directory\":\"{s}\",\"threads\":1,\"memory_mib\":64}}\n", .{dir}));
}

test "[unit] - [watch]: enter follows the selected attempt's stderr, and o switches the follow to stdout" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try startedLaunch(&s, arena.allocator());
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    const rows = [_]usize{ 0, 1 };
    var ui: workz.tui.Ui = .{};
    ui.settle(&rows, 10);
    ui.key(.enter, &rows, 10);
    const now = workz.tracker.parseTime("2026-01-01T00:00:05.000Z").?;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 80, 10, now, true);
    try testing.expect(std.mem.indexOf(u8, out.written(), " attempt 1  running  stderr ") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "to-stderr") != null);
    ui.key(.{ .char = 'o' }, &rows, 10);
    out.clearRetainingCapacity();
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 80, 10, now, true);
    try testing.expect(std.mem.indexOf(u8, out.written(), " attempt 1  running  stdout ") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "to-stdout") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "to-stderr") == null);
}

test "[unit] - [watch]: t shows the timeline, with a running rule's bar running up to now" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try startedLaunch(&s, arena.allocator());
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    const rows = [_]usize{ 0, 1 };
    var ui: workz.tui.Ui = .{};
    ui.settle(&rows, 10);
    ui.key(.{ .char = 't' }, &rows, 10);
    const now = workz.tracker.parseTime("2026-01-01T00:00:05.000Z").?;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 80, 10, now, true);
    const row = lineWith(out.written(), "slow") orelse return error.TestUnexpectedResult;
    const name_at = std.mem.indexOf(u8, row, "slow").? + "slow".len;
    try testing.expect(std.mem.startsWith(u8, std.mem.trimStart(u8, row[name_at..], " "), ">>>"));
}

test "[unit] - [watch]: i shows the selected rule's request and its live memory" {
    var s = try Scratch.init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try startedLaunch(&s, arena.allocator());
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
    defer t.deinit();
    _ = try t.update();
    t.rules.items[0].live_memory = 202 << 20;
    const rows = [_]usize{ 0, 1 };
    var ui: workz.tui.Ui = .{};
    ui.settle(&rows, 10);
    ui.key(.{ .char = 'i' }, &rows, 10);
    const now = workz.tracker.parseTime("2026-01-01T00:00:05.000Z").?;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.tui.draw(testing.allocator, &out.writer, &t, &ui, 80, 12, now, true);
    const request = lineWith(out.written(), "request") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, request, "1 threads, 64M") != null);
    const memory = lineWith(out.written(), "  memory  ") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, memory, "202M now") != null);
}
