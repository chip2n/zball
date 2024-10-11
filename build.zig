const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;
const aseprite = @import("aseprite");

const sokol = @import("sokol");

const CoreDependencies = struct {
    sokol: *Build.Dependency,
    stb: *Build.Dependency,
    zmath: *Build.Dependency,
    zpool: *Build.Dependency,

    shader_path: Build.LazyPath,
    font_path: Build.LazyPath,
    sprite_data_path: Build.LazyPath,
    sprite_image_path: Build.LazyPath,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_sokol_tools = b.dependency("sokol_tools", .{ .target = target, .optimize = optimize });
    const dep_stb = b.dependency("stb", .{ .target = target, .optimize = optimize });
    const dep_zpool = b.dependency("zpool", .{ .target = target, .optimize = optimize });
    const dep_zmath = b.dependency("zmath", .{ .target = target, .optimize = optimize });

    // Shader compilation step
    const shdc = dep_sokol_tools.path("bin/linux/sokol-shdc").getPath(b);
    var shader_cmd = b.addSystemCommand(&.{shdc});
    shader_cmd.addPrefixedFileArg("--input=", b.path("src/shaders/main.glsl"));
    const shader_output = shader_cmd.addPrefixedOutputFileArg("--output=", "main.glsl.zig");
    shader_cmd.addArgs(&.{
        "--slang=glsl410:metal_macos:hlsl5:glsl300es:wgsl",
        "--format=sokol_zig",
    });

    { // Build shaders as a shared library so we can hot reload them
        const lib_shd = b.addSharedLibrary(.{
            .name = "shd",
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tools/shd.zig"),
        });
        const mod_sokol = dep_sokol.module("sokol");
        lib_shd.root_module.addImport("sokol", mod_sokol);

        // zmath
        const mod_zmath = dep_zmath.module("root");
        lib_shd.root_module.addImport("zmath", mod_zmath);

        lib_shd.root_module.addAnonymousImport("shd", .{
            .root_source_file = shader_output,
            .imports = &.{
                .{ .name = "sokol", .module = mod_sokol },
                .{ .name = "zmath", .module = mod_zmath },
            },
        });
        const lib_shd_step = b.step("shd", "Compile shaders as a shared library");
        const lib_shd_install = b.addInstallArtifact(lib_shd, .{ .dest_dir = .{ .override = .bin } });
        lib_shd_step.dependOn(&lib_shd_install.step);
    }

    // Font packer
    const tool_fontpack = try buildFontPackTool(b, optimize, dep_stb);
    const tool_fontpack_run = b.addRunArtifact(tool_fontpack);
    const tool_fontpack_run_step = b.step("fontpack", "Run the font packer");
    tool_fontpack_run_step.dependOn(&tool_fontpack_run.step);
    tool_fontpack_run.addFileArg(b.path("assets/04b09.ttf"));
    const tool_fontpack_output = tool_fontpack_run.addOutputFileArg("font.zig");
    _ = tool_fontpack_run.addOutputFileArg("font.png");

    var sprite_data_path: std.Build.LazyPath = undefined;
    var sprite_image_path: std.Build.LazyPath = undefined;
    { // Aseprite
        const dep_aseprite = b.dependency("aseprite", .{
            .target = target,
            .optimize = optimize,
        });
        const art_aseprite = dep_aseprite.artifact("aseprite");
        const result = aseprite.exportAseprite(b, art_aseprite, b.path("assets/sprites.ase"));
        sprite_data_path = result.img_data;
        sprite_image_path = result.img_path;
    }

    const deps = CoreDependencies{
        .sokol = dep_sokol,
        .stb = dep_stb,
        .zmath = dep_zmath,
        .zpool = dep_zpool,
        .shader_path = shader_output,
        .font_path = tool_fontpack_output,
        .sprite_data_path = sprite_data_path,
        .sprite_image_path = sprite_image_path,
    };

    if (target.result.isWasm()) {
        const dep_emsdk = b.dependency("emsdk", .{});
        const lib = try buildWeb(b, target, optimize, dep_emsdk, deps);
        try addAssets(b, lib);
    } else {
        const exe = try buildNative(b, target, optimize, deps, true);
        try addAssets(b, exe);

        const check_exe = try buildNative(b, target, optimize, deps, false);
        // Used with ZLS for better analysis of comptime shenanigans
        const check = b.step("check", "Check if game compiles");
        check.dependOn(&check_exe.step);
        try addAssets(b, check_exe);

        // Tests
        const tests = b.addTest(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        });

        addDeps(b, tests, deps);
        try addAssets(b, tests);
        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_tests.step);
    }
}

fn addDeps(
    b: *Build,
    step: *Build.Step.Compile,
    deps: CoreDependencies,
) void {
    // sokol
    const mod_sokol = deps.sokol.module("sokol");
    step.root_module.addImport("sokol", mod_sokol);

    // stb
    step.addIncludePath(deps.stb.path("."));
    step.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{"-O3"} });

    // zmath
    const mod_zmath = deps.zmath.module("root");
    step.root_module.addImport("zmath", mod_zmath);

    // zpool
    const mod_zpool = deps.zpool.module("root");
    step.root_module.addImport("zpool", mod_zpool);

    // math
    const mod_math = b.addModule("math", .{
        .root_source_file = b.path("src/math.zig"),
        .imports = &.{
            .{ .name = "zmath", .module = mod_zmath },
        },
    });
    step.root_module.addImport("math", mod_math);

    // tools
    step.root_module.addAnonymousImport("shader", .{
        .root_source_file = deps.shader_path,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
            .{ .name = "zmath", .module = mod_zmath },
        },
    });
    step.root_module.addAnonymousImport("font", .{ .root_source_file = deps.font_path });
    step.root_module.addAnonymousImport("sprites.png", .{ .root_source_file = deps.sprite_image_path });
    step.root_module.addAnonymousImport("sprite", .{ .root_source_file = deps.sprite_data_path });
}

fn addAssets(b: *Build, step: *Build.Step.Compile) !void {
    var dir = try std.fs.cwd().openDir("assets", .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |f| {
        if (f.kind != .file) continue;
        if (!shouldIncludeAsset(f.name)) continue;
        const name = b.pathJoin(&.{ "assets", f.name });
        step.root_module.addAnonymousImport(name, .{ .root_source_file = b.path(name) });
    }
}

fn shouldIncludeAsset(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ".wav", ext)) return true;
    if (std.mem.eql(u8, ".png", ext)) return true;
    if (std.mem.eql(u8, ".json", ext)) return true;
    if (std.mem.eql(u8, ".lvl", ext)) return true;
    return false;
}

fn buildFontPackTool(
    b: *Build,
    optimize: OptimizeMode,
    dep_stb: *Build.Dependency,
) !*Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "fontpack",
        .root_source_file = b.path("tools/fontpack.zig"),
        .target = b.host,
        .optimize = optimize,
    });
    exe.addIncludePath(dep_stb.path("."));
    exe.addCSourceFile(.{ .file = b.path("tools/stb_impl.c"), .flags = &.{"-O3"} });
    exe.linkLibC();
    return exe;
}

fn buildNative(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    deps: CoreDependencies,
    install: bool,
) !*Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "game",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    addDeps(b, exe, deps);

    if (install) {
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

    return exe;
}

fn buildWeb(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    dep_emsdk: *Build.Dependency,
    deps: CoreDependencies,
) !*Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "game",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    addDeps(b, lib, deps);

    const emsdk_sysroot = emSdkLazyPath(b, dep_emsdk, &.{ "upstream", "emscripten", "cache", "sysroot", "include" });
    lib.addSystemIncludePath(emsdk_sysroot);

    const emsdk = deps.sokol.builder.dependency("emsdk", .{});
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = lib,
        .target = target,
        .optimize = optimize,
        .emsdk = emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        .extra_args = &.{"-sUSE_OFFSET_CONVERTER=1"},
        .shell_file_path = b.path("shell.html"),
    });

    const run = sokol.emRunStep(b, .{ .name = "game", .emsdk = emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run the game").dependOn(&run.step);

    return lib;
}

fn emSdkLazyPath(b: *Build, emsdk: *Build.Dependency, subPaths: []const []const u8) Build.LazyPath {
    return emsdk.path(b.pathJoin(subPaths));
}
