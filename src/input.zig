const std = @import("std");
const m = @import("math");
const utils = @import("utils.zig");
const gfx = @import("gfx.zig");

const sokol = @import("sokol");
const sapp = sokol.app;

pub const showMouse = sapp.showMouse;
pub const lockMouse = sapp.lockMouse;

const game = @import("game.zig");

const KeyTable = std.EnumMap(InputAction, struct {
    pressed: bool = false,
    down: bool = false,
});

const State = struct {
    keys: KeyTable = KeyTable.initFull(.{}),

    /// Mouse position in unscaled pixels
    mouse_pos: [2]f32 = .{ 0, 0 },
    mouse_delta: [2]f32 = .{ 0, 0 },
};
var state: State = .{};

const InputAction = enum {
    left,
    right,
    shoot,
    confirm,
    back,
    editor_draw,
    editor_erase,
    editor_save,
    editor_load,
};

const keybindings = .{
    .{ if (utils.is_web) .BACKSPACE else .ESCAPE, &.{ .back } },
    .{ .F1, &.{ .editor_save } },
    .{ .F2, &.{ .editor_load } },
    .{ .LEFT, &.{ .left } },
    .{ .RIGHT, &.{ .right } },
    .{ .SPACE, &.{ .shoot } },
};

const mousebindings = .{
    .{ .LEFT, &.{ .shoot, .editor_draw } },
    .{ .RIGHT, &.{ .shoot, .editor_erase } },
    .{ .MIDDLE, &.{ .shoot } },
};

pub fn pressed(action: InputAction) bool {
    if (game.scene_mgr.transition_progress != 0) return false;
    return state.keys.get(action).?.pressed;
}

pub fn down(action: InputAction) bool {
    if (game.scene_mgr.transition_progress != 0) return false;
    return state.keys.get(action).?.down;
}

/// Get mouse coordinates, scaled to viewport size
pub fn mouse() [2]f32 {
    return gfx.screenToWorld(state.mouse_pos);
}

/// Get mouse delta, scaled based on zoom
pub fn mouseDelta() [2]f32 {
    return m.vmul(state.mouse_delta, 1 / gfx.cameraZoom());
}

pub fn frame() void {
    state.mouse_delta = .{ 0, 0 };
    var iter = state.keys.iterator();
    while (iter.next()) |entry| {
        entry.value.pressed = false;
    }
}

pub fn handleEvent(ev: sapp.Event) void {
    switch (ev.type) {
        .KEY_DOWN => {
            for (identifyKeyActions(ev.key_code)) |action| {
                const ptr = state.keys.getPtr(action).?;
                ptr.pressed = true;
                ptr.down = true;
            }
        },
        .KEY_UP => {
            for (identifyKeyActions(ev.key_code)) |action| {
                const ptr = state.keys.getPtr(action).?;
                ptr.down = false;
            }
        },
        .MOUSE_DOWN => {
            for (identifyMouseActions(ev.mouse_button)) |action| {
                const ptr = state.keys.getPtr(action).?;
                ptr.pressed = true;
                ptr.down = true;
            }
        },
        .MOUSE_UP => {
            for (identifyMouseActions(ev.mouse_button)) |action| {
                const ptr = state.keys.getPtr(action).?;
                ptr.down = false;
            }
        },
        .MOUSE_MOVE => {
            state.mouse_pos = .{ ev.mouse_x, ev.mouse_y };
            state.mouse_delta = m.vadd(state.mouse_delta, .{ ev.mouse_dx, ev.mouse_dy });
        },
        else => {},
    }
}

fn identifyKeyActions(key: sapp.Keycode) []const InputAction {
    inline for (keybindings) |binding| {
        if (key == binding[0]) return binding[1];
    }
    return &.{};
}

fn identifyMouseActions(btn: sapp.Mousebutton) []const InputAction {
    inline for (mousebindings) |binding| {
        if (btn == binding[0]) return binding[1];
    }
    return &.{};
}
