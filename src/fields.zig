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

/// A number field, whole or not.
pub fn float(v: Value, key: []const u8) ?f64 {
    return number(get(v, key));
}

/// A number: an integer, a float, or a number too long for either that the
/// parser kept as text.
pub fn number(x: ?Value) ?f64 {
    return switch (x orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}
