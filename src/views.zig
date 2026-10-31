//! `workz graph`: views of the rule graph in layers. The rules layer shows
//! which rules feed which; the files layer puts the files between them; the
//! resources layer adds the shared inputs, each held once, with the rules
//! that map or join them and the rules writing what a service loads, and
//! the resource groups with the units each rule takes. A view can collapse
//! the samples of each step into one node, focus on a rule with its
//! upstream or downstream rules, follow one path between two rules, or show
//! the producers and users of one shared input. It prints DOT, JSON in the
//! Cytoscape elements shape, or text.
const std = @import("std");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const units = @import("units.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const Layer = enum { rules, files, resources, all };
pub const Format = enum { dot, json, text };

/// A rule with its upstream rules to `up` levels, and its downstream rules
/// to `down` levels; null is none, `all` every level.
pub const Focus = struct {
    rule: []const u8,
    up: ?u32 = null,
    down: ?u32 = null,

    pub const all = std.math.maxInt(u32);

    /// `+X` (all upstream), `X+` (all downstream), `+X+`, and a depth
    /// before or after the sign: `2+X`, `X+1`. Since a rule name may be all
    /// digits, some texts read two ways, such as `12+` and `1+2`: the first
    /// reading whose rule `wf` has wins, else the first reading. Null when
    /// the text names no rule with a direction.
    pub fn parse(text: []const u8, wf: ?*const workflow.Workflow) ?Focus {
        var first: ?Focus = null;
        for ([_][2]bool{ .{ true, true }, .{ true, false }, .{ false, true } }) |use| {
            const f = reading(text, use[0], use[1]) orelse continue;
            if (wf) |w| if (w.ruleIndex(f.rule) != null) return f;
            if (first == null) first = f;
        }
        return first;
    }

    /// `text` read with a depth before its first `+` (`prefix`) and after
    /// its last (`suffix`); null when it does not read that way.
    fn reading(text: []const u8, prefix: bool, suffix: bool) ?Focus {
        var f: Focus = .{ .rule = text };
        var rest = text;
        if (prefix) {
            const i = std.mem.indexOfScalar(u8, rest, '+') orelse return null;
            if (!allDigits(rest[0..i])) return null;
            f.up = if (i == 0) all else std.fmt.parseInt(u32, rest[0..i], 10) catch return null;
            rest = rest[i + 1 ..];
        }
        if (suffix) {
            const i = std.mem.lastIndexOfScalar(u8, rest, '+') orelse return null;
            if (!allDigits(rest[i + 1 ..])) return null;
            f.down = if (i + 1 == rest.len) all else std.fmt.parseInt(u32, rest[i + 1 ..], 10) catch return null;
            rest = rest[0..i];
        }
        if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '+') != null) return null;
        f.rule = rest;
        return f;
    }

    fn allDigits(s: []const u8) bool {
        for (s) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
};

pub const Options = struct {
    layer: Layer = .rules,
    by_step: bool = false,
    focus: ?Focus = null,
    /// `--why FROM:TO`: one path of rules from FROM to TO.
    why: ?[2][]const u8 = null,
    /// `--users NAME`: one shared input with its producers and users.
    users: ?[]const u8 = null,
};

pub const NodeKind = enum { rule, step, file, shared, group };
pub const EdgeKind = enum { input, produces, consumes, within, maps, joins, loads, takes };

pub const Node = struct {
    id: []const u8,
    kind: NodeKind,
    label: []const u8,
    step: ?[]const u8 = null,
    sample: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    /// Rules a step node stands for.
    rules: ?usize = null,
    threads: ?u32 = null,
    memory_mib: ?u64 = null,
    /// A shared input: `service` or `mapped`, and its path.
    shared: ?[]const u8 = null,
    path: ?[]const u8 = null,
    /// A resource group's capacity.
    max: ?u32 = null,
};

pub const Edge = struct {
    source: []const u8,
    target: []const u8,
    kind: EdgeKind,
    /// Units of a resource group a rule takes.
    units: ?u32 = null,
    /// A file that links two rules, for `input` edges.
    file: ?[]const u8 = null,
};

pub const View = struct {
    nodes: []const Node,
    edges: []const Edge,
};

pub const Error = error{ UnknownRule, UnknownShared, NoPath, NotSelected, OutOfMemory };

/// The rules a view shows: the selected ones, narrowed by the options.
fn chosen(a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, mask: []const bool, opts: Options) ![]bool {
    const sel = try a.dupe(bool, mask);
    if (opts.focus) |f| {
        const start = wf.ruleIndex(f.rule) orelse return error.UnknownRule;
        const keep = try a.alloc(bool, wf.rules.len);
        @memset(keep, false);
        keep[start] = true;
        if (f.up) |d| try walk(a, g.parents, start, d, keep);
        if (f.down) |d| try walk(a, g.children, start, d, keep);
        for (sel, keep) |*s, k| s.* = s.* and k;
    }
    if (opts.users) |name| {
        const si = wf.sharedIndex(name) orelse return error.UnknownShared;
        for (sel, wf.rules, 0..) |*s, r, i| s.* = s.* and (usesShared(r, name) or loads(wf, g, i, si));
    }
    if (opts.why) |pair| {
        const path = try whyPath(a, wf, g, mask, pair[0], pair[1]);
        @memset(sel, false);
        for (path) |i| sel[i] = true;
    }
    return sel;
}

fn walk(a: Allocator, next: []const []const usize, start: usize, depth: u32, keep: []bool) !void {
    var level: std.ArrayList(usize) = .empty;
    try level.append(a, start);
    var d: u32 = 0;
    while (d < depth and level.items.len > 0) : (d += 1) {
        var following: std.ArrayList(usize) = .empty;
        for (level.items) |i| for (next[i]) |j| if (!keep[j]) {
            keep[j] = true;
            try following.append(a, j);
        };
        level = following;
    }
}

fn usesShared(r: workflow.Rule, name: []const u8) bool {
    for (r.shared) |s| if (eql(u8, s, name)) return true;
    return false;
}

/// Whether rule `i` writes the path of service `si`, or inside it, which the
/// service loads.
fn loads(wf: *const workflow.Workflow, g: *const graph.Graph, i: usize, si: usize) bool {
    const s = wf.shared[si];
    if (!s.isService()) return false;
    const sp = s.path_abs orelse return false;
    for (wf.rules[i].output_abs) |o| if (workflow.within(sp, o)) return true;
    _ = g;
    return false;
}

/// The rules of one path from rule `from` to rule `to`, in order: the
/// shortest, found breadth first through the selected rules (`mask`)
/// reading each one's outputs.
pub fn whyPath(a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, mask: []const bool, from: []const u8, to: []const u8) ![]const usize {
    const s = wf.ruleIndex(from) orelse return error.UnknownRule;
    const t = wf.ruleIndex(to) orelse return error.UnknownRule;
    if (!mask[s] or !mask[t]) return error.NotSelected;
    const prev = try a.alloc(?usize, wf.rules.len);
    @memset(prev, null);
    var queue: std.ArrayList(usize) = .empty;
    try queue.append(a, s);
    var head: usize = 0;
    var found = s == t;
    while (head < queue.items.len and !found) : (head += 1) {
        const i = queue.items[head];
        for (g.children[i]) |c| if (mask[c] and prev[c] == null and c != s) {
            prev[c] = i;
            if (c == t) {
                found = true;
                break;
            }
            try queue.append(a, c);
        };
    }
    if (!found) return error.NoPath;
    var path: std.ArrayList(usize) = .empty;
    var i = t;
    try path.append(a, i);
    while (i != s) {
        i = prev[i].?;
        try path.append(a, i);
    }
    std.mem.reverse(usize, path.items);
    return path.items;
}

/// The first input of rule `c` that rule `p` writes: the file itself, or
/// a directory `p` writes inside.
fn linkFile(wf: *const workflow.Workflow, g: *const graph.Graph, p: usize, c: usize) ?[]const u8 {
    const r = wf.rules[c];
    for (r.input_abs, r.input) |in, written| {
        if (g.producer.get(in)) |pi| if (pi == p) return written;
        for (wf.rules[p].output_abs) |o| if (workflow.within(in, o) and !eql(u8, in, o)) return written;
    }
    return null;
}

/// Builds the view of the rules that `mask` selects.
pub fn build(a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, mask: []const bool, opts: Options) !View {
    const sel = try chosen(a, wf, g, mask, opts);
    var nodes: std.ArrayList(Node) = .empty;
    var edges: std.ArrayList(Edge) = .empty;
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    var edge_ids: std.StringHashMapUnmanaged(void) = .empty;
    const layer = if (opts.users != null and opts.layer == .rules) Layer.resources else opts.layer;
    const files = layer == .files or layer == .all;
    const resources = layer == .resources or layer == .all;

    // The node each rule is drawn as: itself, or its step.
    const unit = try a.alloc([]const u8, wf.rules.len);
    for (g.order) |i| {
        if (!sel[i]) continue;
        const r = wf.rules[i];
        if (opts.by_step) {
            unit[i] = try std.fmt.allocPrint(a, "step:{s}", .{r.labels.step});
            if (ids.get(unit[i])) |k| {
                const n = &nodes.items[k];
                n.rules.? += 1;
                n.threads = @max(n.threads.?, r.threads);
                n.memory_mib = @max(n.memory_mib.?, r.memory_mib);
                continue;
            }
            try ids.put(a, unit[i], nodes.items.len);
            try nodes.append(a, .{ .id = unit[i], .kind = .step, .label = r.labels.step, .step = r.labels.step, .tool = r.labels.tool, .rules = 1, .threads = r.threads, .memory_mib = r.memory_mib });
        } else {
            unit[i] = try std.fmt.allocPrint(a, "rule:{s}", .{r.name});
            try ids.put(a, unit[i], nodes.items.len);
            try nodes.append(a, .{
                .id = unit[i],
                .kind = .rule,
                .label = r.name,
                .step = r.labels.step,
                .sample = r.labels.sample,
                .tool = r.labels.tool,
                .threads = r.threads,
                .memory_mib = r.memory_mib,
            });
        }
    }

    const Add = struct {
        fn edge(al: Allocator, list: *std.ArrayList(Edge), seen: *std.StringHashMapUnmanaged(void), e: Edge) !void {
            const key = try std.fmt.allocPrint(al, "{s}\x00{s}\x00{s}", .{ e.source, e.target, @tagName(e.kind) });
            if (seen.contains(key)) return;
            try seen.put(al, key, {});
            try list.append(al, e);
        }
        fn file(al: Allocator, list: *std.ArrayList(Node), index: *std.StringHashMapUnmanaged(usize), path: []const u8) ![]const u8 {
            const id = try std.fmt.allocPrint(al, "file:{s}", .{path});
            if (index.contains(id)) return id;
            try index.put(al, id, list.items.len);
            try list.append(al, .{ .id = id, .kind = .file, .label = path, .path = path });
            return id;
        }
    };

    for (g.order) |i| {
        if (!sel[i]) continue;
        const r = wf.rules[i];
        if (files) {
            for (r.output_abs) |o| {
                const f = try Add.file(a, &nodes, &ids, workflow.keyPath(wf.root, o));
                try Add.edge(a, &edges, &edge_ids, .{ .source = unit[i], .target = f, .kind = .produces });
            }
            for (r.input_abs) |in| {
                const f = try Add.file(a, &nodes, &ids, workflow.keyPath(wf.root, in));
                try Add.edge(a, &edges, &edge_ids, .{ .source = f, .target = unit[i], .kind = .consumes });
                // The written files inside a directory input lead to it.
                for (graph.below(g.outputs, in)) |o| if (sel[o.rule]) {
                    const inner = try Add.file(a, &nodes, &ids, workflow.keyPath(wf.root, o.path));
                    try Add.edge(a, &edges, &edge_ids, .{ .source = inner, .target = f, .kind = .within });
                };
            }
        } else for (g.parents[i]) |p| {
            if (!sel[p] or eql(u8, unit[p], unit[i])) continue;
            try Add.edge(a, &edges, &edge_ids, .{ .source = unit[p], .target = unit[i], .kind = .input, .file = if (opts.by_step) null else linkFile(wf, g, p, i) });
        }
        if (!resources) continue;
        for (r.shared) |name| {
            const si = wf.sharedIndex(name) orelse continue;
            const s = wf.shared[si];
            const id = try std.fmt.allocPrint(a, "shared:{s}", .{name});
            if (!ids.contains(id)) {
                try ids.put(a, id, nodes.items.len);
                try nodes.append(a, .{
                    .id = id,
                    .kind = .shared,
                    .label = name,
                    .shared = if (s.isService()) "service" else "mapped",
                    .path = if (s.path_abs) |p| workflow.keyPath(wf.root, p) else null,
                    .memory_mib = s.memory_mib,
                });
                // The rules writing what a service loads.
                for (g.order) |p| if (sel[p] and loads(wf, g, p, si))
                    try Add.edge(a, &edges, &edge_ids, .{ .source = unit[p], .target = id, .kind = .loads });
            }
            try Add.edge(a, &edges, &edge_ids, .{ .source = id, .target = unit[i], .kind = if (s.isService()) .joins else .maps });
        }
        for (r.groups) |gu| {
            const id = try std.fmt.allocPrint(a, "group:{s}", .{gu.name});
            if (!ids.contains(id)) {
                try ids.put(a, id, nodes.items.len);
                try nodes.append(a, .{ .id = id, .kind = .group, .label = gu.name, .max = wf.groupMax(gu.name) });
            }
            try Add.edge(a, &edges, &edge_ids, .{ .source = id, .target = unit[i], .kind = .takes, .units = gu.count });
        }
    }
    return .{ .nodes = nodes.items, .edges = edges.items };
}

// ---- output ----

pub fn writeJson(w: *std.Io.Writer, v: View) !void {
    const NodeData = struct { data: Node };
    const EdgeData = struct { data: struct { id: []const u8, source: []const u8, target: []const u8, kind: EdgeKind, units: ?u32, file: ?[]const u8 } };
    var buf: [256]u8 = undefined;
    try w.writeAll("{\"elements\":{\"nodes\":[");
    for (v.nodes, 0..) |n, k| {
        if (k > 0) try w.writeAll(",");
        try w.print("{f}", .{std.json.fmt(NodeData{ .data = n }, .{ .emit_null_optional_fields = false })});
    }
    try w.writeAll("],\"edges\":[");
    for (v.edges, 0..) |e, k| {
        if (k > 0) try w.writeAll(",");
        const id = std.fmt.bufPrint(&buf, "e{d}", .{k}) catch unreachable;
        try w.print("{f}", .{std.json.fmt(EdgeData{ .data = .{ .id = id, .source = e.source, .target = e.target, .kind = e.kind, .units = e.units, .file = e.file } }, .{ .emit_null_optional_fields = false })});
    }
    try w.writeAll("]}}\n");
}

fn quoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        if (c == '\n') {
            try w.writeAll("\\n");
            continue;
        }
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

/// Graphviz DOT: rules and steps as boxes, files as notes, shared inputs
/// as cylinders with their memory, groups as hexagons; edges styled by
/// kind.
pub fn writeDot(a: Allocator, w: *std.Io.Writer, name: []const u8, v: View) !void {
    try w.writeAll("digraph ");
    try quoted(w, name);
    try w.writeAll(" {\n  rankdir=LR;\n  node [shape=box];\n");
    for (v.nodes) |n| {
        try w.writeAll("  ");
        try quoted(w, n.id);
        var text: std.Io.Writer.Allocating = .init(a);
        try text.writer.writeAll(n.label);
        const shape: []const u8 = switch (n.kind) {
            .rule => "box",
            .step => blk: {
                try text.writer.print("\n", .{});
                try units.count(&text.writer, n.rules.?, "rule", "rules");
                break :blk "box3d";
            },
            .file => "note",
            .shared => blk: {
                try text.writer.print("\n{s}", .{n.shared.?});
                if (n.memory_mib) |m| {
                    try text.writer.writeAll(", ");
                    try units.size(&text.writer, @floatFromInt(m));
                }
                break :blk "cylinder";
            },
            .group => blk: {
                if (n.max) |m| try text.writer.print("\nmax {d}", .{m});
                break :blk "hexagon";
            },
        };
        try w.print(" [shape={s}, label=", .{shape});
        try quoted(w, text.written());
        try w.writeAll("];\n");
    }
    for (v.edges) |e| {
        try w.writeAll("  ");
        try quoted(w, e.source);
        try w.writeAll(" -> ");
        try quoted(w, e.target);
        const style: []const u8 = switch (e.kind) {
            .input, .produces, .consumes => "",
            .within => " [style=dotted, arrowhead=none]",
            .maps => " [style=dashed, label=\"maps\"]",
            .joins => " [style=\"dashed,bold\", label=\"joins\"]",
            .loads => " [style=dotted, label=\"loads\"]",
            .takes => "",
        };
        if (e.kind == .takes) {
            try w.print(" [style=dotted, color=gray40, label=\"{d}\"]", .{e.units orelse 1});
        } else try w.writeAll(style);
        try w.writeAll(";\n");
    }
    try w.writeAll("}\n");
}

/// Text: each rule or step with what feeds it and what it feeds, then
/// each shared input with what loads it and what uses it, then groups.
pub fn writeText(a: Allocator, w: *std.Io.Writer, v: View) !void {
    const Lists = struct {
        fn of(al: Allocator, edges: []const Edge, id: []const u8, kind: ?EdgeKind, incoming: bool) ![]const Edge {
            var out: std.ArrayList(Edge) = .empty;
            for (edges) |e| {
                if (kind) |k| if (e.kind != k) continue;
                if (eql(u8, if (incoming) e.target else e.source, id)) try out.append(al, e);
            }
            return out.items;
        }
    };
    for (v.nodes) |n| {
        if (n.kind != .rule and n.kind != .step) continue;
        try w.print("{s}", .{n.label});
        if (n.kind == .step) {
            try w.writeAll(" (");
            try units.count(w, n.rules.?, "rule", "rules");
            try w.writeAll(")");
        }
        try w.print("  {d} {s}, ", .{ n.threads.?, if (n.threads.? == 1) "thread" else "threads" });
        try units.size(w, @floatFromInt(n.memory_mib.?));
        try w.writeAll("\n");
        try names(w, "after", v, try Lists.of(a, v.edges, n.id, .input, true), true);
        try names(w, "before", v, try Lists.of(a, v.edges, n.id, .input, false), false);
        try names(w, "reads", v, try Lists.of(a, v.edges, n.id, .consumes, true), true);
        try names(w, "writes", v, try Lists.of(a, v.edges, n.id, .produces, false), false);
        for (try Lists.of(a, v.edges, n.id, null, true)) |e| switch (e.kind) {
            .maps, .joins => try w.print("  {s} shared {s}\n", .{ @tagName(e.kind), label(v, e.source) }),
            .takes => try w.print("  takes {d} of group {s}\n", .{ e.units orelse 1, label(v, e.source) }),
            else => {},
        };
    }
    for (v.nodes) |n| {
        if (n.kind != .shared) continue;
        try w.print("shared {s}  {s}", .{ n.label, n.shared.? });
        if (n.memory_mib) |m| {
            try w.writeAll(", ");
            try units.size(w, @floatFromInt(m));
            try w.writeAll(" held once");
        }
        if (n.path) |p| try w.print(", {s}", .{p});
        try w.writeAll("\n");
        try names(w, "loaded from", v, try Lists.of(a, v.edges, n.id, .loads, true), true);
        var users: std.ArrayList(Edge) = .empty;
        for (v.edges) |e| if ((e.kind == .maps or e.kind == .joins) and eql(u8, e.source, n.id)) try users.append(a, e);
        try names(w, "used by", v, users.items, false);
    }
    for (v.nodes) |n| {
        if (n.kind != .group) continue;
        try w.print("group {s}  max {d}\n", .{ n.label, n.max orelse 0 });
        var takers: std.ArrayList(Edge) = .empty;
        for (v.edges) |e| if (e.kind == .takes and eql(u8, e.source, n.id)) try takers.append(a, e);
        try names(w, "taken by", v, takers.items, false);
    }
}

fn label(v: View, id: []const u8) []const u8 {
    for (v.nodes) |n| if (eql(u8, n.id, id)) return n.label;
    return id;
}

/// One line of names, the far end of each edge, with the file linking an
/// input edge.
fn names(w: *std.Io.Writer, title: []const u8, v: View, edges: []const Edge, incoming: bool) !void {
    if (edges.len == 0) return;
    try w.print("  {s} ", .{title});
    for (edges, 0..) |e, k| {
        if (k > 0) try w.writeAll(", ");
        try w.writeAll(label(v, if (incoming) e.source else e.target));
        if (e.file) |f| try w.print(" ({s})", .{f});
    }
    if (edges.len > 3) try w.print("  ({d})", .{edges.len});
    try w.writeAll("\n");
}

/// The path `--why` found, one rule per line, each with the file it reads
/// from the one before.
pub fn writeWhy(w: *std.Io.Writer, wf: *const workflow.Workflow, g: *const graph.Graph, path: []const usize) !void {
    for (path, 0..) |i, k| {
        if (k == 0) {
            try w.print("{s}\n", .{wf.rules[i].name});
            continue;
        }
        try w.print("  -> {s}", .{wf.rules[i].name});
        if (linkFile(wf, g, path[k - 1], i)) |f| try w.print("  (reads {s})", .{f});
        try w.writeAll("\n");
    }
}
