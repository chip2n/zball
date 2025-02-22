const std = @import("std");
const sprite = @import("sprites");
const input = @import("../input.zig");
const zball = @import("../zball.zig");
const shd = @import("shader");
const level = @import("../level.zig");
const m = @import("math");
const utils = @import("../utils.zig");

const gfx = @import("../gfx.zig");
const ui = gfx.ui;
const Texture = gfx.texture.Texture;

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;

const brick_w = zball.brick_w;
const brick_h = zball.brick_h;

const EditorScene = @This();

pub const Brick = struct {
    pos: [2]f32 = .{ 0, 0 },
    sprite: sprite.Sprite = .brick0,
};

const LevelEntity = level.LevelEntity;

allocator: std.mem.Allocator,

bricks: std.ArrayList(Brick),
brush: sprite.Sprite = .brick1a,
show_save_dialog: bool = false,
show_load_dialog: bool = false,
dialog_buf: [128]u8,

pub fn init(allocator: std.mem.Allocator) !EditorScene {
    var bricks = std.ArrayList(Brick).init(allocator);
    errdefer bricks.deinit();

    // Default dialog path is current working directory
    var dialog_buf: [128]u8 = std.mem.zeroes([128]u8);
    if (!utils.is_web) {
        _ = try std.fs.cwd().realpath(".", &dialog_buf);
    }

    return EditorScene{
        .allocator = allocator,
        .bricks = bricks,
        .dialog_buf = dialog_buf,
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
        scene.show_save_dialog = true;
        scene.show_load_dialog = false;
    }
    if (input.pressed(.editor_load)) {
        scene.show_save_dialog = false;
        scene.show_load_dialog = true;
    }
    if (input.pressed(.back)) {
        if (scene.show_save_dialog or scene.show_load_dialog) {
            scene.show_save_dialog = false;
            scene.show_load_dialog = false;
        } else {
            zball.scene_mgr.switchTo(.title);
        }
    }

    { // Background
        const sp = sprite.sprites.bg;
        gfx.render(.{
            .src = m.irect(sp.bounds),
            .dst = .{
                .x = 0,
                .y = 0,
                .w = zball.viewport_size[0],
                .h = zball.viewport_size[1],
            },
            .layer = .background,
        });
    }

    // Render "grid"
    const base_offset_x = (zball.viewport_size[0] - 18 * brick_w) / 2;
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
            gfx.addLight(
                .{ brick.pos[0] + brick_w / 2, brick.pos[1] + brick_h / 2 },
                0xf2a54c,
            );
        }
    }

    const brick_ids = comptime std.enums.values(zball.BrickId);
    var palette: [brick_ids.len]sprite.Sprite = undefined;
    var palette_width: usize = 0;
    inline for (brick_ids, 0..) |id, i| {
        const sp = id.sprites()[0];
        palette[i] = sp;
        palette_width += sprite.get(sp).bounds.w;
    }

    {
        ui.begin(.{});
        defer ui.end();

        { // Palette
            ui.beginWindow(.{
                .id = "palette",
                .x = 8,
                .y = zball.viewport_size[1] - 18,
                .style = .transparent,
            });
            defer ui.endWindow();

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
                .x = @floatFromInt(palette_width + 16),
                .y = zball.viewport_size[1] - 16,
                .style = .transparent,
            });
            defer ui.endWindow();
            ui.text("F1: Save  F2: Load", .{});
        }

        { // Dialogs
            if (scene.show_save_dialog) {
                ui.beginWindow(.{
                    .id = "save",
                    .x = zball.viewport_size[0] / 2,
                    .y = zball.viewport_size[1] / 2,
                    .z = 20,
                    .pivot = .{ 0.5, 0.5 },
                });
                defer ui.endWindow();

                ui.text("Save level", .{});
                if (ui.textInput(.{ .text = &scene.dialog_buf })) |path| {
                    scene.saveLevel(path) catch |err| {
                        switch (err) {
                            error.IsDir => std.log.err("You need to specify a file for the level, not a directory.", .{}),
                            else => std.log.err("Unable to save level: {}", .{err}),
                        }
                    };
                    scene.show_save_dialog = false;
                }
            }
            if (scene.show_load_dialog) {
                ui.beginWindow(.{
                    .id = "load",
                    .x = zball.viewport_size[0] / 2,
                    .y = zball.viewport_size[1] / 2,
                    .z = 20,
                    .pivot = .{ 0.5, 0.5 },
                });
                defer ui.endWindow();

                ui.text("Load level", .{});
                if (ui.textInput(.{ .text = &scene.dialog_buf })) |path| {
                    scene.loadLevel(path) catch |err| {
                        switch (err) {
                            error.IsDir => std.log.err("You need to specify a file for the level, not a directory.", .{}),
                            else => std.log.err("Unable to load level: {}", .{err}),
                        }
                    };
                    scene.show_load_dialog = false;
                }
            }
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
    const base_offset_x = (zball.viewport_size[0] - 18 * brick_w) / 2;
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

fn saveLevel(scene: *EditorScene, path: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    var entities = std.ArrayList(LevelEntity).init(scene.allocator);
    defer entities.deinit();

    for (scene.bricks.items) |b| {
        if (b.sprite == .brick0) continue;
        const id = try zball.spriteToBrickId(b.sprite);
        try entities.append(.{
            .type = .brick,
            .x = @intFromFloat(b.pos[0]),
            .y = @intFromFloat(b.pos[1]),
            .sprite = @intFromEnum(id),
        });
    }
    try level.writeLevel(entities.items, file.writer());
}

fn loadLevel(scene: *EditorScene, path: []const u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const lvl = try level.readLevel(scene.allocator, file.reader());
    defer lvl.deinit();

    scene.bricks.clearAndFree();

    for (lvl.entities) |e| {
        const id = try zball.BrickId.parse(e.sprite);
        try scene.bricks.append(.{
            .pos = .{ @floatFromInt(e.x), @floatFromInt(e.y) },
            .sprite = zball.brickIdToSprite(id),
        });
    }
}
