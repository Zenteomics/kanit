//! Resume state: file identities, rule keys and the versioned `state.json`.
//!
//! A rule is reused when its key matches the recorded key and every recorded
//! output still has its recorded identity. The key covers the command, the
//! search path, the resource request, the written paths, the identities of the
//! inputs, the keys of the producing rules and the engine identity. File
//! contents are read only for the input manifest and explicit verification.
const std = @import("std");
const sys = @import("sys.zig");
const records = @import("records.zig");
const workflow = @import("workflow.zig");
const Allocator = std.mem.Allocator;

pub const format_version: i64 = 4;

pub const engine_key: u32 = 4;
pub const engine_key_text = std.fmt.comptimePrint("workz-key {d}", .{engine_key});

pub const Output = struct {
    path: []const u8,
    id: []const u8,
    sha256: ?[]const u8 = null,
};

pub const Entry = struct {
    key: []const u8,
    command: []const u8,
    env: []const u8,
    request: []const u8,
    writes: []const u8,
    inputs: []const u8,
    parents: []const u8,
    engine: []const u8,
    outputs: []const Output,
    attempt: []const u8,
    finished: []const u8,
    wall_s: f64 = 0,
    input_ids: []const InputId = &.{},
};

pub const InputId = struct { path: []const u8, id: []const u8 };

pub const ManifestEntry = struct { id: []const u8, sha256: []const u8 };

pub const log_version: i64 = 1;

const LogHeader = struct { v: i64, base: []const u8 };

const LogLine = struct {
    env: ?[]const u8 = null,
    text: ?[]const u8 = null,
    file: ?[]const u8 = null,
    id: ?[]const u8 = null,
    rule: ?[]const u8 = null,
    entry: ?Entry = null,
};

pub const Data = struct {
    format_version: i64 = format_version,
    rules: std.json.ArrayHashMap(Entry) = .{},
    files: std.json.ArrayHashMap([]const u8) = .{},
    manifest: std.json.ArrayHashMap(ManifestEntry) = .{},
    envs: std.json.ArrayHashMap([]const u8) = .{},
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    data: Data,
    path: []const u8,
    root: []const u8,
    log_path: []const u8 = "",
    base: []const u8 = "none",
    log_bytes: u64 = 0,
    json_bytes: u64 = 0,

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *State) Allocator {
        return self.arena.allocator();
    }

    pub fn logIsLarge(self: *const State) bool {
        return self.log_bytes > @max(1 << 20, 2 * self.json_bytes);
    }

    pub fn appendLog(self: *State, gpa: Allocator, rules: []const []const u8, files: []const []const u8, envs: []const []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        if (self.log_bytes == 0) try w.writer.print("{f}\n", .{std.json.fmt(LogHeader{ .v = log_version, .base = self.base }, .{})});
        for (envs) |k| if (self.data.envs.map.get(k)) |text|
            try w.writer.print("{f}\n", .{std.json.fmt(LogLine{ .env = k, .text = text }, .{ .emit_null_optional_fields = false })});
        for (files) |p| if (self.data.files.map.get(p)) |id|
            try w.writer.print("{f}\n", .{std.json.fmt(LogLine{ .file = relative(self.root, p), .id = id }, .{ .emit_null_optional_fields = false })});
        for (rules) |name| if (self.data.rules.map.get(name)) |e|
            try w.writer.print("{f}\n", .{std.json.fmt(LogLine{ .rule = name, .entry = try relativeEntry(a, self.root, e) }, .{ .emit_null_optional_fields = false })});
        const fd = try sys.openWrite(gpa, self.log_path, if (self.log_bytes == 0) .truncate else .append);
        defer sys.close(fd);
        try sys.truncateFd(fd, self.log_bytes);
        try sys.writeAll(fd, w.written());
        try sys.fdatasync(fd);
        self.log_bytes += w.written().len;
    }

    pub fn save(self: *State, gpa: Allocator) !void {
        var i: usize = 0;
        while (i < self.data.envs.map.count()) {
            const key = self.data.envs.map.keys()[i];
            const used = for (self.data.rules.map.values()) |e| {
                if (std.mem.eql(u8, e.env, key)) break true;
            } else false;
            if (used) i += 1 else self.data.envs.map.swapRemoveAt(i);
        }
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const data = try relativeData(scratch.allocator(), self.root, &self.data);
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.print("{f}\n", .{std.json.fmt(data, .{})});
        try sys.writeFileAtomic(gpa, self.path, w.written());
        self.json_bytes = w.written().len;
        self.base = try baseOf(self.allocator(), gpa, self.path);
        sys.unlink(gpa, self.log_path) catch |err| if (err != error.FileNotFound) return err;
        self.log_bytes = 0;
    }
};

pub fn loadRecorded(gpa: Allocator, a: Allocator, rec: []const u8) !State {
    var st = try load(gpa, rec);
    errdefer st.deinit();
    for (try records.Journal.unfinished(gpa, a, rec)) |name| _ = st.data.rules.map.swapRemove(name);
    return st;
}

pub fn loadErrorText(a: Allocator, err: anyerror, path: []const u8) !?[]const u8 {
    return switch (err) {
        error.CorruptState => try std.fmt.allocPrint(a, "{s} cannot be read: it is not a valid kanit state; move it aside, and the next launch runs every rule", .{path}),
        error.UnsupportedState => try std.fmt.allocPrint(a, "{s} has a format version this kanit cannot read; use the kanit that wrote it, or move it aside, and the next launch runs every rule", .{path}),
        else => null,
    };
}

pub fn load(gpa: Allocator, rec: []const u8) !State {
    var s: State = .{ .arena = std.heap.ArenaAllocator.init(gpa), .data = .{}, .path = undefined, .root = undefined };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    s.path = try std.fs.path.join(a, &.{ rec, "state.json" });
    s.log_path = try std.fs.path.join(a, &.{ rec, "state.log" });
    s.root = try a.dupe(u8, std.fs.path.dirname(rec) orelse "/");
    const bytes = sys.readFile(gpa, s.path, 1 << 30) catch |err| switch (err) {
        error.FileNotFound => {
            try applyLog(&s, gpa);
            return s;
        },
        else => return err,
    };
    defer gpa.free(bytes);
    var probe = std.json.parseFromSlice(struct { format_version: i64 }, gpa, bytes, .{ .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) err else error.CorruptState;
    const v = probe.value.format_version;
    probe.deinit();
    if (v < 1 or v > format_version) return error.UnsupportedState;
    s.data = std.json.parseFromSliceLeaky(Data, a, bytes, .{ .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) err else error.CorruptState;
    if (v < 3) try dropDevice(a, &s.data);
    if (v >= 4) try absoluteData(a, s.root, &s.data);
    s.data.format_version = format_version;
    s.json_bytes = bytes.len;
    s.base = try baseOf(a, gpa, s.path);
    try applyLog(&s, gpa);
    return s;
}

fn applyLog(s: *State, gpa: Allocator) !void {
    const a = s.arena.allocator();
    const text = sys.readFile(gpa, s.log_path, 1 << 30) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer gpa.free(text);
    const end = (std.mem.lastIndexOfScalar(u8, text, '\n') orelse return) + 1;
    var lines = std.mem.splitScalar(u8, text[0 .. end - 1], '\n');
    const header = std.json.parseFromSliceLeaky(struct { v: i64, base: []const u8 }, a, lines.first(), .{ .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) err else error.CorruptState;
    if (header.v < 1 or header.v > log_version) return error.UnsupportedState;
    if (!std.mem.eql(u8, header.base, s.base)) return;
    while (lines.next()) |line| {
        const l = std.json.parseFromSliceLeaky(LogLine, a, line, .{ .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) err else error.CorruptState;
        if (l.env) |k| {
            try s.data.envs.map.put(a, k, l.text orelse return error.CorruptState);
        } else if (l.file) |p| {
            try s.data.files.map.put(a, try absolute(a, s.root, p), l.id orelse return error.CorruptState);
        } else if (l.rule) |name| {
            var e = l.entry orelse return error.CorruptState;
            try absoluteEntry(a, s.root, &e);
            try s.data.rules.map.put(a, name, e);
        } else return error.CorruptState;
    }
    s.log_bytes = end;
}

fn baseOf(a: Allocator, gpa: Allocator, path: []const u8) ![]const u8 {
    const id = (try sys.lstat(gpa, path)) orelse return "none";
    return std.fmt.allocPrint(a, "{d}:{d}:{d}:{d}", .{ id.ino, id.size, id.mtime_ns, id.ctime_ns });
}

fn relative(root: []const u8, p: []const u8) []const u8 {
    return workflow.keyPath(root, p);
}

fn absolute(a: Allocator, root: []const u8, p: []const u8) ![]const u8 {
    if (p.len == 0 or std.fs.path.isAbsolute(p)) return p;
    if (std.mem.eql(u8, p, ".")) return root;
    return std.fs.path.join(a, &.{ root, p });
}

fn relativeEntry(a: Allocator, root: []const u8, e: Entry) !Entry {
    var n = e;
    n.attempt = relative(root, e.attempt);
    const outputs = try a.alloc(Output, e.outputs.len);
    for (e.outputs, outputs) |o, *x| x.* = .{ .path = relative(root, o.path), .id = o.id, .sha256 = o.sha256 };
    n.outputs = outputs;
    const input_ids = try a.alloc(InputId, e.input_ids.len);
    for (e.input_ids, input_ids) |iid, *x| x.* = .{ .path = relative(root, iid.path), .id = iid.id };
    n.input_ids = input_ids;
    return n;
}

fn absoluteEntry(a: Allocator, root: []const u8, e: *Entry) !void {
    e.attempt = try absolute(a, root, e.attempt);
    const outputs = try a.dupe(Output, e.outputs);
    for (outputs) |*o| o.path = try absolute(a, root, o.path);
    e.outputs = outputs;
    const input_ids = try a.dupe(InputId, e.input_ids);
    for (input_ids) |*x| x.path = try absolute(a, root, x.path);
    e.input_ids = input_ids;
}

fn relativeData(a: Allocator, root: []const u8, d: *const Data) !Data {
    var out = d.*;
    out.rules = .{};
    for (d.rules.map.keys(), d.rules.map.values()) |name, e| try out.rules.map.put(a, name, try relativeEntry(a, root, e));
    out.files = .{};
    for (d.files.map.keys(), d.files.map.values()) |p, id| try out.files.map.put(a, relative(root, p), id);
    out.manifest = .{};
    for (d.manifest.map.keys(), d.manifest.map.values()) |p, m| try out.manifest.map.put(a, relative(root, p), m);
    return out;
}

fn absoluteData(a: Allocator, root: []const u8, d: *Data) !void {
    for (d.rules.map.values()) |*e| try absoluteEntry(a, root, e);
    var files: std.json.ArrayHashMap([]const u8) = .{};
    for (d.files.map.keys(), d.files.map.values()) |p, id| try files.map.put(a, try absolute(a, root, p), id);
    d.files = files;
    var manifest: std.json.ArrayHashMap(ManifestEntry) = .{};
    for (d.manifest.map.keys(), d.manifest.map.values()) |p, m| try manifest.map.put(a, try absolute(a, root, p), m);
    d.manifest = manifest;
}

fn dropDevice(a: Allocator, d: *Data) !void {
    var i: usize = 0;
    rules: while (i < d.rules.map.count()) {
        const e = &d.rules.map.values()[i];
        const outs = try a.dupe(Output, e.outputs);
        for (outs) |*o| {
            if (std.mem.startsWith(u8, o.id, "dir:")) {
                d.rules.map.orderedRemoveAt(i);
                continue :rules;
            }
            o.id = withoutDevice(o.id);
        }
        e.outputs = outs;
        i += 1;
    }
    for (d.manifest.map.values()) |*m| m.id = withoutDevice(m.id);
}

fn withoutDevice(id: []const u8) []const u8 {
    if (std.mem.count(u8, id, ":") != 4) return id;
    return id[std.mem.indexOfScalar(u8, id, ':').? + 1 ..];
}

pub const Identities = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    memo: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    problem: []const u8 = "",
    env_text: []const u8 = "",
    env_key: []const u8 = "",

    pub fn init(gpa: Allocator) Identities {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Identities) void {
        self.memo.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn forget(self: *Identities, path: []const u8) void {
        _ = self.memo.remove(path);
    }

    pub fn get(self: *Identities, path: []const u8) !?[]const u8 {
        if (self.memo.get(path)) |v| return v;
        const a = self.arena.allocator();
        const key = try a.dupe(u8, path);
        var failed: ?[]u8 = null;
        defer if (failed) |f| self.gpa.free(f);
        const id = identityText(a, self.gpa, path, &failed) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.problem = try std.fmt.allocPrint(a, "cannot read input {s}: {s}", .{ path, try walkErrorText(a, err, failed orelse path) });
                return error.Unreadable;
            },
        };
        try self.memo.put(self.gpa, key, id);
        return id;
    }
};

fn identityText(a: Allocator, gpa: Allocator, path: []const u8, failed: *?[]u8) !?[]const u8 {
    const id = (try sys.stat(gpa, path)) orelse return null;
    if (!id.isDir()) return try std.fmt.allocPrint(a, "{f}", .{id});
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    try walk(gpa, path, path.len, &lines, 0, true, failed);
    std.mem.sort([]u8, lines.items, {}, lessString);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (lines.items) |l| h.update(l);
    return try std.fmt.allocPrint(a, "dir:{s}", .{&std.fmt.bytesToHex(h.finalResult(), .lower)});
}

pub fn walkErrorText(a: Allocator, err: anyerror, path: []const u8) ![]const u8 {
    return switch (err) {
        error.NestedDirectorySymlink => std.fmt.allocPrint(a, "{s} is a symlink to a directory; declare the directory it names as an input of its own", .{path}),
        error.DirectoryTooDeep => std.fmt.allocPrint(a, "{s} nests directories more than 64 levels deep", .{path}),
        else => std.fmt.allocPrint(a, "{s}: {s}", .{ path, sys.errorText(err) }),
    };
}

fn lessString(_: void, x: []u8, y: []u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn walk(gpa: Allocator, dir: []const u8, base_len: usize, lines: *std.ArrayList([]u8), depth: usize, dirs: bool, failed: *?[]u8) !void {
    errdefer if (failed.* == null) {
        failed.* = gpa.dupe(u8, dir) catch null;
    };
    if (depth > 64) return error.DirectoryTooDeep;
    const linux = std.os.linux;
    const p = try sys.z(gpa, dir);
    defer gpa.free(p);
    const fd: sys.Fd = @intCast(try sys.check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0)));
    defer sys.close(fd);
    var entries: sys.DirEntries = .{ .fd = fd };
    while (try entries.next()) |e| {
        const child = try std.fs.path.join(gpa, &.{ dir, e.name });
        defer gpa.free(child);
        const is_dir = e.kind == 4 or (e.kind == 0 and ((try sys.lstat(gpa, child)) orelse continue).isDir());
        if (is_dir) {
            if (std.mem.eql(u8, e.name, ".workz")) continue;
            if (dirs) try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s}/\tdir\n", .{child[base_len..]}));
            try walk(gpa, child, base_len, lines, depth + 1, dirs, failed);
            continue;
        }
        const id = (try sys.stat(gpa, child)) orelse {
            if (dirs) try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s}\tmissing\n", .{child[base_len..]}));
            continue;
        };
        if (id.isDir()) {
            failed.* = try gpa.dupe(u8, child);
            return error.NestedDirectorySymlink;
        }
        try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s}\t{f}\n", .{ child[base_len..], id }));
    }
}

pub fn pageBytes(gpa: Allocator, path: []const u8, failed: *?[]u8) !u64 {
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try listFiles(gpa, path, &files, failed);
    var total: u64 = 0;
    for (files.items) |f| {
        const id = (try sys.stat(gpa, f)) orelse continue;
        if (!id.isReg()) {
            failed.* = try gpa.dupe(u8, f);
            return error.NotRegularFile;
        }
        total += std.mem.alignForward(u64, id.size, 4096);
    }
    return total;
}

pub fn listFiles(gpa: Allocator, path: []const u8, out: *std.ArrayList([]u8), failed: *?[]u8) !void {
    const id = (try sys.stat(gpa, path)) orelse return error.FileNotFound;
    if (!id.isDir()) {
        try out.append(gpa, try gpa.dupe(u8, path));
        return;
    }
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    try walk(gpa, path, path.len, &lines, 0, false, failed);
    for (lines.items) |l| {
        const rel = l[0..std.mem.indexOfScalar(u8, l, '\t').?];
        try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ path, rel }));
    }
}

pub const keyed_env = [_][]const u8{ "PATH", "LANG", "LC_ALL", "TZ" };

pub const passed_env = keyed_env ++ [_][]const u8{ "HOME", "USER", "LOGNAME", "TMPDIR", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "TERM" };

pub fn hostEnv(a: Allocator, environ: *const std.process.Environ.Map, pass_env: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ &passed_env, pass_env }) |names| for (names) |name| if (environ.get(name)) |v| {
        try list.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ name, v }));
    };
    return list.items;
}

pub fn envText(a: Allocator, environ: *const std.process.Environ.Map, pass_env: []const []const u8) ![]const u8 {
    const passed = try a.dupe([]const u8, pass_env);
    std.mem.sort([]const u8, passed, {}, lessConst);
    var w: std.Io.Writer.Allocating = .init(a);
    for ([_][]const []const u8{ &keyed_env, passed }) |names| for (names) |name| {
        if (environ.get(name)) |v| try w.writer.print("{s}={s}\n", .{ name, v }) else try w.writer.print("{s} unset\n", .{name});
    };
    return w.toOwnedSlice();
}

pub const EnvChange = struct { name: []const u8, was: ?[]const u8, now: ?[]const u8, keyed: enum { both, added, dropped } = .both };

pub fn envChanges(a: Allocator, was_text: []const u8, now_text: []const u8) ![]EnvChange {
    var was: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
    var now: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
    for ([_]struct { []const u8, *std.StringArrayHashMapUnmanaged(?[]const u8) }{ .{ was_text, &was }, .{ now_text, &now } }) |pair| {
        var it = std.mem.splitScalar(u8, pair[0], '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                try pair[1].put(a, line[0..eq], line[eq + 1 ..]);
            } else if (std.mem.endsWith(u8, line, " unset")) try pair[1].put(a, line[0 .. line.len - 6], null);
        }
    }
    var out: std.ArrayList(EnvChange) = .empty;
    for (now.keys(), now.values()) |name, v| {
        const w = was.get(name) orelse {
            try out.append(a, .{ .name = name, .was = null, .now = v, .keyed = .added });
            continue;
        };
        const same = if (w == null and v == null) true else if (w == null or v == null) false else std.mem.eql(u8, w.?, v.?);
        if (!same) try out.append(a, .{ .name = name, .was = w, .now = v });
    }
    for (was.keys(), was.values()) |name, w| if (!now.contains(name)) try out.append(a, .{ .name = name, .was = w, .now = null, .keyed = .dropped });
    return out.items;
}

pub fn describeEnvChange(w: *std.Io.Writer, c: EnvChange) !void {
    switch (c.keyed) {
        .added => return if (c.now) |v| w.print("now passed, '{s}'", .{v}) else w.writeAll("now passed, unset"),
        .dropped => return w.writeAll("no longer passed"),
        .both => {},
    }
    if (c.was != null and c.now != null and (std.mem.indexOfScalar(u8, c.was.?, ':') != null or std.mem.indexOfScalar(u8, c.now.?, ':') != null)) {
        var any = false;
        for ([_]struct { []const u8, []const u8, []const u8 }{ .{ c.now.?, c.was.?, "added" }, .{ c.was.?, c.now.?, "removed" } }) |dir| {
            var it = std.mem.splitScalar(u8, dir[0], ':');
            while (it.next()) |entry| {
                var other = std.mem.splitScalar(u8, dir[1], ':');
                const present = while (other.next()) |o| {
                    if (std.mem.eql(u8, o, entry)) break true;
                } else false;
                if (!present) {
                    try w.print("{s}{s} {s}", .{ if (any) ", " else "", dir[2], entry });
                    any = true;
                }
            }
        }
        if (!any) try w.writeAll("same entries in another order");
        return;
    }
    if (c.was) |v| try w.print("was '{s}'", .{v}) else try w.writeAll("was unset");
    if (c.now) |v| try w.print(", now '{s}'", .{v}) else try w.writeAll(", now unset");
}

fn lessConst(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub const Cutoff = struct {
    digests: std.StringHashMapUnmanaged([]const u8) = .empty,
    outputs: []?[]const Output,

    pub fn init(a: Allocator, gpa: Allocator, wf: *const workflow.Workflow, st: *State, ids: *Identities, store: bool) !Cutoff {
        var c: Cutoff = .{ .outputs = try a.alloc(?[]const Output, wf.rules.len) };
        @memset(c.outputs, null);
        var mit = st.data.manifest.map.iterator();
        while (mit.next()) |m| {
            const now = (try ids.get(m.key_ptr.*)) orelse continue;
            if (std.mem.eql(u8, now, m.value_ptr.id)) try c.digests.put(a, m.key_ptr.*, m.value_ptr.sha256);
        }
        for (wf.rules, 0..) |r, i| {
            if (!r.cutoff) continue;
            const e = st.data.rules.map.getPtr(r.name) orelse continue;
            const outs = try st.allocator().dupe(Output, e.outputs);
            var complete = true;
            for (outs) |*o| {
                switch (try checkOutput(gpa, ids, o.*)) {
                    .intact => {},
                    .refreshed => |now| o.id = try st.allocator().dupe(u8, now),
                    .missing, .changed => {
                        complete = false;
                        continue;
                    },
                }
                if (o.sha256 == null) o.sha256 = try st.allocator().dupe(u8, &try sys.sha256File(gpa, o.path));
                try c.digests.put(a, o.path, try std.fmt.allocPrint(a, "sha256:{s}", .{o.sha256.?}));
            }
            if (store) e.outputs = outs;
            if (complete) c.outputs[i] = outs;
        }
        return c;
    }

    pub fn record(self: *Cutoff, a: Allocator, i: usize, outputs: []const Output) !void {
        for (outputs) |o| try self.digests.put(a, o.path, try std.fmt.allocPrint(a, "sha256:{s}", .{o.sha256.?}));
        self.outputs[i] = try a.dupe(Output, outputs);
    }

    pub fn parentKey(self: *const Cutoff, a: Allocator, p: usize, consumer: *const workflow.Rule, rule_key: []const u8) ![]const u8 {
        const outs = self.outputs[p] orelse return rule_key;
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll("cutoff");
        for (outs) |o| {
            const read = for (consumer.input_abs) |in| {
                if (workflow.within(in, o.path)) break true;
            } else false;
            if (read) try w.writer.print(" {s}", .{o.sha256.?});
        }
        return w.written();
    }
};

pub const Key = struct {
    command: []const u8,
    env: []const u8,
    request: []const u8,
    writes: []const u8,
    inputs: []const u8,
    input_ids: []const InputId,
    parents: []const u8,
    engine: []const u8,
    key: []const u8,
};

fn hex(a: Allocator, bytes: []const u8) ![]const u8 {
    return a.dupe(u8, &sys.sha256Bytes(bytes));
}

pub fn requestText(a: Allocator, r: *const workflow.Rule) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("threads={d} memory={s}", .{ r.threads, r.memory_text });
    for (r.groups) |g| try w.writer.print(" group:{s}={d}", .{ g.name, g.count });
    for (r.shared) |s| try w.writer.print(" shared:{s}", .{s});
    return w.toOwnedSlice();
}

pub fn computeKey(
    a: Allocator,
    ids: *Identities,
    r: *const workflow.Rule,
    root: []const u8,
    env_text: []const u8,
    parent_names: []const []const u8,
    parent_keys: []const []const u8,
    engine: []const u8,
    cut: ?*const Cutoff,
    extra: []const u8,
    missing: *?[]const u8,
) !?Key {
    var scratch: std.heap.ArenaAllocator = .init(ids.gpa);
    defer scratch.deinit();
    const t = scratch.allocator();
    var k: Key = undefined;
    var shell: []const u8 = r.shell;
    if (r.workdir != null or r.links.len > 0) {
        var w: std.Io.Writer.Allocating = .init(t);
        try w.writer.writeAll(r.shell);
        if (r.workdir) |d| try w.writer.print("\x00workdir {s}", .{d});
        for (r.links) |l| try w.writer.print("\x00link {s} {s}", .{ l.name, workflow.keyPath(root, l.target_abs) });
        shell = w.written();
    }
    k.command = if (extra.len == 0) try hex(a, shell) else try hex(a, try std.fmt.allocPrint(t, "{s}\x00{s}", .{ shell, extra }));
    if (ids.env_key.len == 0 or !std.mem.eql(u8, ids.env_text, env_text)) {
        ids.env_text = try ids.arena.allocator().dupe(u8, env_text);
        ids.env_key = try hex(ids.arena.allocator(), env_text);
    }
    k.env = try a.dupe(u8, ids.env_key);
    k.request = try requestText(a, r);
    {
        var w: std.Io.Writer.Allocating = .init(t);
        for (r.output) |o| try w.writer.print("out\t{s}\n", .{o});
        if (r.log) |l| try w.writer.print("log\t{s}\n", .{l});
        if (r.benchmark) |b| try w.writer.print("benchmark\t{s}\n", .{b});
        k.writes = try hex(a, w.written());
    }
    {
        var w: std.Io.Writer.Allocating = .init(t);
        const input_ids = try a.alloc(InputId, r.input_abs.len);
        for (r.input_abs, input_ids) |in, *iid| {
            const digest = if (cut) |c| c.digests.get(in) else null;
            const id = digest orelse (try ids.get(in)) orelse {
                missing.* = in;
                return null;
            };
            iid.* = .{ .path = in, .id = id };
            try w.writer.print("{s}\t{s}\n", .{ workflow.keyPath(root, in), id });
        }
        k.inputs = try hex(a, w.written());
        k.input_ids = input_ids;
    }
    {
        var w: std.Io.Writer.Allocating = .init(t);
        for (parent_names, parent_keys) |n, pk| try w.writer.print("{s}\t{s}\n", .{ n, pk });
        k.parents = try hex(a, w.written());
    }
    k.engine = engine;
    var w: std.Io.Writer.Allocating = .init(t);
    try w.writer.print("{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n", .{ k.command, k.env, k.request, k.writes, k.inputs, k.parents, k.engine });
    k.key = try hex(a, w.written());
    return k;
}

pub fn firstDifference(e: *const Entry, k: *const Key) ?[]const u8 {
    if (!std.mem.eql(u8, e.engine, k.engine)) return "engine key";
    if (!std.mem.eql(u8, e.command, k.command)) return "command";
    if (!std.mem.eql(u8, e.env, k.env)) return "environment";
    if (!std.mem.eql(u8, e.request, k.request)) return "resource request";
    if (!std.mem.eql(u8, e.writes, k.writes)) return "declared outputs, log or benchmark";
    if (!std.mem.eql(u8, e.inputs, k.inputs)) return "inputs";
    if (!std.mem.eql(u8, e.parents, k.parents)) return "a producing rule";
    return null;
}

pub const OutputCheck = union(enum) {
    intact,
    refreshed: []const u8,
    missing,
    changed,
};

pub fn checkOutput(gpa: Allocator, ids: *Identities, o: Output) !OutputCheck {
    const now = (try ids.get(o.path)) orelse return .missing;
    if (std.mem.eql(u8, now, o.id)) return .intact;
    const want = o.sha256 orelse return .changed;
    const d = try sys.sha256File(gpa, o.path);
    return if (std.mem.eql(u8, want, &d)) .{ .refreshed = now } else .changed;
}

pub fn ruleKey(
    a: Allocator,
    ids: *Identities,
    wf: *const workflow.Workflow,
    parents: []const usize,
    i: usize,
    st: *const State,
    cut: *const Cutoff,
    launch: anytype,
    env_text: []const u8,
    engine: []const u8,
    extra: []const u8,
    missing: *?[]const u8,
) !?Key {
    const names = try a.alloc([]const u8, parents.len);
    const keys = try a.alloc([]const u8, parents.len);
    for (parents, names, keys) |p, *n, *k| {
        n.* = wf.rules[p].name;
        const recorded = if (st.data.rules.map.get(n.*)) |e| e.key else "none";
        k.* = try cut.parentKey(a, p, &wf.rules[i], launch.get(p) orelse recorded);
    }
    return computeKey(a, ids, &wf.rules[i], wf.root, env_text, names, keys, engine, cut, extra, missing);
}

pub const Reuse = union(enum) {
    reuse,
    key: []const u8,
    output_missing: []const u8,
    output_changed: []const u8,
};

pub fn reuseCheck(gpa: Allocator, ids: *Identities, e: *const Entry, k: *const Key) !Reuse {
    if (firstDifference(e, k)) |part| return .{ .key = part };
    for (e.outputs) |o| switch (try checkOutput(gpa, ids, o)) {
        .intact, .refreshed => {},
        .missing => return .{ .output_missing = o.path },
        .changed => return .{ .output_changed = o.path },
    };
    return .reuse;
}
