const std = @import("std");
const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "aseprite",
        .root_module = mod,
    });

    b.installArtifact(exe);
}

const AsepriteResult = struct {
    img_data: LazyPath,
    img_path: LazyPath,
};

/// Export slices in .ase file to Zig code (storing slice data) and PNG (packed sheet).
pub fn exportAseprite(b: *std.Build, ase: *std.Build.Step.Compile, ase_file_path: LazyPath) AsepriteResult {
    const export_cmd = b.addSystemCommand(&.{ "aseprite", "-b" });
    export_cmd.addFileArg(ase_file_path);
    const json_out = export_cmd.addPrefixedOutputFileArg("--data=", "sprites.json");
    export_cmd.addArgs(&.{ "--format", "json-array" });
    const img_out = export_cmd.addPrefixedOutputFileArg("--sheet=", "sprites.png");
    export_cmd.addArg("--list-slices");

    var ase_run = b.addRunArtifact(ase);
    ase_run.addFileArg(json_out);
    ase_run.step.dependOn(&export_cmd.step);
    return .{
        .img_data = ase_run.addOutputFileArg("sprites.zig"),
        .img_path = img_out,
    };
}

