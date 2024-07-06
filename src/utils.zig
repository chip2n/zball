const std = @import("std");

pub fn getExecutablePath(allocator: std.mem.Allocator) ![]const u8 {
    const buf = try allocator.alloc(u8, 256);
    return try std.posix.readlink("/proc/self/exe", buf[0..]);
}
