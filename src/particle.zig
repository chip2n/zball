const std = @import("std");
const root = @import("root");
const sprites = @import("sprite");
const m = @import("math");
const BatchRenderer = @import("batch.zig").BatchRenderer;

const Sprite = sprites.Sprite;

const max_emitters = 32;

const p_size = .{ 1, 3 };

const ParticleEffect = union(enum) {
    none: void,
    explosion: struct {
        sprite: Sprite,
        start_angle: f32 = 0,
        sweep: f32 = std.math.tau,
    },
    flame: struct {
        sprite: Sprite,
    },
};

const Emitter = struct {
    start_time: f32 = 0,
    origin: [2]f32 = .{ 0, 0 },
    count: usize = 0,
    effect: ParticleEffect = .none,
    active: bool = false,

    /// Get position of particle N at time T
    fn particle(em: Emitter, n: usize, t: f32) struct { pos: [2]f32, sz: f32 } {
        const seed = @as(u64, @intFromFloat(em.start_time * 1000)) + @as(u64, @intCast(n));
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const dt = t - em.start_time;

        return switch (em.effect) {
            .none => .{ .pos = .{ 0, 0 }, .sz = 0 },
            .explosion => |e| blk: {
                const bw = root.brick_w;
                const bh = root.brick_h;
                const sz = p_size[0] + rng.float(f32) * (p_size[1] - p_size[0]);
                const pos = [2]f32{
                    em.origin[0] + rng.float(f32) * bw - bw / 2 - sz / 2,
                    em.origin[1] + rng.float(f32) * bh - bh / 2 - sz / 2,
                };
                var vel = [2]f32{ 1, 0 };
                m.vrot(&vel, rng.float(f32) * e.sweep + e.start_angle);

                const gravity = 100;

                const speed = rng.float(f32) * 150 + 10;
                vel = m.vmul(vel, speed);

                vel[1] = vel[1] + gravity * dt;

                break :blk .{
                    .pos = .{
                        pos[0] + vel[0] * dt,
                        pos[1] + vel[1] * dt + 0.5 * gravity * dt * dt,
                    },
                    .sz = sz,
                };
            },
            .flame => blk: {
                const pos = [2]f32{
                    em.origin[0],
                    em.origin[1],
                };
                break :blk .{ .pos = pos, .sz = 8 };
            },
        };
    }
};

pub const ParticleSystem = struct {
    emitters: [max_emitters]Emitter = .{.{}} ** max_emitters,
    time: f32 = 0,

    pub const EmitDesc = struct {
        origin: [2]f32,
        count: usize,
        effect: ParticleEffect,
    };
    pub fn emit(sys: *ParticleSystem, v: EmitDesc) void {
        for (&sys.emitters) |*em| {
            if (em.active) continue;
            em.* = .{
                .start_time = sys.time,
                .origin = v.origin,
                .count = v.count,
                .effect = v.effect,
                .active = true,
            };
            break;
        } else {
            std.log.debug("Max emitter count reached", .{});
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

            switch (em.effect) {
                .none => {},
                .explosion => |e| {
                    for (0..em.count) |n| {
                        const p = em.particle(n, sys.time);
                        const sprite = sprites.get(e.sprite);
                        batch.render(.{
                            .src = sprite.bounds,
                            .dst = .{ .x = p.pos[0], .y = p.pos[1], .w = p.sz, .h = p.sz },
                        });
                    }
                },
                .flame => |e| {
                    for (0..em.count) |n| {
                        const p = em.particle(n, sys.time);
                        const sprite = sprites.get(e.sprite);
                        batch.render(.{
                            .src = sprite.bounds,
                            .dst = .{ .x = p.pos[0], .y = p.pos[1], .w = p.sz, .h = p.sz },
                        });
                    }
                },
            }
        }
    }
};
