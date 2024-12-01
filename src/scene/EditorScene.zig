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

bricks: std.ArrayList(Brick),
brush: sprite.Sprite = .brick1a,

pub fn init(allocator: std.mem.Allocator) !EditorScene {
    var bricks = std.ArrayList(Brick).init(allocator);
    errdefer bricks.deinit();

    return EditorScene{
        .allocator = allocator,
        .bricks = bricks,
    };
}

pub fn deinit(scene: *EditorScene) void {
    scene.bricks.deinit();
}

pub fn frame(scene: *EditorScene, dt: f32) !void {
    _ = dt;

    input.showMouse(true);
    input.lockMouse(false);

    mouse_input: {
        const mouse_pos = input.mouse();
        if (mouse_pos[0] < 0) break :mouse_input;
        if (mouse_pos[1] < 0) break :mouse_input;

        const x: usize = @intFromFloat(mouse_pos[0]);
        const y: usize = @intFromFloat(mouse_pos[1]);

        if (input.down(.editor_draw)) {
            const brick = scene.getBrickAt(x, y);
            if (brick) |b| {
                b.sprite = scene.brush;
            } else {
                const pos = getBrickPosition(x, y);
                if (pos) |p| {
                    try scene.bricks.append(.{ .pos = p, .sprite = scene.brush });
                }
            }
        }
        if (input.down(.editor_erase)) {
            var brick = scene.getBrickAt(x, y) orelse break :mouse_input;
            brick.sprite = .brick0;
        }
    }
    if (input.pressed(.editor_save)) {
        std.log.info("Saving level", .{});
        try scene.saveLevel();
    }
    if (input.pressed(.editor_load)) {
        std.log.info("Loading level", .{});
        try scene.loadLevel();
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

    // Render "grid"
    const base_offset_x = (constants.viewport_size[0] - 18 * brick_w) / 2;
    const base_offset_y = base_offset_x; // for symmetry
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

            const slice = sprite.get(.brick0);
            gfx.render(.{
                .src = m.irect(slice.bounds),
                .dst = .{ .x = fx, .y = fy, .w = brick_w, .h = brick_h },
                .layer = .background,
            });
        }
    }

    // Render all bricks
    gfx.setTexture(gfx.spritesheetTexture());
    for (scene.bricks.items) |brick| {
        const x = brick.pos[0];
        const y = brick.pos[1];
        const slice = sprite.get(brick.sprite);
        gfx.render(.{
            .src = m.irect(slice.bounds),
            .dst = .{ .x = x, .y = y, .w = brick_w, .h = brick_h },
            .layer = if (brick.sprite == .brick0) .background else .main,
        });
        if (brick.sprite == .brick_expl) {
            // TODO refactor (used in game scene as well)
            gfx.addLight(
                .{ brick.pos[0] + brick_w / 2, brick.pos[1] + brick_h / 2 },
                0xf2a54c,
            );
        }
    }

    {
        ui.begin(.{});
        defer ui.end();

        { // Palette
            ui.beginWindow(.{
                .id = "palette",
                .x = 8,
                .y = constants.viewport_size[1] - 18,
                .style = .transparent,
            });
            defer ui.endWindow();

            const palette = [_]sprite.Sprite{ .brick1a, .brick2a, .brick3a, .brick4a, .brick_expl };
            for (palette) |s| {
                if (ui.sprite(.{ .sprite = s })) {
                    scene.brush = s;
                }
                ui.sameLine();
            }
        }

        { // Keys
            ui.beginWindow(.{
                .id = "info",
                .x = 104,
                .y = constants.viewport_size[1] - 16,
                .style = .transparent,
            });
            defer ui.endWindow();
            ui.text("F1: Save  F2: Load", .{});
        }
    }
}

fn getBrickAt(scene: *EditorScene, x: usize, y: usize) ?*Brick {
    for (scene.bricks.items) |*brick| {
        const bounds = m.Rect{ .x = brick.pos[0], .y = brick.pos[1], .w = brick_w, .h = brick_h };
        if (bounds.containsPoint(@floatFromInt(x), @floatFromInt(y))) {
            return brick;
        }
    }
    return null;
}

fn getBrickPosition(x: usize, y: usize) ?[2]f32 {
    const base_offset_x = (constants.viewport_size[0] - 18 * brick_w) / 2;
    const base_offset_y = base_offset_x; // for symmetry
    for (0..20) |j| {
        const count: usize = if (j % 2 == 0) 19 else 18; // staggered
        for (0..count) |i| {
            var offset_x: usize = base_offset_x;
            if (j % 2 == 1) {
                offset_x += brick_w / 2;
            }

            // Brick sprites are overlapping by a pixel
            const fx: f32 = @floatFromInt(i * brick_w - i + offset_x);
            const fy: f32 = @floatFromInt(j * brick_h - j + base_offset_y);

            const bounds = m.Rect{ .x = fx, .y = fy, .w = brick_w, .h = brick_h };
            if (bounds.containsPoint(@floatFromInt(x), @floatFromInt(y))) {
                return .{ fx, fy };
            }
        }
    }

    return null;
}

fn saveLevel(scene: *EditorScene) !void {
    const file = try std.fs.createFileAbsolute("/tmp/out.lvl", .{});
    defer file.close();

    var entities = std.ArrayList(LevelEntity).init(scene.allocator);
    defer entities.deinit();

    for (scene.bricks.items) |b| {
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

fn loadLevel(scene: *EditorScene) !void {
    const file = try std.fs.openFileAbsolute("/tmp/out.lvl", .{});
    defer file.close();

    const lvl = try level.readLevel(scene.allocator, file.reader());
    defer lvl.deinit();

    scene.bricks.clearAndFree();

    for (lvl.entities) |e| {
        try scene.bricks.append(.{
            .pos = .{ @floatFromInt(e.x), @floatFromInt(e.y) },
            .sprite = try game.brickIdToSprite(e.sprite),
        });
    }
}
