//! What `validate` notes beyond what makes a workflow invalid: declarations
//! nothing uses, labels that leave a rule out of the per-sample views, and,
//! with `--inputs`, inputs that exist nowhere and that no rule writes.
const std = @import("std");
const sys = @import("sys.zig");
const workflow = @import("workflow.zig");
const graph = @import("graph.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub fn notes(a: Allocator, w: *std.Io.Writer, wf: *const workflow.Workflow, mask: []const bool) !void {
    for (wf.shared) |s| {
        var used = false;
        for (wf.rules, 0..) |r, i| if (mask[i]) for (r.shared) |n| {
            used = used or eql(u8, n, s.name);
        };
        if (!used) try w.print("note: shared input {s} is used by no selected rule\n", .{s.name});
    }
    for (wf.groups) |g| {
        var used = false;
        for (wf.rules, 0..) |r, i| if (mask[i]) for (r.groups) |gu| {
            used = used or eql(u8, gu.name, g.name);
        };
        if (!used) try w.print("note: resource group {s} is used by no selected rule\n", .{g.name});
    }
    var with: std.StringArrayHashMapUnmanaged(struct { some: usize = 0, missing: ?[]const u8 = null }) = .empty;
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        const gop = try with.getOrPut(a, r.labels.step);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (r.labels.sample) |_| gop.value_ptr.some += 1 else if (gop.value_ptr.missing == null) {
            gop.value_ptr.missing = r.name;
        }
    }
    for (with.keys(), with.values()) |step, v| if (v.some > 0) if (v.missing) |name|
        try w.print("note: rule {s} has no sample, though other rules of step {s} do; it is left out of the per-sample views\n", .{ name, step });
}

pub fn missingInputs(gpa: Allocator, w: *std.Io.Writer, wf: *const workflow.Workflow, g: *const graph.Graph, mask: []const bool) !usize {
    var n: usize = 0;
    for (wf.rules, 0..) |r, i| {
        if (!mask[i]) continue;
        for (r.input_abs, r.input) |in, written| {
            if (g.produces(in)) continue;
            const found = sys.stat(gpa, in) catch |err| {
                n += 1;
                try w.print("input of rule {s}: {s} cannot be read: {s}\n", .{ r.name, written, sys.errorText(err) });
                continue;
            };
            if (found != null) continue;
            n += 1;
            if (try sys.lstat(gpa, in) != null) {
                const target = sys.readlink(gpa, in) catch "";
                defer if (target.len > 0) gpa.free(target);
                try w.print("missing input of rule {s}: {s} (a symlink to {s}, which does not exist)\n", .{ r.name, written, target });
            } else try w.print("missing input of rule {s}: {s}\n", .{ r.name, written });
        }
    }
    if (n > 0) try w.print("{d} missing {s}: create {s}, or fix the {s}\n", .{ n, if (n == 1) "input" else "inputs", if (n == 1) "it" else "them", if (n == 1) "path" else "paths" });
    return n;
}
