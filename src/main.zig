const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const constants = @import("constants.zig");
const gfx = @import("gfx.zig");
const assert = std.debug.assert;

const sokol = @import("sokol");
const sg = sokol.gfx;
const stm = sokol.time;
const slog = sokol.log;
const sapp = sokol.app;
const sglue = sokol.glue;

const shd = @import("shader");
const m = @import("math");

const input = @import("input.zig");

const level = @import("level.zig");
const Level = level.Level;
const SceneManager = @import("scene.zig").SceneManager;
const audio = @import("audio.zig");
const utils = @import("utils.zig");

const levels = .{
    "assets/level1.lvl",
    "assets/level2.lvl",
};

const Texture = gfx.texture.Texture;

const pi = std.math.pi;
const num_audio_samples = 32;

pub const std_options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

const state = @import("state.zig");

const use_gpa = !utils.is_web;

const Rect = m.Rect;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn initializeGame() !void {
    const allocator = if (use_gpa) gpa.allocator() else std.heap.c_allocator;

    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    errdefer sg.shutdown();

    audio.init();
    errdefer audio.deinit();

    stm.setup();

    try gfx.init(allocator);

    try state.init(allocator);
    errdefer state.deinit();
}

// * Sokol

export fn sokolInit() void {
    initializeGame() catch |err| {
        std.log.err("Unable to initialize game: {}", .{err});
        std.process.exit(1);
    };
}

export fn sokolFrame() void {
    state.frame() catch |err| {
        std.log.err("Unable to render frame: {}", .{err});
        std.process.exit(1);
    };
}

export fn sokolEvent(ev: [*c]const sapp.Event) void {
    gfx.ui.handleEvent(ev.*);
    state.handleEvent(ev.*);
}

export fn sokolCleanup() void {
    state.deinit();
    gfx.deinit();
    audio.deinit();
    sg.shutdown();

    if (use_gpa) {
        _ = gpa.deinit();
    }
}

pub fn main() !void {
    sapp.run(.{
        .init_cb = sokolInit,
        .frame_cb = sokolFrame,
        .cleanup_cb = sokolCleanup,
        .event_cb = sokolEvent,
        .width = constants.initial_screen_size[0],
        .height = constants.initial_screen_size[1],
        .icon = .{ .sokol_default = true },
        .window_title = "Game",
        .logger = .{ .func = slog.func },
    });
}
