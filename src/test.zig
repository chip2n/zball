const std = @import("std");

test {
    std.testing.refAllDecls(@import("audio.zig"));
    std.testing.refAllDecls(@import("level.zig"));
    std.testing.refAllDecls(@import("collision2.zig"));
}
