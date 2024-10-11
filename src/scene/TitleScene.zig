const input = @import("../input.zig");
const state = @import("../state.zig");
const constants = @import("../constants.zig");
const utils = @import("../utils.zig");
const settings = @import("../settings.zig");
const sprite = @import("sprite");
const shd = @import("shader");

const gfx = @import("../gfx.zig");
const ui = gfx.ui;

const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;

const TitleScene = @This();

idx: usize = 0,
settings: bool = false,

pub fn init() TitleScene {
    return .{};
}

pub fn frame(scene: *TitleScene, dt: f32) !void {
    _ = dt;
    input.showMouse(false);
    input.lockMouse(true);

    // TODO this is in update, but gamescene menu is in render. maybe silly to break update/render up?
    try ui.begin(.{
        .batch = &state.batch,
        .tex_spritesheet = state.spritesheet_texture,
        .tex_font = state.font_texture,
    });
    defer ui.end();

    { // Footer
        try ui.beginWindow(.{
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
        try ui.beginWindow(.{
            .id = "main",
            .x = constants.viewport_size[0] / 2,
            .y = constants.viewport_size[1] / 2 + 24,
            .z = 10,
            .pivot = .{ 0.5, 0.5 },
            .style = .transparent,
        });
        defer ui.endWindow();

        if (ui.selectionItem("Start", .{})) {
            state.scene_mgr.switchTo(.game);
        }
        if (ui.selectionItem("Settings", .{})) {
            scene.settings = true;
        }

        // We only support the editor on desktop builds (don't want to
        // deal with the browser intgration with the file system)
        if (!utils.is_web) {
            if (ui.selectionItem("Editor", .{})) {
                state.scene_mgr.switchTo(.editor);
            }
        }

        // Web builds cannot quit the game, only go to another page
        if (!utils.is_web) {
            if (ui.selectionItem("Quit", .{})) {
                sapp.quit();
            }
        }
    }

    if (scene.settings and try settings.renderMenu()) {
        scene.settings = false;
    }

    state.batch.setTexture(state.spritesheet_texture);

    state.batch.render(.{
        .src = sprite.sprites.title.bounds,
        .dst = .{
            .x = 0,
            .y = 0,
            .w = constants.viewport_size[0],
            .h = constants.viewport_size[1],
        },
    });

    const vs_params = shd.VsParams{ .mvp = state.camera.view_proj };

    state.beginOffscreenPass();
    sg.applyPipeline(state.offscreen.pip);
    sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
    try state.renderBatch();
    sg.endPass();
}

pub fn handleInput(scene: *TitleScene, ev: sapp.Event) !void {
    if (scene.settings) {
        switch (ev.type) {
            .KEY_DOWN => {
                const action = input.identifyAction(ev.key_code) orelse return;
                switch (action) {
                    .back => scene.settings = false,
                    else => {},
                }
            },
            else => {},
        }
    }
}

pub fn deinit(scene: *TitleScene) void {
    _ = scene;
}
