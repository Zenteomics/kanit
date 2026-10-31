//! Fields of parsed JSON records: events, attempt records, summaries. A
//! missing field, or one of another type, reads as null, so a record that
//! an earlier version wrote still reads.
const std = @import("std");
const Value = std.json.Value;

/// The field `key` of an object.
pub fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// A string field.
pub fn str(v: Value, key: []const u8) ?[]const u8 {
    const x = get(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

/// A whole number field that is not negative.
pub fn int(v: Value, key: []const u8) ?i64 {
    const x = get(v, key) orelse return null;
    return if (x == .integer and x.integer >= 0) x.integer else null;
}

/// A whole number field that is not negative and fits `T`.
pub fn whole(comptime T: type, v: Value, key: []const u8) ?T {
    return std.math.cast(T, int(v, key) orelse return null);
}

/// A number field, whole or not.
pub fn float(v: Value, key: []const u8) ?f64 {
    return number(get(v, key));
}

/// A finite number: an integer, a float, or a number too long for either
/// that the parser kept as text. NaN and infinities read as null.
pub fn number(x: ?Value) ?f64 {
    const f: f64 = switch (x orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |g| g,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(f)) f else null;
}

/// Whether a record's format, its field `v`, is newer than `known`, so it
/// cannot be read as one this version knows. A record without `v` predates
/// the field and is not newer.
pub fn newer(v: Value, known: i64) bool {
    const x = get(v, "v") orelse return false;
    return x != .integer or x.integer > known;
}
