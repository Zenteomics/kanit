//! `kanit clean`: removes what earlier launches left behind in a working
//! directory. It takes the run lock, so it never races a run. It removes
//! containers labelled with the working directory, and with `--keep N` the
//! launch directories older than the newest N, except a launch that holds
//! the recorded attempt of a rule, whose logs belong to current outputs.
//! With `--previous` it removes the earlier outputs that attempts moved
//! into their `previous/` directories, in every launch. With
//! `--intermediates` it removes the outputs the workflow marks
//! `intermediate` once their rule and every rule reading them completed,
//! and records each in the state, so later plans keep those rules done.
const std = @import("std");
const units = @import("units.zig");
const linux = std.os.linux;
const sys = @import("sys.zig");
const records = @import("records.zig");
const state = @import("state.zig");
const container = @import("container.zig");
const process = @import("process.zig");
const workflow = @import("workflow.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    keep: ?usize = null,
    previous: bool = false,
    intermediates: bool = false,
    /// With `intermediates`: steps every recorded output of which goes.
    steps: []const []const u8 = &.{},
    dry_run: bool = false,
};

pub const Result = struct { containers: usize = 0, launches: usize = 0, bytes: u64 = 0, kept_for_records: usize = 0, kept_for_recovery: usize = 0, previous: usize = 0, previous_bytes: u64 = 0, intermediates: usize = 0, intermediate_bytes: u64 = 0, intermediates_kept: usize = 0, failed: usize = 0 };

fn openDir(gpa: Allocator, path: []const u8) !sys.Fd {
    const p = try sys.z(gpa, path);
    defer gpa.free(p);
    return @intCast(try sys.check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0)));
}

pub fn removeAt(gpa: Allocator, parent: sys.Fd, name: [:0]const u8, dry: bool, depth: usize) !u64 {
    if (depth > 64) return error.DirectoryTooDeep;
    var st: linux.Statx = undefined;
    _ = try sys.check(linux.statx(parent, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true }, &st));
    if (st.mode & 0o170000 != 0o040000) {
        if (!dry) _ = try sys.check(linux.unlinkat(parent, name, 0));
        return st.size;
    }
    const fd: sys.Fd = @intCast(try sys.check(linux.openat(parent, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0)));
    defer sys.close(fd);
    if (!dry) _ = linux.fchmod(fd, 0o700);
    var total: u64 = 0;
    var names: std.ArrayList([:0]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var entries: sys.DirEntries = .{ .fd = fd };
    while (try entries.next()) |e| try names.append(gpa, try gpa.dupeZ(u8, e.name));
    for (names.items) |entry| total += try removeAt(gpa, fd, entry, dry, depth + 1);
    if (!dry) _ = try sys.check(linux.unlinkat(parent, name, linux.AT.REMOVEDIR));
    return total;
}

/// `wf` is the workflow whose marks `--intermediates` follows.
pub fn run(gpa: Allocator, a: Allocator, root: []const u8, opts: Options, wf: ?*const workflow.Workflow, environ: *const std.process.Environ.Map, w: *std.Io.Writer) !Result {
    var result: Result = .{};
    const rec = try records.recordsDir(a, root);
    if (!sys.exists(gpa, rec)) return result;
    const lock = records.lock(gpa, rec) catch |err| switch (err) {
        error.Busy => return error.Busy,
        else => return err,
    };
    defer sys.close(lock);

    if (try container.findPodman(gpa, a, environ.get("PATH") orelse "/usr/bin:/bin")) |podman| {
        const devnull = try sys.openRead(gpa, "/dev/null");
        defer sys.close(devnull);
        const envp = try process.Vec.init(a, try state.hostEnv(a, environ, &.{}));
        result.containers = if (opts.dry_run)
            (try container.listLeftovers(gpa, a, podman, root, &envp, devnull)).len
        else
            try container.removeLeftovers(gpa, a, podman, root, &envp, devnull);
    }

    const pending = try records.pendingAttempts(gpa, a, rec, null);
    if (opts.intermediates) {
        if (pending.len > 0) return error.PendingRecovery;
        try removeIntermediates(gpa, a, rec, root, wf, opts.steps, opts.dry_run, &result, w);
    }
    if (opts.previous) try removePrevious(gpa, a, rec, pending, opts.dry_run, &result, w);

    const keep = opts.keep orelse return result;
    const names = try records.launchNames(gpa, a, rec);
    if (names.len <= keep) return result;
    var held: std.StringHashMapUnmanaged(void) = .empty;
    var st = try state.load(gpa, rec);
    defer st.deinit();
    const prefix = try std.fs.path.join(a, &.{ rec, "launches" });
    for (st.data.rules.map.values()) |e| {
        if (!std.mem.startsWith(u8, e.attempt, prefix)) continue;
        var parts = std.mem.tokenizeScalar(u8, e.attempt[prefix.len..], '/');
        if (parts.next()) |id| try held.put(a, id, {});
    }
    const launches_fd = try openDir(gpa, prefix);
    defer sys.close(launches_fd);
    for (names[0 .. names.len - keep]) |name| {
        if (held.contains(name)) {
            result.kept_for_records += 1;
            continue;
        }
        const recovers = for (pending) |p| {
            if (std.mem.eql(u8, p.launch, name)) break true;
        } else false;
        if (recovers) {
            result.kept_for_recovery += 1;
            continue;
        }
        result.bytes += removeAt(gpa, launches_fd, try a.dupeZ(u8, name), opts.dry_run, 0) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try w.print("cannot remove launch {s}: {s}\n", .{ name, sys.errorText(err) });
                result.failed += 1;
                continue;
            },
        };
        result.launches += 1;
        try w.print("{s} launch {s}\n", .{ if (opts.dry_run) "would remove" else "removed", name });
    }
    return result;
}

/// Removes the intermediates: the outputs the workflow marks `intermediate`,
/// and every recorded output of the steps `--step` names, whose rule's
/// recorded attempt wrote them as they are now. Without a workflow file the
/// records name everything: a rule's step comes from the workflow its launch
/// recorded, and what rules read from their recorded input identities. Each
/// removal is recorded in the state with its identity; a file kept is named
/// with the reason.
fn removeIntermediates(gpa: Allocator, a: Allocator, rec: []const u8, root: []const u8, wf: ?*const workflow.Workflow, steps: []const []const u8, dry: bool, result: *Result, w: *std.Io.Writer) !void {
    var st = try state.load(gpa, rec);
    defer st.deinit();
    var ids = state.Identities.init(gpa);
    defer ids.deinit();
    var recorded: Recorded = .{ .gpa = gpa, .root = root };
    defer recorded.deinit();
    const eql = std.mem.eql;

    // What may go, with the rule that wrote it.
    var marked: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    if (wf) |f| for (f.rules) |r| for (r.intermediate_abs) |p| try marked.put(a, p, r.name);
    if (steps.len > 0) for (st.data.rules.map.keys(), st.data.rules.map.values()) |name, e| {
        const step = (try recorded.stepOf(a, wf, name, e.attempt)) orelse continue;
        for (steps) |want| if (eql(u8, want, step)) {
            for (e.outputs) |o| try marked.put(a, o.path, name);
            break;
        };
    };

    // What rules read, and which shared inputs map.
    var reads: std.StringHashMapUnmanaged(void) = .empty;
    var pending: std.StringHashMapUnmanaged([]const u8) = .empty;
    var shared: std.ArrayList([]const u8) = .empty;
    for (st.data.rules.map.values()) |e| for (e.input_ids) |in| try reads.put(a, in.path, {});
    var flows: std.ArrayList(*const workflow.Workflow) = .empty;
    if (wf) |f| try flows.append(a, f);
    for (recorded.flows.values()) |*f| if (f.*) |*x| try flows.append(a, x);
    for (flows.items) |f| {
        for (f.rules) |q| for (q.input_abs) |in| {
            try reads.put(a, in, {});
            if (!st.data.rules.map.contains(q.name)) try pending.put(a, in, q.name);
        };
        for (f.shared) |sh| if (sh.path_abs) |sp| try shared.append(a, sp);
    }

    const inside = try std.fmt.allocPrint(a, "{s}/", .{root});
    const records_dir = try std.fmt.allocPrint(a, "{s}/", .{rec});
    const Chosen = struct { path: []const u8, shown: []const u8, id: []const u8, size: u64 };
    var chosen: std.ArrayList(Chosen) = .empty;
    for (marked.keys(), marked.values()) |p, producer| {
        if (st.data.removed.map.contains(p)) continue;
        if (!std.mem.startsWith(u8, p, inside) or std.mem.startsWith(u8, p, records_dir)) continue;
        const shown = workflow.keyPath(root, p);
        const e = st.data.rules.map.get(producer) orelse continue;
        const id = for (e.outputs) |o| {
            if (eql(u8, o.path, p)) break o.id;
        } else continue;
        var sx: linux.Statx = undefined;
        const zp = try a.dupeZ(u8, p);
        if (linux.errno(linux.statx(linux.AT.FDCWD, zp, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true }, &sx)) != .SUCCESS) continue;
        const why: ?[]const u8 = why: {
            if (sx.mode & 0o170000 != 0o100000) break :why "it is not a regular file";
            if (pending.get(p)) |q| break :why try std.fmt.allocPrint(a, "rule {s} reads it and has not completed", .{q});
            var dir = std.fs.path.dirname(p);
            while (dir) |d| : (dir = std.fs.path.dirname(d)) {
                if (d.len < root.len) break;
                if (reads.contains(d)) break :why "a rule reads the directory that holds it";
            }
            for (shared.items) |sp| if (eql(u8, sp, p) or (std.mem.startsWith(u8, p, sp) and p[sp.len] == '/'))
                break :why "a shared input maps it";
            const now = (ids.get(p) catch break :why "it cannot be read") orelse continue;
            if (!eql(u8, now, id)) break :why try std.fmt.allocPrint(a, "it changed after rule {s} wrote it", .{producer});
            break :why null;
        };
        if (why) |reason| {
            try w.print("kept {s}: {s}\n", .{ shown, reason });
            result.intermediates_kept += 1;
            continue;
        }
        try chosen.append(a, .{ .path = p, .shown = shown, .id = id, .size = sx.size });
    }
    // The state records each removal before the file goes: a mark on a file
    // that stays reads as the file itself, a file gone without its mark
    // would make the next launch run its rule again.
    if (!dry and chosen.items.len > 0) {
        const sa = st.allocator();
        for (chosen.items) |c| try st.data.removed.map.put(sa, try sa.dupe(u8, c.path), try sa.dupe(u8, c.id));
        try st.save(gpa);
    }
    for (chosen.items) |c| {
        if (!dry) sys.unlink(gpa, c.path) catch |err| {
            try w.print("cannot remove {s}: {s}\n", .{ c.shown, sys.errorText(err) });
            result.failed += 1;
            continue;
        };
        result.intermediates += 1;
        result.intermediate_bytes += c.size;
        try w.print("{s} {s}, ", .{ if (dry) "would remove" else "removed", c.shown });
        try units.size(w, @as(f64, @floatFromInt(c.size)) / 1048576.0);
        try w.writeAll("\n");
    }
}

/// The workflows launches recorded, read once each: they name the step of a
/// rule the state recorded, when no workflow file is given or it lacks the
/// rule.
const Recorded = struct {
    gpa: Allocator,
    root: []const u8,
    flows: std.StringArrayHashMapUnmanaged(?workflow.Workflow) = .empty,

    fn deinit(self: *Recorded) void {
        for (self.flows.values()) |*f| if (f.*) |*x| x.deinit();
        self.flows.deinit(self.gpa);
    }

    fn stepOf(self: *Recorded, a: Allocator, wf: ?*const workflow.Workflow, name: []const u8, attempt: []const u8) !?[]const u8 {
        if (wf) |f| if (f.ruleIndex(name)) |i| return f.rules[i].labels.step;
        // An attempt directory is LAUNCH/attempts/RULE/NNN.
        const launch = std.fs.path.dirname(std.fs.path.dirname(std.fs.path.dirname(attempt) orelse return null) orelse return null) orelse return null;
        const got = try self.flows.getOrPut(self.gpa, launch);
        if (!got.found_existing) {
            got.key_ptr.* = try a.dupe(u8, launch);
            var problem: workflow.Problem = .{};
            defer if (problem.message.len > 0) self.gpa.free(problem.message);
            got.value_ptr.* = workflow.loadRecorded(self.gpa, try std.fs.path.join(a, &.{ launch, "workflow" }), self.root, &problem) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
        }
        const f = got.value_ptr.* orelse return null;
        const i = f.ruleIndex(name) orelse return null;
        return f.rules[i].labels.step;
    }
};

fn openBelow(parent: sys.Fd, name: [:0]const u8) ?sys.Fd {
    const rc = linux.openat(parent, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn namesIn(a: Allocator, fd: sys.Fd) ![]const [:0]const u8 {
    var names: std.ArrayList([:0]const u8) = .empty;
    var entries: sys.DirEntries = .{ .fd = fd };
    while (try entries.next()) |e| if (e.name[0] != '.') try names.append(a, try a.dupeZ(u8, e.name));
    return names.items;
}

fn removePrevious(gpa: Allocator, a: Allocator, rec: []const u8, pending: []const records.Pending, dry: bool, result: *Result, w: *std.Io.Writer) !void {
    const launches_fd = openDir(gpa, try std.fs.path.join(a, &.{ rec, "launches" })) catch return;
    defer sys.close(launches_fd);
    for (try records.launchNames(gpa, a, rec)) |launch| {
        const launch_fd = openBelow(launches_fd, try a.dupeZ(u8, launch)) orelse continue;
        defer sys.close(launch_fd);
        const attempts_fd = openBelow(launch_fd, "attempts") orelse continue;
        defer sys.close(attempts_fd);
        const attempts = try std.fs.path.join(a, &.{ rec, "launches", launch, "attempts" });
        var dirs: usize = 0;
        var bytes: u64 = 0;
        for (try namesIn(a, attempts_fd)) |rule| {
            const rule_fd = openBelow(attempts_fd, rule) orelse continue;
            defer sys.close(rule_fd);
            const rule_dir = try std.fs.path.join(a, &.{ attempts, rule });
            for (try namesIn(a, rule_fd)) |n| {
                const attempt = try std.fs.path.join(a, &.{ rule_dir, n });
                if (isPending(pending, attempt)) {
                    try w.print("kept {s}/previous: it holds outputs the next launch puts back\n", .{attempt});
                    result.kept_for_recovery += 1;
                    continue;
                }
                const fd = openBelow(rule_fd, n) orelse continue;
                defer sys.close(fd);
                bytes += removeAt(gpa, fd, "previous", dry, 0) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    error.OutOfMemory => return err,
                    else => {
                        try w.print("cannot remove {s}/{s}/previous: {s}\n", .{ rule_dir, n, sys.errorText(err) });
                        result.failed += 1;
                        continue;
                    },
                };
                dirs += 1;
            }
        }
        if (dirs == 0) continue;
        result.previous += dirs;
        result.previous_bytes += bytes;
        try w.print("{s} previous/ of {d} {s} in launch {s}, ", .{ if (dry) "would remove" else "removed", dirs, if (dirs == 1) "attempt" else "attempts", launch });
        try units.size(w, @as(f64, @floatFromInt(bytes)) / 1048576.0);
        try w.writeAll("\n");
    }
}

fn isPending(pending: []const records.Pending, attempt: []const u8) bool {
    for (pending) |p| if (std.mem.eql(u8, p.dir, attempt)) return true;
    return false;
}
