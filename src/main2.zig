const std = @import("std");
const assert = std.debug.assert;

const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const shd = @import("shaders/triangle.glsl.zig");


const janet = @import("cjanet");
// TODO
const j = @import("janet.zig");
const boot = @embedFile("boot.janet");
const boot_image = @embedFile("out/test.jimage");

const emscripten = @cImport(
    @cInclude("emscripten/console.h"),
);

const state = struct {
    var bind: sg.Bindings = .{};
    var pip: sg.Pipeline = .{};
};

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    // create vertex buffer with triangle vertices
    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&[_]f32{
            // positions         colors
            0.0,  0.5,  0.5, 1.0, 0.0, 0.0, 1.0,
            0.5,  -0.5, 0.5, 0.0, 1.0, 0.0, 1.0,
            -0.5, -0.5, 0.5, 0.0, 0.0, 1.0, 1.0,
        }),
    });

    // create a shader and pipeline object
    var pip_desc: sg.PipelineDesc = .{
        .shader = sg.makeShader(shd.triangleShaderDesc(sg.queryBackend())),
    };
    pip_desc.layout.attrs[0].format = .FLOAT3;
    pip_desc.layout.attrs[1].format = .FLOAT4;
    state.pip = sg.makePipeline(pip_desc);
}

export fn frame() void {
    // default pass-action clears to grey
    sg.beginPass(.{ .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    sg.draw(0, 3, 1);
    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    sg.shutdown();
}

pub fn main() !void {
    if (j.init() != 0) {
        return error.JanetInitializationFailed;
    }
    defer j.deinit();

    const jenv = j.core_env(null) orelse {
        return error.JanetInitializationFailed;
    };
    const lookup = j.env_lookup(jenv);

    // janet.janet_cfuns(jenv, "c", &cfuns);

    // var res: janet.Janet = undefined;
    // if (janet.janet_dostring(jenv, boot, null, &res) != 0) {
    //     return error.JanetInitializationFailed;
    // }

    // Unmarshal bytecode
    const main_func = blk: {
        const handle = j.gclock();
        defer j.gcunlock(handle);

        const marsh_out = j.unmarshal(boot_image, boot_image.len, 0, lookup, null);
        const tbl = j.unwrap_table(marsh_out);

        var ret: j.Janet = undefined;
        const f = j.resolve(tbl, j.csymbol("main"), &ret);
        assert(f == j.BINDING_DEF);
        const main_func: *j.JanetFunction  = j.unwrap_function(ret);
        break :blk main_func;
    };

    const fiber = j.fiber(main_func, 64, 0, null);
    var out: janet.Janet = undefined;
    const result = j.fiber_continue(fiber, j.wrap_nil(), &out);
    if (result != j.SIGNAL_OK and result != j.SIGNAL_EVENT) {
        std.log.warn("Something went wrong!", .{});
        j.stacktrace(fiber, out);
        return;
    }

    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = 640,
        .height = 480,
        .icon = .{ .sokol_default = true },
        .window_title = "triangle.zig",
        .logger = .{ .func = slog.func },
    });
}

// const cfuns = [_]janet.JanetReg{
//     // janet.JanetReg{ .name = "c/start", .cfun = c_start, .documentation = ""},
//     // janet.JanetReg{ .name = "c/end", .cfun = c_end, .documentation = ""},
//     // janet.JanetReg{ .name = "c/should-close?", .cfun = c_should_close, .documentation = ""},
//     // janet.JanetReg{ .name = "c/render", .cfun = c_render, .documentation = ""},
//     janet.JanetReg{ .name = null, .cfun = null, .documentation = null},
// };
