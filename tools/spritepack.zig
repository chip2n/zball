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
    const out = output_file.writer();

    // Parse Aseprite JSON data
    const file = try std.fs.openFileAbsolute(json_path, .{});
    defer file.close();
    const json = try file.readToEndAlloc(arena.allocator(), 1 << 30);
    const data = try parse(arena.allocator(), json);

    _ = try out.write(
        \\const std = @import("std");
        \\const math = @import("math");
        \\
        \\pub const Sprite = std.meta.FieldEnum(@TypeOf(sprites));
        \\pub const SpriteData = struct {
        \\    name: []const u8,
        \\    bounds: math.IRect,
        \\    center: ?math.IRect = null,
        \\};
    );
    _ = try out.write("\n");
    _ = try out.write(
        \\const sprite_arr = std.enums.EnumArray(Sprite, SpriteData).init(sprites);
        \\pub fn get(sprite: Sprite) SpriteData {
        \\    return sprite_arr.get(sprite);
        \\}
    );
    _ = try out.write("\n");
    _ = try out.write("pub const sprites = .{\n");
    for (data.meta.slices) |s| {
        const b = s.keys[0].bounds;
        try out.print("    .{s} = SpriteData{{\n", .{s.name});
        try out.print("        .name = \"{s}\",\n", .{s.name});
        try out.print("        .bounds = .{{ .x = {}, .y = {}, .w = {}, .h = {} }},\n", .{ b.x, b.y, b.w, b.h });
        if (s.keys[0].center) |c| {
            try out.print("        .center = .{{ .x = {}, .y = {}, .w = {}, .h = {} }},\n", .{ c.x, c.y, c.w, c.h });
        }
        _ = try out.write("    },\n");
    }
    _ = try out.write("};\n");
}

test "aseprite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const data = @embedFile("assets/sprites.json");
    const result = try parse(arena.allocator(), data);
    try std.testing.expectEqualStrings(result.meta.image, "sprites.png");
}
