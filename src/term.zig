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

/// Whether output on `fd` may use color: only on a terminal, never when
/// `NO_COLOR` is set to a non-empty value (no-color.org) or `TERM` is `dumb`.
pub fn colorOn(fd: sys.Fd, env: *const std.process.Environ.Map) bool {
    if (!isTerminal(fd)) return false;
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return false;
    if (env.get("TERM")) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    return true;
}

pub const Size = struct { cols: usize, rows: usize };

/// The size of the terminal on `fd`, or 80 by 24 when it cannot be read.
pub fn size(fd: sys.Fd) Size {
    var ws: std.posix.winsize = undefined;
    if (linux.errno(linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
    return .{ .cols = ws.col, .rows = ws.row };
}

/// SGR sequences, or empty strings when color is off, so callers write the
/// same text either way.
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
