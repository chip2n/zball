const std = @import("std");
const zball = @import("../zball.zig");
const sokol = @import("sokol");
const sg = sokol.gfx;

const c = @cImport({
    @cInclude("stb_image.h");
});

var textures: [zball.max_textures]TextureData = .{TextureData{}} ** zball.max_textures;

pub const Texture = usize;

const TextureData = struct {
    active: bool = false,
    desc: sg.ImageDesc = .{},
    img: sg.Image = .{},
    width: usize = 0,
    height: usize = 0,
    data: []u8 = undefined,
};

pub const TextureUsage = enum { immutable, mutable };

pub fn loadPNG(v: struct { data: []const u8, usage: TextureUsage = .immutable }) !Texture {
    var x: c_int = undefined;
    var y: c_int = undefined;
    var channels: c_int = undefined;
    const img_data = c.stbi_load_from_memory(v.data.ptr, @intCast(v.data.len), &x, &y, &channels, 4);
    const size: usize = @intCast(x * y * 4);
    var desc: sg.ImageDesc = .{
        .width = x,
        .height = y,
        .pixel_format = .RGBA8,
        .usage = switch (v.usage) {
            .immutable => .IMMUTABLE,
            .mutable => .DYNAMIC,
        },
    };
    const img_data_slice = img_data[0..size];
    const img = makeSokolImage(&desc, img_data_slice);

    const handle = try newTextureHandle();
    textures[handle] = .{
        .active = true,
        .desc = desc,
        .img = img,
        .width = @intCast(x),
        .height = @intCast(y),
        .data = img_data_slice,
    };

    return handle;
}

pub fn loadRGB8(v: struct { data: []u8, width: usize, height: usize, usage: TextureUsage = .immutable }) !Texture {
    const size: usize = @intCast(v.width * v.height * 4);
    var desc: sg.ImageDesc = .{
        .width = @intCast(v.width),
        .height = @intCast(v.height),
        .pixel_format = .RGBA8,
        .usage = switch (v.usage) {
            .immutable => .IMMUTABLE,
            .mutable => .DYNAMIC,
        },
    };

    const img = makeSokolImage(&desc, v.data[0..size]);

    const handle = try newTextureHandle();
    textures[handle] = (.{
        .active = true,
        .desc = desc,
        .img = img,
        .width = v.width,
        .height = v.height,
        .data = v.data,
    });

    return handle;
}

pub fn get(handle: Texture) !TextureData {
    const tex = textures[handle];
    if (!tex.active) return error.TextureNotFound;
    return tex;
}

fn makeSokolImage(desc: *sg.ImageDesc, data: []const u8) sg.Image {
    switch (desc.usage) {
        .DYNAMIC, .STREAM => {
            const img = sg.makeImage(desc.*);
            desc.data.subimage[0][0] = sg.asRange(data);
            sg.updateImage(img, desc.data);
            return img;
        },
        else => {
            desc.data.subimage[0][0] = sg.asRange(data);
            return sg.makeImage(desc.*);
        },
    }
}

pub fn draw(handle: Texture, x: usize, y: usize) !void {
    const tex = try get(handle);
    std.debug.assert(x < tex.desc.width);
    std.debug.assert(y < tex.desc.height);

    var data = std.mem.bytesAsSlice(u32, tex.data);
    data[y * tex.width + x] = 0xFFFF0000;
    tex.desc.data.subimage[0][0] = sg.asRange(tex.data);
    sg.updateImage(tex.img, tex.desc.data);
}

fn newTextureHandle() !usize {
    for (textures, 0..) |t, i| {
        if (t.active) continue;
        return i;
    }
    return error.MaxTexturesReached;
}
