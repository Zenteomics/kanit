//! `plan`, `explain` and `verify`: the run's reuse decision, without running.
const std = @import("std");
const sys = @import("sys.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const state = @import("state.zig");
const records = @import("records.zig");
const container = @import("container.zig");
const process = @import("process.zig");
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
    /// Environment part of rule keys (state.envText).
    env_text: []const u8,
    engine_id: []const u8,
    rerun: bool = false,
    rerun_rules: []const []const u8 = &.{},
    cut: ?state.Cutoff = null,
    environ: *const std.process.Environ.Map,
    /// Names passed with --pass-env, which Podman also receives.
    pass_env: []const []const u8 = &.{},
    /// Per rule: key text beyond the command, as the run computes it.
    extras: []const []const u8 = &.{},

    pub fn init(gpa: Allocator, a: Allocator, wf: *const workflow.Workflow, g: *const graph.Graph, st: *state.State, ids: *state.Identities, env_text: []const u8, environ: *const std.process.Environ.Map) !Context {
        return .{
            .environ = environ,
            .gpa = gpa,
            .a = a,
            .wf = wf,
            .g = g,
            .st = st,
            .ids = ids,
            .env_text = env_text,
            .engine_id = state.engine_key_text,
        };
    }

    /// Decides every selected rule in graph order. A rule whose producer
    /// runs also runs, since its inputs will change; when the producer has
    /// `cutoff = true`, the run may still reuse it if the producer's outputs
    /// come out the same.
    pub fn decideAll(self: *Context, mask: []const bool) ![]Decision {
        self.cut = try state.Cutoff.init(self.a, self.gpa, self.wf, self.st, self.ids, false);
        self.extras = try self.resolveExtras(mask);
        const out = try self.a.alloc(Decision, self.wf.rules.len);
        for (out) |*d| d.* = .{ .run = false, .reason = "not selected" };
        for (self.g.order) |i| {
            if (!mask[i]) continue;
            out[i] = try self.decide(i, out);
        }
        return out;
    }

    /// Image IDs of the selected container rules, resolved as the run does;
    /// an image that cannot be resolved keeps its reference and is reported.
    fn resolveExtras(self: *Context, mask: []const bool) ![]const []const u8 {
        var images: std.StringHashMapUnmanaged([]const u8) = .empty;
        const refs = try container.imageRefs(self.a, self.wf, mask);
        if (refs.len > 0) {
            const podman = (try container.findPodman(self.gpa, self.a, self.environ.get("PATH") orelse "/usr/bin:/bin")) orelse {
                std.debug.print("workz: podman is not on PATH; container rules cannot be planned exactly\n", .{});
                return container.ruleExtras(self.a, self.wf, &images);
            };
            // Podman sees the environment a run gives it.
            const envp = try process.Vec.init(self.a, try state.hostEnv(self.a, self.environ, self.pass_env));
            const devnull = try sys.openRead(self.gpa, "/dev/null");
            defer sys.close(devnull);
            var missing: ?[]const u8 = null;
            images = try container.resolveImages(self.gpa, self.a, podman, refs, &envp, devnull, &missing);
            if (missing) |m| std.debug.print("workz: container image {s} is not available locally; a run would refuse\n", .{m});
        }
        return container.ruleExtras(self.a, self.wf, &images);
    }

    fn decide(self: *Context, i: usize, prior: []const Decision) !Decision {
        const r = &self.wf.rules[i];
        // An input that no selected rule produces must exist, or the run
        // refuses to start.
        for (r.input_abs, r.input) |in, written| {
            if (self.g.produces(in)) continue;
            if ((try self.ids.get(in)) == null) return .{ .run = true, .reason = try std.fmt.allocPrint(self.a, "input missing: {s}", .{written}) };
        }
        for (self.g.parents[i]) |p| if (prior[p].run) {
            const pr = &self.wf.rules[p];
            const reason = if (pr.cutoff)
                try std.fmt.allocPrint(self.a, "producer {s} runs; reused if its outputs repeat", .{pr.name})
            else
                try std.fmt.allocPrint(self.a, "producer {s} runs", .{pr.name});
            return .{ .run = true, .reason = reason };
        };
        const e = self.st.data.rules.map.get(r.name) orelse return .{ .run = true, .reason = "no completed record" };
        var missing: ?[]const u8 = null;
        const k = (try state.ruleKey(self.a, self.ids, self.wf, self.g.parents[i], i, self.st, &self.cut.?, Prior{ .ds = prior }, self.env_text, self.engine_id, self.extras[i], &missing)) orelse
            return .{ .run = true, .reason = try std.fmt.allocPrint(self.a, "input missing: {s}", .{missing.?}) };
        const asked = self.rerun or for (self.rerun_rules) |n| {
            if (std.mem.eql(u8, n, r.name)) break true;
        } else false;
        if (asked) return .{ .run = true, .reason = "rerun requested", .key = k };
        const reason = switch (try state.reuseCheck(self.gpa, self.ids, &e, &k)) {
            .reuse => return .{ .run = false, .reason = "unchanged", .key = k },
            .key => |what| if (std.mem.eql(u8, what, "environment")) env: {
                const was = self.st.data.envs.map.get(e.env) orelse break :env "environment changed";
                var changed: std.Io.Writer.Allocating = .init(self.a);
                for (try state.envChanges(self.a, was, self.env_text), 0..) |c, n| try changed.writer.print("{s}{s}", .{ if (n > 0) ", " else "", c.name });
                break :env try std.fmt.allocPrint(self.a, "environment changed: {s}", .{changed.written()});
            } else try std.fmt.allocPrint(self.a, "{s} changed", .{what}),
            .output_missing => |p| try std.fmt.allocPrint(self.a, "output missing: {s}", .{p}),
            .output_changed => |p| try std.fmt.allocPrint(self.a, "output changed: {s} (run refuses without --rerun)", .{p}),
        };
        return .{ .run = true, .reason = reason, .key = k };
    }
};

/// The keys this plan gives the rules it decided, for `state.ruleKey`.
const Prior = struct {
    ds: []const Decision,
    pub fn get(self: Prior, p: usize) ?[]const u8 {
        return if (self.ds[p].key) |k| k.key else null;
    }
};

/// A reason without the rule or file it names, to group decisions:
/// "producer X runs" is "a producer runs", "output missing: P" is
/// "output missing", and so on.
pub fn reasonClass(reason: []const u8) []const u8 {
    if (std.mem.startsWith(u8, reason, "producer ")) return if (std.mem.endsWith(u8, reason, "; reused if its outputs repeat")) "a cutoff producer runs; reused if its outputs repeat" else "a producer runs";
    for ([_][]const u8{ "input missing", "output missing", "output changed" }) |p| if (std.mem.startsWith(u8, reason, p)) return p;
    return reason;
}

/// Counts of the decisions by reason class, largest first.
pub fn printSummary(w: *std.Io.Writer, ctx: *Context, mask: []const bool) !void {
    const ds = try ctx.decideAll(mask);
    var groups: std.StringArrayHashMapUnmanaged(struct { run: bool, n: usize }) = .empty;
    for (ctx.g.order) |i| {
        if (!mask[i]) continue;
        const key = try std.fmt.allocPrint(ctx.a, "{s}\x00{s}", .{ if (ds[i].run) "run" else "reuse", reasonClass(ds[i].reason) });
        const gop = try groups.getOrPut(ctx.a, key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .run = ds[i].run, .n = 0 };
        gop.value_ptr.n += 1;
    }
    const Sort = struct {
        vals: []const @TypeOf(groups.values()[0]),
        pub fn lessThan(s: @This(), x: usize, y: usize) bool {
            return s.vals[x].n > s.vals[y].n;
        }
    };
    groups.sort(Sort{ .vals = groups.values() });
    var runs: usize = 0;
    var reuse: usize = 0;
    for (groups.keys(), groups.values()) |k, v| {
        const reason = k[std.mem.indexOfScalar(u8, k, 0).? + 1 ..];
        try w.print("{d:>6} {s:<5} {s}\n", .{ v.n, if (v.run) "run" else "reuse", reason });
        if (v.run) runs += v.n else reuse += v.n;
    }
    try w.print("{d} to run, {d} to reuse\n", .{ runs, reuse });
}

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
            .{ "environment", e.env, k.env },
            .{ "request", e.request, k.request },
            .{ "writes", e.writes, k.writes },
            .{ "inputs", e.inputs, k.inputs },
            .{ "producers", e.parents, k.parents },
            .{ "engine key", e.engine, k.engine },
        };
        for (parts) |p| try w.print("  {s:<10} {s}\n", .{ p[0], if (std.mem.eql(u8, p[1], p[2])) "same" else "changed" });
        if (!std.mem.eql(u8, e.env, k.env)) if (ctx.st.data.envs.map.get(e.env)) |was| {
            for (try state.envChanges(ctx.a, was, ctx.env_text)) |c| {
                try w.print("    {s}: ", .{c.name});
                try state.describeEnvChange(w, c);
                try w.writeAll("\n");
            }
        };
        if (!std.mem.eql(u8, e.request, k.request)) try w.print("    was: {s}\n    now: {s}\n", .{ e.request, k.request });
        if (!std.mem.eql(u8, e.engine, k.engine)) try w.print("    was: {s}\n    now: {s}\n", .{ e.engine, k.engine });
    }
    // Each input against what this rule's record saw; older records lack
    // that, and are compared with the last identity any rule recorded.
    for (r.input_abs, 0..) |in, n| {
        const now = if (d.key) |k| k.input_ids[n].id else (try ctx.ids.get(in)) orelse {
            try w.print("  input missing: {s}\n", .{in});
            continue;
        };
        const was = for (e.input_ids) |x| {
            if (std.mem.eql(u8, x.path, in)) break x.id;
        } else if (e.input_ids.len == 0) ctx.st.data.files.map.get(in) orelse continue else {
            try w.print("  input added: {s}\n", .{in});
            continue;
        };
        if (!std.mem.eql(u8, was, now)) try w.print("  input changed: {s}\n    was {s}\n    now {s}\n", .{ in, was, now });
    }
    for (e.input_ids) |x| {
        const still = for (r.input_abs) |in| {
            if (std.mem.eql(u8, in, x.path)) break true;
        } else false;
        if (!still) try w.print("  input removed: {s}\n", .{x.path});
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
    var unrecorded: usize = 0;
    const sa = st.allocator();
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        const e = st.data.rules.map.getPtr(r.name) orelse {
            try w.print("unrecorded {s}\n", .{r.name});
            unrecorded += 1;
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
    try w.print(": {s}", .{if (ok) "all match" else "differences found"});
    if (unrecorded > 0) try w.print("; {d} selected {s} no record to check", .{ unrecorded, if (unrecorded == 1) "rule has" else "rules have" });
    try w.writeAll("\n");
    if (stored > 0) try st.save(gpa);
    return ok;
}

pub fn loadState(gpa: Allocator, root: []const u8, a: Allocator) !state.State {
    return state.loadRecorded(gpa, a, try records.recordsDir(a, root));
}

/// What `plan --budget` checks: the budget a launch would have.
pub const Budget = struct {
    threads: u32,
    memory_mib: u64,
    /// Neither was given: every CPU and three quarters of the memory.
    defaults: bool,
};

/// Checks every selected rule against the budget as `run` does before a
/// launch: its threads, and its memory with its shared inputs, each held
/// once, and a container rule's Podman client. Returns how many rules
/// cannot fit, so the launch would be refused.
pub fn printBudget(gpa: Allocator, a: Allocator, w: *std.Io.Writer, wf: *const workflow.Workflow, mask: []const bool, b: Budget) !usize {
    const units = @import("units.zig");
    const run = @import("run.zig");
    try w.print("\nbudget: {d} threads, ", .{b.threads});
    try units.size(w, @floatFromInt(b.memory_mib));
    try w.writeAll(if (b.defaults) " (the defaults; give --max-threads and --max-memory as for run)\n" else "\n");

    // Each shared input's memory, counted once.
    const shared = try a.alloc(?u64, wf.shared.len);
    for (wf.shared, shared) |s, *mib| {
        mib.* = null;
        var used = false;
        for (wf.rules, 0..) |r, i| if (mask[i]) for (r.shared) |n| {
            if (std.mem.eql(u8, n, s.name)) used = true;
        };
        if (!used) continue;
        if (s.memory_mib) |m| {
            mib.* = m + run.container_client_mib;
        } else if (s.path_abs) |p| {
            // Mapped files take their pages; a file not there yet counts 0.
            const bytes = state.pageBytes(gpa, p) catch 0;
            mib.* = std.math.divCeil(u64, bytes, 1024 * 1024) catch unreachable;
        }
        try w.print("shared {s}: ", .{s.name});
        try units.size(w, @floatFromInt(mib.*.?));
        try w.print(" held once{s}\n", .{if (s.memory_mib != null) ", with its Podman client" else ""});
    }

    var largest: ?usize = null;
    var largest_need: u64 = 0;
    var refused: usize = 0;
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        var need = run.reservedMib(&r);
        for (r.shared) |n| if (wf.sharedIndex(n)) |si| {
            need += shared[si] orelse 0;
        };
        if (need > largest_need) {
            largest_need = need;
            largest = i;
        }
        if (r.threads <= b.threads and need <= b.memory_mib) continue;
        refused += 1;
        if (refused > 10) continue;
        try w.print("does not fit: {s} needs {d} {s} and ", .{ r.name, r.threads, if (r.threads == 1) "thread" else "threads" });
        try units.size(w, @floatFromInt(need));
        try w.writeAll("\n");
    }
    if (refused > 10) try w.print("and {d} more rules that do not fit\n", .{refused - 10});
    if (largest) |i| {
        try w.print("largest: {s} needs {d} {s} and ", .{ wf.rules[i].name, wf.rules[i].threads, if (wf.rules[i].threads == 1) "thread" else "threads" });
        try units.size(w, @floatFromInt(largest_need));
        try w.writeAll(" with its shared inputs\n");
    }
    if (refused > 0) {
        try units.count(w, refused, "rule does", "rules do");
        try w.writeAll(" not fit: run would refuse the launch\n");
    } else try w.writeAll("every rule fits\n");
    return refused;
}
