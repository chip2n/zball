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
const zball = @import("zball.zig");
const sokol = @import("sokol");
const shd = @import("shader");
const m = @import("math");
const font = @import("font");

const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;

const spritesheet = @embedFile("sprites.png");
const Texture = texture.Texture;

// TODO move?
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: f32,
    v: f32,
};

const Light = struct {
    pos: [2]f32 = .{ 0, 0 },
    color: u32,
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
    window_size: [2]i32 = undefined,
    batch: BatchRenderer = undefined,
    quad_vbuf: sg.Buffer = undefined,
    lights: std.ArrayList(Light) = undefined,
};
var state: GfxState = .{};

pub fn init(allocator: std.mem.Allocator) !void {
    std.debug.assert(!state.initialized);

    state.window_size = .{ sapp.width(), sapp.height() };

    state.batch = try BatchRenderer.init(allocator);
    errdefer state.batch.deinit();

    state.camera = Camera.init(.{
        .win_size = .{
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
            .sample_count = zball.offscreen_sample_count,
            .depth = .{
                .pixel_format = .DEPTH,
                .compare = .LESS_EQUAL,
                .write_enabled = false,
            },
            .color_count = 1,
        };
        pip_desc.layout.attrs[shd.ATTR_main_position].format = .FLOAT3;
        pip_desc.layout.attrs[shd.ATTR_main_color0].format = .UBYTE4N;
        pip_desc.layout.attrs[shd.ATTR_main_texcoord0].format = .FLOAT2;
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
            .sample_count = zball.offscreen_sample_count,
            .depth = .{
                .pixel_format = .DEPTH,
                .compare = .LESS_EQUAL,
                .write_enabled = false,
            },
            .color_count = 1,
        };
        pip_desc.layout.attrs[shd.ATTR_shadow_position].format = .FLOAT3;
        pip_desc.layout.attrs[shd.ATTR_shadow_color0].format = .UBYTE4N;
        pip_desc.layout.attrs[shd.ATTR_shadow_texcoord0].format = .FLOAT2;
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
    const vw: f32 = @floatFromInt(zball.viewport_size[0]);
    const vh: f32 = @floatFromInt(zball.viewport_size[1]);
    state.quad_vbuf = sg.makeBuffer(.{
        .usage = .IMMUTABLE,
        .data = sg.asRange(&[_]f32{
            0,  0,  0, 1,
            vw, 0,  1, 1,
            0,  vh, 0, 0,
            vw, vh, 1, 0,
        }),
    });

    // shader and pipeline object to render a fullscreen quad
    var scene_pip_desc: sg.PipelineDesc = .{
        .shader = sg.makeShader(shd.sceneShaderDesc(sg.queryBackend())),
        .primitive_type = .TRIANGLE_STRIP,
    };
    scene_pip_desc.layout.attrs[shd.ATTR_scene_pos].format = .FLOAT2;
    scene_pip_desc.layout.attrs[shd.ATTR_scene_in_uv].format = .FLOAT2;
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
    state.scene.bind.samplers[shd.SMP_smp] = smp;

    state.lights = try std.ArrayList(Light).initCapacity(allocator, zball.max_lights);

    try ui.init(allocator, &state.batch, state.spritesheet_texture, state.font_texture);
    errdefer ui.deinit();

    state.initialized = true;
}

pub fn deinit() void {
    std.debug.assert(state.initialized);
    ui.deinit();
    state.batch.deinit();
    state.lights.deinit();
    state.initialized = false;
}

pub fn addLight(pos: [2]f32, color: u32) void {
    if (state.lights.items.len >= zball.max_lights) return;
    state.lights.appendAssumeCapacity(.{ .pos = pos, .color = color });
}

pub fn renderMain(fb: Framebuffer) void {
    defer state.lights.clearRetainingCapacity();

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

    const vw: f32 = @floatFromInt(zball.viewport_size[0]);
    const vh: f32 = @floatFromInt(zball.viewport_size[1]);
    var mvp = m.orthographicLh(vw, vh, 0, 100);
    mvp = m.mul(m.translation(-vw / 2, -vh / 2, 0), mvp);
    const vs_params = shd.VsParams{ .mvp = mvp };

    var light_positions = std.mem.zeroes([zball.max_lights][4]f32);
    var light_colors = std.mem.zeroes([zball.max_lights][4]f32);
    for (state.lights.items, 0..) |l, i| {
        const r: f32 = @floatFromInt((l.color >> 16) & 0xFF);
        const g: f32 = @floatFromInt((l.color >> 8) & 0xFF);
        const b: f32 = @floatFromInt((l.color >> 0) & 0xFF);
        light_positions[i][0] = l.pos[0];
        light_positions[i][1] = l.pos[1];
        light_colors[i][0] = r / 255;
        light_colors[i][1] = g / 255;
        light_colors[i][2] = b / 255;
    }
    const fs_params = shd.FsParams{
        .flags = .{ 1, 0, 0, 0 },
        .light_positions = light_positions,
        .light_colors = light_colors,
    };
    const fs_params2 = shd.FsParams{
        .flags = .{ 0, 0, 0, 0 },
        .light_positions = light_positions,
        .light_colors = light_colors,
    };

    // Render background
    for (result.batches) |b| {
        if (b.layer != .background) continue;
        const tex = texture.get(b.tex) catch |err| {
            std.log.warn("Could not render texture {}: {}", .{ b.tex, err });
            continue;
        };
        bind.images[shd.IMG_tex] = tex.img;
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
        sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fs_params));
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
        bind.images[shd.IMG_tex] = tex.img;

        // We render the main layer two times to display a shadow
        // TODO avoid switching pipelines often
        sg.applyPipeline(state.shadow.pip);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
        sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fs_params));
        sg.applyBindings(bind);
        sg.draw(@intCast(b.offset), @intCast(b.len), 1);
    }

    // Render main layer
    var illuminated = false;
    for (result.batches) |b| {
        if (b.layer != .main) continue;
        const tex = texture.get(b.tex) catch |err| {
            std.log.warn("Could not render texture {}: {}", .{ b.tex, err });
            continue;
        };
        bind.images[shd.IMG_tex] = tex.img;
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
        if (!illuminated and b.illuminated) {
            sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fs_params));
        } else {
            sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fs_params2));
        }
        sg.applyBindings(bind);
        sg.draw(@intCast(b.offset), @intCast(b.len), 1);
        illuminated = b.illuminated;
    }

    // Render particles
    for (result.batches) |b| {
        if (b.layer != .particles) continue;
        const tex = texture.get(b.tex) catch |err| {
            std.log.warn("Could not render texture {}: {}", .{ b.tex, err });
            continue;
        };
        bind.images[shd.IMG_tex] = tex.img;
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
        sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fs_params));
        sg.applyBindings(bind);
        sg.draw(@intCast(b.offset), @intCast(b.len), 1);
    }

    // Render ui
    for (result.batches) |b| {
        if (b.layer != .ui) continue;
        const tex = texture.get(b.tex) catch |err| {
            std.log.warn("Could not render texture {}: {}", .{ b.tex, err });
            continue;
        };
        bind.images[shd.IMG_tex] = tex.img;
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
        sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fs_params2));
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
    return Framebuffer.init(@intCast(zball.viewport_size[0]), @intCast(zball.viewport_size[1]));
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
    const mvp = state.camera.view_proj;
    const vs_scene_params = shd.VsSceneParams{ .mvp = mvp };
    var fs_scene_params = shd.FsSceneParams{
        .value = 1.0,
        .scanline_amount = 0.0,
        .vignette_amount = 0.4,
        .vignette_intensity = 0.5,
        .aberration_amount = 0.0,
    };
    if (state.camera.zoom() > 2) {
        // Scale is big enough for scanlines
        fs_scene_params.scanline_amount = 1.0;
        fs_scene_params.vignette_amount = 0.6;
        fs_scene_params.vignette_intensity = 0.4;
        fs_scene_params.aberration_amount = 0.3;
    }
    // Update uniform transition progress (shader uses it to display part of the
    // screen while a transition is in progress)
    fs_scene_params.value = transition_progress;

    sg.applyPipeline(state.scene.pip);
    sg.applyUniforms(shd.UB_vs_scene_params, sg.asRange(&vs_scene_params));
    sg.applyUniforms(shd.UB_fs_scene_params, sg.asRange(&fs_scene_params));
    state.scene.bind.vertex_buffers[0] = state.quad_vbuf;
    state.scene.bind.images[shd.IMG_tex] = fb.attachments_desc.colors[0].image;
    sg.applyBindings(state.scene.bind);
    sg.draw(0, 4, 1);
}

pub fn handleEvent(ev: sapp.Event) void {
    ui.handleEvent(ev);
    switch (ev.type) {
        .RESIZED => {
            const width = ev.window_width;
            const height = ev.window_height;
            state.window_size = .{ width, height };
            state.camera.win_size = .{ @intCast(@max(0, width)), @intCast(@max(0, height)) };
            state.camera.invalidate();
        },
        else => {},
    }
}
