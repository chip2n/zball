const std = @import("std");
const sprite = @import("sprite");
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
const powerup_freq = 0.8; // TODO 0.1?
const powerup_spawn_cooldown = 1.0;
const powerup_fall_speed = 100;
const flame_duration = 5;
const laser_duration = 5;
const laser_speed = 200;
const laser_cooldown = 0.2;
const brick_w = constants.brick_w;
const brick_h = constants.brick_h;
const brick_start_y = constants.brick_start_y;

pub const EntityType = enum {
    none,
    brick,
    ball,
    laser,
    explosion,
};

pub const Entity = struct {
    type: EntityType = .none,
    pos: [2]f32 = .{ 0, 0 },
    dir: [2]f32 = constants.initial_ball_dir,
    sprite: ?sprite.Sprite = null,
    magnetized: bool = false,
    flame: FlameEmitter = .{},
    explosion: ExplosionEmitter = .{},
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

    /// Make the paddle shoot lasers
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

powerups: [16]Powerup = .{.{}} ** 16,

menu: GameMenu = .none,

time: f32 = 0,
time_scale: f32 = 1,

lives: u8 = 3,
score: u32 = 0,

paddle_pos: [2]f32 = initial_paddle_pos,
paddle_size: PaddleSize = .normal,
paddle_magnet: bool = true,

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
powerup_timer: f32 = 0,

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
    for (0..lvl.height) |y| {
        for (0..lvl.width) |x| {
            const i = y * lvl.width + x;
            const brick = lvl.bricks[i];
            if (brick.id == 0) {
                continue;
            }
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            const s: sprite.Sprite = try game.brickIdToSprite(brick.id);

            const sp = sprite.get(s);
            const w: f32 = @floatFromInt(sp.bounds.w);
            const h: f32 = @floatFromInt(sp.bounds.h);
            _ = try scene.spawnEntity(
                .brick,
                .{ fx * w + w / 2, fy * h + h / 2 + brick_start_y },
                .{ 0, 0 },
                s,
            );
        }
    }

    // spawn one ball to start
    const initial_ball_pos = scene.ballOnPaddlePos();
    _ = scene.spawnEntity(.ball, initial_ball_pos, constants.initial_ball_dir, .ball_normal) catch unreachable;

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
                    _ = scene.spawnEntity(.laser, .{ bounds.x + 2, bounds.y }, .{ 0, -1 }, .particle_laser) catch break :shoot;
                    _ = scene.spawnEntity(.laser, .{ bounds.x + bounds.w - 2, bounds.y }, .{ 0, -1 }, .particle_laser) catch break :shoot;
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

        // Move powerups
        for (&scene.powerups) |*p| {
            if (!p.active) continue;
            p.pos[1] += game_dt * powerup_fall_speed;
            if (p.pos[1] > constants.viewport_size[1]) {
                p.active = false;
            }
        }

        { // Has the paddle hit a powerup?
            const paddle_bounds = scene.paddleBounds();
            for (&scene.powerups) |*p| {
                if (!p.active) continue;
                const sp = powerupSprite(p.type);
                const powerup_bounds = m.Rect{
                    // TODO just store bounds? also using hard coded split sprite here
                    .x = p.pos[0],
                    .y = p.pos[1],
                    .w = @floatFromInt(sp.bounds.w),
                    .h = @floatFromInt(sp.bounds.h),
                };
                if (!paddle_bounds.overlaps(powerup_bounds)) continue;
                p.active = false;
                audio.play(.{ .clip = .powerup });
                acquirePowerup(scene, p.type);
            }
        }

        const ball_sprite = sprite.get(scene.ballSprite());
        const ball_w: f32 = @floatFromInt(ball_sprite.bounds.w);
        const ball_h: f32 = @floatFromInt(ball_sprite.bounds.h);

        // Update entities
        for (scene.entities) |*e| {
            if (e.type == .none) continue;
            switch (e.type) {
                .none => {},
                .brick => {},
                .ball => {
                    const ball = e;
                    const old_ball_pos = ball.pos;

                    // Set the ball sprite based on stored size
                    e.sprite = scene.ballSprite();

                    switch (scene.ball_state) {
                        .idle => {
                            scene.updateIdleBall();
                        },
                        .alive => {
                            if (!ball.magnetized) {
                                ball.pos[0] += ball.dir[0] * scene.ball_speed * game_dt;
                                ball.pos[1] += ball.dir[1] * scene.ball_speed * game_dt;
                            }
                        },
                    }
                    const new_ball_pos = ball.pos;

                    if (scene.collideBricks(old_ball_pos, new_ball_pos)) |coll| {
                        if (scene.flame_timer <= 0) {
                            ball.pos = coll.out;
                            ball.dir = m.reflect(ball.dir, coll.normal);
                        }
                    }

                    var out: [2]f32 = undefined;
                    var normal: [2]f32 = undefined;

                    const vw: f32 = @floatFromInt(constants.viewport_size[0]);
                    const vh: f32 = @floatFromInt(constants.viewport_size[1]);

                    // Has the ball hit the paddle?
                    paddle_check: {
                        // NOTE: We only check for collision if the ball is heading
                        // downward, because there are situations the ball could be
                        // temporarily inside the paddle (and I don't know a better way
                        // to solve that which look good or feel good gameplay-wise)
                        if (ball.dir[1] < 0) break :paddle_check;

                        var paddle_bounds = scene.paddleBounds();
                        const paddle_w = paddle_bounds.w;
                        const paddle_h = paddle_bounds.h;
                        const ball_bounds = Rect{
                            .x = old_ball_pos[0] - ball_w,
                            .y = old_ball_pos[1] - ball_h,
                            .w = ball_w,
                            .h = ball_h,
                        };

                        var collided = false;

                        // After we've moved the paddle, a ball may be inside it. If so,
                        // consider it collided.
                        if (paddle_bounds.overlaps(ball_bounds)) {
                            collided = true;
                            out = old_ball_pos;
                        } else {
                            // TODO reuse
                            var r = @import("../collision.zig").Rect{
                                .min = .{ scene.paddle_pos[0] - paddle_w / 2, scene.paddle_pos[1] - paddle_h },
                                .max = .{ scene.paddle_pos[0] + paddle_w / 2, scene.paddle_pos[1] },
                            };
                            r.grow(.{ ball_w / 2, ball_h / 2 });
                            collided = box_intersection(old_ball_pos, new_ball_pos, r, &out, &normal);
                        }

                        if (collided) {
                            ball.dir = paddleReflect(scene.paddle_pos[0], paddle_w, ball.pos, ball.dir);
                            if (scene.paddle_magnet) {
                                // Paddle is magnetized - make ball stick!
                                // TODO sound?
                                ball.pos = out;
                                ball.pos[1] = paddle_bounds.y - ball_h / 2;
                                ball.magnetized = true;
                            } else {
                                // Bounce the ball
                                audio.play(.{ .clip = .bounce });
                                ball.pos = out;
                            }
                        }
                    }

                    { // Has the ball hit the ceiling?
                        const c = line_intersection(
                            old_ball_pos,
                            ball.pos,
                            .{ 0, brick_start_y },
                            .{ vw - ball_w / 2, brick_start_y },
                            &out,
                        );
                        if (c) {
                            audio.play(.{ .clip = .bounce });
                            normal = .{ 0, 1 };
                            ball.pos = out;
                            ball.dir = m.reflect(ball.dir, normal);
                        }
                    }

                    { // Has the ball hit the right wall?
                        const c = line_intersection(
                            old_ball_pos,
                            ball.pos,
                            .{ vw - ball_w / 2, 0 },
                            .{ vw - ball_w / 2, vh },
                            &out,
                        );
                        if (c) {
                            audio.play(.{ .clip = .bounce });
                            normal = .{ -1, 0 };
                            ball.pos = out;
                            ball.dir = m.reflect(ball.dir, normal);
                        }
                    }

                    { // Has the ball hit the left wall?
                        const c = line_intersection(
                            old_ball_pos,
                            ball.pos,
                            .{ ball_w / 2, 0 },
                            .{ ball_w / 2, vh },
                            &out,
                        );
                        if (c) {
                            audio.play(.{ .clip = .bounce });
                            normal = .{ -1, 0 };
                            ball.pos = out;
                            ball.dir = m.reflect(ball.dir, normal);
                        }
                    }

                    { // Has a ball hit the floor?
                        const c = line_intersection(
                            old_ball_pos,
                            ball.pos,
                            .{ 0, vh - ball_h / 2 },
                            .{ vw, vh - ball_h / 2 },
                            &out,
                        );
                        if (c) {
                            audio.play(.{ .clip = .explode, .vol = 0.5 });
                            _ = scene.spawnExplosion(ball.pos, .ball_normal) catch {};
                            ball.type = .none;
                            ball.flame.emitting = false;

                            // If the ball was the final ball, start a death timer
                            for (scene.entities) |entity| {
                                if (entity.type != .ball) continue;
                                if (entity.type != .none) break;
                            } else {
                                scene.killPlayer();
                            }
                        }
                    }

                    // If the ball direction is almost horizontal, adjust it so
                    // that it isn't. If we don't do this, the ball may be stuck
                    // for a very long time.
                    if (@abs(ball.dir[1]) < 0.10) {
                        ball.dir[1] = std.math.sign(ball.dir[1]) * 0.10;
                        m.normalize(&ball.dir);
                    }
                },
                .laser => {
                    const old_pos = e.pos;
                    var new_pos = e.pos;
                    new_pos[1] -= laser_speed * game_dt;
                    e.pos = new_pos;

                    if (scene.collideBricks(old_pos, new_pos)) |_| {
                        e.type = .none;
                    }
                },
                .explosion => {
                    // When the emitter stops, we remove the entity
                    if (!e.explosion.emitting) {
                        e.* = .{};
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
        _ = scene.tickDownTimer("powerup_timer", dt);

        death: {
            if (!scene.tickDownTimer("death_timer", dt)) break :death;

            scene.lives -= 1;
            if (scene.lives == 0) {
                game.scene_mgr.switchTo(.title);
            } else {
                _ = try scene.spawnEntity(.ball, scene.ballOnPaddlePos(), constants.initial_ball_dir, .ball_normal);
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

    { // Top status bar
        const d = sprite.sprites.dialog;
        gfx.render(.{
            .src = .{
                .x = d.bounds.x + d.center.?.x,
                .y = d.bounds.y + d.center.?.y,
                .w = d.center.?.w,
                .h = d.center.?.h,
            },
            .dst = .{
                .x = 0,
                .y = 0,
                .w = constants.viewport_size[0],
                .h = 8,
            },
        });
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

    // Render powerups
    for (scene.powerups) |p| {
        if (!p.active) continue;
        const sp = powerupSprite(p.type);
        gfx.render(.{
            .src = m.irect(sp.bounds),
            .dst = .{
                .x = p.pos[0],
                .y = p.pos[1],
                .w = @floatFromInt(sp.bounds.w),
                .h = @floatFromInt(sp.bounds.h),
            },
            .layer = .main,
            .z = 5,
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
            // always use the normal of the closest brick for ball reflection
            const brick_dist = m.magnitude(m.vsub(e.pos, new_pos));
            if (brick_dist < coll_dist) {
                normal = c_normal;
                coll_dist = brick_dist;
            }
            e.type = .none;

            if (e.sprite) |sp| scene.spawnExplosion(e.pos, sp) catch {};
            audio.play(.{ .clip = .explode });
            scene.score += 100;

            spawnPowerup(scene, e.pos);
        }
        collided = collided or c;
    }

    if (collided) return .{ .out = out, .normal = normal };
    return null;
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

fn spawnEntity(
    scene: *GameScene,
    entity_type: EntityType,
    pos: [2]f32,
    dir: [2]f32,
    s: ?sprite.Sprite,
) !*Entity {
    for (scene.entities) |*e| {
        if (e.type != .none) continue;
        e.* = .{
            .type = entity_type,
            .pos = pos,
            .dir = dir,
            .flame = FlameEmitter.init(.{
                .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                .sprites = game.particleFlameSprites,
            }),
            .sprite = s,
        };
        return e;
    } else {
        return error.MaxEntitiesReached;
    }
}

fn spawnExplosion(scene: *GameScene, pos: [2]f32, sp: sprite.Sprite) !void {
    const expl = try scene.spawnEntity(.explosion, pos, .{ 0, 0 }, null);
    expl.explosion = ExplosionEmitter.init(.{
        .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
        .sprites = game.particleExplosionSprites(sp),
    });
    expl.explosion.emitting = true;
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
    scene.death_timer = 2.5;
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

const Powerup = struct {
    type: PowerupType = .fork,
    pos: [2]f32 = .{ 0, 0 },
    active: bool = false,
};

fn powerupSprite(p: PowerupType) sprite.SpriteData {
    return switch (p) {
        .fork => sprite.sprites.pow_fork,
        .scatter => sprite.sprites.pow_scatter,
        .flame => sprite.sprites.pow_flame,
        .laser => sprite.sprites.pow_laser,
        .paddle_size_up => sprite.sprites.pow_paddlesizeup,
        .paddle_size_down => sprite.sprites.pow_paddlesizedown,
        .ball_speed_up => sprite.sprites.pow_ballspeedup,
        .ball_speed_down => sprite.sprites.pow_ballspeeddown,
        .ball_size_up => sprite.sprites.pow_ballsizeup,
        .ball_size_down => sprite.sprites.pow_ballsizedown,
        .magnet => sprite.sprites.pow_magnet,
        .death => sprite.sprites.pow_death,
    };
}

fn acquirePowerup(scene: *GameScene, p: PowerupType) void {
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
            const new_ball = scene.spawnEntity(.ball, ball.pos, d2, ball.sprite.?) catch break;
            new_ball.flame.emitting = ball.flame.emitting;
        }
        ball.dir = d1;
    }
}

fn spawnPowerup(scene: *GameScene, pos: [2]f32) void {
    if (scene.powerup_timer > 0) return;

    var prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    const rng = prng.random();
    const value = rng.float(f32);
    if (value < 1 - powerup_freq) return;

    for (&scene.powerups) |*p| {
        if (p.active) continue;
        p.* = .{
            .type = rng.enumValue(PowerupType),
            .pos = pos,
            .active = true,
        };
        scene.powerup_timer = powerup_spawn_cooldown;
        return;
    }
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
