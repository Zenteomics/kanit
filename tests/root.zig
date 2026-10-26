//! Unit tests for workz modules, one suite per area. Process behaviour is
//! checked separately by validation/process.sh with real children, cgroups
//! and signals.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");

test {
    testing.refAllDecls(workz);
    testing.refAllDecls(workz.workflow);
    testing.refAllDecls(workz.graph);
    testing.refAllDecls(workz.state);
    testing.refAllDecls(workz.records);
    testing.refAllDecls(workz.process);
    testing.refAllDecls(workz.cgroup);
    testing.refAllDecls(workz.plan);
    testing.refAllDecls(workz.monitor);
    testing.refAllDecls(workz.tracker);
    testing.refAllDecls(workz.fields);
    testing.refAllDecls(workz.report);
    testing.refAllDecls(workz.sys);
    _ = @import("test_workflow.zig");
    _ = @import("test_reuse.zig");
    _ = @import("test_engine.zig");
    _ = @import("test_views.zig");
    _ = @import("test_reports.zig");
}

test "the version is a semantic version" {
    var it = std.mem.splitScalar(u8, workz.version, '.');
    var parts: usize = 0;
    while (it.next()) |p| : (parts += 1) _ = try std.fmt.parseInt(u32, p, 10);
    try std.testing.expectEqual(@as(usize, 3), parts);
}
