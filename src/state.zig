//! Resume state: file identities, rule keys and the versioned `state.json`.
//!
//! A rule is reused when its key matches the recorded key and every recorded
//! output still has its recorded identity. The key covers the command, the
//! search path, the resource request, the written paths, the identities of the
//! inputs, the keys of the producing rules and the engine identity. File
//! contents are read only for the input manifest and explicit verification.
const std = @import("std");
const sys = @import("sys.zig");
const workflow = @import("workflow.zig");
const Allocator = std.mem.Allocator;

pub const format_version: i64 = 1;

/// Version of what a rule key covers. Raise it when the key parts or their
/// encoding change, when what a command starts with changes (shell, flags,
/// working directory, environment, `WORKZ_*` variables), when how outputs are
/// taken or judged complete changes, or when a fix changes the bytes a rule
/// leaves for the same inputs. Raising it reruns every rule once. Scheduling,
/// records, monitoring and speed changes do not raise it.
pub const engine_key: u32 = 1;
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
};

pub const ManifestEntry = struct { id: []const u8, sha256: []const u8 };

pub const Data = struct {
    format_version: i64 = format_version,
    rules: std.json.ArrayHashMap(Entry) = .{},
    /// Last recorded identity of every input and output path, for `explain`.
    files: std.json.ArrayHashMap([]const u8) = .{},
    /// Digest cache for input-manifest files, keyed by path.
    manifest: std.json.ArrayHashMap(ManifestEntry) = .{},
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    data: Data,
    path: []const u8,

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *State) Allocator {
        return self.arena.allocator();
    }

    pub fn save(self: *State, gpa: Allocator) !void {
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.print("{f}\n", .{std.json.fmt(self.data, .{})});
        try sys.writeFileAtomic(gpa, self.path, w.written());
    }
};

pub const LoadError = error{ UnsupportedState, CorruptState };

/// Loads `<records>/state.json`, or returns an empty state when it is absent.
pub fn load(gpa: Allocator, records: []const u8) !State {
    var s: State = .{ .arena = std.heap.ArenaAllocator.init(gpa), .data = .{}, .path = undefined };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    s.path = try std.fs.path.join(a, &.{ records, "state.json" });
    const bytes = sys.readFile(gpa, s.path, 1 << 30) catch |err| switch (err) {
        error.FileNotFound => return s,
        else => return err,
    };
    defer gpa.free(bytes);
    var probe = std.json.parseFromSlice(struct { format_version: i64 }, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.CorruptState;
    const v = probe.value.format_version;
    probe.deinit();
    if (v != format_version) return error.UnsupportedState;
    s.data = std.json.parseFromSliceLeaky(Data, a, bytes, .{ .allocate = .alloc_always }) catch return error.CorruptState;
    return s;
}

/// Identity text of a path: the stat tuple of a file, or a digest over the
/// sorted relative paths and identities of every file below a directory.
/// Each distinct path is examined once per launch.
pub const Identities = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    memo: std.StringHashMapUnmanaged(?[]const u8) = .empty,

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

    pub fn get(self: *Identities, path: []const u8) !?[]const u8 {
        if (self.memo.get(path)) |v| return v;
        const a = self.arena.allocator();
        const key = try a.dupe(u8, path);
        const id = try identityText(a, self.gpa, path);
        try self.memo.put(self.gpa, key, id);
        return id;
    }
};

fn identityText(a: Allocator, gpa: Allocator, path: []const u8) !?[]const u8 {
    const id = (try sys.stat(gpa, path)) orelse return null;
    if (!id.isDir()) return try std.fmt.allocPrint(a, "{f}", .{id});
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    try walk(gpa, path, path.len, &lines, 0);
    std.mem.sort([]u8, lines.items, {}, lessString);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (lines.items) |l| h.update(l);
    return try std.fmt.allocPrint(a, "dir:{s}", .{&std.fmt.bytesToHex(h.finalResult(), .lower)});
}

fn lessString(_: void, x: []u8, y: []u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Collects "relative-path\tidentity\n" for every file below `dir`.
fn walk(gpa: Allocator, dir: []const u8, base_len: usize, lines: *std.ArrayList([]u8), depth: usize) !void {
    if (depth > 64) return error.DirectoryTooDeep;
    const linux = std.os.linux;
    const p = try sys.z(gpa, dir);
    defer gpa.free(p);
    const fd: sys.Fd = @intCast(try sys.check(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0)));
    defer sys.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = try sys.check(linux.getdents64(fd, &buf, buf.len));
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const dtype = buf[off + 18];
            const name = std.mem.sliceTo(buf[off + 19 .. off + reclen], 0);
            off += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const child = try std.fs.path.join(gpa, &.{ dir, name });
            defer gpa.free(child);
            // DT_DIR = 4; DT_UNKNOWN = 0 needs a stat.
            const is_dir = dtype == 4 or (dtype == 0 and ((try sys.lstat(gpa, child)) orelse continue).isDir());
            if (is_dir) {
                try walk(gpa, child, base_len, lines, depth + 1);
            } else {
                const id = (try sys.stat(gpa, child)) orelse continue;
                try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s}\t{f}\n", .{ child[base_len..], id }));
            }
        }
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
    try walk(gpa, path, path.len, &lines, 0);
    for (lines.items) |l| {
        const rel = l[0..std.mem.indexOfScalar(u8, l, '\t').?];
        try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ path, rel }));
    }
}

pub const Key = struct {
    command: []const u8,
    env: []const u8,
    request: []const u8,
    writes: []const u8,
    inputs: []const u8,
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

pub const MissingInput = struct { path: []const u8 };

/// Computes a rule's key. `parent_keys` are the producing rules' keys in
/// `graph.parents` order. Returns null and sets `missing` when an input is absent.
pub fn computeKey(
    a: Allocator,
    ids: *Identities,
    r: *const workflow.Rule,
    path_env: []const u8,
    parent_names: []const []const u8,
    parent_keys: []const []const u8,
    engine: []const u8,
    missing: *?[]const u8,
) !?Key {
    var k: Key = undefined;
    k.command = try hex(a, r.shell);
    k.env = try hex(a, path_env);
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
        for (r.input_abs) |in| {
            const id = (try ids.get(in)) orelse {
                missing.* = in;
                return null;
            };
            try w.writer.print("{s}\t{s}\n", .{ in, id });
        }
        k.inputs = try hex(a, w.written());
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
    if (!std.mem.eql(u8, e.command, k.command)) return "command";
    if (!std.mem.eql(u8, e.env, k.env)) return "PATH";
    if (!std.mem.eql(u8, e.request, k.request)) return "resource request";
    if (!std.mem.eql(u8, e.writes, k.writes)) return "declared outputs, log or benchmark";
    if (!std.mem.eql(u8, e.inputs, k.inputs)) return "inputs";
    if (!std.mem.eql(u8, e.parents, k.parents)) return "a producing rule";
    if (!std.mem.eql(u8, e.engine, k.engine)) return "engine key";
    return null;
}
