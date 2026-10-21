//! Workflow file format 1: parsing with z-toml, strict key checks, and the
//! path, alias and resource rules every workflow must satisfy before a run.
const std = @import("std");
const toml = @import("toml");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

pub const format_version: i64 = 1;

pub const GroupUse = struct { name: []const u8, count: u32 };

pub const Rule = struct {
    index: usize,
    line: u32,
    name: []const u8,
    /// Paths as written, and their absolute lexical forms.
    input: []const []const u8,
    input_abs: []const []const u8,
    output: []const []const u8,
    output_abs: []const []const u8,
    shell: []const u8,
    threads: u32,
    memory_mib: u64,
    /// The memory request as written, part of the rule key.
    memory_text: []const u8,
    priority: i64,
    log: ?[]const u8,
    log_abs: ?[]const u8,
    benchmark: ?[]const u8,
    benchmark_abs: ?[]const u8,
    retries: ?u32,
    timeout_s: ?u64,
    /// Hash outputs after success so consumers are reused when they repeat.
    cutoff: bool,
    /// Image the shell command runs in, or null for the host shell.
    container: ?[]const u8,
    groups: []const GroupUse,
    shared: []const []const u8,
};

pub const Group = struct { name: []const u8, max: u32 };
/// A shared input: files mapped once (`path`), or a service container that
/// holds something in memory for its users (`container`, `command`,
/// `memory`, with `path` mounted read-only).
pub const Shared = struct {
    name: []const u8,
    path: ?[]const u8,
    path_abs: ?[]const u8,
    container: ?[]const u8 = null,
    command: ?[]const u8 = null,
    memory_mib: ?u64 = null,

    pub fn isService(self: Shared) bool {
        return self.container != null;
    }
};

pub const Workflow = struct {
    arena: std.heap.ArenaAllocator,
    /// The file's bytes, kept for snapshots and digests.
    source: []const u8,
    path: []const u8,
    root: []const u8,
    name: []const u8,
    version: []const u8,
    groups: []const Group,
    shared: []const Shared,
    rules: []const Rule,

    pub fn deinit(self: *Workflow) void {
        self.arena.deinit();
    }

    pub fn ruleIndex(self: *const Workflow, name: []const u8) ?usize {
        for (self.rules, 0..) |r, i| if (std.mem.eql(u8, r.name, name)) return i;
        return null;
    }

    pub fn groupMax(self: *const Workflow, name: []const u8) ?u32 {
        for (self.groups) |g| if (std.mem.eql(u8, g.name, name)) return g.max;
        return null;
    }

    pub fn sharedIndex(self: *const Workflow, name: []const u8) ?usize {
        for (self.shared, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return i;
        return null;
    }
};

/// A rejected workflow: the message names the line when the source shows it.
pub const Problem = struct {
    message: []u8 = &.{},

    pub fn set(self: *Problem, gpa: Allocator, comptime fmt: []const u8, args: anytype) error{ Invalid, OutOfMemory } {
        self.message = try std.fmt.allocPrint(gpa, fmt, args);
        return error.Invalid;
    }
};

const top_keys = [_][]const u8{ "workflow", "defaults", "rules", "resource_groups", "shared" };
const workflow_keys = [_][]const u8{ "name", "version", "description", "author", "format_version" };
const default_keys = [_][]const u8{ "threads", "memory" };
const group_keys = [_][]const u8{ "max", "wait" };
const shared_keys = [_][]const u8{ "path", "container", "command", "memory" };
const rule_keys = [_][]const u8{ "name", "input", "output", "shell", "threads", "memory", "resources", "priority", "log", "benchmark", "retries", "timeout", "cutoff", "container" };
const resource_keys = [_][]const u8{ "threads", "memory", "groups", "shared" };

const Parser = struct {
    gpa: Allocator,
    arena: Allocator,
    source: []const u8,
    spans: *toml.EntrySpanMap,
    headers: *toml.HeaderSpanMap,
    problem: *Problem,
    /// Line lookups mostly move forward through the file: the last offset
    /// and its line number, so each lookup counts only from there.
    cursor_offset: usize = 0,
    cursor_line: u32 = 1,

    fn lineAt(self: *Parser, offset: usize) u32 {
        const end = @min(offset, self.source.len);
        if (end < self.cursor_offset) {
            self.cursor_offset = 0;
            self.cursor_line = 1;
        }
        self.cursor_line += @intCast(std.mem.count(u8, self.source[self.cursor_offset..end], "\n"));
        self.cursor_offset = end;
        return self.cursor_line;
    }

    /// Line of the entry or header at `path`, or 0 when the source has none.
    fn line(self: *Parser, path: []const toml.PathSegment) u32 {
        const hp: toml.HintPath = .{ .segments = path };
        if (self.spans.get(hp)) |s| return self.lineAt(s.statement.start);
        if (self.headers.get(hp)) |h| return self.lineAt(h.header.start);
        return 0;
    }

    fn fail(self: *Parser, at: []const toml.PathSegment, comptime fmt: []const u8, args: anytype) error{ Invalid, OutOfMemory } {
        const msg = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(msg);
        const l = self.line(at);
        if (l > 0) return self.problem.set(self.gpa, "line {d}: {s}", .{ l, msg });
        return self.problem.set(self.gpa, "{s}", .{msg});
    }

    fn checkKeys(self: *Parser, table: *const toml.Table, allowed: []const []const u8, at: []const toml.PathSegment, where: []const u8) !void {
        var it = table.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (contains(allowed, key)) continue;
            var path: std.ArrayList(toml.PathSegment) = .empty;
            defer path.deinit(self.gpa);
            try path.appendSlice(self.gpa, at);
            try path.append(self.gpa, .{ .key = key });
            if (closest(allowed, key)) |hint|
                return self.fail(path.items, "unknown key '{s}' in {s}; did you mean '{s}'?", .{ key, where, hint });
            return self.fail(path.items, "unknown key '{s}' in {s}", .{ key, where });
        }
    }

    fn str(self: *Parser, table: *const toml.Table, key: []const u8, at: []const toml.PathSegment, where: []const u8) !?[]const u8 {
        const v = table.get(key) orelse return null;
        return switch (v) {
            .string => |s| try self.arena.dupe(u8, s),
            else => self.failKey(at, key, "{s}.{s} must be a string", .{ where, key }),
        };
    }

    fn int(self: *Parser, table: *const toml.Table, key: []const u8, at: []const toml.PathSegment, where: []const u8) !?i64 {
        const v = table.get(key) orelse return null;
        return switch (v) {
            .integer => |i| @intCast(i.value),
            else => self.failKey(at, key, "{s}.{s} must be an integer", .{ where, key }),
        };
    }

    fn boolean(self: *Parser, table: *const toml.Table, key: []const u8, at: []const toml.PathSegment, where: []const u8) !?bool {
        const v = table.get(key) orelse return null;
        return switch (v) {
            .boolean => |b| b,
            else => self.failKey(at, key, "{s}.{s} must be true or false", .{ where, key }),
        };
    }

    fn strings(self: *Parser, table: *const toml.Table, key: []const u8, at: []const toml.PathSegment, where: []const u8) ![]const []const u8 {
        const v = table.get(key) orelse return &.{};
        const arr = switch (v) {
            .array => |a| a,
            else => return self.failKey(at, key, "{s}.{s} must be an array of strings", .{ where, key }),
        };
        const out = try self.arena.alloc([]const u8, arr.items.len);
        for (arr.items, 0..) |item, i| out[i] = switch (item) {
            .string => |s| try self.arena.dupe(u8, s),
            else => return self.failKey(at, key, "{s}.{s} must be an array of strings", .{ where, key }),
        };
        return out;
    }

    fn failKey(self: *Parser, at: []const toml.PathSegment, key: []const u8, comptime fmt: []const u8, args: anytype) error{ Invalid, OutOfMemory } {
        var path: std.ArrayList(toml.PathSegment) = .empty;
        defer path.deinit(self.gpa);
        try path.appendSlice(self.gpa, at);
        try path.append(self.gpa, .{ .key = key });
        return self.fail(path.items, fmt, args);
    }
};

fn contains(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// Allowed key within edit distance 3 of `key`, for hints.
pub fn closest(allowed: []const []const u8, key: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 4;
    for (allowed) |cand| {
        const d = editDistance(cand, key);
        if (d < best_d) {
            best_d = d;
            best = cand;
        }
    }
    return best;
}

pub fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return 64;
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const sub = prev[j] + @intFromBool(ca != cb);
            cur[j + 1] = @min(sub, @min(prev[j + 1] + 1, cur[j] + 1));
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Memory request in MiB: an integer with an optional K, M, G or T suffix;
/// no suffix means MiB.
pub fn parseMemoryMib(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return null;
    const last = std.ascii.toUpper(t[t.len - 1]);
    const has_unit = std.mem.indexOfScalar(u8, "KMGT", last) != null;
    const digits = if (has_unit) t[0 .. t.len - 1] else t;
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    const mib = switch (if (has_unit) last else 'M') {
        'K' => n / 1024,
        'M' => n,
        'G' => std.math.mul(u64, n, 1024) catch return null,
        'T' => std.math.mul(u64, n, 1024 * 1024) catch return null,
        else => unreachable,
    };
    if (mib == 0) return null;
    return mib;
}

/// Duration in seconds: an integer followed by s, m, h or d, possibly
/// repeated ("1h30m"); a bare integer means seconds.
pub fn parseDuration(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return null;
    if (std.fmt.parseInt(u64, t, 10)) |n| return if (n > 0) n else null else |_| {}
    var total: u64 = 0;
    var i: usize = 0;
    while (i < t.len) {
        const start = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        if (i == start or i == t.len) return null;
        const n = std.fmt.parseInt(u64, t[start..i], 10) catch return null;
        const mult: u64 = switch (t[i]) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            else => return null,
        };
        total = std.math.add(u64, total, std.math.mul(u64, n, mult) catch return null) catch return null;
        i += 1;
    }
    return if (total > 0) total else null;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 161) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
    return true;
}

/// Rejects remote, glob and empty paths; workflows name explicit local files.
fn localPath(p: []const u8) bool {
    if (p.len == 0) return false;
    if (std.mem.indexOf(u8, p, "://") != null or std.mem.startsWith(u8, p, "gh:")) return false;
    for (p) |c| switch (c) {
        0...0x1f, 0x7f, '{', '}', '*', '?', '[', ']' => return false,
        else => {},
    };
    return true;
}

/// Parses and checks a workflow file. `root` is the working directory that
/// relative paths resolve against. On error.Invalid, `problem` holds the reason.
pub fn load(gpa: Allocator, path: []const u8, root: []const u8, problem: *Problem) !Workflow {
    var wf: Workflow = undefined;
    wf.arena = std.heap.ArenaAllocator.init(gpa);
    errdefer wf.arena.deinit();
    const arena = wf.arena.allocator();

    const source = sys.readFile(arena, path, 64 << 20) catch |err| switch (err) {
        error.FileNotFound => return problem.set(gpa, "workflow file not found: {s}", .{path}),
        else => return err,
    };
    wf.source = source;
    wf.path = try arena.dupe(u8, path);
    wf.root = try arena.dupe(u8, root);

    var entries: toml.EntrySpanMap = .empty;
    var headers: toml.HeaderSpanMap = .empty;
    var spans: toml.ParseSpans = .{ .entries = &entries, .headers = &headers };
    defer spans.deinit(gpa);
    var info: toml.ErrorInfo = .{};
    const doc = toml.parseSliceWithSpans(gpa, source, &info, &spans) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set(gpa, "line {d}, column {d}: {s}", .{ info.line, info.col, info.message() }),
    };
    defer toml.deinit(doc, gpa);

    var p: Parser = .{ .gpa = gpa, .arena = arena, .source = source, .spans = &entries, .headers = &headers, .problem = problem };
    try p.checkKeys(doc, &top_keys, &.{}, "the workflow document");

    // [workflow]
    const meta = switch (doc.get("workflow") orelse return problem.set(gpa, "missing [workflow] table", .{})) {
        .table => |t| t,
        else => return problem.set(gpa, "workflow must be a table", .{}),
    };
    const at_wf = [_]toml.PathSegment{.{ .key = "workflow" }};
    try p.checkKeys(meta, &workflow_keys, &at_wf, "[workflow]");
    wf.name = (try p.str(meta, "name", &at_wf, "workflow")) orelse return p.fail(&at_wf, "workflow.name is required", .{});
    wf.version = (try p.str(meta, "version", &at_wf, "workflow")) orelse "";
    if (try p.int(meta, "format_version", &at_wf, "workflow")) |v| {
        if (v != format_version) return p.failKey(&at_wf, "format_version", "workflow format_version {d} is not supported; this engine reads format {d}", .{ v, format_version });
    }

    // [defaults]
    var default_threads: ?i64 = null;
    var default_memory: ?[]const u8 = null;
    if (doc.get("defaults")) |dv| {
        const d = switch (dv) {
            .table => |t| t,
            else => return problem.set(gpa, "defaults must be a table", .{}),
        };
        const at = [_]toml.PathSegment{.{ .key = "defaults" }};
        try p.checkKeys(d, &default_keys, &at, "[defaults]");
        default_threads = try p.int(d, "threads", &at, "defaults");
        default_memory = try p.str(d, "memory", &at, "defaults");
    }

    // [resource_groups.*]
    var groups: std.ArrayList(Group) = .empty;
    if (doc.get("resource_groups")) |gv| {
        const gt = switch (gv) {
            .table => |t| t,
            else => return problem.set(gpa, "resource_groups must be a table", .{}),
        };
        var it = gt.iterator();
        while (it.next()) |e| {
            const at = [_]toml.PathSegment{ .{ .key = "resource_groups" }, .{ .key = e.key_ptr.* } };
            const g = switch (e.value_ptr.*) {
                .table => |t| t,
                else => return p.fail(&at, "resource_groups.{s} must be a table", .{e.key_ptr.*}),
            };
            try p.checkKeys(g, &group_keys, &at, "a resource group");
            const max = (try p.int(g, "max", &at, "resource group")) orelse return p.fail(&at, "resource_groups.{s}.max is required", .{e.key_ptr.*});
            if (max < 1 or max > 1_000_000) return p.failKey(&at, "max", "resource_groups.{s}.max must be between 1 and 1000000", .{e.key_ptr.*});
            if (try p.str(g, "wait", &at, "resource group")) |w| {
                if (!std.mem.eql(u8, w, "queue")) return p.failKey(&at, "wait", "resource_groups.{s}.wait must be \"queue\"", .{e.key_ptr.*});
            }
            try groups.append(arena, .{ .name = try arena.dupe(u8, e.key_ptr.*), .max = @intCast(max) });
        }
    }
    wf.groups = groups.items;

    // [shared.*]
    var shared: std.ArrayList(Shared) = .empty;
    if (doc.get("shared")) |sv| {
        const st = switch (sv) {
            .table => |t| t,
            else => return problem.set(gpa, "shared must be a table", .{}),
        };
        var it = st.iterator();
        while (it.next()) |e| {
            const at = [_]toml.PathSegment{ .{ .key = "shared" }, .{ .key = e.key_ptr.* } };
            const s = switch (e.value_ptr.*) {
                .table => |t| t,
                else => return p.fail(&at, "shared.{s} must be a table", .{e.key_ptr.*}),
            };
            if (!validName(e.key_ptr.*)) return p.fail(&at, "invalid shared name '{s}'", .{e.key_ptr.*});
            try p.checkKeys(s, &shared_keys, &at, "a shared input");
            const sp = try p.str(s, "path", &at, "shared");
            if (sp) |shared_path| if (!localPath(shared_path)) return p.failKey(&at, "path", "shared.{s}.path must be an explicit local path", .{e.key_ptr.*});
            const image = try p.str(s, "container", &at, "shared");
            const command = try p.str(s, "command", &at, "shared");
            const memory = try p.str(s, "memory", &at, "shared");
            if (image == null) {
                if (sp == null) return p.fail(&at, "shared.{s} needs a path, or a container, command and memory for a service", .{e.key_ptr.*});
                if (command != null or memory != null) return p.fail(&at, "shared.{s}: command and memory belong to a service, which needs a container", .{e.key_ptr.*});
            } else {
                if (command == null) return p.failKey(&at, "container", "shared.{s}: a service needs a command", .{e.key_ptr.*});
                if (memory == null) return p.failKey(&at, "container", "shared.{s}: a service needs the memory it holds", .{e.key_ptr.*});
            }
            const mib: ?u64 = if (memory) |m| parseMemoryMib(m) orelse return p.failKey(&at, "memory", "shared.{s}: invalid memory '{s}'", .{ e.key_ptr.*, m }) else null;
            try shared.append(arena, .{
                .name = try arena.dupe(u8, e.key_ptr.*),
                .path = sp,
                .path_abs = if (sp) |shared_path| try sys.absolute(arena, root, shared_path) else null,
                .container = image,
                .command = command,
                .memory_mib = mib,
            });
        }
    }
    wf.shared = shared.items;

    // [[rules]]
    const rules_v = doc.get("rules") orelse return problem.set(gpa, "the workflow declares no [[rules]]", .{});
    const rules_a = switch (rules_v) {
        .array => |a| a,
        else => return problem.set(gpa, "rules must be an array of tables", .{}),
    };
    const rules = try arena.alloc(Rule, rules_a.items.len);
    for (rules_a.items, 0..) |rv, i| {
        const at = [_]toml.PathSegment{ .{ .key = "rules" }, .{ .index = i } };
        const r = switch (rv) {
            .table => |t| t,
            else => return p.fail(&at, "rules[{d}] must be a table", .{i}),
        };
        try p.checkKeys(r, &rule_keys, &at, "a rule");
        const name = (try p.str(r, "name", &at, "rule")) orelse return p.fail(&at, "rule {d} has no name", .{i + 1});
        if (!validName(name)) return p.failKey(&at, "name", "invalid rule name '{s}': use letters, digits, '_', '.', '-', starting with a letter or digit, at most 161 characters", .{name});
        const shell = (try p.str(r, "shell", &at, name)) orelse return p.fail(&at, "rule {s} needs a shell command", .{name});
        const input = try p.strings(r, "input", &at, name);
        const output = try p.strings(r, "output", &at, name);
        if (output.len == 0) return p.fail(&at, "rule {s} must declare output files", .{name});

        var threads: ?i64 = try p.int(r, "threads", &at, name);
        var memory: ?[]const u8 = try p.str(r, "memory", &at, name);
        var group_uses: std.ArrayList(GroupUse) = .empty;
        var shared_uses: []const []const u8 = &.{};
        if (r.get("resources")) |resv| {
            const res_at = [_]toml.PathSegment{ .{ .key = "rules" }, .{ .index = i }, .{ .key = "resources" } };
            const res = switch (resv) {
                .table => |t| t,
                else => return p.fail(&res_at, "rule {s}: resources must be a table", .{name}),
            };
            try p.checkKeys(res, &resource_keys, &res_at, "rule resources");
            if (try p.int(res, "threads", &res_at, name)) |t| threads = t;
            if (try p.str(res, "memory", &res_at, name)) |m| memory = m;
            shared_uses = try p.strings(res, "shared", &res_at, name);
            if (res.get("groups")) |gv| {
                const gt = switch (gv) {
                    .table => |t| t,
                    else => return p.failKey(&res_at, "groups", "rule {s}: groups must be a table of counts", .{name}),
                };
                var git = gt.iterator();
                while (git.next()) |ge| {
                    const count = switch (ge.value_ptr.*) {
                        .integer => |n| n.value,
                        else => return p.failKey(&res_at, "groups", "rule {s}: group counts must be integers", .{name}),
                    };
                    try group_uses.append(arena, .{ .name = try arena.dupe(u8, ge.key_ptr.*), .count = std.math.cast(u32, count) orelse 0 });
                }
            }
        }
        if (threads == null) threads = default_threads;
        if (memory == null) memory = default_memory;
        const t = threads orelse 1;
        if (t < 1 or t > 4096) return p.fail(&at, "rule {s}: threads must be between 1 and 4096", .{name});
        const mtext = memory orelse return p.fail(&at, "rule {s} must declare memory", .{name});
        const mib = parseMemoryMib(mtext) orelse return p.fail(&at, "rule {s}: invalid memory '{s}'", .{ name, mtext });
        const priority = (try p.int(r, "priority", &at, name)) orelse 0;
        if (priority < -1_000_000 or priority > 1_000_000) return p.failKey(&at, "priority", "rule {s}: priority must be between -1000000 and 1000000", .{name});
        const retries: ?u32 = if (try p.int(r, "retries", &at, name)) |n| blk: {
            if (n < 0 or n > 3) return p.failKey(&at, "retries", "rule {s}: retries must be between 0 and 3", .{name});
            break :blk @intCast(n);
        } else null;
        const timeout_s: ?u64 = if (try p.str(r, "timeout", &at, name)) |text|
            parseDuration(text) orelse return p.failKey(&at, "timeout", "rule {s}: invalid timeout '{s}' (use for example \"90s\", \"30m\", \"2h\")", .{ name, text })
        else
            null;
        const log = try p.str(r, "log", &at, name);
        const bench = try p.str(r, "benchmark", &at, name);

        rules[i] = .{
            .index = i,
            .line = p.line(&at),
            .name = name,
            .input = input,
            .input_abs = try absAll(arena, root, input),
            .output = output,
            .output_abs = try absAll(arena, root, output),
            .shell = shell,
            .threads = @intCast(t),
            .memory_mib = mib,
            .memory_text = mtext,
            .priority = priority,
            .log = log,
            .log_abs = if (log) |l| try sys.absolute(arena, root, l) else null,
            .benchmark = bench,
            .benchmark_abs = if (bench) |b| try sys.absolute(arena, root, b) else null,
            .retries = retries,
            .timeout_s = timeout_s,
            .cutoff = (try p.boolean(r, "cutoff", &at, name)) orelse false,
            .container = try p.str(r, "container", &at, name),
            .groups = group_uses.items,
            .shared = shared_uses,
        };
    }
    wf.rules = rules;
    try checkRules(gpa, &wf, problem);
    return wf;
}

fn absAll(arena: Allocator, root: []const u8, paths: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, paths.len);
    for (paths, 0..) |path, i| out[i] = try sys.absolute(arena, root, path);
    return out;
}

/// True when `path` is `root` or lies beneath it.
pub fn within(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/' or std.mem.eql(u8, root, "/");
}

/// Writable paths (outputs, logs, benchmarks) must stay inside the working
/// directory, outside the engine's record directory, and must not resolve
/// through a symlinked parent to somewhere else.
fn checkWritable(gpa: Allocator, wf: *const Workflow, cache: *PathCache, rule: []const u8, written: []const u8, abs: []const u8, problem: *Problem) !void {
    if (!localPath(written) or std.fs.path.isAbsolute(written) or hasParentComponent(written))
        return problem.set(gpa, "rule {s}: '{s}' must be a relative path inside the working directory", .{ rule, written });
    if (!within(wf.root, abs)) return problem.set(gpa, "rule {s}: '{s}' leaves the working directory", .{ rule, written });
    const rel = abs[wf.root.len..];
    if (std.mem.startsWith(u8, rel, "/.workz/") or std.mem.eql(u8, rel, "/.workz"))
        return problem.set(gpa, "rule {s}: '{s}' is inside the engine record directory", .{ rule, written });
    if (try sys.lstat(gpa, abs)) |id| {
        if (!id.isReg()) return problem.set(gpa, "rule {s}: existing '{s}' must be a regular file", .{ rule, written });
    }
    // The nearest existing parent must resolve inside the working directory.
    var parent = std.fs.path.dirname(abs) orelse return;
    const real = while (true) {
        if (try cache.real(parent)) |r| break r;
        parent = std.fs.path.dirname(parent) orelse return;
    };
    const real_root = (try cache.real(wf.root)) orelse return;
    if (!within(real_root, real)) return problem.set(gpa, "rule {s}: the parent of '{s}' resolves outside the working directory", .{ rule, written });
}

fn hasParentComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, "..")) return true;
    return false;
}

const Inode = struct { dev: u64, ino: u64 };

/// One stat and one symlink resolution per distinct path while checking.
const PathCache = struct {
    gpa: Allocator,
    ids: std.StringHashMapUnmanaged(?sys.Identity) = .empty,
    reals: std.StringHashMapUnmanaged(?[]u8) = .empty,

    fn deinit(self: *PathCache) void {
        var it = self.reals.valueIterator();
        while (it.next()) |v| if (v.*) |s| self.gpa.free(s);
        self.reals.deinit(self.gpa);
        self.ids.deinit(self.gpa);
    }

    fn stat(self: *PathCache, path: []const u8) !?sys.Identity {
        if (self.ids.get(path)) |v| return v;
        const id = try sys.stat(self.gpa, path);
        try self.ids.put(self.gpa, path, id);
        return id;
    }

    /// The resolved path of an absolute, normalized `path`, or null when it
    /// does not exist. A path whose last component is not a symlink resolves
    /// through its directory, so each directory is resolved once and each
    /// file costs one `statx`.
    fn real(self: *PathCache, path: []const u8) !?[]const u8 {
        if (self.reals.get(path)) |v| return v;
        const r: ?[]u8 = blk: {
            const dir = std.fs.path.dirname(path) orelse break :blk try sys.realpath(self.gpa, path);
            const id = (try sys.lstat(self.gpa, path)) orelse break :blk null;
            if (id.mode & 0o170000 == 0o120000) break :blk try sys.realpath(self.gpa, path);
            // Not a symlink: its identity is also what stat would return.
            if (!self.ids.contains(path)) try self.ids.put(self.gpa, path, id);
            const real_dir = (try self.real(dir)) orelse break :blk null;
            break :blk try std.fs.path.join(self.gpa, &.{ real_dir, std.fs.path.basename(path) });
        };
        try self.reals.put(self.gpa, path, r);
        return r;
    }
};

fn checkRules(gpa: Allocator, wf: *const Workflow, problem: *Problem) !void {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(gpa);
    var outputs: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer outputs.deinit(gpa);
    var side: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer side.deinit(gpa);
    var out_inodes: std.AutoHashMapUnmanaged(Inode, void) = .empty;
    defer out_inodes.deinit(gpa);
    var cache: PathCache = .{ .gpa = gpa };
    defer cache.deinit();

    for (wf.rules) |r| {
        if ((try names.fetchPut(gpa, r.name, {})) != null) return problem.set(gpa, "line {d}: duplicate rule name '{s}'", .{ r.line, r.name });
        for (r.input) |in| if (!localPath(in)) return problem.set(gpa, "rule {s}: input '{s}' must be an explicit local path", .{ r.name, in });
        for (r.output, r.output_abs) |out, abs| {
            try checkWritable(gpa, wf, &cache, r.name, out, abs, problem);
            if (outputs.get(abs)) |other| return problem.set(gpa, "rules {s} and {s} both produce '{s}'", .{ other, r.name, out });
            try outputs.put(gpa, abs, r.name);
            const out_id = try cache.stat(abs);
            if (out_id) |id| {
                if ((try out_inodes.fetchPut(gpa, .{ .dev = id.dev, .ino = id.ino }, {})) != null)
                    return problem.set(gpa, "rule {s}: output '{s}' is a hard link to another declared output", .{ r.name, out });
            }
            for (r.input_abs) |in| {
                if (std.mem.eql(u8, in, abs)) return problem.set(gpa, "rule {s} cannot overwrite its own input '{s}'", .{ r.name, out });
                const b = out_id orelse continue;
                const a = (try cache.stat(in)) orelse continue;
                if (a.dev == b.dev and a.ino == b.ino)
                    return problem.set(gpa, "rule {s}: input and output '{s}' are the same file", .{ r.name, out });
            }
        }
        for ([_]?[]const u8{ r.log, r.benchmark }, [_]?[]const u8{ r.log_abs, r.benchmark_abs }) |w, a| {
            const written = w orelse continue;
            const abs = a.?;
            try checkWritable(gpa, wf, &cache, r.name, written, abs, problem);
            if (side.get(abs)) |other| return problem.set(gpa, "rules {s} and {s} write the same log or benchmark '{s}'", .{ other, r.name, written });
            try side.put(gpa, abs, r.name);
        }
        for (r.groups) |g| {
            const max = wf.groupMax(g.name) orelse return problem.set(gpa, "rule {s} uses undeclared resource group '{s}'", .{ r.name, g.name });
            if (g.count < 1 or g.count > max) return problem.set(gpa, "rule {s}: group '{s}' request {d} cannot fit its capacity {d}", .{ r.name, g.name, g.count, max });
        }
        var services: usize = 0;
        for (r.shared) |s| if (wf.sharedIndex(s)) |si| if (wf.shared[si].isService()) {
            services += 1;
            if (r.container == null) return problem.set(gpa, "rule {s} uses the shared service '{s}'; only container rules can join a service", .{ r.name, s });
        };
        if (services > 1) return problem.set(gpa, "rule {s} uses {d} shared services; a rule can join one", .{ r.name, services });
        if (r.container) |img| if (img.len == 0 or std.mem.indexOfAny(u8, img, " \t\n") != null) return problem.set(gpa, "rule {s}: invalid container image '{s}'", .{ r.name, img });
        for (r.shared) |s| {
            if (wf.sharedIndex(s) == null) {
                var names_list: std.ArrayList([]const u8) = .empty;
                defer names_list.deinit(gpa);
                for (wf.shared) |d| try names_list.append(gpa, d.name);
                if (closest(names_list.items, s)) |hint|
                    return problem.set(gpa, "rule {s} uses undeclared shared input '{s}'; did you mean '{s}'?", .{ r.name, s, hint });
                return problem.set(gpa, "rule {s} uses undeclared shared input '{s}'", .{ r.name, s });
            }
        }
    }
    var side_inodes: std.AutoHashMapUnmanaged(Inode, []const u8) = .empty;
    defer side_inodes.deinit(gpa);
    var it = side.iterator();
    while (it.next()) |e| {
        if (outputs.contains(e.key_ptr.*)) return problem.set(gpa, "rule {s}: a log or benchmark overlaps a declared output", .{e.value_ptr.*});
        if (try cache.stat(e.key_ptr.*)) |id| {
            if (out_inodes.contains(.{ .dev = id.dev, .ino = id.ino }))
                return problem.set(gpa, "rule {s}: a log or benchmark is a hard link to a declared output", .{e.value_ptr.*});
            try side_inodes.put(gpa, .{ .dev = id.dev, .ino = id.ino }, e.value_ptr.*);
        }
    }
    for (wf.rules) |r| {
        for (r.input_abs, r.input) |in, written| {
            if (side.get(in)) |w| return problem.set(gpa, "rule {s}: input '{s}' is the log or benchmark of rule {s}", .{ r.name, written, w });
            if (side_inodes.count() > 0) if (try cache.stat(in)) |id| {
                if (side_inodes.get(.{ .dev = id.dev, .ino = id.ino })) |w|
                    return problem.set(gpa, "rule {s}: input '{s}' is a hard link to the log or benchmark of rule {s}", .{ r.name, written, w });
            };
            // An input that is a symlink to a declared output must name the producer path.
            if (!outputs.contains(in)) {
                if (try cache.real(in)) |real| {
                    if (outputs.contains(real)) return problem.set(gpa, "rule {s}: declare the producer path instead of the symlink '{s}'", .{ r.name, written });
                }
            }
        }
    }
    // Mapped files are measured at launch, so they cannot be produced by the
    // run; a service's files can (the graph checks its users' order).
    for (wf.shared) |s| {
        const sp = s.path_abs orelse continue;
        if (s.isService()) continue;
        var oit = outputs.iterator();
        while (oit.next()) |e| {
            if (within(sp, e.key_ptr.*)) return problem.set(gpa, "shared input '{s}' contains the output of rule {s}", .{ s.name, e.value_ptr.* });
        }
    }
}
