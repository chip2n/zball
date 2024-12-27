const std = @import("std");
const m = @import("math");
const Rect = m.Rect;

pub const CollisionInfo = struct {
    /// The center of the box moved as closely as possible to the other box
    pos: [2]f32,

    /// The collision normal
    normal: [2]f32,
};

pub fn collide(a: Rect, da: [2]f32, b: Rect, db: [2]f32) ?CollisionInfo {
    // Instead of calculating the intersection of two boxes, we calculate the
    // intersection of a larger box and a ray through Minkowski difference.
    // TODO use grow function
    const box = Rect{
        // .x = a.x,
        // .y = a.y,
        .x = a.x - b.w / 2,
        .y = a.y - b.h / 2,
        .w = a.w + b.w,
        .h = a.h + b.h,
    };
    const origin = .{ b.x + b.w / 2, b.y + b.h / 2 };
    const delta: [2]f32 = .{ db[0] - da[0], db[1] - da[1] };
    if (m.magnitude(delta) == 0) {
        // None of the boxes are moving, or they are moving at the same
        // speed. For our purposes, we can ignore this case and consider them
        // not colliding.
        return null;
    }
    var dir = delta;
    m.normalize(&dir);

    const result = boxRayIntersect(origin, dir, box) orelse return null;
    if (result.t >= m.magnitude(delta)) return null;
    return CollisionInfo{
        .pos = .{
            origin[0] + delta[0] * result.t,
            origin[1] + delta[1] * result.t,
        },
        .normal = result.normal,
    };
}

const BoxRayIntersectResult = struct {
    t: f32,
    normal: [2]f32,
};

fn boxRayIntersect(origin: [2]f32, dir: [2]f32, box: Rect) ?BoxRayIntersectResult {
    std.debug.assert(m.magnitude(dir) != 0);

    const dirfrac = .{ 1 / dir[0], 1 / dir[1] };
    const lb = .{ box.x, box.y };
    const rt = .{ box.x + box.w, box.y + box.h };

    const t1 = (lb[0] - origin[0]) * dirfrac[0];
    const t2 = (rt[0] - origin[0]) * dirfrac[0];
    const t3 = (lb[1] - origin[1]) * dirfrac[1];
    const t4 = (rt[1] - origin[1]) * dirfrac[1];
    const tmin = @max(@min(t1, t2), @min(t3, t4));
    const tmax = @min(@max(t1, t2), @max(t3, t4));

    if (tmin < 0) return null;
    if (tmax < 0) return null;
    if (tmin > tmax) return null;

    var result = BoxRayIntersectResult{ .t = tmin, .normal = .{ 0, 0 } };
    result.normal = blk: {
        if (result.t == t1) break :blk .{ -1, 0 };
        if (result.t == t2) break :blk .{ 1, 0 };
        if (result.t == t3) break :blk .{ 0, 1 };
        if (result.t == t4) break :blk .{ 0, -1 };
        unreachable;
    };

    return result;
}
