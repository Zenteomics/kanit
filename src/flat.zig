//! One line of JSON read without building a tree, for the event logs that
//! `status`, `watch` and the reports read whole: a flat object whose values
//! are strings without escapes, numbers, booleans, null, or arrays of
//! those. `read` accepts only lines that `std.json` reads the same way, and
//! declines any other line, which its caller then reads with `std.json`: a
//! value that is an object or a nested array, a string with an escape or a
//! control character, text that is not UTF-8, a repeated key or anything
//! that is not JSON. A number is classified by `std.json`'s own rule, so a
//! field reads the same either way.
const std = @import("std");
const Value = std.json.Value;

pub const max_fields = 40;

pub const Flat = struct {
    keys: [max_fields][]const u8 = undefined,
    values: [max_fields]Slot = undefined,
    len: usize = 0,

    const Slot = union(enum) { string: []const u8, number: []const u8, boolean: bool, null, array: []const u8 };

    fn find(self: *const Flat, key: []const u8) ?Slot {
        for (self.keys[0..self.len], self.values[0..self.len]) |k, v| if (std.mem.eql(u8, k, key)) return v;
        return null;
    }

    /// The scalar field `key` as `std.json` gives it; an array reads as
    /// absent here and through `strings`.
    pub fn get(self: *const Flat, key: []const u8) ?Value {
        return switch (self.find(key) orelse return null) {
            .string => |s| .{ .string = s },
            .number => |s| Value.parseFromNumberSlice(s),
            .boolean => |b| .{ .bool = b },
            .null => .null,
            .array => null,
        };
    }

    /// Whether `key` holds an array.
    pub fn isArray(self: *const Flat, key: []const u8) bool {
        const v = self.find(key) orelse return false;
        return v == .array;
    }

    /// The strings of the array `key`, skipping its other items, as a walk
    /// of `std.json`'s array of it would.
    pub fn strings(self: *const Flat, key: []const u8) Strings {
        const v = self.find(key) orelse return .{ .text = "" };
        return switch (v) {
            .array => |text| .{ .text = text[1 .. text.len - 1] },
            else => .{ .text = "" },
        };
    }
};

/// The string items of an array `read` accepted.
pub const Strings = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(self: *Strings) ?[]const u8 {
        while (true) {
            var i = space(self.text, self.at);
            if (i >= self.text.len) return null;
            if (self.text[i] == ',') i = space(self.text, i + 1);
            if (i >= self.text.len) return null;
            if (self.text[i] == '"') {
                const s = string(self.text, &i) orelse return null;
                self.at = i;
                return s;
            }
            while (i < self.text.len and self.text[i] != ',') i += 1;
            self.at = i;
        }
    }
};

/// Reads the line into `f` as a flat object, in place, since a `Flat` is
/// too large to copy per line; false when `std.json` must read it.
pub fn read(f: *Flat, line: []const u8) bool {
    f.len = 0;
    var i = space(line, 0);
    if (i >= line.len or line[i] != '{') return false;
    i = space(line, i + 1);
    if (i < line.len and line[i] == '}') return space(line, i + 1) == line.len;
    while (true) {
        if (f.len == max_fields) return false;
        const key = string(line, &i) orelse return false;
        for (f.keys[0..f.len]) |k| if (std.mem.eql(u8, k, key)) return false;
        i = space(line, i);
        if (i >= line.len or line[i] != ':') return false;
        i = space(line, i + 1);
        if (i >= line.len) return false;
        f.values[f.len] = switch (line[i]) {
            '"' => .{ .string = string(line, &i) orelse return false },
            '-', '0'...'9' => .{ .number = number(line, &i) orelse return false },
            't' => if (word(line, &i, "true")) .{ .boolean = true } else return false,
            'f' => if (word(line, &i, "false")) .{ .boolean = false } else return false,
            'n' => if (word(line, &i, "null")) .null else return false,
            '[' => .{ .array = array(line, &i) orelse return false },
            else => return false,
        };
        f.keys[f.len] = key;
        f.len += 1;
        i = space(line, i);
        if (i >= line.len) return false;
        switch (line[i]) {
            ',' => i = space(line, i + 1),
            '}' => return space(line, i + 1) == line.len,
            else => return false,
        }
    }
}

fn space(line: []const u8, from: usize) usize {
    var i = from;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\n' or line[i] == '\r')) i += 1;
    return i;
}

/// A string at `i.*`, without its quotes, when it has no escape and no
/// control character and is UTF-8; `i.*` moves past it.
fn string(line: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= line.len or line[i.*] != '"') return null;
    const start = i.* + 1;
    var j = start;
    var high: u8 = 0;
    while (j < line.len) : (j += 1) switch (line[j]) {
        '"' => {
            const text = line[start..j];
            if (high >= 0x80 and !std.unicode.utf8ValidateSlice(text)) return null;
            i.* = j + 1;
            return text;
        },
        '\\', 0...0x1f => return null,
        else => |c| high |= c,
    };
    return null;
}

/// A number at `i.*` as JSON writes one: `-`, an integer part without a
/// leading zero, a fraction and an exponent; `i.*` moves past it.
fn number(line: []const u8, i: *usize) ?[]const u8 {
    const start = i.*;
    var j = start;
    if (j < line.len and line[j] == '-') j += 1;
    if (j >= line.len) return null;
    if (line[j] == '0') {
        j += 1;
    } else if (line[j] >= '1' and line[j] <= '9') {
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
    } else return null;
    if (j < line.len and line[j] == '.') {
        j += 1;
        const digits = j;
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        if (j == digits) return null;
    }
    if (j < line.len and (line[j] == 'e' or line[j] == 'E')) {
        j += 1;
        if (j < line.len and (line[j] == '+' or line[j] == '-')) j += 1;
        const digits = j;
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        if (j == digits) return null;
    }
    i.* = j;
    return line[start..j];
}

/// An array at `i.*` whose items are strings without escapes, numbers,
/// booleans or null, with its brackets; `i.*` moves past it.
fn array(line: []const u8, i: *usize) ?[]const u8 {
    const start = i.*;
    var j = space(line, start + 1);
    if (j < line.len and line[j] == ']') {
        i.* = j + 1;
        return line[start .. j + 1];
    }
    while (true) {
        if (j >= line.len) return null;
        switch (line[j]) {
            '"' => _ = string(line, &j) orelse return null,
            '-', '0'...'9' => _ = number(line, &j) orelse return null,
            't' => if (!word(line, &j, "true")) return null,
            'f' => if (!word(line, &j, "false")) return null,
            'n' => if (!word(line, &j, "null")) return null,
            else => return null,
        }
        j = space(line, j);
        if (j >= line.len) return null;
        switch (line[j]) {
            ',' => j = space(line, j + 1),
            ']' => {
                i.* = j + 1;
                return line[start .. j + 1];
            },
            else => return null,
        }
    }
}

fn word(line: []const u8, i: *usize, text: []const u8) bool {
    if (!std.mem.startsWith(u8, line[i.*..], text)) return false;
    i.* += text.len;
    return true;
}
