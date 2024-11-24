pub const Camera = @import("gfx/Camera.zig");
pub const BatchRenderer = @import("gfx/batch.zig").BatchRenderer;
pub const BatchResult = @import("gfx/batch.zig").BatchResult;
pub const particle = @import("gfx/particle.zig");
pub const texture = @import("gfx/texture.zig");
pub const ttf = @import("gfx/ttf.zig");
pub const ui = @import("gfx/ui.zig");
pub const Framebuffer = @import("gfx/Framebuffer.zig");
pub const TextRenderer = ttf.TextRenderer;

const std = @import("std");

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;

const shd = @import("shader");
const constants = @import("constants.zig");
const m = @import("math");
const spritesheet = @embedFile("sprites.png");
const Texture = texture.Texture;
const font = @import("font");

// TODO move?
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: f32,
    v: f32,
};

const GfxState = struct {
    initialized: bool = false,
    camera: Camera = undefined,
    // TODO rename these shaders so its clearer what they do
    offscreen: struct {
        pip: sg.Pipeline = .{},
    } = .{},
    shadow: struct {
        pip: sg.Pipeline = .{},
    } = .{},
    scene: struct {
        pip: sg.Pipeline = .{},
        bind: sg.Bindings = .{},
    } = .{},
    spritesheet_texture: Texture = undefined,
    font_texture: Texture = undefined,
    window_size: [2]i32 = constants.initial_screen_size,
    batch: BatchRenderer = BatchRenderer.init(),
    quad_vbuf: sg.Buffer = undefined,
};
var state: GfxState = .{};

pub fn init(allocator: std.mem.Allocator) !void {
    std.debug.assert(!state.initialized);

    state.camera = Camera.init(.{
        .pos = .{ constants.viewport_size[0] / 2, constants.viewport_size[1] / 2 },
        .viewport_size = constants.viewport_size,
        .window_size = .{
            @intCast(state.window_size[0]),
            @intCast(state.window_size[1]),
        },
    });

    // set pass action for offscreen render pass
    state.spritesheet_texture = try texture.loadPNG(.{ .data = spritesheet });
    state.font_texture = try texture.loadPNG(.{ .data = font.image });

    { // offscreen shader
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
            .src_factor_alpha = .SRC_ALPHA,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        };

        state.offscreen.pip = sg.makePipeline(pip_desc);
    }

    { // shadow shader
        var pip_desc: sg.PipelineDesc = .{
            .shader = sg.makeShader(shd.shadowShaderDesc(sg.queryBackend())),
            .cull_mode = .BACK,
            .sample_count = constants.offscreen_sample_count,
            .depth = .{
                .pixel_format = .DEPTH,
                .compare = .LESS_EQUAL,
                .write_enabled = false,
            },
            .color_count = 1,
        };
        pip_desc.layout.attrs[shd.ATTR_vs_shadow_position].format = .FLOAT3;
        pip_desc.layout.attrs[shd.ATTR_vs_shadow_color0].format = .UBYTE4N;
        pip_desc.layout.attrs[shd.ATTR_vs_shadow_texcoord0].format = .FLOAT2;
        pip_desc.colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .SRC_ALPHA,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        };

        state.shadow.pip = sg.makePipeline(pip_desc);
    }

    // a vertex buffer to render a fullscreen quad
    state.quad_vbuf = sg.makeBuffer(.{
        .usage = .IMMUTABLE,
        .data = sg.asRange(&[_]f32{
            -0.5, -0.5, 0, 0,
            0.5,  -0.5, 1, 0,
            -0.5, 0.5,  0, 1,
            0.5,  0.5,  1, 1,
        }),
    });

    // shader and pipeline object to render a fullscreen quad
    var scene_pip_desc: sg.PipelineDesc = .{
        .shader = sg.makeShader(shd.sceneShaderDesc(sg.queryBackend())),
        .primitive_type = .TRIANGLE_STRIP,
    };
    scene_pip_desc.layout.attrs[shd.ATTR_vs_scene_pos].format = .FLOAT2;
    scene_pip_desc.layout.attrs[shd.ATTR_vs_scene_in_uv].format = .FLOAT2;
    scene_pip_desc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .src_factor_alpha = .SRC_ALPHA,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
    };
    state.scene.pip = sg.makePipeline(scene_pip_desc);

    // a sampler to sample the offscreen render target as texture
    const smp = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    // resource bindings to render the fullscreen quad (composed from the
    // offscreen render target textures
    state.scene.bind.vertex_buffers[0] = state.quad_vbuf; // TODO
    state.scene.bind.fs.samplers[0] = smp;

    try ui.init(allocator, &state.batch, state.spritesheet_texture, state.font_texture);
    errdefer ui.deinit();

    state.initialized = true;
}

pub fn deinit() void {
    std.debug.assert(state.initialized);
    ui.deinit();
    state.initialized = false;
}

pub fn renderMain(fb: Framebuffer) void {
    const result = state.batch.commit();
    if (result.batches.len == 0) return;

    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    sg.beginPass(.{
        .action = pass_action,
        .attachments = fb.attachments,
    });
    defer sg.endPass();

    var bind = fb.bind;
    sg.updateBuffer(bind.vertex_buffers[0], sg.asRange(result.verts));
    const vs_params = shd.VsParams{ .mvp = state.camera.view_proj };

    // Render background
    for (result.batches) |b| {
        if (b.layer != .background) continue;
        const tex = texture.get(b.tex) catch |err| {
            std.log.warn("Could not render texture {}: {}", .{ b.tex, err });
            continue;
        };
        bind.fs.images[shd.SLOT_tex] = tex.img;
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
        sg.applyBindings(bind);
        sg.draw(@intCast(b.offset), @intCast(b.len), 1);
    }

    // Render shadows
    for (result.batches) |b| {
        if (b.layer != .main) continue;
        const tex = texture.get(b.tex) catch |err| {
            std.log.warn("Could not render texture {}: {}", .{ b.tex, err });
            continue;
        };
        bind.fs.images[shd.SLOT_tex] = tex.img;

        // We render the main layer two times to display a shadow
        // TODO avoid switching pipelines often
        sg.applyPipeline(state.shadow.pip);
        sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
        sg.applyBindings(bind);
        sg.draw(@intCast(b.offset), @intCast(b.len), 1);
    }

    // Render main layer
    for (result.batches) |b| {
        if (b.layer != .main) continue;
        const tex = texture.get(b.tex) catch |err| {
            std.log.warn("Could not render texture {}: {}", .{ b.tex, err });
            continue;
        };
        bind.fs.images[shd.SLOT_tex] = tex.img;
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
        sg.applyBindings(bind);
        sg.draw(@intCast(b.offset), @intCast(b.len), 1);
    }

    // Render particles
    for (result.batches) |b| {
        if (b.layer != .particles) continue;
        const tex = texture.get(b.tex) catch |err| {
            std.log.warn("Could not render texture {}: {}", .{ b.tex, err });
            continue;
        };
        bind.fs.images[shd.SLOT_tex] = tex.img;
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
        sg.applyBindings(bind);
        sg.draw(@intCast(b.offset), @intCast(b.len), 1);
    }
}

pub fn screenToWorld(pos: [2]f32) [2]f32 {
    return state.camera.screenToWorld(pos);
}

pub fn cameraZoom() f32 {
    return state.camera.zoom();
}

pub fn spritesheetTexture() Texture {
    return state.spritesheet_texture;
}

pub fn fontTexture() Texture {
    return state.font_texture;
}

pub fn setTexture(tex: Texture) void {
    state.batch.setTexture(tex);
}

pub fn renderEmitter(emitter: anytype) void {
    emitter.render(&state.batch);
}

pub fn renderText(s: []const u8, x: f32, y: f32, z: f32) void {
    var text_renderer = TextRenderer{};
    text_renderer.render(&state.batch, s, x, y, z);
}

pub inline fn render(opts: BatchRenderer.RenderOptions) void {
    state.batch.render(opts);
}

pub inline fn renderNinePatch(opts: BatchRenderer.RenderNinePatchOptions) void {
    state.batch.renderNinePatch(opts);
}

// TODO return a handler?
pub fn createFramebuffer() Framebuffer {
    return Framebuffer.init(@intCast(state.window_size[0]), @intCast(state.window_size[1]));
}

pub fn beginFrame() void {
    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
    sg.beginPass(.{
        .action = pass_action,
        .swapchain = sglue.swapchain(),
    });
}

pub fn endFrame() void {
    sg.endPass();
    sg.commit();
}

pub fn renderFramebuffer(fb: Framebuffer, transition_progress: f32) void {
    const scene_params = computeSceneParams();
    var fs_scene_params = shd.FsSceneParams{ .value = 1.0 };
    // Update uniform transition progress (shader uses it to display part of the
    // screen while a transition is in progress)
    fs_scene_params.value = transition_progress;

    sg.applyPipeline(state.scene.pip);
    sg.applyUniforms(.VS, shd.SLOT_vs_scene_params, sg.asRange(&scene_params));
    sg.applyUniforms(.FS, shd.SLOT_fs_scene_params, sg.asRange(&fs_scene_params));
    state.scene.bind.vertex_buffers[0] = state.quad_vbuf;
    state.scene.bind.fs.images[shd.SLOT_tex] = fb.attachments_desc.colors[0].image;
    sg.applyBindings(state.scene.bind);
    sg.draw(0, 4, 1);
}

fn computeSceneParams() shd.VsSceneParams {
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
    return shd.VsSceneParams{ .mvp = model };
}

pub fn handleEvent(ev: sapp.Event) void {
    ui.handleEvent(ev);
    switch (ev.type) {
        .RESIZED => {
            const width = ev.window_width;
            const height = ev.window_height;
            state.window_size = .{ width, height };
            state.camera.window_size = .{ @intCast(@max(0, width)), @intCast(@max(0, height)) };
        },
        else => {},
    }
}
