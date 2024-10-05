const std = @import("std");
const sprite = @import("sprite");
const particle = @import("particle.zig");
const constants = @import("constants.zig");

pub const Brick = struct {
    pos: [2]f32 = .{ 0, 0 },
    sprite: sprite.Sprite = .brick1,
    emitter: ExplosionEmitter = undefined,
    destroyed: bool = true,
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

pub const EntityType = enum {
    ball,
    laser,
};

pub const Entity = struct {
    type: EntityType = .ball, // TODO introduce null-entity and use that instead of active field?
    active: bool = false,
    pos: [2]f32 = .{ 0, 0 },
    dir: [2]f32 = constants.initial_ball_dir,
    flame: FlameEmitter = undefined,
    explosion: ExplosionEmitter = undefined,
};
