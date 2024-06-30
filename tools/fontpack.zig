const std = @import("std");
const c = @cImport({
    @cInclude("stb_image_write.h");
    @cInclude("stb_truetype.h");
});

const GlyphData = struct {
    pos: [2]usize,
    ch: u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const args = try std.process.argsAlloc(arena.allocator());
    if (args.len != 4) return error.InvalidArguments;
    const font_path = args[1];
    const output_path = args[2];
    const img_path = args[3];

    const font_data = try std.fs.cwd().readFileAlloc(arena.allocator(), font_path, 1 << 20);

    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var glyphs: [chars.len]GlyphData = undefined;

    const bw = 64;
    const bh = 64;
    var bitmap: [bh * bw]u8 = std.mem.zeroes([bh * bw]u8);

    try pack(font_data, &bitmap, bw, &glyphs, chars);

    if (c.stbi_write_png(img_path, bw, bh, 1, &bitmap, bw) == 0) {
        return error.ImageWriteFailed;
    }

    var output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();
    const out = output_file.writer();

    try out.print("pub const image = @embedFile(\"{s}\");", .{img_path});

    _ = try out.write("pub const glyphs = .{\n");
    for (glyphs) |glyph| {
        try out.print("    .{{ '{c}', {}, {} }},\n", .{glyph.ch, glyph.pos[0], glyph.pos[1]});
    }
    _ = try out.write("};");

    _ = try out.write("\n\n");

    return std.process.cleanExit();
}

pub fn pack(font_data: []const u8, bitmap: []u8, stride: usize, glyphs: []GlyphData, data: []const u8) !void {
    var font: c.stbtt_fontinfo = undefined;
    if (c.stbtt_InitFont(&font, font_data.ptr, 0) == 0) {
        return error.FontInitFailed;
    }

    const scale = c.stbtt_ScaleForPixelHeight(&font, 8);

    var x: usize = 0;
    var y: usize = 0;
    var max_h: usize = 0;
    for (data, 0..) |ch, i| {
        var ax: c_int = undefined;
        var lsb: c_int = undefined;
        c.stbtt_GetCodepointHMetrics(&font, ch, &ax, &lsb);

        var x1: c_int = undefined;
        var y1: c_int = undefined;
        var x2: c_int = undefined;
        var y2: c_int = undefined;
        c.stbtt_GetCodepointBitmapBox(&font, ch, scale, scale, &x1, &y1, &x2, &y2);

        max_h = @max(max_h, @as(usize, @intCast(y2 - y1)));
        if (x + @as(usize, @intCast(x2 - x1)) >= stride) {
            x = 0;
            y += max_h + 1;
        }
        c.stbtt_MakeCodepointBitmap(&font, bitmap[y * stride + x..].ptr, x2 - x1, y2 - y1, @intCast(stride), scale, scale, ch);
        glyphs[i] = .{ .pos = .{ x, y }, .ch = ch };

        x += @as(usize, @intFromFloat(std.math.round(@as(f32, @floatFromInt(ax)) * scale)));
    }
}
