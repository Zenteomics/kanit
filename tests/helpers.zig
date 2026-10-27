//! Helpers shared by the unit test suites: a scratch directory and workflow
//! loading.
const std = @import("std");
const testing = std.testing;
const workz = @import("workz");
const workflow = workz.workflow;
const sys = workz.sys;

/// A temporary working directory under /var/tmp, removed file by file.
pub const Scratch = struct {
    path: []u8,
    files: std.ArrayList([]u8) = .empty,
    dirs: std.ArrayList([]u8) = .empty,

    pub fn init() !Scratch {
        var rnd: [6]u8 = undefined;
        sys.randomBytes(&rnd);
        const path = try std.fmt.allocPrint(testing.allocator, "/var/tmp/workz-test-{s}", .{&std.fmt.bytesToHex(rnd, .lower)});
        try sys.mkdir(testing.allocator, path);
        return .{ .path = path };
    }

    pub fn file(self: *Scratch, name: []const u8, bytes: []const u8) ![]const u8 {
        const p = try std.fs.path.join(testing.allocator, &.{ self.path, name });
        try sys.writeFile(testing.allocator, p, bytes);
        try self.files.append(testing.allocator, p);
        return p;
    }

    pub fn dir(self: *Scratch, name: []const u8) ![]const u8 {
        const p = try std.fs.path.join(testing.allocator, &.{ self.path, name });
        try sys.mkdir(testing.allocator, p);
        try self.dirs.append(testing.allocator, p);
        return p;
    }

    /// A symlink `name` pointing at `target`.
    pub fn link(self: *Scratch, name: []const u8, target: []const u8) !void {
        const linux = std.os.linux;
        const p = try std.fs.path.join(testing.allocator, &.{ self.path, name });
        try self.files.append(testing.allocator, p);
        const pz = try testing.allocator.dupeZ(u8, p);
        defer testing.allocator.free(pz);
        const tz = try testing.allocator.dupeZ(u8, target);
        defer testing.allocator.free(tz);
        _ = try sys.check(linux.symlinkat(tz, linux.AT.FDCWD, pz));
    }

    pub fn deinit(self: *Scratch) void {
        const linux = std.os.linux;
        for (self.files.items) |f| {
            const z = testing.allocator.dupeZ(u8, f) catch unreachable;
            _ = linux.unlinkat(linux.AT.FDCWD, z, 0);
            testing.allocator.free(z);
            testing.allocator.free(f);
        }
        self.files.deinit(testing.allocator);
        var i = self.dirs.items.len;
        while (i > 0) {
            i -= 1;
            sys.rmdir(testing.allocator, self.dirs.items[i]) catch {};
            testing.allocator.free(self.dirs.items[i]);
        }
        self.dirs.deinit(testing.allocator);
        sys.rmdir(testing.allocator, self.path) catch {};
        testing.allocator.free(self.path);
    }
};

pub fn loadText(s: *Scratch, text: []const u8, problem: *workflow.Problem) !workflow.Workflow {
    const p = try s.file("wf.toml", text);
    return workflow.load(testing.allocator, p, s.path, problem);
}

pub fn expectInvalid(text: []const u8, needle: []const u8) !void {
    var s = try Scratch.init();
    defer s.deinit();
    var problem: workflow.Problem = .{};
    defer testing.allocator.free(problem.message);
    var wf = loadText(&s, text, &problem) catch |err| {
        try testing.expectEqual(error.Invalid, err);
        if (std.mem.indexOf(u8, problem.message, needle) == null) {
            std.debug.print("message: {s}\nexpected to contain: {s}\n", .{ problem.message, needle });
            return error.TestUnexpectedResult;
        }
        return;
    };
    wf.deinit();
    return error.TestExpectedInvalid;
}

pub const head = "[workflow]\nname = \"t\"\nversion = \"1\"\n\n";
