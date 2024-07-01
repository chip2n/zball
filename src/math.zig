pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn normalize(v: *[2]f32) void {
    const mag = magnitude(v.*);
    v[0] /= mag;
    v[1] /= mag;
}

pub fn magnitude(v: [2]f32) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1]);
}

pub fn vsub(v1: [2]f32, v2: [2]f32) [2]f32 {
    return .{
        v1[0] - v2[0],
        v1[1] - v2[1],
    };
}

pub fn vmul(v: [2]f32, s: f32) [2]f32 {
    return .{
        v[0] * s,
        v[1] * s,
    };
}

pub fn reflect(v: [2]f32, normal: [2]f32) [2]f32 {
    // d−2(d⋅n)n
    return vsub(v, vmul(normal, 2 * dot(v, normal)));
}

pub fn dot(v1: [2]f32, v2: [2]f32) f32 {
    return v1[0] * v2[0] + v1[1] * v2[1];
}

pub fn cross(v1: [2]f32, v2: [2]f32) f32 {
    return v1[0] * v2[1] - v1[1] * v2[0];
}
