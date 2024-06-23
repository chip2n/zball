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

const screen_size = .{ 640, 480 };

const state = struct {
    var bind: sg.Bindings = .{};
    var pip: sg.Pipeline = .{};
    var pass_action: sg.PassAction = .{};

    var pos: f32 = 0.0;
    var camera: [2]f32 = .{ screen_size[0] / 2, screen_size[1] / 2 };
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
    const texture = Texture.init(img);
    state.bind.fs.images[shd.SLOT_tex] = sg.makeImage(texture.desc);
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

fn quad(buf: []Vertex, x: f32, y: f32, w: f32, h: f32, offset: usize) void {
    buf[offset + 0] = .{ .x = x, .y = y + h, .z = 0.5, .color = 0xFFFFFFFF, .u = 0.0, .v = 0.0 };
    buf[offset + 1] = .{ .x = x + w, .y = y, .z = 0.5, .color = 0xFFFFFFFF, .u = 1.0, .v = 1.0 };
    buf[offset + 2] = .{ .x = x, .y = y, .z = 0.5, .color = 0xFFFFFFFF, .u = 0.0, .v = 1.0 };
    buf[offset + 3] = .{ .x = x, .y = y + h, .z = 0.5, .color = 0xFFFFFFFF, .u = 0.0, .v = 0.0 };
    buf[offset + 4] = .{ .x = x + w, .y = y + h, .z = 0.5, .color = 0xFFFFFFFF, .u = 1.0, .v = 0.0 };
    buf[offset + 5] = .{ .x = x + w, .y = y, .z = 0.5, .color = 0xFFFFFFFF, .u = 1.0, .v = 1.0 };
}

export fn frame() void {
    const dt: f64 = sapp.frameDuration();
    state.pos += @floatCast(dt * 1);

    var verts: [6]Vertex = undefined;
    quad(&verts, state.pos, 0.0, 640, 480, 0);
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
    _ = ig.igDragFloat("Pos", &state.pos, 0.2, 0.0, 100.0, "format", ig.ImGuiSliderFlags_None);
    ig.igEnd();
    //=== UI CODE ENDS HERE

    const vs_params = computeVsParams();
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });

    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
    sg.draw(0, 6, 1);

    simgui.render();

    sg.endPass();
    sg.commit();
}

export fn event(ev: [*c]const sapp.Event) void {
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
        .width = screen_size[0],
        .height = screen_size[1],
        .icon = .{ .sokol_default = true },
        .window_title = "game",
        .logger = .{ .func = slog.func },
    });
}

fn computeVsParams() shd.VsParams {
    const model = zm.identity();
    const view = zm.translation(-state.camera[0], -state.camera[1], 0);
    const proj = zm.orthographicRh(640, 480, 0.1, 10.0);
    const mvp = zm.mul(model, zm.mul(view, proj));
    return shd.VsParams{ .mvp = mvp };
}
