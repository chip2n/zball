const std = @import("std");

const audio = @import("audio.zig");
const input = @import("input.zig");
const m = @import("math");
const utils = @import("utils.zig");
const shd = @import("shader");
const constants = @import("constants.zig");
const sprite = @import("sprites");

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

const brick_explosion_regions = [_]particle.SpriteRegion{
    .{ .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .weight = 0.3 },
    .{ .bounds = .{ .x = 1, .y = 1, .w = 1, .h = 1 }, .weight = 1 },
    .{ .bounds = .{ .x = 2, .y = 2, .w = 1, .h = 1 }, .weight = 1 },
    .{ .bounds = .{ .x = 1, .y = 1, .w = 2, .h = 2 }, .weight = 1 },
};
const ball_explosion_regions = [_]particle.SpriteRegion{
    .{ .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .weight = 1 },
    .{ .bounds = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .weight = 1 },
};

const brick_sprites1 = [_]particle.SpriteDesc{.{ .sprite = .brick1a, .weight = 1, .regions = &brick_explosion_regions }};
const brick_sprites2 = [_]particle.SpriteDesc{.{ .sprite = .brick2a, .weight = 1, .regions = &brick_explosion_regions }};
const brick_sprites3 = [_]particle.SpriteDesc{.{ .sprite = .brick3a, .weight = 1, .regions = &brick_explosion_regions }};
const brick_sprites4 = [_]particle.SpriteDesc{.{ .sprite = .brick4a, .weight = 1, .regions = &brick_explosion_regions }};
const brick_sprites_expl = [_]particle.SpriteDesc{.{ .sprite = .brick_expl, .weight = 1, .regions = &brick_explosion_regions }};
const brick_sprites_metal = [_]particle.SpriteDesc{.{ .sprite = .brick_metal, .weight = 1, .regions = &brick_explosion_regions }};
const brick_sprites_hidden = [_]particle.SpriteDesc{.{ .sprite = .brick_hidden, .weight = 1, .regions = &brick_explosion_regions }};
const ball_sprites = [_]particle.SpriteDesc{.{ .sprite = .ball_normal, .weight = 1, .regions = &ball_explosion_regions }};

pub fn particleExplosionSprites(s: sprite.Sprite) []const particle.SpriteDesc {
    return switch (s) {
        .brick1a => &brick_sprites1,
        .brick1b => &brick_sprites1,
        .brick2a => &brick_sprites2,
        .brick2b => &brick_sprites2,
        .brick3a => &brick_sprites3,
        .brick3b => &brick_sprites3,
        .brick4a => &brick_sprites4,
        .brick4b => &brick_sprites4,
        .brick_expl => &brick_sprites_expl,
        .brick_metal => &brick_sprites_metal,
        .brick_metal_weak => &brick_sprites_metal,
        .brick_metal_weak2 => &brick_sprites_metal,
        .brick_metal_weak3 => &brick_sprites_metal,
        .brick_hidden => &brick_sprites_hidden,
        .ball_smallest => &ball_sprites,
        .ball_smaller => &ball_sprites,
        .ball_normal => &ball_sprites,
        .ball_larger => &ball_sprites,
        .ball_largest => &ball_sprites,
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

pub const particleFlameSprites = [_]particle.SpriteDesc{
    .{ .sprite = .particle_flame_6, .weight = 0.2 },
    .{ .sprite = .particle_flame_5, .weight = 0.2 },
    .{ .sprite = .particle_flame_4, .weight = 0.4 },
    .{ .sprite = .particle_flame_3, .weight = 0.5 },
    .{ .sprite = .particle_flame_2, .weight = 0.5 },
};

pub const BrickId = enum(u8) {
    grey = 1,
    red = 2,
    green = 3,
    blue = 4,
    explode = 5,
    metal = 6,
    hidden = 7,

    pub fn parse(n: u8) !BrickId {
        return std.meta.intToEnum(BrickId, n);
    }

    // Some bricks have variations, so we return a slice of possible sprites
    pub fn sprites(id: BrickId) []const sprite.Sprite {
        return switch (id) {
            .grey => &[_]sprite.Sprite{ .brick1a, .brick1b },
            .red => &[_]sprite.Sprite{ .brick2a, .brick2b },
            .green => &[_]sprite.Sprite{ .brick3a, .brick3b },
            .blue => &[_]sprite.Sprite{ .brick4a, .brick4b },
            .explode => &[_]sprite.Sprite{ .brick_expl },
            .metal => &[_]sprite.Sprite{ .brick_metal },
            .hidden => &[_]sprite.Sprite{ .brick_hidden },
        };
    }
};

pub fn brickIdToSprite(id: BrickId) sprite.Sprite {
    // Randomize a variant for this brick
    const rng = prng.random();
    const variations = id.sprites();
    return variations[rng.intRangeLessThan(usize, 0, variations.len)];
}

pub fn spriteToBrickId(sp: sprite.Sprite) !BrickId {
    return switch (sp) {
        .brick1a => .grey,
        .brick1b => .grey,
        .brick2a => .red,
        .brick2b => .red,
        .brick3a => .green,
        .brick3b => .green,
        .brick4a => .blue,
        .brick4b => .blue,
        .brick_expl => .explode,
        .brick_metal => .metal,
        .brick_metal_weak => .metal,
        .brick_metal_weak2 => .metal,
        .brick_metal_weak3 => .metal,
        .brick_hidden => .hidden,
        else => return error.BrickSpriteMissing,
    };
}

pub var arena: std.heap.ArenaAllocator = undefined;
pub var prng: std.Random.DefaultPrng = undefined;
pub var time: f64 = 0;
pub var dt: f32 = 0;
pub var levels: std.ArrayList(Level) = undefined;
pub var scene_mgr: SceneManager = undefined;
pub var fb_current: gfx.Framebuffer = undefined;
pub var fb_transition: gfx.Framebuffer = undefined;

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
        const lvl = try level.readLevel(arena.allocator(), fbs.reader());
        errdefer lvl.deinit();
        try levels.append(lvl);
    }

    fb_current = gfx.createFramebuffer();
    fb_transition = gfx.createFramebuffer();
    scene_mgr = SceneManager.init(allocator, levels.items);

    const seed: u64 = @bitCast(std.time.milliTimestamp());
    std.log.info("Seed: {}", .{seed});
    prng = std.Random.DefaultPrng.init(seed);
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
    try scene_mgr.current.frame(dt);

    // TODO render FPS when player presses a button
    // gfx.setTexture(gfx.fontTexture());
    // var buf: [64]u8 = undefined;
    // const text = try std.fmt.bufPrint(&buf, "{d:2}", .{dt});
    // gfx.renderText(text, 16, 16, 5);

    gfx.renderMain(fb_current);

    if (scene_mgr.next) |*next| {
        try next.frame(dt);
        gfx.renderMain(fb_transition);
    }

    gfx.beginFrame();
    defer gfx.endFrame();

    gfx.renderFramebuffer(fb_current, 100);
    if (scene_mgr.next != null) {
        gfx.renderFramebuffer(fb_transition, scene_mgr.transition_progress);
    }

    input.frame();
}
