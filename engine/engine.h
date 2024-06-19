#define SOKOL_IMPL
#define SOKOL_GLCORE

#include <janet.h>

#include "sokol_gfx.h"
#include "sokol_log.h"
#include "glfw_glue.h"

sg_buffer vbuf;
sg_shader shd;
sg_pipeline pip;
sg_bindings bind;

static Janet c_start(int32_t argc, Janet* argv) {
    janet_fixarity(argc, 0);
    glfw_init(&(glfw_desc_t){ .title = "triangle-glfw.c", .width = 640, .height = 480, .no_depth_buffer = true });

    sg_setup(&(sg_desc){
            .environment = glfw_environment(),
            .logger.func = slog_func,
        });

    const float vertices[] = {
        // positions            // colors
        0.0f,  0.5f, 0.5f,     1.0f, 0.0f, 0.0f, 1.0f,
        0.5f, -0.5f, 0.5f,     0.0f, 1.0f, 0.0f, 1.0f,
        -0.5f, -0.5f, 0.5f,     0.0f, 0.0f, 1.0f, 1.0f
    };
    vbuf = sg_make_buffer(&(sg_buffer_desc){
            .data = SG_RANGE(vertices)
        });

    shd = sg_make_shader(&(sg_shader_desc){
            .vs.source =
            "#version 330\n"
            "layout(location=0) in vec4 position;\n"
            "layout(location=1) in vec4 color0;\n"
            "out vec4 color;\n"
            "void main() {\n"
            "  gl_Position = position;\n"
            "  color = color0;\n"
            "}\n",
            .fs.source =
            "#version 330\n"
            "in vec4 color;\n"
            "out vec4 frag_color;\n"
            "void main() {\n"
            "  frag_color = color;\n"
            "}\n"
        });

    pip = sg_make_pipeline(&(sg_pipeline_desc){
            .shader = shd,
            .layout = {
                .attrs = {
                    [0].format=SG_VERTEXFORMAT_FLOAT3,
                    [1].format=SG_VERTEXFORMAT_FLOAT4
                }
            }
        });

    sg_bindings bind2 = {
        .vertex_buffers[0] = vbuf
    };
    bind = bind2;

    return janet_wrap_nil();
}

static Janet c_end(int32_t argc, Janet* argv) {
  janet_fixarity(argc, 0);
  sg_shutdown();
  glfwTerminate();
  return janet_wrap_nil();
}

static Janet c_should_close(int32_t argc, Janet* argv) {
    janet_fixarity(argc, 0);
    return janet_wrap_boolean(glfwWindowShouldClose(glfw_window()));
}

static Janet c_render(int32_t argc, Janet* argv) {
    janet_fixarity(argc, 0);
    sg_begin_pass(&(sg_pass){ .swapchain = glfw_swapchain() });
    sg_apply_pipeline(pip);
    sg_apply_bindings(&bind);
    sg_draw(0, 3, 1);
    sg_end_pass();
    sg_commit();
    glfwSwapBuffers(glfw_window());
    glfwPollEvents();
    return janet_wrap_nil();
}

static const JanetReg engine_cfuns[] = {
    {"c/start", c_start, ""},
    {"c/end", c_end, ""},
    {"c/should-close?", c_should_close, ""},
    {"c/render", c_render, ""},
    {NULL, NULL, NULL}
};

/* JANET_MODULE_ENTRY(JanetTable *env) { */
/*     janet_cfuns(env, "engine", engine_cfuns); */
/* } */
