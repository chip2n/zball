const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const assert = std.debug.assert;

const sokol = @import("sokol");
const sg = sokol.gfx;
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

const Viewport = @import("Viewport.zig");
const Camera = @import("Camera.zig");
const Pipeline = @import("shader.zig").Pipeline;
const TextRenderer = @import("ttf.zig").TextRenderer;
const BatchRenderer = @import("batch.zig").BatchRenderer;

const audio = @import("audio.zig");

const box_intersection = @import("collision.zig").box_intersection;
const line_intersection = @import("collision.zig").line_intersection;

const particle = @import("particle.zig");
const utils = @import("utils.zig");

const ig = @import("cimgui");
const m = @import("math");

const spritesheet = @embedFile("assets/sprites.png");

const Texture = @import("Texture.zig");

pub const offscreen_sample_count = 1;

const pi = std.math.pi;
const num_audio_samples = 32;

pub const std_options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

pub const max_quads = 2048;
pub const max_verts = max_quads * 6; // TODO use index buffers
const max_balls = 32;
const max_entities = 128;
const powerup_freq = 0.3;
const flame_duration = 5;
const laser_duration = 5;
const laser_speed = 200;
const laser_cooldown = 0.2;

const use_gpa = builtin.os.tag != .emscripten;

const initial_screen_size = .{ 640, 480 };
pub const viewport_size: [2]u32 = .{ 160, 120 };
const paddle_speed: f32 = 180;
const ball_w: f32 = sprite.sprites.ball.bounds.w;
const ball_h: f32 = sprite.sprites.ball.bounds.h;
const ball_speed: f32 = 100;
const initial_paddle_pos: [2]f32 = .{
    viewport_size[0] / 2,
    viewport_size[1] - 4,
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
    emitter: ExplosionEmitter = undefined,
    destroyed: bool = false,
};

// TODO move?
pub const Vertex = extern struct {
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

// TODO refactor this a bit
const state = struct {
    var viewport: Viewport = undefined;
    var camera: Camera = undefined;

    const offscreen = struct {
        var pip: sg.Pipeline = .{};
        var bind: sg.Bindings = .{};
        var pass_action: sg.PassAction = .{};
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
    var dt: f32 = 0;

    var spritesheet_texture: Texture = undefined;
    var font_texture: Texture = undefined;
    var textures: std.AutoHashMap(usize, sg.Image) = undefined;

    var window_size: [2]i32 = initial_screen_size;

    /// Mouse position in unscaled pixels
    var mouse_pos: [2]f32 = .{ 0, 0 };
    var mouse_delta: [2]f32 = .{ 0, 0 };

    var allocator: std.mem.Allocator = undefined;
    var arena: std.heap.ArenaAllocator = undefined;

    var scene: Scene = .{ .title = .{} };
    var next_scene: ?SceneType = null;

    var batch = BatchRenderer.init();
};

const BallState = enum {
    alive, // ball is flying around wreaking all sorts of havoc
    idle, // ball is on paddle and waiting to be shot
};

const SceneType = std.meta.Tag(Scene);

const Scene = union(enum) {
    title: TitleScene,
    game: GameScene,

    fn deinit(scene: *Scene) void {
        switch (scene.*) {
            .title => scene.title.deinit(),
            .game => scene.game.deinit(),
        }
    }

    fn update(scene: *Scene, dt: f32) !void {
        switch (scene.*) {
            .title => try scene.title.update(dt),
            .game => try scene.game.update(dt),
        }
    }

    fn render(scene: *Scene) !void {
        switch (scene.*) {
            .title => try scene.title.render(),
            .game => try scene.game.render(),
        }
    }

    fn input(scene: *Scene, ev: [*c]const sapp.Event) !void {
        switch (scene.*) {
            .title => try scene.title.input(ev),
            .game => try scene.game.input(ev),
        }
    }
};

const TitleScene = struct {
    idx: usize = 0,
    settings: bool = false,

    fn update(scene: *TitleScene, dt: f32) !void {
        _ = dt;

        try ui.begin(.{
            .batch = &state.batch,
            .tex_spritesheet = state.spritesheet_texture,
            .tex_font = state.font_texture,
        });
        defer ui.end();

        { // Main menu
            try ui.beginWindow(.{
                .id = "main",
                .x = viewport_size[0] / 2,
                .y = viewport_size[1] / 2 + 24,
                .z = 10,
                .pivot = .{ 0.5, 0.5 },
                .style = .transparent,
            });
            defer ui.endWindow();

            if (ui.selectionItem("Start", .{})) {
                state.next_scene = .game;
            }
            if (ui.selectionItem("Settings", .{})) {
                scene.settings = true;
            }
            if (ui.selectionItem("Quit", .{})) {
                sapp.quit();
            }
        }

        if (scene.settings and try renderSettingsMenu()) {
            scene.settings = false;
        }
    }

    fn render(scene: *TitleScene) !void {
        _ = scene;
        state.batch.setTexture(state.spritesheet_texture);

        state.batch.render(.{
            .src = sprite.sprites.title.bounds,
            .dst = .{
                .x = 0,
                .y = 0,
                .w = viewport_size[0],
                .h = viewport_size[1],
            },
        });

        const result = state.batch.commit();
        sg.updateBuffer(state.offscreen.bind.vertex_buffers[0], sg.asRange(result.verts));

        const vs_params = shd.VsParams{ .mvp = state.camera.view_proj };

        sg.beginPass(.{
            .action = state.offscreen.pass_action,
            .attachments = state.viewport.attachments,
        });
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
        for (result.batches) |b| {
            state.offscreen.bind.fs.images[shd.SLOT_tex] = state.textures.get(b.tex).?;
            sg.applyBindings(state.offscreen.bind);
            sg.draw(@intCast(b.offset), @intCast(b.len), 1);
        }
        sg.endPass();
    }

    fn input(scene: *TitleScene, ev: [*c]const sapp.Event) !void {
        if (scene.settings) {
            switch (ev.*.type) {
                .KEY_DOWN => {
                    switch (ev.*.key_code) {
                        .ESCAPE => scene.settings = false,
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    fn deinit(scene: *TitleScene) void {
        _ = scene;
    }
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

const EntityType = enum {
    ball,
    laser,
};

const Entity = struct {
    type: EntityType = .ball, // TODO introduce null-entity and use that instead of active field?
    active: bool = false,
    pos: [2]f32 = .{ 0, 0 },
    dir: [2]f32 = initial_ball_dir,
    flame: FlameEmitter = undefined,
    explosion: ExplosionEmitter = undefined,
};

const FlameEmitter = particle.Emitter(.{
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

const particleFlameSprites = &.{
    .{ .sprite = .particle_flame_6, .weight = 0.2 },
    .{ .sprite = .particle_flame_5, .weight = 0.2 },
    .{ .sprite = .particle_flame_4, .weight = 0.4 },
    .{ .sprite = .particle_flame_3, .weight = 0.5 },
    .{ .sprite = .particle_flame_2, .weight = 0.5 },
};

// TODO add random rotations?
const ExplosionEmitter = particle.Emitter(.{
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

fn particleExplosionSprites(s: sprite.Sprite) []const particle.SpriteDesc {
    return switch (s) {
        .brick1 => &brick_sprites1,
        .brick2 => &brick_sprites2,
        .brick3 => &brick_sprites3,
        .brick4 => &brick_sprites4,
        .ball => &ball_sprites,
        else => unreachable,
    };
}

/// Get mouse coordinates, scaled to viewport size
fn mouse() [2]f32 {
    return state.camera.screenToWorld(state.mouse_pos);
}

/// Get mouse delta, scaled based on zoom
fn mouseDelta() [2]f32 {
    return m.vmul(state.mouse_delta, 1 / state.camera.zoom());
}

const showMouse = sapp.showMouse;
const lockMouse = sapp.lockMouse;

const GameScene = struct {
    allocator: std.mem.Allocator,

    bricks: []Brick,
    powerups: [16]Powerup = .{.{}} ** 16,

    menu: GameMenu = .none,

    time: f32 = 0,
    lives: u8 = 3,
    score: u32 = 0,

    paddle_type: PaddleType = .normal,
    paddle_pos: [2]f32 = initial_paddle_pos,

    entities: []Entity,

    ball_state: BallState = .idle,

    // When player dies, we start a timer. When it reaches zero, we start a new
    // round (or send them to the title screen).
    death_timer: f32 = 0,

    flame_timer: f32 = 0,
    laser_timer: f32 = 0,
    laser_cooldown: f32 = 0,

    inputs: struct {
        left_down: bool = false,
        right_down: bool = false,
        shoot_down: bool = false,
    } = .{},

    fn init(allocator: std.mem.Allocator) !GameScene {
        const bricks = try allocator.alloc(Brick, num_rows * num_bricks);
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
        const brick_sprites = [_]sprite.Sprite{ .brick1, .brick2, .brick3, .brick4 };
        for (0..num_rows) |y| {
            for (0..num_bricks) |x| {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                const s = brick_sprites[y];
                scene.bricks[y * num_bricks + x] = .{
                    .pos = .{ fx * brick_w, brick_start_y + fy * brick_h },
                    .sprite = s,
                    .emitter = ExplosionEmitter.init(.{
                        .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                        .sprites = particleExplosionSprites(s),
                    }),
                };
            }
        }

        // spawn one ball to start
        const initial_ball_pos = scene.ballOnPaddlePos();
        _ = scene.spawnEntity(.ball, initial_ball_pos, initial_ball_dir) catch unreachable;

        return scene;
    }

    fn deinit(scene: GameScene) void {
        scene.allocator.free(scene.bricks);
        scene.allocator.free(scene.entities);
    }

    fn start(scene: *GameScene) void {
        scene.death_timer = 0;
        scene.flame_timer = 0;
        scene.laser_timer = 0;
    }

    fn update(scene: *GameScene, dt: f32) !void {
        if (scene.paused()) {
            showMouse(true);
            lockMouse(false);
            return;
        }
        showMouse(false);
        lockMouse(true);

        const mouse_delta = mouseDelta();

        scene.time += dt;

        { // Move paddle
            const new_pos = blk: {
                if (m.magnitude(mouse_delta) > 0) {
                    break :blk scene.paddle_pos[0] + mouse_delta[0];
                }
                var paddle_dx: f32 = 0;
                if (scene.inputs.left_down) {
                    paddle_dx -= 1;
                }
                if (scene.inputs.right_down) {
                    paddle_dx += 1;
                }
                break :blk scene.paddle_pos[0] + paddle_dx * paddle_speed * dt;
            };

            const bounds = scene.paddleBounds();
            scene.paddle_pos[0] = std.math.clamp(new_pos, bounds.w / 2, viewport_size[0] - bounds.w / 2);
        }

        // Handle shoot input
        if (scene.inputs.shoot_down) {
            if (scene.ball_state == .idle) {
                scene.ball_state = .alive;
            } else if (scene.paddle_type == .laser and scene.laser_cooldown <= 0) {
                const bounds = scene.paddleBounds();
                _ = try scene.spawnEntity(.laser, .{ bounds.x + 2, bounds.y }, .{ 0, -1 });
                _ = try scene.spawnEntity(.laser, .{ bounds.x + bounds.w - 2, bounds.y }, .{ 0, -1 });
                scene.laser_cooldown = laser_cooldown;
            }
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
                            ball.pos[0] += ball.dir[0] * ball_speed * dt;
                            ball.pos[1] += ball.dir[1] * ball_speed * dt;
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

                    const vw: f32 = @floatFromInt(viewport_size[0]);
                    const vh: f32 = @floatFromInt(viewport_size[1]);

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
                            var r = @import("collision.zig").Rect{
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
                                .sprites = particleExplosionSprites(.ball),
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
                        std.log.debug("Ball direction is almost horizontal - making it less horizontal.", .{});
                        ball.dir[1] = std.math.sign(ball.dir[1]) * 0.10;
                        m.normalize(&ball.dir);
                    }
                },
                .laser => {
                    const old_pos = e.pos;
                    var new_pos = e.pos;
                    new_pos[1] -= laser_speed * dt;
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
            e.flame.update(dt);

            e.explosion.pos = e.pos;
            e.explosion.update(dt);
        }
        for (scene.bricks) |*brick| {
            brick.emitter.update(dt);
        }

        flame: {
            if (!scene.tickDownTimer("flame_timer", dt)) break :flame;
            for (scene.entities) |*e| {
                if (e.type != .ball) continue;
                e.flame.emitting = false;
            }
        }

        laser: { // Laser powerup
            _ = scene.tickDownTimer("laser_cooldown", dt);
            if (!scene.tickDownTimer("laser_timer", dt)) break :laser;
            scene.paddle_type = .normal;
        }

        death: {
            if (!scene.tickDownTimer("death_timer", dt)) break :death;

            if (scene.lives == 0) {
                state.next_scene = .title;
            } else {
                scene.lives -= 1;
                _ = try scene.spawnEntity(.ball, scene.ballOnPaddlePos(), initial_ball_dir);
                scene.ball_state = .idle;
            }
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

            var r = @import("collision.zig").Rect{
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
                brick.emitter = ExplosionEmitter.init(.{
                    .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                    .sprites = particleExplosionSprites(brick.sprite),
                });
                brick.emitter.pos = brick_pos;
                brick.emitter.emitting = true;
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
        return scene.menu != .none;
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
                    .sprites = particleFlameSprites,
                }),
                .explosion = ExplosionEmitter.init(.{
                    .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                    .sprites = particleExplosionSprites(.ball),
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

    fn render(scene: *GameScene) !void {
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

        // Render particles
        for (scene.entities) |e| {
            e.flame.render(&state.batch);
            e.explosion.render(&state.batch);
        }
        for (scene.bricks) |brick| {
            brick.emitter.render(&state.batch);
        }

        { // Top status bar
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
            text_renderer.render(&state.batch, label, 32, 0, 10);
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
                        sapp.quit();
                    }
                },
                .settings => {
                    // We still "render" the pause menu, but flagging it as hidden to preserve its state
                    if (try renderPauseMenu(&scene.menu)) {
                        sapp.quit();
                    }
                    if (try renderSettingsMenu()) {
                        scene.menu = .pause;
                    }
                },
            }
        }

        const result = state.batch.commit();
        sg.updateBuffer(state.offscreen.bind.vertex_buffers[0], sg.asRange(result.verts));

        const vs_params = shd.VsParams{ .mvp = state.camera.view_proj };

        sg.beginPass(.{
            .action = state.offscreen.pass_action,
            .attachments = state.viewport.attachments,
        });

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

    fn input(scene: *GameScene, ev: [*c]const sapp.Event) !void {
        switch (scene.menu) {
            .none => {
                switch (ev.*.type) {
                    .KEY_DOWN => {
                        // TODO refactor input handling
                        switch (ev.*.key_code) {
                            .LEFT => {
                                scene.inputs.left_down = true;
                            },
                            .RIGHT => {
                                scene.inputs.right_down = true;
                            },
                            .SPACE => {
                                scene.inputs.shoot_down = true;
                            },
                            .ESCAPE => {
                                scene.menu = .pause;
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
                        switch (ev.*.key_code) {
                            .ESCAPE => scene.menu = .none,
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
                            .ESCAPE => scene.menu = .pause,
                            else => {},
                        }
                    },
                    else => {},
                }
            },
        }
    }
};

fn renderPauseMenu(menu: *GameMenu) !bool {
    try ui.beginWindow(.{
        .id = "pause",
        .x = viewport_size[0] / 2,
        .y = viewport_size[1] / 2,
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

fn renderSettingsMenu() !bool {
    try ui.beginWindow(.{
        .id = "settings",
        .x = viewport_size[0] / 2,
        .y = viewport_size[1] / 2,
        .z = 20,
        .pivot = .{ 0.5, 0.5 },
    });
    defer ui.endWindow();

    var sfx_focused = false;
    _ = ui.selectionItem("Volume (sfx)", .{ .focused = &sfx_focused });
    ui.slider(.{ .value = &audio.vol_sfx, .focused = sfx_focused });

    var bg_focused = false;
    _ = ui.selectionItem("Volume (bg)", .{ .focused = &bg_focused });
    ui.slider(.{ .value = &audio.vol_bg, .focused = bg_focused });

    if (ui.selectionItem("Back", .{})) {
        return true;
    }

    return false;
}

// TODO move this
fn renderGui() void {
    //=== UI CODE STARTS HERE
    ig.igSetNextWindowPos(.{ .x = 100, .y = 100 }, ig.ImGuiCond_Once, .{ .x = 0, .y = 0 });
    ig.igSetNextWindowSize(.{ .x = 400, .y = 200 }, ig.ImGuiCond_Once);
    _ = ig.igBegin("Debug", 0, ig.ImGuiWindowFlags_None);
    _ = ig.igText("Delta: %.4g", state.dt);
    _ = ig.igText("Window: %d %d", state.window_size[0], state.window_size[1]);
    _ = ig.igText("Window: %d %d", state.window_size[0], state.window_size[1]);
    _ = ig.igText("Mouse (screen): %.4g %.4g", state.mouse_pos[0], state.mouse_pos[1]);
    _ = ig.igText("Mouse (world): %.4g %.4g", mouse()[0], mouse()[1]);
    _ = ig.igText("Memory usage: %d", state.arena.queryCapacity());

    switch (state.scene) {
        .game => |*s| {
            _ = ig.igText("Death timer: %.4g", s.death_timer);
            _ = ig.igText("Flame timer: %.4g", s.flame_timer);
            _ = ig.igText("Laser timer: %.4g", s.laser_timer);
            if (ig.igButton("Enable flame", .{})) {
                acquirePowerup(s, .flame);
            }
            if (ig.igButton("Enable fork", .{})) {
                acquirePowerup(s, .fork);
            }
        },
        else => {},
    }

    if (ig.igDragFloat2("Camera", &state.camera.pos, 1, -1000, 1000, "%.4g", ig.ImGuiSliderFlags_None)) {
        state.camera.invalidate();
    }

    if (ig.igButton("Play sound", .{})) {
        audio.play(.{ .clip = .bounce });
    }
    if (ig.igButton("Play sound twice", .{})) {
        audio.play(.{ .clip = .bounce });
        audio.play(.{ .clip = .bounce });
    }
    if (ig.igButton("Play sound thrice", .{})) {
        audio.play(.{ .clip = .bounce });
        audio.play(.{ .clip = .bounce });
        audio.play(.{ .clip = .bounce });
    }
    if (ig.igButton("Play music", .{})) {
        audio.play(.{ .clip = .music, .loop = true, .vol = 0.5, .category = .bg });
    }

    if (config.shader_reload) {
        if (ig.igButton("Load shader", .{})) {
            debug.reload = true;
        }
    }

    ig.igEnd();
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn initializeGame() !void {
    state.allocator = if (use_gpa) gpa.allocator() else std.heap.c_allocator;
    state.arena = std.heap.ArenaAllocator.init(state.allocator);
    errdefer state.arena.deinit();

    const allocator = state.arena.allocator();

    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    errdefer sg.shutdown();

    audio.init();
    errdefer audio.deinit();

    stm.setup();

    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });
    ui.init(state.allocator);
    errdefer ui.deinit();

    // setup pass action for default render pass
    state.default.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };

    // setup pass action for imgui
    state.ui.pass_action.colors[0] = .{ .load_action = .LOAD };

    state.camera = Camera.init(.{
        .pos = .{ viewport_size[0] / 2, viewport_size[1] / 2 },
        .viewport_size = viewport_size,
        .window_size = .{
            @intCast(state.window_size[0]),
            @intCast(state.window_size[1]),
        },
    });
    state.viewport = Viewport.init(.{
        .size = viewport_size,
        .camera = &state.camera,
    });

    // set pass action for offscreen render pass
    state.offscreen.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1 },
    };

    state.offscreen.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = max_verts * @sizeOf(Vertex),
    });

    // update the fullscreen-quad texture bindings to contain the viewport image
    state.fsq.bind.fs.images[shd.SLOT_tex] = state.viewport.attachments_desc.colors[0].image;

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

fn computeFSQParams() shd.VsFsqParams {
    const width: f32 = @floatFromInt(state.window_size[0]);
    const height: f32 = @floatFromInt(state.window_size[1]);
    const aspect = width / height;

    const vw: f32 = @floatFromInt(viewport_size[0]);
    const vh: f32 = @floatFromInt(viewport_size[1]);
    const viewport_aspect = vw / vh;

    var model = m.scaling(2, (2 / viewport_aspect) * aspect, 1);
    if (aspect > viewport_aspect) {
        model = m.scaling((2 * viewport_aspect) / aspect, 2, 1);
    }
    return shd.VsFsqParams{ .mvp = model };
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
    const dt: f32 = @floatCast(time - state.time);
    state.dt = dt;
    state.time = time;

    var scene = &state.scene;
    scene.update(dt) catch |err| {
        std.log.err("Unable to update scene: {}", .{err});
        std.process.exit(1);
    };

    if (config.shader_reload and debug.reload) {
        state.bg.reload() catch {};
        debug.reload = false;
    }

    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    scene.render() catch |err| {
        std.log.err("Unable to render scene: {}", .{err});
        std.process.exit(1);
    };

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

    // Reset mouse delta
    state.mouse_delta = .{ 0, 0 };

    // Should we move to another scene?
    if (state.next_scene) |next| {
        scene.deinit();
        state.scene = switch (next) {
            .title => Scene{ .title = .{} },
            .game => Scene{ .game = GameScene.init(state.allocator) catch unreachable }, // TODO
        };
        state.next_scene = null;
    }
}

export fn sokolEvent(ev: [*c]const sapp.Event) void {
    _ = simgui.handleEvent(ev.*);
    ui.handleEvent(ev.*);

    switch (ev.*.type) {
        .RESIZED => {
            const width = ev.*.window_width;
            const height = ev.*.window_height;
            state.window_size = .{ width, height };
            state.camera.window_size = .{ @intCast(@max(0, width)), @intCast(@max(0, height)) };
        },
        .MOUSE_MOVE => {
            state.mouse_pos = .{ ev.*.mouse_x, ev.*.mouse_y };
            state.mouse_delta = m.vadd(state.mouse_delta, .{ ev.*.mouse_dx, ev.*.mouse_dy });
        },
        else => {
            state.scene.input(ev) catch |err| {
                std.log.err("Error while processing input: {}", .{err});
            };
        },
    }
}

export fn sokolCleanup() void {
    state.scene.deinit();
    audio.deinit();
    sg.shutdown();
    ui.deinit();
    state.arena.deinit();
    if (config.shader_reload) {
        debug.watcher.deinit();
    }

    if (use_gpa) {
        _ = gpa.deinit();
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
