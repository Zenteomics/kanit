//! Unit tests for workz modules.
const std = @import("std");
const workz = @import("workz");

test "the version is a semantic version" {
    var it = std.mem.splitScalar(u8, workz.version, '.');
    var parts: usize = 0;
    while (it.next()) |p| : (parts += 1) _ = try std.fmt.parseInt(u32, p, 10);
    try std.testing.expectEqual(@as(usize, 3), parts);
}
