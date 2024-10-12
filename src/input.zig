const m = @import("math");
const utils = @import("utils.zig");
const gfx = @import("gfx.zig");

const sokol = @import("sokol");
const sapp = sokol.app;

pub const showMouse = sapp.showMouse;
pub const lockMouse = sapp.lockMouse;

const game = @import("game.zig");

const State = struct {
    /// Mouse position in unscaled pixels
    mouse_pos: [2]f32 = .{ 0, 0 },
    mouse_delta: [2]f32 = .{ 0, 0 },
};
var state: State = undefined;

const InputAction = enum {
    left,
    right,
    shoot,
    confirm,
    back,
};

const keybindings = .{
    .{ if (utils.is_web) .BACKSPACE else .ESCAPE, .back },
    .{ .ENTER, .confirm },
    .{ .LEFT, .left },
    .{ .RIGHT, .right },
    .{ .SPACE, .shoot },
};

pub fn identifyAction(key: sapp.Keycode) ?InputAction {
    inline for (keybindings) |binding| {
        if (key == binding[0]) return binding[1];
    }
    return null;
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
}

pub fn handleEvent(ev: sapp.Event) void {
    switch (ev.type) {
        .MOUSE_MOVE => {
            state.mouse_pos = .{ ev.mouse_x, ev.mouse_y };
            state.mouse_delta = m.vadd(state.mouse_delta, .{ ev.mouse_dx, ev.mouse_dy });
        },
        else => {},
    }
}
