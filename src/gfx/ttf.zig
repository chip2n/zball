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
        z: f32,
    ) void {
        for (text) |ch| {
            const glyph = findGlyph(ch).?;
            const gw: f32 = @floatFromInt(glyph.w);
            const gh: f32 = @floatFromInt(glyph.h);
            const baseline_offset: f32 = @floatFromInt(glyph.bbox[1]);
            batch.render(.{
                .src = .{ .x = glyph.x, .y = glyph.y, .w = glyph.w, .h = glyph.h },
                .dst = .{ .x = self.cursor_x + x, .y = y + font.ascent + baseline_offset, .w = gw, .h = gh },
                .z = z,
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

    /// Truncate text from the end so that it fits within the provided width.
    pub fn truncateEnd(text: []const u8, max_width: f32) []const u8 {
        if (text.len == 0) return text;
        var width: f32 = 0;
        var idx: usize = text.len - 1;
        for (0..text.len) |i| {
            const ch = text[text.len - 1 - i];
            const glyph = findGlyph(ch).?;
            const gw: f32 = @floatFromInt(glyph.advance);
            width += gw;
            if (width <= max_width) {
                idx = text.len - 1 - i;
            } else {
                break;
            }
        }
        return text[idx..];
    }

    fn findGlyph(ch: u8) ?font.Glyph {
        // We could make a lookup table for this but we're not going to display
        // much text in this game
        for (font.glyphs) |g| {
            if (g.ch == ch) return g;
        }
        return null;
    }
};
