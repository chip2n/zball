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
in vec2 uv; // TODO not really needed I guess

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
        vec3 c = texture(sampler2D(tex, smp), uv).xyz;
        frag_color = vec4(c, 1.0);
    } else {
        // Fragment is inside the roll - warp the UV y-coord to fake 3D effect
        float distance_from_bottom = transition_progress - frag_progress;
        float roll_offset = distance_from_bottom/roll_fraction;
        vec2 roll_uv = vec2(uv.x, transition_progress + roll_fraction * warp(roll_offset));
        vec3 c = texture(sampler2D(tex, smp), roll_uv).xyz;
        c = darken(roll_offset, c);
        frag_color = vec4(c, 1.0);
    }
}
@end

@program scene vs_scene fs_scene

//* background shader

@vs vs_bg

in vec2 pos;
in vec2 in_uv;

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
    vec3 a = vec3(0.408, 0.5, 0.5);
    vec3 b = vec3(-0.602, 0.5, 0.5);
    vec3 c = vec3(0.222, 1.0, 1.0);
    vec3 d = vec3(0.0, 0.333, 0.667);
    return a + b * cos(6.28318 * (c * t + d));
}

float sdHexagon(in vec2 p, in float r) {
    const vec3 k = vec3(-0.866025404,0.5,0.577350269);
    p = abs(p);
    p -= 2.0*min(dot(k.xy,p),0.0)*k.xy;
    p -= vec2(clamp(p.x, -k.z*r, k.z*r), r);
    return length(p)*sign(p.y);
}

void main() {
    // TODO pass in?
    vec2 res = vec2(160, 120);

    vec2 uv = gl_FragCoord.xy / res;
    uv.y = 1 - uv.y;
    uv = 2 * uv - 1;

    vec2 ndc = uv;

    // compensate for non-square aspect ratio
    uv.x *= res.x / res.y;

    uv *= 0.4;
    uv.x -= 0.05 * sin(time * 0.8 + uv.y * 3);

    float theta = 0.2 * time;
    float x = uv.x * cos(theta) - uv.y * sin(theta);
    float y = uv.x * sin(theta) + uv.y * cos(theta);
    uv.x = x;
    uv.y = y;

    vec3 final_color = vec3(0);


    for (float i = 0.0; i < 3.0; i++) {
        uv = fract(uv * 2) - 0.5;

        // float d = length(uv) + 0.8;
        float d = 0;
        if (i < 2) {
            d = length(uv) + 0.8;
        } else {
            d = sdHexagon(uv, 1.8);
        }
        d = sin(d*20 + time);
        d = abs(d);

        vec3 col = palette(length(ndc) + length(uv) / 2 + i * 0.4 + time * 0.2);
        final_color += col * vec3(d) * 0.1;
    }

    frag_color = vec4(final_color, 1);
    // frag_color = vec4(d, d, 0, 1);
    // frag_color = vec4(1, 0, 0, 1);
}
@end

@program bg vs_bg fs_bg
