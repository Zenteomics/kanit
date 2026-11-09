//! Fields of parsed JSON records: events, attempt records, summaries. A
//! missing field, or one of another type, reads as null, so a record that
//! an earlier version wrote still reads.
const std = @import("std");
const Value = std.json.Value;

pub fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn str(v: Value, key: []const u8) ?[]const u8 {
    return strOf(get(v, key));
}

pub fn int(v: Value, key: []const u8) ?i64 {
    return intOf(get(v, key));
}

pub fn whole(comptime T: type, v: Value, key: []const u8) ?T {
    return std.math.cast(T, int(v, key) orelse return null);
}

pub fn float(v: Value, key: []const u8) ?f64 {
    return number(get(v, key));
}

/// The rules of `str`, `int` and `newer` for a field already found, so a
/// record read without a JSON tree reads its fields the same way.
pub fn strOf(x: ?Value) ?[]const u8 {
    const y = x orelse return null;
    return if (y == .string) y.string else null;
}

pub fn intOf(x: ?Value) ?i64 {
    const y = x orelse return null;
    return if (y == .integer and y.integer >= 0) y.integer else null;
}

pub fn newerOf(x: ?Value, known: i64) bool {
    const y = x orelse return false;
    return y != .integer or y.integer > known;
}

pub fn number(x: ?Value) ?f64 {
    const f: f64 = switch (x orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |g| g,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(f)) f else null;
}

pub fn newer(v: Value, known: i64) bool {
    return newerOf(get(v, "v"), known);
}
