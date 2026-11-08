//! Unit tests for kanit modules, one suite per area. Process behaviour is
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
    testing.refAllDecls(workz.run);
    testing.refAllDecls(workz.container);
    testing.refAllDecls(workz.clean);
    testing.refAllDecls(workz.logs);
    testing.refAllDecls(workz.html);
    testing.refAllDecls(workz.model);
    testing.refAllDecls(workz.units);
    testing.refAllDecls(workz.term);
    testing.refAllDecls(workz.tui);
    testing.refAllDecls(workz.views);
    testing.refAllDecls(workz.methods);
    testing.refAllDecls(workz.lint);
    testing.refAllDecls(workz.schema);
    testing.refAllDecls(workz.prepare);
    testing.refAllDecls(workz.cli);
    testing.refAllDecls(workz.schedule);
    testing.refAllDecls(workz.names);
    testing.refAllDecls(workz.clock);
    testing.refAllDecls(workz.log);
    _ = @import("test_workflow.zig");
    _ = @import("test_reuse.zig");
    _ = @import("test_engine.zig");
    _ = @import("test_views.zig");
    _ = @import("test_reports.zig");
    _ = @import("test_cli.zig");
    _ = @import("test_schedule.zig");
    _ = @import("test_names.zig");
    _ = @import("test_log.zig");
}

test "the version is a semantic version" {
    var it = std.mem.splitScalar(u8, workz.version, '.');
    var parts: usize = 0;
    while (it.next()) |p| : (parts += 1) _ = try std.fmt.parseInt(u32, p, 10);
    try std.testing.expectEqual(@as(usize, 3), parts);
}
