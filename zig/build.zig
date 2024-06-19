const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "game",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const c_header = b.addTranslateC(.{
        .root_source_file = b.path("janet.h"),
        .optimize = optimize,
        .target = target,
    });
    const c_module = b.addModule("cjanet", .{
        .root_source_file = .{ .generated = .{ .file = &c_header.output_file } },
    });
    exe.root_module.addImport("cjanet", c_module);

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("sokol", dep_sokol.module("sokol"));

    exe.addIncludePath(b.path("."));
    exe.addCSourceFile(.{ .file = b.path("janet.c"), .flags = &.{"-std=c99", "-O2", "-flto", "-DJANET_NO_NANBOX"} });
    exe.linkSystemLibrary("m");
    exe.linkSystemLibrary("GL");
    exe.linkSystemLibrary("glfw");
    b.installArtifact(exe);

    b.installFile("src/game.janet", "bin/game.janet");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("zig-out/bin/"));
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
