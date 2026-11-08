//! Workflow file format 1: parsing with z-toml, strict key checks, and the
//! path, alias and resource rules every workflow must satisfy before a run.
const std = @import("std");
const toml = @import("toml");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

pub const format_version: i64 = 1;

pub const GroupUse = struct { name: []const u8, count: u32 };

pub const Rule = struct {
    line: u32,
    name: []const u8,
    input: []const []const u8,
    input_abs: []const []const u8,
    output: []const []const u8,
    output_abs: []const []const u8,
    shell: []const u8,
    threads: u32,
    memory_mib: u64,
    memory_text: []const u8,
    priority: i64,
    log: ?[]const u8,
    log_abs: ?[]const u8,
    benchmark: ?[]const u8,
    benchmark_abs: ?[]const u8,
    diagnostics: []const []const u8 = &.{},
    diagnostics_abs: []const []const u8 = &.{},
    version: ?[]const u8 = null,
    retries: ?u32,
    timeout_s: ?u64,
    cutoff: bool,
    container: ?[]const u8,
    mounts: []const ImageMount = &.{},
    workdir: ?[]const u8 = null,
    workdir_abs: ?[]const u8 = null,
    links: []const Link = &.{},
    groups: []const GroupUse,
    shared: []const []const u8,
    shared_index: []const usize = &.{},
    labels: Labels = .{ .step = "" },
};

pub const Labels = struct {
    step: []const u8,
    category: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    sample: ?[]const u8 = null,
    declared: Declared = .{},

    pub const Declared = struct { step: bool = false, category: bool = false, tool: bool = false, sample: bool = false };
};

pub const label_keys = [_][]const u8{ "step", "category", "tool", "sample" };

pub fn deriveLabels(name: []const u8, container: ?[]const u8) Labels {
    var l: Labels = .{ .step = name };
    if (std.mem.lastIndexOf(u8, name, "__")) |i| {
        if (i + 2 < name.len) {
            l.step = name[i + 2 ..];
            if (i > 0) l.sample = name[0..i];
        }
    } else if (std.mem.lastIndexOfScalar(u8, name, '_')) |i| {
        if (i > 0) l.step = name[0..i];
    }
    if (container) |image| {
        var repo = image;
        if (std.mem.lastIndexOfScalar(u8, repo, '/')) |i| repo = repo[i + 1 ..];
        if (std.mem.indexOfAny(u8, repo, ":@")) |i| repo = repo[0..i];
        if (repo.len > 0) l.tool = repo;
    }
    return l;
}

fn validLabel(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;
    if ((std.unicode.utf8CountCodepoints(value) catch return false) > 200) return false;
    for (value) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

pub const Link = struct { name: []const u8, target: []const u8, target_abs: []const u8 };

pub const ImageMount = struct { source: []const u8, source_abs: []const u8, target: []const u8 };

pub const Group = struct { name: []const u8, max: u32 };
pub const Shared = struct {
    name: []const u8,
    path: ?[]const u8,
    path_abs: ?[]const u8,
    container: ?[]const u8 = null,
    command: ?[]const u8 = null,
    memory_mib: ?u64 = null,
    timeout_s: ?u64 = null,
    retries: u32 = 0,
    mounts: []const ImageMount = &.{},

    pub fn isService(self: Shared) bool {
        return self.container != null;
    }
};

pub const Workflow = struct {
    arena: std.heap.ArenaAllocator,
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

    pub fn overrideThreads(self: *Workflow, step: []const u8, threads: u32) usize {
        var n: usize = 0;
        for (@constCast(self.rules)) |*r| if (std.mem.eql(u8, r.labels.step, step)) {
            r.threads = threads;
            n += 1;
        };
        return n;
    }

    pub fn ruleIndex(self: *const Workflow, name: []const u8) ?usize {
        for (self.rules, 0..) |r, i| if (std.mem.eql(u8, r.name, name)) return i;
        return null;
    }

    pub fn findRule(self: *const Workflow, token: []const u8) ?usize {
        if (self.ruleIndex(token)) |i| return i;
        var found: ?usize = null;
        for (self.rules, 0..) |r, i| {
            const sample = r.labels.sample orelse continue;
            const step = r.labels.step;
            if (token.len != step.len + 1 + sample.len or token[step.len] != '/') continue;
            if (!std.mem.startsWith(u8, token, step) or !std.mem.endsWith(u8, token, sample)) continue;
            if (found != null) return null;
            found = i;
        }
        return found;
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

pub const Problem = struct {
    message: []u8 = &.{},
    line: u32 = 0,
    col: u32 = 0,
    count: u32 = 0,
    current_line: u32 = 0,

    pub const max_listed = 50;

    pub fn set(self: *Problem, gpa: Allocator, comptime fmt: []const u8, args: anytype) error{ Invalid, OutOfMemory } {
        try self.add(gpa, fmt, args);
        return error.Invalid;
    }

    pub fn add(self: *Problem, gpa: Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        self.count += 1;
        if (self.count == 1 and self.current_line > 0) {
            self.line = self.current_line;
            self.col = 0;
        }
        if (self.count > max_listed) return;
        const msg = try std.fmt.allocPrint(gpa, fmt, args);
        defer gpa.free(msg);
        for (msg) |*ch| if (ch.* < 0x20 or ch.* == 0x7f) {
            ch.* = ' ';
        };
        const entry = if (self.current_line > 0) try std.fmt.allocPrint(gpa, "line {d}: {s}", .{ self.current_line, msg }) else try gpa.dupe(u8, msg);
        if (self.message.len == 0) {
            self.message = entry;
            return;
        }
        defer gpa.free(entry);
        const joined = try std.mem.concat(gpa, u8, &.{ self.message, "\n", entry });
        gpa.free(self.message);
        self.message = joined;
    }
};

pub const top_keys = [_][]const u8{ "workflow", "defaults", "rules", "resource_groups", "shared" };
pub const workflow_keys = [_][]const u8{ "name", "version", "description", "author", "format_version" };
pub const default_keys = [_][]const u8{ "threads", "memory" };
pub const group_keys = [_][]const u8{"max"};
pub const shared_keys = [_][]const u8{ "path", "container", "command", "memory", "timeout", "retries", "mounts" };
pub const rule_keys = [_][]const u8{ "name", "input", "output", "shell", "threads", "memory", "resources", "priority", "log", "benchmark", "retries", "timeout", "cutoff", "container", "mounts", "workdir", "links", "step", "category", "tool", "sample", "diagnostics", "version" };
pub const resource_keys = [_][]const u8{ "threads", "memory", "groups", "shared" };

const Parser = struct {
    gpa: Allocator,
    arena: Allocator,
    source: []const u8,
    spans: *toml.EntrySpanMap,
    headers: *toml.HeaderSpanMap,
    problem: *Problem,
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

    fn line(self: *Parser, path: []const toml.PathSegment) u32 {
        const hp: toml.HintPath = .{ .segments = path };
        if (self.spans.get(hp)) |s| return self.lineAt(s.statement.start);
        if (self.headers.get(hp)) |h| return self.lineAt(h.header.start);
        return 0;
    }

    fn fail(self: *Parser, at: []const toml.PathSegment, comptime fmt: []const u8, args: anytype) error{ Invalid, OutOfMemory } {
        const msg = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(msg);
        self.problem.current_line = self.line(at);
        defer self.problem.current_line = 0;
        return self.problem.set(self.gpa, "{s}", .{msg});
    }

    fn keysNoted(self: *Parser, table: *const toml.Table, allowed: []const []const u8, at: []const toml.PathSegment, where: []const u8) !void {
        self.checkKeys(table, allowed, at, where) catch |err| switch (err) {
            error.Invalid => {},
            else => return err,
        };
    }

    fn checkKeys(self: *Parser, table: *const toml.Table, allowed: []const []const u8, at: []const toml.PathSegment, where: []const u8) !void {
        var it = table.iterator();
        var unknown = false;
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (contains(allowed, key)) continue;
            var path: std.ArrayList(toml.PathSegment) = .empty;
            defer path.deinit(self.gpa);
            try path.appendSlice(self.gpa, at);
            try path.append(self.gpa, .{ .key = key });
            try noted(if (closest(allowed, key)) |hint|
                self.fail(path.items, "unknown key '{s}' in {s}; did you mean '{s}'?", .{ key, where, hint })
            else
                self.fail(path.items, "unknown key '{s}' in {s}", .{ key, where }));
            unknown = true;
        }
        if (unknown) return error.Invalid;
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

    fn imageMounts(self: *Parser, table: *const toml.Table, at: []const toml.PathSegment, what: []const u8, name: []const u8, root: []const u8) ![]const ImageMount {
        const mv = table.get("mounts") orelse return &.{};
        const mt = switch (mv) {
            .table => |tb| tb,
            else => return self.failKey(at, "mounts", "{s} {s}: mounts must be a table of host path = path in the image", .{ what, name }),
        };
        var out: std.ArrayList(ImageMount) = .empty;
        var mit = mt.iterator();
        while (mit.next()) |me| {
            const src = me.key_ptr.*;
            const target = switch (me.value_ptr.*) {
                .string => |s| s,
                else => return self.failKey(at, "mounts", "{s} {s}: the image path for '{s}' must be a string", .{ what, name, src }),
            };
            if (!localPath(src) or std.mem.indexOfAny(u8, src, ":,") != null)
                return self.failKey(at, "mounts", "{s} {s}: invalid mount source '{s}'", .{ what, name, src });
            if (!std.fs.path.isAbsolute(target) or std.mem.eql(u8, target, "/") or std.mem.indexOfAny(u8, target, ":,") != null or hasParentComponent(target))
                return self.failKey(at, "mounts", "{s} {s}: mount target '{s}' must be an absolute path in the image other than /, without ':' or ','", .{ what, name, target });
            try out.append(self.arena, .{ .source = try self.arena.dupe(u8, src), .source_abs = try sys.absolute(self.arena, root, src), .target = try self.arena.dupe(u8, target) });
        }
        return out.items;
    }

    fn failKey(self: *Parser, at: []const toml.PathSegment, key: []const u8, comptime fmt: []const u8, args: anytype) error{ Invalid, OutOfMemory } {
        var path: std.ArrayList(toml.PathSegment) = .empty;
        defer path.deinit(self.gpa);
        try path.appendSlice(self.gpa, at);
        try path.append(self.gpa, .{ .key = key });
        return self.fail(path.items, fmt, args);
    }
};

fn noted(err: error{ Invalid, OutOfMemory }) error{OutOfMemory}!void {
    if (err == error.OutOfMemory) return error.OutOfMemory;
}

fn keep(comptime T: type, x: anyerror!T, default: T) !T {
    return x catch |err| switch (err) {
        error.Invalid => default,
        else => |e| e,
    };
}

fn contains(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

pub fn snippet(w: *std.Io.Writer, source: []const u8, line: u32, col: u32) !void {
    if (line == 0) return;
    var it = std.mem.splitScalar(u8, source, '\n');
    var n: u32 = 1;
    while (it.next()) |text| : (n += 1) {
        if (n != line) continue;
        const shown = text[0..@min(text.len, 200)];
        try w.print("  {d} | {s}\n", .{ n, shown });
        if (col > 0 and col <= shown.len + 1) {
            var gutter: [16]u8 = undefined;
            const width = std.fmt.bufPrint(&gutter, "{d}", .{n}) catch return;
            try w.writeAll("  ");
            for (0..width.len) |_| try w.writeAll(" ");
            try w.writeAll(" | ");
            for (shown[0 .. col - 1]) |c| try w.writeAll(if (c == '\t') "\t" else " ");
            try w.writeAll("^\n");
        }
        return;
    }
}

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

pub const max_memory_mib: u64 = 1 << 30;

pub fn parseMemoryMib(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return null;
    const last = std.ascii.toUpper(t[t.len - 1]);
    const has_unit = std.mem.indexOfScalar(u8, "KMGT", last) != null;
    const digits = if (has_unit) t[0 .. t.len - 1] else t;
    if (!allDigits(digits)) return null;
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    const mib = switch (if (has_unit) last else 'M') {
        'K' => if (n < 1024) return null else std.math.divCeil(u64, n, 1024) catch unreachable,
        'M' => n,
        'G' => std.math.mul(u64, n, 1024) catch return null,
        'T' => std.math.mul(u64, n, 1024 * 1024) catch return null,
        else => unreachable,
    };
    if (mib == 0 or mib > max_memory_mib) return null;
    return mib;
}

pub fn parseDuration(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return null;
    if (allDigits(t)) return if (std.fmt.parseInt(u64, t, 10) catch null) |n| (if (n > 0) n else null) else null;
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

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 161) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
    return true;
}

fn relativeLocal(p: []const u8) bool {
    return localPath(p) and !std.fs.path.isAbsolute(p) and !hasParentComponent(p);
}

pub fn inRecords(root: []const u8, abs: []const u8) bool {
    const rel = if (std.mem.eql(u8, root, "/")) abs else abs[root.len..];
    return std.mem.startsWith(u8, rel, "/.workz/") or std.mem.eql(u8, rel, "/.workz");
}

fn localPath(p: []const u8) bool {
    if (p.len == 0) return false;
    if (std.mem.indexOf(u8, p, "://") != null or std.mem.startsWith(u8, p, "gh:")) return false;
    for (p) |c| switch (c) {
        0...0x1f, 0x7f, '{', '}', '*', '?', '[', ']' => return false,
        else => {},
    };
    return true;
}

pub fn load(gpa: Allocator, path: []const u8, root: []const u8, problem: *Problem) !Workflow {
    var quick: Problem = .{};
    defer gpa.free(quick.message);
    if (loadChecked(gpa, path, root, &quick, true, false)) |wf| return wf else |err| if (err != error.Invalid) return err;
    return loadWithLines(gpa, path, root, problem);
}

pub fn loadWithLines(gpa: Allocator, path: []const u8, root: []const u8, problem: *Problem) !Workflow {
    return loadChecked(gpa, path, root, problem, true, true);
}

pub fn loadRecorded(gpa: Allocator, path: []const u8, root: []const u8, problem: *Problem) !Workflow {
    var quick: Problem = .{};
    defer gpa.free(quick.message);
    if (loadChecked(gpa, path, root, &quick, false, false)) |wf| return wf else |err| if (err != error.Invalid) return err;
    return loadChecked(gpa, path, root, problem, false, true);
}

fn loadChecked(gpa: Allocator, path: []const u8, root: []const u8, problem: *Problem, files: bool, lines: bool) !Workflow {
    const prior = problem.count;
    problem.current_line = 0;
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
    const doc = toml.parseSliceWithSpans(gpa, source, &info, if (lines) &spans else null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            problem.line = @intCast(info.line);
            problem.col = @intCast(info.col);
            return problem.set(gpa, "line {d}, column {d}: {s}", .{ info.line, info.col, info.message() });
        },
    };
    defer toml.deinit(doc, gpa);

    var p: Parser = .{ .gpa = gpa, .arena = arena, .source = source, .spans = &entries, .headers = &headers, .problem = problem };
    try p.keysNoted(doc, &top_keys, &.{}, "the workflow document");

    const meta = switch (doc.get("workflow") orelse return problem.set(gpa, "missing [workflow] table", .{})) {
        .table => |t| t,
        else => return problem.set(gpa, "workflow must be a table", .{}),
    };
    const at_wf = [_]toml.PathSegment{.{ .key = "workflow" }};
    try p.keysNoted(meta, &workflow_keys, &at_wf, "[workflow]");
    wf.name = (try keep(?[]const u8, p.str(meta, "name", &at_wf, "workflow"), "")) orelse name: {
        try noted(p.fail(&at_wf, "workflow.name is required", .{}));
        break :name "";
    };
    if (meta.get("name")) |v| if (v == .string and std.mem.trim(u8, v.string, " \t").len == 0)
        try noted(p.failKey(&at_wf, "name", "workflow.name must not be empty", .{}));
    wf.version = (try keep(?[]const u8, p.str(meta, "version", &at_wf, "workflow"), null)) orelse "";
    if (try p.int(meta, "format_version", &at_wf, "workflow")) |v| {
        if (v != format_version) return p.failKey(&at_wf, "format_version", "workflow format_version {d} is not supported; this engine reads format {d}", .{ v, format_version });
    }

    var default_threads: ?i64 = null;
    var default_memory: ?[]const u8 = null;
    if (doc.get("defaults")) |dv| {
        const d = switch (dv) {
            .table => |t| t,
            else => return problem.set(gpa, "defaults must be a table", .{}),
        };
        const at = [_]toml.PathSegment{.{ .key = "defaults" }};
        try p.keysNoted(d, &default_keys, &at, "[defaults]");
        default_threads = try keep(?i64, p.int(d, "threads", &at, "defaults"), null);
        default_memory = try keep(?[]const u8, p.str(d, "memory", &at, "defaults"), null);
        if (default_threads) |t| if (t < 1 or t > 4096) try noted(p.failKey(&at, "threads", "defaults: threads must be between 1 and 4096", .{}));
        if (default_memory) |m| if (parseMemoryMib(m) == null) try noted(p.failKey(&at, "memory", "defaults: invalid memory '{s}' (use a size from 1M to 1024T, such as 512M or 60G)", .{m}));
    }

    var groups: std.ArrayList(Group) = .empty;
    if (doc.get("resource_groups")) |gv| {
        const gt = switch (gv) {
            .table => |t| t,
            else => return problem.set(gpa, "resource_groups must be a table", .{}),
        };
        var it = gt.iterator();
        while (it.next()) |e| {
            const g = parseGroup(&p, e.key_ptr.*, e.value_ptr.*) catch |err| switch (err) {
                error.Invalid => continue,
                else => return err,
            };
            try groups.append(arena, g);
        }
    }
    wf.groups = groups.items;

    var shared: std.ArrayList(Shared) = .empty;
    if (doc.get("shared")) |sv| {
        const st = switch (sv) {
            .table => |t| t,
            else => return problem.set(gpa, "shared must be a table", .{}),
        };
        var it = st.iterator();
        while (it.next()) |e| {
            const s = parseShared(&p, root, e.key_ptr.*, e.value_ptr.*) catch |err| switch (err) {
                error.Invalid => continue,
                else => return err,
            };
            try shared.append(arena, s);
        }
    }
    wf.shared = shared.items;

    const rules_v = doc.get("rules") orelse return problem.set(gpa, "the workflow declares no [[rules]]", .{});
    const rules_a = switch (rules_v) {
        .array => |a| a,
        else => return problem.set(gpa, "rules must be an array of tables", .{}),
    };
    if (rules_a.items.len == 0) return problem.set(gpa, "the workflow declares no [[rules]]", .{});
    var rules: std.ArrayList(Rule) = .empty;
    for (rules_a.items, 0..) |rv, i| {
        const r = parseRule(&p, &wf, root, default_threads, default_memory, i, rv) catch |err| switch (err) {
            error.Invalid => continue,
            else => return err,
        };
        try rules.append(arena, r);
    }
    if (problem.count > prior) return error.Invalid;
    wf.rules = rules.items;
    try checkRules(gpa, &wf, problem, files);
    for (rules.items) |*r| {
        const idx = try arena.alloc(usize, r.shared.len);
        for (r.shared, idx) |s, *x| x.* = wf.sharedIndex(s).?;
        r.shared_index = idx;
    }
    return wf;
}

fn parseGroup(p: *Parser, name: []const u8, v: toml.Value) !Group {
    const at = [_]toml.PathSegment{ .{ .key = "resource_groups" }, .{ .key = name } };
    const g = switch (v) {
        .table => |t| t,
        else => return p.fail(&at, "resource_groups.{s} must be a table", .{name}),
    };
    if (!validName(name)) return p.fail(&at, "invalid resource group name '{s}': use letters, digits, '_', '.', '-', starting with a letter or digit, at most 161 characters", .{name});
    try p.keysNoted(g, &group_keys, &at, "a resource group");
    const max = (try p.int(g, "max", &at, "resource group")) orelse return p.fail(&at, "resource_groups.{s}.max is required", .{name});
    if (max < 1 or max > 1_000_000) return p.failKey(&at, "max", "resource_groups.{s}.max must be between 1 and 1000000", .{name});
    return .{ .name = try p.arena.dupe(u8, name), .max = @intCast(max) };
}

fn parseShared(p: *Parser, root: []const u8, name: []const u8, v: toml.Value) !Shared {
    const arena = p.arena;
    const at = [_]toml.PathSegment{ .{ .key = "shared" }, .{ .key = name } };
    const s = switch (v) {
        .table => |t| t,
        else => return p.fail(&at, "shared.{s} must be a table", .{name}),
    };
    if (!validName(name)) return p.fail(&at, "invalid shared name '{s}'", .{name});
    try p.keysNoted(s, &shared_keys, &at, "a shared input");
    const sp = try p.str(s, "path", &at, "shared");
    if (sp) |shared_path| if (!localPath(shared_path)) return p.failKey(&at, "path", "shared.{s}.path must be an explicit local path", .{name});
    const image = try p.str(s, "container", &at, "shared");
    const command = try p.str(s, "command", &at, "shared");
    const memory = try p.str(s, "memory", &at, "shared");
    if (image == null) {
        if (sp == null) return p.fail(&at, "shared.{s} needs a path, or a container, command and memory for a service", .{name});
        if (command != null or memory != null) return p.fail(&at, "shared.{s}: command and memory belong to a service, which needs a container", .{name});
    } else {
        if (command == null) return p.failKey(&at, "container", "shared.{s}: a service needs a command", .{name});
        if (memory == null) return p.failKey(&at, "container", "shared.{s}: a service needs the memory it holds", .{name});
    }
    const mib: ?u64 = if (memory) |m| parseMemoryMib(m) orelse return p.failKey(&at, "memory", "shared.{s}: invalid memory '{s}'", .{ name, m }) else null;
    const timeout_s: ?u64 = if (try p.str(s, "timeout", &at, "shared")) |text| blk: {
        if (image == null) return p.failKey(&at, "timeout", "shared.{s}: timeout limits a service's loading, which needs a container", .{name});
        break :blk parseDuration(text) orelse return p.failKey(&at, "timeout", "shared.{s}: invalid timeout '{s}' (use for example \"90s\", \"30m\", \"2h\")", .{ name, text });
    } else null;
    const retries: u32 = if (try p.int(s, "retries", &at, "shared")) |n| blk: {
        if (image == null) return p.failKey(&at, "retries", "shared.{s}: retries start a service again, which needs a container", .{name});
        if (n < 0 or n > 3) return p.failKey(&at, "retries", "shared.{s}: retries must be between 0 and 3", .{name});
        break :blk @intCast(n);
    } else 0;
    const svc_mounts = try p.imageMounts(s, &at, "shared", name, root);
    if (svc_mounts.len > 0 and image == null) return p.failKey(&at, "mounts", "shared.{s}: mounts place host files inside a service's image, which needs a container", .{name});
    return .{
        .name = try arena.dupe(u8, name),
        .path = sp,
        .path_abs = if (sp) |shared_path| try sys.absolute(arena, root, shared_path) else null,
        .container = image,
        .command = command,
        .memory_mib = mib,
        .timeout_s = timeout_s,
        .retries = retries,
        .mounts = svc_mounts,
    };
}

fn parseRule(p: *Parser, wf: *const Workflow, root: []const u8, default_threads: ?i64, default_memory: ?[]const u8, i: usize, rv: toml.Value) !Rule {
    const arena = p.arena;
    const at = [_]toml.PathSegment{ .{ .key = "rules" }, .{ .index = i } };
    const r = switch (rv) {
        .table => |t| t,
        else => return p.fail(&at, "rules[{d}] must be a table", .{i}),
    };
    try p.keysNoted(r, &rule_keys, &at, "a rule");
    const name = (try p.str(r, "name", &at, "rule")) orelse return p.fail(&at, "rule {d} has no name", .{i + 1});
    if (!validName(name)) return p.failKey(&at, "name", "invalid rule name '{s}': use letters, digits, '_', '.', '-', starting with a letter or digit, at most 161 characters", .{name});
    const shell = (try p.str(r, "shell", &at, name)) orelse return p.fail(&at, "rule {s} needs a shell command", .{name});
    if (std.mem.trim(u8, shell, " \t\r\n").len == 0) return p.failKey(&at, "shell", "rule {s}: shell is empty; give the command that writes its outputs", .{name});
    if (std.mem.indexOfScalar(u8, shell, 0) != null) return p.failKey(&at, "shell", "rule {s}: shell holds a NUL byte", .{name});
    var input = try p.strings(r, "input", &at, name);
    const output = try p.strings(r, "output", &at, name);
    const diagnostics = try p.strings(r, "diagnostics", &at, name);
    const version = try p.str(r, "version", &at, name);
    if (version) |v| if (std.mem.trim(u8, v, " \t\n").len == 0) return p.failKey(&at, "version", "rule {s}: version must be a command, such as \"STAR --version\"", .{name});
    const mounts = try p.imageMounts(r, &at, "rule", name, root);
    if (mounts.len > 0) {
        var extra: std.ArrayList([]const u8) = .empty;
        try extra.appendSlice(arena, input);
        for (mounts) |m| {
            const listed = for (extra.items) |in| {
                if (std.mem.eql(u8, in, m.source)) break true;
            } else false;
            if (!listed) try extra.append(arena, m.source);
        }
        input = extra.items;
    }
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
        try p.keysNoted(res, &resource_keys, &res_at, "rule resources");
        if (try p.int(res, "threads", &res_at, name)) |t| threads = t;
        if (try p.str(res, "memory", &res_at, name)) |m| memory = m;
        shared_uses = try p.strings(res, "shared", &res_at, name);
        for (shared_uses, 0..) |s, k| for (shared_uses[0..k]) |earlier| if (std.mem.eql(u8, s, earlier))
            return p.failKey(&res_at, "shared", "rule {s} lists shared input '{s}' twice", .{ name, s });
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
                const units = std.math.cast(u32, count) orelse
                    return p.failKey(&res_at, "groups", "rule {s}: group '{s}' count {d} must be from 1 to the group's max", .{ name, ge.key_ptr.*, count });
                try group_uses.append(arena, .{ .name = try arena.dupe(u8, ge.key_ptr.*), .count = units });
            }
        }
    }
    for (shared_uses) |used| {
        const sh = for (wf.shared) |s| {
            if (std.mem.eql(u8, s.name, used)) break s;
        } else continue;
        if (sh.path) |sp| input = try withInput(arena, root, input, sp, sh.path_abs.?);
        for (sh.mounts) |m| input = try withInput(arena, root, input, m.source, m.source_abs);
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
    const workdir = try p.str(r, "workdir", &at, name);
    var links: std.ArrayList(Link) = .empty;
    if (r.get("links")) |lv| {
        const lt = switch (lv) {
            .table => |tb| tb,
            else => return p.failKey(&at, "links", "rule {s}: links must be a table of name = input path", .{name}),
        };
        if (workdir == null) return p.failKey(&at, "links", "rule {s}: links are made in the rule's workdir, which it does not set", .{name});
        var lit = lt.iterator();
        while (lit.next()) |le| {
            const lname = le.key_ptr.*;
            const target = switch (le.value_ptr.*) {
                .string => |s| s,
                else => return p.failKey(&at, "links", "rule {s}: the target of link '{s}' must be a string", .{ name, lname }),
            };
            if (lname.len == 0 or std.mem.indexOfScalar(u8, lname, '/') != null or std.mem.eql(u8, lname, ".") or std.mem.eql(u8, lname, ".."))
                return p.failKey(&at, "links", "rule {s}: link name '{s}' must be a plain file name", .{ name, lname });
            try links.append(arena, .{ .name = try arena.dupe(u8, lname), .target = try arena.dupe(u8, target), .target_abs = try sys.absolute(arena, root, target) });
        }
    }

    const container = try p.str(r, "container", &at, name);
    var labels = deriveLabels(name, container);
    for (label_keys) |key| if (try p.str(r, key, &at, name)) |value| {
        if (!validLabel(value)) return p.failKey(&at, key, "rule {s}: {s} must be 1 to 200 characters without control characters", .{ name, key });
        if (std.mem.eql(u8, key, "step")) {
            labels.step = value;
            labels.declared.step = true;
        } else if (std.mem.eql(u8, key, "category")) {
            labels.category = value;
            labels.declared.category = true;
        } else if (std.mem.eql(u8, key, "tool")) {
            labels.tool = value;
            labels.declared.tool = true;
        } else {
            labels.sample = value;
            labels.declared.sample = true;
        }
    };

    return .{
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
        .diagnostics = diagnostics,
        .diagnostics_abs = try absAll(arena, root, diagnostics),
        .version = version,
        .retries = retries,
        .timeout_s = timeout_s,
        .cutoff = (try p.boolean(r, "cutoff", &at, name)) orelse false,
        .container = container,
        .mounts = mounts,
        .workdir = workdir,
        .workdir_abs = if (workdir) |d| try sys.absolute(arena, root, d) else null,
        .links = links.items,
        .groups = group_uses.items,
        .shared = shared_uses,
        .labels = labels,
    };
}

fn withInput(arena: Allocator, root: []const u8, input: []const []const u8, path: []const u8, path_abs: []const u8) ![]const []const u8 {
    for (input) |in| if (std.mem.eql(u8, try sys.absolute(arena, root, in), path_abs)) return input;
    const more = try arena.alloc([]const u8, input.len + 1);
    @memcpy(more[0..input.len], input);
    more[input.len] = path;
    return more;
}

fn absAll(arena: Allocator, root: []const u8, paths: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, paths.len);
    for (paths, 0..) |path, i| out[i] = try sys.absolute(arena, root, path);
    return out;
}

pub fn keyPath(root: []const u8, abs: []const u8) []const u8 {
    if (std.mem.eql(u8, root, "/")) return abs;
    if (std.mem.eql(u8, abs, root)) return ".";
    if (abs.len > root.len and std.mem.startsWith(u8, abs, root) and abs[root.len] == '/') return abs[root.len + 1 ..];
    return abs;
}

pub fn within(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/' or std.mem.eql(u8, root, "/");
}

fn checkWritable(gpa: Allocator, wf: *const Workflow, cache: *PathCache, rule: []const u8, written: []const u8, abs: []const u8, problem: *Problem) !void {
    if (!relativeLocal(written))
        return problem.set(gpa, "rule {s}: '{s}' must be a relative path inside the working directory", .{ rule, written });
    if (!within(wf.root, abs)) return problem.set(gpa, "rule {s}: '{s}' leaves the working directory", .{ rule, written });
    if (inRecords(wf.root, abs))
        return problem.set(gpa, "rule {s}: '{s}' is inside the engine record directory", .{ rule, written });
    if (!cache.files) return;
    if (try sys.lstat(gpa, abs)) |id| {
        if (!id.isReg()) return problem.set(gpa, "rule {s}: existing '{s}' must be a regular file", .{ rule, written });
    }
    const parent = std.fs.path.dirname(abs) orelse return;
    const real_root = (try cache.real(wf.root)) orelse return;
    var head = parent;
    while (head.len > wf.root.len and within(wf.root, head)) : (head = std.fs.path.dirname(head) orelse break) {
        if (try cache.real(head) != null) break;
        if (try sys.lstat(gpa, head) != null)
            return problem.set(gpa, "rule {s}: '{s}' passes through a symlinked directory; name it by its real path", .{ rule, written });
    }
    const dest = (try cache.destination(parent)) orelse return;
    defer gpa.free(dest);
    if (!within(real_root, dest)) return problem.set(gpa, "rule {s}: the parent of '{s}' resolves outside the working directory", .{ rule, written });
    if (!sameBelow(wf.root, parent, real_root, dest))
        return problem.set(gpa, "rule {s}: '{s}' passes through a symlinked directory; name it by its real path", .{ rule, written });
}

fn sameBelow(root: []const u8, path: []const u8, real_root: []const u8, real: []const u8) bool {
    if (!within(root, path) or !within(real_root, real)) return false;
    return std.mem.eql(u8, std.mem.trimStart(u8, path[root.len..], "/"), std.mem.trimStart(u8, real[real_root.len..], "/"));
}

fn hasParentComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, "..")) return true;
    return false;
}

const Inode = struct { dev: u64, ino: u64 };

const PathCache = struct {
    gpa: Allocator,
    files: bool = true,
    ids: std.StringHashMapUnmanaged(?sys.Identity) = .empty,
    reals: std.StringHashMapUnmanaged(?[]u8) = .empty,

    fn deinit(self: *PathCache) void {
        var it = self.reals.valueIterator();
        while (it.next()) |v| if (v.*) |s| self.gpa.free(s);
        self.reals.deinit(self.gpa);
        self.ids.deinit(self.gpa);
    }

    fn stat(self: *PathCache, path: []const u8) !?sys.Identity {
        if (!self.files) return null;
        if (self.ids.get(path)) |v| return v;
        const id = try sys.stat(self.gpa, path);
        try self.ids.put(self.gpa, path, id);
        return id;
    }

    fn real(self: *PathCache, path: []const u8) !?[]const u8 {
        if (!self.files) return null;
        if (self.reals.get(path)) |v| return v;
        const r: ?[]u8 = blk: {
            const dir = std.fs.path.dirname(path) orelse break :blk try sys.realpath(self.gpa, path);
            const id = (try sys.lstat(self.gpa, path)) orelse break :blk null;
            if (id.mode & 0o170000 == 0o120000) break :blk try sys.realpath(self.gpa, path);
            if (!self.ids.contains(path)) try self.ids.put(self.gpa, path, id);
            const real_dir = (try self.real(dir)) orelse break :blk null;
            break :blk try std.fs.path.join(self.gpa, &.{ real_dir, std.fs.path.basename(path) });
        };
        errdefer if (r) |x| self.gpa.free(x);
        try self.reals.put(self.gpa, path, r);
        return r;
    }

    fn destination(self: *PathCache, path: []const u8) !?[]u8 {
        var head = path;
        while (true) {
            if (try self.real(head)) |r| {
                const rest = path[head.len..];
                if (std.mem.eql(u8, r, "/") and rest.len > 0) return try self.gpa.dupe(u8, rest);
                return try std.mem.concat(self.gpa, u8, &.{ r, rest });
            }
            head = std.fs.path.dirname(head) orelse return null;
        }
    }
};

fn fileAncestor(gpa: Allocator, problem: *Problem, root: []const u8, files: *const std.StringHashMapUnmanaged([]const u8), sides: *const std.StringHashMapUnmanaged([]const u8), rule: []const u8, what: []const u8, written: []const u8, abs: []const u8) !void {
    var dir = std.fs.path.dirname(abs) orelse return;
    while (dir.len > root.len and within(root, dir)) : (dir = std.fs.path.dirname(dir) orelse return) {
        const owner = files.get(dir) orelse sides.get(dir) orelse continue;
        return problem.add(gpa, "rule {s}: {s}'{s}' needs '{s}' to be a directory, but rule {s} writes that path as a file", .{ rule, what, written, keyPath(root, dir), owner });
    }
}

fn dotDotDiffers(gpa: Allocator, cache: *PathCache, root: []const u8, written: []const u8, abs: []const u8) !bool {
    if (!cache.files) return false;
    var it = std.mem.splitScalar(u8, written, '/');
    var end: ?usize = null;
    var pos: usize = 0;
    while (it.next()) |part| {
        pos += part.len;
        if (std.mem.eql(u8, part, "..")) end = pos;
        pos += 1;
    }
    const cut = end orelse return false;
    const raw = if (std.fs.path.isAbsolute(written)) written[0..cut] else try std.fs.path.join(gpa, &.{ root, written[0..cut] });
    defer if (!std.fs.path.isAbsolute(written)) gpa.free(raw);
    const kernel = (try sys.realpath(gpa, raw)) orelse return false;
    defer gpa.free(kernel);
    const rest = std.mem.trimStart(u8, written[cut..], "/");
    const target = try std.fs.path.join(gpa, &.{ kernel, rest });
    defer gpa.free(target);
    const lexical = (try cache.destination(abs)) orelse return false;
    defer gpa.free(lexical);
    return !std.mem.eql(u8, std.mem.trimEnd(u8, target, "/"), std.mem.trimEnd(u8, lexical, "/"));
}

fn insideInput(gpa: Allocator, problem: *Problem, rule: []const u8, what: []const u8, written: []const u8, abs: []const u8, in_written: []const u8, in: []const u8) !void {
    if (abs.len > in.len and within(in, abs))
        try problem.add(gpa, "rule {s}: {s}'{s}' is inside its directory input '{s}'; write it outside that directory", .{ rule, what, written, in_written });
}

fn checkRules(gpa: Allocator, wf: *const Workflow, problem: *Problem, files: bool) !void {
    const prior = problem.count;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(gpa);
    var outputs: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer outputs.deinit(gpa);
    var side: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer side.deinit(gpa);
    var out_inodes: std.AutoHashMapUnmanaged(Inode, void) = .empty;
    defer out_inodes.deinit(gpa);
    var cache: PathCache = .{ .gpa = gpa, .files = files };
    defer cache.deinit();

    for (wf.rules) |r| {
        problem.current_line = r.line;
        if ((try names.fetchPut(gpa, r.name, {})) != null) {
            try problem.add(gpa, "duplicate rule name '{s}'", .{r.name});
            continue;
        }
        for (r.input) |in| if (!localPath(in))
            try problem.add(gpa, "rule {s}: input '{s}' must be an explicit local path", .{ r.name, in });
        outs: for (r.output, r.output_abs) |out, abs| {
            checkWritable(gpa, wf, &cache, r.name, out, abs, problem) catch |err| switch (err) {
                error.Invalid => continue,
                else => return err,
            };
            if (outputs.get(abs)) |other| {
                if (std.mem.eql(u8, other, r.name))
                    try problem.add(gpa, "rule {s} lists output '{s}' twice", .{ r.name, out })
                else
                    try problem.add(gpa, "rules {s} and {s} both produce '{s}'", .{ other, r.name, out });
                continue;
            }
            try outputs.put(gpa, abs, r.name);
            const out_id = try cache.stat(abs);
            if (out_id) |id| {
                if ((try out_inodes.fetchPut(gpa, .{ .dev = id.dev, .ino = id.ino }, {})) != null) {
                    try problem.add(gpa, "rule {s}: output '{s}' is a hard link to another declared output", .{ r.name, out });
                    continue;
                }
            }
            for (r.input_abs) |in| {
                if (std.mem.eql(u8, in, abs)) {
                    try problem.add(gpa, "rule {s} cannot overwrite its own input '{s}'", .{ r.name, out });
                    continue :outs;
                }
                const b = out_id orelse continue;
                const a = (try cache.stat(in)) orelse continue;
                if (a.dev == b.dev and a.ino == b.ino) {
                    try problem.add(gpa, "rule {s}: input and output '{s}' are the same file", .{ r.name, out });
                    continue :outs;
                }
            }
        }
        for ([_]?[]const u8{ r.log, r.benchmark }, [_]?[]const u8{ r.log_abs, r.benchmark_abs }) |w, a| {
            const written = w orelse continue;
            const abs = a.?;
            checkWritable(gpa, wf, &cache, r.name, written, abs, problem) catch |err| switch (err) {
                error.Invalid => continue,
                else => return err,
            };
            if (side.get(abs)) |other| {
                try problem.add(gpa, "rules {s} and {s} write the same log or benchmark '{s}'", .{ other, r.name, written });
                continue;
            }
            try side.put(gpa, abs, r.name);
        }
        for (r.diagnostics, r.diagnostics_abs, 0..) |written, abs, k| {
            if (!relativeLocal(written))
                try problem.add(gpa, "rule {s}: diagnostics '{s}' must be a relative path inside the working directory", .{ r.name, written })
            else if (inRecords(wf.root, abs))
                try problem.add(gpa, "rule {s}: diagnostics '{s}' is inside the engine record directory", .{ r.name, written })
            else for (r.diagnostics_abs[0..k]) |earlier| {
                if (std.mem.eql(u8, earlier, abs)) {
                    try problem.add(gpa, "rule {s} lists diagnostics '{s}' twice", .{ r.name, written });
                    break;
                }
            }
        }
        for (r.groups) |g| {
            const max = wf.groupMax(g.name) orelse {
                try problem.add(gpa, "rule {s} uses undeclared resource group '{s}'", .{ r.name, g.name });
                continue;
            };
            if (g.count < 1 or g.count > max)
                try problem.add(gpa, "rule {s}: group '{s}' count {d} must be from 1 to the group's max of {d}", .{ r.name, g.name, g.count, max });
        }
        var services: usize = 0;
        for (r.shared) |s| if (wf.sharedIndex(s)) |si| if (wf.shared[si].isService()) {
            services += 1;
            if (r.container == null)
                try problem.add(gpa, "rule {s} uses the shared service '{s}'; only container rules can join a service", .{ r.name, s });
        };
        if (services > 1)
            try problem.add(gpa, "rule {s} uses {d} shared services; a rule can join one", .{ r.name, services });
        if (r.workdir) |d| {
            if (!relativeLocal(d) or !within(wf.root, r.workdir_abs.?) or std.mem.eql(u8, r.workdir_abs.?, wf.root))
                try problem.add(gpa, "rule {s}: workdir '{s}' must be a directory below the working directory", .{ r.name, d })
            else if (inRecords(wf.root, r.workdir_abs.?))
                try problem.add(gpa, "rule {s}: workdir '{s}' is inside the engine record directory", .{ r.name, d })
            else if (try cache.destination(r.workdir_abs.?)) |dest| {
                defer gpa.free(dest);
                const real_root = (try cache.real(wf.root)) orelse wf.root;
                if (!sameBelow(wf.root, r.workdir_abs.?, real_root, dest))
                    try problem.add(gpa, "rule {s}: workdir '{s}' passes through a symlinked directory; name it by its real path", .{ r.name, d });
            }
        }
        own: for (r.input_abs, r.input) |in, in_written| {
            for (r.shared) |name| if (wf.sharedIndex(name)) |si| if (wf.shared[si].path_abs) |p| if (std.mem.eql(u8, p, in)) continue :own;
            for (r.output_abs, r.output) |abs, written| try insideInput(gpa, problem, r.name, "", written, abs, in_written, in);
            if (r.log) |l| try insideInput(gpa, problem, r.name, "", l, r.log_abs.?, in_written, in);
            if (r.benchmark) |b| try insideInput(gpa, problem, r.name, "", b, r.benchmark_abs.?, in_written, in);
            if (r.workdir) |d| try insideInput(gpa, problem, r.name, "workdir ", d, r.workdir_abs.?, in_written, in);
        }
        for (r.links) |l| {
            const is_input = for (r.input_abs) |in| {
                if (std.mem.eql(u8, in, l.target_abs)) break true;
            } else false;
            if (!is_input)
                try problem.add(gpa, "rule {s}: link '{s}' points at '{s}', which is not an input of the rule", .{ r.name, l.name, l.target });
        }
        if (r.mounts.len > 0 and r.container == null)
            try problem.add(gpa, "rule {s} has mounts but no container; mounts place host files inside an image", .{r.name});
        if (r.container) |img| if (img.len == 0 or std.mem.indexOfAny(u8, img, " \t\n") != null)
            try problem.add(gpa, "rule {s}: invalid container image '{s}'", .{ r.name, img });
        for (r.shared) |s| {
            if (wf.sharedIndex(s) != null) continue;
            var names_list: std.ArrayList([]const u8) = .empty;
            defer names_list.deinit(gpa);
            for (wf.shared) |d| try names_list.append(gpa, d.name);
            if (closest(names_list.items, s)) |hint|
                try problem.add(gpa, "rule {s} uses undeclared shared input '{s}'; did you mean '{s}'?", .{ r.name, s, hint })
            else
                try problem.add(gpa, "rule {s} uses undeclared shared input '{s}'", .{ r.name, s });
        }
    }
    problem.current_line = 0;
    var side_inodes: std.AutoHashMapUnmanaged(Inode, []const u8) = .empty;
    defer side_inodes.deinit(gpa);
    var it = side.iterator();
    sides: while (it.next()) |e| {
        problem.current_line = if (wf.ruleIndex(e.value_ptr.*)) |ri| wf.rules[ri].line else 0;
        if (outputs.contains(e.key_ptr.*)) {
            try problem.add(gpa, "rule {s}: a log or benchmark overlaps a declared output", .{e.value_ptr.*});
            continue :sides;
        }
        if (try cache.stat(e.key_ptr.*)) |id| {
            if (out_inodes.contains(.{ .dev = id.dev, .ino = id.ino })) {
                try problem.add(gpa, "rule {s}: a log or benchmark is a hard link to a declared output", .{e.value_ptr.*});
                continue :sides;
            }
            if (try side_inodes.fetchPut(gpa, .{ .dev = id.dev, .ino = id.ino }, e.value_ptr.*)) |other|
                try problem.add(gpa, "rule {s}: a log or benchmark is a hard link to a log or benchmark of rule {s}", .{ e.value_ptr.*, other.value });
        }
    }
    for (wf.rules) |r| {
        problem.current_line = r.line;
        for (r.output_abs, r.output) |abs, written| try fileAncestor(gpa, problem, wf.root, &outputs, &side, r.name, "", written, abs);
        if (r.log) |l| try fileAncestor(gpa, problem, wf.root, &outputs, &side, r.name, "", l, r.log_abs.?);
        if (r.benchmark) |b| try fileAncestor(gpa, problem, wf.root, &outputs, &side, r.name, "", b, r.benchmark_abs.?);
        if (r.workdir) |d| {
            const owner = outputs.get(r.workdir_abs.?) orelse side.get(r.workdir_abs.?);
            if (owner) |o| try problem.add(gpa, "rule {s}: workdir '{s}' is a directory, but rule {s} writes that path as a file", .{ r.name, d, o });
            try fileAncestor(gpa, problem, wf.root, &outputs, &side, r.name, "workdir ", d, r.workdir_abs.?);
        }
    }
    for (wf.rules) |r| {
        problem.current_line = r.line;
        inputs: for (r.input_abs, r.input) |in, written| {
            if (side.get(in)) |w| {
                try problem.add(gpa, "rule {s}: input '{s}' is the log or benchmark of rule {s}", .{ r.name, written, w });
                continue :inputs;
            }
            if (side_inodes.count() > 0) if (try cache.stat(in)) |id| {
                if (side_inodes.get(.{ .dev = id.dev, .ino = id.ino })) |w| {
                    try problem.add(gpa, "rule {s}: input '{s}' is a hard link to the log or benchmark of rule {s}", .{ r.name, written, w });
                    continue :inputs;
                }
            };
            if (try dotDotDiffers(gpa, &cache, wf.root, written, in)) {
                try problem.add(gpa, "rule {s}: input '{s}' names another file than it spells: a '..' follows a symlink; write the path without '..'", .{ r.name, written });
                continue :inputs;
            }
            if (!outputs.contains(in)) if (try cache.destination(in)) |dest| {
                defer gpa.free(dest);
                const real_root = (try cache.real(wf.root)) orelse wf.root;
                if (!within(real_root, dest) or sameBelow(wf.root, in, real_root, dest)) continue :inputs;
                const named = try std.fs.path.join(gpa, &.{ wf.root, dest[real_root.len..] });
                defer gpa.free(named);
                var keys = outputs.keyIterator();
                const reaches = outputs.contains(named) or while (keys.next()) |o| {
                    if (within(named, o.*)) break true;
                } else false;
                if (reaches) {
                    try problem.add(gpa, "rule {s}: declare the producer path instead of the symlink '{s}'", .{ r.name, written });
                    continue :inputs;
                }
            };
        }
    }
    problem.current_line = 0;
    shareds: for (wf.shared) |s| {
        const sp = s.path_abs orelse continue;
        if (s.isService()) continue;
        var oit = outputs.iterator();
        while (oit.next()) |e| {
            if (within(sp, e.key_ptr.*)) {
                try problem.add(gpa, "shared input '{s}' contains the output of rule {s}", .{ s.name, e.value_ptr.* });
                continue :shareds;
            }
        }
    }
    if (problem.count > prior) return error.Invalid;
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
