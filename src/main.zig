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

const max_quads = 1024;
const max_verts = max_quads * 4;

const initial_screen_size = .{ 640, 480 };

const state = struct {
    var bind: sg.Bindings = .{};
    var pip: sg.Pipeline = .{};
    var pass_action: sg.PassAction = .{};

    var texture: Texture = undefined;
    var pos: [2]f32 = .{ 0, 0 };
    var camera: [2]f32 = .{ initial_screen_size[0] / 2, initial_screen_size[1] / 2 };

    var window_size: [2]i32 = initial_screen_size;
};

const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: f32,
    v: f32,
};

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });

    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = max_verts,
    });

    // Let's texture it up!
    state.texture = Texture.init(img);
    state.bind.fs.images[shd.SLOT_tex] = sg.makeImage(state.texture.desc);
    state.bind.fs.samplers[shd.SLOT_smp] = sg.makeSampler(.{});

    // create a shader and pipeline object
    var pip_desc: sg.PipelineDesc = .{
        .shader = sg.makeShader(shd.mainShaderDesc(sg.queryBackend())),
        .cull_mode = .BACK,
    };
    pip_desc.layout.attrs[shd.ATTR_vs_position].format = .FLOAT3;
    pip_desc.layout.attrs[shd.ATTR_vs_color0].format = .UBYTE4N;
    pip_desc.layout.attrs[shd.ATTR_vs_texcoord0].format = .FLOAT2;

    state.pip = sg.makePipeline(pip_desc);

    // initial clear color
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.0, .g = 0.5, .b = 1.0, .a = 1.0 },
    };
}

const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const QuadOptions = struct {
    buf: []Vertex,
    offset: usize = 0,
    src: ?Rect = null,
    dst: Rect,
    // reference texture dimensions
    tw: f32,
    th: f32,
};
fn quad(v: QuadOptions) void {
    const buf = v.buf;
    const offset = v.offset;
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
    buf[offset + 0] = .{ .x = x,      .y = y,          .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv1[1] };
    buf[offset + 1] = .{ .x = x + w,  .y = y + h,      .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv2[1] };
    buf[offset + 2] = .{ .x = x,      .y = y + h,      .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv2[1] };
    buf[offset + 3] = .{ .x = x,      .y = y,          .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv1[1] };
    buf[offset + 4] = .{ .x = x + w,  .y = y,          .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv1[1] };
    buf[offset + 5] = .{ .x = x + w,  .y = y + h,      .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv2[1] };
    // zig fmt: on
}

export fn frame() void {
    const dt: f64 = sapp.frameDuration();
    _ = dt; // autofix

    var verts: [6]Vertex = undefined;
    quad(.{
        .buf = &verts,
        .src = .{ .x = 0, .y = 0, .w = 16, .h = 8 },
        .dst = .{ .x = state.pos[0], .y = state.pos[1], .w = 16, .h = 8 },
        .tw = @floatFromInt(state.texture.desc.width),
        .th = @floatFromInt(state.texture.desc.height),
    });
    sg.updateBuffer(state.bind.vertex_buffers[0], sg.asRange(&verts));

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
    _ = ig.igColorEdit3("Background", &state.pass_action.colors[0].clear_value.r, ig.ImGuiColorEditFlags_None);
    _ = ig.igDragFloat2("Camera", &state.camera, 1, -1000, 1000, "%.4g", ig.ImGuiSliderFlags_None);
    _ = ig.igDragFloat2("Pos", &state.pos, 1, -1000, 1000, "%.4g", ig.ImGuiSliderFlags_None);
    ig.igEnd();
    //=== UI CODE ENDS HERE

    const vs_params = computeVsParams();
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });

    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
    sg.draw(0, verts.len, 1);

    simgui.render();

    sg.endPass();
    sg.commit();
}

export fn event(ev: [*c]const sapp.Event) void {
    switch (ev.*.type) {
        .RESIZED => {
            const width = ev.*.window_width;
            const height = ev.*.window_height;
            state.window_size = .{ width, height };
        },
        else => {},
    }

    // forward input events to sokol-imgui
    _ = simgui.handleEvent(ev.*);
}

export fn cleanup() void {
    sg.shutdown();
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
        .window_title = "game",
        .logger = .{ .func = slog.func },
    });
}

fn computeVsParams() shd.VsParams {
    const model = zm.identity();
    const view = zm.translation(-state.camera[0], -state.camera[1], 0);
    var proj = zm.orthographicLh(
        @floatFromInt(state.window_size[0]),
        @floatFromInt(state.window_size[1]),
        -10,
        10,
    );
    // flip so y-axis point down
    proj = zm.mul(zm.scaling(1, -1, 1), proj);
    const mvp = zm.mul(model, zm.mul(view, proj));
    return shd.VsParams{ .mvp = mvp };
}
