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
        const lib_shd_install = b.addInstallArtifact(lib_shd, .{ .dest_dir = .{ .override = .bin }});
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

    const deps = CoreDependencies{
        .sokol = dep_sokol,
        .cimgui = dep_cimgui,
        .stb = dep_stb,
        .zmath = dep_zmath,
        .shader_path = shader_output,
        .font_path = tool_fontpack_output,
    };

    if (target.result.isWasm()) {
        const dep_emsdk = b.dependency("emsdk", .{});
        const lib = try buildWeb(b, target, optimize, dep_emsdk, deps);
        lib.root_module.addOptions("config", options);
    } else {
        const exe = try buildNative(b, target, optimize, deps, true);
        exe.root_module.addOptions("config", options);
        // TODO debug only
        exe.root_module.addImport("fwatch", dep_fwatch.module("fwatch"));

        const check_exe = try buildNative(b, target, optimize, deps, false);
        // Used with ZLS for better analysis of comptime shenanigans
        const check = b.step("check", "Check if game compiles");
        check.dependOn(&check_exe.step);
    }
}

fn buildFontPackTool(
    b: *Build,
    optimize: OptimizeMode,
    dep_stb: *Build.Dependency,
) !*Build.Step.Compile {
    const tool_fontpack = b.addExecutable(.{
        .name = "fontpack",
        .root_source_file = b.path("tools/fontpack.zig"),
        .target = b.host,
        .optimize = optimize,
    });
    tool_fontpack.addIncludePath(dep_stb.path("."));
    tool_fontpack.addCSourceFile(.{ .file = b.path("tools/stb_impl.c"), .flags = &.{"-O3"} });
    tool_fontpack.linkLibC();
    return tool_fontpack;
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
