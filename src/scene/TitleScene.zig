const input = @import("../input.zig");
const game = @import("../game.zig");
const constants = @import("../constants.zig");
const utils = @import("../utils.zig");
const settings = @import("../settings.zig");
const sprite = @import("sprite");
const shd = @import("shader");
const m = @import("math");

const gfx = @import("../gfx.zig");
const ui = gfx.ui;

const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;

const TitleScene = @This();

idx: usize = 0,
settings_open: bool = false,

pub fn init() TitleScene {
    return .{};
}

pub fn frame(scene: *TitleScene, dt: f32) !void {
    _ = dt;
    input.showMouse(false);
    input.lockMouse(true);

    if (input.pressed(.back)) {
        scene.settings_open = false;
    }

    ui.begin(.{});
    defer ui.end();

    { // Footer
        ui.beginWindow(.{
            .id = "footer",
            .x = 8,
            .y = constants.viewport_size[1],
            .z = 10,
            .pivot = .{ 0, 1 },
            .style = .transparent,
        });
        defer ui.endWindow();
        ui.text("(C) 2024 - Andreas Arvidsson", .{});
    }

    { // Main menu
        ui.beginWindow(.{
            .id = "main",
            .x = constants.viewport_size[0] / 2,
            .y = constants.viewport_size[1] / 2 + 24,
            .z = 10,
            .pivot = .{ 0.5, 0.5 },
            .style = .transparent,
        });
        defer ui.endWindow();

        if (ui.selectionItem("Start", .{})) {
            game.scene_mgr.switchTo(.game);
        }
        if (ui.selectionItem("Settings", .{})) {
            scene.settings_open = true;
        }

        // We only support the editor on desktop builds (don't want to
        // deal with the browser intgration with the file system)
        if (!utils.is_web) {
            if (ui.selectionItem("Editor", .{})) {
                game.scene_mgr.switchTo(.editor);
            }
        }

        // Web builds cannot quit the game, only go to another page
        if (!utils.is_web) {
            if (ui.selectionItem("Quit", .{})) {
                sapp.quit();
            }
        }
    }

    if (scene.settings_open and settings.renderMenu()) {
        scene.settings_open = false;
    }

    // NOCOMMIT how do we want to access these textures?
    gfx.setTexture(gfx.spritesheetTexture());
    gfx.render(.{
        .src = m.irect(sprite.sprites.title.bounds),
        .dst = .{
            .x = 0,
            .y = 0,
            .w = constants.viewport_size[0],
            .h = constants.viewport_size[1],
        },
    });

    gfx.beginOffscreenPass();
    gfx.renderMain();
    gfx.endOffscreenPass();
}

pub fn deinit(scene: *TitleScene) void {
    _ = scene;
}
