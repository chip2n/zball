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

    shader_path: Build.LazyPath,
    font_path: Build.LazyPath,
    sprite_data_path: Build.LazyPath,
    sprite_image_path: Build.LazyPath,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{ .target = target, .optimize = optimize });
    const dep_sokol_tools = b.dependency("sokol_tools", .{ .target = target, .optimize = optimize });
    const dep_stb = b.dependency("stb", .{ .target = target, .optimize = optimize });
    const dep_zmath = b.dependency("zmath", .{ .target = target, .optimize = optimize });

    // Shader compilation step
    const shdc_path = blk: {
        if (b.graph.host.result.os.tag == .linux) {
            break :blk "bin/linux/sokol-shdc";
        } else if (b.graph.host.result.os.tag == .macos) {
            break :blk "bin/osx_arm64/sokol-shdc";
        } else if (b.graph.host.result.os.tag == .windows) {
            break :blk "bin/win32/sokol-shdc";
        }
        unreachable;
    };
    const shdc = dep_sokol_tools.path(shdc_path).getPath(b);
    var shader_cmd = b.addSystemCommand(&.{shdc});
    shader_cmd.addPrefixedFileArg("--input=", b.path("src/shaders/main.glsl"));
    const shader_output = shader_cmd.addPrefixedOutputFileArg("--output=", "main.glsl.zig");
    shader_cmd.addArgs(&.{
        "--slang=glsl410:metal_macos:hlsl5:glsl300es:wgsl",
        "--format=sokol_zig",
    });

    // NOTE: On MacOS, shdc executable does not have executable permissions,
    // probably due to this issue: https://github.com/ziglang/zig/issues/21044
    if (b.graph.host.result.os.tag == .macos) {
        var shdc_perm_workaround = b.addSystemCommand(&.{ "chmod", "+x" });
        shdc_perm_workaround.addFileArg(dep_sokol_tools.path(shdc_path));
        shader_cmd.step.dependOn(&shdc_perm_workaround.step);
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
            .target = b.graph.host,
            .optimize = optimize,
        });
        const art_aseprite = dep_aseprite.artifact("aseprite");
        const result = aseprite.exportAseprite(b, art_aseprite, b.path("assets/sprites.ase"));

        const sprite_copy = b.addSystemCommand(&.{"cp"});
        sprite_copy.addFileArg(result.img_data);
        sprite_copy.addFileArg(result.img_path);
        sprite_copy.addArg("assets/");
        const exporter_run_step = b.step("sprite_export", "Run the sprite exporter");
        exporter_run_step.dependOn(&sprite_copy.step);

        sprite_data_path = b.path("assets/sprites.zig");
        sprite_image_path = b.path("assets/sprites.png");
    }

    const deps = CoreDependencies{
        .sokol = dep_sokol,
        .stb = dep_stb,
        .zmath = dep_zmath,
        .shader_path = shader_output,
        .font_path = tool_fontpack_output,
        .sprite_data_path = sprite_data_path,
        .sprite_image_path = sprite_image_path,
    };

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addDeps(b, main_mod, deps);
    try addAssets(b, main_mod);

    if (target.result.isWasm()) {
        const dep_emsdk = b.dependency("emsdk", .{});
        const lib = b.addStaticLibrary(.{
            .name = "game",
            .root_module = main_mod,
        });
        lib.linkLibC();

        const emsdk_sysroot = emSdkLazyPath(b, dep_emsdk, &.{ "upstream", "emscripten", "cache", "sysroot", "include" });
        lib.addSystemIncludePath(emsdk_sysroot);

        const emsdk = deps.sokol.builder.dependency("emsdk", .{});
        const link_step = try sokol.emLinkStep(b, .{
            .lib_main = lib,
            .target = target,
            .optimize = optimize,
            .emsdk = emsdk,
            .use_webgl2 = true,
            .use_webgpu = false,
            .use_emmalloc = true,
            .use_filesystem = false,
            .extra_args = &.{
                "-sUSE_OFFSET_CONVERTER=1",
                "-sSTACK_SIZE=262144",
            },
            .shell_file_path = b.path("shell.html"),
        });

        const run = sokol.emRunStep(b, .{ .name = "game", .emsdk = emsdk });
        run.step.dependOn(&link_step.step);
        b.step("run", "Run the game").dependOn(&run.step);
    } else {
        const name = switch (target.result.os.tag) {
            .linux => "game-linux",
            .macos => "game-macos",
            .windows => "game-win",
            else => unreachable,
        };
        const exe = b.addExecutable(.{ .name = name, .root_module = main_mod });
        b.installArtifact(exe);

        // Check step
        const check_exe = b.addExecutable(.{ .name = name, .root_module = main_mod });
        const check = b.step("check", "Check if game compiles");
        check.dependOn(&check_exe.step);

        // Run step
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.setCwd(b.path("zig-out/bin/"));
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the game");
        run_step.dependOn(&run_cmd.step);

        // Tests
        const tests = b.addTest(.{ .root_module = main_mod });
        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_tests.step);
    }
}

fn addDeps(
    b: *Build,
    step: *Build.Module,
    deps: CoreDependencies,
) void {
    // sokol
    const mod_sokol = deps.sokol.module("sokol");
    step.addImport("sokol", mod_sokol);

    // stb
    step.addIncludePath(deps.stb.path("."));
    step.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{"-O3"} });

    // zmath
    const mod_zmath = deps.zmath.module("root");
    step.addImport("zmath", mod_zmath);

    // math
    const mod_math = b.addModule("math", .{
        .root_source_file = b.path("src/math.zig"),
        .imports = &.{
            .{ .name = "zmath", .module = mod_zmath },
        },
    });
    step.addImport("math", mod_math);

    // tools
    step.addAnonymousImport("shader", .{
        .root_source_file = deps.shader_path,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
            .{ .name = "math", .module = mod_math },
        },
    });
    step.addAnonymousImport("font", .{ .root_source_file = deps.font_path });
    step.addAnonymousImport("sprites.png", .{ .root_source_file = deps.sprite_image_path });
    step.addAnonymousImport("sprites", .{ .root_source_file = deps.sprite_data_path });
}

fn addAssets(b: *Build, step: *Build.Module) !void {
    var dir = try std.fs.cwd().openDir("assets", .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |f| {
        if (f.kind != .file) continue;
        if (!shouldIncludeAsset(f.name)) continue;
        const name = b.pathJoin(&.{ "assets", f.name });
        step.addAnonymousImport(name, .{ .root_source_file = b.path(name) });
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
        .target = b.graph.host,
        .optimize = optimize,
    });
    exe.addIncludePath(dep_stb.path("."));
    exe.addCSourceFile(.{ .file = b.path("tools/stb_impl.c"), .flags = &.{"-O3"} });
    exe.linkLibC();
    return exe;
}

fn emSdkLazyPath(b: *Build, emsdk: *Build.Dependency, subPaths: []const []const u8) Build.LazyPath {
    return emsdk.path(b.pathJoin(subPaths));
}
