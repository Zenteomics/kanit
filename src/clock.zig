//! Local wall-clock time for text output. The zone comes from `TZ` as the C
//! library reads it: unset means `/etc/localtime`, empty means UTC, `:FILE`
//! or `Area/City` names a TZif file under `/usr/share/zoneinfo`, and any other
//! value is a POSIX rule such as `EST5EDT,M3.2.0,M11.1.0`. A TZif file gives
//! its transitions, and its footer rule covers the times after the last one.
//! A zone that cannot be read is UTC.
const std = @import("std");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

pub const Zone = struct {
    times: []const i64 = &.{},
    offsets: []const i32 = &.{},
    before: i32 = 0,
    rule: ?Rule = null,

    pub const utc: Zone = .{};

    pub fn load(gpa: Allocator, a: Allocator, tz: ?[]const u8) Zone {
        const value = tz orelse return fromFile(gpa, a, "/etc/localtime") orelse utc;
        if (value.len == 0) return utc;
        if (value[0] == ':') return fromName(gpa, a, value[1..]) orelse utc;
        if (Rule.parse(value)) |r| return .{ .before = -r.std_offset, .rule = r };
        return fromName(gpa, a, value) orelse utc;
    }

    fn fromName(gpa: Allocator, a: Allocator, name: []const u8) ?Zone {
        if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null) return null;
        if (std.fs.path.isAbsolute(name)) return fromFile(gpa, a, name);
        return fromFile(gpa, a, std.fs.path.join(a, &.{ "/usr/share/zoneinfo", name }) catch return null);
    }

    fn fromFile(gpa: Allocator, a: Allocator, path: []const u8) ?Zone {
        const bytes = sys.readFile(gpa, path, 1 << 20) catch return null;
        defer gpa.free(bytes);
        return fromBytes(a, bytes) catch null;
    }

    pub fn fromBytes(a: Allocator, bytes: []const u8) !Zone {
        var r: std.Io.Reader = .fixed(bytes);
        const tz = try std.tz.Tz.parse(a, &r);
        const times = try a.alloc(i64, tz.transitions.len);
        const offsets = try a.alloc(i32, tz.transitions.len);
        for (tz.transitions, times, offsets) |t, *time, *off| {
            time.* = t.ts;
            off.* = t.timetype.offset;
        }
        const before: i32 = if (tz.timetypes.len > 0) tz.timetypes[0].offset else 0;
        const rule = if (tz.footer) |f| Rule.parse(f) else null;
        return .{ .times = times, .offsets = offsets, .before = before, .rule = rule };
    }

    pub fn offset(self: Zone, t: i64) i32 {
        if (self.times.len > 0 and t < self.times[0]) return self.before;
        if (self.times.len > 0 and (t <= self.times[self.times.len - 1] or self.rule == null)) {
            var lo: usize = 0;
            var hi: usize = self.times.len;
            while (hi - lo > 1) {
                const mid = (lo + hi) / 2;
                if (self.times[mid] <= t) lo = mid else hi = mid;
            }
            return self.offsets[lo];
        }
        if (self.rule) |r| return r.offset(t);
        return self.before;
    }

    pub fn local(self: Zone, real_ns: i128) Civil {
        const t: i64 = @intCast(@divFloor(real_ns, std.time.ns_per_s));
        return Civil.of(t + self.offset(t));
    }
};

pub const Civil = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    pub fn of(t: i64) Civil {
        const days = @divFloor(t, 86400);
        const secs: u32 = @intCast(t - days * 86400);
        const ymd = fromDays(days);
        return .{ .year = ymd.year, .month = ymd.month, .day = ymd.day, .hour = @intCast(secs / 3600), .minute = @intCast(secs / 60 % 60), .second = @intCast(secs % 60) };
    }

    pub fn sameDay(x: Civil, y: Civil) bool {
        return x.year == y.year and x.month == y.month and x.day == y.day;
    }
};

const Ymd = struct { year: i32, month: u8, day: u8 };

fn fromDays(z0: i64) Ymd {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = @intCast(yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0)), .month = @intCast(m), .day = @intCast(d) };
}

fn toDays(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn leap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub const Rule = struct {
    std_offset: i32,
    dst_offset: ?i32 = null,
    start: Date = .{},
    end: Date = .{},

    pub const Date = struct {
        kind: enum { month, julian, zero } = .month,
        month: u8 = 0,
        week: u8 = 0,
        weekday: u8 = 0,
        day: u16 = 0,
        time: i32 = 7200,

        fn at(self: Date, year: i32) i64 {
            const day: i64 = switch (self.kind) {
                .julian => toDays(year, 1, 1) + self.day - 1 + @as(i64, if (leap(year) and self.day >= 60) 1 else 0),
                .zero => toDays(year, 1, 1) + self.day,
                .month => blk: {
                    const first = toDays(year, self.month, 1);
                    const wday: i64 = @mod(first + 4, 7);
                    var d = first + @mod(@as(i64, self.weekday) - wday, 7) + (@as(i64, self.week) - 1) * 7;
                    const last = first + monthDays(year, self.month) - 1;
                    while (d > last) d -= 7;
                    break :blk d;
                },
            };
            return day * 86400 + self.time;
        }
    };

    pub fn parse(text: []const u8) ?Rule {
        var p: Parser = .{ .s = text };
        if (!p.name()) return null;
        const std_west = p.time() orelse return null;
        var r: Rule = .{ .std_offset = -std_west };
        if (p.done()) return r;
        if (!p.name()) return null;
        r.dst_offset = r.std_offset + 3600;
        if (!p.done() and p.peek() != ',') r.dst_offset = -(p.time() orelse return null);
        if (p.done()) {
            r.start = .{ .kind = .month, .month = 3, .week = 2, .weekday = 0 };
            r.end = .{ .kind = .month, .month = 11, .week = 1, .weekday = 0 };
            return r;
        }
        if (!p.eat(',')) return null;
        r.start = p.date() orelse return null;
        if (!p.eat(',')) return null;
        r.end = p.date() orelse return null;
        return if (p.done()) r else null;
    }

    pub fn offset(self: Rule, t: i64) i32 {
        const dst = self.dst_offset orelse return self.std_offset;
        const year = Civil.of(t + self.std_offset).year;
        const start = self.start.at(year) - self.std_offset;
        const end = self.end.at(year) - dst;
        const in_dst = if (start < end) t >= start and t < end else t < end or t >= start;
        return if (in_dst) dst else self.std_offset;
    }
};

fn monthDays(year: i32, month: u8) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (leap(year)) 29 else 28,
    };
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn done(p: *Parser) bool {
        return p.i >= p.s.len;
    }

    fn peek(p: *Parser) u8 {
        return p.s[p.i];
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.done() or p.s[p.i] != c) return false;
        p.i += 1;
        return true;
    }

    fn name(p: *Parser) bool {
        if (p.eat('<')) {
            const close = std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse return false;
            if (close == p.i) return false;
            p.i = close + 1;
            return true;
        }
        const start = p.i;
        while (!p.done() and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
        return p.i - start >= 3;
    }

    fn number(p: *Parser, max: u32) ?u32 {
        const start = p.i;
        var n: u32 = 0;
        while (!p.done() and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) {
            n = n * 10 + (p.s[p.i] - '0');
            if (n > max) return null;
        }
        return if (p.i > start) n else null;
    }

    fn time(p: *Parser) ?i32 {
        var sign: i32 = 1;
        if (p.eat('-')) sign = -1 else _ = p.eat('+');
        const h = p.number(167) orelse return null;
        var secs: i32 = @intCast(h * 3600);
        if (p.eat(':')) {
            secs += @intCast((p.number(59) orelse return null) * 60);
            if (p.eat(':')) secs += @intCast(p.number(59) orelse return null);
        }
        return sign * secs;
    }

    fn date(p: *Parser) ?Rule.Date {
        var d: Rule.Date = .{};
        if (p.eat('M')) {
            d.kind = .month;
            d.month = @intCast(p.number(12) orelse return null);
            if (d.month == 0 or !p.eat('.')) return null;
            d.week = @intCast(p.number(5) orelse return null);
            if (d.week == 0 or !p.eat('.')) return null;
            d.weekday = @intCast(p.number(6) orelse return null);
        } else if (p.eat('J')) {
            d.kind = .julian;
            d.day = @intCast(p.number(365) orelse return null);
            if (d.day == 0) return null;
        } else {
            d.kind = .zero;
            d.day = @intCast(p.number(365) orelse return null);
        }
        if (p.eat('/')) d.time = p.time() orelse return null;
        return d;
    }
};
