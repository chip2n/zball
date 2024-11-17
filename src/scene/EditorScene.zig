const std = @import("std");
const sprite = @import("sprite");
const constants = @import("../constants.zig");
const input = @import("../input.zig");
const game = @import("../game.zig");
const shd = @import("shader");
const level = @import("../level.zig");
const m = @import("math");

const gfx = @import("../gfx.zig");
const ui = gfx.ui;
const Texture = gfx.texture.Texture;

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;

const Brick = game.Brick;
const brick_w = constants.brick_w;
const brick_h = constants.brick_h;

const EditorScene = @This();

allocator: std.mem.Allocator,

bricks: []Brick,
tex: Texture,
brush: sprite.Sprite = .brick1,

pub fn init(allocator: std.mem.Allocator) !EditorScene {
    const bricks = try allocator.alloc(Brick, 20 * 20);
    errdefer allocator.free(bricks);

    for (0..20) |y| {
        for (0..20) |x| {
            const i = y * 20 + x;
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            bricks[i] = Brick.init(fx, fy, .brick1);
            bricks[i].destroyed = true;
        }
    }

    const width = constants.viewport_size[0];
    const height = constants.viewport_size[1];
    const editor_texture_data = try allocator.alloc(u32, width * height);
    defer allocator.free(editor_texture_data);
    for (editor_texture_data) |*d| {
        d.* = 0x000000;
    }
    // Horizontal lines
    for (1..21) |y| {
        for (0..width) |x| {
            editor_texture_data[y * width * 8 + x] = 0x10FFFFFF;
        }
    }

    // Vertical lines
    for (1..20) |x| {
        for (0..height - 80) |y| {
            editor_texture_data[x * 16 + y * width] = 0x10FFFFFF;
        }
    }
    const tex = try gfx.texture.loadRGB8(.{
        .data = std.mem.sliceAsBytes(editor_texture_data),
        .width = width,
        .height = height,
        .usage = .mutable,
    });

    return EditorScene{
        .allocator = allocator,
        .bricks = bricks,
        .tex = tex,
    };
}

pub fn deinit(scene: *EditorScene) void {
    scene.allocator.free(scene.bricks);
}

pub fn frame(scene: *EditorScene, dt: f32) !void {
    _ = dt;

    input.showMouse(true);
    input.lockMouse(false);

    input: {
        const mouse_pos = input.mouse();
        if (mouse_pos[0] < 0) break :input;
        if (mouse_pos[1] < 0) break :input;

        const x: usize = @intFromFloat(mouse_pos[0]);
        const y: usize = @intFromFloat(mouse_pos[1]);

        const brick_x = x / 16;
        const brick_y = y / 8;
        if (brick_x >= 20) break :input;
        if (brick_y >= 20) break :input;

        var brick = &scene.bricks[brick_y * 20 + brick_x];
        if (input.down(.editor_draw)) {
            brick.sprite = scene.brush;
            brick.destroyed = false;
        }
        if (input.down(.editor_erase)) {
            brick.destroyed = true;
        }
        if (input.pressed(.editor_save)) {
            std.log.info("Saving level", .{});
            const file = try std.fs.createFileAbsolute("/tmp/out.lvl", .{});
            defer file.close();
            var data: [20 * 20]level.Brick = undefined;
            for (scene.bricks, 0..) |b, i| {
                var id: u8 = 0;
                if (!b.destroyed) {
                    id = try game.spriteToBrickId(b.sprite);
                }
                data[i] = .{ .id = id };
            }
            try level.writeLevel(&data, file.writer());
        }
    }

    // Render all bricks
    gfx.setTexture(gfx.spritesheetTexture());
    for (scene.bricks) |brick| {
        if (brick.destroyed) continue;
        const x = brick.pos[0];
        const y = brick.pos[1];
        const slice = sprite.get(brick.sprite);
        gfx.render(.{
            .src = m.irect(slice.bounds),
            .dst = .{ .x = x, .y = y, .w = brick_w, .h = brick_h },
        });
    }

    { // Render grid
        gfx.setTexture(scene.tex);
        const tex = try gfx.texture.get(scene.tex);
        gfx.render(.{
            .dst = .{ .x = 0, .y = 0, .w = @floatFromInt(tex.width), .h = @floatFromInt(tex.height) },
        });
    }

    { // Palette
        ui.begin(.{});
        defer ui.end();

        ui.beginWindow(.{
            .id = "palette",
            .x = 0,
            .y = constants.viewport_size[1] - 8,
            .style = .transparent,
        });
        defer ui.endWindow();

        const palette = [_]sprite.Sprite{ .brick1, .brick2, .brick3, .brick4 };
        for (palette) |s| {
            if (ui.sprite(.{ .sprite = s })) {
                scene.brush = s;
            }
            ui.sameLine();
        }
    }
}
