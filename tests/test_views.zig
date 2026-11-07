//! Unit tests of the views of a launch: the event tracker, the interactive
//! view and the summary.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const sys = workz.sys;
const helpers = @import("helpers.zig");
const Scratch = helpers.Scratch;

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
    // The last line is cut in the middle, as while the engine writes it.
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
    try testing.expectEqual(@as(?usize, 0), ui.selected);
    ui.key(.{ .char = 'q' }, &fewer, 2);
    try testing.expect(ui.quit);
}

test "[regression] - [watch]: S then R act on the same rule after its row moves" {
    const tui = workz.tui;
    var ui: tui.Ui = .{};
    // Rules a (0) and b (1) run; the top row is selected without a key.
    const running = [_]usize{ 0, 1 };
    ui.settle(&running, 10);
    try testing.expectEqual(@as(?usize, 0), ui.selected);

    ui.key(.{ .char = 'S' }, &running, 10);
    try testing.expectEqualStrings("stop", ui.action.?.cmd);
    try testing.expectEqual(@as(?usize, 0), ui.action.?.rule);
    // a stops and sorts below b, which keeps running.
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
    // trim ran from 2 s to 4 s of a 5 s launch and failed.
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
    // Running first, then pending in launch order.
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

/// Columns of `line` outside escape sequences.
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
    // Only cursor, clear and erase sequences: no color (SGR ends in 'm').
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, frame, i, 0x1b)) |at| : (i = at + 1) {
        var j = at + 2;
        while (j < frame.len and (frame[j] < 0x40 or frame[j] > 0x7e)) j += 1;
        try testing.expect(frame[j] != 'm');
    }
    // The progress bar: one of three rules done is none here; one failed.
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
    // Rows reorder as rules finish: the untouched selection stays on top.
    ui.settle(&.{ 1, 2, 3 }, 5);
    try testing.expectEqual(@as(?usize, 1), ui.selected);
    ui.key(.down, &.{ 1, 2, 3 }, 5);
    try testing.expectEqual(@as(?usize, 2), ui.selected);
    // Once moved, it stays on its rule.
    ui.settle(&.{ 2, 3, 1 }, 5);
    try testing.expectEqual(@as(?usize, 2), ui.selected);
    ui.settle(&.{ 3, 1, 2 }, 5);
    try testing.expectEqual(@as(?usize, 2), ui.selected);
}

test "[unit] - [run]: the readable summary names each failure with its last error line and the next command" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try s.dir("launch");
    _ = try s.dir("launch/attempts");
    _ = try s.dir("launch/attempts/align_S1");
    _ = try s.dir("launch/attempts/align_S1/001");
    _ = try s.dir("launch/attempts/prep");
    _ = try s.dir("launch/attempts/prep/001");
    _ = try s.file("launch/summary.json",
        \\{"status":"failed","elapsed_s":3.4,"selected":4,"counts":{"completed":2,"reused":0,"failed":1,"blocked":1,"cancelled":0,"not_started":0}}
    );
    _ = try s.file("launch/attempts/prep/001/record.json",
        \\{"rule":"prep","attempt":1,"status":"completed","reason":"","wall_s":1.0}
    );
    _ = try s.file("launch/attempts/align_S1/001/record.json",
        \\{"rule":"align_S1","attempt":1,"status":"failed","reason":"exited with status 3","wall_s":1.2}
    );
    _ = try s.file("launch/attempts/align_S1/001/stderr.log", "reading index\nalign: reference index is truncated\n\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.monitor.writeSummary(testing.allocator, arena.allocator(), &out.writer, launch, false);
    const text = out.written();
    try testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
    try testing.expect(std.mem.startsWith(u8, text, " failed    after 3.4 s: 2 completed, 0 reused, 1 failed, 1 blocked\n"));
    try testing.expect(std.mem.indexOf(u8, text, "\n failures  align_S1  exited with status 3\n                     | align: reference index is truncated\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n next      kanit logs align_S1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "prep") == null);
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

test "[unit] - [run]: the readable summary names the rules a failure blocked" {
    var s = try Scratch.init();
    defer s.deinit();
    const launch = try s.dir("launch");
    _ = try s.file("launch/summary.json",
        \\{"status":"failed","elapsed_s":1,"selected":3,"counts":{"completed":1,"reused":0,"failed":1,"blocked":2},"failures":[{"rule":"align","status":"failed","reason":"exited with status 1"},{"rule":"merge","status":"blocked","reason":"blocked"},{"rule":"plot","status":"blocked","reason":"blocked"}]}
    );
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try workz.monitor.writeSummary(testing.allocator, arena.allocator(), &out.writer, launch, false);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\n blocked   merge, plot\n") != null);
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
    try workz.monitor.history(testing.allocator, &out.writer, s.path, 10);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "\nC                               unreadable\nB                               unreadable\nA                               completed") != null);
}

test "[edge] - [run]: program output becomes valid UTF-8 and cuts never split a character" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each byte that starts no valid sequence is replaced on its own.
    try testing.expectEqualStrings("ok \u{FFFD} done \u{FFFD}\u{FFFD}", try sys.utf8Text(a, "ok \xff done \xe2\x82"));
    const valid = "caf\u{e9}";
    try testing.expect((try sys.utf8Text(a, valid)).ptr == valid.ptr);
    try testing.expectEqualStrings("caf", sys.utf8Prefix("caf\u{e9}", 4));
    try testing.expectEqualStrings("caf\u{e9}", sys.utf8Prefix("caf\u{e9}", 5));
    // 30 characters of two bytes each, shown as 20: 9, "...", 8.
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
    _ = try s.file("events.jsonl", "garbage\n");
    var t = try workz.tracker.Tracker.init(testing.allocator, s.path);
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
