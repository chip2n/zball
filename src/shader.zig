//! This file contains code relating to the background shader

const std = @import("std");
const config = @import("config");
const sokol = @import("sokol");
const sg = sokol.gfx;

const ShaderDescFn = *const fn (sg.Backend) sg.ShaderDesc;

pub const Pipeline = if (config.shader_reload) DynamicPipeline else StaticPipeline;

/// A static pipeline that does not support reloading (the shader is compiled in to the binary)
pub const StaticPipeline = struct {
    pip: sg.Pipeline = .{},
    pip_desc: sg.PipelineDesc = .{},
    bind: sg.Bindings = .{},

    pub fn init() !StaticPipeline {
        const shd = @import("shader");
        var pip_desc: sg.PipelineDesc = .{
            .shader = sg.makeShader(shd.bgShaderDesc(sg.queryBackend())),
            .primitive_type = .TRIANGLE_STRIP,
            .depth = .{
                .pixel_format = .DEPTH,
                .compare = .LESS_EQUAL,
                .write_enabled = false,
            },
        };
        pip_desc.layout.attrs[shd.ATTR_vs_bg_pos].format = .FLOAT2;
        pip_desc.layout.attrs[shd.ATTR_vs_bg_in_uv].format = .FLOAT2;
        const pip = sg.makePipeline(pip_desc);
        return .{
            .pip = pip,
            .pip_desc = pip_desc,
        };
    }
};

/// A pipeline that loads a shader (compiled as a shared library) and allows you
/// to reload it at any point.
pub const DynamicPipeline = struct {
    pip: sg.Pipeline,
    pip_desc: sg.PipelineDesc,
    shader_desc: sg.ShaderDesc,
    bind: sg.Bindings,
    path: []const u8,
    name: [:0]const u8,

    pub fn load(path: []const u8, name: [:0]const u8) !Pipeline {
        var lib = try std.DynLib.open(path);
        defer lib.close();

        const out = try lookupShaderDesc(&lib, name);
        const desc = out.desc;
        const pos_attr = out.pos;

        var pip_desc: sg.PipelineDesc = .{
            .shader = sg.makeShader(desc),
            .primitive_type = .TRIANGLE_STRIP,
            .depth = .{
                .pixel_format = .DEPTH,
                .compare = .LESS_EQUAL,
                .write_enabled = false,
            },
        };
        pip_desc.layout.attrs[pos_attr].format = .FLOAT2;
        const pip = sg.makePipeline(pip_desc);

        return Pipeline{
            .pip = pip,
            .pip_desc = pip_desc,
            .shader_desc = desc,
            .bind = .{},
            .path = path,
            .name = name,
        };
    }

    pub fn reload(self: *Pipeline) !void {
        var lib = try std.DynLib.open(self.path);
        defer lib.close();

        const out = try lookupShaderDesc(&lib, self.name);
        const desc = out.desc;
        const pos_attr = out.pos;

        if (desc.fs.uniform_blocks[0].size != self.shader_desc.fs.uniform_blocks[0].size) {
            std.log.warn("Uniforms changed - cannot reload shader", .{});
            return error.ShaderReloadFailed;
        }

        sg.destroyPipeline(self.pip);
        sg.destroyShader(self.pip_desc.shader);

        self.pip_desc.shader = sg.makeShader(desc);
        self.pip_desc.layout.attrs[pos_attr].format = .FLOAT2;
        self.shader_desc = desc;

        self.pip = sg.makePipeline(self.pip_desc);
    }

    fn lookupShaderDesc(lib: *std.DynLib, name: [:0]const u8) !struct { desc: sg.ShaderDesc, pos: usize } {
        const f = lib.lookup(ShaderDescFn, name) orelse return error.ShaderLoadFailed;
        const pos = lib.lookup(*usize, "ATTR_vs_bg_pos") orelse return error.ShaderLoadFailed;
        const desc = f(sg.queryBackend());
        return .{ .desc = desc, .pos = pos.* };
    }
};
