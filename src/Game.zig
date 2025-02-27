const std = @import("std");
const sprite = @import("sprites");
const audio = @import("audio.zig");
const utils = @import("utils.zig");
const zball = @import("zball.zig");
const level = @import("level.zig");
const m = @import("math");

const InputState = @import("input.zig").State;
const collide = @import("collision.zig").collide;
const CollisionInfo = @import("collision.zig").CollisionInfo;

const BrickId = zball.BrickId;
const ExplosionEmitter = zball.ExplosionEmitter;
const FlameEmitter = zball.FlameEmitter;
const Level = level.Level;
const Rect = m.Rect;

const pi = std.math.pi;

const initial_paddle_pos: [2]f32 = .{
    @as(f32, @floatFromInt(zball.viewport_size[0])) / 2,
    @as(f32, @floatFromInt(zball.viewport_size[1])) - 8.5,
};

const brick_start_y = zball.brick_start_y;
const death_delay = 2.5;

const Game = @This();

allocator: std.mem.Allocator,
prng: std.Random.DefaultPrng,

time: f32 = 0,
lives: u8 = 3,
score: u32 = 0,

paddle_pos: [2]f32 = initial_paddle_pos,
paddle_size: PaddleSize = .normal,
paddle_magnet: bool = false,

entities: []Entity,
flame_emitters: []FlameEmitter,
explosion_emitters: []ExplosionEmitter,

ball_speed: f32 = zball.ball_base_speed,
ball_size: BallSize = .normal,

// When player dies, we start this timer. When it reaches zero, we start a new
// round (or send them to the title screen).
death_timer: f32 = 0,

// When a powerup spawns, we wait a little bit before spawning the next powerup
drop_spawn_timer: f32 = 0,

flame_timer: f32 = 0,
laser_timer: f32 = 0,
laser_cooldown_timer: f32 = 0,

// Triggered audio effects are queued up in this and cleared every tick
audio_clips: std.BoundedArray(audio.PlayDesc, 16) = std.BoundedArray(audio.PlayDesc, 16){},

pub const EntityType = enum {
    none,
    brick,
    ball,
    laser,
    powerup,
    coin,
};

pub const Entity = struct {
    type: EntityType = .none,
    pos: [2]f32 = .{ 0, 0 }, // Origin: top-left corner
    dir: [2]f32 = .{ 0, 0 },
    speed: f32 = 0,
    collision_layers: CollisionLayers = .{},
    sprite: ?sprite.Sprite = null,
    magnetized: bool = false,
    flame: usize = 0, // index + 1 into flame_emitters field (zero is null value)
    controlled: bool = true,
    frame: u8 = 0,
    gravity: bool = false,
    collectible: bool = false,
    collect_score: u16 = 0,
    collect_effect: ?PowerupType = null,

    rendered: bool = true,
    brick_id: ?BrickId = null,
    lives: u8 = 1,

    pub fn center(e: Entity) [2]f32 {
        const sprite_id = e.sprite orelse return e.pos;
        const sp = sprite.get(sprite_id);
        const w: f32 = @floatFromInt(sp.bounds.w);
        const h: f32 = @floatFromInt(sp.bounds.h);
        return .{ e.pos[0] + w / 2, e.pos[1] + h / 2 };
    }

    pub fn bounds(e: Entity) Rect {
        const sprite_id = e.sprite orelse return .{ .x = e.pos[0], .y = e.pos[1], .w = 0, .h = 0 };
        const sp = sprite.get(sprite_id);
        const w: f32 = @floatFromInt(sp.bounds.w);
        const h: f32 = @floatFromInt(sp.bounds.h);
        return Rect{ .x = e.pos[0], .y = e.pos[1], .w = w, .h = h };
    }
};

const CollisionLayers = packed struct {
    level: bool = false,
    bricks: bool = false,
    paddle: bool = false,
};

const BallSize = enum { smallest, smaller, normal, larger, largest };
const PaddleSize = enum { smallest, smaller, normal, larger, largest };

const PowerupType = enum {
    /// Splits the ball into two in a Y-shape
    fork,

    /// Splits the ball into four in an X-shape
    scatter,

    /// Make the ball pass through bricks
    flame,

    /// Make the paddle lasers
    laser,

    /// Increase the paddle size
    paddle_size_up,

    /// Decrease the paddle size
    paddle_size_down,

    /// Increase the ball speed
    ball_speed_up,

    /// Decrease the ball speed
    ball_speed_down,

    /// Increase the ball size
    ball_size_up,

    /// Decrease the ball size
    ball_size_down,

    /// Makes the ball(s) stick to the paddle; player can shoot them manually
    magnet,

    /// Kills the player instantly
    death,
};

pub fn init(allocator: std.mem.Allocator, lvl: Level, seed: u64) !Game {
    const entities = try allocator.alloc(Entity, zball.max_entities);
    errdefer allocator.free(entities);

    const flame_emitters = try allocator.alloc(FlameEmitter, zball.max_balls);
    errdefer allocator.free(flame_emitters);

    const explosion_emitters = try allocator.alloc(ExplosionEmitter, zball.max_entities);
    errdefer allocator.free(explosion_emitters);

    var g = Game{
        .allocator = allocator,
        .prng = std.Random.DefaultPrng.init(seed),
        .entities = entities,
        .flame_emitters = flame_emitters,
        .explosion_emitters = explosion_emitters,
    };

    // initialize allocated memory
    for (g.entities) |*e| e.* = .{};
    for (g.flame_emitters) |*e| e.* = .{};
    for (g.explosion_emitters) |*e| e.* = .{};

    // initialize bricks
    for (lvl.entities) |e| {
        switch (e.type) {
            .brick => {
                const id = try BrickId.parse(e.sprite);
                var entity = brickEntity(id);
                const fx: f32 = @floatFromInt(e.x);
                const fy: f32 = @floatFromInt(e.y);
                entity.pos = .{ fx, fy + brick_start_y };
                _ = try g.spawnEntity(entity);
            },
        }
    }

    // spawn one ball to start
    const initial_ball_pos = g.ballOnPaddlePos();
    const initial_ball = try g.spawnBall(initial_ball_pos, zball.initial_ball_dir);
    initial_ball.magnetized = true;

    return g;
}

pub fn deinit(g: Game) void {
    g.allocator.free(g.entities);
    g.allocator.free(g.explosion_emitters);
    g.allocator.free(g.flame_emitters);
}

pub fn tick(g: *Game, dt: f32, input: InputState) !void {
    g.time += dt;

    g.audio_clips.clear();

    const mouse_delta = input.mouse_delta;
    const old_paddle_pos = g.paddle_pos;

    { // Move paddle
        const dx = blk: {
            // Mouse
            if (m.magnitude(mouse_delta) > 0) {
                break :blk mouse_delta[0];
            }
            // Keyboard
            var paddle_dx: f32 = 0;
            if (input.down(.left)) {
                paddle_dx -= 1;
            }
            if (input.down(.right)) {
                paddle_dx += 1;
            }
            break :blk paddle_dx * zball.paddle_speed * dt;
        };

        const bounds = g.paddleBounds();
        g.paddle_pos[0] = std.math.clamp(
            g.paddle_pos[0] + dx,
            bounds.w / 2,
            zball.viewport_size[0] - bounds.w / 2,
        );
        for (g.entities) |*e| {
            if (e.type == .none) continue;
            if (!e.magnetized) continue;
            e.pos[0] += g.paddle_pos[0] - old_paddle_pos[0];
        }
    }

    // Handle shoot input
    if (input.down(.shoot)) shoot: {
        if (g.laser_timer > 0 and g.laser_cooldown_timer <= 0) {
            const bounds = g.paddleBounds();
            _ = g.spawnEntity(.{
                .type = .laser,
                .pos = .{ bounds.x - 1, bounds.y },
                .dir = .{ 0, -1 },
                .speed = zball.laser_speed,
                .sprite = .particle_laser,
                .collision_layers = .{
                    .bricks = true,
                },
            }) catch break :shoot;
            _ = g.spawnEntity(.{
                .type = .laser,
                .pos = .{ bounds.x + bounds.w - 2, bounds.y },
                .dir = .{ 0, -1 },
                .speed = zball.laser_speed,
                .sprite = .particle_laser,
                .collision_layers = .{
                    .bricks = true,
                },
            }) catch break :shoot;
            g.laser_cooldown_timer = zball.laser_cooldown;
            g.play(.{ .clip = .laser });
        }

        // When any ball is magnetized, shooting means releasing all
        // the balls and deactivating the magnet
        var any_ball_magnetized = false;
        for (g.entities) |e| {
            if (e.type == .none) continue;
            if (!e.magnetized) continue;
            any_ball_magnetized = true;
        }
        if (any_ball_magnetized) {
            g.paddle_magnet = false;
            for (g.entities) |*e| {
                e.magnetized = false;
            }
        }
    }

    // Update entities
    for (g.entities) |*e| {
        if (e.type == .none) continue;

        const old_pos = e.pos;

        // Sync global ball flags with entity flags
        blk: {
            if (e.type != .ball) break :blk;
            e.speed = g.ball_speed;
            e.sprite = g.ballSprite();
        }

        // Handle entities affected by gravity
        blk: {
            if (e.type == .none) break :blk;
            if (!e.gravity) break :blk;
            var vel = m.vmul(e.dir, e.speed);
            vel[1] += dt * zball.gravity;
            vel[1] = @min(vel[1], zball.terminal_velocity);
            e.dir = vel;
            m.normalize(&e.dir);
            e.speed = m.magnitude(vel);
            if (e.pos[1] > zball.viewport_size[1]) {
                e.type = .none;
                e.frame = 0;
            }
        }

        // Handle moving entities
        blk: {
            if (e.dir[0] == 0 and e.dir[1] == 0) break :blk;
            if (e.magnetized) break :blk;
            e.pos[0] += e.dir[0] * e.speed * dt;
            e.pos[1] += e.dir[1] * e.speed * dt;
        }

        // Resolve collisions
        if (e.collision_layers.bricks) {
            if (g.collideBricks(e, old_pos, e.pos)) |coll| {
                switch (e.type) {
                    .ball => {
                        if (g.flame_timer <= 0) {
                            e.pos = coll.pos;
                            e.dir = m.reflect(e.dir, coll.normal);
                            // Always play bouncing sound when we "reflect" the ball
                            g.play(.{ .clip = .bounce });
                        }
                    },
                    .laser => {
                        e.type = .none;
                    },
                    else => {},
                }
            }
        }

        var out: [2]f32 = undefined;
        var normal: [2]f32 = undefined;
        if (e.collision_layers.level) {
            if (collideLevelBounds(e.*, old_pos, e.pos, &out, &normal)) {
                e.pos = out;
                e.dir = m.reflect(e.dir, normal);
                switch (e.type) {
                    .ball => {
                        g.play(.{ .clip = .bounce });
                    },
                    else => {},
                }
            }
        }

        if (e.collision_layers.paddle) {
            if (g.collidePaddle(e, old_pos, e.pos, old_paddle_pos)) |coll| {
                if (e.collectible) {
                    g.collectEntity(e);
                } else {
                    const paddle_bounds = g.paddleBounds();
                    const entity_bounds = e.bounds();
                    if (coll.normal[1] == 1) {
                        e.pos = .{ coll.pos[0], coll.pos[1] };
                        e.dir = paddleReflect(g.paddle_pos[0], paddle_bounds.w, e.pos, e.dir);
                        if (g.paddle_magnet) {
                            // Paddle is magnetized - make ball stick!
                            e.magnetized = true;
                        } else {
                            // Bounce the ball
                            g.play(.{ .clip = .bounce });
                        }
                    } else if (coll.normal[0] == -1) {
                        e.pos[0] = paddle_bounds.x - entity_bounds.w;
                        e.dir = .{ -1, 1 };
                        m.normalize(&e.dir);
                        if (e.controlled) {
                            g.play(.{ .clip = .bounce });
                            e.controlled = false;
                        }
                    } else if (coll.normal[0] == 1) {
                        e.pos[0] = paddle_bounds.x + paddle_bounds.w + entity_bounds.w;
                        e.dir = .{ 1, 1 };
                        m.normalize(&e.dir);
                        if (e.controlled) {
                            g.play(.{ .clip = .bounce });
                            e.controlled = false;
                        }
                    }
                }
            }
        }

        // If entity outside level bounds, always kill
        const vw: f32 = @floatFromInt(zball.viewport_size[0]);
        const vh: f32 = @floatFromInt(zball.viewport_size[1]);
        var level_bounds = Rect{ .x = 0, .y = 0, .w = vw, .h = vh - 8 };
        level_bounds.grow(.{ 16, 16 });
        if (!level_bounds.overlaps(e.bounds())) {
            switch (e.type) {
                .ball => {
                    g.play(.{ .clip = .explode, .vol = 0.5 });
                    g.spawnExplosion(e.pos, .ball_normal);
                    e.type = .none;
                    g.destroyFlame(e);

                    // If the ball was the final ball, start a death timer
                    for (g.entities) |entity| {
                        if (entity.type != .ball) continue;
                        if (entity.type != .none) break;
                    } else {
                        g.killPlayer();
                    }
                },
                .laser => e.type = .none,
                .coin => e.type = .none,
                .powerup => e.type = .none,
                else => {},
            }
        }

        // Entity type specific behavior
        switch (e.type) {
            .none => {},
            .brick => {},
            .laser => {},
            .powerup => {},
            .coin => {
                defer e.frame = (e.frame + 1) % 64;
                if (e.frame >= 32) {
                    e.sprite = .coin2;
                } else {
                    e.sprite = .coin1;
                }
            },
            .ball => {
                // If the ball direction is almost horizontal, adjust it so
                // that it isn't. If we don't do this, the ball may be stuck
                // for a very long time.
                if (@abs(e.dir[1]) < 0.10) {
                    e.dir[1] = std.math.sign(e.dir[1]) * 0.10;
                    m.normalize(&e.dir);
                }
            },
        }
    }

    // Sync flame emitter positions with entities
    for (g.entities) |*e| {
        if (e.flame == 0) continue;
        const emitter = &g.flame_emitters[e.flame - 1];
        if (!emitter.emitting) {
            e.flame = 0;
        } else {
            emitter.pos = e.center();
        }
    }

    // Update emitters
    for (g.explosion_emitters) |*e| {
        if (!e.emitting) continue;
        e.update(dt);
    }
    for (g.flame_emitters) |*e| {
        if (!e.emitting) continue;
        e.update(dt);
    }

    flame: {
        if (!utils.tickDownTimer(g, "flame_timer", dt)) break :flame;
        for (g.entities) |*e| {
            if (e.type != .ball) continue;
            g.destroyFlame(e);
        }
    }

    _ = utils.tickDownTimer(g, "laser_cooldown_timer", dt);
    _ = utils.tickDownTimer(g, "laser_timer", dt);
    _ = utils.tickDownTimer(g, "drop_spawn_timer", dt);

    death: {
        if (!utils.tickDownTimer(g, "death_timer", dt)) break :death;

        g.lives -= 1;
        if (g.lives == 0) {
            return;
        } else {
            const ball = try g.spawnBall(g.ballOnPaddlePos(), zball.initial_ball_dir);
            ball.magnetized = true;
            g.ball_speed = zball.ball_base_speed;
            g.ball_size = .normal;
            g.flame_timer = 0;
        }
    }
}

/// Check if player has cleared all the bricks
pub fn isCleared(g: Game) bool {
    for (g.entities) |e| {
        if (e.type != .brick) continue;
        // NOTE: It's fine to leave unrevealed hidden bricks (but
        // the drawback is the player gets a lower score)
        if (e.brick_id == .hidden and !e.rendered) continue;
        if (e.type != .none and e.brick_id != .hidden) return false;
    }
    return true;
}

// The angle depends on how far the ball is from the center of the paddle
fn paddleReflect(paddle_pos: f32, paddle_width: f32, ball_pos: [2]f32, ball_dir: [2]f32) [2]f32 {
    const p = (paddle_pos - ball_pos[0]) / paddle_width;
    var new_dir = [_]f32{ -p, -ball_dir[1] };
    m.normalize(&new_dir);
    return new_dir;
}

fn play(g: *Game, clip: audio.PlayDesc) void {
    g.audio_clips.append(clip) catch return;
}

/// Create an entity from a brick ID.
fn brickEntity(id: BrickId) Entity {
    const s: sprite.Sprite = zball.brickIdToSprite(id);
    var entity = Entity{ .type = .brick, .sprite = s, .brick_id = id };
    switch (id) {
        .grey, .red, .green, .blue => {},
        .explode => {},
        .metal => {
            entity.lives = 2;
        },
        .hidden => {
            entity.rendered = false;
            entity.lives = 2;
        },
    }
    return entity;
}

fn spawnEntity(g: *Game, entity: Entity) !*Entity {
    for (g.entities) |*e| {
        if (e.type != .none) continue;
        e.* = entity;
        return e;
    } else {
        return error.MaxEntitiesReached;
    }
}

fn spawnExplosion(g: *Game, pos: [2]f32, sp: sprite.Sprite) void {
    for (g.explosion_emitters) |*emitter| {
        if (emitter.emitting) continue;
        emitter.start(g.prng.random(), pos);
        emitter.sprites = zball.particleExplosionSprites(sp);
        break;
    }
}

fn spawnFlame(g: *Game, e: *Entity) void {
    for (g.flame_emitters, 0..) |*emitter, i| {
        if (emitter.emitting) continue;
        emitter.start(g.prng.random(), e.pos);
        emitter.sprites = &zball.particleFlameSprites;
        e.flame = i + 1;
        break;
    }
}

fn destroyFlame(g: *Game, e: *Entity) void {
    if (e.flame > 0) {
        g.flame_emitters[e.flame - 1].emitting = false;
        e.flame = 0;
    }
}

fn spawnDrop(g: *Game, pos: [2]f32, speed: f32, dir: [2]f32) void {
    if (g.drop_spawn_timer > 0) return;

    const rng = g.prng.random();
    const idx = rng.weightedIndex(f32, &.{ 1 - zball.powerup_freq - zball.coin_freq, zball.powerup_freq, zball.coin_freq });
    switch (idx) {
        0 => return,
        1 => g.spawnPowerup(pos, speed, dir),
        2 => g.spawnCoin(pos, speed, dir),
        else => unreachable,
    }
}

fn spawnPowerup(g: *Game, pos: [2]f32, speed: f32, dir: [2]f32) void {
    const rng = g.prng.random();
    const effect = rng.enumValue(PowerupType);

    // Speed of spawned powerup is randomized, but scales with speed of colliding entity
    const new_speed = (speed / 2) + rng.float(f32) * 50;

    // Horizontal direction is randomized a bit
    var new_dir = dir;
    new_dir[0] += 0.7 * (rng.float(f32) - 0.5);
    m.normalize(&new_dir);

    _ = g.spawnEntity(.{
        .type = .powerup,
        .pos = pos,
        .dir = new_dir,
        .speed = new_speed,
        .sprite = powerupSprite(effect),
        .gravity = true,
        .collectible = true,
        .collect_score = 200,
        .collect_effect = effect,
        .collision_layers = .{
            .level = true,
            .paddle = true,
        },
    }) catch return;
}

fn spawnCoin(g: *Game, pos: [2]f32, speed: f32, dir: [2]f32) void {
    const rng = g.prng.random();

    // Speed of spawned coin is randomized, but scales with speed of colliding entity
    const new_speed = (speed / 2) + rng.float(f32) * 50;

    // Horizontal direction is randomized a bit
    var new_dir = dir;
    new_dir[0] += 0.7 * (rng.float(f32) - 0.5);

    m.normalize(&new_dir);
    _ = g.spawnEntity(.{
        .type = .coin,
        .pos = pos,
        .dir = new_dir,
        .speed = new_speed,
        .sprite = .coin1,
        .gravity = true,
        .collectible = true,
        .collect_score = 100,
        .collision_layers = .{
            .level = true,
            .paddle = true,
        },
    }) catch return;
}

fn spawnBall(g: *Game, pos: [2]f32, dir: [2]f32) !*Entity {
    return try g.spawnEntity(.{
        .type = .ball,
        .pos = pos,
        .dir = dir,
        .collision_layers = .{
            .level = true,
            .bricks = true,
            .paddle = true,
        },
        .speed = g.ball_speed,
        .sprite = .ball_normal,
    });
}

fn powerupSprite(p: PowerupType) sprite.Sprite {
    return switch (p) {
        .fork => .pow_fork,
        .scatter => .pow_scatter,
        .flame => .pow_flame,
        .laser => .pow_laser,
        .paddle_size_up => .pow_paddlesizeup,
        .paddle_size_down => .pow_paddlesizedown,
        .ball_speed_up => .pow_ballspeedup,
        .ball_speed_down => .pow_ballspeeddown,
        .ball_size_up => .pow_ballsizeup,
        .ball_size_down => .pow_ballsizedown,
        .magnet => .pow_magnet,
        .death => .pow_death,
    };
}

fn ballOnPaddlePos(g: Game) [2]f32 {
    const paddle_bounds = g.paddleBounds();
    const ball_sprite = sprite.get(g.ballSprite());
    const ball_w: f32 = @floatFromInt(ball_sprite.bounds.w);
    const ball_h: f32 = @floatFromInt(ball_sprite.bounds.h);
    return .{
        g.paddle_pos[0] - ball_w / 2,
        g.paddle_pos[1] - paddle_bounds.h / 2 - ball_h,
    };
}

pub fn paddleBounds(g: Game) Rect {
    const sp = sprite.sprites.paddle;

    const scale: f32 = switch (g.paddle_size) {
        .smallest => 0.25,
        .smaller => 0.5,
        .normal => 1.0,
        .larger => 1.5,
        .largest => 2.0,
    };

    var w: f32 = @floatFromInt(sp.bounds.w);
    w *= scale;
    const h: f32 = @floatFromInt(sp.bounds.h);
    return m.Rect{
        .x = g.paddle_pos[0] - w / 2,
        .y = g.paddle_pos[1] - h / 2,
        .w = w,
        .h = h,
    };
}

fn ballSprite(g: Game) sprite.Sprite {
    return switch (g.ball_size) {
        .smallest => .ball_smallest,
        .smaller => .ball_smaller,
        .normal => .ball_normal,
        .larger => .ball_larger,
        .largest => .ball_largest,
    };
}

fn collideLevelBounds(e: Entity, p1: [2]f32, p2: [2]f32, out_pos: *[2]f32, out_normal: *[2]f32) bool {
    var bounds = e.bounds();
    bounds.x = p1[0];
    bounds.y = p1[1];

    const vw: f32 = @floatFromInt(zball.viewport_size[0]);
    const vh: f32 = @floatFromInt(zball.viewport_size[1]);

    const delta = [2]f32{ p2[0] - p1[0], p2[1] - p1[1] };

    var curr_dist = m.magnitude(delta);
    var collided = false;
    const top_wall = Rect{ .x = 0, .y = brick_start_y, .w = vw, .h = 2 };
    if (collide(top_wall, .{ 0, 0 }, bounds, delta)) |coll| {
        out_pos.* = coll.pos;
        out_normal.* = coll.normal;
        curr_dist = m.magnitude(m.vsub(coll.pos, p1));
        collided = true;
    }

    const right_wall = Rect{ .x = vw - 2, .y = 0, .w = 2, .h = vh };
    if (collide(right_wall, .{ 0, 0 }, bounds, delta)) |coll| {
        out_pos.* = coll.pos;
        const dist = m.magnitude(m.vsub(coll.pos, p1));
        if (dist < curr_dist) {
            curr_dist = dist;
            out_normal.* = coll.normal;
        }
        collided = true;
    }

    const left_wall = Rect{ .x = 0, .y = 0, .w = 2, .h = vh };
    if (collide(left_wall, .{ 0, 0 }, bounds, delta)) |coll| {
        out_pos.* = coll.pos;
        const dist = m.magnitude(m.vsub(coll.pos, p1));
        if (dist < curr_dist) {
            curr_dist = dist;
            out_normal.* = coll.normal;
        }
        collided = true;
    }

    return collided;
}

// Paddle bounces are handled as follows:
//
// If the ball hits the top surface of the paddle, we bounce the ball in a
// direction determined by how far the ball is from the center paddle. Hitting
// it in the center launches it in a vertical direction, while each side gives
// the ball trajectory a more horizontal direction.
//
// If the ball hits the side of the paddle, we reflect the ball downwards at a
// 45 degree angle away from the paddle and prevent further collisions to ensure
// there's no weirdness at the level edges. At this point, the ball can be
// "shoved" by moving the paddle towards it, but it doesn't trigger further
// direction changes.
fn collidePaddle(g: *Game, e: *Entity, p1: [2]f32, p2: [2]f32, old_paddle_pos: [2]f32) ?CollisionInfo {
    const paddle_bounds = g.paddleBounds();
    const entity_bounds = e.bounds();

    var old_entity_bounds = entity_bounds;
    old_entity_bounds.x = p1[0];
    old_entity_bounds.y = p1[1];
    var old_paddle_bounds = paddle_bounds;
    old_paddle_bounds.x = old_paddle_pos[0] - paddle_bounds.w / 2;
    old_paddle_bounds.y = old_paddle_pos[1] - paddle_bounds.h / 2;

    const entity_delta = m.vsub(p2, p1);
    const paddle_delta = m.vsub(g.paddle_pos, old_paddle_pos);

    const result = collide(old_paddle_bounds, paddle_delta, old_entity_bounds, entity_delta) orelse {
        std.debug.assert(old_paddle_bounds.overlaps(old_entity_bounds) or !paddle_bounds.overlaps(entity_bounds));
        return null;
    };
    return result;
}

fn collideBricks(g: *Game, ball: *const Entity, old_pos: [2]f32, new_pos: [2]f32) ?CollisionInfo {
    const delta = m.vsub(new_pos, old_pos);
    const ball_bounds = ball.bounds();

    var old_ball_bounds = ball_bounds;
    old_ball_bounds.x = old_pos[0];
    old_ball_bounds.y = old_pos[1];

    var out: [2]f32 = undefined;
    var normal: [2]f32 = undefined;
    var collided = false;
    var coll_dist = std.math.floatMax(f32);
    for (g.entities) |*e| {
        if (e.type != .brick) continue;

        const brick_bounds = e.bounds();
        const result = collide(brick_bounds, .{ 0, 0 }, old_ball_bounds, delta) orelse continue;
        collided = true;

        // always use the normal of the closest brick for ball reflection
        const brick_dist = m.magnitude(m.vsub(e.pos, result.pos));
        if (brick_dist < coll_dist) {
            out = result.pos;
            normal = result.normal;
            coll_dist = brick_dist;
        }

        const destroyed = g.destroyBrick(e);
        if (destroyed) spawnDrop(g, e.pos, ball.speed, ball.dir);
    }
    if (collided) return .{ .pos = out, .normal = normal };
    return null;
}

fn collectEntity(g: *Game, e: *Entity) void {
    std.debug.assert(e.collectible);

    switch (e.type) {
        .coin => g.play(.{ .clip = .coin }),
        else => g.play(.{ .clip = .powerup }),
    }
    g.score += e.collect_score;
    e.type = .none;
    e.frame = 0;

    if (e.collect_effect) |effect| {
        g.acquirePowerup(effect);
    }
}

fn destroyBrick(g: *Game, brick: *Entity) bool {
    std.debug.assert(brick.type == .brick);
    brick.lives -= 1;
    switch (brick.brick_id.?) {
        .grey, .red, .green, .blue => {
            if (brick.lives > 0) {
                g.play(.{ .clip = .clink });
            }
        },
        .metal => {
            if (g.flame_timer <= 0) {
                if (brick.lives > 0) {
                    const rng = g.prng.random();
                    const weak_sprites = [_]sprite.Sprite{
                        .brick_metal_weak,
                        .brick_metal_weak2,
                        .brick_metal_weak3,
                    };
                    const next_sprite = weak_sprites[rng.intRangeAtMost(usize, 0, weak_sprites.len - 1)];
                    // Metal bricks requires two hits to break
                    brick.sprite = next_sprite;
                    if (g.flame_timer <= 0) {
                        g.play(.{ .clip = .clink });
                    }
                }
            } else {
                brick.lives = 0;
            }
        },
        .explode => {
            if (brick.lives == 0) {
                brick.type = .none;
                // Surrounding bricks go boom
                g.destroyBricksCircle(brick.pos, 16);
            }
        },
        .hidden => {
            brick.rendered = true;
            if (brick.lives > 0) {
                g.play(.{ .clip = .reveal });
            }
        },
    }

    if (brick.lives == 0) {
        brick.type = .none;
        g.play(.{ .clip = .explode });

        var points: f32 = 100;
        var mult: f32 = 1.0;

        // Fast balls give more points
        if (g.ball_speed > zball.ball_base_speed) {
            const current_extra_speed = g.ball_speed - zball.ball_base_speed;
            const max_extra_speed = zball.ball_speed_max - zball.ball_base_speed;
            const bonus = @round(50 * (current_extra_speed / max_extra_speed));
            points += bonus;
        }

        // Smaller paddle give more points
        switch (g.paddle_size) {
            .smallest => mult = 1.5,
            .smaller => mult = 1.25,
            else => {},
        }

        // Smaller balls give more points
        switch (g.ball_size) {
            .smallest => mult = 1.5,
            .smaller => mult = 1.25,
            else => {},
        }

        g.score += @as(u32, @intFromFloat(@round(points * mult)));
        g.spawnExplosion(brick.pos, brick.sprite.?);
    }

    return brick.lives == 0;
}

fn destroyBricksCircle(g: *Game, origin: [2]f32, radius: f32) void {
    for (g.entities) |*e| {
        if (e.type != .brick) continue;
        const dir = m.vsub(e.center(), origin);
        if (m.magnitude(dir) <= radius) {
            _ = g.destroyBrick(e);
        }
    }
}

fn acquirePowerup(g: *Game, p: PowerupType) void {
    g.score += 200;
    switch (p) {
        .fork => g.splitBall(&.{
            -pi / 8.0,
            pi / 8.0,
        }),
        .scatter => g.splitBall(&.{
            -pi / 4.0,
            pi / 4.0,
            3 * pi / 4.0,
            5 * pi / 4.0,
        }),
        .flame => {
            g.flame_timer = zball.flame_duration;
            for (g.entities) |*e| {
                if (e.type != .ball) continue;
                if (e.flame > 0) continue;
                g.spawnFlame(e);
            }
        },
        .laser => {
            g.laser_timer = zball.laser_duration;
        },
        .paddle_size_up => {
            const sizes = std.enums.values(PaddleSize);
            const i = @intFromEnum(g.paddle_size);
            if (i < sizes.len - 1) {
                g.paddle_size = @enumFromInt(i + 1);
            }
        },
        .paddle_size_down => {
            const i = @intFromEnum(g.paddle_size);
            if (i > 0) {
                g.paddle_size = @enumFromInt(i - 1);
            }
        },
        .ball_speed_up => {
            g.ball_speed = @min(zball.ball_speed_max, g.ball_speed + 50);
        },
        .ball_speed_down => {
            g.ball_speed = @max(zball.ball_speed_min, g.ball_speed - 50);
        },
        .ball_size_up => {
            const sizes = std.enums.values(BallSize);
            const i = @intFromEnum(g.ball_size);
            if (i < sizes.len - 1) {
                g.ball_size = @enumFromInt(i + 1);
            }
        },
        .ball_size_down => {
            const i = @intFromEnum(g.ball_size);
            if (i > 0) {
                g.ball_size = @enumFromInt(i - 1);
            }
        },
        .magnet => {
            g.paddle_magnet = true;
        },
        .death => {
            // Destroy all balls
            for (g.entities) |*e| {
                switch (e.type) {
                    .ball => {
                        e.type = .none;
                        g.destroyFlame(e);
                        g.play(.{ .clip = .explode, .vol = 0.5 });
                        g.spawnExplosion(e.pos, .ball_normal);
                    },
                    else => {},
                }
            }
            g.killPlayer();
        },
    }
}

fn splitBall(g: *Game, angles: []const f32) void {
    var active_balls = std.BoundedArray(usize, zball.max_balls){ .len = 0 };
    for (g.entities, 0..) |e, i| {
        if (e.type != .ball) continue;
        active_balls.append(i) catch continue;
    }
    for (active_balls.constSlice()) |i| {
        var ball = &g.entities[i];
        var d1 = ball.dir;
        m.vrot(&d1, angles[0]);
        for (angles[1..]) |angle| {
            var d2 = ball.dir;
            m.vrot(&d2, angle);
            const new_ball = g.spawnBall(ball.pos, d2) catch break;
            if (g.flame_timer > 0) g.spawnFlame(new_ball);
        }
        ball.dir = d1;
    }
}

fn killPlayer(g: *Game) void {
    g.play(.{ .clip = .death });
    g.death_timer = death_delay;
}
