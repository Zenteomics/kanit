//! Builds the workz executable and its unit tests.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Shipped builds (ReleaseSafe) are stripped; -Dstrip=false keeps symbols for profiling.
    const strip = b.option(bool, "strip", "Strip debug information") orelse (optimize != .Debug);

    const toml = b.dependency("z_toml", .{ .target = target, .optimize = optimize }).module("toml");

    const workz = b.addModule("workz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    workz.addImport("toml", toml);

    const exe = b.addExecutable(.{
        .name = "workz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    exe.root_module.addImport("workz", workz);
    b.installArtifact(exe);
    // The licence, and the notice of z-toml, which the binary links, ship with it.
    b.installFile("LICENSE", "share/doc/workz/LICENSE");
    b.installFile("THIRD_PARTY.md", "share/doc/workz/THIRD_PARTY.md");

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run workz").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("workz", workz);
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
