const std = @import("std");
const sprite = @import("sprites");
const constants = @import("../constants.zig");
const input = @import("../input.zig");
const audio = @import("../audio.zig");
const settings = @import("../settings.zig");
const shd = @import("shader");

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;

const level = @import("../level.zig");
const Level = level.Level;

const game = @import("../game.zig");
const Brick = game.Brick;
const ExplosionEmitter = game.ExplosionEmitter;
const FlameEmitter = game.FlameEmitter;

const gfx = @import("../gfx.zig");
const ui = gfx.ui;
const TextRenderer = gfx.ttf.TextRenderer;

const m = @import("math");
const Rect = m.Rect;
const box_intersection = @import("../collision.zig").box_intersection;
const line_intersection = @import("../collision.zig").line_intersection;
const pi = std.math.pi;

// TODO move to constants?
const paddle_speed: f32 = 180;
const ball_base_speed: f32 = 200;
const ball_speed_min: f32 = 100;
const ball_speed_max: f32 = 300;
const initial_paddle_pos: [2]f32 = .{
    constants.viewport_size[0] / 2,
    constants.viewport_size[1] - 4,
};
const max_balls = 32;
const max_entities = 1024;
const coin_freq = 0.4;
const powerup_freq = 0.1;
const drop_fall_speed = 100;

/// Prevents two drops being spawned back-to-back in a quick succession
const drop_spawn_cooldown = 0.5;

const flame_duration = 5;
const laser_duration = 5;
const laser_speed = 300;
const laser_cooldown = 0.2;
const brick_w = constants.brick_w;
const brick_h = constants.brick_h;
const brick_start_y = constants.brick_start_y;
const death_delay = 2.5;

comptime {
    std.debug.assert(coin_freq + powerup_freq <= 1);
}

pub const EntityType = enum {
    none,
    brick,
    ball,
    laser,
    explosion,
    powerup,
    coin,
};

pub const Entity = struct {
    type: EntityType = .none,
    pos: [2]f32 = .{ 0, 0 },
    dir: [2]f32 = .{ 0, 0 },
    speed: f32 = 0,
    colliding: bool = false,
    sprite: ?sprite.Sprite = null,
    magnetized: bool = false,
    flame: FlameEmitter = .{},
    explosion: ExplosionEmitter = .{},
    controlled: bool = true,
    frame: u8 = 0,
    falling: bool = false,
    collectible: bool = false,
    collect_score: u16 = 0,
    collect_effect: ?PowerupType = null,
};

const BallState = enum {
    alive, // ball is flying around wreaking all sorts of havoc
    idle, // ball is on paddle and waiting to be shot
};

const GameMenu = enum { none, pause, settings };

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

const GameScene = @This();

allocator: std.mem.Allocator,

menu: GameMenu = .none,

time: f32 = 0,
time_scale: f32 = 1,

lives: u8 = 3,
score: u32 = 0,

paddle_pos: [2]f32 = initial_paddle_pos,
paddle_size: PaddleSize = .normal,
paddle_magnet: bool = false,

entities: []Entity,

// TODO remove "idle" ball state - use magnetized logic instead
ball_state: BallState = .idle,
ball_speed: f32 = ball_base_speed,
ball_size: BallSize = .normal,

// When player clears the board, we start this timer. When it reaches zero,
// we switch to the next board (or the title screen, if the board cleared
// was the last one).
clear_timer: f32 = 0,

// When player dies, we start this timer. When it reaches zero, we start a new
// round (or send them to the title screen).
death_timer: f32 = 0,

// When a powerup spawns, we wait a little bit before spawning the next powerup
drop_spawn_timer: f32 = 0,

flame_timer: f32 = 0,
laser_timer: f32 = 0,
laser_cooldown_timer: f32 = 0,

pub fn init(allocator: std.mem.Allocator, lvl: Level) !GameScene {
    const entities = try allocator.alloc(Entity, max_entities);
    errdefer allocator.free(entities);

    var scene = GameScene{
        .allocator = allocator,
        .entities = entities,
    };

    // zero-intialize entities
    for (scene.entities) |*e| e.* = .{};

    // initialize bricks
    for (lvl.entities) |e| {
        switch (e.type) {
            .brick => {
                const s: sprite.Sprite = try game.brickIdToSprite(e.sprite);

                const fx: f32 = @floatFromInt(e.x);
                const fy: f32 = @floatFromInt(e.y);
                const sp = sprite.get(s);
                const w: f32 = @floatFromInt(sp.bounds.w);
                const h: f32 = @floatFromInt(sp.bounds.h);
                // TODO not a fan of the entity pivot point differences between editor and game
                _ = try scene.spawnEntity(.{
                    .type = .brick,
                    .pos = .{ fx + w / 2, fy + h / 2 + brick_start_y },
                    .sprite = s,
                });
            },
        }
    }

    // spawn one ball to start
    const initial_ball_pos = scene.ballOnPaddlePos();
    _ = try scene.spawnBall(initial_ball_pos, constants.initial_ball_dir);

    return scene;
}

pub fn deinit(scene: GameScene) void {
    scene.allocator.free(scene.entities);
}

pub fn frame(scene: *GameScene, dt: f32) !void {
    // The delta time used by the game itself (minus "global
    // timers"). Scaled by `time_scale` to support slowdown effects.
    const game_dt = scene.time_scale * dt;

    // UI input
    switch (scene.menu) {
        .none => if (input.pressed(.back)) {
            scene.menu = .pause;
        },
        .pause => if (input.pressed(.back)) {
            scene.menu = .none;
        },
        .settings => if (input.pressed(.back)) {
            scene.menu = .pause;
        },
    }

    if (!scene.paused()) {
        input.showMouse(false);
        input.lockMouse(true);

        const mouse_delta = input.mouseDelta();

        scene.time += game_dt;

        const old_paddle_pos = scene.paddle_pos;
        { // Move paddle
            const dx = blk: {
                // Mouse
                if (m.magnitude(mouse_delta) > 0) {
                    break :blk mouse_delta[0] * scene.time_scale;
                }
                // Keyboard
                var paddle_dx: f32 = 0;
                if (input.down(.left)) {
                    paddle_dx -= 1;
                }
                if (input.down(.right)) {
                    paddle_dx += 1;
                }
                break :blk paddle_dx * paddle_speed * game_dt;
            };

            const bounds = scene.paddleBounds();
            scene.paddle_pos[0] = std.math.clamp(scene.paddle_pos[0] + dx, bounds.w / 2, constants.viewport_size[0] - bounds.w / 2);
            for (scene.entities) |*e| {
                if (e.type == .none) continue;
                if (!e.magnetized) continue;
                e.pos[0] += dx;
            }
        }

        // Handle shoot input
        if (input.down(.shoot)) shoot: {
            if (scene.ball_state == .idle) {
                scene.ball_state = .alive;
            } else {
                if (scene.laser_timer > 0 and scene.laser_cooldown_timer <= 0) {
                    const bounds = scene.paddleBounds();
                    _ = scene.spawnEntity(.{
                        .type = .laser,
                        .pos = .{ bounds.x + 2, bounds.y },
                        .dir = .{ 0, -1 },
                        .speed = laser_speed,
                        .sprite = .particle_laser,
                        .colliding = true,
                    }) catch break :shoot;
                    _ = scene.spawnEntity(.{
                        .type = .laser,
                        .pos = .{ bounds.x + bounds.w - 2, bounds.y },
                        .dir = .{ 0, -1 },
                        .speed = laser_speed,
                        .sprite = .particle_laser,
                        .colliding = true,
                    }) catch break :shoot;
                    scene.laser_cooldown_timer = laser_cooldown;
                    audio.play(.{ .clip = .laser });
                }

                if (scene.paddle_magnet) {
                    // When any ball is magnetized, shooting means releasing all
                    // the balls and deactivating the magnet
                    var any_ball_magnetized = false;
                    for (scene.entities) |e| {
                        if (e.type == .none) continue;
                        if (!e.magnetized) continue;
                        any_ball_magnetized = true;
                    }
                    if (any_ball_magnetized) {
                        scene.paddle_magnet = false;
                        for (scene.entities) |*e| {
                            e.magnetized = false;
                        }
                    }
                }
            }
        }

        // Update entities
        for (scene.entities) |*e| {
            if (e.type == .none) continue;

            // Sync global ball flags with entity flags
            blk: {
                if (e.type != .ball) break :blk;
                e.speed = scene.ball_speed;
                e.sprite = scene.ballSprite();
            }

            // Handle falling entities
            blk: {
                if (e.type == .none) break :blk;
                if (!e.falling) break :blk;
                e.pos[1] += game_dt * drop_fall_speed;
                if (e.pos[1] > constants.viewport_size[1]) {
                    e.type = .none;
                    e.frame = 0;
                }
            }

            // Handle collectible entities
            blk: {
                // TODO also related to collisions
                if (!e.collectible) break :blk;
                const paddle_bounds = scene.paddleBounds();
                const sp = sprite.get(e.sprite orelse break :blk);
                const bounds = m.Rect{
                    .x = e.pos[0],
                    .y = e.pos[1],
                    .w = @floatFromInt(sp.bounds.w),
                    .h = @floatFromInt(sp.bounds.h),
                };

                if (paddle_bounds.overlaps(bounds)) {
                    audio.play(.{ .clip = .powerup });
                    scene.score += e.collect_score;
                    e.type = .none;
                    e.frame = 0;

                    if (e.collect_effect) |effect| {
                        scene.acquirePowerup(effect);
                    }
                }
            }

            // Handle moving entities
            const old_pos = e.pos;
            blk: {
                if (e.dir[0] == 0 and e.dir[1] == 0) break :blk;
                if (e.magnetized) break :blk;
                e.pos[0] += e.dir[0] * e.speed * game_dt;
                e.pos[1] += e.dir[1] * e.speed * game_dt;
            }

            // Resolve collisions
            blk: {
                if (!e.colliding) break :blk;
                // TODO
                if (scene.collideBricks2(old_pos, e.pos)) |coll| {
                    switch (e.type) {
                        .ball => {
                            if (scene.flame_timer <= 0) {
                                e.pos = coll.out;
                                e.dir = m.reflect(e.dir, coll.normal);
                                // Always play bouncing cound when we "reflect" the ball
                                audio.play(.{ .clip = .bounce });
                            }
                        },
                        .laser => {
                            e.type = .none;
                        },
                        else => {},
                    }
                }
                var out: [2]f32 = undefined;
                var normal: [2]f32 = undefined;
                if (collideLevelBounds(e.*, old_pos, e.pos, &out, &normal)) {
                    switch (e.type) {
                        .ball => {
                            audio.play(.{ .clip = .bounce });
                            e.pos = out;
                            e.dir = m.reflect(e.dir, normal);
                        },
                        else => {},
                    }
                }

                _ = scene.collidePaddle(e, old_pos, e.pos, old_paddle_pos);

                // If entity outside level bounds, always kill
                // TODO also consider x
                const vw: f32 = @floatFromInt(constants.viewport_size[1]);
                if (e.pos[1] > vw or e.pos[1] < 0) {
                    switch (e.type) {
                        .ball => {
                            audio.play(.{ .clip = .explode, .vol = 0.5 });
                            _ = scene.spawnExplosion(e.pos, .ball_normal) catch {};
                            e.type = .none;
                            e.flame.emitting = false;

                            // If the ball was the final ball, start a death timer
                            for (scene.entities) |entity| {
                                if (entity.type != .ball) continue;
                                if (entity.type != .none) break;
                            } else {
                                scene.killPlayer();
                            }
                        },
                        .laser => {
                            e.type = .none;
                        },
                        else => {},
                    }
                }
            }

            // Entity type specific behavior
            switch (e.type) {
                .none => {},
                .brick => {},
                .laser => {},
                .powerup => {},
                .explosion => {
                    // When the emitter stops, we remove the entity
                    if (!e.explosion.emitting) {
                        e.* = .{};
                    }
                },
                .coin => {
                    defer e.frame = (e.frame + 1) % 64;
                    if (e.frame >= 32) {
                        e.sprite = .coin2;
                    } else {
                        e.sprite = .coin1;
                    }
                },
                .ball => {
                    const ball = e;

                    switch (scene.ball_state) {
                        .idle => {
                            scene.updateIdleBall();
                        },
                        .alive => {
                            // if (!ball.magnetized) {
                            //     ball.pos[0] += ball.dir[0] * scene.ball_speed * game_dt;
                            //     ball.pos[1] += ball.dir[1] * scene.ball_speed * game_dt;
                            // }
                        },
                    }

                    // var out: [2]f32 = undefined;
                    // _ = out; // autofix
                    // var normal: [2]f32 = undefined;
                    // _ = normal; // autofix

                    // const vw: f32 = @floatFromInt(constants.viewport_size[0]);
                    // const vh: f32 = @floatFromInt(constants.viewport_size[1]);

                    // Has the ball hit the paddle?
                    // paddle_check: {
                    //     // Paddle bounces are handled as follows:
                    //     //
                    //     // If the ball hits the top surface of the paddle, we
                    //     // bounce the ball in a direction determined by how far
                    //     // the ball is from the center paddle. Hitting it in the
                    //     // center launches it in a vertical direction, while
                    //     // each side gives the ball trajectory a more horizontal
                    //     // direction.
                    //     //
                    //     // If the ball hits the side of the paddle, we reflect
                    //     // the ball downwards at a 45 degree angle away from the
                    //     // paddle and prevent further collisions to ensure
                    //     // there's no weirdness at the level edges. At this
                    //     // point, the ball can be "shoved" by moving the paddle
                    //     // towards it, but it doesn't trigger further direction
                    //     // changes.
                    //     //
                    //     // NOTE: We only check for collision if the ball is heading
                    //     // downward, because there are situations the ball could be
                    //     // temporarily inside the paddle (and I don't know a better way
                    //     // to solve that which look good or feel good gameplay-wise)
                    //     if (ball.dir[1] < 0) break :paddle_check;

                    //     const paddle_bounds = scene.paddleBounds();
                    //     const paddle_w = paddle_bounds.w;
                    //     const paddle_h = paddle_bounds.h;
                    //     const ball_bounds = Rect{
                    //         .x = old_pos[0] - ball_w / 2,
                    //         .y = old_pos[1] - ball_h / 2,
                    //         .w = ball_w,
                    //         .h = ball_h,
                    //     };

                    //     // Top surface

                    //     // TODO if the ball moves fast, it might go through the
                    //     // grace zone. So we should probably consider the old
                    //     // position as well somehow
                    //     const hit_y = scene.paddle_pos[1] - paddle_h - ball_h / 2;
                    //     const grace_x = 2;
                    //     const grace_y = 2;
                    //     if (ball.pos[1] > hit_y and ball.pos[1] < hit_y + grace_y and ball.pos[0] >= paddle_bounds.x - ball_w / 2 - grace_x and ball.pos[0] <= paddle_bounds.x + paddle_bounds.w + ball_w / 2 + grace_x) {
                    //         ball.dir = paddleReflect(scene.paddle_pos[0], paddle_w, ball.pos, ball.dir);
                    //         if (scene.paddle_magnet) {
                    //             // Paddle is magnetized - make ball stick!
                    //             // TODO sound?
                    //             ball.pos[0] = ball.pos[0];
                    //             ball.pos[1] = hit_y;
                    //             ball.magnetized = true;
                    //         } else {
                    //             // Bounce the ball
                    //             audio.play(.{ .clip = .bounce });
                    //             // TODO calculate correct out
                    //             // ball.pos = out;
                    //             ball.pos[0] = ball.pos[0];
                    //             ball.pos[1] = hit_y;
                    //         }
                    //         break :paddle_check;
                    //     }

                    //     if (ball.pos[1] > paddle_bounds.y + 2 and paddle_bounds.overlaps(ball_bounds)) {
                    //         const paddle_dir = ball.pos[0] - old_paddle_pos[0];
                    //         if (paddle_dir < 0) {
                    //             ball.dir = .{ -1, 1 };
                    //             ball.pos[0] = paddle_bounds.x - ball_w / 2;
                    //         } else {
                    //             ball.dir = .{ 1, 1 };
                    //             ball.pos[0] = paddle_bounds.x + paddle_bounds.w + ball_w / 2;
                    //         }
                    //         m.normalize(&ball.dir);
                    //         if (ball.controlled) {
                    //             audio.play(.{ .clip = .bounce });
                    //             ball.controlled = false;
                    //         }
                    //         break :paddle_check;
                    //     }
                    // }

                    // If the ball direction is almost horizontal, adjust it so
                    // that it isn't. If we don't do this, the ball may be stuck
                    // for a very long time.
                    if (@abs(ball.dir[1]) < 0.10) {
                        ball.dir[1] = std.math.sign(ball.dir[1]) * 0.10;
                        m.normalize(&ball.dir);
                    }
                },
            }
        }

        // TODO the particle system could be responsible to update all emitters (via handles)
        for (scene.entities) |*e| {
            e.flame.pos = e.pos;
            e.flame.update(game_dt);
            e.explosion.pos = e.pos;
            e.explosion.update(game_dt);
        }

        flame: {
            if (!scene.tickDownTimer("flame_timer", game_dt)) break :flame;
            for (scene.entities) |*e| {
                if (e.type != .ball) continue;
                e.flame.emitting = false;
            }
        }

        _ = scene.tickDownTimer("laser_cooldown_timer", game_dt);
        _ = scene.tickDownTimer("laser_timer", game_dt);
        _ = scene.tickDownTimer("drop_spawn_timer", dt);

        death: {
            if (!scene.tickDownTimer("death_timer", dt)) break :death;

            scene.lives -= 1;
            if (scene.lives == 0) {
                game.scene_mgr.switchTo(.title);
            } else {
                _ = try scene.spawnBall(scene.ballOnPaddlePos(), constants.initial_ball_dir);
                scene.ball_state = .idle;
                scene.ball_speed = ball_base_speed;
                scene.ball_size = .normal;
                scene.flame_timer = 0;
            }
        }

        clear: {
            const clear_delay = 2.5;

            // Has player cleared all the bricks?
            if (scene.clear_timer == 0) {
                for (scene.entities) |e| {
                    if (e.type != .brick) continue;
                    if (e.type != .none) break :clear;
                }
                scene.clear_timer = clear_delay;
                break :clear;
            }

            if (!scene.tickDownTimer("clear_timer", dt)) {
                scene.time_scale = m.lerp(1, 0.1, 1 - (scene.clear_timer / clear_delay));
                break :clear;
            }

            // TODO ugly
            if (game.scene_mgr.level_idx < game.scene_mgr.levels.len - 1) {
                game.scene_mgr.level_idx += 1;
                game.scene_mgr.switchTo(.game);
            } else {
                game.scene_mgr.level_idx = 0;
                game.scene_mgr.switchTo(.title);
            }
            return;
        }
    }

    // * Render

    // TODO should not have to do this
    gfx.setTexture(gfx.spritesheetTexture());

    { // Background
        gfx.setTexture(gfx.spritesheetTexture());
        const sp = sprite.sprites.bg;
        gfx.render(.{
            .src = m.irect(sp.bounds),
            .dst = .{
                .x = 0,
                .y = 0,
                .w = constants.viewport_size[0],
                .h = constants.viewport_size[1],
            },
            .layer = .background,
        });
    }

    { // Top bar
        for (0..scene.lives) |i| {
            const fi: f32 = @floatFromInt(i);
            const sp = sprite.sprites.ball_normal;
            gfx.render(.{
                .src = m.irect(sp.bounds),
                .dst = .{ .x = 2 + fi * (sp.bounds.w + 2), .y = 2, .w = sp.bounds.w, .h = sp.bounds.h },
            });
        }

        // Score
        // TODO have to always remember this when rendering text...
        gfx.setTexture(gfx.fontTexture());
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "score {:0>4}", .{scene.score}) catch unreachable;
        gfx.renderText(label, 32, 0, 5);
    }

    gfx.setTexture(gfx.spritesheetTexture());

    // Render entities
    for (scene.entities) |e| {
        if (e.type == .none) continue;
        if (e.type == .ball) {
            if (e.flame.emitting) {
                gfx.addLight(e.pos, 0xf2a54c);
            }
        }
        if (e.type == .laser) {
            gfx.addLight(e.pos, 0x99E550);
        }
        if (e.type == .brick and e.sprite == .brick_expl) {
            // TODO refactor
            gfx.addLight(.{ e.pos[0], e.pos[1] }, 0xf2a54c);
        }
        if (e.sprite) |s| {
            const sp = sprite.get(s);
            const w: f32 = @floatFromInt(sp.bounds.w);
            const h: f32 = @floatFromInt(sp.bounds.h);
            gfx.render(.{
                .src = m.irect(sp.bounds),
                .dst = .{
                    .x = e.pos[0] - w / 2,
                    .y = e.pos[1] - h / 2,
                    .w = w,
                    .h = h,
                },
                .layer = switch (e.type) {
                    .coin, .powerup => .particles,
                    else => .main,
                },
                .illuminated = switch (e.type) {
                    .laser => false,
                    else => true,
                },
            });
        }
    }

    { // Render paddle
        const sp = sprite.sprites.paddle;
        const bounds = scene.paddleBounds();

        gfx.renderNinePatch(.{
            .src = m.irect(sp.bounds),
            .center = m.irect(sp.center.?),
            .dst = bounds,
            .layer = .main,
        });
    }

    // Render the laser cannons, if active
    if (scene.laser_timer > 0) {
        const bounds = scene.paddleBounds();
        const left = sprite.sprites.laser_left;
        const right = sprite.sprites.laser_right;
        gfx.render(.{
            .src = m.irect(left.bounds),
            .dst = .{
                .x = bounds.x - 2,
                .y = bounds.y - 2,
                .w = left.bounds.w,
                .h = left.bounds.h,
            },
        });
        gfx.render(.{
            .src = m.irect(right.bounds),
            .dst = .{
                .x = bounds.x + bounds.w - right.bounds.w + 2,
                .y = bounds.y - 2,
                .w = right.bounds.w,
                .h = right.bounds.h,
            },
        });
    }

    // Render entity explosion particles
    for (scene.entities) |e| {
        gfx.renderEmitter(e.explosion);
    }

    // Render entity flame particles
    for (scene.entities) |e| {
        gfx.renderEmitter(e.flame);
    }

    { // Render game menus
        ui.begin(.{});
        defer ui.end();

        switch (scene.menu) {
            .none => {},
            .pause => {
                if (renderPauseMenu(&scene.menu)) {
                    game.scene_mgr.switchTo(.title);
                }
            },
            .settings => {
                // We still "render" the pause menu, but flagging it as hidden to preserve its state
                if (renderPauseMenu(&scene.menu)) {
                    game.scene_mgr.switchTo(.title);
                }
                if (settings.renderMenu()) {
                    scene.menu = .pause;
                }
            },
        }
    }
}

fn collideLevelBounds(entity: Entity, p1: [2]f32, p2: [2]f32, out_pos: *[2]f32, out_normal: *[2]f32) bool {
    const sp = sprite.get(entity.sprite orelse return false);
    const ew: f32 = @floatFromInt(sp.bounds.w);
    const eh: f32 = @floatFromInt(sp.bounds.h);
    _ = eh; // autofix

    const vw: f32 = @floatFromInt(constants.viewport_size[0]);
    const vh: f32 = @floatFromInt(constants.viewport_size[1]);

    // Ceiling
    if (line_intersection(p1, p2, .{ 0, brick_start_y }, .{ vw, brick_start_y }, out_pos)) {
        out_normal.* = .{ 0, 1 };
        return true;
    }

    // Right wall
    if (line_intersection(p1, p2, .{ vw - ew / 2, 0 }, .{ vw - ew / 2, vh }, out_pos)) {
        out_normal.* = .{ -1, 0 };
        return true;
    }

    // Left wall
    if (line_intersection(p1, p2, .{ ew / 2, 0 }, .{ ew / 2, vh }, out_pos)) {
        out_normal.* = .{ 1, 0 };
        return true;
    }

    // Floor
    // TODO out kinda wronk
    // if (p2[1] > vh - eh / 2) {
    //     out_pos.* = p2;
    //     out_normal.* = .{ 0, -1 };
    //     return true;
    // }

    return false;
}

// Paddle bounces are handled as follows:
//
// If the ball hits the top surface of the paddle, we
// bounce the ball in a direction determined by how far
// the ball is from the center paddle. Hitting it in the
// center launches it in a vertical direction, while
// each side gives the ball trajectory a more horizontal
// direction.
//
// If the ball hits the side of the paddle, we reflect
// the ball downwards at a 45 degree angle away from the
// paddle and prevent further collisions to ensure
// there's no weirdness at the level edges. At this
// point, the ball can be "shoved" by moving the paddle
// towards it, but it doesn't trigger further direction
// changes.
fn collidePaddle(scene: *GameScene, e: *Entity, p1: [2]f32, p2: [2]f32, old_paddle_pos: [2]f32) bool {
    _ = p2; // autofix

    // NOTE: We only check for collision if the ball is heading
    // downward, because there are situations the ball could be
    // temporarily inside the paddle (and I don't know a better way
    // to solve that which look good or feel good gameplay-wise)
    if (e.dir[1] < 0) return false;

    const sp = sprite.get(e.sprite orelse return false);
    const ew: f32 = @floatFromInt(sp.bounds.w);
    const eh: f32 = @floatFromInt(sp.bounds.h);
    const paddle_bounds = scene.paddleBounds();
    const paddle_w = paddle_bounds.w;
    const paddle_h = paddle_bounds.h;
    const ball_bounds = Rect{
        .x = p1[0] - ew / 2,
        .y = p1[1] - eh / 2,
        .w = ew,
        .h = eh,
    };

    // Top surface

    // TODO if the ball moves fast, it might go through the
    // grace zone. So we should probably consider the old
    // position as well somehow
    const hit_y = scene.paddle_pos[1] - paddle_h - eh / 2;
    const grace_x = 2;
    const grace_y = 2;
    if (e.pos[1] > hit_y and e.pos[1] < hit_y + grace_y and e.pos[0] >= paddle_bounds.x - ew / 2 - grace_x and e.pos[0] <= paddle_bounds.x + paddle_bounds.w + ew / 2 + grace_x) {
        e.pos[1] = hit_y;
        e.dir = paddleReflect(scene.paddle_pos[0], paddle_w, e.pos, e.dir);
        // TODO ugly here
        if (scene.paddle_magnet) {
            // Paddle is magnetized - make ball stick!
            // TODO sound?
            e.magnetized = true;
        } else {
            // Bounce the ball
            audio.play(.{ .clip = .bounce });
        }
        return true;
    }

    if (e.pos[1] > paddle_bounds.y + 2 and paddle_bounds.overlaps(ball_bounds)) {
        const paddle_dir = e.pos[0] - old_paddle_pos[0];
        if (paddle_dir < 0) {
            e.pos[0] = paddle_bounds.x - ew / 2;
            e.dir = .{ -1, 1 };
        } else {
            e.pos[0] = paddle_bounds.x + paddle_bounds.w + ew / 2;
            e.dir = .{ 1, 1 };
        }
        m.normalize(&e.dir);
        if (e.controlled) {
            // TODO ugly here
            audio.play(.{ .clip = .bounce });
            e.controlled = false;
        }
        return true;
    }
    return false;
}

fn collideBricks2(scene: *GameScene, old_pos: [2]f32, new_pos: [2]f32) ?struct {
    out: [2]f32,
    normal: [2]f32,
} {
    const delta = m.vsub(new_pos, old_pos);
    const ball_sprite = sprite.get(scene.ballSprite());
    const ball_w: f32 = @floatFromInt(ball_sprite.bounds.w);
    const ball_h: f32 = @floatFromInt(ball_sprite.bounds.h);
    const ball_bounds = Rect{
        .x = old_pos[0] - ball_w / 2,
        .y = old_pos[1] - ball_h / 2,
        .w = ball_w,
        .h = ball_h,
    };

    var out: [2]f32 = undefined;
    var normal: [2]f32 = undefined;
    var collided = false;
    var coll_dist = std.math.floatMax(f32);
    for (scene.entities) |*e| {
        if (e.type != .brick) continue;

        const brick_bounds = Rect{
            .x = e.pos[0] - brick_w / 2,
            .y = e.pos[1] - brick_h / 2,
            .w = brick_w,
            .h = brick_h,
        };
        const coll = @import("../collision2.zig");
        const result = coll.collide(brick_bounds, .{ 0, 0 }, ball_bounds, delta) orelse continue;
        collided = true;

        // TODO brick_w/brick_h nonsense

        // always use the normal of the closest brick for ball reflection
        const brick_dist = m.magnitude(m.vsub(e.pos, result.pos));
        if (brick_dist < coll_dist) {
            std.log.warn("=== {d:2}x{d:2}", .{ result.normal[0], result.normal[1] });
            out = result.pos;
            normal = result.normal;
            coll_dist = brick_dist;
        }

        const destroyed = scene.destroyBrick(e);
        if (destroyed) spawnDrop(scene, e.pos);
    }
    if (collided) {
        std.log.warn("====", .{});
        return .{ .out = out, .normal = normal };
    }
    return null;
}

fn collideBricks(scene: *GameScene, old_pos: [2]f32, new_pos: [2]f32) ?struct {
    out: [2]f32,
    normal: [2]f32,
} {
    var out: [2]f32 = undefined;
    var normal: [2]f32 = undefined;

    const ball_sprite = sprite.get(scene.ballSprite());
    const ball_w: f32 = @floatFromInt(ball_sprite.bounds.w);
    const ball_h: f32 = @floatFromInt(ball_sprite.bounds.h);

    var collided = false;
    var coll_dist = std.math.floatMax(f32);

    for (scene.entities) |*e| {
        if (e.type != .brick) continue;

        var r = @import("../collision.zig").Rect{
            .min = .{ e.pos[0] - brick_w / 2, e.pos[1] - brick_h / 2 },
            .max = .{ e.pos[0] + brick_w / 2, e.pos[1] + brick_h / 2 },
        };
        r.grow(.{ ball_w / 2, ball_h / 2 });
        var c_normal: [2]f32 = undefined;
        const c = box_intersection(old_pos, new_pos, r, &out, &c_normal);
        if (c) {
            // TODO brick_w/brick_h nonsense

            // always use the normal of the closest brick for ball reflection
            const brick_dist = m.magnitude(m.vsub(e.pos, new_pos));
            if (brick_dist < coll_dist) {
                normal = c_normal;
                coll_dist = brick_dist;
            }

            const destroyed = scene.destroyBrick(e);
            if (destroyed) spawnDrop(scene, e.pos);
        }
        collided = collided or c;
    }

    if (collided) return .{ .out = out, .normal = normal };
    return null;
}

fn destroyBrick(scene: *GameScene, brick: *Entity) bool {
    std.debug.assert(brick.type == .brick);
    const sp = brick.sprite.?;
    // TODO Not great to switch on sprite here - rather, we probably want
    // separate subtypes or properties
    var destroyed = false;
    switch (sp) {
        .brick_expl => {
            brick.type = .none;
            // Surrounding bricks go boom
            scene.destroyBricksCircle(brick.pos, 16);
            destroyed = true;
        },
        .brick_metal => {
            const rng = game.prng.random();
            const weak_sprites = [_]sprite.Sprite{
                .brick_metal_weak,
                .brick_metal_weak2,
                .brick_metal_weak3,
            };
            const next_sprite = weak_sprites[rng.intRangeAtMost(usize, 0, weak_sprites.len - 1)];
            // Metal bricks requires two hits to break
            brick.sprite = next_sprite;
            if (scene.flame_timer <= 0) {
                audio.play(.{ .clip = .clink });
            }
        },
        .brick_metal_weak, .brick_metal_weak2, .brick_metal_weak3 => {
            destroyed = true;
            if (scene.flame_timer <= 0) {
                audio.play(.{ .clip = .clink });
            }
        },
        else => {
            destroyed = true;
        },
    }

    if (destroyed) {
        brick.type = .none;
        audio.play(.{ .clip = .explode });
        scene.score += 100;
        scene.spawnExplosion(brick.pos, sp) catch {};
    }

    return destroyed;
}

fn destroyBricksCircle(scene: *GameScene, origin: [2]f32, radius: f32) void {
    for (scene.entities) |*e| {
        if (e.type != .brick) continue;
        const dir = m.vsub(e.pos, origin);
        if (m.magnitude(dir) <= radius) {
            _ = scene.destroyBrick(e);
        }
    }
}

fn tickDownTimer(scene: *GameScene, comptime field: []const u8, dt: f32) bool {
    if (@field(scene, field) <= 0) return false;
    @field(scene, field) -= dt;
    if (@field(scene, field) > 0) return false;

    @field(scene, field) = 0;
    return true;
}

fn ballSprite(scene: GameScene) sprite.Sprite {
    return switch (scene.ball_size) {
        .smallest => .ball_smallest,
        .smaller => .ball_smaller,
        .normal => .ball_normal,
        .larger => .ball_larger,
        .largest => .ball_largest,
    };
}

fn paddleBounds(scene: GameScene) Rect {
    const sp = sprite.sprites.paddle;

    const scale: f32 = switch (scene.paddle_size) {
        .smallest => 0.25,
        .smaller => 0.5,
        .normal => 1.0,
        .larger => 1.5,
        .largest => 2.0,
    };

    var w: f32 = @floatFromInt(sp.bounds.w);
    w *= scale;
    // NOTE: Hard coded because we can't extract this based on sprite bounds
    // TODO why not?
    const h: f32 = 7;
    return m.Rect{
        .x = scene.paddle_pos[0] - w / 2,
        .y = scene.paddle_pos[1] - h,
        .w = w,
        .h = h,
    };
}

fn paused(scene: *GameScene) bool {
    return scene.menu != .none or game.scene_mgr.next != null;
}

// The angle depends on how far the ball is from the center of the paddle
fn paddleReflect(paddle_pos: f32, paddle_width: f32, ball_pos: [2]f32, ball_dir: [2]f32) [2]f32 {
    const p = (paddle_pos - ball_pos[0]) / paddle_width;
    var new_dir = [_]f32{ -p, -ball_dir[1] };
    m.normalize(&new_dir);
    return new_dir;
}

fn updateIdleBall(scene: *GameScene) void {
    // TODO make iterator for this
    for (scene.entities) |*e| {
        if (e.type != .ball) continue;
        e.pos = scene.ballOnPaddlePos();
    }
}

fn killPlayer(scene: *GameScene) void {
    audio.play(.{ .clip = .death });
    scene.death_timer = death_delay;
}

fn ballOnPaddlePos(scene: GameScene) [2]f32 {
    const paddle_bounds = scene.paddleBounds();
    const ball_sprite = sprite.get(scene.ballSprite());
    const ball_h: f32 = @floatFromInt(ball_sprite.bounds.h);
    return .{
        scene.paddle_pos[0],
        scene.paddle_pos[1] - paddle_bounds.h - ball_h / 2,
    };
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

fn acquirePowerup(scene: *GameScene, p: PowerupType) void {
    scene.score += 200;
    switch (p) {
        .fork => splitBall(scene, &.{
            -pi / 8.0,
            pi / 8.0,
        }),
        .scatter => splitBall(scene, &.{
            -pi / 4.0,
            pi / 4.0,
            3 * pi / 4.0,
            5 * pi / 4.0,
        }),
        .flame => {
            scene.flame_timer = flame_duration;
            for (scene.entities) |*e| {
                if (e.type != .ball) continue;
                e.flame.emitting = true;
            }
        },
        .laser => {
            scene.laser_timer = laser_duration;
        },
        .paddle_size_up => {
            const sizes = std.enums.values(PaddleSize);
            const i = @intFromEnum(scene.paddle_size);
            if (i < sizes.len - 1) {
                scene.paddle_size = @enumFromInt(i + 1);
            }
        },
        .paddle_size_down => {
            const i = @intFromEnum(scene.paddle_size);
            if (i > 0) {
                scene.paddle_size = @enumFromInt(i - 1);
            }
        },
        .ball_speed_up => {
            scene.ball_speed = @min(ball_speed_max, scene.ball_speed + 50);
        },
        .ball_speed_down => {
            scene.ball_speed = @max(ball_speed_min, scene.ball_speed - 50);
        },
        .ball_size_up => {
            const sizes = std.enums.values(BallSize);
            const i = @intFromEnum(scene.ball_size);
            if (i < sizes.len - 1) {
                scene.ball_size = @enumFromInt(i + 1);
            }
        },
        .ball_size_down => {
            const i = @intFromEnum(scene.ball_size);
            if (i > 0) {
                scene.ball_size = @enumFromInt(i - 1);
            }
        },
        .magnet => {
            scene.paddle_magnet = true;
        },
        .death => {
            // Destroy all balls
            for (scene.entities) |*e| {
                switch (e.type) {
                    .ball => {
                        e.type = .none;
                        e.flame.emitting = false;
                        audio.play(.{ .clip = .explode, .vol = 0.5 });
                        _ = scene.spawnExplosion(e.pos, .ball_normal) catch {};
                    },
                    else => {},
                }
            }
            scene.killPlayer();
        },
    }
}

fn splitBall(scene: *GameScene, angles: []const f32) void {
    var active_balls = std.BoundedArray(usize, max_balls){ .len = 0 };
    for (scene.entities, 0..) |e, i| {
        if (e.type != .ball) continue;
        active_balls.append(i) catch continue;
    }
    for (active_balls.constSlice()) |i| {
        var ball = &scene.entities[i];
        var d1 = ball.dir;
        m.vrot(&d1, angles[0]);
        for (angles[1..]) |angle| {
            var d2 = ball.dir;
            m.vrot(&d2, angle);
            const new_ball = scene.spawnBall(ball.pos, d2) catch break;
            new_ball.flame.emitting = ball.flame.emitting;
        }
        ball.dir = d1;
    }
}

fn spawnEntity(scene: *GameScene, entity: Entity) !*Entity {
    for (scene.entities) |*e| {
        if (e.type != .none) continue;
        e.* = entity;
        // Auto-fill some fields so the caller don't have to remember it
        e.flame = FlameEmitter.init(.{ .rng = game.prng.random(), .sprites = &game.particleFlameSprites });
        return e;
    } else {
        return error.MaxEntitiesReached;
    }
}

fn spawnExplosion(scene: *GameScene, pos: [2]f32, sp: sprite.Sprite) !void {
    const expl = try scene.spawnEntity(.{ .type = .explosion, .pos = pos });
    expl.explosion = ExplosionEmitter.init(.{
        .rng = game.prng.random(),
        .sprites = game.particleExplosionSprites(sp),
    });
    expl.explosion.emitting = true;
}

fn spawnDrop(scene: *GameScene, pos: [2]f32) void {
    if (scene.drop_spawn_timer > 0) return;

    const rng = game.prng.random();
    const idx = rng.weightedIndex(f32, &.{ 1 - powerup_freq - coin_freq, powerup_freq, coin_freq });
    switch (idx) {
        0 => return,
        1 => scene.spawnPowerup(pos),
        2 => scene.spawnCoin(pos),
        else => unreachable,
    }
}

fn spawnPowerup(scene: *GameScene, pos: [2]f32) void {
    const rng = game.prng.random();
    const effect = rng.enumValue(PowerupType);
    _ = scene.spawnEntity(.{
        .type = .powerup,
        .pos = pos,
        .sprite = powerupSprite(effect),
        .falling = true,
        .collectible = true,
        .collect_score = 200,
        .collect_effect = effect,
    }) catch return;
}

fn spawnCoin(scene: *GameScene, pos: [2]f32) void {
    _ = scene.spawnEntity(.{
        .type = .coin,
        .pos = pos,
        .sprite = .coin1,
        .falling = true,
        .collectible = true,
        .collect_score = 100,
    }) catch return;
}

fn spawnBall(scene: *GameScene, pos: [2]f32, dir: [2]f32) !*Entity {
    return try scene.spawnEntity(.{
        .type = .ball,
        .pos = pos,
        .dir = dir,
        .colliding = true,
        .speed = scene.ball_speed,
        .sprite = .ball_normal,
    });
}

fn renderPauseMenu(menu: *GameMenu) bool {
    ui.beginWindow(.{
        .id = "pause",
        .x = constants.viewport_size[0] / 2,
        .y = constants.viewport_size[1] / 2,
        .pivot = .{ 0.5, 0.5 },
        .style = if (menu.* == .settings) .hidden else .dialog,
    });
    defer ui.endWindow();

    if (ui.selectionItem("Continue", .{})) {
        menu.* = .none;
    }
    if (ui.selectionItem("Settings", .{})) {
        menu.* = .settings;
    }
    if (ui.selectionItem("Quit", .{})) {
        return true;
    }

    return false;
}
