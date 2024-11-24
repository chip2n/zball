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
    frag_color = texture(sampler2D(tex, smp), uv) * color; // TODO remove color I guess
}
@end

@program main vs fs

//* shadow shader

// This shader renders everything in a solid shadow color, placing it at an offset to give the illusion of a drop shadow. Fancy!

@vs vs_shadow

uniform vs_params {
    mat4 mvp;
};

in vec4 position;
in vec4 color0;
in vec2 texcoord0;

out vec2 uv;

void main() {
    vec4 offset = vec4(2, 2, 0, 0);
    gl_Position = mvp * (position + offset);
    uv = texcoord0;
}
@end

@fs fs_shadow
uniform texture2D tex;
uniform sampler smp;

in vec2 uv;
out vec4 frag_color;

void main() {
    vec4 sampled_color = texture(sampler2D(tex, smp), uv);
    frag_color = vec4(26.0/255, 31.0/255, 37.0/255, sampled_color.a);
}
@end

@program shadow vs_shadow fs_shadow

//* scene shader

@vs vs_scene
@glsl_options flip_vert_y

uniform vs_scene_params {
    mat4 mvp;
};

in vec2 pos;
in vec2 in_uv;

out vec2 frag_pos;
out vec2 uv;

void main() {
    gl_Position = mvp * vec4(pos, 0, 1);
    frag_pos = pos;
    uv = in_uv;
}
@end

@fs fs_scene

uniform texture2D tex;
uniform sampler smp;
uniform fs_scene_params {
    float value;
};

in vec2 frag_pos;
in vec2 uv;

out vec4 frag_color;

float warp(float x) {
    return 0.5 - sin(asin(1 - 2 * x) / 2);
}

vec3 darken(float x, vec3 color) {
    float pos = x;
    if (x > 0.5) pos = 1.0 - x;
    float factor = min(warp(pos) * 2 + 0.4, 1.0);
    return color * factor;
}

void main() {
    float transition_progress = value;
    float frag_progress = 0.5 + frag_pos.y;

    // Fragment is outside the transition animation
    if (frag_progress > transition_progress) discard;

    float roll_fraction = 0.2 * (1 - transition_progress);

    if (frag_progress < transition_progress - roll_fraction) {
        // Fragment is fully "rolled out" - render normally
        frag_color = texture(sampler2D(tex, smp), uv);
    } else {
        // Fragment is inside the roll - warp the UV y-coord to fake 3D effect
        float distance_from_bottom = transition_progress - frag_progress;
        float roll_offset = distance_from_bottom/roll_fraction;
        vec2 roll_uv = vec2(uv.x, transition_progress + roll_fraction * warp(roll_offset));
        vec4 c = texture(sampler2D(tex, smp), roll_uv);
        vec3 modified_color = darken(roll_offset, c.xyz);
        frag_color = vec4(modified_color, c.a);
    }
}
@end

@program scene vs_scene fs_scene
