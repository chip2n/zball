const ui = @import("ui.zig");

const sokol = @import("sokol");
const sapp = sokol.app;

const TitleScene = struct {
    idx: usize = 0,
    settings: bool = false,

    fn init() TitleScene {
        showMouse(false);
        lockMouse(true);
        return .{};
    }

    fn update(scene: *TitleScene, dt: f32) !void {
        _ = dt;

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
                .y = viewport_size[1],
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
                .x = viewport_size[0] / 2,
                .y = viewport_size[1] / 2 + 24,
                .z = 10,
                .pivot = .{ 0.5, 0.5 },
                .style = .transparent,
            });
            defer ui.endWindow();

            if (ui.selectionItem("Start", .{})) {
                state.next_scene = .game;
            }
            if (ui.selectionItem("Settings", .{})) {
                scene.settings = true;
            }

            // We only support the editor on desktop builds (don't want to
            // deal with the browser intgration with the file system)
            if (!is_web) {
                if (ui.selectionItem("Editor", .{})) {
                    state.next_scene = .editor;
                }
            }

            // Web builds cannot quit the game, only go to another page
            if (!is_web) {
                if (ui.selectionItem("Quit", .{})) {
                    sapp.quit();
                }
            }
        }

        if (scene.settings and try renderSettingsMenu()) {
            scene.settings = false;
        }
    }

    fn render(scene: *TitleScene) !void {
        _ = scene;
        state.batch.setTexture(state.spritesheet_texture);

        state.batch.render(.{
            .src = sprite.sprites.title.bounds,
            .dst = .{
                .x = 0,
                .y = 0,
                .w = viewport_size[0],
                .h = viewport_size[1],
            },
        });

        const result = state.batch.commit();
        sg.updateBuffer(state.offscreen.bind.vertex_buffers[0], sg.asRange(result.verts));

        const vs_params = shd.VsParams{ .mvp = state.camera.view_proj };

        sg.beginPass(.{
            .action = state.offscreen.pass_action,
            .attachments = state.viewport.attachments,
        });
        sg.applyPipeline(state.offscreen.pip);
        sg.applyUniforms(.VS, shd.SLOT_vs_params, sg.asRange(&vs_params));
        for (result.batches) |b| {
            const tex = try texture.get(b.tex);
            state.offscreen.bind.fs.images[shd.SLOT_tex] = tex.img;
            sg.applyBindings(state.offscreen.bind);
            sg.draw(@intCast(b.offset), @intCast(b.len), 1);
        }
        sg.endPass();
    }

    fn input(scene: *TitleScene, ev: [*c]const sapp.Event) !void {
        if (scene.settings) {
            switch (ev.*.type) {
                .KEY_DOWN => {
                    switch (ev.*.key_code) {
                        .ESCAPE => scene.settings = false,
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    fn deinit(scene: *TitleScene) void {
        _ = scene;
    }
};
