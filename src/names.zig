//! How text output names rules. A rule whose labels carry a sample is shown
//! by its step and sample: as two columns in lines and tables, and as the one
//! word STEP/SAMPLE where a single word is needed. Every other rule is shown
//! by its name, and so are rules that share a step and sample with another.
//! Commands that take a rule accept the same word (`find`,
//! `Workflow.findRule`). Each rule also carries the tool it names, shown in
//! its own column. Steps and samples are listed in the order their first
//! rule appears, each step with the first tool its rules name.
const std = @import("std");
const workflow = @import("workflow.zig");
const sys = @import("sys.zig");
const fields = @import("fields.zig");
const Allocator = std.mem.Allocator;

pub const Step = struct {
    name: []const u8,
    tool: ?[]const u8 = null,
};

pub const Widths = struct {
    step: usize,
    sample: usize,
    tool: usize = 0,
};

pub const step_max = 24;
pub const sample_max = 20;
pub const tool_max = 16;

pub const Names = struct {
    rule: []const []const u8,
    step: []const []const u8,
    sample: []const []const u8,
    word: []const []const u8,
    tool: []const []const u8,
    step_of: []const u32,
    sample_of: []const ?u32,
    steps: []const Step,
    samples: []const []const u8,
    by_word: std.StringHashMapUnmanaged(u32),

    pub fn init(a: Allocator, rules: anytype) !Names {
        const n = rules.len;
        var count: std.StringHashMapUnmanaged(u32) = .empty;
        const pair = try a.alloc(?[]const u8, n);
        for (rules, pair) |r, *p| {
            p.* = null;
            const sample = r.labels.sample orelse continue;
            p.* = try std.fmt.allocPrint(a, "{s}/{s}", .{ r.labels.step, sample });
            const gop = try count.getOrPut(a, p.*.?);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
        const rule = try a.alloc([]const u8, n);
        const step = try a.alloc([]const u8, n);
        const sample = try a.alloc([]const u8, n);
        const word = try a.alloc([]const u8, n);
        const tool = try a.alloc([]const u8, n);
        const step_of = try a.alloc(u32, n);
        const sample_of = try a.alloc(?u32, n);
        var steps: std.ArrayList(Step) = .empty;
        var samples: std.ArrayList([]const u8) = .empty;
        var step_index: std.StringHashMapUnmanaged(u32) = .empty;
        var sample_index: std.StringHashMapUnmanaged(u32) = .empty;
        var by_word: std.StringHashMapUnmanaged(u32) = .empty;
        try by_word.ensureTotalCapacity(a, @intCast(2 * n));
        for (rules, 0..) |r, i| {
            rule[i] = try a.dupe(u8, r.name);
            by_word.putAssumeCapacity(rule[i], @intCast(i));
            step[i] = rule[i];
            sample[i] = "";
            word[i] = rule[i];
            tool[i] = if (r.labels.tool) |t| try a.dupe(u8, t) else "";
            if (pair[i]) |p| if (count.get(p).? == 1) {
                word[i] = p;
                step[i] = p[0..r.labels.step.len];
                sample[i] = p[r.labels.step.len + 1 ..];
                by_word.putAssumeCapacity(p, @intCast(i));
            };
            const sg = try step_index.getOrPut(a, r.labels.step);
            if (!sg.found_existing) {
                sg.key_ptr.* = try a.dupe(u8, r.labels.step);
                sg.value_ptr.* = @intCast(steps.items.len);
                try steps.append(a, .{ .name = sg.key_ptr.* });
            }
            step_of[i] = sg.value_ptr.*;
            const s = &steps.items[sg.value_ptr.*];
            if (s.tool == null) if (r.labels.tool) |t| {
                s.tool = try a.dupe(u8, t);
            };
            sample_of[i] = null;
            if (r.labels.sample) |name| {
                const mg = try sample_index.getOrPut(a, name);
                if (!mg.found_existing) {
                    mg.key_ptr.* = try a.dupe(u8, name);
                    mg.value_ptr.* = @intCast(samples.items.len);
                    try samples.append(a, mg.key_ptr.*);
                }
                sample_of[i] = mg.value_ptr.*;
            }
        }
        return .{
            .rule = rule,
            .step = step,
            .sample = sample,
            .word = word,
            .tool = tool,
            .step_of = step_of,
            .sample_of = sample_of,
            .steps = steps.items,
            .samples = samples.items,
            .by_word = by_word,
        };
    }

    pub fn find(self: *const Names, token: []const u8) ?usize {
        const i = self.by_word.get(token) orelse return null;
        return i;
    }

    pub fn widths(self: *const Names, mask: ?[]const bool) Widths {
        var w: Widths = .{ .step = 0, .sample = 0 };
        for (self.step, self.sample, self.tool, 0..) |st, sm, tl, i| {
            if (mask) |m| if (!m[i]) continue;
            w.step = @max(w.step, @min(columns(st), step_max));
            w.sample = @max(w.sample, @min(columns(sm), sample_max));
            w.tool = @max(w.tool, @min(columns(tl), tool_max));
        }
        return w;
    }
};

pub fn columns(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub fn ofLaunch(gpa: Allocator, a: Allocator, launch_dir: []const u8) ?Names {
    const info = sys.readFile(gpa, std.fs.path.join(a, &.{ launch_dir, "launch.json" }) catch return null, 1 << 20) catch return null;
    defer gpa.free(info);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, info, .{ .allocate = .alloc_always }) catch return null;
    const workdir = fields.str(v, "workdir") orelse return null;
    var problem: workflow.Problem = .{};
    defer if (problem.message.len > 0) gpa.free(problem.message);
    var wf = workflow.loadRecorded(gpa, std.fs.path.join(a, &.{ launch_dir, "workflow" }) catch return null, workdir, &problem) catch return null;
    defer wf.deinit();
    return Names.init(a, wf.rules) catch null;
}

pub fn resolve(gpa: Allocator, a: Allocator, launch_dir: ?[]const u8, token: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, token, '/') == null) return token;
    const dir = launch_dir orelse return null;
    const n = ofLaunch(gpa, a, dir) orelse return null;
    return n.rule[n.find(token) orelse return null];
}
