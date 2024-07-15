const std = @import("std");
const font = @import("font");
const BatchRenderer = @import("batch.zig").BatchRenderer;

pub const TextRenderer = struct {
    cursor_x: f32 = 0,

    pub fn render(
        self: *TextRenderer,
        batch: *BatchRenderer,
        text: []const u8,
        x: f32,
        y: f32,
    ) void {
        for (text) |ch| {
            const glyph = findGlyph(ch).?;
            const gx: f32 = @floatFromInt(glyph.x);
            const gy: f32 = @floatFromInt(glyph.y);
            const gw: f32 = @floatFromInt(glyph.w);
            const gh: f32 = @floatFromInt(glyph.h);
            const baseline_offset: f32 = @floatFromInt(glyph.bbox[1]);
            batch.render(.{
                .src = .{ .x = gx, .y = gy, .w = gw, .h = gh },
                .dst = .{ .x = self.cursor_x + x, .y = y + font.ascent + baseline_offset, .w = gw, .h = gh },
            });
            self.cursor_x += @floatFromInt(glyph.advance);
        }
        self.cursor_x = 0;
    }

    /// Measure the minimum bounding box that contains the glyphs when laid out
    /// on a single line.
    pub fn measure(text: []const u8) [2]f32 {
        var width: f32 = 0;
        var height: f32 = 0;
        for (text) |ch| {
            const glyph = findGlyph(ch).?;
            const gh: f32 = @floatFromInt(glyph.h);
            width += @floatFromInt(glyph.advance);
            height = @max(height, gh);
        }
        return .{ width, height };
    }

    fn findGlyph(ch: u8) ?font.Glyph {
        // TODO inefficient - make a lookup table
        for (font.glyphs) |g| {
            if (g.ch == ch) return g;
        }
        return null;
    }
};
