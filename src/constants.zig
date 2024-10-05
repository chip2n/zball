const m = @import("math");

pub const initial_screen_size = .{ 640, 480 };
pub const viewport_size: [2]u32 = .{ 320, 240 };

// TODO read these from sprites
pub const brick_w = 16;
pub const brick_h = 8;

pub const brick_start_y = 8;

pub const initial_ball_dir: [2]f32 = blk: {
    var dir: [2]f32 = .{ 0.3, -1 };
    m.normalize(&dir);
    break :blk dir;
};
