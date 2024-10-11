const m = @import("math");
const utils = @import("utils.zig");
const gfx = @import("gfx.zig");

const sokol = @import("sokol");
const sapp = sokol.app;

pub const showMouse = sapp.showMouse;
pub const lockMouse = sapp.lockMouse;

const state = @import("state.zig");

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
