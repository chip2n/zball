const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

const sokol = @import("sokol");

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
    });
    const dep_sokol_tools = b.dependency("sokol_tools", .{ .target = target, .optimize = optimize });
    const dep_cimgui = b.dependency("cimgui", .{ .target = target, .optimize = optimize });
    // inject the cimgui header search path into the sokol C library compile step
    const cimgui_root = dep_cimgui.namedWriteFiles("cimgui").getDirectory();
    dep_sokol.artifact("sokol_clib").addIncludePath(cimgui_root);
    const dep_stb = b.dependency("stb", .{ .target = target, .optimize = optimize });
    const dep_zmath = b.dependency("zmath", .{ .target = target, .optimize = optimize });

    // Shader compilation step
    const shdc = dep_sokol_tools.path("bin/linux/sokol-shdc").getPath(b);
    const shader_cmd = b.addSystemCommand(&.{
        shdc,
        "--input=src/shaders/main.glsl",
        "--output=src/shaders/main.glsl.zig",
        "--slang=glsl410:metal_macos:hlsl5:glsl300es:wgsl",
        "--format=sokol_zig",
    });

    if (target.result.isWasm()) {
        const dep_emsdk = b.dependency("emsdk", .{});
        const lib = try buildWeb(b, target, optimize, dep_emsdk, dep_sokol, dep_cimgui, dep_stb, dep_zmath);
        lib.step.dependOn(&shader_cmd.step);
    } else {
        const exe = try buildNative(b, target, optimize, dep_sokol, dep_cimgui, dep_stb, dep_zmath);
        exe.step.dependOn(&shader_cmd.step);
    }
}

fn buildNative(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    dep_sokol: *Build.Dependency,
    dep_cimgui: *Build.Dependency,
    dep_stb: *Build.Dependency,
    dep_zmath: *Build.Dependency,
) !*Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "game",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // sokol
    exe.root_module.addImport("sokol", dep_sokol.module("sokol"));

    // imgui
    exe.root_module.addImport("cimgui", dep_cimgui.module("cimgui"));

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

    return exe;
}

fn buildWeb(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    dep_emsdk: *Build.Dependency,
    dep_sokol: *Build.Dependency,
    dep_cimgui: *Build.Dependency,
    dep_stb: *Build.Dependency,
    dep_zmath: *Build.Dependency,
) !*Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "game",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    // sokol
    lib.root_module.addImport("sokol", dep_sokol.module("sokol"));

    // imgui
    lib.root_module.addImport("cimgui", dep_cimgui.module("cimgui"));

    // stb
    lib.addIncludePath(dep_stb.path("."));
    lib.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{"-O3"} });

    // zmath
    lib.root_module.addImport("zmath", dep_zmath.module("root"));

    const emsdk_sysroot = emSdkLazyPath(b, dep_emsdk, &.{ "upstream", "emscripten", "cache", "sysroot", "include" });
    lib.addSystemIncludePath(emsdk_sysroot);

    // need to inject the Emscripten system header include path into
    // the cimgui C library otherwise the C/C++ code won't find
    // C stdlib headers
    dep_cimgui.artifact("cimgui_clib").addSystemIncludePath(emsdk_sysroot);

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

    return lib;
}

fn emSdkLazyPath(b: *Build, emsdk: *Build.Dependency, subPaths: []const []const u8) Build.LazyPath {
    return emsdk.path(b.pathJoin(subPaths));
}
