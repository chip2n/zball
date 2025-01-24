const std = @import("std");

pub const Vec4 = @Vector(4, f32);
pub const Mat4 = [4]@Vector(4, f32);

pub const Rect = GenRect(f32);
pub const IRect = GenRect(u32);

pub fn identity() Mat4 {
    return .{
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    };
}

pub fn translation(x: f32, y: f32, z: f32) Mat4 {
    return .{
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ x, y, z, 1.0 },
    };
}

pub fn scaling(x: f32, y: f32, z: f32) Mat4 {
    return .{
        .{ x, 0.0, 0.0, 0.0 },
        .{ 0.0, y, 0.0, 0.0 },
        .{ 0.0, 0.0, z, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    };
}

pub fn orthographicLh(w: f32, h: f32, near: f32, far: f32) Mat4 {
    const r = 1 / (far - near);
    return .{
        .{ 2 / w, 0.0, 0.0, 0.0 },
        .{ 0.0, 2 / h, 0.0, 0.0 },
        .{ 0.0, 0.0, r, 0.0 },
        .{ 0.0, 0.0, -r * near, 1.0 },
    };
}

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var c: Mat4 = undefined;
    comptime var m: u32 = 0;
    inline while (m < 4) : (m += 1) {
        c[m] = .{
            a[m][0] * b[0][0] + a[m][1] * b[1][0] + a[m][2] * b[2][0] + a[m][3] * b[3][0],
            a[m][0] * b[0][1] + a[m][1] * b[1][1] + a[m][2] * b[2][1] + a[m][3] * b[3][1],
            a[m][0] * b[0][2] + a[m][1] * b[1][2] + a[m][2] * b[2][2] + a[m][3] * b[3][2],
            a[m][0] * b[0][3] + a[m][1] * b[1][3] + a[m][2] * b[2][3] + a[m][3] * b[3][3],
        };
    }
    return c;
}

pub fn mulVecMat(v: Vec4, m: Mat4) Vec4 {
    return .{
        m[0][0] * v[0] + m[1][0] * v[1] + m[2][0] * v[2] + m[3][0] * v[3],
        m[0][1] * v[0] + m[1][1] * v[1] + m[2][1] * v[2] + m[3][1] * v[3],
        m[0][2] * v[0] + m[1][2] * v[1] + m[2][2] * v[2] + m[3][2] * v[3],
        m[0][3] * v[0] + m[1][3] * v[1] + m[2][3] * v[2] + m[3][3] * v[3],
    };
}

pub fn inverse(matrix: Mat4) ?Mat4 {
    const m: [16]f32 = @bitCast(matrix);
    var inv: [16]f32 = undefined;
    var result: [16]f32 = undefined;
    var det: f32 = 0.0;
    var i: usize = 0;

    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

    det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];

    if (det == 0) return null;

    det = 1.0 / det;

    while (i < 16) : (i += 1) {
        result[i] = inv[i] * det;
    }

    return @bitCast(result);
}

fn GenRect(comptime T: type) type {
    return struct {
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
