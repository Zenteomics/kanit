//! Unit tests of the flat reader of event lines: every line it accepts,
//! `std.json` reads with the same fields, and the lines kanit writes most
//! are accepted.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const flat = workz.flat;
const Value = std.json.Value;

const written = [_][]const u8{
    "{\"v\":1,\"time\":\"2026-11-09T05:27:39.672Z\",\"event\":\"task_started\",\"rule\":\"S1__trim\",\"attempt\":1,\"pid\":1814835,\"cgroup\":\"/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/workz-1814784-18e649444831579a.scope/task-0-1\",\"directory\":\"/var/tmp/kanit-ev.V7KEu4/.workz/launches/20261109T052739.219-cd4856c7/attempts/S1__trim/001\",\"threads\":1,\"memory_mib\":128,\"waited_s\":0.000498573,\"shared\":[]}",
    "{\"v\":1,\"time\":\"2026-11-09T05:27:39.672Z\",\"event\":\"task_started\",\"rule\":\"S1__align\",\"attempt\":2,\"pid\":7,\"cgroup\":null,\"directory\":\"/w/a\",\"threads\":2,\"memory_mib\":512,\"waited_s\":3.5e-4,\"shared\":[\"genome\", \"index\"]}",
    "{\"v\":1,\"time\":\"2026-11-09T05:27:42.315Z\",\"event\":\"task_finished\",\"rule\":\"S3__trim\",\"attempt\":1,\"status\":\"completed\",\"wall_s\":2.639699122,\"cpu_s\":2.602489,\"maxrss_kib\":85420,\"memory_peak\":86753280}",
    "{\"v\":1,\"time\":\"2026-11-09T05:27:47.015Z\",\"event\":\"task_finished\",\"rule\":\"S4__align\",\"attempt\":1,\"status\":\"failed\",\"reason\":\"exited with status 2: aligner: genome index is incomplete: missing SA file\",\"exit_code\":2,\"signal\":null,\"wall_s\":0.001539119}",
    "{\"v\":1,\"time\":\"2026-11-09T05:27:39.676Z\",\"event\":\"task_waiting\",\"rule\":\"S5__trim\",\"reason\":\"threads\",\"threads\":1,\"memory_mib\":128}",
    "{\"v\":1,\"time\":\"2026-11-09T05:27:44.663Z\",\"event\":\"sample\",\"running\":3,\"ready\":3,\"threads_reserved\":4,\"memory_reserved_mib\":768,\"shared_reserved_mib\":0,\"memory_current\":200052736,\"cpu_cores_used\":3.7237000636758495}",
    "{\"v\":1,\"time\":\"2026-11-09T05:27:47.015Z\",\"event\":\"task_blocked\",\"rule\":\"S4__count\"}",
    "{\"v\":1,\"time\":\"2026-11-09T05:28:01.303Z\",\"event\":\"task_retry\",\"rule\":\"S2__count\",\"next_attempt\":2}",
    "{\"v\":1,\"time\":\"2026-11-09T05:28:06.661Z\",\"event\":\"launch_ending\"}",
    "{\"v\":1,\"time\":\"2026-11-09T05:27:39.662Z\",\"event\":\"launch_started\",\"launch\":\"20261109T052739.219-cd4856c7\",\"selected\":3,\"rules\":[\"S1__trim\",\"S1__align\",\"merge\"],\"max_threads\":4,\"max_memory_mib\":2048,\"jobs\":4,\"isolation\":true}",
};

const declined = [_][]const u8{
    "{\"v\":1,\"event\":\"launch_finished\",\"counts\":{\"completed\":16}}",
    "{\"v\":1,\"event\":\"task_finished\",\"reason\":\"exited: \\\"quoted\\\"\"}",
    "{\"v\":1,\"event\":\"x\",\"list\":[[1]]}",
    "{\"v\":1,\"event\":\"x\",\"v\":2}",
    "{\"v\":1,\"event\":\"x\",\"bad\":01}",
    "{\"v\":1,\"event\":\"x\",\"bad\":1.}",
    "{\"v\":1,\"event\":\"x\",\"bad\":\"\xff\"}",
    "{\"v\":1,\"event\":\"x\",\"bad\":\"tab\there\"}",
    "{\"v\":1,\"event\":\"x\"} trailing",
    "{\"v\":1,\"event\":\"x\",}",
    "[1,2]",
    "",
    "not json",
};

fn same(x: ?Value, y: ?Value) bool {
    const a = x orelse return y == null;
    const b = y orelse return false;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| @as(u64, @bitCast(v)) == @as(u64, @bitCast(b.float)),
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        else => false,
    };
}

/// Fails when `read` accepts a line that `std.json` reads differently.
fn agree(line: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: flat.Flat = undefined;
    if (!flat.read(&f, line)) return false;
    const tree = std.json.parseFromSliceLeaky(Value, arena.allocator(), line, .{}) catch return error.TreeRejectsAcceptedLine;
    if (tree != .object) return error.AcceptedNonObject;
    if (tree.object.count() != f.len) return error.FieldCountDiffers;
    for (f.keys[0..f.len]) |key| {
        const t = tree.object.get(key) orelse return error.MissingField;
        if (t == .array) {
            if (!f.isArray(key)) return error.ArrayDiffers;
            var items = f.strings(key);
            for (t.array.items) |item| {
                if (item != .string) continue;
                const got = items.next() orelse return error.ArrayItemsDiffer;
                if (!std.mem.eql(u8, got, item.string)) return error.ArrayItemsDiffer;
            }
            if (items.next() != null) return error.ArrayItemsDiffer;
        } else if (!same(f.get(key), t)) return error.FieldDiffers;
    }
    return true;
}

test "[unit] - [events]: the lines kanit writes most are read flat, with the fields std.json reads" {
    for (written) |line| try testing.expect(try agree(line));
}

test "[unit] - [events]: objects, nested arrays, escapes, repeated keys and lines that are not JSON go to std.json" {
    for (declined) |line| {
        var f: flat.Flat = undefined;
        try testing.expect(!flat.read(&f, line));
        try testing.expect(!try agree(line));
    }
}

test "[unit] - [events]: numbers keep std.json's kinds: integers, floats, large integers and negative zero" {
    const line = "{\"a\":0,\"b\":-3,\"c\":2.5,\"d\":1e3,\"e\":-0,\"f\":99999999999999999999,\"g\":1E-2,\"h\":true,\"i\":false,\"j\":null}";
    try testing.expect(try agree(line));
    var f: flat.Flat = undefined;
    try testing.expect(flat.read(&f, line));
    try testing.expectEqual(@as(i64, -3), f.get("b").?.integer);
    try testing.expect(f.get("e").? == .float);
    try testing.expect(f.get("f").? == .number_string);
}

test "[edge] - [events]: surrogates, overlong forms and code points past U+10FFFF read as std.json reads them" {
    const texts = [_][]const u8{ "\xed\xa0\x80", "\xed\xbf\xbf", "\xc0\xaf", "\xe0\x80\xaf", "\xf4\x90\x80\x80", "\xf8\x88\x80\x80\x80", "\xef\xbf\xbe", "\xf0\x9f\x98\x80", "\x7f", "\xe2\x80\xa8" };
    var buf: [64]u8 = undefined;
    for (texts) |t| {
        const line = try std.fmt.bufPrint(&buf, "{{\"v\":1,\"s\":\"{s}\",\"a\":[\"{s}\"]}}", .{ t, t });
        _ = try agree(line);
    }
}

test "[edge] - [events]: no change to a line makes the flat reader read it differently from std.json" {
    var prng = std.Random.DefaultPrng.init(0x6b616e6974);
    const rand = prng.random();
    const bytes = "\"\\{}[],:0123456789eE.-+ tfnrlua\x00\x1f\x7f\xc3\xa9\xff";
    var buf: [1024]u8 = undefined;
    var accepted: usize = 0;
    for (0..50_000) |_| {
        const base = written[rand.uintLessThan(usize, written.len)];
        var len: usize = @min(base.len, buf.len - 4);
        @memcpy(buf[0..len], base[0..len]);
        for (0..1 + rand.uintLessThan(usize, 3)) |_| {
            const at = rand.uintLessThan(usize, len + 1);
            switch (rand.uintLessThan(u8, 4)) {
                0 => if (at < len) {
                    buf[at] = bytes[rand.uintLessThan(usize, bytes.len)];
                },
                1 => if (at < len) {
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
                2 => if (len < buf.len) {
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = bytes[rand.uintLessThan(usize, bytes.len)];
                    len += 1;
                },
                else => len = at,
            }
        }
        if (try agree(buf[0..len])) accepted += 1;
    }
    try testing.expect(accepted > 1000);
}
