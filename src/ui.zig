const std = @import("std");
const root = @import("root");
const font = @import("font");
const m = @import("math");
const sprites = @import("sprite");
const Sprite = sprites.Sprite;
const sokol = @import("sokol");
const sapp = sokol.app;
const BatchRenderer = @import("batch.zig").BatchRenderer;
const TextRenderer = @import("ttf.zig").TextRenderer;
const Texture = @import("texture.zig").Texture;

const WindowData = struct {
    focus_id: u64 = 0,
    focus_prev_id: u64 = 0,
    draw_list: [128]DrawListEntry = undefined, // TODO allocator instead?
    draw_list_idx: usize = 0,
    same_line: bool = false,
    cursor_advance: [2]f32 = .{ 0, 0 },

    fn addDrawListEntry(data: *WindowData, entry: DrawListEntry) void {
        std.debug.assert(data.draw_list_idx < data.draw_list.len - 1);
        data.draw_list[data.draw_list_idx] = entry;
        data.draw_list_idx += 1;
    }
};

var window_data: std.AutoHashMap(u64, WindowData) = undefined;

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
    sprite: struct {
        sprite: Sprite,
        x: f32,
        y: f32,
    },
};

var origin: [2]f32 = .{ 0, 0 };
var cursor: [2]f32 = .{ 0, 0 };
var pivot: [2]f32 = .{ 0, 0 };
var win_id: u64 = 0;
var win_width: f32 = 0;
var win_height: f32 = 0;
var win_z: f32 = 0;
var win_style: WindowStyle = .dialog;
var batch: *BatchRenderer = undefined;
var tex_spritesheet: Texture = undefined;
var tex_font: Texture = undefined;

// Manage window focus
var window_stack: std.ArrayList(u64) = undefined;
var prev_window_stack: std.ArrayList(u64) = undefined;

const io = struct {
    var key_pressed: sapp.Keycode = .INVALID;
    var mouse_pressed: sapp.Mousebutton = .INVALID;
    var mouse_pos: [2]f32 = .{ 0, 0 };
};

const WindowStyle = enum {
    /// Frame contents in a dialog, with semi-transparent background overlay
    dialog,

    /// No styling at all
    transparent,

    /// Used to preserve window state without displaying window
    hidden,
};

pub fn init(allocator: std.mem.Allocator) void {
    window_data = std.AutoHashMap(u64, WindowData).init(allocator);
    window_stack = std.ArrayList(u64).init(allocator);
    prev_window_stack = std.ArrayList(u64).init(allocator);
}

pub fn deinit() void {
    window_data.deinit();
    window_stack.deinit();
    prev_window_stack.deinit();
}

pub const BeginDesc = struct {
    batch: *BatchRenderer,
    tex_spritesheet: Texture,
    tex_font: Texture,
};

pub fn begin(v: BeginDesc) !void {
    window_stack.clearRetainingCapacity();
    batch = v.batch;
    tex_spritesheet = v.tex_spritesheet;
    tex_font = v.tex_font;
}

pub fn end() void {
    io.key_pressed = .INVALID;
    io.mouse_pressed = .INVALID;
    win_id = 0;

    { // If any window has been closed during this frame, clear its data
        var iter = window_data.keyIterator();
        while (iter.next()) |k| {
            for (window_stack.items) |id| {
                if (k.* == id) break;
            } else {
                _ = window_data.remove(k.*);
            }
        }
    }

    prev_window_stack.clearRetainingCapacity();
    // TODO can we avoid memory shenanigans by allocating once in the beginning
    // so that memory allocations cannot fail?
    prev_window_stack.appendSlice(window_stack.items) catch unreachable;
    window_stack.clearRetainingCapacity();
}

// TODO maybe feed our own events? mouse pos needs to be scaled...
pub fn handleEvent(ev: sapp.Event) void {
    switch (ev.type) {
        .KEY_DOWN => {
            io.key_pressed = ev.key_code;
        },
        .MOUSE_DOWN => {
            io.mouse_pressed = ev.mouse_button;
        },
        else => {},
    }
}

pub fn handleMouseMove(x: f32, y: f32) void {
    io.mouse_pos[0] = x;
    io.mouse_pos[1] = y;
}

fn genId(key: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
    return hasher.final();
}

pub const BeginWindowDesc = struct {
    id: []const u8,
    x: f32,
    y: f32,
    z: f32 = 10,
    pivot: [2]f32 = .{ 0, 0 },
    style: WindowStyle = .dialog,
};

pub fn beginWindow(v: BeginWindowDesc) !void {
    const id = genId(v.id);
    win_id = id;

    win_width = 0;
    win_height = 0;
    win_z = v.z;
    win_style = v.style;
    origin[0] = v.x;
    origin[1] = v.y;
    cursor[0] = v.x;
    cursor[1] = v.y;
    pivot = v.pivot;

    try window_stack.append(id);

    const r = try window_data.getOrPut(id);
    if (!r.found_existing) {
        r.value_ptr.* = .{};
    } else {
        r.value_ptr.draw_list_idx = 0;
        r.value_ptr.same_line = false;
        r.value_ptr.cursor_advance[0] = 0;
        r.value_ptr.cursor_advance[1] = 0;
    }
}

pub fn endWindow() void {
    const win_data = window_data.get(win_id).?;
    win_id = 0;

    // TODO do we want to render it here? abstract away batch renderer so we
    // store render commands instead?
    const padding: f32 = switch (win_style) {
        .dialog => 8,
        else => 0,
    };

    const dialog = sprites.get(.dialog);
    // TODO separate sprite sheet for UI
    batch.setTexture(tex_spritesheet);

    var w = win_width + @as(f32, @floatFromInt(dialog.bounds.w - dialog.center.?.w));
    w += padding * 2;
    var h = win_height + @as(f32, @floatFromInt(dialog.bounds.h - dialog.center.?.h));
    h += padding * 2;
    const offset = .{ @round(-pivot[0] * w), @round(-pivot[1] * h) };

    switch (win_style) {
        .dialog => {
            // Semi-transparent background overlay
            batch.render(.{
                .src = sprites.get(.overlay).bounds,
                .dst = .{ .x = 0, .y = 0, .w = root.viewport_size[0], .h = root.viewport_size[1] },
                .z = win_z - 0.1,
            });

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
        .hidden => return,
    }

    { // render draw list
        var text_renderer = TextRenderer{};
        for (win_data.draw_list[0..win_data.draw_list_idx]) |e| {
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
                    const thumb = sprites.get(.slider_thumb);
                    const rail_inactive = sprites.get(.slider_rail_inactive);
                    const rail_active = sprites.get(.slider_rail_active);
                    // inactive rail
                    batch.render(.{
                        .src = rail_inactive.bounds,
                        .dst = .{
                            .x = s.x + padding + offset[0],
                            .y = s.y + padding + offset[1],
                            .w = win_width,
                            .h = @floatFromInt(rail_inactive.bounds.h),
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
                            .h = @floatFromInt(rail_active.bounds.h),
                        },
                        .z = win_z,
                    });
                    // thumb
                    batch.render(.{
                        .src = thumb.bounds,
                        .dst = .{
                            .x = s.x + padding + offset[0] + win_width * s.value - @round(@as(f32, @floatFromInt(thumb.bounds.w)) / 2),
                            .y = s.y + padding + offset[1] - @floor(@as(f32, @floatFromInt(thumb.bounds.h)) / 2),
                            .w = @floatFromInt(thumb.bounds.w),
                            .h = @floatFromInt(thumb.bounds.h),
                        },
                        .z = win_z,
                    });
                },
                .sprite => |s| {
                    batch.setTexture(tex_spritesheet);
                    const sp = sprites.get(s.sprite);

                    batch.render(.{
                        .src = sp.bounds,
                        .dst = .{
                            .x = s.x,
                            .y = s.y,
                            .w = @floatFromInt(sp.bounds.w),
                            .h = @floatFromInt(sp.bounds.h),
                        },
                    });
                },
            }
        }
    }
}

pub const SelectionItemDesc = struct {
    focused: ?*bool = null,
};

pub fn selectionItem(s: []const u8, v: SelectionItemDesc) bool {
    const id = genId(s);
    const arrow_w = 8;
    const sz = TextRenderer.measure(s);
    win_width = @max(win_width, sz[0] + arrow_w + 2);

    var win_data = window_data.getPtr(win_id).?;
    const focus_id = &win_data.focus_id;
    const focus_prev_id = &win_data.focus_prev_id;

    // If nothing is focused, we'll steal focus
    if (focus_id.* == 0) {
        focus_id.* = id;
    }

    const last_win = blk: {
        if (prev_window_stack.items.len == 0) {
            break :blk win_id;
        }
        break :blk prev_window_stack.items[prev_window_stack.items.len - 1];
    };
    const selected = win_id == last_win and focus_id.* == id;
    if (v.focused) |f| {
        f.* = selected;
    }

    if (selected) {
        // Up/down arrows resigns focus
        switch (io.key_pressed) {
            .UP => {
                focus_id.* = focus_prev_id.*;
                io.key_pressed = .INVALID;
            },
            .DOWN => {
                focus_id.* = 0;
                io.key_pressed = .INVALID;
            },
            else => {},
        }
    }

    if (selected) {
        win_data.addDrawListEntry(.{ .text = .{ .s = ">", .x = cursor[0], .y = cursor[1] } });
    }
    win_data.addDrawListEntry(.{ .text = .{ .s = s, .x = cursor[0] + arrow_w, .y = cursor[1] } });

    cursor[1] += font.ascent + 4;
    win_height = cursor[1] - origin[1] - 4;
    focus_prev_id.* = id;

    return selected and io.key_pressed == .ENTER;
}

const SliderDesc = struct {
    value: *f32,
    focused: bool,
};
pub fn slider(v: SliderDesc) void {
    var win_data = window_data.getPtr(win_id).?;

    if (v.focused) {
        if (io.key_pressed == .LEFT) v.value.* = @max(0, v.value.* - 0.1);
        if (io.key_pressed == .RIGHT) v.value.* = @min(v.value.* + 0.1, 1);
    }

    win_data.addDrawListEntry(.{
        .slider = .{
            .value = v.value.*,
            .x = cursor[0],
            .y = cursor[1],
        },
    });
    cursor[1] += 4;
    win_height += 4;
}

const SpriteDesc = struct {
    sprite: Sprite,
};
pub fn sprite(v: SpriteDesc) bool {
    var win_data = window_data.getPtr(win_id).?;

    if (win_data.same_line) {
        cursor[0] += win_data.cursor_advance[0];
    } else {
        cursor[1] += win_data.cursor_advance[1];
    }
    win_data.cursor_advance[0] = 0;
    win_data.cursor_advance[1] = 0;

    win_data.addDrawListEntry(.{
        .sprite = .{
            .sprite = v.sprite,
            .x = cursor[0],
            .y = cursor[1],
        },
    });

    const sp = sprites.get(v.sprite);
    const bounds = m.Rect{
        .x = cursor[0],
        .y = cursor[1],
        .w = @floatFromInt(sp.bounds.w),
        .h = @floatFromInt(sp.bounds.h),
    };
    const pressed = io.mouse_pressed == .LEFT and bounds.containsPoint(io.mouse_pos[0], io.mouse_pos[1]);
    if (io.mouse_pressed == .LEFT) {
        std.log.warn("{d:.2} {d:.2}", .{ io.mouse_pos[0], io.mouse_pos[1] });
    }

    // TODO also do this on the other elements
    win_data.same_line = false;
    win_data.cursor_advance[0] = @floatFromInt(sp.bounds.w);
    win_data.cursor_advance[1] = @floatFromInt(sp.bounds.h);

    return pressed;
}

pub fn sameLine() void {
    var win_data = window_data.getPtr(win_id).?;
    win_data.same_line = true;
}
