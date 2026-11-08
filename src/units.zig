//! How kanit shows durations and sizes to people: one form everywhere, so a
//! figure reads the same in the terminal, the text reports and the HTML
//! page. Machine output (TSV, JSON) keeps plain numbers.
const std = @import("std");

pub fn duration(w: *std.Io.Writer, s: f64) !void {
    if (!std.math.isFinite(s)) return w.writeAll("-");
    if (s < 0.0995) return w.print("{d:.0} ms", .{@max(s, 0) * 1000});
    if (s < 59.95) return w.print("{d:.1} s", .{@max(s, 0)});
    const whole: u64 = std.math.lossyCast(u64, @round(s));
    if (whole < 3600) return w.print("{d}m {d:0>2}s", .{ whole / 60, whole % 60 });
    return w.print("{d}h {d:0>2}m", .{ whole / 3600, whole % 3600 / 60 });
}

pub fn size(w: *std.Io.Writer, mib: f64) !void {
    if (!std.math.isFinite(mib)) return w.writeAll("-");
    if (mib >= 1024 * 1024) return w.print("{d:.1} TiB", .{mib / (1024 * 1024)});
    if (mib >= 100 * 1024) return w.print("{d:.0} GiB", .{mib / 1024});
    if (mib >= 1024) return w.print("{d:.1} GiB", .{mib / 1024});
    if (mib >= 10) return w.print("{d:.0} MiB", .{mib});
    return w.print("{d:.1} MiB", .{@max(mib, 0)});
}

pub fn percent(w: *std.Io.Writer, part: f64, total: f64) !void {
    const pct = if (total > 0) part / total * 100 else 0;
    if (pct > 0 and pct < 0.5) return w.writeAll("<1%");
    try w.print("{d:.0}%", .{pct});
}

pub fn right(w: *std.Io.Writer, width: usize, comptime f: anytype, args: anytype) !void {
    var buf: [64]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    @call(.auto, f, .{&fw} ++ args) catch {};
    const text = fw.buffered();
    if (text.len < width) try w.splatByteAll(' ', width - text.len);
    try w.writeAll(text);
}

pub fn count(w: *std.Io.Writer, n: usize, one: []const u8, many: []const u8) !void {
    try w.print("{d} {s}", .{ n, if (n == 1) one else many });
}

pub fn middle(buf: []u8, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    if (max < 7) return s[0..charStart(s, max)];
    const keep = max - 3;
    const head = charStart(s, (keep + 1) / 2);
    var tail = s.len - (keep - (keep + 1) / 2);
    while (tail < s.len and s[tail] & 0xc0 == 0x80) tail += 1;
    return std.fmt.bufPrint(buf, "{s}...{s}", .{ s[0..head], s[tail..] }) catch s[0..head];
}

fn charStart(s: []const u8, n: usize) usize {
    var i = @min(n, s.len);
    while (i > 0 and i < s.len and s[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

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
