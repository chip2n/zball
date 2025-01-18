const std = @import("std");
const sprite = @import("sprites");
const input = @import("../input.zig");
const utils = @import("../utils.zig");
const audio = @import("../audio.zig");
const settings = @import("../settings.zig");
const level = @import("../level.zig");
const Level = level.Level;
const Game = @import("../Game.zig");
const zball = @import("../zball.zig");
const gfx = @import("../gfx.zig");
const ui = gfx.ui;
const m = @import("math");

const GameScene = @This();

allocator: std.mem.Allocator,
game_state: Game,
menu: GameMenu = .none,

// For slowdown effects (delta time is scaled by this factor)
time_scale: f32 = 1,

// When player clears the board, this timer is started. When it reaches zero, we
// switch to the next board (or the title screen, if the board cleared was the
// last one).
clear_timer: f32 = 0,

const GameMenu = enum { none, pause, settings };

pub fn init(allocator: std.mem.Allocator, lvl: Level, seed: u64) !GameScene {
    return GameScene{
        .allocator = allocator,
        .game_state = try Game.init(allocator, lvl, seed),
    };
}

pub fn deinit(scene: GameScene) void {
    scene.game_state.deinit();
}

pub fn frame(scene: *GameScene, dt: f32) !void {
    const game_dt = scene.time_scale * dt;

    switch (scene.menu) {
        .none => if (input.pressed(.back)) {
            scene.menu = .pause;
        },
        .pause => if (input.pressed(.back)) {
            scene.menu = .none;
        },
        .settings => if (input.pressed(.back)) {
            scene.menu = .pause;
        },
    }

    if (!scene.paused()) {
        input.showMouse(false);
        input.lockMouse(true);

        var game_input = input.State{};
        game_input.keys = input.state.keys;
        game_input.mouse_pos = input.mouse();
        game_input.mouse_delta = input.mouseDelta();

        // Make mouse movement feel sluggish when time is slowed down
        game_input.mouse_delta[0] *= scene.time_scale;
        game_input.mouse_delta[1] *= scene.time_scale;

        try scene.game_state.tick(game_dt, game_input);

        // Play any sound effects queued up
        for (scene.game_state.audio_clips.constSlice()) |c| {
            audio.play(c);
        }

        if (scene.game_state.lives == 0) {
            zball.scene_mgr.switchTo(.title);
        }

        if (scene.game_state.isCleared()) clear: {
            const clear_delay = 2.5;

            if (scene.clear_timer == 0) {
                scene.clear_timer = clear_delay;
            }

            if (!utils.tickDownTimer(scene, "clear_timer", dt)) {
                scene.time_scale = m.lerp(1, 0.1, 1 - (scene.clear_timer / clear_delay));
                break :clear;
            }

            if (zball.scene_mgr.level_idx < zball.scene_mgr.levels.len - 1) {
                zball.scene_mgr.level_idx += 1;
                zball.scene_mgr.switchTo(.game);
            } else {
                zball.scene_mgr.switchTo(.title);
            }
        }
    }

    // * Render

    // TODO should not have to do this
    gfx.setTexture(gfx.spritesheetTexture());

    { // Background
        gfx.setTexture(gfx.spritesheetTexture());
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

    { // Top bar
        for (0..scene.game_state.lives) |i| {
            const fi: f32 = @floatFromInt(i);
            const sp = sprite.sprites.ball_normal;
            gfx.render(.{
                .src = m.irect(sp.bounds),
                .dst = .{
                    .x = 2 + fi * (sp.bounds.w + 2),
                    .y = 2,
                    .w = sp.bounds.w,
                    .h = sp.bounds.h,
                },
            });
        }

        // Score
        const score = scene.game_state.score;
        // TODO have to always remember this when rendering text...
        gfx.setTexture(gfx.fontTexture());
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "score {:0>4}", .{score}) catch unreachable;
        gfx.renderText(label, 32, 0, 5);
    }

    gfx.setTexture(gfx.spritesheetTexture());

    // Render entities
    for (scene.game_state.entities) |e| {
        if (e.type == .none) continue;
        if (!e.rendered) continue;
        if (e.type == .ball) {
            if (e.flame.emitting) {
                gfx.addLight(e.center(), 0xf2a54c);
            }
        }
        if (e.type == .laser) {
            gfx.addLight(e.center(), 0x99E550);
        }
        if (e.type == .brick and e.sprite == .brick_expl) {
            gfx.addLight(e.center(), 0xf2a54c);
        }
        if (e.sprite) |s| {
            const sp = sprite.get(s);
            const dst = e.bounds();
            gfx.render(.{
                .src = m.irect(sp.bounds),
                .dst = dst,
                .layer = switch (e.type) {
                    .coin, .powerup => .particles,
                    else => .main,
                },
                .illuminated = switch (e.type) {
                    .laser => false,
                    else => true,
                },
            });
        }
    }

    { // Render paddle
        const sp = sprite.sprites.paddle;
        const bounds = scene.game_state.paddleBounds();
        gfx.renderNinePatch(.{
            .src = m.irect(sp.bounds),
            .center = m.irect(sp.center.?),
            .dst = bounds,
            .layer = .main,
        });
    }

    // Render the laser cannons, if active
    if (scene.game_state.laser_timer > 0) {
        const bounds = scene.game_state.paddleBounds();
        const left = sprite.sprites.laser_left;
        const right = sprite.sprites.laser_right;
        gfx.render(.{
            .src = m.irect(left.bounds),
            .dst = .{
                .x = bounds.x - 2,
                .y = bounds.y - 2,
                .w = left.bounds.w,
                .h = left.bounds.h,
            },
        });
        gfx.render(.{
            .src = m.irect(right.bounds),
            .dst = .{
                .x = bounds.x + bounds.w - right.bounds.w + 2,
                .y = bounds.y - 2,
                .w = right.bounds.w,
                .h = right.bounds.h,
            },
        });
    }

    // Render entity explosion particles
    for (scene.game_state.entities) |e| {
        gfx.renderEmitter(e.explosion);
    }

    // Render entity flame particles
    for (scene.game_state.entities) |e| {
        gfx.renderEmitter(e.flame);
    }

    { // Render game menus
        ui.begin(.{});
        defer ui.end();

        switch (scene.menu) {
            .none => {},
            .pause => {
                if (renderPauseMenu(&scene.menu)) {
                    zball.scene_mgr.switchTo(.title);
                }
            },
            .settings => {
                // We still "render" the pause menu, but flagging it as hidden to preserve its state
                if (renderPauseMenu(&scene.menu)) {
                    zball.scene_mgr.switchTo(.title);
                }
                if (settings.renderMenu()) {
                    scene.menu = .pause;
                }
            },
        }
    }
}

fn paused(scene: *GameScene) bool {
    return scene.menu != .none or zball.scene_mgr.next != null;
}

fn renderPauseMenu(menu: *GameMenu) bool {
    ui.beginWindow(.{
        .id = "pause",
        .x = zball.viewport_size[0] / 2,
        .y = zball.viewport_size[1] / 2,
        .pivot = .{ 0.5, 0.5 },
        .style = if (menu.* == .settings) .hidden else .dialog,
    });
    defer ui.endWindow();

    if (ui.selectionItem("Continue", .{})) {
        menu.* = .none;
    }
    if (ui.selectionItem("Settings", .{})) {
        menu.* = .settings;
    }
    if (ui.selectionItem("Quit", .{})) {
        return true;
    }

    return false;
}
