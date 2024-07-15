const std = @import("std");
const c = @cImport({
    @cInclude("stb_image_write.h");
    @cInclude("stb_truetype.h");
});

const GlyphData = struct {
    pos: [2]usize,
    size: [2]usize,
    bbox: [4]i32,
    ch: u8,
    advance: usize,
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

    // TODO do entire ascii table
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 :;@>";
    var glyphs: [chars.len]GlyphData = undefined;

    const bw = 64;
    const bh = 64;
    var bitmap: [bh * bw]u8 = std.mem.zeroes([bh * bw]u8);

    var ascent: i32 = undefined;
    var descent: i32 = undefined;
    var line_gap: i32 = undefined;
    try pack(font_data, &bitmap, bw, &glyphs, &ascent, &descent, &line_gap, chars);

    var bitmap_rgba: [bitmap.len * 4]u8 = undefined;
    convertRGBA(&bitmap, &bitmap_rgba);

    if (c.stbi_write_png(img_path, bw, bh, 4, &bitmap_rgba, bw * 4) == 0) {
        return error.ImageWriteFailed;
    }

    var output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();
    const out = output_file.writer();

    try out.print("pub const image = @embedFile(\"{s}\");\n", .{img_path});
    try out.print("pub const ascent = {};\n", .{ascent});
    try out.print("pub const descent = {};\n\n", .{descent});
    try out.print("pub const line_gap = {};\n\n", .{line_gap});

    _ = try out.write("pub const Glyph = struct {\n");
    _ = try out.write("    ch: u8,\n");
    _ = try out.write("    x: usize,\n");
    _ = try out.write("    y: usize,\n");
    _ = try out.write("    w: usize,\n");
    _ = try out.write("    h: usize,\n");
    _ = try out.write("    bbox: [4]i32,\n");
    _ = try out.write("    advance: usize,\n");
    _ = try out.write("};\n");

    _ = try out.write("pub const glyphs = [_]Glyph{\n");
    for (glyphs) |glyph| {
        try out.print(
            "    .{{ .ch = '{c}', .x = {}, .y = {}, .w = {}, .h = {}, .bbox = .{{ {}, {}, {}, {} }}, .advance = {} }},\n",
            .{
                glyph.ch,
                glyph.pos[0],
                glyph.pos[1],
                glyph.size[0],
                glyph.size[1],
                glyph.bbox[0],
                glyph.bbox[1],
                glyph.bbox[2],
                glyph.bbox[3],
                glyph.advance,
            },
        );
    }
    _ = try out.write("};");

    _ = try out.write("\n\n");

    return std.process.cleanExit();
}

pub fn pack(
    font_data: []const u8,
    bitmap: []u8,
    stride: usize,
    glyphs: []GlyphData,
    out_ascent: *i32,
    out_descent: *i32,
    out_line_gap: *i32,
    data: []const u8,
) !void {
    var font: c.stbtt_fontinfo = undefined;
    if (c.stbtt_InitFont(&font, font_data.ptr, 0) == 0) {
        return error.FontInitFailed;
    }

    const scale = c.stbtt_ScaleForPixelHeight(&font, 8);

    var ascent: c_int = undefined;
    var descent: c_int = undefined;
    var line_gap: c_int = undefined;
    c.stbtt_GetFontVMetrics(&font, &ascent, &descent, &line_gap);

    ascent = @intFromFloat(@round(@as(f32, @floatFromInt(ascent)) * scale));
    descent = @intFromFloat(@round(@as(f32, @floatFromInt(descent)) * scale));
    out_ascent.* = @intCast(ascent);
    out_descent.* = @intCast(descent);
    out_line_gap.* = @intCast(line_gap);

    var x: usize = 0;
    var y: usize = 0;
    var max_h: usize = 0;
    for (data, 0..) |ch, i| {
        var ax: c_int = undefined;
        var lsb: c_int = undefined;
        c.stbtt_GetCodepointHMetrics(&font, ch, &ax, &lsb);

        const advance: usize = @intFromFloat(std.math.round(@as(f32, @floatFromInt(ax)) * scale));
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
        c.stbtt_MakeCodepointBitmap(&font, bitmap[y * stride + x ..].ptr, x2 - x1, y2 - y1, @intCast(stride), scale, scale, ch);
        glyphs[i] = .{
            // TODO refactor these params to make it clear that they are tex coords
            .pos = .{ x, y },
            .size = .{ @intCast(x2 - x1), @intCast(y2 - y1) },
            .bbox = .{ @intCast(x1), @intCast(y1), @intCast(x2), @intCast(y2) },
            .ch = ch,
            .advance = advance,
        };

        x += advance;
    }
}

// Convert 1-channel bitmap to RGBA (setting A=0 for black pixels)
fn convertRGBA(src: []u8, dst: []u8) void {
    std.debug.assert(dst.len == src.len * 4);
    for (src, 0..) |p, i| {
        dst[i * 4 + 0] = p;
        dst[i * 4 + 1] = p;
        dst[i * 4 + 2] = p;
        dst[i * 4 + 3] = p; //if (p == 0) 0 else 255;
    }
}
