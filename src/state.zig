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

/// Format 2 adds the recorded environments, format 3 records file
/// identities without the device number, and format 4 writes paths inside
/// the working directory relative to it, so a moved project keeps its
/// records. Older files are read as the current format (`dropDevice`; their
/// paths are absolute).
pub const format_version: i64 = 4;

/// Version of what a rule key covers. Raise it when the key parts or their
/// encoding change, when what a command starts with changes (shell, flags,
/// working directory, environment, `WORKZ_*` variables), when how outputs are
/// taken or judged complete changes, or when a fix changes the bytes a rule
/// leaves for the same inputs. Raising it reruns every rule once. Scheduling,
/// records, monitoring and speed changes do not raise it.
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
    /// Wall seconds of the recorded attempt; ranks ready rules by the work
    /// that follows them. 0 when unknown.
    wall_s: f64 = 0,
    /// Each input as the key saw it: its content digest where one is
    /// stored, else its identity; for `explain`. Empty in older records.
    input_ids: []const InputId = &.{},
};

pub const InputId = struct { path: []const u8, id: []const u8 };

pub const ManifestEntry = struct { id: []const u8, sha256: []const u8 };

pub const Data = struct {
    format_version: i64 = format_version,
    rules: std.json.ArrayHashMap(Entry) = .{},
    /// Last recorded identity of every input and output path, for `explain`.
    files: std.json.ArrayHashMap([]const u8) = .{},
    /// Digest cache for input-manifest files, keyed by path.
    manifest: std.json.ArrayHashMap(ManifestEntry) = .{},
    /// Keyed environment text (`envText`) by its key part, for each
    /// environment a recorded rule ran in, so `explain` can name what changed.
    envs: std.json.ArrayHashMap([]const u8) = .{},
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    data: Data,
    path: []const u8,
    /// The working directory, which relative paths in the file are under.
    root: []const u8,

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *State) Allocator {
        return self.arena.allocator();
    }

    pub fn save(self: *State, gpa: Allocator) !void {
        // Only environments some recorded rule still refers to are kept.
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
    }
};

/// `state.json` as the next launch decides from it: a rule that an
/// interrupted launch dispatched without saving its result has no record,
/// so it runs again. `clean` reads the plain file instead, to keep every
/// launch that a record names.
pub fn loadRecorded(gpa: Allocator, a: Allocator, rec: []const u8) !State {
    var st = try load(gpa, rec);
    errdefer st.deinit();
    for (try records.Journal.unfinished(gpa, a, rec)) |name| _ = st.data.rules.map.swapRemove(name);
    return st;
}

/// Why the state file at `path` cannot be used, and what to do, for a
/// `load` error; null for any other error.
pub fn loadErrorText(a: Allocator, err: anyerror, path: []const u8) !?[]const u8 {
    return switch (err) {
        error.CorruptState => try std.fmt.allocPrint(a, "{s} cannot be read: it is not a valid workz state; move it aside, and the next launch runs every rule", .{path}),
        error.UnsupportedState => try std.fmt.allocPrint(a, "{s} has a format version this workz cannot read; use the workz that wrote it, or move it aside, and the next launch runs every rule", .{path}),
        else => null,
    };
}

/// Loads `<rec>/state.json`, or returns an empty state when it is absent.
pub fn load(gpa: Allocator, rec: []const u8) !State {
    var s: State = .{ .arena = std.heap.ArenaAllocator.init(gpa), .data = .{}, .path = undefined, .root = undefined };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    s.path = try std.fs.path.join(a, &.{ rec, "state.json" });
    s.root = try a.dupe(u8, std.fs.path.dirname(rec) orelse "/");
    const bytes = sys.readFile(gpa, s.path, 1 << 30) catch |err| switch (err) {
        error.FileNotFound => return s,
        else => return err,
    };
    defer gpa.free(bytes);
    var probe = std.json.parseFromSlice(struct { format_version: i64 }, gpa, bytes, .{ .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) err else error.CorruptState;
    const v = probe.value.format_version;
    probe.deinit();
    if (v < 1 or v > format_version) return error.UnsupportedState;
    // Running out of memory is not a damaged file.
    s.data = std.json.parseFromSliceLeaky(Data, a, bytes, .{ .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) err else error.CorruptState;
    // Format 1 lacks `envs`, which this engine adds as rules run; formats 1
    // and 2 record identities with the device number. Once read, the file
    // is saved as the current format.
    if (v < 3) try dropDevice(a, &s.data);
    if (v >= 4) try absoluteData(a, s.root, &s.data);
    s.data.format_version = format_version;
    return s;
}

/// Formats 1 and 2 record a file's identity with the device number first,
/// `dev:ino:size:mtime_ns:ctime_ns`; recorded outputs and manifest entries
/// are read without it. A directory's identity is a digest over the
/// identities of its files in that form and cannot be read again, so a rule
/// that wrote a directory loses its record and runs again. The `files` map
/// keeps the old text: `explain` shows it as the identity that was.
/// A path as `state.json` writes it: relative to the working directory when
/// inside it, else absolute.
fn relative(root: []const u8, p: []const u8) []const u8 {
    return workflow.keyPath(root, p);
}

/// A path as `state.json` wrote it, made absolute again.
fn absolute(a: Allocator, root: []const u8, p: []const u8) ![]const u8 {
    if (p.len == 0 or std.fs.path.isAbsolute(p)) return p;
    if (std.mem.eql(u8, p, ".")) return root;
    return std.fs.path.join(a, &.{ root, p });
}

/// A copy of `d` with its paths as `state.json` writes them.
fn relativeData(a: Allocator, root: []const u8, d: *const Data) !Data {
    var out = d.*;
    out.rules = .{};
    for (d.rules.map.keys(), d.rules.map.values()) |name, e| {
        var n = e;
        n.attempt = relative(root, e.attempt);
        const outputs = try a.alloc(Output, e.outputs.len);
        for (e.outputs, outputs) |o, *x| x.* = .{ .path = relative(root, o.path), .id = o.id, .sha256 = o.sha256 };
        n.outputs = outputs;
        const input_ids = try a.alloc(InputId, e.input_ids.len);
        for (e.input_ids, input_ids) |iid, *x| x.* = .{ .path = relative(root, iid.path), .id = iid.id };
        n.input_ids = input_ids;
        try out.rules.map.put(a, name, n);
    }
    out.files = .{};
    for (d.files.map.keys(), d.files.map.values()) |p, id| try out.files.map.put(a, relative(root, p), id);
    out.manifest = .{};
    for (d.manifest.map.keys(), d.manifest.map.values()) |p, m| try out.manifest.map.put(a, relative(root, p), m);
    return out;
}

/// Makes the relative paths of a format 4 file absolute under `root`.
fn absoluteData(a: Allocator, root: []const u8, d: *Data) !void {
    for (d.rules.map.values()) |*e| {
        e.attempt = try absolute(a, root, e.attempt);
        const outputs = try a.dupe(Output, e.outputs);
        for (outputs) |*o| o.path = try absolute(a, root, o.path);
        e.outputs = outputs;
        const input_ids = try a.dupe(InputId, e.input_ids);
        for (input_ids) |*x| x.path = try absolute(a, root, x.path);
        e.input_ids = input_ids;
    }
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

/// Identity text of a path: the stat tuple of a file, or a digest over the
/// sorted relative paths and identities of every entry below a directory.
/// Each distinct path is examined once per launch.
pub const Identities = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    memo: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// Why the last `get` returned `error.Unreadable`, naming the input and
    /// the entry below it that failed. Lives as long as the memo.
    problem: []const u8 = "",

    pub fn init(gpa: Allocator) Identities {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Identities) void {
        self.memo.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Drops a memoized path, after a rule rewrites it.
    pub fn forget(self: *Identities, path: []const u8) void {
        _ = self.memo.remove(path);
    }

    /// The identity of `path`, or null when it does not exist. A directory
    /// that cannot be read, or that holds a symlink to a directory, returns
    /// `error.Unreadable` and sets `problem`.
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

/// What went wrong at `path` while walking a directory, for a person.
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

/// Collects "relative-path\tidentity\n" for every entry below `dir`: a
/// file's identity, `dir` for a directory, so that empty ones count, and
/// `missing` for a dangling symlink. With `dirs` false it lists files only.
/// Record directories (`.workz`) are left out: the engine writes into them
/// while rules run. A symlink to a directory is refused, since its target's
/// contents would go unrecorded. On an error, `failed` names the entry.
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
        // A file system that gives no type needs a stat.
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

/// Total bytes of a file or of every file below a directory, each rounded
/// up to whole 4 KiB pages; used to reserve shared inputs.
pub fn pageBytes(gpa: Allocator, path: []const u8) !u64 {
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try listFiles(gpa, path, &files);
    var total: u64 = 0;
    for (files.items) |f| {
        const id = (try sys.stat(gpa, f)) orelse continue;
        total += std.mem.alignForward(u64, id.size, 4096);
    }
    return total;
}

/// Every regular file at or below `path`.
pub fn listFiles(gpa: Allocator, path: []const u8, out: *std.ArrayList([]u8)) !void {
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
    var failed: ?[]u8 = null;
    defer if (failed) |f| gpa.free(f);
    try walk(gpa, path, path.len, &lines, 0, false, &failed);
    for (lines.items) |l| {
        const rel = l[0..std.mem.indexOfScalar(u8, l, '\t').?];
        try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ path, rel }));
    }
}

/// Environment variables that can change a command's output and so belong
/// to the rule key. Session variables (HOME, USER, TERM, XDG_RUNTIME_DIR,
/// DBUS_SESSION_BUS_ADDRESS) and TMPDIR are passed to rules but not keyed.
pub const keyed_env = [_][]const u8{ "PATH", "LANG", "LC_ALL", "TZ" };

/// Variables host rules and Podman receive: the keyed ones and the session
/// variables. Names given with --pass-env are added to them.
pub const passed_env = keyed_env ++ [_][]const u8{ "HOME", "USER", "LOGNAME", "TMPDIR", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "TERM" };

/// The environment of host rules and of Podman, as NAME=VALUE: each of
/// `passed_env` and of `pass_env` that is set.
pub fn hostEnv(a: Allocator, environ: *const std.process.Environ.Map, pass_env: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ &passed_env, pass_env }) |names| for (names) |name| if (environ.get(name)) |v| {
        try list.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ name, v }));
    };
    return list.items;
}

/// The environment part of rule keys: each keyed variable and each name
/// passed with --pass-env (sorted), with its value or as unset.
pub fn envText(a: Allocator, environ: *const std.process.Environ.Map, pass_env: []const []const u8) ![]const u8 {
    const passed = try a.dupe([]const u8, pass_env);
    std.mem.sort([]const u8, passed, {}, lessConst);
    var w: std.Io.Writer.Allocating = .init(a);
    for ([_][]const []const u8{ &keyed_env, passed }) |names| for (names) |name| {
        if (environ.get(name)) |v| try w.writer.print("{s}={s}\n", .{ name, v }) else try w.writer.print("{s} unset\n", .{name});
    };
    return w.toOwnedSlice();
}

/// One variable of the keyed environment that differs between two
/// `envText` texts: `was` or `now` is null when the variable is unset;
/// `keyed` says whether it was and is part of the key (a passed name).
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

/// Describes one change: entries added to or removed from a colon list
/// such as PATH, or the old and new values.
pub fn describeEnvChange(w: *std.Io.Writer, c: EnvChange) !void {
    switch (c.keyed) {
        .added => return if (c.now) |v| w.print("now passed, '{s}'", .{v}) else w.writeAll("now passed, unset"),
        .dropped => return w.writeAll("no longer passed"),
        .both => {},
    }
    // A list such as PATH on either side is described entry by entry.
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

/// Content-keyed files. Inputs listed in the input manifest and outputs of
/// rules marked `cutoff = true` are keyed on their SHA-256 digest; their
/// identity only decides when the digest must be computed again. A touched
/// or copied-back file with the same bytes therefore keeps every key.
///
/// Early cutoff. A rule marked `cutoff = true` has its outputs hashed after
/// success. A consumer then keys such an input on its content digest, and the
/// producer contributes its output digests instead of its rule key, so a
/// producer that reruns and writes the same bytes leaves its consumers reused.
/// A digest is used only while the file's identity equals the recorded one.
pub const Cutoff = struct {
    /// Output path to "sha256:<hex>".
    digests: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Per rule: what a cutoff producer contributes to its consumers' keys.
    parent: []?[]const u8,

    /// Builds the view from the recorded state. Outputs recorded without a
    /// digest are hashed once; with `store`, the digest is kept in the state.
    pub fn init(a: Allocator, gpa: Allocator, wf: *const workflow.Workflow, st: *State, ids: *Identities, store: bool) !Cutoff {
        var c: Cutoff = .{ .parent = try a.alloc(?[]const u8, wf.rules.len) };
        @memset(c.parent, null);
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
                const now = (try ids.get(o.path)) orelse {
                    complete = false;
                    continue;
                };
                if (!std.mem.eql(u8, now, o.id)) {
                    complete = false;
                    continue;
                }
                if (o.sha256 == null) o.sha256 = try st.allocator().dupe(u8, &try sys.sha256File(gpa, o.path));
                try c.digests.put(a, o.path, try std.fmt.allocPrint(a, "sha256:{s}", .{o.sha256.?}));
            }
            if (store) e.outputs = outs;
            if (complete) c.parent[i] = try parentText(a, outs);
        }
        return c;
    }

    /// Records the digests of a cutoff rule that just completed.
    pub fn record(self: *Cutoff, a: Allocator, i: usize, outputs: []const Output) !void {
        for (outputs) |o| try self.digests.put(a, o.path, try std.fmt.allocPrint(a, "sha256:{s}", .{o.sha256.?}));
        self.parent[i] = try parentText(a, outputs);
    }

    /// A producer's contribution to a consumer's key.
    pub fn parentKey(self: *const Cutoff, i: usize, rule_key: []const u8) []const u8 {
        return self.parent[i] orelse rule_key;
    }
};

fn parentText(a: Allocator, outputs: []const Output) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("cutoff");
    for (outputs) |o| try w.writer.print(" {s}", .{o.sha256.?});
    return w.toOwnedSlice();
}

pub const Key = struct {
    command: []const u8,
    env: []const u8,
    request: []const u8,
    writes: []const u8,
    inputs: []const u8,
    /// What `inputs` covers, one entry per input in `input_abs` order.
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

/// Computes a rule's key. `parent_keys` are the producing rules' keys in
/// `graph.parents` order. Returns null and sets `missing` when an input is absent.
pub fn computeKey(
    a: Allocator,
    ids: *Identities,
    r: *const workflow.Rule,
    /// The working directory: paths inside it enter the key relative to it.
    root: []const u8,
    env_text: []const u8,
    parent_names: []const []const u8,
    parent_keys: []const []const u8,
    engine: []const u8,
    cut: ?*const Cutoff,
    /// What else decides the command's result: a container rule's image ID
    /// and its shared service; empty for host rules.
    extra: []const u8,
    missing: *?[]const u8,
) !?Key {
    var k: Key = undefined;
    // A workdir and links are part of the command; without them the text
    // is the shell alone.
    var shell: []const u8 = r.shell;
    if (r.workdir != null or r.links.len > 0) {
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll(r.shell);
        if (r.workdir) |d| try w.writer.print("\x00workdir {s}", .{d});
        for (r.links) |l| try w.writer.print("\x00link {s} {s}", .{ l.name, workflow.keyPath(root, l.target_abs) });
        shell = w.written();
    }
    if (extra.len == 0) {
        k.command = try hex(a, shell);
    } else {
        const text = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ shell, extra });
        k.command = try hex(a, text);
    }
    k.env = try hex(a, env_text);
    k.request = try requestText(a, r);
    {
        var w: std.Io.Writer.Allocating = .init(a);
        defer w.deinit();
        for (r.output) |o| try w.writer.print("out\t{s}\n", .{o});
        if (r.log) |l| try w.writer.print("log\t{s}\n", .{l});
        if (r.benchmark) |b| try w.writer.print("benchmark\t{s}\n", .{b});
        k.writes = try hex(a, w.written());
    }
    {
        var w: std.Io.Writer.Allocating = .init(a);
        defer w.deinit();
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
        var w: std.Io.Writer.Allocating = .init(a);
        defer w.deinit();
        for (parent_names, parent_keys) |n, pk| try w.writer.print("{s}\t{s}\n", .{ n, pk });
        k.parents = try hex(a, w.written());
    }
    k.engine = engine;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    try w.writer.print("{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n", .{ k.command, k.env, k.request, k.writes, k.inputs, k.parents, k.engine });
    k.key = try hex(a, w.written());
    return k;
}

/// The first differing key part between a recorded entry and a new key.
pub fn firstDifference(e: *const Entry, k: *const Key) ?[]const u8 {
    // Another engine key encodes the other parts differently: it alone
    // explains the difference.
    if (!std.mem.eql(u8, e.engine, k.engine)) return "engine key";
    if (!std.mem.eql(u8, e.command, k.command)) return "command";
    if (!std.mem.eql(u8, e.env, k.env)) return "environment";
    if (!std.mem.eql(u8, e.request, k.request)) return "resource request";
    if (!std.mem.eql(u8, e.writes, k.writes)) return "declared outputs, log or benchmark";
    if (!std.mem.eql(u8, e.inputs, k.inputs)) return "inputs";
    if (!std.mem.eql(u8, e.parents, k.parents)) return "a producing rule";
    return null;
}

/// What became of a recorded output.
pub const OutputCheck = union(enum) {
    /// The file has the identity recorded for it.
    intact,
    /// Its identity changed but its bytes still match the stored digest;
    /// the payload is the identity to record.
    refreshed: []const u8,
    missing,
    changed,
};

/// Whether a recorded output is still the file its rule wrote: the recorded
/// identity, or, for an output with a stored digest, the same bytes. Reads
/// the file only when its identity differs and a digest is stored.
pub fn checkOutput(gpa: Allocator, ids: *Identities, o: Output) !OutputCheck {
    const now = (try ids.get(o.path)) orelse return .missing;
    if (std.mem.eql(u8, now, o.id)) return .intact;
    const want = o.sha256 orelse return .changed;
    const d = try sys.sha256File(gpa, o.path);
    return if (std.mem.eql(u8, want, &d)) .{ .refreshed = now } else .changed;
}

/// The key of rule `i`. Each producer contributes the key it has in this
/// launch (`launch.get(p)`), else its recorded key, else "none"; a cutoff
/// producer contributes the digests of its outputs instead.
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
        k.* = cut.parentKey(p, launch.get(p) orelse recorded);
    }
    return computeKey(a, ids, &wf.rules[i], wf.root, env_text, names, keys, engine, cut, extra, missing);
}

/// Why a recorded rule cannot be reused with key `k`, or `.reuse`.
pub const Reuse = union(enum) {
    reuse,
    /// The first key part that differs, as `firstDifference` names it.
    key: []const u8,
    output_missing: []const u8,
    output_changed: []const u8,
};

/// The reuse decision `plan` reports and `run` acts on: the same key, and
/// every recorded output intact (`checkOutput`).
pub fn reuseCheck(gpa: Allocator, ids: *Identities, e: *const Entry, k: *const Key) !Reuse {
    if (firstDifference(e, k)) |part| return .{ .key = part };
    for (e.outputs) |o| switch (try checkOutput(gpa, ids, o)) {
        .intact, .refreshed => {},
        .missing => return .{ .output_missing = o.path },
        .changed => return .{ .output_changed = o.path },
    };
    return .reuse;
}
