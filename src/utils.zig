const std = @import("std");
const builtin = @import("builtin");

pub const is_web = builtin.os.tag == .emscripten;

pub fn getExecutablePath(allocator: std.mem.Allocator) ![]const u8 {
    const buf = try allocator.alloc(u8, 256);
    return try std.posix.readlink("/proc/self/exe", buf[0..]);
}

pub fn tickDownTimer(s: anytype, comptime field: []const u8, dt: f32) bool {
    if (@field(s, field) <= 0) return false;
    @field(s, field) -= dt;
    if (@field(s, field) > 0) return false;

    @field(s, field) = 0;
    return true;
}
