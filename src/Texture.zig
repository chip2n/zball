const sokol = @import("sokol");
const sg = sokol.gfx;

desc: sg.ImageDesc,

pub fn init() @This() {
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
