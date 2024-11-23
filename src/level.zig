const std = @import("std");

const LevelHeader = packed struct(u32) {
    version: u8,
    entity_count: u16,
    _padding: u8 = 0,
};

const LevelEntityType = enum(u8) {
    brick,
};

pub const Level = struct {
    allocator: std.mem.Allocator,
    entities: []LevelEntity,

    pub fn deinit(self: Level) void {
        self.allocator.free(self.entities);
    }
};

pub const LevelEntity = packed struct(u48) {
    type: LevelEntityType,
    x: u16,
    y: u16,
    sprite: u8 = 0,
};

pub fn readLevel(allocator: std.mem.Allocator, reader: anytype) !Level {
    const header = try reader.readStruct(LevelHeader);
    if (header.version != 1) {
        return error.UnknownLevelVersion;
    }
    var entities = std.ArrayList(LevelEntity).init(allocator);
    for (0..header.entity_count) |_| {
        const entity = try reader.readStruct(LevelEntity);
        try entities.append(entity);
    }
    return Level{
        .allocator = allocator,
        .entities = try entities.toOwnedSlice(),
    };
}

pub fn writeLevel(entities: []const LevelEntity, writer: anytype) !void {
    if (entities.len > std.math.maxInt(u16)) return error.MaxEntityCountReached;
    try writer.writeStruct(LevelHeader{
        .version = 1,
        .entity_count = @intCast(entities.len),
    });
    for (entities) |e| {
        try writer.writeStruct(e);
    }
}

test "write and read level" {
    const entities: [3]LevelEntity = .{
        .{ .type = .brick, .x = 17 * 0, .y = 0, .sprite = 0 },
        .{ .type = .brick, .x = 17 * 1, .y = 0, .sprite = 1 },
        .{ .type = .brick, .x = 17 * 2, .y = 0, .sprite = 2 },
    };

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();
    try writeLevel(&entities, writer);

    var fbs = std.io.fixedBufferStream(buf.items);
    const result = try readLevel(std.testing.allocator, fbs.reader());
    defer result.deinit();

    try std.testing.expectEqual(result.entities.len, entities.len);
    try std.testing.expectEqual(result.entities[0], entities[0]);
    try std.testing.expectEqual(result.entities[1], entities[1]);
    try std.testing.expectEqual(result.entities[2], entities[2]);
}
