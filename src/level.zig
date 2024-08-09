const std = @import("std");

// All levels are the same size currently
const width = 20;
const height = 20;

pub const Brick = struct {
    id: u8,
};

pub const Level = struct {
    /// Number of bricks in a row
    width: usize,

    /// Number of bricks in a column
    height: usize,

    /// Bricks in the level - 0 means no bricks
    bricks: []Brick,

    pub fn deinit(self: Level, allocator: std.mem.Allocator) void {
        allocator.free(self.bricks);
    }
};

pub fn parseLevel(allocator: std.mem.Allocator, reader: anytype) !Level {
    var bricks = try std.ArrayList(Brick).initCapacity(allocator, width * height);
    errdefer bricks.deinit();

    var line_buffer: [width]u8 = undefined;
    for (0..height) |_| {
        var fbs = std.io.fixedBufferStream(&line_buffer);
        reader.streamUntilDelimiter(fbs.writer(), '\n', fbs.buffer.len + 1) catch |err| {
            switch (err) {
                error.EndOfStream => if (fbs.getWritten().len == 0) return error.InvalidLevelFormat,
                error.StreamTooLong => return error.InvalidLevelFormat,
                error.NoSpaceLeft => return error.InvalidLevelFormat,
            }
        };
        for (line_buffer) |c| {
            const id = std.fmt.parseInt(u8, &.{c}, 10) catch return error.InvalidLevelFormat;
            try bricks.append(.{ .id = id });
        }
    }

    return Level{
        .width = width,
        .height = height,
        .bricks = try bricks.toOwnedSlice(),
    };
}

test "parse level 1" {
    const data = @embedFile("assets/level1.lvl");
    var fbs = std.io.fixedBufferStream(data);
    const result = try parseLevel(std.testing.allocator, fbs.reader());
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(width, result.width);
    try std.testing.expectEqual(height, result.height);
    try std.testing.expectEqual(1, result.bricks[0].id);
}
