const std = @import("std");
const root = @import("root");
const sprites = @import("sprite");
const m = @import("math.zig");
const BatchRenderer = @import("batch.zig").BatchRenderer;

const Sprite = sprites.Sprite;

const max_emitters = 16;

const p_size = .{ 1, 3 };

const Emitter = struct {
    start_time: f32 = 0,
    origin: [2]f32 = .{ 0, 0 },
    count: usize = 0,
    start_angle: f32 = 0,
    sweep: f32 = 0,
    sprite: ?Sprite = null,
    active: bool = false,

    /// Get position of particle N at time T
    fn particle(em: Emitter, n: usize, t: f32) struct { pos: [2]f32, sz: f32 } {
        const seed = @as(u64, @intFromFloat(em.start_time * 1000)) + @as(u64, @intCast(n));
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const dt = t - em.start_time;

        const bw = root.brick_w;
        const bh = root.brick_h;
        const sz = p_size[0] + rng.float(f32) * (p_size[1] - p_size[0]);
        const pos = [2]f32{
            em.origin[0] + rng.float(f32) * bw - bw / 2 - sz / 2,
            em.origin[1] + rng.float(f32) * bh - bh / 2 - sz / 2,
        };
        var vel = [2]f32{ 1, 0 };
        m.vrot(&vel, rng.float(f32) * em.sweep + em.start_angle);

        const gravity = 100;

        const speed = rng.float(f32) * 150 + 10;
        vel = m.vmul(vel, speed);

        vel[1] = vel[1] + gravity * dt;

        return .{
            .pos = .{
                pos[0] + vel[0] * dt,
                pos[1] + vel[1] * dt + 0.5 * gravity * dt * dt,
            },
            .sz = sz,
        };
    }
};

pub const ParticleSystem = struct {
    emitters: [max_emitters]Emitter = .{.{}} ** max_emitters,
    time: f32 = 0,

    pub const EmitDesc = struct {
        origin: [2]f32,
        count: usize,
        sprite: Sprite,
        start_angle: f32 = 0,
        sweep: f32 = std.math.tau,
    };
    pub fn emit(sys: *ParticleSystem, v: EmitDesc) void {
        for (&sys.emitters) |*em| {
            if (em.active) continue;
            em.* = .{
                .start_time = sys.time,
                .origin = v.origin,
                .count = v.count,
                .sprite = v.sprite,
                .start_angle = v.start_angle,
                .sweep = v.sweep,
                .active = true,
            };
            break;
        } else {
            std.log.err("Max emitter count reached", .{});
            unreachable;
        }
    }

    pub fn update(sys: *ParticleSystem, dt: f32) void {
        sys.time += dt;
        for (&sys.emitters) |*em| {
            if (!em.active) continue;
            if (sys.time - em.start_time > 2) {
                em.active = false;
            }
        }
    }

    pub fn render(sys: ParticleSystem, batch: *BatchRenderer) void {
        for (sys.emitters) |em| {
            if (!em.active) continue;
            for (0..em.count) |n| {
                const p = em.particle(n, sys.time);
                const sprite = sprites.get(em.sprite.?);
                batch.render(.{
                    // TODO I dislike this conversion
                    .src = .{
                        .x = @floatFromInt(sprite.bounds.x),
                        .y = @floatFromInt(sprite.bounds.y),
                        .w = @floatFromInt(sprite.bounds.w),
                        .h = @floatFromInt(sprite.bounds.h),
                    },
                    .dst = .{ .x = p.pos[0], .y = p.pos[1], .w = p.sz, .h = p.sz },
                });
            }
        }
    }
};
