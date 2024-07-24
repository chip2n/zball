// TODO use for all particle effects

const std = @import("std");
const root = @import("root");
const sprites = @import("sprite");
const m = @import("math");
const BatchRenderer = @import("batch.zig").BatchRenderer;

const Sprite = sprites.Sprite;

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
    active: bool = false,
    // sprite: ?Sprite = null,
    pos: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    time: f32 = 0,
    lifetime: f32 = 0,
};

const SpriteDesc = struct {
    sprite: Sprite,
    weight: f32,
};

const EmitterDesc = struct {
    /// The sprites to use for each particle, along with the factor of the lifetime they will be displayed
    sprites: []const SpriteDesc,

    /// How many particles to emit in one cycle
    count: usize,

    /// Maximum time each particle will live, in seconds
    lifetime: f32,

    /// Randomness of lifetime value
    lifetime_randomness: f32,

    /// The gravity applied to each particle
    gravity: f32,

    /// Defines circle in which the particles will spawn randomly
    spawn_radius: f32,
};

pub fn Emitter(comptime desc: EmitterDesc) type {
    const count = desc.count;
    const lifetime = desc.lifetime;
    const lifetime_randomness = desc.lifetime_randomness;
    const min_lifetime = lifetime * (1 - lifetime_randomness);
    const gravity = desc.gravity;

    const spawn_freq = lifetime / @as(f32, @floatFromInt(count));

    const weight_sum = blk: {
        var sum: f32 = 0;
        for (desc.sprites) |s| {
            sum += s.weight;
        }
        break :blk sum;
    };

    return struct {
        const Self = @This();

        pos: [2]f32 = .{ 0, 0 },

        particles: [count]Particle = .{.{}} ** count,
        idx: usize = 0,
        time: f32 = 0,
        spawn_timer: f32 = 0,
        prng: std.Random.DefaultPrng,

        pub fn init() Self {
            const prng = std.Random.DefaultPrng.init(0);
            return .{ .prng = prng };
        }

        pub fn update(self: *Self, dt: f32) void {
            const rng = self.prng.random();

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

            // TODO we need z index for this to look better
            // Time to spawn another particle?
            if (self.spawn_timer >= spawn_freq) {
                self.spawn_timer = 0;

                const len = rng.float(f32) * desc.spawn_radius;
                var pos = [2]f32{ len, 0 };
                const angle = rng.float(f32) * std.math.tau;
                m.vrot(&pos, angle);
                const vel = .{ 0, 0 };

                const p_lifetime = min_lifetime + rng.float(f32) * (lifetime - min_lifetime);

                // const sprite = desc.sprites[rng.weightedIndex(f32, &weights)].sprite;
                self.particles[self.idx] = .{
                    .active = true,
                    // .sprite = sprite,
                    .pos = m.vadd(self.pos, pos),
                    .vel = vel,
                    .time = 0,
                    .lifetime = p_lifetime,
                };
                self.idx = (self.idx + 1) % (count - 1);
            }
        }

        pub fn render(self: Self, batch: *BatchRenderer) void {
            for (self.particles) |p| {
                if (!p.active) continue;

                // Figure out which sprite should be rendered based on how long
                // the particle has been alive
                const sprite_factor = p.time / lifetime;
                std.debug.assert(p.time < lifetime);
                var sprite_id: Sprite = undefined;
                var i: f32 = 0;
                for (desc.sprites) |s| {
                    i += s.weight;
                    if (i >= sprite_factor * weight_sum) {
                        sprite_id = s.sprite;
                        break;
                    }
                } else continue;

                const sprite = sprites.get(sprite_id);
                const w: f32 = @floatFromInt(sprite.bounds.w);
                const h: f32 = @floatFromInt(sprite.bounds.h);
                batch.render(.{
                    .src = sprite.bounds,
                    .dst = .{
                        .x = p.pos[0] - w / 2,
                        .y = p.pos[1] - w / 2,
                        .w = w,
                        .h = h,
                    },
                });
            }
        }
    };
}
