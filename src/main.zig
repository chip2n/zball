const std = @import("std");
const assert = std.debug.assert;

const sokol = @import("sokol");
const sg = sokol.gfx;
const slog = sokol.log;
const sapp = sokol.app;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const shd = @import("shaders/main.glsl.zig");

const ig = @import("cimgui");
const zm = @import("zmath");

const img = @embedFile("spritesheet.png");
const Texture = @import("Texture.zig");

const offscreen_sample_count = 1;

const max_quads = 256;
const max_verts = max_quads * 6; // TODO use index buffers

const initial_screen_size = .{ 640, 480 };
const viewport_size: [2]i32 = .{ 160, 120 };
const paddle_w: f32 = 16;
const paddle_h: f32 = 8;
const paddle_speed: f32 = 80;
const ball_w: f32 = 4;
const ball_h: f32 = 4;
const ball_speed: f32 = 20;
const initial_paddle_pos: [2]f32 = .{
    viewport_size[0] / 2,
    viewport_size[1] - 10,
};
const initial_ball_pos: [2]f32 = .{
    initial_paddle_pos[0],
    initial_paddle_pos[1] - paddle_h / 2 - ball_h / 2,
};
const initial_ball_dir: [2]f32 = .{ 0, -1 };
const num_bricks = 10;
const num_rows = 5;
const brick_w = 16;
const brick_h = 8;

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

const Brick = struct {
    pos: [2]f32,
};

const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: f32,
    v: f32,
};

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
    const ui = struct {
        var pass_action: sg.PassAction = .{};
    };
    const default = struct {
        var pass_action: sg.PassAction = .{};
    };

    var texture: Texture = undefined;
    var camera: [2]f32 = .{ viewport_size[0] / 2, viewport_size[1] / 2 };

    var window_size: [2]i32 = initial_screen_size;

    var paddle_pos: [2]f32 = initial_paddle_pos;
    var ball_pos: [2]f32 = initial_ball_pos;
    var ball_dir: [2]f32 = initial_ball_dir;

    const input = struct {
        var left_down: bool = false;
        var right_down: bool = false;
    };

    var allocator = std.heap.c_allocator;
    var arena: std.heap.ArenaAllocator = undefined;

    var bricks: std.ArrayList(Brick) = undefined;
};

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
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

    state.offscreen.bind.fs.images[shd.SLOT_tex] = sg.makeImage(state.texture.desc);
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

    // initialize game state
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    state.arena = std.heap.ArenaAllocator.init(state.allocator);
    errdefer state.arena.deinit();
    state.bricks = std.ArrayList(Brick).initCapacity(state.arena.allocator(), num_rows * num_bricks) catch unreachable;
    for (0..num_rows) |y| {
        for (0..num_bricks) |x| {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            state.bricks.append(.{ .pos = .{ fx * brick_w, fy * brick_h } }) catch unreachable;
        }
    }
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
    buf[0] = .{ .x = x,      .y = y,          .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv1[1] };
    buf[1] = .{ .x = x,      .y = y + h,      .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv2[1] };
    buf[2] = .{ .x = x + w,  .y = y + h,      .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv2[1] };
    buf[3] = .{ .x = x,      .y = y,          .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv1[1] };
    buf[4] = .{ .x = x + w,  .y = y + h,      .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv2[1] };
    buf[5] = .{ .x = x + w,  .y = y,          .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv1[1] };
    // zig fmt: on
}

fn isRectsOverlapping(r1: Rect, r2: Rect) bool {
    if (r1.x > r2.x + r2.w) return false;
    if (r1.x + r1.w < r2.x) return false;
    if (r1.y > r2.y + r2.h) return false;
    if (r1.y + r1.h < r2.y) return false;
    return true;
}

export fn frame() void {
    const dt: f32 = @floatCast(sapp.frameDuration());

    { // Move paddle
        var paddle_dx: f32 = 0;
        if (state.input.left_down) {
            paddle_dx -= 1;
        }
        if (state.input.right_down) {
            paddle_dx += 1;
        }
        state.paddle_pos[0] += paddle_dx * paddle_speed * dt;
    }

    { // Move ball
        state.ball_pos[0] += state.ball_dir[0] * ball_speed * dt;
        state.ball_pos[1] += state.ball_dir[1] * ball_speed * dt;
    }

    // Has the ball hit any bricks?
    const ball_rect = Rect{ .x = state.ball_pos[0], .y = state.ball_pos[1], .w = ball_w, .h = ball_h };
    for (state.bricks.items, 0..) |brick, i| {
        const brick_rect = Rect{ .x = brick.pos[0], .y = brick.pos[1], .w = brick_w, .h = brick_h };
        if (isRectsOverlapping(ball_rect, brick_rect)) {
            _ = state.bricks.swapRemove(i);
        }
    }

    var verts: [max_verts]Vertex = undefined;
    var vert_index: usize = 0;
    for (state.bricks.items) |brick| {
        const x = brick.pos[0];
        const y = brick.pos[1];
        quad(.{
            .buf = verts[vert_index..],
            .src = .{ .x = y * brick_w, .y = 0, .w = brick_w, .h = brick_h },
            .dst = .{ .x = x, .y = y, .w = brick_w, .h = brick_h },
            .tw = @floatFromInt(state.texture.desc.width),
            .th = @floatFromInt(state.texture.desc.height),
        });
        vert_index += 6;
    }

    // ball
    quad(.{
        .buf = verts[vert_index..],
        .src = .{ .x = 0, .y = 0, .w = ball_w, .h = ball_h },
        .dst = .{
            .x = state.ball_pos[0] - ball_w / 2,
            .y = state.ball_pos[1] - ball_h / 2,
            .w = ball_w,
            .h = ball_h,
        },
        .tw = @floatFromInt(state.texture.desc.width),
        .th = @floatFromInt(state.texture.desc.height),
    });
    vert_index += 6;

    // paddle
    quad(.{
        .buf = verts[vert_index..],
        .src = .{ .x = 0, .y = 0, .w = brick_w, .h = brick_h },
        .dst = .{
            .x = state.paddle_pos[0] - paddle_w / 2,
            .y = state.paddle_pos[1] - paddle_h / 2,
            .w = paddle_w,
            .h = paddle_h,
        },
        .tw = @floatFromInt(state.texture.desc.width),
        .th = @floatFromInt(state.texture.desc.height),
    });
    vert_index += 6;

    sg.updateBuffer(state.offscreen.bind.vertex_buffers[0], sg.asRange(&verts));

    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    //=== UI CODE STARTS HERE
    ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, ig.ImGuiCond_Once, .{ .x = 0, .y = 0 });
    ig.igSetNextWindowSize(.{ .x = 400, .y = 100 }, ig.ImGuiCond_Once);
    _ = ig.igBegin("Hello Dear ImGui!", 0, ig.ImGuiWindowFlags_None);
    _ = ig.igText("Window: %d %d", state.window_size[0], state.window_size[1]);
    _ = ig.igDragFloat2("Camera", &state.camera, 1, -1000, 1000, "%.4g", ig.ImGuiSliderFlags_None);
    ig.igEnd();
    //=== UI CODE ENDS HERE

    const vs_params = computeVsParams();
    const fsq_params = computeFSQParams();

    sg.beginPass(.{ .action = state.offscreen.pass_action, .attachments = state.offscreen.attachments });
    sg.applyPipeline(state.offscreen.pip);
    sg.applyBindings(state.offscreen.bind);
    sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
    sg.draw(0, verts.len, 1);
    sg.endPass();

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

export fn event(ev: [*c]const sapp.Event) void {
    switch (ev.*.type) {
        .KEY_DOWN => {
            switch (ev.*.key_code) {
                .LEFT => {
                    state.input.left_down = true;
                },
                .RIGHT => {
                    state.input.right_down = true;
                },
                else => {},
            }
        },
        .KEY_UP => {
            switch (ev.*.key_code) {
                .LEFT => {
                    state.input.left_down = false;
                },
                .RIGHT => {
                    state.input.right_down = false;
                },
                else => {},
            }
        },
        .RESIZED => {
            const width = ev.*.window_width;
            const height = ev.*.window_height;
            state.window_size = .{ width, height };
            createOffscreenAttachments(viewport_size[0], viewport_size[1]);
        },
        else => {},
    }

    // forward input events to sokol-imgui
    _ = simgui.handleEvent(ev.*);
}

export fn cleanup() void {
    sg.shutdown();
    state.arena.deinit();
}

pub fn main() !void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = initial_screen_size[0],
        .height = initial_screen_size[1],
        .icon = .{ .sokol_default = true },
        .window_title = "Game",
        .logger = .{ .func = slog.func },
    });
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
    state.fsq.bind.fs.images[0] = state.offscreen.attachments_desc.colors[0].image;
}
