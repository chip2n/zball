const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

const sokol = @import("sokol");

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    if (target.result.isWasm()) {
        try buildWeb(b, target, optimize, dep_sokol);
    } else {
        try buildNative(b, target, optimize, dep_sokol);
    }
}

fn buildNative(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, dep_sokol: *Build.Dependency) !void {
    const exe = b.addExecutable(.{
        .name = "game",
        .root_source_file = b.path("src/main2.zig"),
        // .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("sokol", dep_sokol.module("sokol"));

    const c_header = b.addTranslateC(.{
        .root_source_file = b.path("janet.h"),
        .optimize = optimize,
        .target = target,
    });
    const c_module = b.addModule("cjanet", .{
        .root_source_file = .{ .generated = .{ .file = &c_header.output_file } },
    });
    exe.root_module.addImport("cjanet", c_module);

    exe.addIncludePath(b.path("."));
    // "-std=c99", "-O2", "-flto", "-DJANET_NO_NANBOX"
    exe.addCSourceFile(.{ .file = b.path("janet.c"), .flags = &.{} });
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

    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);

}

fn buildWeb(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode, dep_sokol: *Build.Dependency) !void {
    const lib = b.addStaticLibrary(.{
        .name = "game",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main2.zig"),
        // .root_source_file = b.path("src/debug.zig"),
        .link_libc = true,
    });
    lib.root_module.addImport("sokol", dep_sokol.module("sokol"));
    // _ = dep_sokol;

    const c_header = b.addTranslateC(.{
        .root_source_file = b.path("janet.h"),
        .optimize = optimize,
        .target = target,
    });
    const c_module = b.addModule("cjanet", .{
        .root_source_file = .{ .generated = .{ .file = &c_header.output_file } },
    });
    c_module.link_libc = true;
    lib.root_module.addImport("cjanet", c_module);

    lib.addIncludePath(b.path("."));

    c_header.addIncludeDir("/home/chip/.emscripten_cache/sysroot/include");
    c_module.addIncludePath(.{ .cwd_relative = "/home/chip/.emscripten_cache/sysroot/include"});
    lib.addIncludePath(.{ .cwd_relative = "/home/chip/.emscripten_cache/sysroot/include"});

    //"-std=c99", "-O2", "-flto", "-DJANET_NO_NANBOX"
    lib.addCSourceFile(.{ .file = b.path("janet.c"), .flags = &.{"-flto"} });

    b.installFile("src/game.janet", "web/game.janet");

    const emsdk = dep_sokol.builder.dependency("emsdk", .{});
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = lib,
        .target = target,
        .optimize = optimize,
        .emsdk = emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        // .extra_args = &.{"-sUSE_GLFW=3"},
        .extra_args = &.{"-sUSE_OFFSET_CONVERTER=1"},
        // TODO
        .shell_file_path = "/home/chip/dev/janet-sokol/src/shell.html"
    });
    const run = sokol.emRunStep(b, .{ .name = "game", .emsdk = emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run the game").dependOn(&run.step);
}
