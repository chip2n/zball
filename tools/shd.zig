const std = @import("std");
const shd = @import("shd");
const sg = @import("sokol").gfx;

export fn bgShaderDesc(backend: sg.Backend) sg.ShaderDesc {
    return shd.bgShaderDesc(backend);
}

export const ATTR_vs_bg_pos: usize = shd.ATTR_vs_bg_pos;
export const SLOT_fs_bg_params: usize = shd.SLOT_fs_bg_params;
