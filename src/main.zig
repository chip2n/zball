const std = @import("std");
const assert = std.debug.assert;

const sokol = @import("sokol");
const sg = sokol.gfx;
const slog = sokol.log;
const sapp = sokol.app;
const sglue = sokol.glue;
const shd = @import("shaders/main.glsl.zig");

const img = @embedFile("spritesheet.png");
const Texture = @import("Texture.zig");

const state = struct {
    var bind: sg.Bindings = .{};
    var pip: sg.Pipeline = .{};
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

    // create vertex buffer with triangle vertices
    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&[_]Vertex{
            // zig fmt: off
            .{ .x = -0.5, .y =  0.5, .z = 0.5, .color = 0xFFFFFFFF, .u = 0.0, .v = 0.0 },
            .{ .x = 0.5,  .y = -0.5, .z = 0.5, .color = 0xFFFFFFFF, .u = 1.0, .v = 1.0 },
            .{ .x = -0.5, .y = -0.5, .z = 0.5, .color = 0xFFFFFFFF, .u = 0.0, .v = 1.0 },

            .{ .x = -0.5, .y =  0.5, .z = 0.5, .color = 0xFFFFFFFF, .u = 0.0, .v = 0.0 },
            .{ .x = 0.5,  .y =  0.5, .z = 0.5, .color = 0xFFFFFFFF, .u = 1.0, .v = 0.0 },
            .{ .x = 0.5,  .y = -0.5, .z = 0.5, .color = 0xFFFFFFFF, .u = 1.0, .v = 1.0 },
            // zig fmt: on
        }),
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
}

export fn frame() void {
    // default pass-action clears to grey
    sg.beginPass(.{ .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);

    sg.draw(0, 6, 1);
    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    sg.shutdown();
}

pub fn main() !void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = 640,
        .height = 480,
        .icon = .{ .sokol_default = true },
        .window_title = "game",
        .logger = .{ .func = slog.func },
    });
}
