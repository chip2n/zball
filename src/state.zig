const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const stm = sokol.time;
const sglue = sokol.glue;
const sapp = sokol.app;

const audio = @import("audio.zig");
const m = @import("math");
const utils = @import("utils.zig");
const shd = @import("shader");
const constants = @import("constants.zig");

const gfx = @import("gfx.zig");
const Viewport = gfx.Viewport;
const Camera = gfx.Camera;
const BatchRenderer = gfx.BatchRenderer;
const SceneManager = @import("scene.zig").SceneManager;
const Texture = gfx.texture.Texture;

const font = @import("font");

const level = @import("level.zig");
const Level = level.Level;
const level_files = .{
    "assets/level1.lvl",
    "assets/level2.lvl",
};

pub var arena: std.heap.ArenaAllocator = undefined;

/// Mouse position in unscaled pixels
pub var mouse_pos: [2]f32 = .{ 0, 0 };
pub var mouse_delta: [2]f32 = .{ 0, 0 };

pub var time: f64 = 0;
pub var dt: f32 = 0;

pub var levels: std.ArrayList(Level) = undefined;
pub var scene_mgr: SceneManager = undefined;

pub var current_framebuffer: gfx.Framebuffer = undefined;
pub var transition_framebuffer: gfx.Framebuffer = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    arena = std.heap.ArenaAllocator.init(allocator);

    gfx.init(allocator) catch |err| {
        std.log.err("Unable to initialize graphics system: {}", .{err});
        std.process.exit(1);
    };

    audio.init();

    // load all levels
    levels = std.ArrayList(Level).init(arena.allocator());
    errdefer levels.deinit();
    inline for (level_files) |path| {
        const data = @embedFile(path);
        var fbs = std.io.fixedBufferStream(data);
        const lvl = try level.parseLevel(arena.allocator(), fbs.reader());
        errdefer lvl.deinit(arena.allocator());
        try levels.append(lvl);
    }

    current_framebuffer = gfx.createFramebuffer();
    transition_framebuffer = gfx.createFramebuffer();
    scene_mgr = SceneManager.init(allocator, levels.items);

}

pub fn deinit() void {
    scene_mgr.deinit();
    gfx.deinit();
    audio.deinit();
    arena.deinit();
}

pub fn frame() !void {
    const ticks = stm.now();
    const now = stm.sec(ticks);
    const new_dt: f32 = @floatCast(now - time);
    dt = new_dt;
    time = now;

    try scene_mgr.update(dt);

    // Render the current scene, as well as the next scene if we're transitioning
    gfx.setFramebuffer(current_framebuffer);
    try scene_mgr.current.frame(dt);
    if (scene_mgr.next) |*next| {
        gfx.setFramebuffer(transition_framebuffer);
        try next.frame(dt);
    }

    gfx.beginFrame();
    defer gfx.endFrame();

    gfx.renderFramebuffer(current_framebuffer, 100);
    if (scene_mgr.next != null) {
        gfx.renderFramebuffer(transition_framebuffer, scene_mgr.transition_progress);
    }

    // Reset mouse delta
    mouse_delta = .{ 0, 0 };
}

// NOCOMMIT make sapp-agnostic
pub fn handleEvent(ev: sapp.Event) void {
    gfx.ui.handleEvent(ev);
    switch (ev.type) {
        .RESIZED => {
            const width = ev.window_width;
            const height = ev.window_height;
            gfx.resize(width, height);
        },
        .MOUSE_MOVE => {
            mouse_pos = .{ ev.mouse_x, ev.mouse_y };
            mouse_delta = m.vadd(mouse_delta, .{ ev.mouse_dx, ev.mouse_dy });
        },
        else => {
            scene_mgr.handleInput(ev) catch |err| {
                std.log.err("Error while processing input: {}", .{err});
            };
        },
    }
}
