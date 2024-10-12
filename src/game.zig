const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const stm = sokol.time;
const sglue = sokol.glue;
const sapp = sokol.app;

const audio = @import("audio.zig");
const input = @import("input.zig");
const m = @import("math");
const utils = @import("utils.zig");
const shd = @import("shader");
const constants = @import("constants.zig");
const sprite = @import("sprite");

const gfx = @import("gfx.zig");
const Viewport = gfx.Viewport;
const Camera = gfx.Camera;
const BatchRenderer = gfx.BatchRenderer;
const SceneManager = @import("scene.zig").SceneManager;
const Texture = gfx.texture.Texture;
const particle = gfx.particle;

const font = @import("font");

const level = @import("level.zig");
const Level = level.Level;
const level_files = .{
    "assets/level1.lvl",
    "assets/level2.lvl",
};

const brick_w = constants.brick_w;
const brick_h = constants.brick_h;

pub const Brick = struct {
    pos: [2]f32 = .{ 0, 0 },
    sprite: sprite.Sprite = .brick1,
    emitter: ExplosionEmitter = undefined,
    destroyed: bool = true,

    pub fn init(x: f32, y: f32, sp: sprite.Sprite) Brick {
        return .{
            .pos = .{ x * brick_w, y * brick_h },
            .sprite = sp,
            .emitter = ExplosionEmitter.init(.{
                .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                .sprites = particleExplosionSprites(.brick1),
            }),
            .destroyed = false,
        };
    }

    pub fn explode(brick: *Brick) void {
        const pos = .{ brick.pos[0] + brick_w / 2, brick.pos[1] + brick_h / 2 };
        brick.emitter = ExplosionEmitter.init(.{
            .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
            .sprites = particleExplosionSprites(brick.sprite),
        });
        brick.emitter.pos = pos;
        brick.emitter.emitting = true;
    }
};

pub const ExplosionEmitter = particle.Emitter(.{
    .loop = false,
    .count = 20,
    .velocity = .{ 100, 0 },
    .velocity_randomness = 1,
    .velocity_sweep = std.math.tau,
    .lifetime = 1,
    .lifetime_randomness = 0.1,
    .gravity = 200,
    .spawn_radius = 2,
    .explosiveness = 1,
});

const brick_explosion_regions = .{
    .{ .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .weight = 1 },
    .{ .bounds = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .weight = 1 },
};
const ball_explosion_regions = .{
    .{ .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .weight = 1 },
    .{ .bounds = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .weight = 1 },
};

const brick_sprites1 = .{.{ .sprite = .brick1, .weight = 1, .regions = &brick_explosion_regions }};
const brick_sprites2 = .{.{ .sprite = .brick2, .weight = 1, .regions = &brick_explosion_regions }};
const brick_sprites3 = .{.{ .sprite = .brick3, .weight = 1, .regions = &brick_explosion_regions }};
const brick_sprites4 = .{.{ .sprite = .brick4, .weight = 1, .regions = &brick_explosion_regions }};
const ball_sprites = .{.{ .sprite = .ball, .weight = 1, .regions = &ball_explosion_regions }};

pub fn particleExplosionSprites(s: sprite.Sprite) []const particle.SpriteDesc {
    return switch (s) {
        .brick1 => &brick_sprites1,
        .brick2 => &brick_sprites2,
        .brick3 => &brick_sprites3,
        .brick4 => &brick_sprites4,
        .ball => &ball_sprites,
        else => unreachable,
    };
}

pub const FlameEmitter = particle.Emitter(.{
    .loop = true,
    .count = 30,
    .velocity = .{ 0, 0 },
    .velocity_randomness = 0,
    .velocity_sweep = 0,
    .lifetime = 1,
    .lifetime_randomness = 0.5,
    .gravity = -30,
    .spawn_radius = 2,
    .explosiveness = 0,
});

pub const particleFlameSprites = &.{
    .{ .sprite = .particle_flame_6, .weight = 0.2 },
    .{ .sprite = .particle_flame_5, .weight = 0.2 },
    .{ .sprite = .particle_flame_4, .weight = 0.4 },
    .{ .sprite = .particle_flame_3, .weight = 0.5 },
    .{ .sprite = .particle_flame_2, .weight = 0.5 },
};

pub fn brickIdToSprite(id: u8) !sprite.Sprite {
    return switch (id) {
        1 => .brick1,
        2 => .brick2,
        3 => .brick3,
        4 => .brick4,
        else => return error.UnknownBrickId,
    };
}

pub fn spriteToBrickId(sp: sprite.Sprite) !u8 {
    return switch (sp) {
        .brick1 => 1,
        .brick2 => 2,
        .brick3 => 3,
        .brick4 => 4,
        else => return error.BrickSpriteMissing,
    };
}

pub var arena: std.heap.ArenaAllocator = undefined;
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

pub fn frame(now: f64) !void {
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

    input.frame();
}

// NOCOMMIT make sapp-agnostic
pub fn handleEvent(ev: sapp.Event) void {
    input.handleEvent(ev);
    gfx.handleEvent(ev);
}
