@header const zm = @import("zmath")
@ctype mat4 zm.Mat

//* main shader

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

//* fullscreen quad shader

@vs vs_fsq
@glsl_options flip_vert_y

uniform vs_fsq_params {
    mat4 mvp;
};

in vec2 pos;

out vec2 uv;

void main() {
    gl_Position = mvp * vec4(pos, 0, 1);
    uv = vec2(pos.x + 0.5, pos.y + 0.5);
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

//* background shader

@vs vs_bg

in vec2 pos;

void main() {
    gl_Position = vec4(pos * 2, 0, 1);
}
@end

@fs fs_bg
uniform fs_bg_params {
    float time;
};

out vec4 frag_color;

vec3 palette(float t) {
    vec3 a = vec3(0.5, 0.5, 0.5);
    vec3 b = vec3(0.5, 0.5, 0.5);
    vec3 c = vec3(1.0, 1.0, 1.0);
    vec3 d = vec3(0.263, 0.416, 0.557);
    return a + b * cos(6.28318 * (c * t + d));
}

void main() {
    // TODO pass in?
    vec2 res = vec2(160, 120);

    // calculate clip space coords
    vec2 uv = gl_FragCoord.xy / res;
    uv.y = 1 - uv.y;
    uv = 2 * uv - 1;

    vec2 uv0 = uv;

    vec3 final_color = vec3(0);

    for (float i = 0.0; i < 4.0; i++) {

        // compensate for non-square aspect ratio
        uv.x *= res.x / res.y;

        uv = fract(uv * 1.5) - 0.5;

        float d = length(uv) * exp(-length(uv0));

        vec3 col = palette(length(uv0) + i * 0.4 + time * 0.4);
        d = sin(d*8 + time)/8;
        d = abs(d);
        // d = smoothstep(0.0, 0.1, d);
        d = pow(0.01 / d, 1.2);

        final_color += col * d;
    }

    // frag_color = vec4(uv.x, uv.y, 0, 1);
    frag_color = vec4(final_color, 1);

    // frag_color = vec4(1, 0, 0, 1);
}
@end

@program bg vs_bg fs_bg
