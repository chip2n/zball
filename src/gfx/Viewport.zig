const root = @import("root");

const sokol = @import("sokol");
const sg = sokol.gfx;

const m = @import("math");
const shd = @import("shader");
const Camera = @import("Camera.zig");

const offscreen_sample_count = root.offscreen_sample_count;

const Viewport = @This();

size: [2]u32,
camera: *Camera,
attachments_desc: sg.AttachmentsDesc = .{},
attachments_desc2: sg.AttachmentsDesc = .{},
attachments: sg.Attachments = .{},
attachments2: sg.Attachments = .{},

pub fn init(v: struct { size: [2]u32, camera: *Camera }) Viewport {
    var viewport = Viewport{ .size = v.size, .camera = v.camera };

    // setup the offscreen render pass resources
    // this will also be called when the window resizes
    viewport.createOffscreenAttachments();

    return viewport;
}

// helper function to create or re-create render target images and pass object for offscreen rendering
fn createOffscreenAttachments(v: *Viewport) void {
    // destroy previous resources (can be called with invalid ids)
    sg.destroyAttachments(v.attachments);
    for (v.attachments_desc.colors) |att| {
        sg.destroyImage(att.image);
    }
    sg.destroyImage(v.attachments_desc.depth_stencil.image);

    // destroy previous resources (can be called with invalid ids)
    sg.destroyAttachments(v.attachments2);
    for (v.attachments_desc2.colors) |att| {
        sg.destroyImage(att.image);
    }
    sg.destroyImage(v.attachments_desc2.depth_stencil.image);

    // create offscreen render target images
    const color_img_desc: sg.ImageDesc = .{
        .render_target = true,
        .width = @intCast(v.size[0]),
        .height = @intCast(v.size[1]),
        .sample_count = offscreen_sample_count,
    };
    var depth_img_desc = color_img_desc;
    depth_img_desc.pixel_format = .DEPTH;

    v.attachments_desc.colors[0].image = sg.makeImage(color_img_desc);
    v.attachments_desc.depth_stencil.image = sg.makeImage(depth_img_desc);
    v.attachments = sg.makeAttachments(v.attachments_desc);

    v.attachments_desc2.colors[0].image = sg.makeImage(color_img_desc);
    v.attachments_desc2.depth_stencil.image = sg.makeImage(depth_img_desc);
    v.attachments2 = sg.makeAttachments(v.attachments_desc2);
}
