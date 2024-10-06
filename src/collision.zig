// TODO merge into math file

const m = @import("math");

// TODO separate from math rect
pub const Rect = struct {
    min: [2]f32,
    max: [2]f32,

    pub fn contains(self: Rect, p: [2]f32) bool {
        if (p[0] <= self.min[0] or p[0] >= self.max[0]) return false;
        if (p[1] <= self.min[1] or p[1] >= self.max[1]) return false;
        return true;
    }

    pub fn grow(self: *Rect, delta: [2]f32) void {
        self.min[0] -= delta[0];
        self.min[1] -= delta[1];
        self.max[0] += delta[0];
        self.max[1] += delta[1];
    }
};

// The angle depends on how far the ball is from the center of the paddle
// fn paddle_reflect(paddle_pos: f32, paddle_width: f32, ball_pos: [2]f32, ball_dir: [2]f32) [2]f32 {
//     const p = (paddle_pos - ball_pos[0]) / paddle_width;
//     var new_dir = [_]f32{ -p, -ball_dir[1] };
//     normalize(&new_dir);
//     return new_dir;
// }

// const CollisionInfo = struct {
//     t: f32,
//     pos: [2]f32,
//     normal: [2]f32,
// };

pub fn box_intersection(p0: [2]f32, p1: [2]f32, box: Rect, out: ?*[2]f32, normal: ?*[2]f32) bool {
    const min = box.min;
    const max = box.max;

    var t: f32 = m.magnitude(m.vsub(p0, p1));
    var collided = false;

    // Top
    if (line_intersection(p0, p1, .{ min[0], min[1] }, .{ max[0], min[1] }, out)) {
        const nt = m.magnitude(m.vsub(out.?.*, p0));
        if (nt < t) {
            t = nt;
            if (normal) |n| n.* = .{ 0, -1 };
            collided = true;
        }
    }
    // Left
    if (line_intersection(p0, p1, .{ min[0], min[1] }, .{ min[0], max[1] }, out)) {
        const nt = m.magnitude(m.vsub(out.?.*, p0));
        if (nt < t) {
            t = nt;
            if (normal) |n| n.* = .{ -1, 0 };
            collided = true;
        }
    }
    // Right
    if (line_intersection(p0, p1, .{ max[0], min[1] }, .{ max[0], max[1] }, out)) {
        const nt = m.magnitude(m.vsub(out.?.*, p0));
        if (nt < t) {
            t = nt;
            if (normal) |n| n.* = .{ 1, 0 };
            collided = true;
        }
    }
    // Bottom
    if (line_intersection(p0, p1, .{ min[0], max[1] }, .{ max[0], max[1] }, out)) {
        const nt = m.magnitude(m.vsub(out.?.*, p0));
        if (nt < t) {
            t = nt;
            if (normal) |n| n.* = .{ 0, 1 };
            collided = true;
        }
    }

    return collided;
}

pub fn line_intersection(
    p0: [2]f32,
    p1: [2]f32,
    p2: [2]f32,
    p3: [2]f32,
    out: ?*[2]f32,
) bool {
    const s1_x = p1[0] - p0[0];
    const s1_y = p1[1] - p0[1];
    const s2_x = p3[0] - p2[0];
    const s2_y = p3[1] - p2[1];

    const s = (-s1_y * (p0[0] - p2[0]) + s1_x * (p0[1] - p2[1])) / (-s2_x * s1_y + s1_x * s2_y);
    const t = (s2_x * (p0[1] - p2[1]) - s2_y * (p0[0] - p2[0])) / (-s2_x * s1_y + s1_x * s2_y);

    // NOTE: strictly less/greater than to avoid collision when p0 is on the
    // p2->p3 line (we move the ball to that position during a bounce)
    if (s > 0 and s < 1 and t > 0 and t < 1) {
        if (out) |o| {
            o.*[0] = p0[0] + (t * s1_x);
            o.*[1] = p0[1] + (t * s1_y);
        }
        return true;
    }

    return false;
}
