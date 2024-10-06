const std = @import("std");
const sprite = @import("sprite");
const texture = @import("../texture.zig");
const Texture = texture.Texture;
const constants = @import("../constants.zig");
const input = @import("../input.zig");
const state = @import("../state.zig");
const ui = @import("../ui.zig");
const shd = @import("shader");
const level = @import("../level.zig");

const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;

const game = @import("../game.zig");
const Brick = game.Brick;
const ExplosionEmitter = game.ExplosionEmitter; // TODO should not be needed here

const brick_w = constants.brick_w;
const brick_h = constants.brick_h;

pub const EditorScene = struct {
    allocator: std.mem.Allocator,

    bricks: []Brick,
    tex: Texture,
    brush: sprite.Sprite = .brick1,

    inputs: struct {
        mouse_left_down: bool = false,
        mouse_right_down: bool = false,
    } = .{},

    pub fn init(allocator: std.mem.Allocator) !EditorScene {
        const bricks = try allocator.alloc(Brick, 20 * 20);
        errdefer allocator.free(bricks);

        // TODO reuse
        for (0..20) |y| {
            for (0..20) |x| {
                const i = y * 20 + x;
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                // TODO make intializer for bricks
                bricks[i] = .{
                    .pos = .{ fx * brick_w, fy * brick_h },
                    .sprite = .brick1,
                    .emitter = ExplosionEmitter.init(.{
                        .seed = @as(u64, @bitCast(std.time.milliTimestamp())),
                        .sprites = game.particleExplosionSprites(.brick1),
                    }),
                    .destroyed = true,
                };
            }
        }

        // TODO handle allocated memory properly
        const width = constants.viewport_size[0];
        const height = constants.viewport_size[1];
        const editor_texture_data = try allocator.alloc(u32, width * height);
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
        const tex = try texture.loadRGB8(.{
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
        input.showMouse(true);
        input.lockMouse(false);

        _ = dt; // autofix
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
            if (scene.inputs.mouse_left_down) {
                brick.sprite = scene.brush;
                brick.destroyed = false;
            }
            if (scene.inputs.mouse_right_down) {
                brick.destroyed = true;
            }
        }

        // const editor_texture = try texture.get(scene.tex);
        // if (x >= editor_texture.width) return;
        // if (y >= editor_texture.height) return;
        // try texture.draw(scene.tex, x, y);

        // Render all bricks
        // TODO refactor?
        state.batch.setTexture(state.spritesheet_texture);
        for (scene.bricks) |brick| {
            if (brick.destroyed) continue;
            const x = brick.pos[0];
            const y = brick.pos[1];
            const slice = sprite.get(brick.sprite);
            state.batch.render(.{
                .src = slice.bounds,
                .dst = .{ .x = x, .y = y, .w = brick_w, .h = brick_h },
            });
        }

        { // Render grid
            state.batch.setTexture(scene.tex);
            const tex = try texture.get(scene.tex);
            state.batch.render(.{
                .dst = .{ .x = 0, .y = 0, .w = @floatFromInt(tex.width), .h = @floatFromInt(tex.height) },
            });
        }

        { // Palette
            try ui.begin(.{
                .batch = &state.batch,
                .tex_spritesheet = state.spritesheet_texture,
                .tex_font = state.font_texture,
            });
            defer ui.end();

            try ui.beginWindow(.{
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

        const vs_params = shd.VsParams{ .mvp = state.camera.view_proj };
        state.beginOffscreenPass();
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
        try state.renderBatch();
        sg.endPass();
    }

    pub fn handleInput(scene: *EditorScene, ev: [*c]const sapp.Event) !void {
        switch (ev.*.type) {
            .MOUSE_DOWN => {
                switch (ev.*.mouse_button) {
                    .LEFT => scene.inputs.mouse_left_down = true,
                    .RIGHT => scene.inputs.mouse_right_down = true,
                    else => {},
                }
            },
            .MOUSE_UP => {
                switch (ev.*.mouse_button) {
                    .LEFT => scene.inputs.mouse_left_down = false,
                    .RIGHT => scene.inputs.mouse_right_down = false,
                    else => {},
                }
            },
            .KEY_DOWN => {
                const action = input.identifyAction(ev.*.key_code) orelse return;
                switch (action) {
                    .confirm => {
                        std.log.warn("SAVE", .{});
                        // TODO overwrite if already exists
                        const file = try std.fs.createFileAbsolute("/tmp/out.lvl", .{});
                        defer file.close();
                        // TODO stop with this 20 nonsense
                        var data: [20 * 20]level.Brick = undefined;
                        for (scene.bricks, 0..) |b, i| {
                            var id: u8 = 0;
                            if (!b.destroyed) {
                                id = try game.spriteToBrickId(b.sprite);
                            }
                            data[i] = .{ .id = id };
                        }
                        try level.writeLevel(&data, file.writer());
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};
