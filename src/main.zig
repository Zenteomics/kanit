//! Command-line entry point.
const std = @import("std");
const workz = @import("workz");
const sys = workz.sys;
const workflow = workz.workflow;
const graph = workz.graph;
const usage =
    \\usage: workz <command> [options]
    \\
    \\commands:
    \\  validate WORKFLOW        check the workflow file and graph
    \\  graph WORKFLOW           print the selected graph in DOT form
    \\  version                  print the engine version
    \\
    \\common options:
    \\  -d, --workdir DIR        working directory (default: the workflow's directory)
    \\  -t, --target RULE        select RULE and its dependencies (repeatable)
    \\
;

const Exit = enum(u8) { ok = 0, failed = 1, usage = 2, interrupted = 130, _ };

fn fail(comptime fmt: []const u8, args: anytype) Exit {
    std.debug.print("workz: " ++ fmt ++ "\n", args);
    return .usage;
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    argv: []const [:0]const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return @intFromEnum(Exit.usage);
    }
    // Debug builds keep the leak-checking allocator; shipped builds use the
    // caching SMP allocator, which avoids a map and unmap per allocation.
    const gpa = if (@import("builtin").mode == .Debug) init.gpa else std.heap.smp_allocator;
    const ctx: Ctx = .{ .gpa = gpa, .a = a, .io = init.io, .env = init.environ_map, .argv = args };
    const cmd = args[1];
    const rest = args[2..];
    const eq = std.mem.eql;
    const code: Exit = if (eq(u8, cmd, "version") or eq(u8, cmd, "--version")) blk: {
        try out(init.io, "workz {s}\n", .{workz.version});
        break :blk .ok;
    } else if (eq(u8, cmd, "help") or eq(u8, cmd, "--help") or eq(u8, cmd, "-h")) blk: {
        try out(init.io, "{s}", .{usage});
        break :blk .ok;
    } else if (eq(u8, cmd, "validate")) try cmdValidate(ctx, rest, false) else if (eq(u8, cmd, "graph")) try cmdValidate(ctx, rest, true) else fail("unknown command '{s}'; run 'workz help'", .{cmd});
    return @intFromEnum(code);
}

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

const Common = struct {
    workflow: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    targets: std.ArrayList([]const u8) = .empty,
    positional: std.ArrayList([]const u8) = .empty,
};

/// Parses common options; `extra` handles command-specific options and
/// returns how many arguments it consumed (0 when not its option).
fn parseArgs(a: std.mem.Allocator, args: []const [:0]const u8, c: *Common, extra: anytype) !?Exit {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--workdir")) {
            c.workdir = value orelse return fail("{s} needs a value", .{arg});
            i += 1;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--target")) {
            try c.targets.append(a, value orelse return fail("{s} needs a value", .{arg}));
            i += 1;
        } else if (arg.len > 1 and arg[0] == '-') {
            const used = try extra.option(arg, value);
            if (used == 0) return fail("unknown option '{s}'", .{arg});
            if (used == std.math.maxInt(usize)) return .usage;
            i += used - 1;
        } else if (c.workflow == null) {
            c.workflow = arg;
        } else try c.positional.append(a, arg);
    }
    return null;
}

const NoExtra = struct {
    fn option(_: NoExtra, _: []const u8, _: ?[]const u8) !usize {
        return 0;
    }
};

const Loaded = struct {
    wf: workflow.Workflow,
    g: graph.Graph,
    mask: []bool,

    fn deinit(self: *Loaded) void {
        self.g.deinit();
        self.wf.deinit();
    }
};

fn rootOf(c: Ctx, common: *const Common) !?[]const u8 {
    const here = try sys.cwd(c.a);
    const given = if (common.workdir) |d| try sys.absolute(c.a, here, d) else if (common.workflow) |w| std.fs.path.dirname(try sys.absolute(c.a, here, w)) orelse "/" else here;
    return (try sys.realpath(c.a, given)) orelse {
        std.debug.print("workz: working directory does not exist: {s}\n", .{given});
        return null;
    };
}

/// Loads, checks and selects; prints the reason and returns null when invalid.
fn load(c: Ctx, common: *const Common) !?Loaded {
    const wpath = common.workflow orelse {
        std.debug.print("workz: missing workflow file\n", .{});
        return null;
    };
    const root = (try rootOf(c, common)) orelse return null;
    const wf_abs = try sys.absolute(c.a, try sys.cwd(c.a), wpath);
    var problem: workflow.Problem = .{};
    var wf = workflow.load(c.gpa, wf_abs, root, &problem) catch |err| switch (err) {
        error.Invalid => {
            std.debug.print("workz: {s}: {s}\n", .{ wpath, problem.message });
            c.gpa.free(problem.message);
            return null;
        },
        else => return err,
    };
    errdefer wf.deinit();
    var g = graph.build(c.gpa, &wf, &problem) catch |err| switch (err) {
        error.Cycle => {
            std.debug.print("workz: {s}: {s}\n", .{ wpath, problem.message });
            c.gpa.free(problem.message);
            wf.deinit();
            return null;
        },
        else => return err,
    };
    errdefer g.deinit();
    var unknown: ?[]const u8 = null;
    const mask = graph.select(c.a, &wf, &g, common.targets.items, &unknown) catch |err| switch (err) {
        error.UnknownTarget => {
            std.debug.print("workz: unknown target '{s}'\n", .{unknown.?});
            g.deinit();
            wf.deinit();
            return null;
        },
        else => return err,
    };
    return .{ .wf = wf, .g = g, .mask = mask };
}

fn cmdValidate(c: Ctx, args: []const [:0]const u8, dot: bool) !Exit {
    var common: Common = .{};
    if (try parseArgs(c.a, args, &common, NoExtra{})) |e| return e;
    var l = (try load(c, &common)) orelse return .usage;
    defer l.deinit();
    if (dot) {
        var buf: [8192]u8 = undefined;
        var w = std.Io.File.stdout().writer(c.io, &buf);
        try graph.writeDot(&w.interface, &l.wf, &l.g, l.mask);
        try w.interface.flush();
        return .ok;
    }
    var selected: usize = 0;
    for (l.mask) |m| selected += @intFromBool(m);
    try out(c.io, "valid: {s} ({d} rules, {d} selected, {d} groups, {d} shared)\n", .{ l.wf.name, l.wf.rules.len, selected, l.wf.groups.len, l.wf.shared.len });
    return .ok;
}
