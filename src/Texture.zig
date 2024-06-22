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
    const img_data = c.stbi_load_from_memory(img, img.len, &x, &y, &channels, 4);
    const size: usize = @intCast(x * y * 4);
    var desc: sg.ImageDesc = .{
        .width = x,
        .height = y,
        .pixel_format = .RGBA8,
    };
    desc.data.subimage[0][0] = sg.asRange(img_data[0..size]);
    return .{ .desc = desc };
}
