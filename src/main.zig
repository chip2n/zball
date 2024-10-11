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
const fwatch = @import("fwatch");
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

const debug = if (builtin.os.tag == .linux) struct {
    var watcher: *fwatch.FileWatcher(void) = undefined;
    var reload: bool = false;
} else struct {};

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

    gfx.texture.init(allocator);
    errdefer gfx.texture.deinit();

    stm.setup();

    gfx.ui.init(allocator);
    errdefer gfx.ui.deinit();

    try state.init(allocator);
    errdefer state.deinit();
}

fn onFileEvent(event_type: fwatch.FileEventType, path: []const u8, _: void) !void {
    std.log.info("File event ({}): {s}", .{ event_type, path });
    debug.reload = true;
}

// * Sokol

export fn sokolInit() void {
    initializeGame() catch unreachable;
}

export fn sokolFrame() void {
    state.frame();
}

export fn sokolEvent(ev: [*c]const sapp.Event) void {
    gfx.ui.handleEvent(ev.*);
    state.handleEvent(ev.*);
}

export fn sokolCleanup() void {
    state.deinit();
    gfx.texture.deinit();
    audio.deinit();
    sg.shutdown();
    gfx.ui.deinit();
    if (config.shader_reload) {
        debug.watcher.deinit();
    }

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
        .width = state.window_size[0],
        .height = state.window_size[1],
        .icon = .{ .sokol_default = true },
        .window_title = "Game",
        .logger = .{ .func = slog.func },
    });
}
