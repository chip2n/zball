@header const zm = @import("zmath")
@ctype mat4 zm.Mat

@vs vs
uniform vs_params {
    mat4 mvp;
};

in vec4 position;
in vec4 color0;
in vec2 texcoord0;

out vec4 color;
out vec2 uv;

void main() {
    gl_Position = mvp * position;
    color = color0;
    uv = texcoord0;
}
@end

@fs fs
uniform texture2D tex;
uniform sampler smp;

in vec4 color;
in vec2 uv;
out vec4 frag_color;

void main() {
    frag_color = texture(sampler2D(tex, smp), uv) * color;
}
@end

@program main vs fs

// shaders for rendering a fullscreen-quad in default pass
@vs vs_fsq
@glsl_options flip_vert_y

uniform vs_fsq_params {
    mat4 mvp;
};

in vec2 pos;

out vec2 uv;

void main() {
    gl_Position = mvp * vec4(pos, 0, 1);
    uv = pos;
}
@end

@fs fs_fsq
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;

out vec4 frag_color;

void main() {
    vec3 c = texture(sampler2D(tex, smp), uv).xyz;
    frag_color = vec4(c, 1.0);
}
@end

@program fsq vs_fsq fs_fsq
