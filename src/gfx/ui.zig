const std = @import("std");
const gfx = @import("../gfx.zig");
const root = @import("root");
const font = @import("font");
const zball = @import("../zball.zig");
const input = @import("../input.zig");
const m = @import("math");
const sprites = @import("sprites");
const Sprite = sprites.Sprite;
const sokol = @import("sokol");
const sapp = sokol.app;
const BatchRenderer = @import("batch.zig").BatchRenderer;
const TextRenderer = @import("ttf.zig").TextRenderer;
const Texture = @import("texture.zig").Texture;

const WindowData = struct {
    focus_id: u64 = 0,
    focus_prev_id: u64 = 0,
    draw_list: [128]DrawListEntry = undefined,
    draw_list_idx: usize = 0,
    same_line: bool = false,
    cursor_advance: [2]f32 = .{ 0, 0 },

    fn addDrawListEntry(data: *WindowData, entry: DrawListEntry) void {
        std.debug.assert(data.draw_list_idx < data.draw_list.len - 1);
        data.draw_list[data.draw_list_idx] = entry;
        data.draw_list_idx += 1;
    }
};

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
    ninepatch: struct {
        sprite: Sprite,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    },
};

var window_data: std.AutoHashMap(u64, WindowData) = undefined;
var origin: [2]f32 = .{ 0, 0 };
var cursor: [2]f32 = .{ 0, 0 };
var pivot: [2]f32 = .{ 0, 0 };
var win_id: u64 = 0;
var win_width: f32 = 0;
var win_height: f32 = 0;
var win_z: f32 = 0;
var win_style: WindowStyle = .dialog;

// Manage window focus
var window_stack: std.ArrayList(u64) = undefined;
var prev_window_stack: std.ArrayList(u64) = undefined;

const io = struct {
    var key_pressed: sapp.Keycode = .INVALID;
    var char_buf: [64]u8 = std.mem.zeroes([64]u8);
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

pub fn init(allocator: std.mem.Allocator) !void {
    window_data = std.AutoHashMap(u64, WindowData).init(allocator);
    try window_data.ensureTotalCapacity(16);
    window_stack = try std.ArrayList(u64).initCapacity(allocator, 16);
    prev_window_stack = try std.ArrayList(u64).initCapacity(allocator, 16);
}

pub fn deinit() void {
    window_data.deinit();
    window_stack.deinit();
    prev_window_stack.deinit();
}

pub const BeginDesc = struct {};

pub fn begin(v: BeginDesc) void {
    _ = v;
    window_stack.clearRetainingCapacity();
}

pub fn end() void {
    io.key_pressed = .INVALID;
    io.mouse_pressed = .INVALID;
    io.char_buf = std.mem.zeroes([64]u8);
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
    prev_window_stack.appendSliceAssumeCapacity(window_stack.items);
    window_stack.clearRetainingCapacity();
}

pub fn handleEvent(ev: sapp.Event) void {
    switch (ev.type) {
        .CHAR => {
            if (ev.char_code > std.math.maxInt(u8)) return;
            if (std.mem.indexOfScalar(u8, &io.char_buf, 0)) |i| {
                io.char_buf[i] = @intCast(ev.char_code);
            }
        },
        .KEY_DOWN => {
            io.key_pressed = ev.key_code;
        },
        .KEY_UP => {
            io.key_pressed = .INVALID;
        },
        .MOUSE_DOWN => {
            io.mouse_pressed = ev.mouse_button;
        },
        .MOUSE_MOVE => {
            const world_mouse_pos = input.mouse();
            io.mouse_pos[0] = world_mouse_pos[0];
            io.mouse_pos[1] = world_mouse_pos[1];
        },
        else => {},
    }
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

pub fn beginWindow(v: BeginWindowDesc) void {
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

    window_stack.appendAssumeCapacity(id);

    const r = window_data.getOrPutAssumeCapacity(id);
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

    const padding: f32 = switch (win_style) {
        .dialog => 6,
        else => 0,
    };

    const dialog = sprites.get(.dialog);

    var w = win_width + @as(f32, @floatFromInt(dialog.bounds.w - dialog.center.?.w));
    w += padding * 2;
    var h = win_height + @as(f32, @floatFromInt(dialog.bounds.h - dialog.center.?.h));
    h += padding * 2;
    const offset = .{
        @round(-pivot[0] * w),
        @round(-pivot[1] * h),
    };

    const offset_content = .{
        offset[0] + @as(f32, @floatFromInt(dialog.center.?.x)),
        offset[1] + @as(f32, @floatFromInt(dialog.center.?.y)),
    };

    switch (win_style) {
        .dialog => {
            // Semi-transparent background overlay
            const overlay = sprites.get(.overlay);
            gfx.render(.{
                .src = m.irect(overlay.bounds),
                .dst = .{ .x = 0, .y = 0, .w = zball.viewport_size[0], .h = zball.viewport_size[1] },
                .z = win_z - 0.1,
                .layer = .ui,
            });

            gfx.renderNinePatch(.{
                .src = m.irect(dialog.bounds),
                .center = m.irect(dialog.center.?),
                .dst = .{
                    .x = origin[0] + offset[0],
                    .y = origin[1] + offset[1],
                    .w = w,
                    .h = h,
                },
                .layer = .ui,
                .z = win_z,
            });
        },
        .transparent => {},
        .hidden => return,
    }

    { // render draw list
        for (win_data.draw_list[0..win_data.draw_list_idx]) |e| {
            switch (e) {
                .text => |t| {
                    gfx.renderText(
                        t.s,
                        t.x + padding + offset_content[0],
                        t.y + padding + offset_content[1],
                        win_z,
                    );
                },
                .slider => |s| {
                    const thumb = sprites.get(.slider_thumb);
                    const rail_inactive = sprites.get(.slider_rail_inactive);
                    const rail_active = sprites.get(.slider_rail_active);
                    // inactive rail
                    gfx.render(.{
                        .src = m.irect(rail_inactive.bounds),
                        .dst = .{
                            .x = s.x + padding + offset_content[0],
                            .y = s.y + padding + offset_content[1],
                            .w = win_width,
                            .h = @floatFromInt(rail_inactive.bounds.h),
                        },
                        .layer = .ui,
                        .z = win_z,
                    });
                    // active rail
                    gfx.render(.{
                        .src = m.irect(rail_active.bounds),
                        .dst = .{
                            .x = s.x + padding + offset_content[0],
                            .y = s.y + padding + offset_content[1],
                            .w = win_width * s.value,
                            .h = @floatFromInt(rail_active.bounds.h),
                        },
                        .layer = .ui,
                        .z = win_z,
                    });
                    // thumb
                    gfx.render(.{
                        .src = m.irect(thumb.bounds),
                        .dst = .{
                            .x = s.x + padding + offset_content[0] + win_width * s.value - @round(@as(f32, @floatFromInt(thumb.bounds.w)) / 2),
                            .y = s.y + padding + offset_content[1] - @floor(@as(f32, @floatFromInt(thumb.bounds.h)) / 2),
                            .w = @floatFromInt(thumb.bounds.w),
                            .h = @floatFromInt(thumb.bounds.h),
                        },
                        .layer = .ui,
                        .z = win_z,
                    });
                },
                .sprite => |s| {
                    const sp = sprites.get(s.sprite);
                    gfx.render(.{
                        .src = m.irect(sp.bounds),
                        .dst = .{
                            .x = s.x + padding + offset_content[0],
                            .y = s.y + padding + offset_content[1],
                            .w = @floatFromInt(sp.bounds.w),
                            .h = @floatFromInt(sp.bounds.h),
                        },
                        .layer = .ui,
                        .z = win_z,
                    });
                },
                .ninepatch => |s| {
                    const sp = sprites.get(s.sprite);
                    gfx.renderNinePatch(.{
                        .src = m.irect(sp.bounds),
                        .center = m.irect(sp.center.?),
                        .dst = .{
                            .x = s.x + padding + offset_content[0],
                            .y = s.y + padding + offset_content[1],
                            .w = s.w,
                            .h = s.h,
                        },
                        .layer = .ui,
                        .z = win_z,
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
        win_data.addDrawListEntry(.{ .text = .{ .s = ">", .x = cursor[0] - 2, .y = cursor[1] } });
    }
    win_data.addDrawListEntry(.{ .text = .{ .s = s, .x = cursor[0] - 2 + arrow_w, .y = cursor[1] } });

    cursor[1] += font.ascent + 4;
    win_height += font.ascent + 4;
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
    // TODO also do this on the other elements
    win_data.same_line = false;
    win_data.cursor_advance[0] = @floatFromInt(sp.bounds.w);
    win_data.cursor_advance[1] = @floatFromInt(sp.bounds.h);

    return pressed;
}

const TextDesc = struct {};

pub fn text(s: []const u8, v: TextDesc) void {
    _ = v;
    const sz = TextRenderer.measure(s);
    win_width = @max(win_width, sz[0]);

    var win_data = window_data.getPtr(win_id).?;
    win_data.addDrawListEntry(.{ .text = .{ .s = s, .x = cursor[0], .y = cursor[1] } });

    cursor[1] += font.ascent + 4;
    win_height += font.ascent + 4;
}

const TextInputDesc = struct {
    text: []u8,
};

pub fn textInput(v: TextInputDesc) ?[]u8 {
    var win_data = window_data.getPtr(win_id).?;
    const w = zball.viewport_size[0] - 48;
    const h = 12;
    win_data.addDrawListEntry(.{
        .ninepatch = .{
            .sprite = .text_input,
            .x = cursor[0],
            .y = cursor[1],
            .w = w,
            .h = h,
        },
    });

    // Read all user-inputted characters and write them to the text field buffer
    for (io.char_buf) |ch| {
        if (ch == 0) break;
        if (std.mem.indexOfScalar(u8, v.text, 0)) |idx| {
            if (idx < v.text.len) {
                switch (ch) {
                    ' '...'~' => {
                        v.text[idx] = ch;
                    },
                    else => {},
                }
            }
        }
    }
    switch (io.key_pressed) {
        .BACKSPACE => {
            if (std.mem.indexOfScalar(u8, v.text, 0)) |idx| {
                if (idx > 0) v.text[idx - 1] = 0;
            } else {
                if (v.text.len > 0) v.text[v.text.len - 1] = 0;
            }
        },
        .INVALID => {},
        else => {},
    }
    const t = std.mem.sliceTo(v.text, 0);
    const tt = TextRenderer.truncateEnd(t, w - 8);
    const sz = TextRenderer.measure(tt);
    if (t.len == tt.len) {
        // Text is not truncated - align to left
        win_data.addDrawListEntry(.{ .text = .{ .s = tt, .x = cursor[0] + 4, .y = cursor[1] + 2 } });
    } else {
        // Text is truncated - align to right
        win_data.addDrawListEntry(.{ .text = .{ .s = tt, .x = cursor[0] + w - 4 - sz[0], .y = cursor[1] + 2 } });
    }
    win_width = @max(win_width, w);
    win_height += h;
    cursor[0] = 0;
    cursor[1] += h;

    if (io.key_pressed == .ENTER) {
        return t;
    }
    return null;
}

pub fn sameLine() void {
    var win_data = window_data.getPtr(win_id).?;
    win_data.same_line = true;
}
