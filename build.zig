const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

const sokol = @import("sokol");

const CoreDependencies = struct {
    sokol: *Build.Dependency,
    cimgui: *Build.Dependency,
    stb: *Build.Dependency,
    zmath: *Build.Dependency,

    shader_path: Build.LazyPath,
    font_path: Build.LazyPath,
    sprite_path: Build.LazyPath,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Whether to dynamically load background shader from a shared library, thus
    // allowing for shader reload. If false, the shader will be compiled in to the
    // binary.
    const shader_reload = b.option(bool, "shader-reload", "Enable automatic shader reloading") orelse false;
    if (target.result.isWasm() and shader_reload) {
        std.log.err("Web builds does not support shader reloading.", .{});
        return error.InvalidConfiguration;
    }
    const options = b.addOptions();
    options.addOption(bool, "shader_reload", shader_reload);

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
    const dep_fwatch = b.dependency("zig_file_watch", .{ .target = target, .optimize = optimize });

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

    const tool_spritepack = try buildSpritePackTool(b, optimize);
    const tool_spritepack_run = b.addRunArtifact(tool_spritepack);
    const tool_spritepack_run_step = b.step("spritepack", "Run the sprite packer");
    tool_spritepack_run_step.dependOn(&tool_spritepack_run.step);
    tool_spritepack_run.addFileArg(b.path("assets/sprites.json"));
    const tool_spritepack_output = tool_spritepack_run.addOutputFileArg("sprite.zig");

    const deps = CoreDependencies{
        .sokol = dep_sokol,
        .cimgui = dep_cimgui,
        .stb = dep_stb,
        .zmath = dep_zmath,
        .shader_path = shader_output,
        .font_path = tool_fontpack_output,
        .sprite_path = tool_spritepack_output,
    };

    if (target.result.isWasm()) {
        const dep_emsdk = b.dependency("emsdk", .{});
        const lib = try buildWeb(b, target, optimize, dep_emsdk, deps);
        lib.root_module.addOptions("config", options);
        try addAssets(b, lib);
    } else {
        const exe = try buildNative(b, target, optimize, deps, true);
        exe.root_module.addOptions("config", options);
        try addAssets(b, exe);
        // TODO debug only
        exe.root_module.addImport("fwatch", dep_fwatch.module("fwatch"));

        const check_exe = try buildNative(b, target, optimize, deps, false);
        // Used with ZLS for better analysis of comptime shenanigans
        const check = b.step("check", "Check if game compiles");
        check.dependOn(&check_exe.step);
        try addAssets(b, check_exe);
        check_exe.root_module.addOptions("config", options);

        // Tests
        const tests = b.addTest(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        });

        try addAssets(b, tests);
        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_tests.step);
    }
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

fn buildSpritePackTool(
    b: *Build,
    optimize: OptimizeMode,
) !*Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "spritepack",
        .root_source_file = b.path("tools/spritepack.zig"),
        .target = b.host,
        .optimize = optimize,
    });
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

    // sokol
    const mod_sokol = deps.sokol.module("sokol");
    exe.root_module.addImport("sokol", mod_sokol);

    // imgui
    const mod_cimgui = deps.cimgui.module("cimgui");
    exe.root_module.addImport("cimgui", mod_cimgui);

    // stb
    exe.addIncludePath(deps.stb.path("."));
    exe.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{"-O3"} });

    // zmath
    const mod_zmath = deps.zmath.module("root");
    exe.root_module.addImport("zmath", mod_zmath);

    // tools
    exe.root_module.addAnonymousImport("shader", .{
        .root_source_file = deps.shader_path,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
            .{ .name = "zmath", .module = mod_zmath },
        },
    });
    exe.root_module.addAnonymousImport("font", .{ .root_source_file = deps.font_path });
    exe.root_module.addAnonymousImport("sprite", .{ .root_source_file = deps.sprite_path });

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

    // sokol
    const mod_sokol = deps.sokol.module("sokol");
    lib.root_module.addImport("sokol", mod_sokol);

    // imgui
    const mod_cimgui = deps.cimgui.module("cimgui");
    lib.root_module.addImport("cimgui", mod_cimgui);

    // stb
    lib.addIncludePath(deps.stb.path("."));
    lib.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{"-O3"} });

    // zmath
    const mod_zmath = deps.zmath.module("root");
    lib.root_module.addImport("zmath", mod_zmath);

    // tools
    lib.root_module.addAnonymousImport("shader", .{
        .root_source_file = deps.shader_path,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
            .{ .name = "zmath", .module = mod_zmath },
        },
    });
    lib.root_module.addAnonymousImport("font", .{ .root_source_file = deps.font_path });
    lib.root_module.addAnonymousImport("sprite", .{ .root_source_file = deps.sprite_path });

    const emsdk_sysroot = emSdkLazyPath(b, dep_emsdk, &.{ "upstream", "emscripten", "cache", "sysroot", "include" });
    lib.addSystemIncludePath(emsdk_sysroot);

    // need to inject the Emscripten system header include path into
    // the cimgui C library otherwise the C/C++ code won't find
    // C stdlib headers
    deps.cimgui.artifact("cimgui_clib").addSystemIncludePath(emsdk_sysroot);

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
