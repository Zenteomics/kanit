//! Terminal capabilities for the views: whether a descriptor is a terminal,
//! whether output to it may use color, and its size. Color uses the sixteen
//! standard SGR colors, so it follows the user's terminal theme; every view
//! stays readable without it, because color only adds emphasis.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub fn isTerminal(fd: sys.Fd) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.tcgetattr(fd, &t)) == .SUCCESS;
}

pub fn colorOn(fd: sys.Fd, env: *const std.process.Environ.Map) bool {
    if (!isTerminal(fd)) return false;
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return false;
    if (env.get("TERM")) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    return true;
}

pub const Size = struct { cols: usize, rows: usize };

pub fn size(fd: sys.Fd) Size {
    var ws: std.posix.winsize = undefined;
    if (linux.errno(linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
    return .{ .cols = ws.col, .rows = ws.row };
}

pub const Style = struct {
    on: bool,

    pub fn reset(s: Style) []const u8 {
        return if (s.on) "\x1b[0m" else "";
    }
    pub fn bold(s: Style) []const u8 {
        return if (s.on) "\x1b[1m" else "";
    }
    pub fn dim(s: Style) []const u8 {
        return if (s.on) "\x1b[2m" else "";
    }
    pub fn red(s: Style) []const u8 {
        return if (s.on) "\x1b[31m" else "";
    }
    pub fn green(s: Style) []const u8 {
        return if (s.on) "\x1b[32m" else "";
    }
    pub fn yellow(s: Style) []const u8 {
        return if (s.on) "\x1b[33m" else "";
    }
    pub fn blue(s: Style) []const u8 {
        return if (s.on) "\x1b[34m" else "";
    }
    pub fn magenta(s: Style) []const u8 {
        return if (s.on) "\x1b[35m" else "";
    }
    pub fn cyan(s: Style) []const u8 {
        return if (s.on) "\x1b[36m" else "";
    }
};

pub fn blankControls(s: []u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        var c = s[i];
        if (c == 0xc2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9f) {
            c = ' ';
            i += 1;
        } else if (c < 0x20 or c == 0x7f) c = ' ';
        s[w] = c;
        w += 1;
    }
    return s[0..w];
}
