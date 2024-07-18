const std = @import("std");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn overlaps(self: Rect, other: Rect) bool {
        // Rectangle has area 0
        if (self.w == 0 or self.h == 0 or other.w == 0 or other.h == 0) return false;

        // One rectangle is on left side of other
        if (self.x >= (other.x + other.w) or other.x >= (self.x + self.w)) return false;

        // One rectangle is above other
        if (other.y >= (self.y + self.h) or self.y >= (other.y + other.h)) return false;

        return true;
    }
};

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

pub fn vrot(v: *[2]f32, rad: f32) void {
    const x = v[0] * @cos(rad) - v[1] * @sin(rad);
    const y = v[0] * @sin(rad) + v[1] * @cos(rad);
    v[0] = x;
    v[1] = y;
}

/// Calculate angle between two vectors
pub fn vangle(v1: [2]f32, v2: [2]f32) f32 {
    // θ=atan2(w2​v1​ − w1​v2​, w1​v1 ​+ w2​v2​)
    return std.math.atan2(
        v2[1] * v1[0] - v2[0] * v1[1],
        v2[0] * v1[0] + v2[1] * v1[1],
    );
}
