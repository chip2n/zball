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

const TextRenderer = @import("../ttf.zig").TextRenderer;

const ui = @import("../ui.zig");

const m = @import("math");
const Rect = m.Rect;
const box_intersection = @import("../collision.zig").box_intersection;
const line_intersection = @import("../collision.zig").line_intersection;
const pi = std.math.pi;

const state = @import("../state.zig");

// TODO move to constants?
const paddle_speed: f32 = 180;
const ball_w: f32 = sprite.sprites.ball.bounds.w;
const ball_h: f32 = sprite.sprites.ball.bounds.h;
const ball_speed: f32 = 200;
const initial_paddle_pos: [2]f32 = .{
    constants.viewport_size[0] / 2,
    constants.viewport_size[1] - 4,
};
const max_balls = 32;
const max_entities = 128;
const powerup_freq = 0.3;
const powerup_fall_speed = 100;
const flame_duration = 5;
const laser_duration = 5;
const laser_speed = 200;
const laser_cooldown = 0.2;
const max_brick_emitters = 20;
const brick_w = constants.brick_w;
const brick_h = constants.brick_h;
const brick_start_y = constants.brick_start_y;


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

const BallState = enum {
    alive, // ball is flying around wreaking all sorts of havoc
    idle, // ball is on paddle and waiting to be shot
};

const GameMenu = enum { none, pause, settings };

const PaddleType = enum {
    normal,
    laser,
};

fn paddleSprite(p: PaddleType) sprite.SpriteData {
    return switch (p) {
        .normal => sprite.sprites.paddle_normal,
        .laser => sprite.sprites.paddle_laser,
    };
}

const PowerupType = enum {
    /// Splits the ball into two in a Y-shape
    fork,

    /// Splits the ball into four in an X-shape
    scatter,

    /// Make the ball pass through bricks
    flame,

    /// Make the paddle shoot lasers
    laser,
};

// TODO add random rotations?
pub const GameScene = struct {
    allocator: std.mem.Allocator,

    bricks: []Brick,
    powerups: [16]Powerup = .{.{}} ** 16,

    menu: GameMenu = .none,

    time: f32 = 0,
    time_scale: f32 = 1,

    lives: u8 = 1,
    score: u32 = 0,

    paddle_type: PaddleType = .normal,
    paddle_pos: [2]f32 = initial_paddle_pos,

    entities: []Entity,

    ball_state: BallState = .idle,

    // When player clears the board, we start this timer. When it reaches zero,
    // we switch to the next board (or the title screen, if the board cleared
    // was the last one).
    clear_timer: f32 = 0,

    // When player dies, we start this timer. When it reaches zero, we start a new
    // round (or send them to the title screen).
    death_timer: f32 = 0,

    flame_timer: f32 = 0,
    laser_timer: f32 = 0,
    laser_cooldown: f32 = 0,

    // TODO make a better input system
    inputs: struct {
        left_down: bool = false,
        right_down: bool = false,
        shoot_down: bool = false,
    } = .{},

    pub fn init(allocator: std.mem.Allocator, lvl: Level) !GameScene {
        const bricks = try allocator.alloc(Brick, lvl.width * lvl.height);
        errdefer allocator.free(bricks);
        const entities = try allocator.alloc(Entity, max_entities);
        errdefer allocator.free(entities);

        var scene = GameScene{
            .allocator = allocator,
            .bricks = bricks,
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
                    scene.bricks[i] = .{};
                    continue;
                }
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                const s: sprite.Sprite = try game.brickIdToSprite(brick.id);
                scene.bricks[i] = .{
                    .pos = .{ fx * brick_w, brick_start_y + fy * brick_h },
                    .sprite = s,
                    .emitter = ExplosionEmitter.init(.{
                        .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                        .sprites = game.particleExplosionSprites(s),
                    }),
                    .destroyed = false,
                };
            }
        }

        // spawn one ball to start
        const initial_ball_pos = scene.ballOnPaddlePos();
        _ = scene.spawnEntity(.ball, initial_ball_pos, constants.initial_ball_dir) catch unreachable;

        return scene;
    }

    pub fn deinit(scene: GameScene) void {
        scene.allocator.free(scene.bricks);
        scene.allocator.free(scene.entities);
    }

    pub fn start(scene: *GameScene) void {
        scene.death_timer = 0;
        scene.flame_timer = 0;
        scene.laser_timer = 0;
    }

    pub fn frame(scene: *GameScene, dt: f32) !void {
        // The delta time used by the game itself (minus "global
        // timers"). Scaled by `time_scale` to support slowdown effects.
        const game_dt = scene.time_scale * dt;

        if (!scene.paused()) {
            input.showMouse(false);
            input.lockMouse(true);

            const mouse_delta = input.mouseDelta();

            scene.time += game_dt;

            { // Move paddle
                const new_pos = blk: {
                    // Mouse
                    if (m.magnitude(mouse_delta) > 0) {
                        break :blk scene.paddle_pos[0] + (mouse_delta[0] * scene.time_scale);
                    }
                    // Keyboard
                    var paddle_dx: f32 = 0;
                    if (scene.inputs.left_down) {
                        paddle_dx -= 1;
                    }
                    if (scene.inputs.right_down) {
                        paddle_dx += 1;
                    }
                    break :blk scene.paddle_pos[0] + paddle_dx * paddle_speed * game_dt;
                };

                const bounds = scene.paddleBounds();
                scene.paddle_pos[0] = std.math.clamp(new_pos, bounds.w / 2, constants.viewport_size[0] - bounds.w / 2);
            }

            // Handle shoot input
            if (scene.inputs.shoot_down) shoot: {
                if (scene.ball_state == .idle) {
                    scene.ball_state = .alive;
                } else if (scene.paddle_type == .laser and scene.laser_cooldown <= 0) {
                    const bounds = scene.paddleBounds();
                    _ = scene.spawnEntity(.laser, .{ bounds.x + 2, bounds.y }, .{ 0, -1 }) catch break :shoot;
                    _ = scene.spawnEntity(.laser, .{ bounds.x + bounds.w - 2, bounds.y }, .{ 0, -1 }) catch break :shoot;
                    scene.laser_cooldown = laser_cooldown;
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

            // Update entities
            for (scene.entities) |*e| {
                if (!e.active) continue;
                switch (e.type) {
                    .ball => {
                        const ball = e;
                        const old_ball_pos = ball.pos;
                        switch (scene.ball_state) {
                            .idle => {
                                scene.updateIdleBall();
                            },
                            .alive => {
                                ball.pos[0] += ball.dir[0] * ball_speed * game_dt;
                                ball.pos[1] += ball.dir[1] * ball_speed * game_dt;
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
                                audio.play(.{ .clip = .bounce });
                                ball.pos = out;
                                ball.dir = paddleReflect(scene.paddle_pos[0], paddle_w, ball.pos, ball.dir);
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
                                // TODO avoid recreation
                                ball.explosion = ExplosionEmitter.init(.{
                                    .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                                    .sprites = game.particleExplosionSprites(.ball),
                                });
                                ball.explosion.emitting = true;
                                ball.active = false;
                                ball.flame.emitting = false;

                                // If the ball was the final ball, start a death timer
                                for (scene.entities) |entity| {
                                    if (entity.type != .ball) continue;
                                    if (entity.active) break;
                                } else {
                                    audio.play(.{ .clip = .death });
                                    scene.death_timer = 2.5;
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
                            e.active = false;
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
            for (scene.bricks) |*brick| {
                brick.emitter.update(game_dt);
            }

            flame: {
                if (!scene.tickDownTimer("flame_timer", game_dt)) break :flame;
                for (scene.entities) |*e| {
                    if (e.type != .ball) continue;
                    e.flame.emitting = false;
                }
            }

            laser: { // Laser powerup
                _ = scene.tickDownTimer("laser_cooldown", game_dt);
                if (!scene.tickDownTimer("laser_timer", game_dt)) break :laser;
                scene.paddle_type = .normal;
            }

            death: {
                if (!scene.tickDownTimer("death_timer", dt)) break :death;

                scene.lives -= 1;
                if (scene.lives == 0) {
                    state.scene_mgr.switchTo(.title);
                } else {
                    _ = try scene.spawnEntity(.ball, scene.ballOnPaddlePos(), constants.initial_ball_dir);
                    scene.ball_state = .idle;
                }
            }

            clear: {
                const clear_delay = 2.5;

                // Has player cleared all the bricks?
                if (scene.clear_timer == 0) {
                    for (scene.bricks) |brick| {
                        if (!brick.destroyed) break :clear;
                    }
                    scene.clear_timer = clear_delay;
                    break :clear;
                }

                if (!scene.tickDownTimer("clear_timer", dt)) {
                    scene.time_scale = m.lerp(1, 0.1, 1 - (scene.clear_timer / clear_delay));
                    break :clear;
                }

                // TODO ugly
                if (state.scene_mgr.level_idx < state.scene_mgr.levels.len - 1) {
                    state.scene_mgr.level_idx += 1;
                    state.scene_mgr.switchTo(.game);
                } else {
                    state.scene_mgr.level_idx = 0;
                    state.scene_mgr.switchTo(.title);
                }
                return;
            }
        }

        // Render
        { // Top status bar
            state.batch.setTexture(state.spritesheet_texture);
            const d = sprite.sprites.dialog;
            state.batch.render(.{
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
                state.batch.render(.{
                    .src = sprite.sprites.ball.bounds,
                    .dst = .{ .x = 2 + fi * (ball_w + 2), .y = 2, .w = ball_w, .h = ball_h },
                });
            }

            // Score
            // TODO have to always remember this when rendering text...
            state.batch.setTexture(state.font_texture);
            var text_renderer = TextRenderer{};
            var buf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "score {:0>4}", .{scene.score}) catch unreachable;
            text_renderer.render(&state.batch, label, 32, 0, 5);
        }

        state.batch.setTexture(state.spritesheet_texture);

        // Render all bricks
        for (scene.bricks) |brick| {
            if (brick.destroyed) continue;
            const x = brick.pos[0];
            const y = brick.pos[1];
            const slice = sprite.get(brick.sprite);
            state.batch.render(.{
                .src = slice.bounds,
                .dst = .{ .x = x, .y = y, .w = brick_w, .h = brick_h },
            });
        }

        // Render entities
        for (scene.entities) |e| {
            if (!e.active) continue;
            switch (e.type) {
                .ball => {
                    state.batch.render(.{
                        .src = sprite.sprites.ball.bounds,
                        .dst = .{
                            .x = e.pos[0] - ball_w / 2,
                            .y = e.pos[1] - ball_h / 2,
                            .w = ball_w,
                            .h = ball_h,
                        },
                        .z = 2,
                    });
                },
                .laser => {
                    const sp = sprite.sprites.particle_laser;
                    state.batch.render(.{
                        .src = sp.bounds,
                        .dst = .{
                            .x = e.pos[0] - sp.bounds.w / 2,
                            .y = e.pos[1] - sp.bounds.h / 2,
                            .w = sp.bounds.w,
                            .h = sp.bounds.h,
                        },
                        .z = 2,
                    });
                },
            }
        }

        { // Render paddle
            const sp = paddleSprite(scene.paddle_type);
            const w: f32 = @floatFromInt(sp.bounds.w);
            const h: f32 = @floatFromInt(sp.bounds.h);
            state.batch.render(.{
                .src = sp.bounds,
                .dst = .{
                    .x = scene.paddle_pos[0] - w / 2,
                    .y = scene.paddle_pos[1] - h,
                    .w = w,
                    .h = h,
                },
            });
        }

        // Render powerups
        for (scene.powerups) |p| {
            if (!p.active) continue;
            const sp = powerupSprite(p.type);
            state.batch.render(.{
                .src = sp.bounds,
                .dst = .{
                    .x = p.pos[0],
                    .y = p.pos[1],
                    .w = @floatFromInt(sp.bounds.w),
                    .h = @floatFromInt(sp.bounds.h),
                },
            });
        }

        // Render brick explosions
        for (scene.bricks) |brick| {
            brick.emitter.render(&state.batch);
        }

        // Render entity explosion particles
        for (scene.entities) |e| {
            e.explosion.render(&state.batch);
        }

        // Render entity flame particles
        for (scene.entities) |e| {
            e.flame.render(&state.batch);
        }

        { // Render game menus
            try ui.begin(.{
                .batch = &state.batch,
                .tex_spritesheet = state.spritesheet_texture,
                .tex_font = state.font_texture,
            });
            defer ui.end();

            switch (scene.menu) {
                .none => {},
                .pause => {
                    if (try renderPauseMenu(&scene.menu)) {
                        state.scene_mgr.switchTo(.title);
                    }
                },
                .settings => {
                    // We still "render" the pause menu, but flagging it as hidden to preserve its state
                    if (try renderPauseMenu(&scene.menu)) {
                        state.scene_mgr.switchTo(.title);
                    }
                    if (try settings.renderMenu()) {
                        scene.menu = .pause;
                    }
                },
            }
        }

        const vs_params = shd.VsParams{ .mvp = state.camera.view_proj };

        { // Main scene
            state.beginOffscreenPass();

            // render background
            sg.applyPipeline(state.bg.pip);
            const bg_params = shd.FsBgParams{
                .time = scene.time,
            };
            sg.applyUniforms(.FS, shd.SLOT_fs_bg_params, sg.asRange(&bg_params));
            sg.applyBindings(state.bg.bind);
            sg.draw(0, 4, 1);

            // render game scene
            sg.applyPipeline(state.offscreen.pip);
            sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
            try state.renderBatch();
            sg.endPass();
        }
    }

    fn collideBricks(scene: *GameScene, old_pos: [2]f32, new_pos: [2]f32) ?struct {
        out: [2]f32,
        normal: [2]f32,
    } {
        var out: [2]f32 = undefined;
        var normal: [2]f32 = undefined;

        var collided = false;
        var coll_dist = std.math.floatMax(f32);
        for (scene.bricks) |*brick| {
            if (brick.destroyed) continue;

            var r = @import("../collision.zig").Rect{
                .min = .{ brick.pos[0], brick.pos[1] },
                .max = .{ brick.pos[0] + brick_w, brick.pos[1] + brick_h },
            };
            r.grow(.{ ball_w / 2, ball_h / 2 });
            var c_normal: [2]f32 = undefined;
            const c = box_intersection(old_pos, new_pos, r, &out, &c_normal);
            if (c) {
                // always use the normal of the closest brick for ball reflection
                const brick_pos = .{ brick.pos[0] + brick_w / 2, brick.pos[1] + brick_h / 2 };
                const brick_dist = m.magnitude(m.vsub(brick_pos, new_pos));
                if (brick_dist < coll_dist) {
                    normal = c_normal;
                    coll_dist = brick_dist;
                }
                brick.destroyed = true;
                // If we haven't reached the max emitter count for bricks, start a new one
                var emitter_count: usize = 0;
                for (scene.bricks) |b2| {
                    if (!b2.emitter.emitting) continue;
                    emitter_count += 1;
                }
                if (emitter_count < max_brick_emitters) {
                    brick.emitter = ExplosionEmitter.init(.{
                        .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                        .sprites = game.particleExplosionSprites(brick.sprite),
                    });
                    brick.emitter.pos = brick_pos;
                    brick.emitter.emitting = true;
                }
                audio.play(.{ .clip = .explode });
                scene.score += 100;

                spawnPowerup(scene, brick.pos);
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

    fn paddleBounds(scene: GameScene) Rect {
        const sp = paddleSprite(scene.paddle_type);
        const w: f32 = @floatFromInt(sp.bounds.w);
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
        return scene.menu != .none or state.scene_mgr.next != null;
    }

    fn spawnEntity(scene: *GameScene, entity_type: EntityType, pos: [2]f32, dir: [2]f32) !*Entity {
        for (scene.entities) |*e| {
            if (e.active) continue;
            e.* = .{
                .type = entity_type,
                .pos = pos,
                .dir = dir,
                // TODO some entities don't need emitters...
                .flame = FlameEmitter.init(.{
                    .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                    .sprites = game.particleFlameSprites,
                }),
                .explosion = ExplosionEmitter.init(.{
                    .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                    .sprites = game.particleExplosionSprites(.ball),
                }),
                .active = true,
            };
            return e;
        } else {
            return error.MaxEntitiesReached;
        }
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
            if (!e.active) continue;
            if (e.type != .ball) continue;
            e.pos = scene.ballOnPaddlePos();
        }
    }

    fn ballOnPaddlePos(scene: GameScene) [2]f32 {
        const bounds = scene.paddleBounds();
        return .{
            scene.paddle_pos[0],
            scene.paddle_pos[1] - bounds.h - ball_h / 2,
        };
    }

    pub fn handleInput(scene: *GameScene, ev: [*c]const sapp.Event) !void {
        switch (scene.menu) {
            .none => {
                switch (ev.*.type) {
                    .KEY_DOWN => {
                        const action = input.identifyAction(ev.*.key_code) orelse return;
                        switch (action) {
                            .left => {
                                scene.inputs.left_down = true;
                            },
                            .right => {
                                scene.inputs.right_down = true;
                            },
                            .shoot => {
                                scene.inputs.shoot_down = true;
                            },
                            .back => {
                                scene.menu = .pause;
                            },
                            else => {},
                        }
                    },
                    .KEY_UP => {
                        const action = input.identifyAction(ev.*.key_code) orelse return;
                        switch (action) {
                            .left => {
                                scene.inputs.left_down = false;
                            },
                            .right => {
                                scene.inputs.right_down = false;
                            },
                            .shoot => {
                                scene.inputs.shoot_down = false;
                            },
                            else => {},
                        }
                    },
                    .MOUSE_DOWN => {
                        scene.inputs.shoot_down = true;
                    },
                    .MOUSE_UP => {
                        scene.inputs.shoot_down = false;
                    },
                    else => {},
                }
            },
            .pause => {
                switch (ev.*.type) {
                    .KEY_DOWN => {
                        const action = input.identifyAction(ev.*.key_code) orelse return;
                        switch (action) {
                            .back => scene.menu = .none,
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            .settings => {
                switch (ev.*.type) {
                    .KEY_DOWN => {
                        const action = input.identifyAction(ev.*.key_code) orelse return;
                        switch (action) {
                            .back => scene.menu = .pause,
                            else => {},
                        }
                    },
                    else => {},
                }
            },
        }
    }
};

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
                if (!e.active) continue;
                if (e.type != .ball) continue;
                e.flame.emitting = true;
            }
        },
        .laser => {
            scene.laser_timer = laser_duration;
            scene.paddle_type = .laser;
        },
    }
}

fn splitBall(scene: *GameScene, angles: []const f32) void {
    var active_balls = std.BoundedArray(usize, max_balls){ .len = 0 };
    for (scene.entities, 0..) |e, i| {
        if (!e.active) continue;
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
            const new_ball = scene.spawnEntity(.ball, ball.pos, d2) catch break;
            new_ball.flame.emitting = ball.flame.emitting;
        }
        ball.dir = d1;
    }
}

fn spawnPowerup(scene: *GameScene, pos: [2]f32) void {
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
        return;
    }
}

fn renderPauseMenu(menu: *GameMenu) !bool {
    try ui.beginWindow(.{
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
