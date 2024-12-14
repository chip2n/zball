const std = @import("std");
const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

pub const SpriteData = struct {
    name: []const u8,
    bounds: Rect,
    center: ?Rect = null,
};
const sprite_arr = std.enums.EnumArray(Sprite, SpriteData).init(sprites);
pub fn get(sprite: Sprite) SpriteData {
    return sprite_arr.get(sprite);
}
pub const Sprite = enum {
    dialog,
    title,
    ball_normal,
    overlay,
    slider_thumb,
    slider_rail_active,
    slider_rail_inactive,
    powerup_split,
    powerup_flame,
    particle_flame_3,
    particle_flame_5,
    particle_flame_2,
    particle_flame_1,
    particle_flame_6,
    particle_flame_4,
    pow_laser,
    pow_flame,
    pow_scatter,
    pow_fork,
    pow_paddlesizeup,
    pow_paddlesizedown,
    pow_magnet,
    pow_ballsizedown,
    pow_ballsizeup,
    pow_ballspeedup,
    pow_ballspeeddown,
    particle_laser,
    winicon8,
    winicon16,
    winicon32,
    paddle,
    laser_left,
    laser_right,
    ball_smaller,
    ball_smallest,
    ball_larger,
    ball_largest,
    pow_death,
    bg,
    brick1a,
    brick1b,
    brick2a,
    brick2b,
    brick3a,
    brick3b,
    brick4a,
    brick4b,
    brick0,
    brick_expl,
    brick_metal,
    brick_metal_weak,
    brick_metal_weak2,
    brick_metal_weak3,
    text_input,
};
pub const sprites: std.enums.EnumFieldStruct(Sprite, SpriteData, null) = .{
    .dialog = SpriteData{
        .name = "dialog",
        .bounds = .{ .x = 161, .y = 0, .w = 10, .h = 10 },
        .center = .{ .x = 2, .y = 2, .w = 4, .h = 4 },
    },
    .title = SpriteData{
        .name = "title",
        .bounds = .{ .x = 0, .y = 0, .w = 160, .h = 120 },
    },
    .ball_normal = SpriteData{
        .name = "ball_normal",
        .bounds = .{ .x = 169, .y = 14, .w = 4, .h = 4 },
    },
    .overlay = SpriteData{
        .name = "overlay",
        .bounds = .{ .x = 191, .y = 11, .w = 1, .h = 1 },
    },
    .slider_thumb = SpriteData{
        .name = "slider_thumb",
        .bounds = .{ .x = 194, .y = 11, .w = 4, .h = 5 },
    },
    .slider_rail_active = SpriteData{
        .name = "slider_rail_active",
        .bounds = .{ .x = 199, .y = 13, .w = 1, .h = 1 },
    },
    .slider_rail_inactive = SpriteData{
        .name = "slider_rail_inactive",
        .bounds = .{ .x = 201, .y = 13, .w = 1, .h = 1 },
    },
    .powerup_split = SpriteData{
        .name = "powerup_split",
        .bounds = .{ .x = 205, .y = 9, .w = 16, .h = 8 },
    },
    .powerup_flame = SpriteData{
        .name = "powerup_flame",
        .bounds = .{ .x = 222, .y = 9, .w = 16, .h = 8 },
    },
    .particle_flame_3 = SpriteData{
        .name = "particle_flame_3",
        .bounds = .{ .x = 242, .y = 11, .w = 3, .h = 3 },
    },
    .particle_flame_5 = SpriteData{
        .name = "particle_flame_5",
        .bounds = .{ .x = 246, .y = 15, .w = 5, .h = 5 },
    },
    .particle_flame_2 = SpriteData{
        .name = "particle_flame_2",
        .bounds = .{ .x = 251, .y = 13, .w = 1, .h = 1 },
    },
    .particle_flame_1 = SpriteData{
        .name = "particle_flame_1",
        .bounds = .{ .x = 251, .y = 11, .w = 1, .h = 1 },
    },
    .particle_flame_6 = SpriteData{
        .name = "particle_flame_6",
        .bounds = .{ .x = 245, .y = 3, .w = 6, .h = 6 },
    },
    .particle_flame_4 = SpriteData{
        .name = "particle_flame_4",
        .bounds = .{ .x = 246, .y = 10, .w = 4, .h = 4 },
    },
    .pow_laser = SpriteData{
        .name = "pow_laser",
        .bounds = .{ .x = 161, .y = 37, .w = 13, .h = 13 },
    },
    .pow_flame = SpriteData{
        .name = "pow_flame",
        .bounds = .{ .x = 175, .y = 37, .w = 13, .h = 13 },
    },
    .pow_scatter = SpriteData{
        .name = "pow_scatter",
        .bounds = .{ .x = 161, .y = 51, .w = 13, .h = 13 },
    },
    .pow_fork = SpriteData{
        .name = "pow_fork",
        .bounds = .{ .x = 175, .y = 51, .w = 13, .h = 13 },
    },
    .pow_paddlesizeup = SpriteData{
        .name = "pow_paddlesizeup",
        .bounds = .{ .x = 161, .y = 65, .w = 13, .h = 13 },
    },
    .pow_paddlesizedown = SpriteData{
        .name = "pow_paddlesizedown",
        .bounds = .{ .x = 175, .y = 65, .w = 13, .h = 13 },
    },
    .pow_magnet = SpriteData{
        .name = "pow_magnet",
        .bounds = .{ .x = 161, .y = 79, .w = 13, .h = 13 },
    },
    .pow_ballsizedown = SpriteData{
        .name = "pow_ballsizedown",
        .bounds = .{ .x = 175, .y = 79, .w = 13, .h = 13 },
    },
    .pow_ballsizeup = SpriteData{
        .name = "pow_ballsizeup",
        .bounds = .{ .x = 161, .y = 93, .w = 13, .h = 13 },
    },
    .pow_ballspeedup = SpriteData{
        .name = "pow_ballspeedup",
        .bounds = .{ .x = 175, .y = 93, .w = 13, .h = 13 },
    },
    .pow_ballspeeddown = SpriteData{
        .name = "pow_ballspeeddown",
        .bounds = .{ .x = 161, .y = 107, .w = 13, .h = 13 },
    },
    .particle_laser = SpriteData{
        .name = "particle_laser",
        .bounds = .{ .x = 247, .y = 23, .w = 3, .h = 9 },
    },
    .winicon8 = SpriteData{
        .name = "winicon8",
        .bounds = .{ .x = 208, .y = 32, .w = 8, .h = 8 },
    },
    .winicon16 = SpriteData{
        .name = "winicon16",
        .bounds = .{ .x = 208, .y = 41, .w = 16, .h = 16 },
    },
    .winicon32 = SpriteData{
        .name = "winicon32",
        .bounds = .{ .x = 208, .y = 58, .w = 32, .h = 32 },
    },
    .paddle = SpriteData{
        .name = "paddle",
        .bounds = .{ .x = 212, .y = 98, .w = 24, .h = 7 },
        .center = .{ .x = 2, .y = 0, .w = 20, .h = 7 },
    },
    .laser_left = SpriteData{
        .name = "laser_left",
        .bounds = .{ .x = 211, .y = 108, .w = 5, .h = 9 },
    },
    .laser_right = SpriteData{
        .name = "laser_right",
        .bounds = .{ .x = 218, .y = 108, .w = 5, .h = 9 },
    },
    .ball_smaller = SpriteData{
        .name = "ball_smaller",
        .bounds = .{ .x = 165, .y = 14, .w = 3, .h = 3 },
    },
    .ball_smallest = SpriteData{
        .name = "ball_smallest",
        .bounds = .{ .x = 162, .y = 14, .w = 2, .h = 2 },
    },
    .ball_larger = SpriteData{
        .name = "ball_larger",
        .bounds = .{ .x = 174, .y = 14, .w = 6, .h = 6 },
    },
    .ball_largest = SpriteData{
        .name = "ball_largest",
        .bounds = .{ .x = 181, .y = 14, .w = 7, .h = 7 },
    },
    .pow_death = SpriteData{
        .name = "pow_death",
        .bounds = .{ .x = 175, .y = 107, .w = 13, .h = 13 },
    },
    .bg = SpriteData{
        .name = "bg",
        .bounds = .{ .x = 192, .y = 18, .w = 1, .h = 1 },
    },
    .brick1a = SpriteData{
        .name = "brick1a",
        .bounds = .{ .x = 180, .y = 135, .w = 17, .h = 10 },
    },
    .brick1b = SpriteData{
        .name = "brick1b",
        .bounds = .{ .x = 180, .y = 146, .w = 17, .h = 10 },
    },
    .brick2a = SpriteData{
        .name = "brick2a",
        .bounds = .{ .x = 198, .y = 135, .w = 17, .h = 10 },
    },
    .brick2b = SpriteData{
        .name = "brick2b",
        .bounds = .{ .x = 198, .y = 146, .w = 17, .h = 10 },
    },
    .brick3a = SpriteData{
        .name = "brick3a",
        .bounds = .{ .x = 216, .y = 135, .w = 17, .h = 10 },
    },
    .brick3b = SpriteData{
        .name = "brick3b",
        .bounds = .{ .x = 216, .y = 146, .w = 17, .h = 10 },
    },
    .brick4a = SpriteData{
        .name = "brick4a",
        .bounds = .{ .x = 234, .y = 135, .w = 17, .h = 10 },
    },
    .brick4b = SpriteData{
        .name = "brick4b",
        .bounds = .{ .x = 234, .y = 146, .w = 17, .h = 10 },
    },
    .brick0 = SpriteData{
        .name = "brick0",
        .bounds = .{ .x = 180, .y = 159, .w = 17, .h = 10 },
    },
    .brick_expl = SpriteData{
        .name = "brick_expl",
        .bounds = .{ .x = 198, .y = 159, .w = 17, .h = 10 },
    },
    .brick_metal = SpriteData{
        .name = "brick_metal",
        .bounds = .{ .x = 216, .y = 159, .w = 17, .h = 10 },
    },
    .brick_metal_weak = SpriteData{
        .name = "brick_metal_weak",
        .bounds = .{ .x = 216, .y = 170, .w = 17, .h = 10 },
    },
    .brick_metal_weak2 = SpriteData{
        .name = "brick_metal_weak2",
        .bounds = .{ .x = 216, .y = 181, .w = 17, .h = 10 },
    },
    .brick_metal_weak3 = SpriteData{
        .name = "brick_metal_weak3",
        .bounds = .{ .x = 216, .y = 192, .w = 17, .h = 10 },
    },
    .text_input = SpriteData{
        .name = "text_input",
        .bounds = .{ .x = 176, .y = 1, .w = 3, .h = 3 },
        .center = .{ .x = 1, .y = 1, .w = 1, .h = 1 },
    },
};
