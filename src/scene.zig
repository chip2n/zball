const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;

const level = @import("level.zig");
const Level = level.Level;

// TODO
const main = @import("main.zig");
const TitleScene = @import("scene/title.zig").TitleScene;
const GameScene = main.GameScene;
const EditorScene = @import("scene/editor.zig").EditorScene;

const transition_duration = 2;

const SceneType = std.meta.Tag(Scene);

const Scene = union(enum) {
    title: TitleScene,
    game: GameScene,
    editor: EditorScene,

    fn init(scene: *Scene) void {
        switch (scene.*) {
            inline else => |*impl| impl.init(),
        }
    }

    fn deinit(scene: *Scene) void {
        switch (scene.*) {
            inline else => |*impl| impl.deinit(),
        }
    }

    fn frame(scene: *Scene, dt: f32) !void {
        switch (scene.*) {
            inline else => |*impl| try impl.frame(dt),
        }
    }

    // TODO: Could be handled separately and fetched in frame()
    fn handleInput(scene: *Scene, ev: [*c]const sapp.Event) !void {
        switch (scene.*) {
            inline else => |*impl| try impl.handleInput(ev),
        }
    }
};

pub const SceneManager = struct {
    allocator: std.mem.Allocator,
    current: Scene,
    next: ?Scene = null,
    transition_progress: f32 = 0,
    level_idx: usize = 0,
    levels: []Level,
    rendering_next: bool = false,

    // TODO: Do we actually need the allocator?
    pub fn init(
        allocator: std.mem.Allocator,
        levels: []Level,
    ) SceneManager {
        var mgr = SceneManager{
            .allocator = allocator,
            .current = undefined,
            .levels = levels,
        };
        mgr.current = mgr.createScene(.title);
        return mgr;
    }

    pub fn deinit(mgr: *SceneManager) void {
        mgr.current.deinit();
        if (mgr.next) |*next| {
            next.deinit();
            mgr.next = null;
        }
    }

    pub fn switchTo(mgr: *SceneManager, scene_type: SceneType) void {
        mgr.next = mgr.createScene(scene_type);
    }

    pub fn frame(mgr: *SceneManager, dt: f32) !void {
        if (mgr.next) |next| {
            mgr.transition_progress += dt / transition_duration;
            if (mgr.transition_progress >= 1) {
                mgr.transition_progress = 0;
                mgr.current = next;
                mgr.next = null;
            }
        }

        try mgr.current.frame(dt);

        // If we're transitioning, render part of the next screen, but flipped
        // as a "roll down" effect
        if (mgr.next) |*next| {
            // TODO ugly
            mgr.rendering_next = true;
            defer mgr.rendering_next = false;
            try next.frame(dt);
        }
    }

    pub fn handleInput(mgr: *SceneManager, ev: [*c]const sapp.Event) !void {
        try mgr.current.handleInput(ev);
    }

    fn createScene(mgr: SceneManager, scene_type: SceneType) Scene {
        return switch (scene_type) {
            .title => Scene{ .title = TitleScene.init() },
            .game => Scene{ .game = GameScene.init(mgr.allocator, mgr.levels[mgr.level_idx]) catch unreachable }, // TODO
            .editor => Scene{ .editor = EditorScene.init(mgr.allocator) catch unreachable }, // TODO
        };
    }
};

// pub const Scene = struct {
//     ptr: *anyopaque,
//     initFn: fn (scene: *anyopaque) void,
//     deinitFn: fn (scene: *anyopaque) void,
//     frameFn: fn (scene: *anyopaque) void,
//     inputFn: fn (scene: *anyopaque, ev: [*c]const sapp.Event) void,

//     pub fn init(self: Scene) void {
//         self.initFn(self.ptr);
//     }
// };
