const std = @import("std");
const builtin = @import("builtin");

pub const is_web = builtin.os.tag == .emscripten;

pub fn getExecutablePath(allocator: std.mem.Allocator) ![]const u8 {
    const buf = try allocator.alloc(u8, 256);
    return try std.posix.readlink("/proc/self/exe", buf[0..]);
}
