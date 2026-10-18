//! Command-line entry point.
const std = @import("std");
const workz = @import("workz");

const usage =
    \\usage: workz <command> [options]
    \\
    \\commands:
    \\  version                  print the engine version
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    if (args.len == 2 and (std.mem.eql(u8, args[1], "version") or std.mem.eql(u8, args[1], "--version"))) {
        try w.interface.print("workz {s}\n", .{workz.version});
        try w.interface.flush();
        return 0;
    }
    std.debug.print("{s}", .{usage});
    return 2;
}
