const std = @import("std");
const font = @import("font");
const sprite = @import("sprite");
const BatchRenderer = @import("batch.zig").BatchRenderer;
const TextRenderer = @import("ttf.zig").TextRenderer;
const Texture = @import("Texture.zig");

const DrawListEntry = union(enum) {
    text: struct {
        s: []const u8,
        x: f32,
        y: f32,
    },
};

var origin: [2]f32 = .{ 0, 0 };
var cursor: [2]f32 = .{ 0, 0 };
var pivot: [2]f32 = .{ 0, 0 };
var win_width: f32 = 0;
var win_height: f32 = 0;
var draw_list: [128]DrawListEntry = undefined;
var draw_list_idx: usize = 0;
var batch: *BatchRenderer = undefined;
var tex_spritesheet: Texture = undefined;
var tex_font: Texture = undefined;

pub const BeginDesc = struct {
    x: f32,
    y: f32,
    pivot: [2]f32 = .{ 0, 0 },
    batch: *BatchRenderer,
    tex_spritesheet: Texture,
    tex_font: Texture,
};

pub fn begin(v: BeginDesc) void {
    win_width = 0;
    win_height = 0;
    origin[0] = v.x;
    origin[1] = v.y;
    cursor[0] = v.x;
    cursor[1] = v.y;
    pivot = v.pivot;
    batch = v.batch;
    tex_spritesheet = v.tex_spritesheet;
    tex_font = v.tex_font;
    draw_list_idx = 0;
}

pub fn end() void {
    const padding = 8;

    const dialog = sprite.sprites.dialog;
    batch.setTexture(tex_spritesheet);

    var w = win_width + dialog.bounds.w - dialog.center.w;
    w += padding * 2;
    var h = win_height + dialog.bounds.h - dialog.center.h;
    h += padding * 2;
    const offset = .{ @round(-pivot[0] * w), @round(-pivot[1] * h) };

    batch.renderNinePatch(.{
        .src = dialog.bounds,
        .center = dialog.center,
        .dst = .{
            .x = origin[0] + offset[0],
            .y = origin[1] + offset[1],
            .w = w,
            .h = h,
        },
    });

    { // render draw list
        var text_renderer = TextRenderer{};
        batch.setTexture(tex_font); // TODO
        for (draw_list) |e| {
            switch (e) {
                .text => |t| {
                    text_renderer.render(
                        batch,
                        t.s,
                        t.x + padding + offset[0],
                        t.y + padding + offset[1],
                    );
                },
            }
        }
    }
}

pub const SelectionItemDesc = struct {
    selected: bool = false,
};

pub fn selectionItem(s: []const u8, v: SelectionItemDesc) void {
    const arrow_w = 8;
    const sz = TextRenderer.measure(s);
    win_width = @max(win_width, sz[0] + arrow_w + 2);

    if (v.selected) {
        addDrawListEntry(.{
            .text = .{
                .s = ">",
                .x = cursor[0],
                .y = cursor[1],
            },
        });
    }
    addDrawListEntry(.{
        .text = .{
            .s = s,
            .x = cursor[0] + arrow_w,
            .y = cursor[1],
        },
    });

    cursor[1] += font.ascent + 4;
    win_height = cursor[1] - origin[1] - 4;
}

fn addDrawListEntry(entry: DrawListEntry) void {
    std.debug.assert(draw_list_idx < draw_list.len - 1);
    draw_list[draw_list_idx] = entry;
    draw_list_idx += 1;
}
