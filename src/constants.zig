const m = @import("math");

pub const viewport_size: [2]u32 = .{ 320, 240 };
pub const initial_screen_size = .{ viewport_size[0] * 3, viewport_size[1] * 3 };

// TODO read these from sprites
pub const brick_w = 17;
pub const brick_h = 10;

pub const brick_start_y = 8;

pub const initial_ball_dir: [2]f32 = blk: {
    var dir: [2]f32 = .{ 0.3, -1 };
    m.normalize(&dir);
    break :blk dir;
};

pub const max_quads = 4096;
pub const max_verts = max_quads * 6;
pub const offscreen_sample_count = 1;
pub const max_textures = 8;
pub const max_lights = 256;
