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

const brick_w = constants.brick_w;
const brick_h = constants.brick_h;

const EditorScene = @This();

pub const Brick = struct {
    pos: [2]f32 = .{ 0, 0 },
    sprite: sprite.Sprite = .brick0,
};

const LevelEntity = level.LevelEntity;

allocator: std.mem.Allocator,

bricks: []Brick,
brush: sprite.Sprite = .brick1a,

pub fn init(allocator: std.mem.Allocator) !EditorScene {
    var bricks = std.ArrayList(Brick).init(allocator);
    errdefer bricks.deinit();

    const base_offset_x = (constants.viewport_size[0] - 18 * brick_w) / 2;
    const base_offset_y = base_offset_x; // for symmetry
    var i: usize = 0;
    for (0..20) |y| {
        const count: usize = if (y % 2 == 0) 19 else 18; // staggered
        for (0..count) |x| {
            var offset_x: usize = base_offset_x;
            if (y % 2 == 1) {
                offset_x += brick_w / 2;
            }

            // Brick sprites are overlapping by a pixel
            const fx: f32 = @floatFromInt(x * brick_w - x + offset_x);
            const fy: f32 = @floatFromInt(y * brick_h - y + base_offset_y);
            try bricks.append(Brick{ .pos = .{ fx, fy } });

            i += 1;
        }
    }

    return EditorScene{
        .allocator = allocator,
        .bricks = try bricks.toOwnedSlice(),
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

        var brick = scene.getBrickAt(x, y) orelse break :input;

        if (input.down(.editor_draw)) {
            brick.sprite = scene.brush;
        }
        if (input.down(.editor_erase)) {
            brick.sprite = .brick0;
        }
        if (input.pressed(.editor_save)) {
            std.log.info("Saving level", .{});
            try scene.saveLevel();
        }
    }

    { // Background
        gfx.setTexture(gfx.spritesheetTexture());
        const sp = sprite.sprites.bg;
        gfx.render(.{
            .src = m.irect(sp.bounds),
            .dst = .{
                .x = 0,
                .y = 0,
                .w = constants.viewport_size[0],
                .h = constants.viewport_size[1],
            },
            .layer = .background,
        });
    }

    // Render all bricks
    gfx.setTexture(gfx.spritesheetTexture());
    for (scene.bricks) |brick| {
        const x = brick.pos[0];
        const y = brick.pos[1];
        const slice = sprite.get(brick.sprite);
        gfx.render(.{
            .src = m.irect(slice.bounds),
            .dst = .{ .x = x, .y = y, .w = brick_w, .h = brick_h },
            .layer = if (brick.sprite == .brick0) .background else .main,
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

        const palette = [_]sprite.Sprite{ .brick1a, .brick2a, .brick3a, .brick4a };
        for (palette) |s| {
            if (ui.sprite(.{ .sprite = s })) {
                scene.brush = s;
            }
            ui.sameLine();
        }
    }
}

fn getBrickAt(scene: *EditorScene, x: usize, y: usize) ?*Brick {
    for (scene.bricks) |*brick| {
        const bounds = m.Rect{ .x = brick.pos[0], .y = brick.pos[1], .w = brick_w, .h = brick_h };
        if (bounds.containsPoint(@floatFromInt(x), @floatFromInt(y))) {
            return brick;
        }
    }
    return null;
}

fn saveLevel(scene: *EditorScene) !void {
    const file = try std.fs.createFileAbsolute("/tmp/out.lvl", .{});
    defer file.close();

    var entities = std.ArrayList(LevelEntity).init(scene.allocator);
    defer entities.deinit();

    for (scene.bricks) |b| {
        if (b.sprite == .brick0) continue;
        try entities.append(.{
            .type = .brick,
            .x = @intFromFloat(b.pos[0]),
            .y = @intFromFloat(b.pos[1]),
            .sprite = try game.spriteToBrickId(b.sprite),
        });
    }
    try level.writeLevel(entities.items, file.writer());
}
