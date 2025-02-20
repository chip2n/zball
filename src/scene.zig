const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;

const level = @import("level.zig");
const Level = level.Level;

const main = @import("main.zig");
const TitleScene = @import("scene/TitleScene.zig");
const GameScene = @import("scene/GameScene.zig");
const EditorScene = @import("scene/EditorScene.zig");

const transition_duration = 1.5;

const SceneType = std.meta.Tag(Scene);

const Scene = union(enum) {
    title: TitleScene,
    game: GameScene,
    editor: EditorScene,

    pub fn init(scene: *Scene) void {
        switch (scene.*) {
            inline else => |*impl| impl.init(),
        }
    }

    pub fn deinit(scene: *Scene) void {
        switch (scene.*) {
            inline else => |*impl| impl.deinit(),
        }
    }

    pub fn frame(scene: *Scene, dt: f32) !void {
        switch (scene.*) {
            inline else => |*impl| try impl.frame(dt),
        }
    }
};

pub const SceneManager = struct {
    allocator: std.mem.Allocator,
    seed: u64,
    current: Scene,
    next: ?Scene = null,
    transition_progress: f32 = 1,
    level_idx: usize = 0,
    levels: []Level,
    rendering_next: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        levels: []Level,
        seed: u64,
    ) SceneManager {
        var mgr = SceneManager{
            .allocator = allocator,
            .seed = seed,
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
        if (mgr.next) |*next| {
            next.deinit();
        }
        mgr.next = mgr.createScene(scene_type);
        mgr.transition_progress = 0;
        if (scene_type != .game) {
            mgr.level_idx = 0;
        }
    }

    /// Update the transition state
    pub fn update(mgr: *SceneManager, dt: f32) !void {
        if (mgr.next) |*next| {
            mgr.transition_progress += dt / transition_duration;
            if (mgr.transition_progress >= 1) {
                mgr.transition_progress = 1;
                mgr.current.deinit();
                mgr.current = next.*;
                mgr.next = null;
            }
        }
    }

    fn createScene(mgr: SceneManager, scene_type: SceneType) Scene {
        return switch (scene_type) {
            .title => Scene{ .title = TitleScene.init() },
            .game => Scene{ .game = GameScene.init(mgr.allocator, mgr.levels[mgr.level_idx], mgr.seed) catch unreachable },
            .editor => Scene{ .editor = EditorScene.init(mgr.allocator) catch unreachable },
        };
    }
};
