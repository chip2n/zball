const zball = @import("../zball.zig");
const Vertex = @import("batch.zig").Vertex;
const sokol = @import("sokol");
const sg = sokol.gfx;
const shd = @import("shader");

attachments_desc: sg.AttachmentsDesc = .{},
attachments: sg.Attachments = .{},
bind: sg.Bindings = .{},

pub fn init(width: u32, height: u32) @This() {
    var attachments_desc = sg.AttachmentsDesc{};
    const color_img_desc: sg.ImageDesc = .{
        .usage = .{ .render_attachment = true },
        .width = @intCast(width),
        .height = @intCast(height),
        .sample_count = zball.offscreen_sample_count,
    };
    var depth_img_desc = color_img_desc;
    depth_img_desc.pixel_format = .DEPTH;

    attachments_desc.colors[0].image = sg.makeImage(color_img_desc);
    attachments_desc.depth_stencil.image = sg.makeImage(depth_img_desc);
    const attachments = sg.makeAttachments(attachments_desc);

    var bind = sg.Bindings{};
    bind.vertex_buffers[0] = sg.makeBuffer(.{
        .usage = .{ .stream_update = true },
        .size = zball.max_scene_verts * @sizeOf(Vertex),
    });
    bind.samplers[shd.SMP_smp] = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    return .{
        .attachments_desc = attachments_desc,
        .attachments = attachments,
        .bind = bind,
    };
}
