// TODO use for all particle effects

const std = @import("std");
const root = @import("root");
const sprites = @import("sprite");
const m = @import("math");
const BatchRenderer = @import("batch.zig").BatchRenderer;

const Sprite = sprites.Sprite;

const IRect = m.IRect;
const vadd = m.vadd;
const vmul = m.vmul;
const vrot = m.vrot;

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

const Particle = struct {
    seed: u8 = 0,
    active: bool = false,
    pos: [2]f32 = .{ 0, 0 },
    z: f32 = 0,
    vel: [2]f32 = .{ 0, 0 },
    time: f32 = 0,
    lifetime: f32 = 0,
};

pub const SpriteDesc = struct {
    sprite: Sprite,
    weight: f32,
    regions: []const struct { bounds: IRect, weight: f32 } = &.{},
};

const EmitterDesc = struct {
    /// Whether particles should keep emitting after lifetime expires
    loop: bool,

    /// How many particles to emit in one cycle
    count: usize,

    /// The base velocity for each particle
    velocity: [2]f32,

    /// Randomness of the velocity magnitude
    velocity_randomness: f32,

    /// Random rotation (in radians) applied to the base velocity
    velocity_sweep: f32,

    /// Maximum time each particle will live, in seconds
    lifetime: f32,

    /// Randomness of lifetime value
    lifetime_randomness: f32,

    /// The gravity applied to each particle
    gravity: f32,

    /// Defines circle in which the particles will spawn randomly
    spawn_radius: f32,

    /// Defines how packed the particles will be in one cycle (0 means even
    /// distribution, 1 means emit all particles instantly)
    explosiveness: f32,
};

// TODO Remove comptime usage - everything can be tweaked during runtime. Needs allocator in this case (unless we make count fixed)
pub fn Emitter(comptime desc: EmitterDesc) type {
    const count = desc.count;
    const lifetime = desc.lifetime;
    const lifetime_randomness = desc.lifetime_randomness;
    const min_lifetime = lifetime * (1 - lifetime_randomness);
    const gravity = desc.gravity;

    const spawn_freq = (lifetime / @as(f32, @floatFromInt(count)) * (1 - desc.explosiveness));

    return struct {
        const Self = @This();

        emitting: bool = false,
        pos: [2]f32 = .{ 0, 0 },

        /// The sprites to use for each particle, along with the factor of the lifetime they will be displayed
        sprites: []const SpriteDesc,

        particles: [count]Particle = .{.{}} ** count,
        idx: usize = 0,
        time: f32 = 0,
        spawn_timer: f32 = 0,
        cycle_timer: f32 = 0,
        next_spawn: f32 = 0,
        cycle_spawns: usize = 0,
        prng: std.Random.DefaultPrng,

        const EmitterInitDesc = struct {
            seed: u64,
            sprites: []const SpriteDesc,
        };

        pub fn init(v: EmitterInitDesc) Self {
            const prng = std.Random.DefaultPrng.init(v.seed);
            return .{
                .sprites = v.sprites,
                .prng = prng,
            };
        }

        pub fn update(self: *Self, dt: f32) void {
            self.time += dt;

            for (&self.particles) |*p| {
                p.vel[1] = p.vel[1] + gravity * dt;
                p.pos = .{
                    p.pos[0] + p.vel[0] * dt,
                    p.pos[1] + p.vel[1] * dt,
                };
                p.time += dt;

                if (p.time >= p.lifetime) p.active = false;
            }

            self.spawn_timer += dt;

            // Time to spawn another particle?
            if (self.emitting) {
                const start = self.cycle_timer;
                const end = start + dt;
                var t = start;
                while (t < end and self.cycle_spawns < count) {
                    if (self.next_spawn <= t) {
                        self.spawnParticle();
                    }
                    t += spawn_freq;
                }

                self.cycle_timer = end;
            } else {
                self.cycle_timer = 0;
                self.cycle_spawns = 0;
                self.next_spawn = 0;
            }

            // Next cycle?
            if (self.cycle_timer >= lifetime) {
                self.cycle_timer = 0;
                self.cycle_spawns = 0;
                self.next_spawn = 0;
                if (!desc.loop) self.emitting = false;
            }
        }

        fn spawnParticle(self: *Self) void {
            const rng = self.prng.random();
            const pos = blk: {
                const len = rng.float(f32) * desc.spawn_radius;
                var result = [2]f32{ len, 0 };
                const angle = rng.float(f32) * std.math.tau;
                vrot(&result, angle);
                break :blk result;
            };

            const vel = blk: {
                var result = desc.velocity;
                result = vmul(result, (1 - rng.float(f32) * desc.velocity_randomness));
                const angle = rng.float(f32) * desc.velocity_sweep;
                vrot(&result, angle);
                break :blk result;
            };

            const p_lifetime = min_lifetime + rng.float(f32) * (lifetime - min_lifetime);

            self.particles[self.idx] = .{
                .seed = rng.int(u8),
                .active = true,
                .pos = vadd(self.pos, pos),
                .z = rng.float(f32),
                .vel = vel,
                .time = 0,
                .lifetime = p_lifetime,
            };
            self.idx = (self.idx + 1) % (count - 1);
            self.cycle_spawns += 1;
            self.next_spawn += spawn_freq;
        }

        pub fn render(self: Self, batch: *BatchRenderer) void {
            // TODO cache
            const weight_sum = blk: {
                var sum: f32 = 0;
                for (self.sprites) |s| {
                    sum += s.weight;
                }
                break :blk sum;
            };

            for (self.particles) |p| {
                if (!p.active) continue;

                // Figure out which sprite should be rendered based on how long
                // the particle has been alive
                const sprite_factor = p.time / lifetime;
                std.debug.assert(p.time < lifetime);
                var sprite_desc: SpriteDesc = undefined;

                {
                    var i: f32 = 0;
                    for (self.sprites) |s| {
                        i += s.weight;
                        if (i >= sprite_factor * weight_sum) {
                            sprite_desc = s;
                            break;
                        }
                    } else continue;
                }

                const sprite = sprites.get(sprite_desc.sprite);

                // Should we use a region of this sprite, or the whole thing?
                const src = blk: {
                    if (sprite_desc.regions.len > 0) {
                        const idx = p.seed % sprite_desc.regions.len;
                        const region = sprite_desc.regions[idx].bounds;
                        break :blk IRect{
                            .x = sprite.bounds.x + region.x,
                            .y = sprite.bounds.y + region.y,
                            .w = region.w,
                            .h = region.h,
                        };
                    }
                    break :blk sprite.bounds;
                };

                const w: f32 = @floatFromInt(src.w);
                const h: f32 = @floatFromInt(src.h);
                batch.render(.{
                    .src = src,
                    .dst = .{
                        .x = p.pos[0] - w / 2,
                        .y = p.pos[1] - h / 2,
                        .w = w,
                        .h = h,
                    },
                    .z = p.z,
                });
            }
        }
    };
}

fn weightArray(arr: anytype) []const f32 {
    var weights: [arr.len]f32 = undefined;
    for (arr, &weights) |x, *w| {
        w.* = x.weight;
    }
    return weights;
}
