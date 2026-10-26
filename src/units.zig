//! How workz shows durations and sizes to people: one form everywhere, so a
//! figure reads the same in the terminal, the text reports and the HTML
//! page. Machine output (TSV, JSON) keeps plain numbers.
const std = @import("std");

/// A duration: `48.2 s` under a minute, `3m 07s` under an hour, `2h 05m`.
pub fn duration(w: *std.Io.Writer, s: f64) !void {
    if (s < 60) return w.print("{d:.1} s", .{@max(s, 0)});
    const whole: u64 = @intFromFloat(@round(s));
    if (whole < 3600) return w.print("{d}m {d:0>2}s", .{ whole / 60, whole % 60 });
    return w.print("{d}h {d:0>2}m", .{ whole / 3600, whole % 3600 / 60 });
}

/// A size given in MiB: `9.8 MiB`, `512 MiB`, `1.5 GiB`, `120 GiB`, `1.2 TiB`.
pub fn size(w: *std.Io.Writer, mib: f64) !void {
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
