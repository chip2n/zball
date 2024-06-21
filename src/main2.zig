const std = @import("std");

const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const shd = @import("shaders/triangle.glsl.zig");


const janet = @import("cjanet");
// TODO
const janet2 = @import("janet.zig");
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
    if (janet2.init() != 0) {
        return error.JanetInitializationFailed;
    }
    defer janet2.deinit();

    const jenv = janet2.core_env(null) orelse {
        return error.JanetInitializationFailed;
    };
    const lookup = janet2.env_lookup(jenv);

    // janet.janet_cfuns(jenv, "c", &cfuns);

    // var res: janet.Janet = undefined;
    // if (janet.janet_dostring(jenv, boot, null, &res) != 0) {
    //     return error.JanetInitializationFailed;
    // }

    { // Unmarshal bytecode
        const handle = janet2.gclock();
        // TODO defer unlocn

        const marsh_out = janet2.unmarshal(
            boot_image,
            // @sizeOf(@TypeOf(boot_image)),
            boot_image.len,
            0,
            lookup,
            null
        );
        // if (janet.janet_checktype(marsh_out, janet.JANET_FUNCTION) != 0) {
        //     return error.JanetInitializationFailed;
        // }

        // const jfunc = janet.janet_unwrap_function(marsh_out);
        const tbl = janet2.unwrap_table(marsh_out);
        var main_func: *janet.JanetFunction  = undefined;
        var found = false;
        for (0..@intCast(tbl.*.count)) |i| outer: {
            const key = tbl.*.data[i].key;
            const value = tbl.*.data[i].value;
            const t = janet2.janet_type(key);

            var buf: [128]u8 = undefined;
            _ = try std.fmt.bufPrintZ(&buf, "key type: {}", .{t});
            emscripten.emscripten_console_log(&buf);

            std.log.warn("key type: {}", .{t});
            if (janet2.checktype(key, janet.JANET_SYMBOL) != 0) {
                std.log.warn("pass", .{});
                // const sym = janet.janet_unwrap_symbol(key);
                const s = janet2.to_string(key);
                if (std.mem.eql(u8, std.mem.span(s), "main")) {
                    std.log.warn("s: {s}", .{s});
                    std.log.warn("main type: {}", .{janet2.janet_type(value)});
                    const main_tbl = janet2.unwrap_table(value);

                    for (0..@intCast(main_tbl.*.count)) |j| {
                        const key2 = main_tbl.*.data[j].key;
                        const value2 = main_tbl.*.data[j].value;
                        std.log.warn("key: {} {}", .{janet2.janet_type(key2), janet2.janet_type(value2)});
                        // TODO we shouldn't have to do this nonsense - why can't I just use table_get?
                        // const unwrapped = janet.janet_unwrap_keyword(key2);
                        // std.log.warn("name of the thing: {s}", .{unwrapped});
                        if (janet2.janet_type(value2) == 12) {
                            main_func = janet2.unwrap_function(value2);
                            found = true;
                            break :outer;
                        }
                    }
                    const f = janet2.table_find(main_tbl, janet2.wrap_keyword("value"));
                    std.log.warn("found??? {*}", .{f});
                    const main_func_raw = janet2.table_get(main_tbl, janet2.wrap_keyword("value"));
                    std.log.warn("main type2: {}", .{janet2.janet_type(main_func_raw)});
                    main_func = janet2.unwrap_function(main_func_raw);
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            std.log.err("Could not find main function in janet code", .{});
            return error.JanetInitializationFailed;
        }

        std.log.warn("NAME: {s}", .{main_func.*.def.*.name});

        // TODO pcall instead, this blocks GC and stuff (or maybe thats fine?)
        // const result = janet.janet_call(main_func, 0, null);
        // _ = result;

        // const temptab = jenv;
        // const args = janet.janet_array(0);

        // janet.janet_table_put(temptab, janet.janet_ckeywordv("args"), janet.janet_wrap_array(args));
        // janet.janet_table_put(temptab, janet.janet_ckeywordv("executable"), janet.janet_cstringv("game"));
        // janet.janet_gcroot(janet.janet_wrap_table(temptab));

        janet2.gcunlock(handle);


        const fiber = janet2.fiber(main_func, 64, 0, null);
        
        // fiber.*.env = temptab;

        // fiber.env.* = temptab; // TODO needed?
        // fiber.*.env = jenv;
        var out: janet.Janet = undefined;
        const result = janet2.fiber_continue(fiber, janet2.wrap_nil(), &out);
        if (result != janet2.SIGNAL_OK and result != janet2.SIGNAL_EVENT) {
            std.log.warn("Something went wrong!", .{});
            janet2.stacktrace(fiber, out);
            return;
        }
        


        // std.log.warn("Type: {}", .{janet2.janet_type(marsh_out)});
        std.log.warn("Table count: {}", .{tbl.*.count});
    }


    // std.log.warn("func name: {s}", .{jfunc.*.def.*.name});

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
