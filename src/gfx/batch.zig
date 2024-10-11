const std = @import("std");
const root = @import("root");
const texture = @import("texture.zig");
const constants = @import("../constants.zig");
const Texture = texture.Texture;
const m = @import("math");
const Rect = m.Rect;
const IRect = m.IRect;

const max_quads = constants.max_quads;
const max_verts = constants.max_verts;
const max_cmds = max_quads;
const max_tex = 8;

const TextureId = usize;

// TODO we can look up tw and th afterwards. Also, tex could be just u8
const TextureInfo = struct { handle: Texture, tw: f32, th: f32 };

const RenderCommand = union(enum) {
    sprite: struct {
        src: ?IRect,
        dst: Rect,
        z: f32,
        alpha: u8,
        tex: TextureInfo,
    },
    nine_patch: struct {
        src: IRect,
        center: IRect,
        dst: Rect,
        z: f32,
        alpha: u8,
        tex: TextureInfo,
    },

    fn z_index(cmd: RenderCommand) f32 {
        return switch (cmd) {
            .sprite => |c| c.z,
            .nine_patch => |c| c.z,
        };
    }

    fn tex(cmd: RenderCommand) TextureInfo {
        return switch (cmd) {
            .sprite => |c| c.tex,
            .nine_patch => |c| c.tex,
        };
    }
};

pub const BatchResult = struct {
    verts: []const Vertex,
    batches: []const Batch,
};

pub const Batch = struct {
    offset: usize,
    len: usize,
    tex: Texture,
};

pub const BatchRenderer = struct {
    verts: [max_verts]Vertex = undefined,
    batches: [max_tex]Batch = undefined,
    buf: [max_cmds]RenderCommand = undefined,
    idx: usize = 0,

    num_cmds_submitted: usize = 0,
    num_cmds_accepted: usize = 0,

    tex: ?Texture = null,

    pub fn init() BatchRenderer {
        return .{};
    }

    pub fn setTexture(self: *BatchRenderer, tex: Texture) void {
        self.tex = tex;
        // const tw: f32 = @floatFromInt(tex.desc.width);
        // const th: f32 = @floatFromInt(tex.desc.height);
        // self.buf[self.idx] = .{
        //     .switch_tex = .{
        //         .tex = tex.id,
        //         .tw = tw,
        //         .th = th,
        //     },
        // };
        // self.idx += 1;
        // std.debug.assert(self.idx < self.buf.len);
    }

    const RenderOptions = struct { src: ?IRect = null, dst: Rect, z: f32 = 0, alpha: u8 = 0xFF };
    pub fn render(self: *BatchRenderer, v: RenderOptions) void {
        const tex = texture.get(self.tex.?) catch return;
        const tw: f32 = @floatFromInt(tex.width);
        const th: f32 = @floatFromInt(tex.height);
        self.command(.{
            .sprite = .{
                .src = v.src,
                .dst = v.dst,
                .z = v.z,
                .alpha = v.alpha,
                .tex = .{ .handle = self.tex.?, .tw = tw, .th = th },
            },
        });
    }

    const RenderNinePatchOptions = struct { src: IRect, center: IRect, dst: Rect, z: f32 = 0, alpha: u8 = 0xFF };
    pub fn renderNinePatch(self: *BatchRenderer, v: RenderNinePatchOptions) void {
        const tex = texture.get(self.tex.?) catch return;
        const tw: f32 = @floatFromInt(tex.width);
        const th: f32 = @floatFromInt(tex.height);
        self.command(.{
            .nine_patch = .{
                .src = v.src,
                .center = v.center,
                .dst = v.dst,
                .z = v.z,
                .alpha = v.alpha,
                .tex = .{ .handle = self.tex.?, .tw = tw, .th = th },
            },
        });
    }

    fn command(self: *BatchRenderer, cmd: RenderCommand) void {
        self.num_cmds_submitted += 1;
        if (self.idx == self.buf.len) return;

        self.num_cmds_accepted += 1;
        self.buf[self.idx] = cmd;
        self.idx += 1;
    }

    pub fn commit(self: *BatchRenderer) BatchResult {
        if (self.idx == 0) return .{ .verts = &.{}, .batches = &.{} };

        const buf = self.buf[0..self.idx];

        // Order draw calls by z-index first and texture ID second
        std.mem.sort(RenderCommand, buf, {}, cmdLessThan);

        // TODO maybe an easier way?
        var tex = buf[0].tex().handle;
        var tw = buf[0].tex().tw;
        var th = buf[0].tex().th;

        var i: usize = 0;
        var batch_idx: usize = 0;
        var batch_count: usize = 1;
        self.batches[0].offset = 0;
        self.batches[0].len = 0;
        self.batches[0].tex = tex;

        for (buf) |cmd| {
            if (tex.id != cmd.tex().handle.id) {
                // Make new batch
                tex = cmd.tex().handle;
                tw = cmd.tex().tw;
                th = cmd.tex().th;

                batch_idx += 1;
                batch_count += 1;
                self.batches[batch_idx].offset = i;
                self.batches[batch_idx].len = 0;
                self.batches[batch_idx].tex = tex;
            }

            switch (cmd) {
                .sprite => |c| {
                    const color: u32 = 0xFFFFFF + (@as(u32, @intCast(c.alpha)) << 24);
                    quad(.{
                        .buf = self.verts[i..],
                        .src = c.src,
                        .dst = c.dst,
                        .z = c.z,
                        .color = color,
                        .tw = tw,
                        .th = th,
                    });
                    self.batches[batch_idx].len += 6;
                    i += 6;
                },
                .nine_patch => |c| {
                    const color: u32 = 0xFFFFFF + (@as(u32, @intCast(c.alpha)) << 24);
                    // TODO refactor this
                    { // top-left corner
                        const w = c.center.x;
                        const h = c.center.y;
                        const src = IRect{ .x = c.src.x, .y = c.src.y, .w = w, .h = h };
                        const dst = Rect{ .x = c.dst.x, .y = c.dst.y, .w = @floatFromInt(w), .h = @floatFromInt(h) };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .z = c.z,
                            .color = color,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // top-right corner
                        const w = c.src.w - c.center.x - c.center.w;
                        const h = c.center.y;
                        const src = IRect{
                            .x = c.src.x + c.center.x + c.center.w,
                            .y = c.src.y,
                            .w = w,
                            .h = h,
                        };
                        const dst = Rect{
                            .x = c.dst.x + c.dst.w - @as(f32, @floatFromInt(w)),
                            .y = c.dst.y,
                            .w = @floatFromInt(w),
                            .h = @floatFromInt(h),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .z = c.z,
                            .color = color,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // bottom-left corner
                        const w = c.center.x;
                        const h = c.src.h - c.center.y - c.center.h;
                        const src = IRect{
                            .x = c.src.x,
                            .y = c.src.y + c.src.h - h,
                            .w = w,
                            .h = h,
                        };
                        const dst = Rect{
                            .x = c.dst.x,
                            .y = c.dst.y + c.dst.h - @as(f32, @floatFromInt(h)),
                            .w = @floatFromInt(w),
                            .h = @floatFromInt(h),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .z = c.z,
                            .color = color,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // bottom-right corner
                        const w = c.src.w - c.center.x - c.center.w;
                        const h = c.src.h - c.center.y - c.center.h;
                        const src = IRect{
                            .x = c.src.x + c.center.x + c.center.w,
                            .y = c.src.y + c.src.h - h,
                            .w = w,
                            .h = h,
                        };
                        const dst = Rect{
                            .x = c.dst.x + c.dst.w - @as(f32, @floatFromInt(w)),
                            .y = c.dst.y + c.dst.h - @as(f32, @floatFromInt(h)),
                            .w = @floatFromInt(w),
                            .h = @floatFromInt(h),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .z = c.z,
                            .color = color,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // top edge
                        const w = c.center.w;
                        const h = c.center.y;
                        const src = IRect{
                            .x = c.src.x + c.center.x,
                            .y = c.src.y,
                            .w = w,
                            .h = h,
                        };
                        const dst = Rect{
                            .x = c.dst.x + @as(f32, @floatFromInt(c.center.x)),
                            .y = c.dst.y,
                            .w = c.dst.w - @as(f32, @floatFromInt(c.src.w - c.center.w)),
                            .h = @floatFromInt(h),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .z = c.z,
                            .color = color,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // right edge
                        const w = c.src.w - c.center.x - c.center.w;
                        const h = c.center.h;
                        const src = IRect{
                            .x = c.src.x + c.center.x + c.center.w,
                            .y = c.src.y + c.center.y,
                            .w = w,
                            .h = h,
                        };
                        const dst = Rect{
                            .x = c.dst.x + c.dst.w - @as(f32, @floatFromInt(w)),
                            .y = c.dst.y + @as(f32, @floatFromInt(c.center.y)),
                            .w = @floatFromInt(w),
                            .h = c.dst.h - @as(f32, @floatFromInt(c.src.h - c.center.h)),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .z = c.z,
                            .color = color,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // bottom edge
                        const w = c.center.w;
                        const h = c.src.h - c.center.y - c.center.h;
                        const src = IRect{
                            .x = c.src.x + c.center.x,
                            .y = c.src.y + c.center.y + c.center.h,
                            .w = w,
                            .h = h,
                        };
                        const dst = Rect{
                            .x = c.dst.x + @as(f32, @floatFromInt(c.center.x)),
                            .y = c.dst.y + c.dst.h - @as(f32, @floatFromInt(h)),
                            .w = c.dst.w - @as(f32, @floatFromInt(c.src.w - c.center.w)),
                            .h = @floatFromInt(h),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .z = c.z,
                            .color = color,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }

                    { // left edge
                        const w = c.center.x;
                        const h = c.center.h;
                        const src = IRect{
                            .x = c.src.x,
                            .y = c.src.y + c.center.y,
                            .w = w,
                            .h = h,
                        };
                        const dst = Rect{
                            .x = c.dst.x,
                            .y = c.dst.y + @as(f32, @floatFromInt(c.center.y)),
                            .w = @floatFromInt(w),
                            .h = c.dst.h - @as(f32, @floatFromInt(c.src.h - c.center.h)),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .z = c.z,
                            .color = color,
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
                            .x = c.dst.x + @as(f32, @floatFromInt(c.center.x)),
                            .y = c.dst.y + @as(f32, @floatFromInt(c.center.y)),
                            .w = c.dst.w - @as(f32, @floatFromInt(c.src.w - c.center.w)),
                            .h = c.dst.h - @as(f32, @floatFromInt(c.src.h - c.center.h)),
                        };
                        quad(.{
                            .buf = self.verts[i..],
                            .src = src,
                            .dst = dst,
                            .z = c.z,
                            .color = color,
                            .tw = tw,
                            .th = th,
                        });
                        self.batches[batch_idx].len += 6;
                        i += 6;
                    }
                },
            }
        }

        if (self.num_cmds_accepted < self.num_cmds_submitted) {
            std.log.debug("Some render commands were dropped", .{});
        }

        self.idx = 0;
        self.num_cmds_submitted = 0;
        self.num_cmds_accepted = 0;

        return .{
            .verts = self.verts[0..i],
            .batches = self.batches[0..batch_count],
        };
    }

    fn cmdLessThan(_: void, lhs: RenderCommand, rhs: RenderCommand) bool {
        const lz = lhs.z_index();
        const rz = rhs.z_index();

        if (lz < rz) return true;
        if (lz > rz) return false;
        return false;
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
    src: ?IRect = null,
    dst: Rect,
    z: f32 = 0,
    color: u32 = 0xFFFFFFFF,
    // reference texture dimensions
    tw: f32,
    th: f32,
};

inline fn quad(v: QuadOptions) void {
    const buf = v.buf;
    const x = v.dst.x;
    const y = v.dst.y;
    const z = v.z;
    const w = v.dst.w;
    const h = v.dst.h;
    const tw = v.tw;
    const th = v.th;

    const src = if (v.src) |r| Rect{
        .x = @floatFromInt(r.x),
        .y = @floatFromInt(r.y),
        .w = @floatFromInt(r.w),
        .h = @floatFromInt(r.h),
    } else Rect{ .x = 0, .y = 0, .w = tw, .h = th };

    const uv1 = .{ src.x / tw, src.y / th };
    const uv2 = .{ (src.x + src.w) / tw, (src.y + src.h) / th };
    // zig fmt: off
    buf[0] = .{ .x = x,      .y = y,          .z = z, .color = v.color, .u = uv1[0], .v = uv1[1] };
    buf[1] = .{ .x = x,      .y = y + h,      .z = z, .color = v.color, .u = uv1[0], .v = uv2[1] };
    buf[2] = .{ .x = x + w,  .y = y + h,      .z = z, .color = v.color, .u = uv2[0], .v = uv2[1] };
    buf[3] = .{ .x = x,      .y = y,          .z = z, .color = v.color, .u = uv1[0], .v = uv1[1] };
    buf[4] = .{ .x = x + w,  .y = y + h,      .z = z, .color = v.color, .u = uv2[0], .v = uv2[1] };
    buf[5] = .{ .x = x + w,  .y = y,          .z = z, .color = v.color, .u = uv2[0], .v = uv1[1] };
    // zig fmt: on
}
