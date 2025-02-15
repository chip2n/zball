const std = @import("std");
const zball = @import("../zball.zig");
const root = @import("root");
const texture = @import("texture.zig");
const Texture = texture.Texture;
const m = @import("math");
const Rect = m.Rect;
const IRect = m.IRect;

const max_batches = 16;

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: f32,
    v: f32,
};

const TextureId = usize;

const TextureInfo = struct { handle: Texture, tw: f32, th: f32 };
const Layer = enum { background, main, particles, ui };

const RenderCommand = union(enum) {
    sprite: struct {
        src: ?IRect,
        dst: Rect,
        z: f32,
        alpha: u8,
        tex: TextureInfo,
        layer: Layer,
        illuminated: bool,
    },
    nine_patch: struct {
        src: IRect,
        center: IRect,
        dst: Rect,
        z: f32,
        alpha: u8,
        tex: TextureInfo,
        layer: Layer,
        illuminated: bool,
    },

    fn layer(cmd: RenderCommand) Layer {
        return switch (cmd) {
            inline else => |c| c.layer,
        };
    }

    fn z_index(cmd: RenderCommand) f32 {
        return switch (cmd) {
            inline else => |c| c.z,
        };
    }

    fn tex(cmd: RenderCommand) TextureInfo {
        return switch (cmd) {
            inline else => |c| c.tex,
        };
    }

    fn illuminated(cmd: RenderCommand) bool {
        return switch (cmd) {
            inline else => |c| c.illuminated,
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
    layer: Layer,
    illuminated: bool,
};

pub const BatchRenderer = struct {
    allocator: std.mem.Allocator,
    verts: std.ArrayListUnmanaged(Vertex),
    batches: std.ArrayListUnmanaged(Batch),
    buf: std.ArrayListUnmanaged(RenderCommand),
    idx: usize = 0,

    num_cmds_submitted: usize = 0,
    num_cmds_accepted: usize = 0,

    tex: ?Texture = null,

    pub fn init(allocator: std.mem.Allocator) !BatchRenderer {
        return .{
            .allocator = allocator,
            .verts = try std.ArrayListUnmanaged(Vertex).initCapacity(allocator, zball.max_scene_verts),
            .batches = try std.ArrayListUnmanaged(Batch).initCapacity(allocator, max_batches),
            .buf = try std.ArrayListUnmanaged(RenderCommand).initCapacity(allocator, zball.max_scene_quads),
        };
    }

    pub fn deinit(self: *BatchRenderer) void {
        self.verts.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.buf.deinit(self.allocator);
    }

    pub inline fn setTexture(self: *BatchRenderer, tex: Texture) void {
        self.tex = tex;
    }

    pub const RenderOptions = struct {
        src: ?IRect = null,
        dst: Rect,
        z: f32 = 0,
        alpha: u8 = 0xFF,
        layer: Layer = .main,
        illuminated: bool = true,
    };
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
                .layer = v.layer,
                .illuminated = v.illuminated,
            },
        });
    }

    pub const RenderNinePatchOptions = struct {
        src: IRect,
        center: IRect,
        dst: Rect,
        z: f32 = 0,
        alpha: u8 = 0xFF,
        layer: Layer = .main,
        illuminated: bool = true,
    };
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
                .layer = v.layer,
                .illuminated = v.illuminated,
            },
        });
    }

    fn command(self: *BatchRenderer, cmd: RenderCommand) void {
        self.num_cmds_submitted += 1;
        if (self.buf.items.len == self.buf.capacity) return;
        self.num_cmds_accepted += 1;

        self.buf.appendAssumeCapacity(cmd);
    }

    pub fn commit(self: *BatchRenderer) BatchResult {
        if (self.buf.items.len == 0) return .{ .verts = &.{}, .batches = &.{} };

        const buf = self.buf.items;
        std.mem.sort(RenderCommand, buf, {}, cmdLessThan);

        var tex = buf[0].tex().handle;
        var tw = buf[0].tex().tw;
        var th = buf[0].tex().th;
        var layer = buf[0].layer();
        var illuminated = buf[0].illuminated();

        self.batches.appendAssumeCapacity(.{
            .offset = 0,
            .len = 0,
            .tex = tex,
            .layer = layer,
            .illuminated = illuminated,
        });

        for (buf) |cmd| {
            if (tex != cmd.tex().handle or layer != cmd.layer() or illuminated != cmd.illuminated()) {
                // Make new batch
                tex = cmd.tex().handle;
                tw = cmd.tex().tw;
                th = cmd.tex().th;
                layer = cmd.layer();
                illuminated = cmd.illuminated();

                self.batches.appendAssumeCapacity(.{
                    .offset = self.verts.items.len,
                    .len = 0,
                    .tex = tex,
                    .layer = layer,
                    .illuminated = illuminated,
                });
            }

            switch (cmd) {
                .sprite => |c| {
                    const color: u32 = 0xFFFFFF + (@as(u32, @intCast(c.alpha)) << 24);
                    self.quad(.{
                        .src = c.src,
                        .dst = c.dst,
                        .z = c.z,
                        .color = color,
                        .tw = tw,
                        .th = th,
                    });
                },
                .nine_patch => |c| {
                    const color: u32 = 0xFFFFFF + (@as(u32, @intCast(c.alpha)) << 24);
                    { // top-left corner
                        const w = c.center.x;
                        const h = c.center.y;
                        const src = IRect{ .x = c.src.x, .y = c.src.y, .w = w, .h = h };
                        const dst = Rect{ .x = c.dst.x, .y = c.dst.y, .w = @floatFromInt(w), .h = @floatFromInt(h) };
                        self.quad(.{ .src = src, .dst = dst, .z = c.z, .color = color, .tw = tw, .th = th });
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
                        self.quad(.{ .src = src, .dst = dst, .z = c.z, .color = color, .tw = tw, .th = th });
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
                        self.quad(.{ .src = src, .dst = dst, .z = c.z, .color = color, .tw = tw, .th = th });
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
                        self.quad(.{ .src = src, .dst = dst, .z = c.z, .color = color, .tw = tw, .th = th });
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
                        self.quad(.{ .src = src, .dst = dst, .z = c.z, .color = color, .tw = tw, .th = th });
                    }

                    { // right edge
                        const w = c.src.w - c.center.x - c.center.w;
                        const h = c.center.h;
                        const src = IRect{ .x = c.src.x + c.center.x + c.center.w, .y = c.src.y + c.center.y, .w = w, .h = h };
                        const dst = Rect{
                            .x = c.dst.x + c.dst.w - @as(f32, @floatFromInt(w)),
                            .y = c.dst.y + @as(f32, @floatFromInt(c.center.y)),
                            .w = @floatFromInt(w),
                            .h = c.dst.h - @as(f32, @floatFromInt(c.src.h - c.center.h)),
                        };
                        self.quad(.{ .src = src, .dst = dst, .z = c.z, .color = color, .tw = tw, .th = th });
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
                        self.quad(.{ .src = src, .dst = dst, .z = c.z, .color = color, .tw = tw, .th = th });
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
                        self.quad(.{ .src = src, .dst = dst, .z = c.z, .color = color, .tw = tw, .th = th });
                    }

                    { // main background
                        const w = c.center.w;
                        const h = c.center.h;
                        self.quad(.{
                            .src = .{
                                .x = c.src.x + c.center.x,
                                .y = c.src.y + c.center.y,
                                .w = w,
                                .h = h,
                            },
                            .dst = .{
                                .x = c.dst.x + @as(f32, @floatFromInt(c.center.x)),
                                .y = c.dst.y + @as(f32, @floatFromInt(c.center.y)),
                                .w = c.dst.w - @as(f32, @floatFromInt(c.src.w - c.center.w)),
                                .h = c.dst.h - @as(f32, @floatFromInt(c.src.h - c.center.h)),
                            },
                            .z = c.z,
                            .color = color,
                            .tw = tw,
                            .th = th,
                        });
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
            .verts = self.verts.items,
            .batches = self.batches.items,
        };
    }

    pub fn reset(self: *BatchRenderer) void {
        self.verts.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        self.buf.clearRetainingCapacity();
    }

    fn cmdLessThan(_: void, lhs: RenderCommand, rhs: RenderCommand) bool {
        const le = lhs.layer();
        const re = rhs.layer();
        const lt = lhs.tex();
        const rt = rhs.tex();
        const lz = lhs.z_index();
        const rz = rhs.z_index();

        if (@intFromEnum(le) < @intFromEnum(re)) return true;
        if (@intFromEnum(le) > @intFromEnum(re)) return false;
        if (lz < rz) return true;
        if (lz > rz) return false;
        if (lhs.illuminated() and !rhs.illuminated()) return true;
        if (!lhs.illuminated() and rhs.illuminated()) return false;
        if (lt.handle < rt.handle) return true;
        if (lt.handle > rt.handle) return false;
        return false;
    }

    inline fn quad(self: *BatchRenderer, v: QuadOptions) void {
        // NOTE: Render at exact pixel coordinates for pixel perfect rendering
        const x = std.math.round(v.dst.x);
        const y = std.math.round(v.dst.y);
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

        const q = [_]Vertex{
            // zig fmt: off
            .{ .x = x,     .y = y,     .z = z, .color = v.color, .u = uv1[0], .v = uv1[1] },
            .{ .x = x,     .y = y + h, .z = z, .color = v.color, .u = uv1[0], .v = uv2[1] },
            .{ .x = x + w, .y = y + h, .z = z, .color = v.color, .u = uv2[0], .v = uv2[1] },
            .{ .x = x,     .y = y,     .z = z, .color = v.color, .u = uv1[0], .v = uv1[1] },
            .{ .x = x + w, .y = y + h, .z = z, .color = v.color, .u = uv2[0], .v = uv2[1] },
            .{ .x = x + w, .y = y,     .z = z, .color = v.color, .u = uv2[0], .v = uv1[1] },
            // zig fmt: on
        };

        if (self.verts.items.len + q.len > self.verts.capacity) {
            std.log.err("Max vertices reached - dropping rest of commands", .{});
            return;
        }
        self.verts.appendSliceAssumeCapacity(&q);
        self.batches.items[self.batches.items.len - 1].len += q.len;
    }
};

const QuadOptions = struct {
    src: ?IRect = null,
    dst: Rect,
    z: f32 = 0,
    color: u32 = 0xFFFFFFFF,
    // reference texture dimensions
    tw: f32,
    th: f32,
};
