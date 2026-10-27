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
    /// Every output path with its rule, sorted by path, to find the rules
    /// writing inside a directory.
    outputs: []const Output,

    /// Whether a rule writes `path`, or a file below it.
    pub fn produces(self: *const Graph, path: []const u8) bool {
        if (self.producer.contains(path)) return true;
        return below(self.outputs, path).len > 0;
    }

    pub fn deinit(self: *Graph) void {
        self.arena.deinit();
    }
};

pub fn build(gpa: Allocator, wf: *const workflow.Workflow, cycle_message: *workflow.Problem) !Graph {
    var g: Graph = undefined;
    g.arena = std.heap.ArenaAllocator.init(gpa);
    errdefer g.arena.deinit();
    const a = g.arena.allocator();
    const n = wf.rules.len;

    g.producer = .empty;
    for (wf.rules, 0..) |r, i| for (r.output_abs) |o| try g.producer.put(a, o, i);
    var outs: std.ArrayList(Output) = .empty;
    for (wf.rules, 0..) |r, i| for (r.output_abs) |o| try outs.append(a, .{ .path = o, .rule = i });
    std.mem.sort(Output, outs.items, {}, Output.lessThan);
    g.outputs = outs.items;

    const parents = try a.alloc([]const usize, n);
    var child_lists = try a.alloc(std.ArrayList(usize), n);
    for (child_lists) |*c| c.* = .empty;
    for (wf.rules, 0..) |r, i| {
        var ps: std.ArrayList(usize) = .empty;
        for (r.input_abs) |in| {
            if (g.producer.get(in)) |pi| {
                if (std.mem.indexOfScalar(usize, ps.items, pi) == null) try ps.append(a, pi);
            }
            // A directory input depends on every rule writing inside it.
            for (below(g.outputs, in)) |o| {
                if (o.rule == i) continue;
                if (std.mem.indexOfScalar(usize, ps.items, o.rule) == null) try ps.append(a, o.rule);
            }
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
        const cycle = try findCycle(a, parents, pending);
        var text: std.Io.Writer.Allocating = .init(a);
        for (cycle) |i| try text.writer.print("{s} -> ", .{wf.rules[i].name});
        try text.writer.writeAll(wf.rules[cycle[0]].name);
        cycle_message.current_line = wf.rules[cycle[0]].line;
        _ = cycle_message.set(gpa, "the rule graph has a cycle: {s} (each rule writes an input of the next)", .{text.written()}) catch {};
        cycle_message.current_line = 0;
        return error.Cycle;
    }
    g.order = order.items;
    try checkServiceInputs(gpa, wf, &g, cycle_message);
    return g;
}

/// The rules of one cycle, each a parent of the next, from the rules Kahn's
/// algorithm left with `pending` parents. Every such rule has a parent also
/// left, so walking from parent to parent returns to a rule already seen.
fn findCycle(a: Allocator, parents: []const []const usize, pending: []const usize) ![]usize {
    var i = for (pending, 0..) |c, k| {
        if (c > 0) break k;
    } else unreachable;
    const seen_at = try a.alloc(?usize, pending.len);
    @memset(seen_at, null);
    var walk: std.ArrayList(usize) = .empty;
    while (seen_at[i] == null) {
        seen_at[i] = walk.items.len;
        try walk.append(a, i);
        i = for (parents[i]) |p| {
            if (pending[p] > 0) break p;
        } else unreachable;
    }
    const loop = walk.items[seen_at[i].?..];
    std.mem.reverse(usize, loop);
    return loop;
}

/// An output path and the rule that writes it.
pub const Output = struct {
    path: []const u8,
    rule: usize,

    fn lessThan(_: void, x: Output, y: Output) bool {
        return std.mem.lessThan(u8, x.path, y.path);
    }
};

/// The outputs strictly below directory `dir`, from outputs sorted by path:
/// they start with "dir/", so they are the run that begins at the first
/// path not sorting before "dir/".
pub fn below(outputs: []const Output, dir: []const u8) []const Output {
    var lo: usize = 0;
    var hi: usize = outputs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (beforeDirSlash(outputs[mid].path, dir)) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < outputs.len and isBelow(dir, outputs[end].path)) end += 1;
    return outputs[lo..end];
}

/// Whether `path` sorts before `dir` followed by '/'.
fn beforeDirSlash(path: []const u8, dir: []const u8) bool {
    const n = @min(path.len, dir.len);
    switch (std.mem.order(u8, path[0..n], dir[0..n])) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (path.len <= dir.len) return true;
    return path[dir.len] < '/';
}

fn isBelow(dir: []const u8, path: []const u8) bool {
    return path.len > dir.len + 1 and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

/// A service loads its path when its first user starts; a rule that joins
/// the service cannot also write there, since the service would start
/// before the file exists. Rules that write there are producers of every
/// user, through the service's path as their input.
fn checkServiceInputs(gpa: Allocator, wf: *const workflow.Workflow, g: *const Graph, problem: *workflow.Problem) !void {
    for (wf.shared) |s| {
        const sp = s.path_abs orelse continue;
        if (!s.isService()) continue;
        for (wf.rules, 0..) |r, u| {
            const joins = for (r.shared) |name| {
                if (std.mem.eql(u8, name, s.name)) break true;
            } else false;
            if (!joins) continue;
            for (below(g.outputs, sp)) |o| if (o.rule == u) {
                problem.current_line = r.line;
                defer problem.current_line = 0;
                const out = std.mem.trimStart(u8, o.path[wf.root.len..], "/");
                return problem.set(gpa, "rule {s} joins service '{s}' and writes {s}, which the service loads; the service would start before the file exists", .{ r.name, s.name, out });
            };
        }
    }
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
