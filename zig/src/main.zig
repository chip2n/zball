const std = @import("std");
const janet = @import("cjanet");

const c = @cImport(
    @cInclude("GLFW/glfw3.h"),
);

const sokol = @import("sokol");
const sg = sokol.gfx;

const boot = @embedFile("boot.janet");

var sample_count: i32 = 1;
var window: *c.GLFWwindow = undefined;
var vbuf: sg.Buffer = undefined;
var shd: sg.Shader = undefined;
var pip: sg.Pipeline = undefined;
var bind: sg.Bindings = undefined;

pub fn main() !void {
    if (janet.janet_init() != 0) {
        return error.JanetInitializationFailed;
    }
    defer janet.janet_deinit();

    const jenv = janet.janet_core_env(null) orelse {
        return error.JanetInitializationFailed;
    };

    janet.janet_cfuns(jenv, "c", &cfuns);
    var res: janet.Janet = undefined;
    if (janet.janet_dostring(jenv, boot, null, &res) != 0) {
        return error.JanetInitializationFailed;
    }
}

fn c_start(argc: i32, argv: [*c]janet.Janet) callconv(.C) janet.Janet {
    _ = argv; // autofix
    janet.janet_fixarity(argc, 0);

    if (c.glfwInit() == c.GLFW_FALSE) {
        janet.janet_panic("Failed to initialize GLFW.");
    }
    c.glfwWindowHint(c.GLFW_COCOA_RETINA_FRAMEBUFFER, 0);
    c.glfwWindowHint(c.GLFW_DEPTH_BITS, 0);
    c.glfwWindowHint(c.GLFW_STENCIL_BITS, 0);
    c.glfwWindowHint(c.GLFW_SAMPLES, if (sample_count == 1) 0 else sample_count);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 4);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 1);
    c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);

    window = c.glfwCreateWindow(640, 480, "Game", null, null) orelse {
        janet.janet_panic("Failed to initialize GLFW.");
    };
    c.glfwMakeContextCurrent(window);
    c.glfwSwapInterval(1);

    sg.setup(.{
        .environment = .{
            .defaults = .{
                .color_format = .RGBA8,
                .depth_format = .NONE,
                .sample_count = sample_count,
            },
        },
    });

    const vertices = [_]f32{
        // positions            // colors
        0.0,  0.5, 0.5,     1.0, 0.0, 0.0, 1.0,
        0.5, -0.5, 0.5,     0.0, 1.0, 0.0, 1.0,
        -0.5, -0.5, 0.5,     0.0, 0.0, 1.0, 1.0
    };
    vbuf = sg.makeBuffer(.{
        .data = sg.asRange(&vertices),
    });

    shd = sg.makeShader(.{
        .vs = .{ .source = @embedFile("vert.glsl") },
        .fs = .{ .source = @embedFile("frag.glsl") },
    });

    var pip_desc: sg.PipelineDesc = .{
        .shader = shd,
    };
    pip_desc.layout.attrs[0]  = .{ .format = .FLOAT3 };
    pip_desc.layout.attrs[1]  = .{ .format = .FLOAT4 };
    pip = sg.makePipeline(pip_desc);

    bind.vertex_buffers[0] = vbuf;

    return janet.janet_wrap_nil();
}

fn c_end(argc: i32, argv: [*c]janet.Janet) callconv(.C) janet.Janet {
    _ = argv; // autofix
    janet.janet_fixarity(argc, 0);

    sg.shutdown();
    c.glfwTerminate();

    return janet.janet_wrap_nil();
}

fn c_should_close(argc: i32, argv: [*c]janet.Janet) callconv(.C) janet.Janet {
    _ = argv; // autofix
    janet.janet_fixarity(argc, 0);

    return janet.janet_wrap_boolean(c.glfwWindowShouldClose(window));
}

fn c_render(argc: i32, argv: [*c]janet.Janet) callconv(.C) janet.Janet {
    _ = argv; // autofix
    janet.janet_fixarity(argc, 0);

    var width: i32 = undefined;
    var height: i32 = undefined;
    c.glfwGetFramebufferSize(window, &width, &height);
    const chain: sg.Swapchain = .{
        .width = width,
        .height = height,
        .sample_count = sample_count,
        .color_format = .RGBA8,
        .depth_format = .NONE,
        .gl = .{
            // we just assume here that the GL framebuffer is always 0
            .framebuffer = 0,
        }
    };
    sg.beginPass(.{ .swapchain = chain });
    sg.applyPipeline(pip);
    sg.applyBindings(bind);
    sg.draw(0, 3, 1);
    sg.endPass();
    sg.commit();

    c.glfwSwapBuffers(window);
    c.glfwPollEvents();
    return janet.janet_wrap_nil();
}

const cfuns = [_]janet.JanetReg{
    janet.JanetReg{ .name = "c/start", .cfun = c_start, .documentation = ""},
    janet.JanetReg{ .name = "c/end", .cfun = c_end, .documentation = ""},
    janet.JanetReg{ .name = "c/should-close?", .cfun = c_should_close, .documentation = ""},
    janet.JanetReg{ .name = "c/render", .cfun = c_render, .documentation = ""},
    janet.JanetReg{ .name = null, .cfun = null, .documentation = null},
};
