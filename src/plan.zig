//! `plan`, `explain` and `verify`: the run's reuse decision, without running.
const std = @import("std");
const sys = @import("sys.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const state = @import("state.zig");
const records = @import("records.zig");
const container = @import("container.zig");
const process = @import("process.zig");
const naming = @import("names.zig");
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
    env_text: []const u8,
    engine_id: []const u8,
    rerun: bool = false,
    rerun_rules: []const []const u8 = &.{},
    cut: ?state.Cutoff = null,
    environ: *const std.process.Environ.Map,
    pass_env: []const []const u8 = &.{},
    extras: []const []const u8 = &.{},
    names: naming.Names,

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
            .names = try naming.Names.init(a, wf.rules),
        };
    }

    pub fn decideAll(self: *Context, mask: []const bool) ![]Decision {
        self.cut = try state.Cutoff.init(self.a, self.gpa, self.wf, self.st, self.ids, false);
        if (self.extras.len == 0) self.extras = try self.resolveExtras(mask);
        const out = try self.a.alloc(Decision, self.wf.rules.len);
        for (out) |*d| d.* = .{ .run = false, .reason = "not selected" };
        for (self.g.order) |i| {
            if (!mask[i]) continue;
            out[i] = try self.decide(i, out);
        }
        return out;
    }

    fn resolveExtras(self: *Context, mask: []const bool) ![]const []const u8 {
        var images: std.StringHashMapUnmanaged([]const u8) = .empty;
        const refs = try container.imageRefs(self.a, self.wf, mask);
        if (refs.len > 0) {
            const podman = (try container.findPodman(self.gpa, self.a, self.environ.get("PATH") orelse "/usr/bin:/bin")) orelse {
                std.debug.print("kanit: podman is not on PATH; container rules cannot be planned exactly\n", .{});
                return container.ruleExtras(self.a, self.wf, &images);
            };
            const envp = try process.Vec.init(self.a, try state.hostEnv(self.a, self.environ, self.pass_env));
            const devnull = try sys.openRead(self.gpa, "/dev/null");
            defer sys.close(devnull);
            var unresolved: ?container.Unresolved = null;
            images = try container.resolveImages(self.gpa, self.a, podman, refs, &envp, devnull, &unresolved, null);
            if (unresolved) |u| std.debug.print("kanit: a run would refuse: {s}\n", .{try u.text(self.a)});
        }
        return container.ruleExtras(self.a, self.wf, &images);
    }

    fn decide(self: *Context, i: usize, prior: []const Decision) !Decision {
        const r = &self.wf.rules[i];
        for (r.input_abs, r.input) |in, written| {
            if (self.g.produces(in)) continue;
            if ((try self.ids.get(in)) == null) return .{ .run = true, .reason = try std.fmt.allocPrint(self.a, "input missing: {s}", .{written}) };
        }
        for (self.g.parents[i]) |p| if (prior[p].run) {
            const pr = &self.wf.rules[p];
            const reason = if (pr.cutoff)
                try std.fmt.allocPrint(self.a, "producer {s} runs; reused if its outputs repeat", .{self.names.word[p]})
            else
                try std.fmt.allocPrint(self.a, "producer {s} runs", .{self.names.word[p]});
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
            .output_changed => |p| try std.fmt.allocPrint(self.a, "output changed: {s} (run refuses without --rerun-rule or --rerun)", .{p}),
        };
        return .{ .run = true, .reason = reason, .key = k };
    }
};

const Prior = struct {
    ds: []const Decision,
    pub fn get(self: Prior, p: usize) ?[]const u8 {
        return if (self.ds[p].key) |k| k.key else null;
    }
};

pub fn reasonClass(reason: []const u8) []const u8 {
    if (std.mem.startsWith(u8, reason, "producer ")) return if (std.mem.endsWith(u8, reason, "; reused if its outputs repeat")) "a cutoff producer runs; reused if its outputs repeat" else "a producer runs";
    for ([_][]const u8{ "input missing", "output missing", "output changed" }) |p| if (std.mem.startsWith(u8, reason, p)) return p;
    return reason;
}

pub fn printSummary(w: *std.Io.Writer, ctx: *const Context, ds: []const Decision, mask: []const bool) !void {
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

fn grouped(ctx: *const Context, mask: []const bool) bool {
    var steps: usize = 0;
    var selected: usize = 0;
    const seen = ctx.a.alloc(bool, ctx.names.steps.len) catch return true;
    @memset(seen, false);
    for (mask, 0..) |m, i| if (m) {
        selected += 1;
        if (ctx.names.sample_of[i] != null) return true;
        if (!seen[ctx.names.step_of[i]]) steps += 1;
        seen[ctx.names.step_of[i]] = true;
    };
    return steps < selected;
}

fn pad(w: *std.Io.Writer, text: []const u8, width: usize) !void {
    try w.writeAll(text);
    try w.splatByteAll(' ', width -| naming.columns(text));
}

pub fn printPlan(w: *std.Io.Writer, ctx: *const Context, ds: []const Decision, mask: []const bool) !void {
    if (!grouped(ctx, mask)) return printRules(w, ctx, ds, mask);
    const n = &ctx.names;
    const Row = struct { rules: usize = 0, run: usize = 0, first: ?usize = null, reasons: std.StringArrayHashMapUnmanaged(usize) = .empty };
    const rows = try ctx.a.alloc(Row, n.steps.len);
    @memset(rows, .{});
    for (ctx.g.order) |i| {
        if (!mask[i]) continue;
        const r = &rows[n.step_of[i]];
        r.rules += 1;
        if (!ds[i].run) continue;
        r.run += 1;
        if (r.first == null) r.first = i;
        const gop = try r.reasons.getOrPut(ctx.a, reasonClass(ds[i].reason));
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var step_w: usize = 4;
    var tool_w: usize = 0;
    for (rows, n.steps) |r, st| if (r.rules > 0) {
        step_w = @max(step_w, naming.columns(st.name));
        tool_w = @max(tool_w, naming.columns(st.tool orelse ""));
    };
    if (tool_w > 0) tool_w = @max(tool_w, 4);
    try pad(w, "STEP", step_w + 2);
    if (tool_w > 0) try pad(w, "TOOL", tool_w + 2);
    try w.writeAll("RULES    RUN  REUSE  WHY\n");
    var runs: usize = 0;
    var reuse: usize = 0;
    for (rows, n.steps) |r, st| {
        if (r.rules == 0) continue;
        runs += r.run;
        reuse += r.rules - r.run;
        try pad(w, st.name, step_w + 2);
        if (tool_w > 0) try pad(w, st.tool orelse "", tool_w + 2);
        try w.print("{d:>5}  {d:>5}  {d:>5}  ", .{ r.rules, r.run, r.rules - r.run });
        if (r.run == 0) {
            try w.writeAll("unchanged\n");
            continue;
        }
        if (r.run == 1) {
            const i = r.first.?;
            if (n.sample[i].len > 0) try w.print("{s}: ", .{n.sample[i]}) else if (!std.mem.eql(u8, n.word[i], st.name)) try w.print("{s}: ", .{n.word[i]});
            try w.print("{s}\n", .{ds[i].reason});
            continue;
        }
        if (r.reasons.count() == 1) {
            try w.print("{s}\n", .{r.reasons.keys()[0]});
            continue;
        }
        for (r.reasons.keys(), r.reasons.values(), 0..) |why, count, k| try w.print("{s}{s} ({d})", .{ if (k > 0) ", " else "", why, count });
        try w.writeAll("\n");
    }
    try w.print("{d} to run, {d} to reuse\n", .{ runs, reuse });
}

pub fn printRules(w: *std.Io.Writer, ctx: *const Context, ds: []const Decision, mask: []const bool) !void {
    const n = &ctx.names;
    const widths = n.widths(mask);
    const step_w = @max(widths.step, 4);
    try pad(w, if (widths.sample > 0) "STEP" else "RULE", step_w + 2);
    if (widths.sample > 0) try pad(w, "SAMPLE", @max(widths.sample, 6) + 2);
    try w.writeAll("DECISION  WHY\n");
    var runs: usize = 0;
    var reuse: usize = 0;
    for (ctx.g.order) |i| {
        if (!mask[i]) continue;
        const d = ds[i];
        if (d.run) runs += 1 else reuse += 1;
        try pad(w, n.step[i], step_w + 2);
        if (widths.sample > 0) try pad(w, n.sample[i], @max(widths.sample, 6) + 2);
        try pad(w, if (d.run) "run" else "reuse", 10);
        try w.print("{s}\n", .{d.reason});
    }
    try w.print("{d} to run, {d} to reuse\n", .{ runs, reuse });
}

pub fn printJson(w: *std.Io.Writer, ctx: *const Context, ds: []const Decision, mask: []const bool) !void {
    const Entry = struct { rule: []const u8, step: []const u8, sample: ?[]const u8, run: bool, reason: []const u8 };
    var list: std.ArrayList(Entry) = .empty;
    var runs: usize = 0;
    for (ctx.g.order) |i| {
        if (!mask[i]) continue;
        const r = &ctx.wf.rules[i];
        runs += @intFromBool(ds[i].run);
        try list.append(ctx.a, .{ .rule = r.name, .step = r.labels.step, .sample = r.labels.sample, .run = ds[i].run, .reason = ds[i].reason });
    }
    try w.print("{f}\n", .{std.json.fmt(.{ .v = records.record_version, .run = runs, .reuse = list.items.len - runs, .rules = list.items }, .{})});
}

pub fn explain(w: *std.Io.Writer, ctx: *Context, mask: []const bool, token: []const u8) !bool {
    const i = ctx.wf.findRule(token) orelse return false;
    const ds = try ctx.decideAll(mask);
    const d = ds[i];
    const r = &ctx.wf.rules[i];
    const name = r.name;
    if (std.mem.eql(u8, ctx.names.word[i], name))
        try w.print("rule {s}: {s} ({s})\n", .{ name, if (d.run) "runs" else "is reused", d.reason })
    else
        try w.print("{s} (rule {s}): {s} ({s})\n", .{ ctx.names.word[i], name, if (d.run) "runs" else "is reused", d.reason });
    const e = ctx.st.data.rules.map.get(name) orelse return true;
    const here = sys.cwd(ctx.a) catch "";
    const attempt = if (here.len > 1 and e.attempt.len > here.len + 1 and std.mem.startsWith(u8, e.attempt, here) and e.attempt[here.len] == '/') e.attempt[here.len + 1 ..] else e.attempt;
    try w.print("  recorded: {s}, attempt {s}\n", .{ e.finished, attempt });
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

const Finding = struct { rule: usize, kind: []const u8, path: ?[]const u8 = null };

pub fn verify(w: *std.Io.Writer, gpa: Allocator, st: *state.State, ids: *state.Identities, wf: *const workflow.Workflow, mask: []const bool, content: bool, json: bool) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var found: std.ArrayList(Finding) = .empty;
    var ok = true;
    var checked: usize = 0;
    var stored: usize = 0;
    var unrecorded: usize = 0;
    const sa = st.allocator();
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        const e = st.data.rules.map.getPtr(r.name) orelse {
            try found.append(a, .{ .rule = i, .kind = "unrecorded" });
            unrecorded += 1;
            continue;
        };
        const outs = try sa.dupe(state.Output, e.outputs);
        for (outs) |*o| {
            checked += 1;
            switch (try state.checkOutput(gpa, ids, o.*)) {
                .intact => {},
                .refreshed => |now| o.id = try sa.dupe(u8, now),
                .missing => {
                    try found.append(a, .{ .rule = i, .kind = "missing", .path = o.path });
                    ok = false;
                    continue;
                },
                .changed => {
                    try found.append(a, .{ .rule = i, .kind = "changed", .path = o.path });
                    ok = false;
                    continue;
                },
            }
            if (!content) continue;
            const d = try sys.sha256File(gpa, o.path);
            if (o.sha256) |want| {
                if (!std.mem.eql(u8, want, &d)) {
                    try found.append(a, .{ .rule = i, .kind = "content", .path = o.path });
                    ok = false;
                }
            } else {
                o.sha256 = try sa.dupe(u8, &d);
                stored += 1;
            }
        }
        e.outputs = outs;
    }
    if (stored > 0) try st.save(gpa);
    const n = try naming.Names.init(a, wf.rules);
    const shown = struct {
        fn path(root: []const u8, p: []const u8) []const u8 {
            return if (p.len > root.len + 1 and std.mem.startsWith(u8, p, root) and p[root.len] == '/') p[root.len + 1 ..] else p;
        }
    }.path;
    if (json) {
        const Entry = struct { rule: []const u8, step: []const u8, sample: ?[]const u8, finding: []const u8, path: ?[]const u8 };
        var list: std.ArrayList(Entry) = .empty;
        for (found.items) |f| try list.append(a, .{ .rule = wf.rules[f.rule].name, .step = wf.rules[f.rule].labels.step, .sample = wf.rules[f.rule].labels.sample, .finding = f.kind, .path = if (f.path) |p| shown(wf.root, p) else null });
        try w.print("{f}\n", .{std.json.fmt(.{ .v = records.record_version, .checked = checked, .by_content = content, .digests_stored = stored, .unrecorded = unrecorded, .ok = ok and unrecorded == 0, .findings = list.items }, .{})});
        return ok and unrecorded == 0;
    }
    const widths = n.widths(mask);
    for (found.items) |f| {
        var row: std.Io.Writer.Allocating = .init(a);
        try pad(&row.writer, f.kind, 12);
        try pad(&row.writer, n.step[f.rule], widths.step + 2);
        if (widths.sample > 0) try pad(&row.writer, n.sample[f.rule], widths.sample + 2);
        if (f.path) |p| try row.writer.writeAll(shown(wf.root, p));
        if (std.mem.eql(u8, f.kind, "content")) try row.writer.writeAll(" differs from its stored digest");
        try w.print("{s}\n", .{std.mem.trimEnd(u8, row.written(), " ")});
    }
    try w.print("{d} {s} checked{s}", .{ checked, if (checked == 1) "output" else "outputs", if (content) " by content" else "" });
    if (stored > 0) try w.print(", {d} digests stored", .{stored});
    try w.print(": {s}", .{if (ok) "all match" else "differences found"});
    if (unrecorded > 0) try w.print("; {d} selected {s} no record to check", .{ unrecorded, if (unrecorded == 1) "rule has" else "rules have" });
    try w.writeAll("\n");
    return ok and unrecorded == 0;
}

pub fn loadState(gpa: Allocator, root: []const u8, a: Allocator) !state.State {
    return state.loadRecorded(gpa, a, try records.recordsDir(a, root));
}

pub const Budget = struct {
    threads: u32,
    memory_mib: u64,
    defaults: bool,
};

pub fn printBudget(gpa: Allocator, a: Allocator, w: *std.Io.Writer, wf: *const workflow.Workflow, runs: []const bool, reused: usize, b: Budget) !usize {
    const units = @import("units.zig");
    const run = @import("run.zig");
    try w.print("\nbudget: {d} {s}, ", .{ b.threads, if (b.threads == 1) "thread" else "threads" });
    try units.size(w, @floatFromInt(b.memory_mib));
    try w.writeAll(if (b.defaults) " (the defaults; give --max-threads and --max-memory as for run)\n" else "\n");
    if (reused > 0) {
        try units.count(w, reused, "reused rule needs", "reused rules need");
        try w.writeAll(" no budget\n");
    }

    var failure: []const u8 = "";
    const shared = run.sharedSizes(gpa, a, wf, runs, &failure) catch |err| switch (err) {
        error.Unmeasurable => {
            try w.print("cannot measure {s}: run would refuse the launch\n", .{failure});
            return 1;
        },
        else => return err,
    };
    for (wf.shared, shared) |s, z| {
        const size = z orelse continue;
        try w.print("shared {s}: ", .{s.name});
        try units.size(w, @floatFromInt(size.reserve_mib));
        try w.print(" held once{s}\n", .{if (s.memory_mib != null) ", with its Podman client" else ""});
    }

    var largest: ?usize = null;
    var largest_need: u64 = 0;
    var refused: usize = 0;
    for (wf.rules, 0..) |r, i| {
        if (!runs[i]) continue;
        const need = run.neededMib(&r, shared);
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
