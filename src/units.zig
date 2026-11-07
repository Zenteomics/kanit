//! How kanit shows durations and sizes to people: one form everywhere, so a
//! figure reads the same in the terminal, the text reports and the HTML
//! page. Machine output (TSV, JSON) keeps plain numbers.
const std = @import("std");

/// A duration: `42 ms` under a tenth of a second, `48.2 s` under a minute,
/// `3m 07s` under an hour, `2h 05m`.
pub fn duration(w: *std.Io.Writer, s: f64) !void {
    if (!std.math.isFinite(s)) return w.writeAll("-");
    if (s < 0.0995) return w.print("{d:.0} ms", .{@max(s, 0) * 1000});
    // 59.96 s rounds to 60.0, so it is shown as 1m 00s.
    if (s < 59.95) return w.print("{d:.1} s", .{@max(s, 0)});
    const whole: u64 = std.math.lossyCast(u64, @round(s));
    if (whole < 3600) return w.print("{d}m {d:0>2}s", .{ whole / 60, whole % 60 });
    return w.print("{d}h {d:0>2}m", .{ whole / 3600, whole % 3600 / 60 });
}

/// A size given in MiB: `9.8 MiB`, `512 MiB`, `1.5 GiB`, `120 GiB`, `1.2 TiB`.
pub fn size(w: *std.Io.Writer, mib: f64) !void {
    if (!std.math.isFinite(mib)) return w.writeAll("-");
    if (mib >= 1024 * 1024) return w.print("{d:.1} TiB", .{mib / (1024 * 1024)});
    if (mib >= 100 * 1024) return w.print("{d:.0} GiB", .{mib / 1024});
    if (mib >= 1024) return w.print("{d:.1} GiB", .{mib / 1024});
    if (mib >= 10) return w.print("{d:.0} MiB", .{mib});
    return w.print("{d:.1} MiB", .{@max(mib, 0)});
}

/// A part of a total in percent, `12%`, or `<1%` for a small nonzero part.
pub fn percent(w: *std.Io.Writer, part: f64, total: f64) !void {
    const pct = if (total > 0) part / total * 100 else 0;
    if (pct > 0 and pct < 0.5) return w.writeAll("<1%");
    try w.print("{d:.0}%", .{pct});
}

/// Writes what `f` writes, right-aligned in `width` columns.
pub fn right(w: *std.Io.Writer, width: usize, comptime f: anytype, args: anytype) !void {
    var buf: [64]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    @call(.auto, f, .{&fw} ++ args) catch {};
    const text = fw.buffered();
    if (text.len < width) try w.splatByteAll(' ', width - text.len);
    try w.writeAll(text);
}

/// `n` and the noun, plural unless n is 1: `1 rule`, `3 rules`.
pub fn count(w: *std.Io.Writer, n: usize, one: []const u8, many: []const u8) !void {
    try w.print("{d} {s}", .{ n, if (n == 1) one else many });
}

/// `s` in at most `max` bytes: a longer one keeps its start and end around
/// "...", since rules of one step differ at the end. Cuts fall between
/// UTF-8 characters; the result may live in `buf`.
pub fn middle(buf: []u8, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    if (max < 7) return s[0..charStart(s, max)];
    const keep = max - 3;
    const head = charStart(s, (keep + 1) / 2);
    var tail = s.len - (keep - (keep + 1) / 2);
    while (tail < s.len and s[tail] & 0xc0 == 0x80) tail += 1;
    return std.fmt.bufPrint(buf, "{s}...{s}", .{ s[0..head], s[tail..] }) catch s[0..head];
}

/// The start of the character at or before byte `n` of `s`.
fn charStart(s: []const u8, n: usize) usize {
    var i = @min(n, s.len);
    while (i > 0 and i < s.len and s[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

/// A name in a field of `width` columns, left-aligned, cut by `middle`:
/// `{f}` with `field(name, 30)`.
pub fn field(name: []const u8, width: usize) Field {
    return .{ .name = name, .width = width };
}

pub const Field = struct {
    name: []const u8,
    width: usize,

    pub fn format(self: Field, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [256]u8 = undefined;
        const shown = middle(&buf, self.name, @min(self.width, buf.len));
        try w.writeAll(shown);
        try w.splatByteAll(' ', self.width -| shown.len);
    }
};
