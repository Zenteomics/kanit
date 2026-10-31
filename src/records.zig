//! Launch and attempt records under `<workdir>/.workz/`.
//!
//! Layout:
//!   .workz/lock                      held with flock for the whole run
//!   .workz/state.json                resume state (state.zig)
//!   .workz/journal                   dispatch and done markers between state saves
//!   .workz/launches/<id>/workflow    snapshot of the workflow file
//!   .workz/launches/<id>/launch.json options, engine identity, shared sizes
//!   .workz/launches/<id>/events.jsonl typed events, append-only
//!   .workz/launches/<id>/summary.json final counts and status
//!   .workz/launches/<id>/report.html  the launch's page (html.zig), redrawn while it runs
//!   .workz/launches/<id>/versions.json the output of each tool's version command,
//!       with versions/ holding each one's whole output
//!   .workz/launches/<id>/control      commands for the running launch
//!   .workz/launches/<id>/shared/      service scripts, logs and stop pipes
//!   .workz/launches/<id>/attempts/<rule>/<NNN>/ command.sh, request.json,
//!       stdout.log, stderr.log, record.json (written last), previous/,
//!       diagnostics/ (the tails a failed attempt kept)
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

pub const event_version = 1;
/// Version of the JSON records of a launch: `launch.json`, `request.json`,
/// `record.json`, `versions.json` and `summary.json`. A reader refuses a
/// newer one; one without `v` is from before the field and reads as 1.
pub const record_version = 1;

pub fn recordsDir(a: Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, ".workz" });
}

/// Makes the records directory `records`, readable by its owner alone: it
/// holds every attempt's output and the environment values passed to rules.
pub fn makeRecordsDir(gpa: Allocator, records: []const u8) !void {
    try sys.mkdirAll(gpa, records);
    const p = try sys.z(gpa, records);
    defer gpa.free(p);
    _ = try sys.check(linux.fchmodat(linux.AT.FDCWD, p, 0o700));
}

/// Where an attempt keeps its copies of the diagnostics files the rule
/// wrote as `written`.
pub fn diagnosticPaths(a: Allocator, dir: []const u8, written: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, written.len);
    for (written, out) |w, *o| o.* = try std.fs.path.join(a, &.{ dir, "diagnostics", w });
    return out;
}

/// The diagnostics an ended attempt kept, as its `record.json` lists them;
/// none when it has no record yet.
pub fn keptDiagnostics(gpa: Allocator, a: Allocator, dir: []const u8) ![]const []const u8 {
    const path = try std.fs.path.join(a, &.{ dir, "record.json" });
    const bytes = sys.readFile(gpa, path, 16 << 20) catch |err| return if (err == error.OutOfMemory) err else &.{};
    defer gpa.free(bytes);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) err else &.{};
    if (v != .object) return &.{};
    const list = v.object.get("diagnostics") orelse return &.{};
    if (list != .array) return &.{};
    var written: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |item| if (item == .string) try written.append(a, item.string);
    return diagnosticPaths(a, dir, written.items);
}

/// Takes the run lock; error.Busy when another run holds it.
pub fn lock(gpa: Allocator, records: []const u8) !sys.Fd {
    const p = try std.fs.path.join(gpa, &.{ records, "lock" });
    defer gpa.free(p);
    const fd = try sys.openWrite(gpa, p, .append);
    errdefer sys.close(fd);
    const LOCK_EX = 2;
    const LOCK_NB = 4;
    // `running` probes take the lock shared for an instant; a launch holds
    // it for its whole life. A short retry tells the two apart.
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        _ = sys.check(linux.flock(fd, LOCK_EX | LOCK_NB)) catch |err| switch (err) {
            error.WouldBlock => {
                if (tries == 20) return error.Busy;
                const ts: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
                _ = linux.nanosleep(&ts, null);
                continue;
            },
            else => return err,
        };
        return fd;
    }
}

/// Whether a run holds the run lock now. It only tests the lock: a shared
/// lock that is free is let go at once.
pub fn running(gpa: Allocator, records: []const u8) bool {
    const p = std.fs.path.join(gpa, &.{ records, "lock" }) catch return false;
    defer gpa.free(p);
    const fd = sys.openRead(gpa, p) catch return false;
    defer sys.close(fd);
    const LOCK_SH = 1;
    const LOCK_NB = 4;
    return linux.errno(linux.flock(fd, LOCK_SH | LOCK_NB)) == .AGAIN;
}

/// A new launch directory named by UTC time and a random suffix.
pub fn newLaunch(gpa: Allocator, a: Allocator, records: []const u8) !struct { id: []const u8, dir: []const u8 } {
    var tbuf: [32]u8 = undefined;
    var tw = std.Io.Writer.fixed(&tbuf);
    try sys.formatTime(&tw, sys.realNs());
    const t = tw.buffered();
    // 2026-10-23T11:51:02.123Z -> 20261023T115102.123, which sorts by time.
    const compact = try std.fmt.allocPrint(a, "{s}{s}{s}T{s}{s}{s}.{s}", .{ t[0..4], t[5..7], t[8..10], t[11..13], t[14..16], t[17..19], t[20..23] });
    var rnd: [4]u8 = undefined;
    sys.randomBytes(&rnd);
    const id = try std.fmt.allocPrint(a, "{s}-{s}", .{ compact, &std.fmt.bytesToHex(rnd, .lower) });
    const dir = try std.fs.path.join(a, &.{ records, "launches", id });
    try sys.mkdirAll(gpa, dir);
    return .{ .id = id, .dir = dir };
}

/// The launch IDs under `records`, oldest first: an ID begins with its
/// start time, so the names sort by time.
pub fn launchNames(gpa: Allocator, a: Allocator, records: []const u8) ![]const []const u8 {
    return (try sys.dirNames(gpa, a, try std.fs.path.join(a, &.{ records, "launches" }))) orelse &.{};
}

/// The newest launch directory, or null when there is none.
pub fn latestLaunch(gpa: Allocator, a: Allocator, records: []const u8) !?[]const u8 {
    const names = try launchNames(gpa, a, records);
    if (names.len == 0) return null;
    return try std.fs.path.join(a, &.{ records, "launches", names[names.len - 1] });
}

/// Whether the launch in `launch_dir` (`<records>/launches/<id>`) can still
/// change: it has no summary, an engine holds the working directory's lock,
/// and it is the newest launch, the only one a held lock can belong to. A
/// launch without a summary that is not active ended without recording its
/// end, as when its engine was killed.
pub fn launchActive(gpa: Allocator, launch_dir: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (sys.exists(gpa, std.fs.path.join(a, &.{ launch_dir, "summary.json" }) catch return false)) return false;
    const rec = std.fs.path.dirname(std.fs.path.dirname(launch_dir) orelse return false) orelse return false;
    if (!running(gpa, rec)) return false;
    const latest = (latestLaunch(gpa, a, rec) catch return false) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(latest), std.fs.path.basename(launch_dir));
}

/// Append-only JSON Lines event stream. Each line is one object with a
/// format version, a UTC time and an event name.
pub const Events = struct {
    gpa: Allocator,
    fd: sys.Fd,

    pub fn open(gpa: Allocator, launch_dir: []const u8) !Events {
        const p = try std.fs.path.join(gpa, &.{ launch_dir, "events.jsonl" });
        defer gpa.free(p);
        return .{ .gpa = gpa, .fd = try sys.openWrite(gpa, p, .append) };
    }

    pub fn close(self: *Events) void {
        sys.close(self.fd);
    }

    pub fn emit(self: *Events, comptime name: []const u8, fields: anytype) void {
        self.write(name, fields) catch |err| std.debug.print("workz: cannot write event {s}: {s}\n", .{ name, @errorName(err) });
    }

    fn write(self: *Events, comptime name: []const u8, fields: anytype) !void {
        var w: std.Io.Writer.Allocating = .init(self.gpa);
        defer w.deinit();
        try w.writer.print("{{\"v\":{d},\"time\":\"", .{event_version});
        try sys.formatTime(&w.writer, sys.realNs());
        try w.writer.writeAll("\",\"event\":\"" ++ name ++ "\"");
        try writeFields(&w.writer, fields);
        try w.writer.writeAll("}\n");
        try sys.writeAll(self.fd, w.written());
    }
};

/// Writes `,"name":value` for each field of an anonymous struct.
pub fn writeFields(w: *std.Io.Writer, fields: anytype) !void {
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |f| {
        try w.writeAll(",\"" ++ f.name ++ "\":");
        try w.print("{f}", .{std.json.fmt(@field(fields, f.name), .{})});
    }
}

/// Writes a value as a JSON record file through a rename, so readers never
/// see a partial file. Resume state uses `state.save`, which also fsyncs.
pub fn writeJson(gpa: Allocator, path: []const u8, value: anytype) !void {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.print("{f}\n", .{std.json.fmt(value, .{ .whitespace = .indent_2 })});
    try sys.writeFileReplace(gpa, path, w.written());
}

pub fn timeText(a: Allocator, ns: i128) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try sys.formatTime(&w.writer, ns);
    return w.toOwnedSlice();
}

/// Dispatch and done markers. A rule dispatched without a later done marker
/// was interrupted before its result reached `state.json`; its entry is
/// dropped on the next launch so the rule runs again.
pub const Journal = struct {
    fd: sys.Fd,

    pub fn open(gpa: Allocator, records: []const u8) !Journal {
        const p = try std.fs.path.join(gpa, &.{ records, "journal" });
        defer gpa.free(p);
        return .{ .fd = try sys.openWrite(gpa, p, .append) };
    }

    pub fn close(self: *Journal) void {
        sys.close(self.fd);
    }

    pub fn mark(self: *Journal, gpa: Allocator, kind: []const u8, rule: []const u8) !void {
        const line = try std.fmt.allocPrint(gpa, "{s}\t{s}\n", .{ kind, rule });
        defer gpa.free(line);
        try sys.writeAll(self.fd, line);
    }

    /// Rules dispatched without a later done marker.
    pub fn unfinished(gpa: Allocator, a: Allocator, records: []const u8) ![]const []const u8 {
        const p = try std.fs.path.join(gpa, &.{ records, "journal" });
        defer gpa.free(p);
        const text = sys.readFile(gpa, p, 1 << 30) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer gpa.free(text);
        var open_rules: std.StringArrayHashMapUnmanaged(void) = .empty;
        var it = std.mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const rule = line[tab + 1 ..];
            if (std.mem.eql(u8, line[0..tab], "dispatch")) {
                try open_rules.put(a, try a.dupe(u8, rule), {});
            } else _ = open_rules.swapRemove(rule);
        }
        return open_rules.keys();
    }

    /// Empties the journal after a final state save.
    pub fn reset(gpa: Allocator, records: []const u8) !void {
        const p = try std.fs.path.join(gpa, &.{ records, "journal" });
        defer gpa.free(p);
        try sys.writeFile(gpa, p, "");
    }
};
