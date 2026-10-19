//! `plan`, `explain` and `verify`: the run's reuse decision, without running.
const std = @import("std");
const sys = @import("sys.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const state = @import("state.zig");
const records = @import("records.zig");
const Allocator = std.mem.Allocator;

pub const Decision = struct {
    run: bool,
    reason: []const u8,
    key: ?state.Key = null,
};

pub const Context = struct {
    gpa: Allocator,
    a: Allocator,
    wf: *const workflow.Workflow,
    g: *const graph.Graph,
    st: *state.State,
    ids: *state.Identities,
    path_env: []const u8,
    engine_id: []const u8,
    rerun: bool = false,

    pub fn init(gpa: Allocator, a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, st: *state.State, ids: *state.Identities, path_env: []const u8) !Context {
        return .{
            .gpa = gpa,
            .a = a,
            .wf = wf,
            .g = g,
            .st = st,
            .ids = ids,
            .path_env = path_env,
            .engine_id = state.engine_key_text,
        };
    }

    /// Decides every selected rule in graph order. A rule whose producer
    /// runs also runs: its inputs will change.
    pub fn decideAll(self: *Context, mask: []const bool) ![]Decision {
        const out = try self.a.alloc(Decision, self.wf.rules.len);
        for (out) |*d| d.* = .{ .run = false, .reason = "not selected" };
        for (self.g.order) |i| {
            if (!mask[i]) continue;
            out[i] = try self.decide(i, out);
        }
        return out;
    }

    fn decide(self: *Context, i: usize, prior: []const Decision) !Decision {
        const r = &self.wf.rules[i];
        for (self.g.parents[i]) |p| if (prior[p].run) return .{ .run = true, .reason = try std.fmt.allocPrint(self.a, "producer {s} runs", .{self.wf.rules[p].name}) };
        const e = self.st.data.rules.map.get(r.name) orelse return .{ .run = true, .reason = "no completed record" };
        var names: std.ArrayList([]const u8) = .empty;
        var keys: std.ArrayList([]const u8) = .empty;
        for (self.g.parents[i]) |p| {
            try names.append(self.a, self.wf.rules[p].name);
            try keys.append(self.a, if (prior[p].key) |k| k.key else if (self.st.data.rules.map.get(self.wf.rules[p].name)) |pe| pe.key else "none");
        }
        var missing: ?[]const u8 = null;
        const k = (try state.computeKey(self.a, self.ids, r, self.path_env, names.items, keys.items, self.engine_id, &missing)) orelse
            return .{ .run = true, .reason = try std.fmt.allocPrint(self.a, "input missing: {s}", .{missing.?}) };
        if (self.rerun) return .{ .run = true, .reason = "rerun requested", .key = k };
        if (state.firstDifference(&e, &k)) |what| return .{ .run = true, .reason = try std.fmt.allocPrint(self.a, "{s} changed", .{what}), .key = k };
        for (e.outputs) |o| {
            const id = (try self.ids.get(o.path)) orelse return .{ .run = true, .reason = try std.fmt.allocPrint(self.a, "output missing: {s}", .{o.path}), .key = k };
            if (!std.mem.eql(u8, id, o.id)) return .{ .run = true, .reason = try std.fmt.allocPrint(self.a, "output changed: {s} (run refuses without --rerun)", .{o.path}), .key = k };
        }
        return .{ .run = false, .reason = "unchanged", .key = k };
    }
};

pub fn printPlan(w: *std.Io.Writer, ctx: *Context, mask: []const bool) !void {
    const ds = try ctx.decideAll(mask);
    var runs: usize = 0;
    var reuse: usize = 0;
    for (ctx.g.order) |i| {
        if (!mask[i]) continue;
        const d = ds[i];
        if (d.run) runs += 1 else reuse += 1;
        try w.print("{s:<5} {s}  ({s})\n", .{ if (d.run) "run" else "reuse", ctx.wf.rules[i].name, d.reason });
    }
    try w.print("{d} to run, {d} to reuse\n", .{ runs, reuse });
}

/// Explains one rule: each part of its key against the recorded entry, and
/// which input files changed since they were last recorded.
pub fn explain(w: *std.Io.Writer, ctx: *Context, mask: []const bool, name: []const u8) !bool {
    const i = ctx.wf.ruleIndex(name) orelse return false;
    const ds = try ctx.decideAll(mask);
    const d = ds[i];
    const r = &ctx.wf.rules[i];
    try w.print("rule {s}: {s} ({s})\n", .{ name, if (d.run) "runs" else "is reused", d.reason });
    const e = ctx.st.data.rules.map.get(name) orelse return true;
    try w.print("  recorded: {s}, attempt {s}\n", .{ e.finished, e.attempt });
    if (d.key) |k| {
        const parts = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "command", e.command, k.command },
            .{ "PATH", e.env, k.env },
            .{ "request", e.request, k.request },
            .{ "writes", e.writes, k.writes },
            .{ "inputs", e.inputs, k.inputs },
            .{ "producers", e.parents, k.parents },
            .{ "engine key", e.engine, k.engine },
        };
        for (parts) |p| try w.print("  {s:<10} {s}\n", .{ p[0], if (std.mem.eql(u8, p[1], p[2])) "same" else "changed" });
        if (!std.mem.eql(u8, e.request, k.request)) try w.print("    was: {s}\n    now: {s}\n", .{ e.request, k.request });
        if (!std.mem.eql(u8, e.engine, k.engine)) try w.print("    was: {s}\n    now: {s}\n", .{ e.engine, k.engine });
    }
    for (r.input_abs) |in| {
        const now = (try ctx.ids.get(in)) orelse {
            try w.print("  input missing: {s}\n", .{in});
            continue;
        };
        const was = ctx.st.data.files.map.get(in) orelse continue;
        if (!std.mem.eql(u8, was, now)) try w.print("  input changed: {s}\n    was {s}\n    now {s}\n", .{ in, was, now });
    }
    for (ctx.g.parents[i]) |p| if (ds[p].run) try w.print("  producer runs: {s} ({s})\n", .{ ctx.wf.rules[p].name, ds[p].reason });
    return true;
}

/// Checks recorded outputs of the selected rules. With `content`, hashes
/// them, compares against stored digests and stores missing ones.
pub fn verify(w: *std.Io.Writer, gpa: Allocator, st: *state.State, ids: *state.Identities, wf: *const workflow.Workflow, mask: []const bool, content: bool) !bool {
    var ok = true;
    var checked: usize = 0;
    var stored: usize = 0;
    const sa = st.allocator();
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        const e = st.data.rules.map.getPtr(r.name) orelse {
            try w.print("unrecorded {s}\n", .{r.name});
            continue;
        };
        const outs = try sa.dupe(state.Output, e.outputs);
        for (outs) |*o| {
            checked += 1;
            const id = (try ids.get(o.path)) orelse {
                try w.print("missing   {s}: {s}\n", .{ r.name, o.path });
                ok = false;
                continue;
            };
            if (!std.mem.eql(u8, id, o.id)) {
                try w.print("changed   {s}: {s}\n", .{ r.name, o.path });
                ok = false;
                continue;
            }
            if (!content) continue;
            const d = try sys.sha256File(gpa, o.path);
            if (o.sha256) |want| {
                if (!std.mem.eql(u8, want, &d)) {
                    try w.print("content   {s}: {s} differs from its stored digest\n", .{ r.name, o.path });
                    ok = false;
                }
            } else {
                o.sha256 = try sa.dupe(u8, &d);
                stored += 1;
            }
        }
        e.outputs = outs;
    }
    try w.print("{d} outputs checked{s}", .{ checked, if (content) " by content" else "" });
    if (stored > 0) try w.print(", {d} digests stored", .{stored});
    try w.print(": {s}\n", .{if (ok) "all match" else "differences found"});
    if (stored > 0) try st.save(gpa);
    return ok;
}

pub fn loadState(gpa: Allocator, root: []const u8, a: Allocator) !state.State {
    const rec = try records.recordsDir(a, root);
    var st = try state.load(gpa, rec);
    errdefer st.deinit();
    for (try records.Journal.unfinished(gpa, a, rec)) |name| _ = st.data.rules.map.swapRemove(name);
    return st;
}
