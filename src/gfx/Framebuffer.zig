const constants = @import("../constants.zig");
const Vertex = @import("../gfx.zig").Vertex;
const sokol = @import("sokol");
const sg = sokol.gfx;
const shd = @import("shader");

attachments_desc: sg.AttachmentsDesc = .{},
attachments: sg.Attachments = .{},
bind: sg.Bindings = .{},

pub fn init(width: u32, height: u32) @This() {
    var attachments_desc = sg.AttachmentsDesc{};
    const color_img_desc: sg.ImageDesc = .{
        .render_target = true,
        .width = @intCast(width),
        .height = @intCast(height),
        .sample_count = constants.offscreen_sample_count,
    };
    var depth_img_desc = color_img_desc;
    depth_img_desc.pixel_format = .DEPTH;

    attachments_desc.colors[0].image = sg.makeImage(color_img_desc);
    attachments_desc.depth_stencil.image = sg.makeImage(depth_img_desc);
    const attachments = sg.makeAttachments(attachments_desc);

    var bind = sg.Bindings{};
    // TODO max_verts is actually max verts PER frame buffer, but we're making two of those...
    bind.vertex_buffers[0] = sg.makeBuffer(.{
        .usage = .DYNAMIC,
        .size = constants.max_verts * @sizeOf(Vertex),
    });
    bind.fs.samplers[shd.SLOT_smp] = sg.makeSampler(.{});

    return .{
        .attachments_desc = attachments_desc,
        .attachments = attachments,
        .bind = bind,
    };
}
