const std = @import("std");
const builtin = @import("builtin");

const constants = @import("constants.zig");
const gfx = @import("gfx.zig");
const input = @import("input.zig");
const audio = @import("audio.zig");
const utils = @import("utils.zig");
const state = @import("state.zig");

const sokol = @import("sokol");
const sg = sokol.gfx;
const stm = sokol.time;
const slog = sokol.log;
const sapp = sokol.app;
const sglue = sokol.glue;

pub const std_options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

const use_gpa = !utils.is_web;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// * Sokol

pub fn main() !void {
    sapp.run(.{
        .init_cb = sokolInit,
        .frame_cb = sokolFrame,
        .cleanup_cb = sokolCleanup,
        .event_cb = sokolEvent,
        .width = constants.initial_screen_size[0],
        .height = constants.initial_screen_size[1],
        .icon = .{ .sokol_default = true },
        .window_title = "ZBall",
        .logger = .{ .func = slog.func },
    });
}

export fn sokolInit() void {
    const allocator = if (use_gpa) gpa.allocator() else std.heap.c_allocator;

    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    stm.setup();

    gfx.init(allocator) catch |err| {
        std.log.err("Unable to initialize graphics system: {}", .{err});
        std.process.exit(1);
    };

    audio.init();

    state.init(allocator) catch |err| {
        std.log.err("Unable to initialize game state: {}", .{err});
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

