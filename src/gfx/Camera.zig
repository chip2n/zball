const m = @import("math");
const Mat4 = m.Mat4;

const Camera = @This();

pos: [2]f32,
viewport_size: [2]u32,
window_size: [2]u32,
proj: Mat4,
view: Mat4,
view_inv: Mat4,
view_proj: Mat4,
view_proj_inv: Mat4,

pub fn init(v: struct {
    pos: [2]f32 = .{ 0, 0 },
    viewport_size: [2]u32,
    window_size: [2]u32,
}) Camera {
    const proj = calculateProj(v.viewport_size);
    const view = calculateView(v.pos);
    const view_proj = m.mul(view, proj);
    return .{
        .pos = v.pos,
        .viewport_size = v.viewport_size,
        .window_size = v.window_size,
        .proj = proj,
        .view = view,
        .view_inv = m.inverse(view),
        .view_proj = view_proj,
        .view_proj_inv = m.inverse(view_proj),
    };
}

fn calculateProj(viewport_size: [2]u32) Mat4 {
    return m.orthographicRh(
        @floatFromInt(viewport_size[0]),
        @floatFromInt(viewport_size[1]),
        -10,
        10,
    );
}

fn calculateView(pos: [2]f32) Mat4 {
    return m.translation(-pos[0], -pos[1], 0);
}

pub fn invalidate(cam: *Camera) void {
    cam.view = calculateView(cam.pos);
    cam.view_inv = m.inverse(cam.view);
    cam.view_proj = m.mul(cam.view, cam.proj);
    cam.view_proj_inv = m.inverse(cam.view_proj);
}

/// Convert a screen coordinate into world space
pub fn screenToWorld(cam: Camera, p: [2]f32) [2]f32 {
    const win_w: f32 = @floatFromInt(cam.window_size[0]);
    const win_h: f32 = @floatFromInt(cam.window_size[1]);
    const win_aspect = win_w / win_h;

    const viewport_w: f32 = @floatFromInt(cam.viewport_size[0]);
    const viewport_h: f32 = @floatFromInt(cam.viewport_size[1]);
    const viewport_aspect = viewport_w / viewport_h;

    const clip_coords = blk: {
        if (win_aspect > viewport_aspect) {
            break :blk m.Vec4(
                (p[0] - win_w / 2) / (win_h * viewport_aspect / 2),
                -(p[1] - win_h / 2) / (win_h / 2),
                0,
                0,
            );
        }
        break :blk m.Vec4(
            (p[0] - win_w / 2) / (win_w / 2),
            -(p[1] - win_h / 2) / (win_w / viewport_aspect / 2),
            0,
            0,
        );
    };

    const result = m.mul(clip_coords, cam.view_proj_inv);
    return .{
        result[0] + cam.pos[0],
        // TODO Why do I need to invert this?
        viewport_h - (result[1] + cam.pos[1]),
    };
}

pub fn zoom(cam: Camera) f32 {
    const win_w: f32 = @floatFromInt(cam.window_size[0]);
    const win_h: f32 = @floatFromInt(cam.window_size[1]);
    const win_aspect = win_w / win_h;

    const viewport_w: f32 = @floatFromInt(cam.viewport_size[0]);
    const viewport_h: f32 = @floatFromInt(cam.viewport_size[1]);
    const viewport_aspect = viewport_w / viewport_h;

    if (win_aspect > viewport_aspect) {
        return win_h / viewport_h;
    } else {
        return win_w / viewport_w;
    }
}
