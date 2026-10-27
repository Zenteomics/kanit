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
    /// Files the command writes about its own failure, such as a tool's own
    /// log; their tails are kept with a failed attempt. Not part of the key.
    diagnostics: []const []const u8 = &.{},
    diagnostics_abs: []const []const u8 = &.{},
    /// A command that prints the version of the rule's tool, run once per
    /// launch in the rule's image or on the host; not part of the key.
    version: ?[]const u8 = null,
    retries: ?u32,
    timeout_s: ?u64,
    /// Hash outputs after success so consumers are reused when they repeat.
    cutoff: bool,
    /// Image the shell command runs in, or null for the host shell.
    container: ?[]const u8,
    /// Host files or directories mounted read-only over paths in the image.
    /// Their sources are also inputs of the rule.
    mounts: []const ImageMount = &.{},
    /// Directory the command runs in, inside the working directory, made
    /// before each attempt; paths stay relative to the working directory.
    workdir: ?[]const u8 = null,
    workdir_abs: ?[]const u8 = null,
    /// Symlinks made in the work directory before each attempt, each to one
    /// of the rule's inputs.
    links: []const Link = &.{},
    groups: []const GroupUse,
    shared: []const []const u8,
    /// `shared` as indices into `Workflow.shared`, set once the workflow
    /// is checked.
    shared_index: []const usize = &.{},
    /// What the rule is, for reports and the live view; not part of its key.
    labels: Labels = .{ .step = "" },
};

/// What a rule is: the step it is an instance of, the category of that
/// step, the tool it runs and the sample it works on. Each is declared in
/// the workflow or derived (see `deriveLabels`); none is part of the rule
/// key, so changing one reruns nothing.
pub const Labels = struct {
    step: []const u8,
    category: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    sample: ?[]const u8 = null,
    /// Which of the four the workflow declared.
    declared: Declared = .{},

    pub const Declared = struct { step: bool = false, category: bool = false, tool: bool = false, sample: bool = false };
};

pub const label_keys = [_][]const u8{ "step", "category", "tool", "sample" };

/// The labels of a rule that declares none: the step is the part of the
/// name after the last "__" ("s1__STAR_ALIGN" is "STAR_ALIGN"), else before
/// the last "_" ("align_s1" is "align"), else the whole name; the sample is
/// the part before the last "__", the convention of preparers that name
/// rules SAMPLE__STEP; the tool of a container rule is its image's
/// repository name without registry, path or tag. Declared labels replace
/// the derived ones one by one.
pub fn deriveLabels(name: []const u8, container: ?[]const u8) Labels {
    var l: Labels = .{ .step = name };
    if (std.mem.lastIndexOf(u8, name, "__")) |i| {
        // A name that ends in "__" keeps it as its step.
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

/// A label value: 1 to 200 bytes without control characters.
fn validLabel(value: []const u8) bool {
    if (value.len == 0 or value.len > 200) return false;
    for (value) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

pub const Link = struct { name: []const u8, target: []const u8, target_abs: []const u8 };

pub const ImageMount = struct { source: []const u8, source_abs: []const u8, target: []const u8 };

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
    /// Longest a service may take to become ready.
    timeout_s: ?u64 = null,
    /// Starts after a failure before ready, before its users fail.
    retries: u32 = 0,
    /// Host paths mounted read-only over paths in the service's image.
    mounts: []const ImageMount = &.{},

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
    /// Where in the source, when known: 1-based line, and column or 0.
    line: u32 = 0,
    col: u32 = 0,

    pub fn set(self: *Problem, gpa: Allocator, comptime fmt: []const u8, args: anytype) error{ Invalid, OutOfMemory } {
        self.message = try std.fmt.allocPrint(gpa, fmt, args);
        return error.Invalid;
    }
};

const top_keys = [_][]const u8{ "workflow", "defaults", "rules", "resource_groups", "shared" };
const workflow_keys = [_][]const u8{ "name", "version", "description", "author", "format_version" };
const default_keys = [_][]const u8{ "threads", "memory" };
const group_keys = [_][]const u8{"max"};
const shared_keys = [_][]const u8{ "path", "container", "command", "memory", "timeout", "retries", "mounts" };
const rule_keys = [_][]const u8{ "name", "input", "output", "shell", "threads", "memory", "resources", "priority", "log", "benchmark", "retries", "timeout", "cutoff", "container", "mounts", "workdir", "links", "step", "category", "tool", "sample", "diagnostics", "version" };
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
        self.problem.line = l;
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

    /// `mounts = { "host path" = "/path/in/image" }` of a rule or service.
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
            // Podman's --volume syntax cannot carry ':' or ','.
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

fn contains(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// Writes line `line` of `source` under a gutter, with a caret under
/// column `col` when it is known.
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
            // Tabs keep their width so the caret lines up.
            for (shown[0 .. col - 1]) |c| try w.writeAll(if (c == '\t') "\t" else " ");
            try w.writeAll("^\n");
        }
        return;
    }
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

/// An explicit local path written relative to the working directory,
/// without "..".
fn relativeLocal(p: []const u8) bool {
    return localPath(p) and !std.fs.path.isAbsolute(p) and !hasParentComponent(p);
}

/// Whether `abs`, a path at or below `root`, is the engine's record
/// directory or inside it.
pub fn inRecords(root: []const u8, abs: []const u8) bool {
    const rel = if (std.mem.eql(u8, root, "/")) abs else abs[root.len..];
    return std.mem.startsWith(u8, rel, "/.workz/") or std.mem.eql(u8, rel, "/.workz");
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
        else => {
            problem.line = @intCast(info.line);
            problem.col = @intCast(info.col);
            return problem.set(gpa, "line {d}, column {d}: {s}", .{ info.line, info.col, info.message() });
        },
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
            const timeout_s: ?u64 = if (try p.str(s, "timeout", &at, "shared")) |text| blk: {
                if (image == null) return p.failKey(&at, "timeout", "shared.{s}: timeout limits a service's loading, which needs a container", .{e.key_ptr.*});
                break :blk parseDuration(text) orelse return p.failKey(&at, "timeout", "shared.{s}: invalid timeout '{s}' (use for example \"90s\", \"30m\", \"2h\")", .{ e.key_ptr.*, text });
            } else null;
            const retries: u32 = if (try p.int(s, "retries", &at, "shared")) |n| blk: {
                if (image == null) return p.failKey(&at, "retries", "shared.{s}: retries start a service again, which needs a container", .{e.key_ptr.*});
                if (n < 0 or n > 3) return p.failKey(&at, "retries", "shared.{s}: retries must be between 0 and 3", .{e.key_ptr.*});
                break :blk @intCast(n);
            } else 0;
            const svc_mounts = try p.imageMounts(s, &at, "shared", e.key_ptr.*, root);
            if (svc_mounts.len > 0 and image == null) return p.failKey(&at, "mounts", "shared.{s}: mounts place host files inside a service's image, which needs a container", .{e.key_ptr.*});
            try shared.append(arena, .{
                .name = try arena.dupe(u8, e.key_ptr.*),
                .path = sp,
                .path_abs = if (sp) |shared_path| try sys.absolute(arena, root, shared_path) else null,
                .container = image,
                .command = command,
                .memory_mib = mib,
                .timeout_s = timeout_s,
                .retries = retries,
                .mounts = svc_mounts,
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
        var input = try p.strings(r, "input", &at, name);
        const output = try p.strings(r, "output", &at, name);
        const diagnostics = try p.strings(r, "diagnostics", &at, name);
        const version = try p.str(r, "version", &at, name);
        if (version) |v| if (std.mem.trim(u8, v, " \t\n").len == 0) return p.failKey(&at, "version", "rule {s}: version must be a command, such as \"STAR --version\"", .{name});
        const mounts = try p.imageMounts(r, &at, "rule", name, root);
        if (mounts.len > 0) {
            // Each mount source is also an input of the rule.
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
                    const units = std.math.cast(u32, count) orelse
                        return p.failKey(&res_at, "groups", "rule {s}: group '{s}' count {d} must be from 1 to the group's max", .{ name, ge.key_ptr.*, count });
                    try group_uses.append(arena, .{ .name = try arena.dupe(u8, ge.key_ptr.*), .count = units });
                }
            }
        }
        // A rule reads the files of the mapped shared inputs it uses, so each
        // is also its input and a rebuilt index reruns it. A service's path
        // is not: rules of the workflow may produce it during the launch.
        for (shared_uses) |used| {
            const sh = for (wf.shared) |s| {
                if (std.mem.eql(u8, s.name, used)) break s;
            } else continue;
            if (sh.isService()) continue;
            const sp = sh.path orelse continue;
            const sp_abs = sh.path_abs orelse continue;
            const listed = for (input) |in| {
                if (std.mem.eql(u8, try sys.absolute(arena, root, in), sp_abs)) break true;
            } else false;
            if (listed) continue;
            const more = try arena.alloc([]const u8, input.len + 1);
            @memcpy(more[0..input.len], input);
            more[input.len] = sp;
            input = more;
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

        rules[i] = .{
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
    wf.rules = rules;
    try checkRules(gpa, &wf, problem);
    // Every shared name now exists: resolve each rule's to indices once.
    for (rules) |*r| {
        const idx = try arena.alloc(usize, r.shared.len);
        for (r.shared, idx) |s, *x| x.* = wf.sharedIndex(s).?;
        r.shared_index = idx;
    }
    return wf;
}

fn absAll(arena: Allocator, root: []const u8, paths: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, paths.len);
    for (paths, 0..) |path, i| out[i] = try sys.absolute(arena, root, path);
    return out;
}

/// How rule keys and `state.json` name path `abs`: relative to the working
/// directory `root` when inside it, so moving the project keeps them, else
/// absolute.
pub fn keyPath(root: []const u8, abs: []const u8) []const u8 {
    if (std.mem.eql(u8, root, "/")) return abs;
    if (std.mem.eql(u8, abs, root)) return ".";
    if (abs.len > root.len and std.mem.startsWith(u8, abs, root) and abs[root.len] == '/') return abs[root.len + 1 ..];
    return abs;
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
    if (!relativeLocal(written))
        return problem.set(gpa, "rule {s}: '{s}' must be a relative path inside the working directory", .{ rule, written });
    if (!within(wf.root, abs)) return problem.set(gpa, "rule {s}: '{s}' leaves the working directory", .{ rule, written });
    if (inRecords(wf.root, abs))
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
        // Errors about this rule show its line.
        problem.line = r.line;
        if ((try names.fetchPut(gpa, r.name, {})) != null) return problem.set(gpa, "line {d}: duplicate rule name '{s}'", .{ r.line, r.name });
        for (r.input) |in| if (!localPath(in)) return problem.set(gpa, "rule {s}: input '{s}' must be an explicit local path", .{ r.name, in });
        for (r.output, r.output_abs) |out, abs| {
            try checkWritable(gpa, wf, &cache, r.name, out, abs, problem);
            if (outputs.get(abs)) |other| {
                if (std.mem.eql(u8, other, r.name)) return problem.set(gpa, "rule {s} lists output '{s}' twice", .{ r.name, out });
                return problem.set(gpa, "rules {s} and {s} both produce '{s}'", .{ other, r.name, out });
            }
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
        // Diagnostics are only read, after a failure: any file inside the
        // working directory but outside the records.
        for (r.diagnostics, r.diagnostics_abs) |written, abs| {
            if (!relativeLocal(written))
                return problem.set(gpa, "rule {s}: diagnostics '{s}' must be a relative path inside the working directory", .{ r.name, written });
            if (inRecords(wf.root, abs)) return problem.set(gpa, "rule {s}: diagnostics '{s}' is inside the engine record directory", .{ r.name, written });
        }
        for (r.groups) |g| {
            const max = wf.groupMax(g.name) orelse return problem.set(gpa, "rule {s} uses undeclared resource group '{s}'", .{ r.name, g.name });
            if (g.count < 1 or g.count > max) return problem.set(gpa, "rule {s}: group '{s}' count {d} must be from 1 to the group's max of {d}", .{ r.name, g.name, g.count, max });
        }
        var services: usize = 0;
        for (r.shared) |s| if (wf.sharedIndex(s)) |si| if (wf.shared[si].isService()) {
            services += 1;
            if (r.container == null) return problem.set(gpa, "rule {s} uses the shared service '{s}'; only container rules can join a service", .{ r.name, s });
        };
        if (services > 1) return problem.set(gpa, "rule {s} uses {d} shared services; a rule can join one", .{ r.name, services });
        if (r.workdir) |d| {
            if (!relativeLocal(d) or !within(wf.root, r.workdir_abs.?) or std.mem.eql(u8, r.workdir_abs.?, wf.root))
                return problem.set(gpa, "rule {s}: workdir '{s}' must be a directory below the working directory", .{ r.name, d });
            if (inRecords(wf.root, r.workdir_abs.?))
                return problem.set(gpa, "rule {s}: workdir '{s}' is inside the engine record directory", .{ r.name, d });
        }
        for (r.links) |l| {
            const is_input = for (r.input_abs) |in| {
                if (std.mem.eql(u8, in, l.target_abs)) break true;
            } else false;
            if (!is_input) return problem.set(gpa, "rule {s}: link '{s}' points at '{s}', which is not an input of the rule", .{ r.name, l.name, l.target });
        }
        if (r.mounts.len > 0 and r.container == null) return problem.set(gpa, "rule {s} has mounts but no container; mounts place host files inside an image", .{r.name});
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
    problem.line = 0;
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
        // Errors about this rule show its line.
        problem.line = r.line;
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
    problem.line = 0;
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
