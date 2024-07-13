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

const img = @embedFile("spritesheet.png");
const titlescreen = @embedFile("titlescreen.png");
const audio_bounce = @import("audio.zig").embed("assets/bounce.wav");

const Texture = @import("Texture.zig");

const offscreen_sample_count = 1;

const num_audio_samples = 32;

// TODO reuse in batch
const max_quads = 256;
const max_verts = max_quads * 6; // TODO use index buffers

const initial_screen_size = .{ 640, 480 };
const viewport_size: [2]i32 = .{ 160, 120 };
const paddle_w: f32 = 16;
const paddle_h: f32 = 8;
const paddle_speed: f32 = 80;
const ball_w: f32 = 4;
const ball_h: f32 = 4;
const ball_speed: f32 = 70;
const initial_paddle_pos: [2]f32 = .{
    viewport_size[0] / 2,
    viewport_size[1] - 10,
};

const initial_ball_pos: [2]f32 = .{
    initial_paddle_pos[0],
    initial_paddle_pos[1] - paddle_h / 2 - ball_h / 2,
};
const initial_ball_dir: [2]f32 = .{ 0.3, -1 };
const num_bricks = 10;
const num_rows = 5;
pub const brick_w = 16;
pub const brick_h = 8;
const brick_start_y = 8;

const Rect = m.Rect;

const Brick = struct {
    pos: [2]f32,
    sprite: usize,
    destroyed: bool = false,
};

pub const sprites = [_]Rect{
    .{ .x = 0 * brick_w, .y = 0, .w = brick_w, .h = brick_h },
    .{ .x = 1 * brick_w, .y = 0, .w = brick_w, .h = brick_h },
    .{ .x = 2 * brick_w, .y = 0, .w = brick_w, .h = brick_h },
    .{ .x = 3 * brick_w, .y = 0, .w = brick_w, .h = brick_h },
    .{ .x = 4 * brick_w, .y = 0, .w = brick_w, .h = brick_h },
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

    var texture: Texture = undefined;
    var titlescreen_texture: Texture = undefined;
    var font_texture: Texture = undefined;
    var camera: [2]f32 = .{ viewport_size[0] / 2, viewport_size[1] / 2 };
    var textures: std.AutoHashMap(usize, sg.Image) = undefined;

    var window_size: [2]i32 = initial_screen_size;

    var allocator = std.heap.c_allocator;
    var arena: std.heap.ArenaAllocator = undefined;

    var scene: Scene = .{ .title = .{} };

    var batch = BatchRenderer.init();
    var particles = ParticleSystem{};

    // const audio = struct {
    //     var even_odd: u32 = 0;
    //     var sample_pos: usize = 0;
    //     var samples: [num_audio_samples]f32 = undefined;
    // };
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

    fn render(scene: Scene) void {
        switch (scene) {
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

    fn render(scene: TitleScene) void {
        state.batch.setTexture(state.titlescreen_texture);

        state.batch.render(.{
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

const GameScene = struct {
    bricks: [num_rows * num_bricks]Brick = undefined,

    time: f32 = 0,
    lives: u8 = 3,
    score: u32 = 0,

    paddle_pos: [2]f32 = initial_paddle_pos,
    ball_pos: [2]f32 = initial_ball_pos,
    ball_dir: [2]f32 = initial_ball_dir,
    ball_state: BallState = .idle,

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
        m.normalize(&scene.ball_dir);

        // initialize bricks
        for (0..num_rows) |y| {
            for (0..num_bricks) |x| {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                scene.bricks[y * num_bricks + x] = .{
                    .pos = .{ fx * brick_w, brick_start_y + fy * brick_h },
                    .sprite = y,
                };
            }
        }

        return scene;
    }

    fn update(scene: *GameScene, dt: f32) void {
        scene.time += dt;

        // Reset data from previous frame
        scene.collision_count = 0;

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

        const old_ball_pos = scene.ball_pos;
        switch (scene.ball_state) {
            .idle => {
                scene.updateIdleBall();
            },
            .alive => {
                scene.ball_pos[0] += scene.ball_dir[0] * ball_speed * dt;
                scene.ball_pos[1] += scene.ball_dir[1] * ball_speed * dt;
            },
        }
        const new_ball_pos = scene.ball_pos;

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
                    const brick_dist = m.magnitude(m.vsub(brick_pos, scene.ball_pos));
                    if (brick_dist < coll_dist) {
                        normal = c_normal;
                        coll_dist = brick_dist;
                    }
                    std.log.warn("COLLIDED", .{});
                    brick.destroyed = true;
                    state.particles.emit(brick_pos, 10, brick.sprite);
                    state.audio.play(.{ .clip = .bounce, .loop = false });
                    scene.score += 100;

                    scene.collisions[scene.collision_count] = .{ .brick = i, .loc = out, .normal = c_normal };
                    scene.collision_count += 1;
                }
                collided = collided or c;
            }
            if (collided) {
                scene.ball_pos = out;
                scene.ball_dir = m.reflect(scene.ball_dir, normal);
            }
        }

        const vw: f32 = @floatFromInt(viewport_size[0]);
        const vh: f32 = @floatFromInt(viewport_size[1]);

        { // Has the ball hit the paddle?
            var r = @import("collision.zig").Rect{
                .min = .{ scene.paddle_pos[0] - paddle_w / 2, scene.paddle_pos[1] - paddle_h / 2 },
                .max = .{ scene.paddle_pos[0] + paddle_w / 2, scene.paddle_pos[1] + paddle_h / 2 },
            };
            r.grow(.{ ball_w / 2, ball_h / 2 });
            // TODO not sure we're using the right ball positions
            const c = @import("collision.zig").box_intersection(old_ball_pos, new_ball_pos, r, &out, &normal);
            if (c) {
                std.log.warn("PADDLE", .{});
                scene.ball_pos = out;
                scene.ball_dir = paddle_reflect(scene.paddle_pos[0], paddle_w, scene.ball_pos, scene.ball_dir);
            }
        }

        { // Has the ball hit the ceiling?
            const c = @import("collision.zig").line_intersection(
                old_ball_pos,
                scene.ball_pos,
                .{ 0, brick_start_y },
                .{ vw - ball_w / 2, brick_start_y },
                &out,
            );
            if (c) {
                std.log.warn("CEILING", .{});
                normal = .{ 0, 1 };
                scene.ball_pos = out;
                scene.ball_dir = m.reflect(scene.ball_dir, normal);
            }
        }

        { // Has the ball hit the right wall?
            const c = @import("collision.zig").line_intersection(
                old_ball_pos,
                scene.ball_pos,
                .{ vw - ball_w / 2, 0 },
                .{ vw - ball_w / 2, vh },
                &out,
            );
            if (c) {
                std.log.warn("WALL", .{});
                normal = .{ -1, 0 };
                scene.ball_pos = out;
                scene.ball_dir = m.reflect(scene.ball_dir, normal);
            }
        }

        { // Has the ball hit the left wall?
            const c = @import("collision.zig").line_intersection(
                old_ball_pos,
                scene.ball_pos,
                .{ ball_w / 2, 0 },
                .{ ball_w / 2, vh },
                &out,
            );
            if (c) {
                std.log.warn("WALL", .{});
                normal = .{ -1, 0 };
                scene.ball_pos = out;
                scene.ball_dir = m.reflect(scene.ball_dir, normal);
            }
        }

        { // Has the ball hit the floor?
            const c = @import("collision.zig").line_intersection(
                old_ball_pos,
                scene.ball_pos,
                .{ 0, vh - ball_h / 2 },
                .{ vw, vh - ball_h / 2 },
                &out,
            );
            if (c) {
                std.log.warn("DEAD!", .{});
                if (scene.lives == 0) {
                    std.log.warn("GAME OVER", .{});
                    state.scene = Scene{ .title = .{} };
                } else {
                    scene.lives -= 1;
                    scene.updateIdleBall();
                    scene.ball_dir = initial_ball_dir;
                    m.normalize(&scene.ball_dir);
                    scene.ball_state = .idle;
                }
            }
        }

        state.particles.update(dt);
    }

    // The angle depends on how far the ball is from the center of the paddle
    fn paddle_reflect(paddle_pos: f32, paddle_width: f32, ball_pos: [2]f32, ball_dir: [2]f32) [2]f32 {
        const p = (paddle_pos - ball_pos[0]) / paddle_width;
        var new_dir = [_]f32{ -p, -ball_dir[1] };
        m.normalize(&new_dir);
        return new_dir;
    }

    fn updateIdleBall(scene: *GameScene) void {
        scene.ball_pos[0] = scene.paddle_pos[0];
        scene.ball_pos[1] = scene.paddle_pos[1] - 5 * ball_h / 3;
    }

    fn render(scene: GameScene) void {
        state.batch.setTexture(state.texture);

        // Render all bricks
        for (scene.bricks) |brick| {
            if (brick.destroyed) continue;
            const x = brick.pos[0];
            const y = brick.pos[1];
            state.batch.render(.{
                .src = sprites[brick.sprite],
                .dst = .{ .x = x, .y = y, .w = brick_w, .h = brick_h },
            });
        }

        // Render ball
        state.batch.render(.{
            .src = .{ .x = 0, .y = 0, .w = ball_w, .h = ball_h },
            .dst = .{
                .x = scene.ball_pos[0] - ball_w / 2,
                .y = scene.ball_pos[1] - ball_h / 2,
                .w = ball_w,
                .h = ball_h,
            },
        });

        // Render paddle
        state.batch.render(.{
            .src = .{ .x = 0, .y = 0, .w = brick_w, .h = brick_h },
            .dst = .{
                .x = scene.paddle_pos[0] - paddle_w / 2,
                .y = scene.paddle_pos[1] - paddle_h / 2,
                .w = paddle_w,
                .h = paddle_h,
            },
        });

        // Render particles
        state.particles.render(&state.batch);

        // Top status bar
        for (0..scene.lives) |i| {
            const fi: f32 = @floatFromInt(i);
            state.batch.render(.{
                .src = .{ .x = 0, .y = 0, .w = ball_w, .h = ball_h },
                .dst = .{ .x = 2 + fi * (ball_w + 2), .y = 2, .w = ball_w, .h = ball_h },
            });
        }

        { // Text
            state.batch.setTexture(state.font_texture); // TODO have to always remember this when rendering text...
            var text_renderer = TextRenderer{};
            var buf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "score {:0>4}", .{scene.score}) catch unreachable;
            text_renderer.render(&state.batch, label, 32, 0);
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

    if (ig.igButton("Play sound", .{})) {
        state.audio.play(.{ .clip = .bounce, .loop = false });
    }
    if (ig.igButton("Play sound twice", .{})) {
        state.audio.play(.{ .clip = .bounce, .loop = false });
        state.audio.play(.{ .clip = .bounce, .loop = false });
    }
    if (ig.igButton("Play sound thrice", .{})) {
        state.audio.play(.{ .clip = .bounce, .loop = false });
        state.audio.play(.{ .clip = .bounce, .loop = false });
        state.audio.play(.{ .clip = .bounce, .loop = false });
    }
    if (ig.igButton("Play music", .{})) {
        state.audio.play(.{ .clip = .music, .loop = true, .volume = 0.4 });
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

    state.texture = Texture.init(img);
    state.titlescreen_texture = Texture.init(titlescreen);
    state.font_texture = Texture.init(font.image);

    state.textures = std.AutoHashMap(usize, sg.Image).init(allocator);
    try state.textures.put(state.texture.id, sg.makeImage(state.texture.desc));
    try state.textures.put(state.titlescreen_texture.id, sg.makeImage(state.titlescreen_texture.desc));
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
    // forward input events to sokol-imgui
    _ = simgui.handleEvent(ev.*);

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
