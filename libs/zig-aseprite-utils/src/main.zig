const std = @import("std");

pub const AsepriteData = struct {
    frames: []struct {
        filename: []const u8,
        frame: Rect,
        rotated: bool,
        trimmed: bool,
        spriteSourceSize: Rect,
        sourceSize: Size,
        duration: u32,
    },
    meta: struct {
        app: []const u8,
        version: []const u8,
        image: []const u8,
        format: []const u8,
        size: struct { w: u32, h: u32 },
        scale: []const u8,
        slices: []const Slice,
    },
};

pub const Slice = struct {
    name: []const u8,
    color: []const u8,
    keys: []const SliceKey,
};

pub const SliceKey = struct {
    frame: usize,
    bounds: Rect,
    center: ?Rect = null,
    pivot: ?Point = null,
};

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Size = struct {
    w: u32,
    h: u32,
};

pub const Point = struct {
    x: u32,
    y: u32,
};

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !AsepriteData {
    return try std.json.parseFromSliceLeaky(AsepriteData, allocator, data, .{ .ignore_unknown_fields = true });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const args = try std.process.argsAlloc(arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    const json_path = args[1];
    const output_path = args[2];

    var output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();
    var buffer: [1024]u8 = undefined;
    var out = output_file.writer(&buffer);

    // Parse Aseprite JSON data
    const file = try std.fs.openFileAbsolute(json_path, .{});
    defer file.close();
    const json = try file.readToEndAlloc(arena.allocator(), 1 << 30);
    const data = try parse(arena.allocator(), json);

    _ = try out.interface.write(
        \\const std = @import("std");
        \\const Rect = struct { x: u32, y: u32, w: u32, h: u32 };
        \\const Point = struct { x: u32, y: u32 };
        \\
        \\pub const SpriteData = struct {
        \\    name: []const u8,
        \\    bounds: Rect,
        \\    center: ?Rect = null,
        \\    pivot: ?Point = null,
        \\};
    );
    _ = try out.interface.write("\n");
    _ = try out.interface.write(
        \\const sprite_arr = std.enums.EnumArray(Sprite, SpriteData).init(sprites);
        \\pub fn get(sprite: Sprite) SpriteData {
        \\    return sprite_arr.get(sprite);
        \\}
    );
    _ = try out.interface.write("\n");

    // Write sprite IDs as enum
    _ = try out.interface.write("pub const Sprite = enum {\n");
    for (data.meta.slices) |s| {
        try out.interface.print("    {s},\n", .{s.name});
    }
    _ = try out.interface.write("};\n");

    _ = try out.interface.write("pub const sprites: std.enums.EnumFieldStruct(Sprite, SpriteData, null) = .{\n");
    for (data.meta.slices) |s| {
        const b = s.keys[0].bounds;
        try out.interface.print("    .{s} = SpriteData{{\n", .{s.name});
        try out.interface.print("        .name = \"{s}\",\n", .{s.name});
        try out.interface.print("        .bounds = .{{ .x = {}, .y = {}, .w = {}, .h = {} }},\n", .{ b.x, b.y, b.w, b.h });
        if (s.keys[0].center) |c| {
            try out.interface.print("        .center = .{{ .x = {}, .y = {}, .w = {}, .h = {} }},\n", .{ c.x, c.y, c.w, c.h });
        }
        if (s.keys[0].pivot) |p| {
            try out.interface.print("        .pivot = .{{ .x = {}, .y = {} }},\n", .{ p.x, p.y });
        }
        _ = try out.interface.write("    },\n");
    }
    _ = try out.interface.write("};\n");

    try out.interface.flush();
}

test "aseprite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const data = @embedFile("assets/sprites.json");
    const result = try parse(arena.allocator(), data);
    try std.testing.expectEqualStrings(result.meta.image, "sprites.png");
}
