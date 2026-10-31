//! `workz report --methods`: what produced the results recorded in a
//! working directory, for the methods section of a paper or a lab notebook:
//! the workflow files and engines, each tool with its version and image,
//! and each step's request and command. It reads `state.json` and the
//! records of the attempts it points to, so it describes the outputs as
//! they are, across every launch that made them.
const std = @import("std");
const sys = @import("sys.zig");
const records = @import("records.zig");
const state = @import("state.zig");
const fields = @import("fields.zig");
const units = @import("units.zig");
const toml = @import("toml");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const eql = std.mem.eql;
const get = fields.get;

/// A workflow file, by its `[workflow]` name and version and the digest of
/// its bytes, and the recorded rules it made.
pub const Source = struct { name: []const u8, version: []const u8 = "", sha256: []const u8 = "", rules: usize = 0 };

/// An engine or a launch, and the recorded rules it made.
pub const Count = struct { name: []const u8, rules: usize = 0 };

/// A tool: what its rules declared or derived as `tool`, the image they ran
/// in, and the version its command printed.
pub const Tool = struct {
    tool: []const u8,
    /// The first line its version command printed, or null when no rule
    /// names one or no launch recorded its output.
    version: ?[]const u8,
    version_command: ?[]const u8,
    container: ?[]const u8,
    image: ?[]const u8,
    steps: []const []const u8,
    rules: usize,
};

/// A step: how many rules ran it, their requests, and the command of the
/// first of them by name. The requests are null when no rule of the step
/// has a recorded request.
pub const Step = struct {
    step: []const u8,
    rules: usize,
    tool: []const u8,
    threads_min: ?f64 = null,
    threads_max: ?f64 = null,
    memory_mib_min: ?f64 = null,
    memory_mib_max: ?f64 = null,
    example: []const u8,
    command: []const u8,
};

pub const Methods = struct {
    workdir: []const u8,
    rules: usize,
    /// UTC times the first and last recorded rule finished.
    first_finished: []const u8,
    last_finished: []const u8,
    workflows: []const Source,
    engines: []const Count,
    launches: []const Count,
    tools: []const Tool,
    steps: []const Step,
};

/// One recorded rule, from its attempt's records and its launch's.
const Rule = struct {
    name: []const u8,
    step: []const u8,
    tool: []const u8,
    /// The request, from the attempt's record, else its request file.
    threads: ?f64,
    memory_mib: ?f64,
    container: ?[]const u8,
    image: ?[]const u8,
    version_command: ?[]const u8,
    version: ?[]const u8,
    shell: []const u8,
    finished: []const u8,
    launch: *const Launch,
};

const Launch = struct {
    id: []const u8,
    engine: []const u8 = "",
    workflow_name: []const u8 = "",
    workflow_version: []const u8 = "",
    workflow_sha256: []const u8 = "",
    versions: ?Value = null,
};

/// A JSON record file, or null when there is none; one that does not parse
/// is named on standard error and read as absent.
fn readJson(gpa: Allocator, a: Allocator, path: []const u8) !?Value {
    const bytes = sys.readFile(gpa, path, 16 << 20) catch |err| return if (err == error.OutOfMemory) err else null;
    defer gpa.free(bytes);
    return std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.debug.print("workz: {s} is not valid JSON; its fields are left out\n", .{path});
        return null;
    };
}

fn str(v: ?Value, key: []const u8) []const u8 {
    return fields.str(v orelse return "", key) orelse "";
}

fn optStr(v: ?Value, key: []const u8) ?[]const u8 {
    const s = fields.str(v orelse return null, key) orelse return null;
    return if (s.len > 0) s else null;
}

/// The first non-empty line of `text`.
fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len > 0) return t;
    }
    return "";
}

/// The version a launch recorded for `command` run in `image`, or on the
/// host when `image` is null: the first line of what it printed, if it
/// exited 0.
fn versionOf(l: *const Launch, command: []const u8, image: ?[]const u8) ?[]const u8 {
    const list = l.versions orelse return null;
    if (list != .array) return null;
    for (list.array.items) |e| {
        if (!eql(u8, str(e, "command"), command)) continue;
        const img = optStr(e, "image");
        const same = if (img) |x| (image != null and eql(u8, x, image.?)) else image == null;
        if (!same) continue;
        if (fields.int(e, "exit_code") != 0) return null;
        const line = firstLine(str(e, "output"));
        return if (line.len > 0) line else null;
    }
    return null;
}

/// Counts a rule for workflow file `s` in `list`.
fn countSource(a: Allocator, list: *std.ArrayList(Source), s: Source) !void {
    for (list.items) |*x| if (eql(u8, x.name, s.name) and eql(u8, x.version, s.version) and eql(u8, x.sha256, s.sha256)) {
        x.rules += 1;
        return;
    };
    var n = s;
    n.rules = 1;
    try list.append(a, n);
}

/// Counts a rule for `name` in `list`.
fn count(a: Allocator, list: *std.ArrayList(Count), name: []const u8) !void {
    for (list.items) |*x| if (eql(u8, x.name, name)) {
        x.rules += 1;
        return;
    };
    try list.append(a, .{ .name = name, .rules = 1 });
}

const Names = struct { name: []const u8 = "", version: []const u8 = "" };

/// The `[workflow]` name and version in a launch's copy of its workflow
/// file, for a launch whose `launch.json` does not record them.
fn snapshotNames(gpa: Allocator, a: Allocator, launch_dir: []const u8) !Names {
    const bytes = sys.readFile(gpa, try std.fs.path.join(a, &.{ launch_dir, "workflow" }), 64 << 20) catch |err| return if (err == error.OutOfMemory) err else .{};
    defer gpa.free(bytes);
    const doc = toml.parseSlice(gpa, bytes, null) catch |err| return if (err == error.OutOfMemory) err else .{};
    defer toml.deinit(doc, gpa);
    const meta = switch (doc.get("workflow") orelse return .{}) {
        .table => |t| t,
        else => return .{},
    };
    var out: Names = .{};
    if (meta.get("name")) |v| if (v == .string) {
        out.name = try a.dupe(u8, v.string);
    };
    if (meta.get("version")) |v| if (v == .string) {
        out.version = try a.dupe(u8, v.string);
    };
    return out;
}

/// Reads what produced the results recorded in working directory `root`.
pub fn collect(gpa: Allocator, a: Allocator, root: []const u8) !Methods {
    const rec = try records.recordsDir(a, root);
    var st = try state.load(gpa, rec);
    defer st.deinit();

    var launches: std.StringArrayHashMapUnmanaged(*Launch) = .empty;
    var rules: std.ArrayList(Rule) = .empty;
    for (st.data.rules.map.keys(), st.data.rules.map.values()) |name, e| {
        // attempts/<rule>/<NNN> inside the launch directory.
        const launch_dir = std.fs.path.dirname(std.fs.path.dirname(std.fs.path.dirname(e.attempt) orelse continue) orelse continue) orelse continue;
        const gop = try launches.getOrPut(a, launch_dir);
        if (!gop.found_existing) {
            const l = try a.create(Launch);
            const info = try readJson(gpa, a, try std.fs.path.join(a, &.{ launch_dir, "launch.json" }));
            const names: Names = if (info != null and get(info.?, "workflow_name") != null)
                .{ .name = str(info, "workflow_name"), .version = str(info, "workflow_version") }
            else
                try snapshotNames(gpa, a, launch_dir);
            l.* = .{
                .id = try a.dupe(u8, std.fs.path.basename(launch_dir)),
                .engine = str(info, "engine"),
                .workflow_name = names.name,
                .workflow_version = names.version,
                .workflow_sha256 = str(info, "workflow_sha256"),
                .versions = try readJson(gpa, a, try std.fs.path.join(a, &.{ launch_dir, "versions.json" })),
            };
            gop.key_ptr.* = try a.dupe(u8, launch_dir);
            gop.value_ptr.* = l;
        }
        const l = gop.value_ptr.*;
        const record = try readJson(gpa, a, try std.fs.path.join(a, &.{ e.attempt, "record.json" }));
        const request = try readJson(gpa, a, try std.fs.path.join(a, &.{ e.attempt, "request.json" }));
        const labels = if (record) |r| get(r, "labels") else null;
        const req = if (record) |r| get(r, "request") else null;
        const image = optStr(record, "image");
        const command = optStr(record, "version");
        try rules.append(a, .{
            .name = try a.dupe(u8, name),
            .step = if (str(labels, "step").len > 0) str(labels, "step") else try a.dupe(u8, name),
            .tool = str(labels, "tool"),
            .threads = if (req) |q| fields.float(q, "threads") else if (request) |q| fields.float(q, "threads") else null,
            .memory_mib = if (req) |q| fields.float(q, "memory_mib") else if (request) |q| fields.float(q, "memory_mib") else null,
            .container = optStr(req, "container"),
            .image = image,
            .version_command = command,
            .version = if (command) |c| versionOf(l, c, image) else null,
            .shell = str(request, "shell"),
            .finished = try a.dupe(u8, e.finished),
            .launch = l,
        });
    }
    // Steps in the order they first finished, which follows the pipeline;
    // rules by name within a step.
    std.mem.sort(Rule, rules.items, {}, struct {
        fn lt(_: void, x: Rule, y: Rule) bool {
            const o = std.mem.order(u8, x.finished, y.finished);
            return o == .lt or (o == .eq and std.mem.lessThan(u8, x.name, y.name));
        }
    }.lt);

    var workflows: std.ArrayList(Source) = .empty;
    var engines: std.ArrayList(Count) = .empty;
    var used: std.ArrayList(Count) = .empty;
    var tools: std.ArrayList(Tool) = .empty;
    var steps: std.ArrayList(Step) = .empty;
    var first: []const u8 = "";
    var last: []const u8 = "";
    for (rules.items) |r| {
        if (first.len == 0 or std.mem.order(u8, r.finished, first) == .lt) first = r.finished;
        if (std.mem.order(u8, r.finished, last) == .gt) last = r.finished;
        try countSource(a, &workflows, .{ .name = r.launch.workflow_name, .version = r.launch.workflow_version, .sha256 = r.launch.workflow_sha256 });
        try count(a, &engines, r.launch.engine);
        try count(a, &used, r.launch.id);

        const step = for (steps.items) |*s| {
            if (eql(u8, s.step, r.step)) break s;
        } else blk: {
            try steps.append(a, .{ .step = r.step, .rules = 0, .tool = r.tool, .example = r.name, .command = r.shell });
            break :blk &steps.items[steps.items.len - 1];
        };
        step.rules += 1;
        if (r.threads) |t| {
            step.threads_min = @min(step.threads_min orelse t, t);
            step.threads_max = @max(step.threads_max orelse t, t);
        }
        if (r.memory_mib) |m| {
            step.memory_mib_min = @min(step.memory_mib_min orelse m, m);
            step.memory_mib_max = @max(step.memory_mib_max orelse m, m);
        }
        if (std.mem.lessThan(u8, r.name, step.example)) {
            step.example = r.name;
            step.command = r.shell;
            step.tool = r.tool;
        }

        const tool = for (tools.items) |*t| {
            const same_image = if (t.image) |x| (r.image != null and eql(u8, x, r.image.?)) else r.image == null;
            const same_command = if (t.version_command) |x| (r.version_command != null and eql(u8, x, r.version_command.?)) else r.version_command == null;
            if (eql(u8, t.tool, r.tool) and same_image and same_command) break t;
        } else blk: {
            try tools.append(a, .{ .tool = r.tool, .version = null, .version_command = r.version_command, .container = r.container, .image = r.image, .steps = &.{}, .rules = 0 });
            break :blk &tools.items[tools.items.len - 1];
        };
        tool.rules += 1;
        if (tool.version == null) tool.version = r.version;
        for (tool.steps) |s| {
            if (eql(u8, s, r.step)) break;
        } else {
            const list = try a.alloc([]const u8, tool.steps.len + 1);
            @memcpy(list[0..tool.steps.len], tool.steps);
            list[tool.steps.len] = r.step;
            tool.steps = list;
        }
    }
    return .{
        .workdir = root,
        .rules = rules.items.len,
        .first_finished = first,
        .last_finished = last,
        .workflows = workflows.items,
        .engines = engines.items,
        .launches = used.items,
        .tools = tools.items,
        .steps = steps.items,
    };
}

pub fn writeJson(w: *std.Io.Writer, m: Methods) !void {
    try w.print("{f}\n", .{std.json.fmt(m, .{ .whitespace = .indent_2 })});
}

/// The methods as text: sources, then tools, then steps.
pub fn writeText(w: *std.Io.Writer, m: Methods) !void {
    try w.print("Results in {s}: ", .{m.workdir});
    try units.count(w, m.rules, "rule", "rules");
    try w.print(", finished from {s} to {s}\n", .{ m.first_finished, m.last_finished });

    try w.writeAll("\nworkflow\n");
    for (m.workflows) |s| {
        try w.print("  {s}", .{if (s.name.len > 0) s.name else "(unnamed)"});
        if (s.version.len > 0) try w.print(" {s}", .{s.version});
        if (s.sha256.len > 0) try w.print(", file sha256:{s}", .{s.sha256});
        try ruleCount(w, s.rules, m.workflows.len);
    }
    try w.writeAll("engine\n");
    for (m.engines) |s| {
        try w.print("  {s}", .{if (s.name.len > 0) s.name else "(not recorded)"});
        try ruleCount(w, s.rules, m.engines.len);
    }
    try w.writeAll("launches\n");
    for (m.launches) |s| {
        try w.print("  {s}", .{s.name});
        try ruleCount(w, s.rules, m.launches.len);
    }

    try w.writeAll("\ntools\n");
    var unversioned: usize = 0;
    for (m.tools) |t| {
        try w.print("  {s}", .{if (t.tool.len > 0) t.tool else "(no tool label)"});
        if (t.version) |v| try w.print(": {s}", .{v});
        try w.writeAll("\n");
        if (t.container) |c| {
            try w.print("    image    {s}\n", .{c});
            if (t.image) |id| try w.print("             sha256:{s}\n", .{id});
        } else try w.writeAll("    host\n");
        if (t.version_command) |c| {
            try w.print("    version  {s}", .{c});
            // It failed, did not run, or ran in a launch that is gone.
            if (t.version == null) try w.writeAll(" (no version recorded)");
            try w.writeAll("\n");
        } else if (t.tool.len > 0) unversioned += 1;
        try w.writeAll("    steps    ");
        for (t.steps, 0..) |s, k| try w.print("{s}{s}", .{ if (k == 0) "" else ", ", s });
        try w.print(" (", .{});
        try units.count(w, t.rules, "rule", "rules");
        try w.writeAll(")\n");
    }

    try w.writeAll("\nsteps\n");
    for (m.steps) |s| {
        try w.print("  {s}: ", .{s.step});
        try units.count(w, s.rules, "rule", "rules");
        if (s.threads_min) |t_lo| {
            try w.writeAll(", ");
            try range(w, t_lo, s.threads_max.?, false);
            try w.writeAll(if (s.threads_max.? == 1) " thread" else " threads");
            if (s.memory_mib_min) |m_lo| {
                try w.writeAll(" and ");
                try range(w, m_lo, s.memory_mib_max.?, true);
            }
            try w.writeAll(if (s.rules == 1) "\n" else " each\n");
        } else try w.writeAll(", request not recorded\n");
        try w.print("    {s}: ", .{s.example});
        // Continuation lines of a multi-line command stay indented.
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, s.command, " \n"), '\n');
        var k: usize = 0;
        while (lines.next()) |line| : (k += 1) try w.print("{s}{s}\n", .{ if (k == 0) "" else "      ", line });
    }
    if (unversioned > 0) {
        try w.writeAll("\n");
        try units.count(w, unversioned, "tool has", "tools have");
        try w.print(" no version command: give {s} rules `version`, such as \"STAR --version\", and the next launch that runs them records it.\n", .{if (unversioned == 1) "its" else "their"});
    }
}

fn ruleCount(w: *std.Io.Writer, rules: usize, of: usize) !void {
    if (of > 1) {
        try w.writeAll(" (");
        try units.count(w, rules, "rule", "rules");
        try w.writeAll(")");
    }
    try w.writeAll("\n");
}

fn range(w: *std.Io.Writer, lo: f64, hi: f64, mib: bool) !void {
    if (mib) try units.size(w, lo) else try w.print("{d}", .{lo});
    if (hi == lo) return;
    try w.writeAll(" to ");
    if (mib) try units.size(w, hi) else try w.print("{d}", .{hi});
}
