const std = @import("std");
const m = @import("math");

pub const viewport_size: [2]u32 = .{ 320, 240 };
pub const initial_screen_size = .{ viewport_size[0] * 3, viewport_size[1] * 3 };

pub const paddle_speed: f32 = 180;
pub const ball_base_speed: f32 = 200;
pub const ball_speed_min: f32 = 100;
pub const ball_speed_max: f32 = 300;
pub const max_balls = 32;
pub const max_entities = 1024;
pub const coin_freq = 0.4;
pub const powerup_freq = 0.1;

/// Prevents two drops being spawned back-to-back in a quick succession
pub const drop_spawn_cooldown = 0.5;

pub const flame_duration = 5;
pub const laser_duration = 5;
pub const laser_speed = 300;
pub const laser_cooldown = 0.2;

pub const gravity = 400;
pub const terminal_velocity = 300;

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

comptime {
    std.debug.assert(coin_freq + powerup_freq <= 1);
}

