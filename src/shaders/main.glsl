@header const m = @import("math")
@ctype mat4 m.Mat4

@block utils
/* Gradient noise from Jorge Jimenez's presentation: */
/* http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare */
float gradientNoise(vec2 uv) {
	return fract(52.9829189 * fract(dot(uv, vec2(0.06711056, 0.00583715))));
}
@end

//* main shader

@vs vs
@msl_options fixup_clipspace

layout(binding=0) uniform vs_params {
    mat4 mvp;
};

in vec4 position;
in vec4 color0;
in vec2 texcoord0;

out vec4 color;
out vec2 uv;
out vec2 frag_position;

void main() {
    gl_Position = mvp * position;
    color = color0;
    uv = texcoord0;
    frag_position = position.xy;
}
@end

@fs fs
@include_block utils

layout(binding=0) uniform texture2D tex;
layout(binding=1) uniform sampler smp;
layout(binding=2) uniform fs_params {
    vec4 flags;
    vec4 light_positions[256];
    vec4 light_colors[256];
};

in vec4 color;
in vec2 uv;
in vec2 frag_position;
out vec4 frag_color;

float constant = 2.0;  // Constant factor
float linear = 0.04;   // Linear attenuation
float quadratic = 0.032;  // Quadratic attenuation

void main() {
    vec4 c = texture(sampler2D(tex, smp), uv) * color; // TODO remove color I guessa

    if (flags.x > 0) {
        for (int i = 0; i < light_positions.length(); i++) {
            vec2 light_pos = light_positions[i].xy;
            vec3 light_color = light_colors[i].rgb;
            float distance_to_light = length(light_pos - frag_position);
            float light_strength = 0.5;
            float attenuation = 1.0 / (constant + linear * distance_to_light + quadratic * (distance_to_light * distance_to_light));
            float s = attenuation * light_strength;
            vec3 light_result = vec3(s, s, s) * light_color;
            c += vec4(light_result, 0);

            // A little bit extra glow
            if (distance_to_light < 10) {
                c += vec4(light_color * 0.015, 0);
            } else if (distance_to_light < 14) {
                // c += vec4(light_color * 0.015, 0);
            }
        }
    }

    // This prevents banding for the light effects
    c += (1.0 / 255.0) * gradientNoise(gl_FragCoord.xy) - (0.5 / 255.0);

    frag_color = c;
}
@end

@program main vs fs

//* shadow shader

// This shader renders everything in a solid shadow color, placing it at an offset to give the illusion of a drop shadow. Fancy!

@vs vs_shadow
@msl_options fixup_clipspace

layout(binding=0) uniform vs_params {
    mat4 mvp;
};

in vec4 position;
in vec4 color0;
in vec2 texcoord0;

out vec2 uv;
out vec2 frag_position;

void main() {
    vec4 offset = vec4(2, 2, 0, 0);
    gl_Position = mvp * (position + offset);
    uv = texcoord0;
    frag_position = position.xy;
}
@end

// TODO share between shaders
@fs fs_shadow
layout(binding=0) uniform texture2D tex;
layout(binding=1) uniform sampler smp;
layout(binding=2) uniform fs_params {
    vec4 flags;
    vec4 light_positions[256];
    vec4 light_colors[256];
};

in vec2 uv;
in vec2 frag_position;
out vec4 frag_color;

void main() {
    vec4 sampled_color = texture(sampler2D(tex, smp), uv);
    vec3 shadow_color = vec3(26.0/255, 31.0/255, 37.0/255);
    float distance_to_light = 9999;
    for (int i = 0; i < light_positions.length(); i++) {
        vec2 light_pos = light_positions[i].xy;
        distance_to_light = min(distance_to_light, length(light_pos - frag_position));
    }
    frag_color = vec4(shadow_color, sampled_color.a * max(0.2, (1 - (20 / distance_to_light))));
}
@end

@program shadow vs_shadow fs_shadow

//* scene shader

@vs vs_scene
@msl_options fixup_clipspace
@msl_options flip_vert_y

layout(binding=0) uniform vs_scene_params {
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
@include_block utils

layout(binding=0) uniform texture2D tex;
layout(binding=1) uniform sampler smp;
layout(binding=2) uniform fs_scene_params {
    float value;
    float scanline_amount;
    float vignette_amount;
    float vignette_intensity;
    float aberration_amount;
};

in vec2 frag_pos;
in vec2 uv;

out vec4 frag_color;

const float PI = 3.1415926535897932384626433832795;
vec2 resolution = vec2(320, 240); // TODO pass in through uniform

float warp(float x) {
    return 0.5 - sin(asin(1 - 2 * x) / 2);
}

vec3 darken(float x, vec3 color) {
    float pos = x;
    if (x > 0.5) pos = 1.0 - x;
    float factor = min(warp(pos) * 2 + 0.4, 1.0);
    return color * factor;
}

// Scanline effect

// Distance from the center of the closest pixel
vec2 dist(vec2 pos) {
    pos = pos * resolution;
    return -((pos - floor(pos)) - vec2(0.5));
}

// 1D gaussian
float gaus(float pos, float scale) {
    return exp2(scale * pos * pos);
}

// Sample the texture, and consider if we're in a scene transition (in the "rolling" part)
vec3 pixel(vec2 uv, vec2 off) {
    vec2 real_uv = uv;

    float transition_progress = value;
#if SOKOL_MSL
    float frag_progress = frag_pos.y / resolution.y;
#else
    float frag_progress = 1 - frag_pos.y / resolution.y;
#endif

    // Fragment is outside the transition animation
    if (frag_progress > transition_progress) discard;

    float roll_fraction = 0.2 * (1 - transition_progress);
    float distance_from_bottom = transition_progress - frag_progress;
    float roll_offset = distance_from_bottom/roll_fraction;
    bool in_roll = frag_progress >= transition_progress - roll_fraction;
    if (in_roll) {
        // TODO snap to pixel I guess?
        real_uv = vec2(uv.x, transition_progress + roll_fraction * warp(roll_offset));
    }

    vec2 pos = floor(real_uv * resolution + off) / resolution + vec2(0.5) / resolution;
    vec3 color = texture(sampler2D(tex, smp), pos).rgb;
    if (in_roll) {
        color = darken(roll_offset, color);
    }
    return color;
}

vec3 sample_line(vec2 pos, float off) {
    // NOTE: 0.99 should really be 1, but for some reason I get some artifacts
    // at pixel boundaries when I use it...
    vec3 b = pixel(pos, vec2(-0.99, off));
    vec3 c = pixel(pos, vec2(0.0, off));
    vec3 d = pixel(pos, vec2(0.99, off));
    float dst = dist(pos).x;

    float scale = -2;
    float wb = gaus(dst - 1.0, scale);
    float wc = gaus(dst + 0.0, scale);
    float wd = gaus(dst + 1.0, scale);

    return (b * wb + c * wc + d * wd) / (wb + wc + wd);
}

// Calculate scanline weight at given position
float scanline(vec2 pos, float off) {
    float dst = dist(pos).y;
    float strength = -8.0;
    return gaus(dst + off, strength);
}

// Sample color at given position based on the surrounding three lines
vec3 sample3(vec2 pos) {
    vec3 color = pixel(pos, vec2(0.0));
    if (scanline_amount > 0.0) {
        vec3 c1 = sample_line(pos, -1.0);
        vec3 c2 = sample_line(pos, 0.0);
        vec3 c3 = sample_line(pos, 1.0);

        float w1 = scanline(pos, -1.0);
        float w2 = scanline(pos, 0.0);
        float w3 = scanline(pos, 1.1);

        vec3 scanlines = c1 * w1 + c2 * w2 + c3 * w3;
        color = mix(color, scanlines, scanline_amount);
    }
    return color;
}

float vignette(vec2 uv){
	uv *= 1.0 - uv.xy;
	float vignette = uv.x * uv.y * 15.0;
	return pow(vignette, vignette_intensity * vignette_amount);
}

void main() {
    vec3 color = sample3(uv);

    if (aberration_amount > 0) {
        float chromatic = aberration_amount;
        vec2 chromatic_x = vec2(chromatic,0.0) / resolution.x;
        vec2 chromatic_y = vec2(0.0, chromatic/2.0) / resolution.y;
        float r = sample3(uv - chromatic_x).r;
        float g = sample3(uv + chromatic_y).g;
        float b = sample3(uv + chromatic_x).b;
        color = vec3(r,g,b);
    }

    color *= 1 + scanline_amount * 0.6;
    if(vignette_amount > 0.0) color *= vignette(uv);

    // Prevent banding in gradients
    color += (1.0 / 255.0) * gradientNoise(gl_FragCoord.xy) - (0.5 / 255.0);

    frag_color = vec4(color, 1);
}
@end

@program scene vs_scene fs_scene
