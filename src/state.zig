const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const stm = sokol.time;
const sglue = sokol.glue;
const sapp = sokol.app;

const m = @import("math");
const utils = @import("utils.zig");
const shd = @import("shader");
const config = @import("config");
const constants = @import("constants.zig");

const gfx = @import("gfx.zig");
const Viewport = gfx.Viewport;
const Camera = gfx.Camera;
const BatchRenderer = gfx.BatchRenderer;
const SceneManager = @import("scene.zig").SceneManager;
const Pipeline = gfx.Pipeline;
const Texture = gfx.texture.Texture;

const font = @import("font");

const level = @import("level.zig");
const Level = level.Level;
const level_files = .{
    "assets/level1.lvl",
    "assets/level2.lvl",
};

const spritesheet = @embedFile("assets/sprites.png");

// TODO move?
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: f32,
    v: f32,
};

pub var arena: std.heap.ArenaAllocator = undefined;

pub var viewport: Viewport = undefined;
pub var camera: Camera = undefined;
pub var offscreen: struct {
    pip: sg.Pipeline = .{},
    bind: sg.Bindings = .{},
    bind2: sg.Bindings = .{},
    pass_action: sg.PassAction = .{},
} = .{};
pub var fsq: struct {
    pip: sg.Pipeline = .{},
    bind: sg.Bindings = .{},
    pass_action: sg.PassAction = .{},
} = .{};
pub var bg: Pipeline = undefined;
pub var spritesheet_texture: Texture = undefined;
pub var font_texture: Texture = undefined;
pub var window_size: [2]i32 = constants.initial_screen_size;
pub var batch: BatchRenderer = BatchRenderer.init();
pub var quad_vbuf: sg.Buffer = undefined;

/// Mouse position in unscaled pixels
pub var mouse_pos: [2]f32 = .{ 0, 0 };
pub var mouse_delta: [2]f32 = .{ 0, 0 };

pub var time: f64 = 0;
pub var dt: f32 = 0;

pub var levels: std.ArrayList(Level) = undefined;
pub var scene_mgr: SceneManager = undefined;

// NOCOMMIT this mixes render-specific stuff with game stuff (scene manager etc).
// NOCOMMIT move some into gfx subsystem?
pub fn init(allocator: std.mem.Allocator) !void {
    arena = std.heap.ArenaAllocator.init(allocator);

    camera = gfx.Camera.init(.{
        .pos = .{ constants.viewport_size[0] / 2, constants.viewport_size[1] / 2 },
        .viewport_size = constants.viewport_size,
        .window_size = .{
            @intCast(window_size[0]),
            @intCast(window_size[1]),
        },
    });

    viewport = gfx.Viewport.init(.{
        .size = constants.viewport_size,
        .camera = &camera,
    });

    // set pass action for offscreen render pass
    offscreen.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1 },
    };
    offscreen.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = constants.max_verts * @sizeOf(Vertex),
    });
    // TODO max_verts doubled now
    offscreen.bind2.vertex_buffers[0] = sg.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = constants.max_verts * @sizeOf(Vertex),
    });

    // update the fullscreen-quad texture bindings to contain the viewport image
    // TODO do elsewhere?
    fsq.bind.fs.images[shd.SLOT_tex] = viewport.attachments_desc.colors[0].image;

    spritesheet_texture = try gfx.texture.loadPNG(.{ .data = spritesheet });
    font_texture = try gfx.texture.loadPNG(.{ .data = font.image });

    offscreen.bind.fs.samplers[shd.SLOT_smp] = sg.makeSampler(.{});
    offscreen.bind2.fs.samplers[shd.SLOT_smp] = sg.makeSampler(.{});

    // create a shader and pipeline object
    var pip_desc: sg.PipelineDesc = .{
        .shader = sg.makeShader(shd.mainShaderDesc(sg.queryBackend())),
        .cull_mode = .BACK,
        .sample_count = constants.offscreen_sample_count,
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

    offscreen.pip = sg.makePipeline(pip_desc);

    // a vertex buffer to render a fullscreen quad
    quad_vbuf = sg.makeBuffer(.{
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
    fsq.pip = sg.makePipeline(fsq_pip_desc);
    // setup pass action for fsq render pass
    fsq.pass_action.colors[0] = .{
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
    fsq.bind.vertex_buffers[0] = quad_vbuf; // TODO
    fsq.bind.fs.samplers[0] = smp;

    // background shader
    bg = try gfx.Pipeline.init();
    bg.bind.vertex_buffers[0] = quad_vbuf;

    // load all levels
    levels = std.ArrayList(Level).init(arena.allocator());
    errdefer levels.deinit();
    inline for (level_files) |path| {
        const data = @embedFile(path);
        var fbs = std.io.fixedBufferStream(data);
        const lvl = try level.parseLevel(arena.allocator(), fbs.reader());
        errdefer lvl.deinit(arena.allocator());
        try levels.append(lvl);
    }

    scene_mgr = SceneManager.init(allocator, levels.items);
}

pub fn deinit() void {
    scene_mgr.deinit();
    arena.deinit();
}

pub fn beginOffscreenPass() void {
    sg.beginPass(.{
        .action = offscreen.pass_action,
        .attachments = currentAttachments(),
    });
}

fn currentAttachments() sg.Attachments {
    if (scene_mgr.rendering_next) {
        return viewport.attachments2;
    } else {
        return viewport.attachments;
    }
}

pub fn renderBatch() !void {
    const result = batch.commit();
    sg.updateBuffer(vertexBuffer(), sg.asRange(result.verts));
    var bind = currentBind();
    for (result.batches) |b| {
        const tex = try gfx.texture.get(b.tex);
        bind.fs.images[shd.SLOT_tex] = tex.img;
        sg.applyBindings(bind);
        sg.draw(@intCast(b.offset), @intCast(b.len), 1);
    }
}

fn vertexBuffer() sg.Buffer {
    // TODO currentBind()
    if (scene_mgr.rendering_next) {
        return offscreen.bind2.vertex_buffers[0];
    } else {
        return offscreen.bind.vertex_buffers[0];
    }
}

fn currentBind() sg.Bindings {
    if (scene_mgr.rendering_next) {
        return offscreen.bind2;
    } else {
        return offscreen.bind;
    }
}

pub fn frame() void {
    const ticks = stm.now();
    const now = stm.sec(ticks);
    const new_dt: f32 = @floatCast(now - time);
    dt = new_dt;
    time = now;

    scene_mgr.frame(dt) catch |err| {
        std.log.err("Unable to update scene: {}", .{err});
        std.process.exit(1);
    };

    const fsq_params = computeFSQParams();
    var fs_fsq_params = shd.FsFsqParams{ .value = 1.0 };
    {
        sg.beginPass(.{ .action = fsq.pass_action, .swapchain = sglue.swapchain() });
        defer sg.endPass();

        { // Current scene
            fsq.bind.fs.images[shd.SLOT_tex] = viewport.attachments_desc.colors[0].image;
            sg.applyPipeline(fsq.pip);
            fsq.bind.vertex_buffers[0] = quad_vbuf;
            sg.applyBindings(fsq.bind);
            sg.applyUniforms(.VS, shd.SLOT_vs_fsq_params, sg.asRange(&fsq_params));
            sg.applyUniforms(.FS, shd.SLOT_fs_fsq_params, sg.asRange(&fs_fsq_params));
            sg.draw(0, 4, 1);
        }

        // Next scene (in case of transition)
        if (scene_mgr.next != null) {

            // Update uniform transition progress (shader uses it to display part of the
            // screen while a transition is in progress)
            fs_fsq_params.value = scene_mgr.transition_progress;

            fsq.bind.fs.images[shd.SLOT_tex] = viewport.attachments_desc2.colors[0].image;
            sg.applyPipeline(fsq.pip);

            sg.applyBindings(fsq.bind);
            sg.applyUniforms(.VS, shd.SLOT_vs_fsq_params, sg.asRange(&fsq_params));
            sg.applyUniforms(.FS, shd.SLOT_fs_fsq_params, sg.asRange(&fs_fsq_params));
            sg.draw(0, 4, 1);
        }
    }
    sg.commit();

    // Reset mouse delta
    mouse_delta = .{ 0, 0 };
}

// NOCOMMIT
fn computeFSQParams() shd.VsFsqParams {
    const width: f32 = @floatFromInt(window_size[0]);
    const height: f32 = @floatFromInt(window_size[1]);
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

// NOCOMMIT make sapp-agnostic
pub fn handleEvent(ev: sapp.Event) void {
    switch (ev.type) {
        .RESIZED => {
            const width = ev.window_width;
            const height = ev.window_height;
            window_size = .{ width, height };
            camera.window_size = .{ @intCast(@max(0, width)), @intCast(@max(0, height)) };
        },
        .MOUSE_MOVE => {
            mouse_pos = .{ ev.mouse_x, ev.mouse_y };
            mouse_delta = m.vadd(mouse_delta, .{ ev.mouse_dx, ev.mouse_dy });
        },
        else => {
            scene_mgr.handleInput(ev) catch |err| {
                std.log.err("Error while processing input: {}", .{err});
            };
        },
    }
}
