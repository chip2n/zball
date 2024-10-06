const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;

const shd = @import("shader");

const constants = @import("constants.zig");

const gfx = @import("gfx.zig");
const Viewport = gfx.Viewport;
const Camera = gfx.Camera;
const BatchRenderer = gfx.BatchRenderer;
const SceneManager = @import("scene.zig").SceneManager;
const Pipeline = gfx.Pipeline;
const Texture = gfx.texture.Texture;

const level = @import("level.zig");
const Level = level.Level;

pub var viewport: Viewport = undefined;
pub var camera: Camera = undefined;

pub const offscreen = struct {
    pub var pip: sg.Pipeline = .{};
    pub var bind: sg.Bindings = .{};
    pub var bind2: sg.Bindings = .{};
    pub var pass_action: sg.PassAction = .{};
};

pub const fsq = struct {
    pub var pip: sg.Pipeline = .{};
    pub var bind: sg.Bindings = .{};
    pub var pass_action: sg.PassAction = .{};
};

pub var bg: Pipeline = undefined;

pub var time: f64 = 0;
pub var dt: f32 = 0;

pub var spritesheet_texture: Texture = undefined;
pub var font_texture: Texture = undefined;

pub var window_size: [2]i32 = constants.initial_screen_size;

/// Mouse position in unscaled pixels
pub var mouse_pos: [2]f32 = .{ 0, 0 };
pub var mouse_delta: [2]f32 = .{ 0, 0 };

pub var allocator: std.mem.Allocator = undefined;
pub var arena: std.heap.ArenaAllocator = undefined;

pub var levels: std.ArrayList(Level) = undefined;

pub var scene_mgr: SceneManager = undefined;

pub var batch = BatchRenderer.init();

pub var quad_vbuf: sg.Buffer = undefined;

pub fn beginOffscreenPass() void {
    sg.beginPass(.{
        .action = offscreen.pass_action,
        .attachments = currentAttachments(),
    });
}

fn currentAttachments() sg.Attachments {
    if (scene_mgr.rendering_next) {
        return viewport.attachments2;
    } else {
        return viewport.attachments;
    }
}

pub fn renderBatch() !void {
    const result = batch.commit();
    sg.updateBuffer(vertexBuffer(), sg.asRange(result.verts));
    var bind = currentBind();
    for (result.batches) |b| {
        const tex = try gfx.texture.get(b.tex);
        bind.fs.images[shd.SLOT_tex] = tex.img;
        sg.applyBindings(bind);
        sg.draw(@intCast(b.offset), @intCast(b.len), 1);
    }
}

fn vertexBuffer() sg.Buffer {
    // TODO currentBind()
    if (scene_mgr.rendering_next) {
        return offscreen.bind2.vertex_buffers[0];
    } else {
        return offscreen.bind.vertex_buffers[0];
    }
}

fn currentBind() sg.Bindings {
    if (scene_mgr.rendering_next) {
        return offscreen.bind2;
    } else {
        return offscreen.bind;
    }
}
