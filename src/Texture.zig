const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const c = @cImport({
    @cInclude("stb_image.h");
});

const img = @embedFile("spritesheet.png");

desc: sg.ImageDesc,

pub fn init() @This() {
    var x: c_int = undefined;
    var y: c_int = undefined;
    var channels: c_int = undefined;
    _ = c.stbi_load_from_memory(img, img.len, &x, &y, &channels, 4);
    std.log.warn("{} {} {}", .{x, y, channels});
    var desc: sg.ImageDesc = .{
        .width = 4,
        .height = 4,
        .pixel_format = .RGBA8,
    };
    desc.data.subimage[0][0] = sg.asRange(&[4 * 4]u32{
        0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF, 0xFF000000,
        0xFF000000, 0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF,
        0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF, 0xFF000000,
        0xFF000000, 0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF,
    });
    return .{ .desc = desc };
}
