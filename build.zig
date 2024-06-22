const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

const sokol = @import("sokol");

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{ .target = target, .optimize = optimize });
    const dep_stb = b.dependency("stb", .{ .target = target, .optimize = optimize });
    const dep_zmath = b.dependency("zmath", .{ .target = target, .optimize = optimize });

    if (target.result.isWasm()) {
        const dep_emsdk = b.dependency("emsdk", .{});
        try buildWeb(b, target, optimize, dep_emsdk, dep_sokol, dep_stb, dep_zmath);
    } else {
        try buildNative(b, target, optimize, dep_sokol, dep_stb, dep_zmath);
    }
}

fn buildNative(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    dep_sokol: *Build.Dependency,
    dep_stb: *Build.Dependency,
    dep_zmath: *Build.Dependency,
) !void {
    const exe = b.addExecutable(.{
        .name = "game",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // sokol
    exe.root_module.addImport("sokol", dep_sokol.module("sokol"));

    // stb
    exe.addIncludePath(dep_stb.path("."));
    exe.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{"-O3"} });

    // zmath
    exe.root_module.addImport("zmath", dep_zmath.module("root"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("zig-out/bin/"));
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);
}

fn buildWeb(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    dep_emsdk: *Build.Dependency,
    dep_sokol: *Build.Dependency,
    dep_stb: *Build.Dependency,
    dep_zmath: *Build.Dependency,
) !void {
    const lib = b.addStaticLibrary(.{
        .name = "game",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    // sokol
    lib.root_module.addImport("sokol", dep_sokol.module("sokol"));

    // stb
    lib.addIncludePath(dep_stb.path("."));
    lib.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{"-O3"} });

    // zmath
    lib.root_module.addImport("zmath", dep_zmath.module("root"));

    const emsdk_sysroot = emSdkLazyPath(b, dep_emsdk, &.{ "upstream", "emscripten", "cache", "sysroot", "include" });
    lib.addSystemIncludePath(emsdk_sysroot);
    const emsdk = dep_sokol.builder.dependency("emsdk", .{});
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = lib,
        .target = target,
        .optimize = optimize,
        .emsdk = emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        .extra_args = &.{"-sUSE_OFFSET_CONVERTER=1"},
        .shell_file_path = b.path("src/shell.html").getPath(b),
    });

    const run = sokol.emRunStep(b, .{ .name = "game", .emsdk = emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run the game").dependOn(&run.step);
}

fn emSdkLazyPath(b: *Build, emsdk: *Build.Dependency, subPaths: []const []const u8) Build.LazyPath {
    return emsdk.path(b.pathJoin(subPaths));
}
