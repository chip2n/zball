const zball = @import("zball.zig");
const audio = @import("audio.zig");

const gfx = @import("gfx.zig");
const ui = gfx.ui;

pub fn renderMenu() bool {
    ui.beginWindow(.{
        .id = "settings",
        .x = zball.viewport_size[0] / 2,
        .y = zball.viewport_size[1] / 2,
        .z = 20,
        .pivot = .{ 0.5, 0.5 },
    });
    defer ui.endWindow();

    var sfx_focused = false;
    _ = ui.selectionItem("Volume", .{ .focused = &sfx_focused });
    ui.slider(.{ .value = &audio.vol_sfx, .focused = sfx_focused });

    if (ui.selectionItem("Back", .{})) {
        return true;
    }

    return false;
}
