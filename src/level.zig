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

pub const LevelEntity = packed struct(u64) {
    type: LevelEntityType,
    x: u16,
    y: u16,
    sprite: u8 = 0,
    _padding: u16 = 0,
};

pub fn readLevel(allocator: std.mem.Allocator, reader: anytype) !Level {
    const headerInt = try reader.takeInt(u32, .little);
    const header: LevelHeader = @bitCast(headerInt);
    if (header.version != 1) {
        return error.UnknownLevelVersion;
    }
    var entities = std.ArrayList(LevelEntity).init(allocator);
    for (0..header.entity_count) |_| {
        const entityInt = try reader.takeInt(u64, .little);
        const entity: LevelEntity = @bitCast(entityInt);
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
    }, .little);
    for (entities) |e| {
        try writer.writeStruct(e, .little);
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
    var writer = buf.writer();
    var writer_adapter = writer.adaptToNewApi();
    try writeLevel(&entities, &writer_adapter.new_interface);

    var reader = std.io.Reader.fixed(buf.items);
    var reader_adapter = reader.adaptToNewApi();
    const result = try readLevel(std.testing.allocator, &reader_adapter.new_interface);
    defer result.deinit();

    try std.testing.expectEqual(result.entities.len, entities.len);
    try std.testing.expectEqual(result.entities[0], entities[0]);
    try std.testing.expectEqual(result.entities[1], entities[1]);
    try std.testing.expectEqual(result.entities[2], entities[2]);
}
