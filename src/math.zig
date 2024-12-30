const std = @import("std");
const zm = @import("zmath");

pub const identity = zm.identity;
pub const translation = zm.translation;
pub const orthographicRh = zm.orthographicRh;
pub const orthographicLh = zm.orthographicLh;
pub const mul = zm.mul;
pub const Vec4 = zm.f32x4;
pub const Mat4 = zm.Mat;
pub const scaling = zm.scaling;
pub const inverse = zm.inverse;

pub const Rect = GenRect(f32);
pub const IRect = GenRect(u32);

fn GenRect(comptime T: type) type {
    return packed struct {
        const Self = @This();

        x: T,
        y: T,
        w: T,
        h: T,

        pub fn center(self: Self) [2]f32 {
            return .{ self.x + self.w / 2, self.y + self.h / 2 };
        }

        pub fn overlaps(self: Self, other: Self) bool {
            // Rectangle has area 0
            if (self.w == 0 or self.h == 0 or other.w == 0 or other.h == 0) return false;

            // One rectangle is on left side of other
            if (self.x >= (other.x + other.w) or other.x >= (self.x + self.w)) return false;

            // One rectangle is above other
            if (other.y >= (self.y + self.h) or self.y >= (other.y + other.h)) return false;

            return true;
        }

        pub fn containsPoint(self: Self, px: T, py: T) bool {
            if (px < self.x or px > self.x + self.w) return false;
            if (py < self.y or py > self.y + self.h) return false;
            return true;
        }

        pub fn grow(self: *Self, delta: [2]f32) void {
            self.x -= delta[0] / 2;
            self.y -= delta[1] / 2;
            self.w += delta[0];
            self.h += delta[1];
        }
    };
}

/// Helper to convert a rect-ish type to IRect (e.g. data from zig-aseprite-utils)
pub fn irect(r: anytype) IRect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

pub fn normalize(v: *[2]f32) void {
    const mag = magnitude(v.*);
    v[0] /= mag;
    v[1] /= mag;
}

pub fn magnitude(v: [2]f32) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1]);
}

pub fn veq(v1: [2]f32, v2: [2]f32) bool {
    return v1[0] == v2[0] and v1[1] == v2[1];
}

pub fn vadd(v1: [2]f32, v2: [2]f32) [2]f32 {
    return .{
        v1[0] + v2[0],
        v1[1] + v2[1],
    };
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

pub fn lerp(start: f32, end: f32, t: f32) f32 {
    return start * (1 - t) + end * t;
}
