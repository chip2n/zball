const std = @import("std");
const constants = @import("../constants.zig");
const m = @import("math");
const Mat4 = m.Mat4;

const Camera = @This();

win_size: [2]u32,
view: Mat4,
proj: Mat4,
view_proj: Mat4,
view_proj_inv: Mat4,

pub fn init(v: struct {
    win_size: [2]u32,
}) Camera {
    const view = calculateView(v.win_size[0], v.win_size[1]);
    const proj = calculateProj(v.win_size[0], v.win_size[1]);
    const view_proj = m.mul(view, proj);
    return .{
        .win_size = v.win_size,
        .view = view,
        .proj = proj,
        .view_proj = view_proj,
        .view_proj_inv = m.inverse(view_proj),
    };
}

pub fn invalidate(cam: *Camera) void {
    cam.proj = calculateProj(cam.win_size[0], cam.win_size[1]);
    cam.view = calculateView(cam.win_size[0], cam.win_size[1]);
    cam.view_proj = m.mul(cam.view, cam.proj);
    cam.view_proj_inv = m.inverse(cam.view_proj);
}

fn calculateView(width: u32, height: u32) Mat4 {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const vw: f32 = @floatFromInt(constants.viewport_size[0]);
    const vh: f32 = @floatFromInt(constants.viewport_size[1]);
    const scale = @min(@floor(w / vw), @floor(h / vh));

    // Never place view at an uneven position
    var offset_x: f32 = @rem(w, 2) / 2;
    var offset_y: f32 = @rem(h, 2) / 2;
    offset_x -= (vw * scale) / 2;
    offset_y -= (vh * scale) / 2;

    var view = m.translation(offset_x, offset_y, 0);
    view = m.mul(m.scaling(scale, scale, 1), view);
    return view;
}

fn calculateProj(width: u32, height: u32) Mat4 {
    return m.orthographicLh(@floatFromInt(width), @floatFromInt(height), 0, 10);
}

pub fn screenToWorld(cam: Camera, p: [2]f32) [2]f32 {
    const w: f32 = @floatFromInt(cam.win_size[0]);
    const h: f32 = @floatFromInt(cam.win_size[1]);
    const mx = 2 * p[0] / w - 1;
    const my = (2 * p[1] / h - 1);
    const result = m.mul(@Vector(4, f32){ mx, my, 0, 1 }, cam.view_proj_inv);
    return .{ result[0], result[1] };
}

pub fn zoom(cam: Camera) f32 {
    const w: f32 = @floatFromInt(cam.win_size[0]);
    const h: f32 = @floatFromInt(cam.win_size[1]);
    const vw: f32 = @floatFromInt(constants.viewport_size[0]);
    const vh: f32 = @floatFromInt(constants.viewport_size[1]);
    return @min(@floor(w / vw), @floor(h / vh));
}
