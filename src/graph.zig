//! The rule graph: a rule depends on the rules that produce its inputs.
const std = @import("std");
const workflow = @import("workflow.zig");
const Allocator = std.mem.Allocator;

pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    /// For each rule, the rules producing its inputs, sorted, without duplicates.
    parents: []const []const usize,
    children: []const []const usize,
    /// Rule indices with every parent before its children; ties keep file order.
    order: []const usize,
    /// Output path to producing rule.
    producer: std.StringHashMapUnmanaged(usize),

    pub fn deinit(self: *Graph) void {
        self.arena.deinit();
    }
};

pub const Error = error{ Cycle, OutOfMemory };

pub fn build(gpa: Allocator, wf: *const workflow.Workflow, cycle_message: *workflow.Problem) !Graph {
    var g: Graph = undefined;
    g.arena = std.heap.ArenaAllocator.init(gpa);
    errdefer g.arena.deinit();
    const a = g.arena.allocator();
    const n = wf.rules.len;

    g.producer = .empty;
    for (wf.rules, 0..) |r, i| for (r.output_abs) |o| try g.producer.put(a, o, i);

    const parents = try a.alloc([]const usize, n);
    var child_lists = try a.alloc(std.ArrayList(usize), n);
    for (child_lists) |*c| c.* = .empty;
    for (wf.rules, 0..) |r, i| {
        var ps: std.ArrayList(usize) = .empty;
        for (r.input_abs) |in| {
            const pi = g.producer.get(in) orelse continue;
            if (std.mem.indexOfScalar(usize, ps.items, pi) == null) try ps.append(a, pi);
        }
        std.mem.sort(usize, ps.items, {}, std.sort.asc(usize));
        parents[i] = ps.items;
        for (ps.items) |pi| try child_lists[pi].append(a, i);
    }
    const children = try a.alloc([]const usize, n);
    for (child_lists, 0..) |c, i| children[i] = c.items;
    g.parents = parents;
    g.children = children;

    // Kahn's algorithm, always taking the lowest ready index for a stable order.
    const pending = try a.alloc(usize, n);
    for (parents, 0..) |ps, i| pending[i] = ps.len;
    var ready: std.PriorityQueue(usize, void, lessIndex) = .empty;
    defer ready.deinit(gpa);
    for (pending, 0..) |c, i| if (c == 0) try ready.push(gpa, i);
    var order: std.ArrayList(usize) = .empty;
    while (ready.pop()) |i| {
        try order.append(a, i);
        for (children[i]) |c| {
            pending[c] -= 1;
            if (pending[c] == 0) try ready.push(gpa, c);
        }
    }
    if (order.items.len != n) {
        for (pending, 0..) |c, i| if (c > 0) {
            _ = cycle_message.set(gpa, "the rule graph has a cycle through rule {s}", .{wf.rules[i].name}) catch {};
            break;
        };
        return error.Cycle;
    }
    g.order = order.items;
    return g;
}

fn lessIndex(_: void, x: usize, y: usize) std.math.Order {
    return std.math.order(x, y);
}

/// Marks the selected targets and every rule they depend on. With no
/// targets, every rule is selected. Unknown names are returned in `unknown`.
pub fn select(gpa: Allocator, wf: *const workflow.Workflow, g: *const Graph, targets: []const []const u8, unknown: *?[]const u8) ![]bool {
    const mask = try gpa.alloc(bool, wf.rules.len);
    if (targets.len == 0) {
        @memset(mask, true);
        return mask;
    }
    @memset(mask, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    for (targets) |t| {
        const i = wf.ruleIndex(t) orelse {
            unknown.* = t;
            gpa.free(mask);
            return error.UnknownTarget;
        };
        try stack.append(gpa, i);
    }
    while (stack.pop()) |i| {
        if (mask[i]) continue;
        mask[i] = true;
        try stack.appendSlice(gpa, g.parents[i]);
    }
    return mask;
}

/// Writes the selected graph in Graphviz DOT form.
pub fn writeDot(w: *std.Io.Writer, wf: *const workflow.Workflow, g: *const Graph, mask: []const bool) !void {
    try w.print("digraph \"{s}\" {{\n  rankdir=LR;\n  node [shape=box];\n", .{wf.name});
    for (g.order) |i| {
        if (!mask[i]) continue;
        try w.print("  \"{s}\";\n", .{wf.rules[i].name});
        for (g.parents[i]) |p| try w.print("  \"{s}\" -> \"{s}\";\n", .{ wf.rules[p].name, wf.rules[i].name });
    }
    try w.writeAll("}\n");
}
