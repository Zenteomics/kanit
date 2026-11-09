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

    /// The widths held to the limits a terminal row allows; longer names
    /// are cut to fit.
    pub fn capped(w: Widths) Widths {
        return .{ .step = @min(w.step, step_max), .sample = @min(w.sample, sample_max), .tool = @min(w.tool, tool_max) };
    }
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
    /// The largest memory request of the rules.
    max_request_mib: u64 = 0,

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
        var largest: u64 = 0;
        if (comptime @hasField(std.meta.Elem(@TypeOf(rules)), "memory_mib")) for (rules) |r| {
            largest = @max(largest, r.memory_mib);
        };
        return .{
            .max_request_mib = largest,
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
            w.step = @max(w.step, columns(st));
            w.sample = @max(w.sample, columns(sm));
            w.tool = @max(w.tool, columns(tl));
        }
        return w;
    }
};

/// The columns `text` takes on a terminal.
pub fn columns(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = codepoint(text, i);
        n += width(c.value);
        i += c.len;
    }
    return n;
}

pub const Codepoint = struct { value: u21, len: usize };

/// The code point at byte `i`, or the byte itself when it starts no valid
/// UTF-8 sequence.
pub fn codepoint(text: []const u8, i: usize) Codepoint {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .value = text[i], .len = 1 };
    if (i + len > text.len) return .{ .value = text[i], .len = 1 };
    const value = std.unicode.utf8Decode(text[i .. i + len]) catch return .{ .value = text[i], .len = 1 };
    return .{ .value = value, .len = len };
}

/// The columns a code point takes: none for combining marks and zero-width
/// characters, two for East Asian wide characters and emoji, else one.
pub fn width(c: u21) usize {
    const zero = [_][2]u21{ .{ 0x0300, 0x036F }, .{ 0x1AB0, 0x1AFF }, .{ 0x1DC0, 0x1DFF }, .{ 0x200B, 0x200F }, .{ 0x20D0, 0x20FF }, .{ 0xFE00, 0xFE0F }, .{ 0xFE20, 0xFE2F } };
    const wide = [_][2]u21{ .{ 0x1100, 0x115F }, .{ 0x2E80, 0x303E }, .{ 0x3041, 0x33FF }, .{ 0x3400, 0x4DBF }, .{ 0x4E00, 0x9FFF }, .{ 0xA000, 0xA4CF }, .{ 0xAC00, 0xD7A3 }, .{ 0xF900, 0xFAFF }, .{ 0xFE30, 0xFE4F }, .{ 0xFF00, 0xFF60 }, .{ 0xFFE0, 0xFFE6 }, .{ 0x1F300, 0x1F64F }, .{ 0x1F900, 0x1F9FF }, .{ 0x20000, 0x3FFFD } };
    if (c < 0x300) return 1;
    for (zero) |r| if (c >= r[0] and c <= r[1]) return 0;
    for (wide) |r| if (c >= r[0] and c <= r[1]) return 2;
    return 1;
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
