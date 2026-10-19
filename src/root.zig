//! workz: a local workflow engine for prepared rule graphs.
pub const version = "0.1.0";
pub const sys = @import("sys.zig");
pub const workflow = @import("workflow.zig");
pub const graph = @import("graph.zig");
pub const state = @import("state.zig");
pub const records = @import("records.zig");
pub const process = @import("process.zig");
pub const cgroup = @import("cgroup.zig");
pub const run = @import("run.zig");
pub const plan = @import("plan.zig");
pub const monitor = @import("monitor.zig");
pub const report = @import("report.zig");
