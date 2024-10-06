const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const constants = @import("constants.zig");
const gfx = @import("gfx.zig");
const assert = std.debug.assert;

const sokol = @import("sokol");
const sg = sokol.gfx;
const stm = sokol.time;
const slog = sokol.log;
const sapp = sokol.app;
const sglue = sokol.glue;

const shd = @import("shader");
const font = @import("font");
const fwatch = @import("fwatch");
const m = @import("math");

const input = @import("input.zig");

const level = @import("level.zig");
const Level = level.Level;
const SceneManager = @import("scene.zig").SceneManager;
const audio = @import("audio.zig");
const utils = @import("utils.zig");

const spritesheet = @embedFile("assets/sprites.png");

const levels = .{
    "assets/level1.lvl",
    "assets/level2.lvl",
};

const Texture = gfx.texture.Texture;

pub const offscreen_sample_count = 1;

const pi = std.math.pi;
const num_audio_samples = 32;

pub const std_options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

const state = @import("state.zig");

pub const max_quads = 4096;
pub const max_verts = max_quads * 6;

const use_gpa = !utils.is_web;

const Rect = m.Rect;

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

    gfx.texture.init(state.allocator);
    errdefer gfx.texture.deinit();

    stm.setup();

    gfx.ui.init(state.allocator);
    errdefer gfx.ui.deinit();

    state.camera = gfx.Camera.init(.{
        .pos = .{ constants.viewport_size[0] / 2, constants.viewport_size[1] / 2 },
        .viewport_size = constants.viewport_size,
        .window_size = .{
            @intCast(state.window_size[0]),
            @intCast(state.window_size[1]),
        },
    });
    state.viewport = gfx.Viewport.init(.{
        .size = constants.viewport_size,
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
    // TODO max_verts doubled now
    state.offscreen.bind2.vertex_buffers[0] = sg.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = max_verts * @sizeOf(Vertex),
    });

    // update the fullscreen-quad texture bindings to contain the viewport image
    // TODO do elsewhere?
    state.fsq.bind.fs.images[shd.SLOT_tex] = state.viewport.attachments_desc.colors[0].image;

    state.spritesheet_texture = try gfx.texture.loadPNG(.{ .data = spritesheet });
    state.font_texture = try gfx.texture.loadPNG(.{ .data = font.image });

    state.offscreen.bind.fs.samplers[shd.SLOT_smp] = sg.makeSampler(.{});
    state.offscreen.bind2.fs.samplers[shd.SLOT_smp] = sg.makeSampler(.{});

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
    state.quad_vbuf = sg.makeBuffer(.{
        .usage = .IMMUTABLE,
        .data = sg.asRange(&[_]f32{ -0.5, -0.5, 0, 0, 0.5, -0.5, 1, 0, -0.5, 0.5, 0, 1, 0.5, 0.5, 1, 1 }),
    });

    // shader and pipeline object to render a fullscreen quad
    var fsq_pip_desc: sg.PipelineDesc = .{
        .shader = sg.makeShader(shd.fsqShaderDesc(sg.queryBackend())),
        .primitive_type = .TRIANGLE_STRIP,
    };
    fsq_pip_desc.layout.attrs[shd.ATTR_vs_fsq_pos].format = .FLOAT2;
    fsq_pip_desc.layout.attrs[shd.ATTR_vs_fsq_in_uv].format = .FLOAT2;
    state.fsq.pip = sg.makePipeline(fsq_pip_desc);
    // setup pass action for fsq render pass
    state.fsq.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };

    // a sampler to sample the offscreen render target as texture
    const smp = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    // resource bindings to render the fullscreen quad (composed from the
    // offscreen render target textures
    state.fsq.bind.vertex_buffers[0] = state.quad_vbuf; // TODO
    state.fsq.bind.fs.samplers[0] = smp;

    // background shader
    if (config.shader_reload) {
        const path = try utils.getExecutablePath(allocator);
        const dir = std.fs.path.dirname(path).?;
        const shader_path = try std.fs.path.join(allocator, &.{ dir, "libshd.so" });
        state.bg = try gfx.Pipeline.load(shader_path, "bgShaderDesc");

        debug.watcher = try fwatch.FileWatcher(void).init(allocator, onFileEvent);
        errdefer debug.watcher.deinit();

        try debug.watcher.start();
        try debug.watcher.add(shader_path, {});
    } else {
        state.bg = try gfx.Pipeline.init();
    }
    state.bg.bind.vertex_buffers[0] = state.quad_vbuf;

    // load all levels
    state.levels = std.ArrayList(Level).init(allocator);
    errdefer state.levels.deinit();
    inline for (levels) |path| {
        const data = @embedFile(path);
        var fbs = std.io.fixedBufferStream(data);
        const lvl = try level.parseLevel(allocator, fbs.reader());
        errdefer lvl.deinit(allocator);
        try state.levels.append(lvl);
    }

    state.scene_mgr = SceneManager.init(allocator, state.levels.items);
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

    const vw: f32 = @floatFromInt(constants.viewport_size[0]);
    const vh: f32 = @floatFromInt(constants.viewport_size[1]);
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

    state.scene_mgr.frame(dt) catch |err| {
        std.log.err("Unable to update scene: {}", .{err});
        std.process.exit(1);
    };

    if (config.shader_reload and debug.reload) {
        state.bg.reload() catch {};
        debug.reload = false;
    }

    const fsq_params = computeFSQParams();
    var fs_fsq_params = shd.FsFsqParams{ .value = 1.0 };
    {
        sg.beginPass(.{ .action = state.fsq.pass_action, .swapchain = sglue.swapchain() });
        defer sg.endPass();

        { // Current scene
            state.fsq.bind.fs.images[shd.SLOT_tex] = state.viewport.attachments_desc.colors[0].image;
            sg.applyPipeline(state.fsq.pip);
            state.fsq.bind.vertex_buffers[0] = state.quad_vbuf;
            sg.applyBindings(state.fsq.bind);
            sg.applyUniforms(.VS, shd.SLOT_vs_fsq_params, sg.asRange(&fsq_params));
            sg.applyUniforms(.FS, shd.SLOT_fs_fsq_params, sg.asRange(&fs_fsq_params));
            sg.draw(0, 4, 1);
        }

        // Next scene (in case of transition)
        if (state.scene_mgr.next != null) {

            // Update uniform transition progress (shader uses it to display part of the
            // screen while a transition is in progress)
            fs_fsq_params.value = state.scene_mgr.transition_progress;

            state.fsq.bind.fs.images[shd.SLOT_tex] = state.viewport.attachments_desc2.colors[0].image;
            sg.applyPipeline(state.fsq.pip);

            sg.applyBindings(state.fsq.bind);
            sg.applyUniforms(.VS, shd.SLOT_vs_fsq_params, sg.asRange(&fsq_params));
            sg.applyUniforms(.FS, shd.SLOT_fs_fsq_params, sg.asRange(&fs_fsq_params));
            sg.draw(0, 4, 1);
        }
    }
    sg.commit();

    // Reset mouse delta
    state.mouse_delta = .{ 0, 0 };
}

export fn sokolEvent(ev: [*c]const sapp.Event) void {
    gfx.ui.handleEvent(ev.*);

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

            const world_mouse_pos = input.mouse();
            gfx.ui.handleMouseMove(world_mouse_pos[0], world_mouse_pos[1]);
        },
        else => {
            state.scene_mgr.handleInput(ev) catch |err| {
                std.log.err("Error while processing input: {}", .{err});
            };
        },
    }
}

export fn sokolCleanup() void {
    state.scene_mgr.deinit();
    gfx.texture.deinit();
    audio.deinit();
    sg.shutdown();
    gfx.ui.deinit();
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
        .width = state.window_size[0],
        .height = state.window_size[1],
        .icon = .{ .sokol_default = true },
        .window_title = "Game",
        .logger = .{ .func = slog.func },
    });
}
