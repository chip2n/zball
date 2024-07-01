const std = @import("std");
const Texture = @import("Texture.zig");
const m = @import("math.zig");
const Rect = m.Rect;

// TODO copied
const max_quads = 256;
const max_verts = max_quads * 6;
const max_cmds = max_quads;
const max_tex = 8;

const TextureId = usize;

const RenderCommand = struct {
    tex: Texture,
    src: ?Rect = null,
    dst: Rect,
};

pub const BatchResult = struct {
    verts: []const Vertex,
    batches: []const Batch,
};

pub const Batch = struct {
    offset: usize,
    len: usize,
    tex: Texture, // TODO only store id instead?
};

pub const BatchRenderer = struct {
    verts: [max_verts]Vertex = undefined,
    batches: [max_tex]Batch = undefined,
    buf: [max_cmds]RenderCommand = undefined,
    idx: usize = 0,
    tex: ?Texture = null,

    pub fn init() BatchRenderer {
        return .{};
    }

    const RenderOptions = struct { src: ?Rect = null, dst: Rect };

    pub fn setTexture(self: *BatchRenderer, tex: Texture) void {
        self.tex = tex;
    }

    pub fn render(self: *BatchRenderer, v: RenderOptions) void {
        std.debug.assert(self.tex != null);
        self.buf[self.idx] = .{ .tex = self.tex.?, .src = v.src, .dst = v.dst };
        self.idx += 1;
        std.debug.assert(self.idx < self.buf.len);
    }

    pub fn commit(self: *BatchRenderer) BatchResult {
        const buf = self.buf[0..self.idx];
        std.mem.sort(RenderCommand, buf, @as(usize, 0), sortLessThanFn);

        var i: usize = 0;
        var batch_idx: usize = 0;
        var batch_count: usize = 1;
        var tex = self.buf[0].tex;
        self.batches[0].offset = 0;
        self.batches[0].len = 0;
        self.batches[0].tex = tex;
        for (buf) |cmd| {
            if (cmd.tex.id != tex.id) {
                batch_idx += 1;
                self.batches[batch_idx].offset = i;
                self.batches[batch_idx].len = 0;
                self.batches[batch_idx].tex = cmd.tex;
                batch_count += 1;
                tex = cmd.tex;
            }

            quad(.{
                .buf = self.verts[i..],
                .src = cmd.src,
                .dst = cmd.dst,
                .tw = @floatFromInt(cmd.tex.desc.width),
                .th = @floatFromInt(cmd.tex.desc.height),
            });

            self.batches[batch_idx].len += 6;
            i += 6;
        }

        return .{ .verts = self.verts[0..i], .batches = self.batches[0..batch_count] };
    }

    fn sortLessThanFn(context: usize, lhs: RenderCommand, rhs: RenderCommand) bool {
        _ = context;
        return lhs.tex.id < rhs.tex.id;
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
