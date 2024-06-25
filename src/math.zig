pub fn normalize(v: *[2]f32) void {
    const mag = magnitude(v.*);
    v[0] /= mag;
    v[1] /= mag;
}

pub fn magnitude(v: [2]f32) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1]);
}

pub fn vsub(v1: [2]f32, v2: [2]f32) [2]f32 {
    return .{
        v1[0] - v2[0],
        v1[1] - v2[1],
    };
}
