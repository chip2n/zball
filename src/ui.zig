const std = @import("std");
const font = @import("font");
const sprite = @import("sprite");
const sokol = @import("sokol");
const sapp = sokol.app;
const BatchRenderer = @import("batch.zig").BatchRenderer;
const TextRenderer = @import("ttf.zig").TextRenderer;
const Texture = @import("Texture.zig");

const DrawListEntry = union(enum) {
    text: struct {
        s: []const u8,
        x: f32,
        y: f32,
    },
    slider: struct {
        value: f32,
        x: f32,
        y: f32,
    },
};

var origin: [2]f32 = .{ 0, 0 };
var cursor: [2]f32 = .{ 0, 0 };
var pivot: [2]f32 = .{ 0, 0 };
var win_width: f32 = 0;
var win_height: f32 = 0;
var win_z: f32 = 0;
var win_style: WindowStyle = .dialog;
var draw_list: [128]DrawListEntry = undefined;
var draw_list_idx: usize = 0;
var batch: *BatchRenderer = undefined;
var tex_spritesheet: Texture = undefined;
var tex_font: Texture = undefined;

const io = struct {
    var key_pressed: sapp.Keycode = .INVALID;
};

const WindowStyle = enum {
    dialog,
    transparent,
};

pub const BeginDesc = struct {
    x: f32,
    y: f32,
    z: f32 = 10,
    pivot: [2]f32 = .{ 0, 0 },
    batch: *BatchRenderer,
    tex_spritesheet: Texture,
    tex_font: Texture,
    style: WindowStyle = .dialog,
};

pub fn begin(v: BeginDesc) void {
    win_width = 0;
    win_height = 0;
    win_z = v.z;
    win_style = v.style;
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

    var w = win_width + @as(f32, @floatFromInt(dialog.bounds.w - dialog.center.?.w));
    w += padding * 2;
    var h = win_height + @as(f32, @floatFromInt(dialog.bounds.h - dialog.center.?.h));
    h += padding * 2;
    const offset = .{ @round(-pivot[0] * w), @round(-pivot[1] * h) };

    switch (win_style) {
        .dialog => {
            batch.renderNinePatch(.{
                .src = dialog.bounds,
                .center = dialog.center.?,
                .dst = .{
                    .x = origin[0] + offset[0],
                    .y = origin[1] + offset[1],
                    .w = w,
                    .h = h,
                },
                .z = win_z,
            });
        },
        .transparent => {},
    }

    { // render draw list
        var text_renderer = TextRenderer{};
        for (draw_list[0..draw_list_idx]) |e| {
            switch (e) {
                .text => |t| {
                    batch.setTexture(tex_font);
                    text_renderer.render(
                        batch,
                        t.s,
                        t.x + padding + offset[0],
                        t.y + padding + offset[1],
                        win_z,
                    );
                },
                .slider => |s| {
                    batch.setTexture(tex_spritesheet);
                    const thumb = sprite.sprites.slider_thumb;
                    const rail_inactive = sprite.sprites.slider_rail_inactive;
                    const rail_active = sprite.sprites.slider_rail_active;
                    // inactive rail
                    batch.render(.{
                        .src = rail_inactive.bounds,
                        .dst = .{
                            .x = s.x + padding + offset[0],
                            .y = s.y + padding + offset[1],
                            .w = win_width,
                            .h = rail_inactive.bounds.h,
                        },
                        .z = win_z,
                    });
                    // active rail
                    batch.render(.{
                        .src = rail_active.bounds,
                        .dst = .{
                            .x = s.x + padding + offset[0],
                            .y = s.y + padding + offset[1],
                            .w = win_width * s.value,
                            .h = rail_active.bounds.h,
                        },
                        .z = win_z,
                    });
                    // thumb
                    batch.render(.{
                        .src = thumb.bounds,
                        .dst = .{
                            .x = s.x + padding + offset[0] + win_width * s.value - @round(@as(f32, thumb.bounds.w) / 2),
                            .y = s.y + padding + offset[1] - @floor(@as(f32, thumb.bounds.h) / 2),
                            .w = thumb.bounds.w,
                            .h = thumb.bounds.h,
                        },
                        .z = win_z,
                    });
                },
            }
        }
    }

    // clear IO
    io.key_pressed = .INVALID;
}

pub const SelectionItemDesc = struct {
    selected: bool = false,
};

pub fn selectionItem(s: []const u8, v: SelectionItemDesc) bool {
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

    return v.selected and io.key_pressed == .ENTER;
}

const SliderDesc = struct {
    value: *f32,
    focused: bool,
};
pub fn slider(v: SliderDesc) void {
    if (v.focused) {
        if (io.key_pressed == .LEFT) v.value.* = @max(0, v.value.* - 0.1);
        if (io.key_pressed == .RIGHT) v.value.* = @min(v.value.* + 0.1, 1);
    }

    addDrawListEntry(.{
        .slider = .{
            .value = v.value.*,
            .x = cursor[0],
            .y = cursor[1],
        },
    });
    cursor[1] += 4;
    win_height += 4;
}

pub fn handleEvent(ev: sapp.Event) void {
    switch (ev.type) {
        .KEY_DOWN => {
            io.key_pressed = ev.key_code;
        },
        else => {},
    }
}

fn addDrawListEntry(entry: DrawListEntry) void {
    std.debug.assert(draw_list_idx < draw_list.len - 1);
    draw_list[draw_list_idx] = entry;
    draw_list_idx += 1;
}
