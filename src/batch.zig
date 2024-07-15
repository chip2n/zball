const std = @import("std");
const Texture = @import("Texture.zig");
const m = @import("math.zig");
const Rect = m.Rect;

// TODO copied
const max_quads = 512;
const max_verts = max_quads * 6;
const max_cmds = max_quads;
const max_tex = 8;

const TextureId = usize;

const RenderCommand = union(enum) {
    switch_tex: struct {
        tex: usize,
        tw: f32,
        th: f32,
    },
    sprite: struct {
        src: ?Rect,
        dst: Rect,
    },
    nine_patch: struct {
        src: Rect,
        center: Rect,
        dst: Rect,
    },
};

pub const BatchResult = struct {
    verts: []const Vertex,
    batches: []const Batch,
};

pub const Batch = struct {
    offset: usize,
    len: usize,
    tex: usize,
};

pub const BatchRenderer = struct {
    verts: [max_verts]Vertex = undefined,
    batches: [max_tex]Batch = undefined,
    buf: [max_cmds]RenderCommand = undefined,
    idx: usize = 0,

    pub fn init() BatchRenderer {
        return .{};
    }

    pub fn setTexture(self: *BatchRenderer, tex: Texture) void {
        const tw: f32 = @floatFromInt(tex.desc.width);
        const th: f32 = @floatFromInt(tex.desc.height);
        self.buf[self.idx] = .{
            .switch_tex = .{
                .tex = tex.id,
                .tw = tw,
                .th = th,
            },
        };
        self.idx += 1;
        std.debug.assert(self.idx < self.buf.len);
    }

    const RenderOptions = struct { src: ?Rect = null, dst: Rect };
    pub fn render(self: *BatchRenderer, v: RenderOptions) void {
        self.buf[self.idx] = .{
            .sprite = .{
                .src = v.src,
                .dst = v.dst,
            },
        };
        self.idx += 1;
        std.debug.assert(self.idx < self.buf.len);
    }

    const RenderNinePatchOptions = struct { src: Rect, center: Rect, dst: Rect };
    pub fn renderNinePatch(self: *BatchRenderer, v: RenderNinePatchOptions) void {
        self.buf[self.idx] = .{
            .nine_patch = .{
                .src = v.src,
                .center = v.center,
                .dst = v.dst,
            },
        };
        self.idx += 1;
        std.debug.assert(self.idx < self.buf.len);
    }

    // TODO: Implement z-ordering and use sorting to avoid tex switches
    pub fn commit(self: *BatchRenderer) BatchResult {
        const buf = self.buf[0..self.idx];

        // First command must be setting the texture
        var tex = buf[0].switch_tex.tex;
        var tw = buf[0].switch_tex.tw;
        var th = buf[0].switch_tex.th;

        var i: usize = 0;
        var batch_idx: usize = 0;
        var batch_count: usize = 1;
        self.batches[0].offset = 0;
        self.batches[0].len = 0;
        self.batches[0].tex = tex;
        for (buf[1..]) |cmd| {
            switch (cmd) {
                .switch_tex => |c| {
                    tex = c.tex;
                    tw = c.tw;
                    th = c.th;
                    batch_idx += 1;
                    batch_count += 1;
                    self.batches[batch_idx].offset = i;
                    self.batches[batch_idx].len = 0;
                    self.batches[batch_idx].tex = c.tex;
                },
                .sprite => |c| {
                    quad(.{
                        .buf = self.verts[i..],
                        .src = c.src,
                        .dst = c.dst,
                        .tw = tw,
                        .th = th,
                    });
                    self.batches[batch_idx].len += 6;
                    i += 6;
                },
                .nine_patch => |c| {
                    { // top-left corner
                        const w = c.center.x;
                        const h = c.center.y;
                        const src = .{ .x = c.src.x, .y = c.src.y, .w = w, .h = h };
                        const dst = .{ .x = c.dst.x, .y = c.dst.y, .w = w, .h = h };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // top-right corner
                        const w = c.src.w - c.center.x - c.center.w;
                        const h = c.center.y;
                        const src = .{
                            .x = c.src.x + c.center.x + c.center.w,
                            .y = c.src.y,
                            .w = w,
                            .h = h,
                        };
                        const dst = .{
                            .x = c.dst.x + c.dst.w - w,
                            .y = c.dst.y,
                            .w = w,
                            .h = h,
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // bottom-left corner
                        const w = c.center.x;
                        const h = c.src.h - c.center.y - c.center.h;
                        const src = .{
                            .x = c.src.x,
                            .y = c.src.y + c.src.h - h,
                            .w = w,
                            .h = h,
                        };
                        const dst = .{
                            .x = c.dst.x,
                            .y = c.dst.y + c.dst.h - h,
                            .w = w,
                            .h = h,
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }
                    { // bottom-right corner
                        const w = c.src.w - c.center.x - c.center.w;
                        const h = c.src.h - c.center.y - c.center.h;
                        const src = .{
                            .x = c.src.x + c.center.x + c.center.w,
                            .y = c.src.y + c.src.h - h,
                            .w = w,
                            .h = h,
                        };
                        const dst = .{
                            .x = c.dst.x + c.dst.w - w,
                            .y = c.dst.y + c.dst.h - h,
                            .w = w,
                            .h = h,
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // top edge
                        const w = c.center.w;
                        const h = c.center.y;
                        const src = .{
                            .x = c.src.x + c.center.x,
                            .y = c.src.y,
                            .w = w,
                            .h = h,
                        };
                        const dst = .{
                            .x = c.dst.x + c.center.x,
                            .y = c.dst.y,
                            .w = c.dst.w - (c.src.w - c.center.w),
                            .h = h,
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // right edge
                        const w = c.src.w - c.center.x - c.center.w;
                        const h = c.center.h;
                        const src = .{
                            .x = c.src.x + c.center.x + c.center.w,
                            .y = c.src.y + c.center.y,
                            .w = w,
                            .h = h,
                        };
                        const dst = .{
                            .x = c.dst.x + c.dst.w - w,
                            .y = c.dst.y + c.center.y,
                            .w = w,
                            .h = c.dst.h - (c.src.h - c.center.h),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // bottom edge
                        const w = c.center.w;
                        const h = c.src.h - c.center.y - c.center.h;
                        const src = .{
                            .x = c.src.x + c.center.x,
                            .y = c.src.y + c.center.y + c.center.h,
                            .w = w,
                            .h = h,
                        };
                        const dst = .{
                            .x = c.dst.x + c.center.x,
                            .y = c.dst.y + c.dst.h - h,
                            .w = c.dst.w - (c.src.w - c.center.w),
                            .h = h,
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // left edge
                        const w = c.center.x;
                        const h = c.center.h;
                        const src = .{
                            .x = c.src.x,
                            .y = c.src.y + c.center.y,
                            .w = w,
                            .h = h,
                        };
                        const dst = .{
                            .x = c.dst.x,
                            .y = c.dst.y + c.center.y,
                            .w = w,
                            .h = c.dst.h - (c.src.h - c.center.h),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // main background
                        const w = c.center.w;
                        const h = c.center.h;
                        const src = .{
                            .x = c.src.x + c.center.x,
                            .y = c.src.y + c.center.y,
                            .w = w,
                            .h = h,
                        };
                        const dst = .{
                            .x = c.dst.x + c.center.x,
                            .y = c.dst.y + c.center.y,
                            .w = c.dst.w - (c.src.w - c.center.w),
                            .h = c.dst.h - (c.src.h - c.center.h),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }
                },
            }
        }

        self.idx = 0;

        return .{ .verts = self.verts[0..i], .batches = self.batches[0..batch_count] };
    }
};

// TODO below is copied - where does it belong?

const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: f32,
    v: f32,
};

const QuadOptions = struct {
    buf: []Vertex,
    src: ?Rect = null,
    dst: Rect,
    // reference texture dimensions
    tw: f32,
    th: f32,
};

fn quad(v: QuadOptions) void {
    const buf = v.buf;
    const x = v.dst.x;
    const y = v.dst.y;
    const z = 0;
    const w = v.dst.w;
    const h = v.dst.h;
    const tw = v.tw;
    const th = v.th;

    const src = v.src orelse Rect{ .x = 0, .y = 0, .w = tw, .h = th };
    const uv1 = .{ src.x / tw, src.y / th };
    const uv2 = .{ (src.x + src.w) / tw, (src.y + src.h) / th };
    // zig fmt: off
    buf[0] = .{ .x = x,      .y = y,          .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv1[1] };
    buf[1] = .{ .x = x,      .y = y + h,      .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv2[1] };
    buf[2] = .{ .x = x + w,  .y = y + h,      .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv2[1] };
    buf[3] = .{ .x = x,      .y = y,          .z = z, .color = 0xFFFFFFFF, .u = uv1[0], .v = uv1[1] };
    buf[4] = .{ .x = x + w,  .y = y + h,      .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv2[1] };
    buf[5] = .{ .x = x + w,  .y = y,          .z = z, .color = 0xFFFFFFFF, .u = uv2[0], .v = uv1[1] };
    // zig fmt: on
}
