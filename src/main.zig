const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const assert = std.debug.assert;

const sokol = @import("sokol");
const sg = sokol.gfx;
const saudio = sokol.audio;
const stm = sokol.time;
const slog = sokol.log;
const sapp = sokol.app;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const shd = @import("shader");
const font = @import("font");
const sprite = @import("sprite");
const ui = @import("ui.zig");
const fwatch = @import("fwatch");

const Pipeline = @import("shader.zig").Pipeline;
const TextRenderer = @import("ttf.zig").TextRenderer;
const ParticleSystem = @import("particle.zig").ParticleSystem;
const BatchRenderer = @import("batch.zig").BatchRenderer;
const AudioSystem = @import("audio.zig").AudioSystem;

const utils = @import("utils.zig");

const ig = @import("cimgui");
// TODO
const m = @import("math.zig");
const zm = @import("zmath");

const spritesheet = @embedFile("assets/sprites.png");

const audio_bounce = @import("audio.zig").embed("assets/bounce.wav");

const Texture = @import("Texture.zig");

const offscreen_sample_count = 1;

const num_audio_samples = 32;

pub const max_quads = 512;
pub const max_verts = max_quads * 6; // TODO use index buffers
const max_balls = 32;
const powerup_freq = 0.3;
const flame_duration = 5;

const initial_screen_size = .{ 640, 480 };
const viewport_size: [2]i32 = .{ 160, 120 };
const paddle_w: f32 = sprite.sprites.paddle.bounds.w;
const paddle_h: f32 = sprite.sprites.paddle.bounds.h;
const paddle_speed: f32 = 80;
const ball_w: f32 = sprite.sprites.ball.bounds.w;
const ball_h: f32 = sprite.sprites.ball.bounds.h;
const ball_speed: f32 = 70;
const initial_paddle_pos: [2]f32 = .{
    viewport_size[0] / 2,
    viewport_size[1] - 4,
};

const initial_ball_pos: [2]f32 = .{
    initial_paddle_pos[0],
    initial_paddle_pos[1] - paddle_h - ball_h / 2,
};
const initial_ball_dir: [2]f32 = blk: {
    var dir: [2]f32 = .{ 0.3, -1 };
    m.normalize(&dir);
    break :blk dir;
};
const num_bricks = 10;
const num_rows = 4;
pub const brick_w = 16;
pub const brick_h = 8;
const brick_start_y = 8;

const Rect = m.Rect;

const Brick = struct {
    pos: [2]f32,
    sprite: sprite.Sprite,
    destroyed: bool = false,
};

const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: f32,
    v: f32,
};

const debug = if (builtin.os.tag == .linux) struct {
    var watcher: *fwatch.FileWatcher(void) = undefined;
    var reload: bool = false;
} else struct {};

const state = struct {
    const offscreen = struct {
        var pass_action: sg.PassAction = .{};
        var attachments_desc: sg.AttachmentsDesc = .{};
        var attachments: sg.Attachments = .{};
        var pip: sg.Pipeline = .{};
        var bind: sg.Bindings = .{};
    };
    const fsq = struct {
        var pip: sg.Pipeline = .{};
        var bind: sg.Bindings = .{};
    };
    var bg: Pipeline = undefined;
    const ui = struct {
        var pass_action: sg.PassAction = .{};
    };
    const default = struct {
        var pass_action: sg.PassAction = .{};
    };

    var time: f64 = 0;

    var spritesheet_texture: Texture = undefined;
    var font_texture: Texture = undefined;
    var camera: [2]f32 = .{ viewport_size[0] / 2, viewport_size[1] / 2 };
    var textures: std.AutoHashMap(usize, sg.Image) = undefined;

    var window_size: [2]i32 = initial_screen_size;

    var allocator = std.heap.c_allocator;
    var arena: std.heap.ArenaAllocator = undefined;

    var scene: Scene = .{ .title = .{} };

    var batch = BatchRenderer.init();
    var particles = ParticleSystem{};

    var audio = AudioSystem{};
};

const BallState = enum {
    alive, // ball is flying around wreaking all sorts of havoc
    idle, // ball is on paddle and waiting to be shot
};

const Scene = union(enum) {
    title: TitleScene,
    game: GameScene,

    const count = std.enums.values(@typeInfo(Scene).Union.tag_type.?).len;

    fn update(scene: *Scene, dt: f32) void {
        switch (scene.*) {
            .title => scene.title.update(dt),
            .game => scene.game.update(dt),
        }
    }

    fn render(scene: *Scene) void {
        switch (scene.*) {
            .title => scene.title.render(),
            .game => scene.game.render(),
        }
    }

    fn input(scene: *Scene, ev: [*c]const sapp.Event) void {
        switch (scene.*) {
            .title => scene.title.input(ev),
            .game => scene.game.input(ev),
        }
    }
};

const TitleScene = struct {
    idx: usize = 0,

    fn update(scene: *TitleScene, dt: f32) void {
        _ = scene;
        _ = dt;
    }

    fn render(scene: *TitleScene) void {
        state.batch.setTexture(state.spritesheet_texture);

        state.batch.render(.{
            .src = sprite.sprites.title.bounds,
            .dst = .{ .x = 0, .y = 0, .w = viewport_size[0], .h = viewport_size[1] },
        });

        { // Text
            state.batch.setTexture(state.font_texture); // TODO have to always remember this when rendering text...

            var y = @as(f32, @floatFromInt(viewport_size[1])) / 2;
            { // Start
                var text_renderer = TextRenderer{};
                var buf: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{s} start", .{if (scene.idx == 0) ">" else " "}) catch unreachable;
                const measure = TextRenderer.measure(label);
                text_renderer.render(&state.batch, label, (viewport_size[0] - measure[0]) / 2, y);
                y += measure[1] + 4;
            }
            { // Quit
                var text_renderer = TextRenderer{};
                var buf: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{s} quit", .{if (scene.idx == 1) ">" else " "}) catch unreachable;
                const measure = TextRenderer.measure(label);
                text_renderer.render(&state.batch, label, (viewport_size[0] - measure[0]) / 2, y);
            }
        }

        const result = state.batch.commit();
        sg.updateBuffer(state.offscreen.bind.vertex_buffers[0], sg.asRange(result.verts));

        const vs_params = computeVsParams();

        sg.beginPass(.{ .action = state.offscreen.pass_action, .attachments = state.offscreen.attachments });
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
        for (result.batches) |b| {
            state.offscreen.bind.fs.images[shd.SLOT_tex] = state.textures.get(b.tex).?;
            sg.applyBindings(state.offscreen.bind);
            sg.draw(@intCast(b.offset), @intCast(b.len), 1);
        }
        sg.endPass();
    }

    fn input(scene: *TitleScene, ev: [*c]const sapp.Event) void {
        switch (ev.*.type) {
            .KEY_DOWN => {
                switch (ev.*.key_code) {
                    .DOWN => {
                        scene.idx = @mod(scene.idx + 1, Scene.count);
                    },
                    .UP => {
                        if (scene.idx == 0) {
                            scene.idx = Scene.count - 1;
                        } else {
                            scene.idx -= 1;
                        }
                    },
                    .ENTER, .SPACE => {
                        if (scene.idx == 0) {
                            state.scene = Scene{ .game = GameScene.init() };
                        } else if (scene.idx == 1) {
                            sapp.quit();
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

const GameMenu = struct {
    state: enum { none, pause, settings } = .none,
    pause_idx: usize = 0,
    settings_idx: usize = 0,
};

const PowerupType = enum { split, flame };
const Powerup = struct {
    type: PowerupType = .split,
    pos: [2]f32 = .{ 0, 0 },
    active: bool = false,
};

const Ball = struct {
    pos: [2]f32 = initial_ball_pos,
    dir: [2]f32 = initial_ball_dir,
    active: bool = false,
};

const GameScene = struct {
    bricks: [num_rows * num_bricks]Brick = undefined,
    powerups: [16]Powerup = .{.{}} ** 16,

    menu: GameMenu = .{},

    time: f32 = 0,
    lives: u8 = 3,
    score: u32 = 0,

    // When player dies, we start a timer. When it reaches zero, we start a new
    // round (or send them to the title screen).
    death_timer: f32 = 0,

    paddle_pos: [2]f32 = initial_paddle_pos,

    balls: [max_balls]Ball = .{.{}} ** max_balls,
    ball_state: BallState = .idle,

    flame_timer: f32 = 0,

    inputs: struct {
        left_down: bool = false,
        right_down: bool = false,
        space_down: bool = false,
    } = .{},

    collisions: [8]struct {
        brick: usize,
        loc: [2]f32,
        normal: [2]f32,
    } = undefined,
    collision_count: usize = 0,

    fn init() GameScene {
        var scene = GameScene{};

        // spawn one ball to start
        scene.balls[0] = .{
            .pos = initial_ball_pos,
            .dir = initial_ball_dir,
            .active = true,
        };

        // initialize bricks
        const brick_sprites = [_]sprite.Sprite{ .brick1, .brick2, .brick3, .brick4 };
        for (0..num_rows) |y| {
            for (0..num_bricks) |x| {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                scene.bricks[y * num_bricks + x] = .{
                    .pos = .{ fx * brick_w, brick_start_y + fy * brick_h },
                    .sprite = brick_sprites[y],
                };
            }
        }

        return scene;
    }

    fn update(scene: *GameScene, dt: f32) void {
        // Reset data from previous frame
        scene.collision_count = 0;

        if (scene.paused()) return;
        scene.time += dt;

        { // Move paddle
            var paddle_dx: f32 = 0;
            if (scene.inputs.left_down) {
                paddle_dx -= 1;
            }
            if (scene.inputs.right_down) {
                paddle_dx += 1;
            }
            const new_pos = scene.paddle_pos[0] + paddle_dx * paddle_speed * dt;
            scene.paddle_pos[0] = std.math.clamp(new_pos, paddle_w / 2, viewport_size[0] - paddle_w / 2);
        }

        // Fire ball when pressing space
        if (scene.inputs.space_down and scene.ball_state == .idle) {
            scene.ball_state = .alive;
        }

        // Move powerups
        for (&scene.powerups) |*p| {
            if (!p.active) continue;
            p.pos[1] += dt * 40;
            if (p.pos[1] > viewport_size[1]) {
                p.active = false;
            }
        }

        { // Has the paddle hit a powerup?
            const paddle_bounds = m.Rect{
                .x = scene.paddle_pos[0] - paddle_w / 2,
                .y = scene.paddle_pos[1] - paddle_h,
                .w = paddle_w,
                .h = paddle_h,
            };
            for (&scene.powerups) |*p| {
                if (!p.active) continue;
                const powerup_bounds = m.Rect{
                    // TODO just store bounds? also using hard coded split sprite here
                    .x = p.pos[0],
                    .y = p.pos[1],
                    .w = sprite.sprites.powerup_split.bounds.w,
                    .h = sprite.sprites.powerup_split.bounds.h,
                };
                if (!paddle_bounds.overlaps(powerup_bounds)) continue;
                p.active = false;
                state.audio.play(.{ .clip = .powerup });
                switch (p.type) {
                    .split => {
                        // var new_balls = std.BoundedArray(Ball, max_balls){ .len = 0 };
                        // var new_balls: [max_balls]Ball = .{.{}} ** max_balls;
                        var new_balls = std.BoundedArray(usize, max_balls){ .len = 0 };

                        for (scene.balls, 0..) |ball, i| {
                            if (!ball.active) continue;
                            new_balls.append(i) catch continue;
                        }
                        for (new_balls.constSlice()) |i| {
                            var ball = &scene.balls[i];
                            var d1 = ball.dir;
                            var d2 = ball.dir;
                            m.vrot(&d1, -std.math.pi / 8.0);
                            m.vrot(&d2, std.math.pi / 8.0);
                            ball.dir = d1;
                            scene.spawnBall(ball.pos, d2) catch break;
                        }
                    },
                    .flame => {
                        scene.flame_timer = flame_duration;
                        // TODO add particle effect
                    },
                }
            }
        }

        // Move balls
        for (&scene.balls) |*ball| {
            if (!ball.active) continue;
            const old_ball_pos = ball.pos;
            switch (scene.ball_state) {
                .idle => {
                    scene.updateIdleBall();
                },
                .alive => {
                    ball.pos[0] += ball.dir[0] * ball_speed * dt;
                    ball.pos[1] += ball.dir[1] * ball_speed * dt;
                },
            }
            const new_ball_pos = ball.pos;

            var out: [2]f32 = undefined;
            var normal: [2]f32 = undefined;

            { // Has the ball hit any bricks?
                var collided = false;
                var coll_dist = std.math.floatMax(f32);
                for (&scene.bricks, 0..) |*brick, i| {
                    if (brick.destroyed) continue;

                    var r = @import("collision.zig").Rect{
                        .min = .{ brick.pos[0], brick.pos[1] },
                        .max = .{ brick.pos[0] + brick_w, brick.pos[1] + brick_h },
                    };
                    r.grow(.{ ball_w / 2, ball_h / 2 });
                    var c_normal: [2]f32 = undefined;
                    const c = @import("collision.zig").box_intersection(old_ball_pos, new_ball_pos, r, &out, &c_normal);
                    if (c) {
                        // always use the normal of the closest brick for ball reflection
                        const brick_pos = .{ brick.pos[0] + brick_w / 2, brick.pos[1] + brick_h / 2 };
                        const brick_dist = m.magnitude(m.vsub(brick_pos, ball.pos));
                        if (brick_dist < coll_dist) {
                            normal = c_normal;
                            coll_dist = brick_dist;
                        }
                        brick.destroyed = true;
                        state.particles.emit(.{
                            .origin = brick_pos,
                            .count = 10,
                            .sprite = brick.sprite,
                        });
                        state.audio.play(.{ .clip = .explode });
                        scene.score += 100;

                        scene.spawnPowerup(brick.pos);

                        scene.collisions[scene.collision_count] = .{ .brick = i, .loc = out, .normal = c_normal };
                        scene.collision_count += 1;
                    }
                    collided = collided or c;
                }
                if (collided and scene.flame_timer <= 0) {
                    ball.pos = out;
                    ball.dir = m.reflect(ball.dir, normal);
                }
            }

            const vw: f32 = @floatFromInt(viewport_size[0]);
            const vh: f32 = @floatFromInt(viewport_size[1]);

            { // Has the ball hit the paddle?
                // TODO reuse
                var r = @import("collision.zig").Rect{
                    .min = .{ scene.paddle_pos[0] - paddle_w / 2, scene.paddle_pos[1] - paddle_h },
                    .max = .{ scene.paddle_pos[0] + paddle_w / 2, scene.paddle_pos[1] },
                };
                r.grow(.{ ball_w / 2, ball_h / 2 });
                // TODO not sure we're using the right ball positions
                const c = @import("collision.zig").box_intersection(old_ball_pos, new_ball_pos, r, &out, &normal);
                if (c) {
                    state.audio.play(.{ .clip = .bounce });
                    ball.pos = out;
                    ball.dir = paddle_reflect(scene.paddle_pos[0], paddle_w, ball.pos, ball.dir);
                }
            }

            { // Has the ball hit the ceiling?
                const c = @import("collision.zig").line_intersection(
                    old_ball_pos,
                    ball.pos,
                    .{ 0, brick_start_y },
                    .{ vw - ball_w / 2, brick_start_y },
                    &out,
                );
                if (c) {
                    state.audio.play(.{ .clip = .bounce });
                    normal = .{ 0, 1 };
                    ball.pos = out;
                    ball.dir = m.reflect(ball.dir, normal);
                }
            }

            { // Has the ball hit the right wall?
                const c = @import("collision.zig").line_intersection(
                    old_ball_pos,
                    ball.pos,
                    .{ vw - ball_w / 2, 0 },
                    .{ vw - ball_w / 2, vh },
                    &out,
                );
                if (c) {
                    state.audio.play(.{ .clip = .bounce });
                    normal = .{ -1, 0 };
                    ball.pos = out;
                    ball.dir = m.reflect(ball.dir, normal);
                }
            }

            { // Has the ball hit the left wall?
                const c = @import("collision.zig").line_intersection(
                    old_ball_pos,
                    ball.pos,
                    .{ ball_w / 2, 0 },
                    .{ ball_w / 2, vh },
                    &out,
                );
                if (c) {
                    state.audio.play(.{ .clip = .bounce });
                    normal = .{ -1, 0 };
                    ball.pos = out;
                    ball.dir = m.reflect(ball.dir, normal);
                }
            }

            { // Has a ball hit the floor?
                const c = @import("collision.zig").line_intersection(
                    old_ball_pos,
                    ball.pos,
                    .{ 0, vh - ball_h / 2 },
                    .{ vw, vh - ball_h / 2 },
                    &out,
                );
                if (c) {
                    state.audio.play(.{ .clip = .explode, .vol = 0.5 });
                    state.particles.emit(.{
                        .origin = ball.pos,
                        .count = 10,
                        .sprite = .ball,
                        .start_angle = -std.math.pi,
                        .sweep = std.math.pi,
                    });
                    ball.active = false;

                    // If the ball was the final ball, start a death timer
                    for (scene.balls) |balls| {
                        if (balls.active) break;
                    } else {
                        state.audio.play(.{ .clip = .death });
                        scene.death_timer = 2.5;
                    }
                }
            }
        }

        state.particles.update(dt);

        flame: {
            if (scene.flame_timer <= 0) break :flame;
            scene.flame_timer -= dt;
            if (scene.flame_timer > 0) break :flame;

            scene.flame_timer = 0;
        }

        death: {
            if (scene.death_timer <= 0) break :death;
            scene.death_timer -= dt;
            if (scene.death_timer > 0) break :death;

            scene.death_timer = 0;

            if (scene.lives == 0) {
                state.scene = Scene{ .title = .{} };
            } else {
                scene.lives -= 1;

                scene.balls[0] = .{
                    .active = true,
                    .dir = initial_ball_dir,
                };
                scene.ball_state = .idle;
            }
        }
    }

    fn paused(scene: *GameScene) bool {
        return scene.menu.state != .none;
    }

    fn spawnBall(scene: *GameScene, pos: [2]f32, dir: [2]f32) !void {
        for (&scene.balls) |*ball| {
            if (ball.active) continue;
            ball.* = .{
                .pos = pos,
                .dir = dir,
                .active = true,
            };
            break;
        } else {
            return error.MaxBallsReached;
        }
    }

    fn spawnPowerup(scene: *GameScene, pos: [2]f32) void {
        // TODO don't recreate
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

    // The angle depends on how far the ball is from the center of the paddle
    fn paddle_reflect(paddle_pos: f32, paddle_width: f32, ball_pos: [2]f32, ball_dir: [2]f32) [2]f32 {
        const p = (paddle_pos - ball_pos[0]) / paddle_width;
        var new_dir = [_]f32{ -p, -ball_dir[1] };
        m.normalize(&new_dir);
        return new_dir;
    }

    fn updateIdleBall(scene: *GameScene) void {
        for (&scene.balls) |*ball| {
            if (!ball.active) continue;
            ball.pos[0] = scene.paddle_pos[0];
            ball.pos[1] = scene.paddle_pos[1] - paddle_h - ball_h / 2;
        }
    }

    fn render(scene: *GameScene) void {
        state.batch.setTexture(state.spritesheet_texture);

        // Render all bricks
        for (scene.bricks) |brick| {
            if (brick.destroyed) continue;
            const x = brick.pos[0];
            const y = brick.pos[1];
            const slice = sprite.get(brick.sprite);
            state.batch.render(.{
                .src = .{
                    .x = @floatFromInt(slice.bounds.x),
                    .y = @floatFromInt(slice.bounds.y),
                    .w = @floatFromInt(slice.bounds.w),
                    .h = @floatFromInt(slice.bounds.h),
                },
                .dst = .{ .x = x, .y = y, .w = brick_w, .h = brick_h },
            });
        }

        // Render balls
        for (scene.balls) |ball| {
            if (!ball.active) continue;
            state.batch.render(.{
                .src = sprite.sprites.ball.bounds,
                .dst = .{
                    .x = ball.pos[0] - ball_w / 2,
                    .y = ball.pos[1] - ball_h / 2,
                    .w = ball_w,
                    .h = ball_h,
                },
            });
        }

        // Render paddle
        state.batch.render(.{
            .src = sprite.sprites.paddle.bounds,
            .dst = .{
                .x = scene.paddle_pos[0] - paddle_w / 2,
                .y = scene.paddle_pos[1] - paddle_h,
                .w = paddle_w,
                .h = paddle_h,
            },
        });

        // Render powerups
        for (scene.powerups) |p| {
            if (!p.active) continue;
            const s = sprite.sprites.powerup_split;
            state.batch.render(.{
                .src = s.bounds,
                .dst = .{
                    .x = p.pos[0],
                    .y = p.pos[1],
                    .w = s.bounds.w,
                    .h = s.bounds.h,
                },
            });
        }

        // Render particles
        state.particles.render(&state.batch);

        { // Top status bar
            const d = sprite.sprites.dialog;
            state.batch.render(.{
                .src = .{
                    .x = d.bounds.x + d.center.x,
                    .y = d.bounds.y + d.center.y,
                    .w = d.center.w,
                    .h = d.center.h,
                },
                .dst = .{
                    .x = 0,
                    .y = 0,
                    .w = viewport_size[0],
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
        }

        { // Score
            state.batch.setTexture(state.font_texture); // TODO have to always remember this when rendering text...
            var text_renderer = TextRenderer{};
            var buf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "score {:0>4}", .{scene.score}) catch unreachable;
            text_renderer.render(&state.batch, label, 32, 0);
        }

        // Render game menus
        switch (scene.menu.state) {
            .none => {},
            .pause => {
                // overlay
                state.batch.setTexture(state.spritesheet_texture);
                state.batch.render(.{
                    .src = sprite.sprites.overlay.bounds,
                    .dst = .{ .x = 0, .y = 0, .w = viewport_size[0], .h = viewport_size[1] },
                });

                ui.begin(.{
                    .x = viewport_size[0] / 2,
                    .y = viewport_size[1] / 2,
                    .pivot = .{ 0.5, 0.5 },
                    .batch = &state.batch,
                    .tex_spritesheet = state.spritesheet_texture,
                    .tex_font = state.font_texture,
                });
                defer ui.end();

                if (ui.selectionItem("Continue", .{ .selected = scene.menu.pause_idx == 0 })) {
                    scene.menu.state = .none;
                }
                if (ui.selectionItem("Settings", .{ .selected = scene.menu.pause_idx == 1 })) {
                    scene.menu.state = .settings;
                }
                if (ui.selectionItem("Quit", .{ .selected = scene.menu.pause_idx == 2 })) {
                    sapp.quit();
                }
            },
            .settings => {
                // overlay
                state.batch.setTexture(state.spritesheet_texture);
                state.batch.render(.{
                    .src = sprite.sprites.overlay.bounds,
                    .dst = .{ .x = 0, .y = 0, .w = viewport_size[0], .h = viewport_size[1] },
                });

                ui.begin(.{
                    .x = viewport_size[0] / 2,
                    .y = viewport_size[1] / 2,
                    .pivot = .{ 0.5, 0.5 },
                    .batch = &state.batch,
                    .tex_spritesheet = state.spritesheet_texture,
                    .tex_font = state.font_texture,
                });
                defer ui.end();

                _ = ui.selectionItem("Volume (sfx)", .{ .selected = scene.menu.settings_idx == 0 });
                ui.slider(.{ .value = &state.audio.vol_sfx, .focused = scene.menu.settings_idx == 0 });
                _ = ui.selectionItem("Volume (bg)", .{ .selected = scene.menu.settings_idx == 1 });
                ui.slider(.{ .value = &state.audio.vol_bg, .focused = scene.menu.settings_idx == 1 });
                if (ui.selectionItem("Back", .{ .selected = scene.menu.settings_idx == 2 })) {
                    scene.menu.state = .pause;
                }
            },
        }

        const result = state.batch.commit();
        sg.updateBuffer(state.offscreen.bind.vertex_buffers[0], sg.asRange(result.verts));

        const vs_params = computeVsParams();

        sg.beginPass(.{ .action = state.offscreen.pass_action, .attachments = state.offscreen.attachments });

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
        for (result.batches) |b| {
            state.offscreen.bind.fs.images[shd.SLOT_tex] = state.textures.get(b.tex).?;
            sg.applyBindings(state.offscreen.bind);
            sg.draw(@intCast(b.offset), @intCast(b.len), 1);
        }

        sg.endPass();
    }

    fn input(scene: *GameScene, ev: [*c]const sapp.Event) void {
        switch (scene.menu.state) {
            .none => {
                switch (ev.*.type) {
                    .KEY_DOWN => {
                        switch (ev.*.key_code) {
                            .LEFT => {
                                scene.inputs.left_down = true;
                            },
                            .RIGHT => {
                                scene.inputs.right_down = true;
                            },
                            .SPACE => {
                                scene.inputs.space_down = true;
                            },
                            .ESCAPE => {
                                scene.menu.state = .pause;
                            },
                            else => {},
                        }
                    },
                    .KEY_UP => {
                        switch (ev.*.key_code) {
                            .LEFT => {
                                scene.inputs.left_down = false;
                            },
                            .RIGHT => {
                                scene.inputs.right_down = false;
                            },
                            .SPACE => {
                                scene.inputs.space_down = false;
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            .pause => {
                switch (ev.*.type) {
                    .KEY_DOWN => {
                        switch (ev.*.key_code) {
                            .UP => {
                                if (scene.menu.pause_idx == 0) {
                                    scene.menu.pause_idx = 2;
                                } else {
                                    scene.menu.pause_idx -= 1;
                                }
                            },
                            .DOWN => {
                                if (scene.menu.pause_idx == 2) {
                                    scene.menu.pause_idx = 0;
                                } else {
                                    scene.menu.pause_idx += 1;
                                }
                            },
                            .ESCAPE => {
                                scene.menu.state = .none;
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            .settings => {
                switch (ev.*.type) {
                    .KEY_DOWN => {
                        switch (ev.*.key_code) {
                            .UP => {
                                if (scene.menu.settings_idx == 0) {
                                    scene.menu.settings_idx = 2;
                                } else {
                                    scene.menu.settings_idx -= 1;
                                }
                            },
                            .DOWN => {
                                if (scene.menu.settings_idx == 2) {
                                    scene.menu.settings_idx = 0;
                                } else {
                                    scene.menu.settings_idx += 1;
                                }
                            },
                            .ESCAPE => {
                                scene.menu.state = .pause;
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            },
        }
    }
};

fn renderGui() void {
    //=== UI CODE STARTS HERE
    ig.igSetNextWindowPos(.{ .x = 100, .y = 100 }, ig.ImGuiCond_Once, .{ .x = 0, .y = 0 });
    ig.igSetNextWindowSize(.{ .x = 400, .y = 200 }, ig.ImGuiCond_Once);
    _ = ig.igBegin("Debug", 0, ig.ImGuiWindowFlags_None);
    _ = ig.igText("Window: %d %d", state.window_size[0], state.window_size[1]);
    _ = ig.igText("Memory usage: %d", state.arena.queryCapacity());
    // _ = ig.igText("Ball pos: %f %f", scene.ball_pos[0], scene.ball_pos[1]);
    _ = ig.igDragFloat2("Camera", &state.camera, 1, -1000, 1000, "%.4g", ig.ImGuiSliderFlags_None);

    if (ig.igButton("emit", .{})) {
        state.particles.emit(.{
            .origin = .{ 40, 40 },
            .count = 10,
            .sprite = .ball,
            .start_angle = -std.math.pi,
            .sweep = std.math.pi,
        });
    }
    if (ig.igButton("Play sound", .{})) {
        state.audio.play(.{ .clip = .bounce });
    }
    if (ig.igButton("Play sound twice", .{})) {
        state.audio.play(.{ .clip = .bounce });
        state.audio.play(.{ .clip = .bounce });
    }
    if (ig.igButton("Play sound thrice", .{})) {
        state.audio.play(.{ .clip = .bounce });
        state.audio.play(.{ .clip = .bounce });
        state.audio.play(.{ .clip = .bounce });
    }
    if (ig.igButton("Play music", .{})) {
        state.audio.play(.{ .clip = .music, .loop = true, .vol = 0.5, .category = .bg });
    }

    if (config.shader_reload) {
        if (ig.igButton("Load shader", .{})) {
            debug.reload = true;
        }
    }

    ig.igEnd();
}

fn initializeGame() !void {
    state.arena = std.heap.ArenaAllocator.init(state.allocator);
    errdefer state.arena.deinit();

    const allocator = state.arena.allocator();

    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    errdefer sg.shutdown();

    saudio.setup(.{
        // TODO: The sample_rate and num_channels parameters are only hints for
        // the audio backend, it isn't guaranteed that those are the values used
        // for actual playback.
        .num_channels = 2,
        .buffer_frames = 512, // lowers audio latency (TODO shitty on web though)
        .logger = .{ .func = slog.func },
    });
    errdefer saudio.shutdown();

    stm.setup();

    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });

    // setup pass action for default render pass
    state.default.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };

    // setup pass action for imgui
    state.ui.pass_action.colors[0] = .{ .load_action = .LOAD };

    // set pass action for offscreen render pass
    state.offscreen.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1 },
    };

    state.offscreen.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = max_verts * @sizeOf(Vertex),
    });

    // setup the offscreen render pass resources
    // this will also be called when the window resizes
    createOffscreenAttachments(viewport_size[0], viewport_size[1]);

    state.spritesheet_texture = Texture.init(spritesheet);
    state.font_texture = Texture.init(font.image);

    state.textures = std.AutoHashMap(usize, sg.Image).init(allocator);
    try state.textures.put(state.spritesheet_texture.id, sg.makeImage(state.spritesheet_texture.desc));
    try state.textures.put(state.font_texture.id, sg.makeImage(state.font_texture.desc));
    state.offscreen.bind.fs.samplers[shd.SLOT_smp] = sg.makeSampler(.{});

    // create a shader and pipeline object
    var pip_desc: sg.PipelineDesc = .{
        .shader = sg.makeShader(shd.mainShaderDesc(sg.queryBackend())),
        .cull_mode = .BACK,
        .sample_count = offscreen_sample_count,
        .depth = .{
            .pixel_format = .DEPTH,
            .compare = .LESS_EQUAL,
            .write_enabled = false,
        },
        .color_count = 1,
    };
    pip_desc.layout.attrs[shd.ATTR_vs_position].format = .FLOAT3;
    pip_desc.layout.attrs[shd.ATTR_vs_color0].format = .UBYTE4N;
    pip_desc.layout.attrs[shd.ATTR_vs_texcoord0].format = .FLOAT2;
    pip_desc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
    };

    state.offscreen.pip = sg.makePipeline(pip_desc);

    // a vertex buffer to render a fullscreen quad
    const quad_vbuf = sg.makeBuffer(.{
        .usage = .IMMUTABLE,
        .data = sg.asRange(&[_]f32{ -0.5, -0.5, 0.5, -0.5, -0.5, 0.5, 0.5, 0.5 }),
    });

    // shader and pipeline object to render a fullscreen quad which composes
    // the 3 offscreen render targets into the default framebuffer
    var fsq_pip_desc: sg.PipelineDesc = .{
        .shader = sg.makeShader(shd.fsqShaderDesc(sg.queryBackend())),
        .primitive_type = .TRIANGLE_STRIP,
    };
    fsq_pip_desc.layout.attrs[shd.ATTR_vs_fsq_pos].format = .FLOAT2;
    state.fsq.pip = sg.makePipeline(fsq_pip_desc);

    // a sampler to sample the offscreen render target as texture
    const smp = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    // resource bindings to render the fullscreen quad (composed from the
    // offscreen render target textures
    state.fsq.bind.vertex_buffers[0] = quad_vbuf;
    state.fsq.bind.fs.samplers[0] = smp;

    // background shader
    if (config.shader_reload) {
        const path = try utils.getExecutablePath(allocator);
        const dir = std.fs.path.dirname(path).?;
        const shader_path = try std.fs.path.join(allocator, &.{ dir, "libshd.so" });
        state.bg = try Pipeline.load(shader_path, "bgShaderDesc");

        debug.watcher = try fwatch.FileWatcher(void).init(allocator, onFileEvent);
        errdefer debug.watcher.deinit();

        try debug.watcher.start();
        try debug.watcher.add(shader_path, {});
    } else {
        state.bg = try Pipeline.init();
    }
    state.bg.bind.vertex_buffers[0] = quad_vbuf;
}

const QuadOptions = struct {
    buf: []Vertex,
    src: ?Rect = null,
    dst: Rect,
    // reference texture dimensions
    tw: f32,
    th: f32,
};

fn quad(v: QuadOptions) void {
    const buf = v.buf;
    const x = v.dst.x;
    const y = v.dst.y;
    const z = 0;
    const w = v.dst.w;
    const h = v.dst.h;
    const tw = v.tw;
    const th = v.th;

    const src = v.src orelse Rect{ .x = 0, .y = 0, .w = tw, .h = th };
    const uv1 = .{ src.x / tw, src.y / th };
    const uv2 = .{ (src.x + src.w) / tw, (src.y + src.h) / th };
    // zig fmt: off
    buf[0] = .{ .x = x,      .y = y,      .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv1[1] };
    buf[1] = .{ .x = x,      .y = y + h,  .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv2[1] };
    buf[2] = .{ .x = x + w,  .y = y + h,  .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv2[1] };
    buf[3] = .{ .x = x,      .y = y,      .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv1[1] };
    buf[4] = .{ .x = x + w,  .y = y + h,  .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv2[1] };
    buf[5] = .{ .x = x + w,  .y = y,      .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv1[1] };
    // zig fmt: on
}

fn computeVsParams() shd.VsParams {
    const model = zm.identity();
    const view = zm.translation(-state.camera[0], -state.camera[1], 0);
    const proj = zm.orthographicLh(
        @floatFromInt(viewport_size[0]),
        @floatFromInt(viewport_size[1]),
        -10,
        10,
    );
    const mvp = zm.mul(model, zm.mul(view, proj));
    return shd.VsParams{ .mvp = mvp };
}

fn computeFSQParams() shd.VsFsqParams {
    const width: f32 = @floatFromInt(state.window_size[0]);
    const height: f32 = @floatFromInt(state.window_size[1]);
    const aspect = width / height;

    const vw: f32 = @floatFromInt(viewport_size[0]);
    const vh: f32 = @floatFromInt(viewport_size[1]);
    const viewport_aspect = vw / vh;

    var model = zm.scaling(2, (2 / viewport_aspect) * aspect, 1);
    if (aspect > viewport_aspect) {
        model = zm.scaling((2 * viewport_aspect) / aspect, 2, 1);
    }
    return shd.VsFsqParams{ .mvp = model };
}

// helper function to create or re-create render target images and pass object for offscreen rendering
fn createOffscreenAttachments(width: i32, height: i32) void {
    // destroy previous resources (can be called with invalid ids)
    sg.destroyAttachments(state.offscreen.attachments);
    for (state.offscreen.attachments_desc.colors) |att| {
        sg.destroyImage(att.image);
    }
    sg.destroyImage(state.offscreen.attachments_desc.depth_stencil.image);

    // create offscreen render target images and pass
    const color_img_desc: sg.ImageDesc = .{
        .render_target = true,
        .width = width,
        .height = height,
        .sample_count = offscreen_sample_count,
    };
    var depth_img_desc = color_img_desc;
    depth_img_desc.pixel_format = .DEPTH;

    state.offscreen.attachments_desc.colors[0].image = sg.makeImage(color_img_desc);
    state.offscreen.attachments_desc.depth_stencil.image = sg.makeImage(depth_img_desc);
    state.offscreen.attachments = sg.makeAttachments(state.offscreen.attachments_desc);

    // update the fullscreen-quad texture bindings
    state.fsq.bind.fs.images[shd.SLOT_tex] = state.offscreen.attachments_desc.colors[0].image;
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
    const ticks = stm.now();
    const time = stm.sec(ticks);
    state.time = time;

    const dt: f32 = @floatCast(sapp.frameDuration());
    state.scene.update(dt);

    if (config.shader_reload and debug.reload) {
        state.bg.reload() catch {};
        debug.reload = false;
    }

    state.audio.update(time);

    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    state.scene.render();

    renderGui();

    const fsq_params = computeFSQParams();
    sg.beginPass(.{ .action = state.default.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.fsq.pip);
    sg.applyBindings(state.fsq.bind);
    sg.applyUniforms(.VS, shd.SLOT_vs_fsq_params, sg.asRange(&fsq_params));
    sg.draw(0, 4, 1);
    sg.endPass();

    sg.beginPass(.{ .action = state.ui.pass_action, .swapchain = sglue.swapchain() });
    simgui.render();
    sg.endPass();

    sg.commit();
}

export fn sokolEvent(ev: [*c]const sapp.Event) void {
    _ = simgui.handleEvent(ev.*);
    ui.handleEvent(ev.*);

    switch (ev.*.type) {
        .RESIZED => {
            const width = ev.*.window_width;
            const height = ev.*.window_height;
            state.window_size = .{ width, height };
            createOffscreenAttachments(viewport_size[0], viewport_size[1]);
        },
        else => {
            state.scene.input(ev);
        },
    }
}

export fn sokolCleanup() void {
    saudio.shutdown();
    sg.shutdown();
    state.arena.deinit();
    if (config.shader_reload) {
        debug.watcher.deinit();
    }
}

pub fn main() !void {
    sapp.run(.{
        .init_cb = sokolInit,
        .frame_cb = sokolFrame,
        .cleanup_cb = sokolCleanup,
        .event_cb = sokolEvent,
        .width = initial_screen_size[0],
        .height = initial_screen_size[1],
        .icon = .{ .sokol_default = true },
        .window_title = "Game",
        .logger = .{ .func = slog.func },
    });
}
