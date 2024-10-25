const constants = @import("constants.zig");
const audio = @import("audio.zig");

const gfx = @import("gfx.zig");
const ui = gfx.ui;

pub fn renderMenu() bool {
    ui.beginWindow(.{
        .id = "settings",
        .x = constants.viewport_size[0] / 2,
        .y = constants.viewport_size[1] / 2,
        .z = 20,
        .pivot = .{ 0.5, 0.5 },
    });
    defer ui.endWindow();

    var sfx_focused = false;
    _ = ui.selectionItem("Volume (sfx)", .{ .focused = &sfx_focused });
    ui.slider(.{ .value = &audio.vol_sfx, .focused = sfx_focused });

    var bg_focused = false;
    _ = ui.selectionItem("Volume (bg)", .{ .focused = &bg_focused });
    ui.slider(.{ .value = &audio.vol_bg, .focused = bg_focused });

    if (ui.selectionItem("Back", .{})) {
        return true;
    }

    return false;
}
