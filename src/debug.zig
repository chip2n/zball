const particle = @import("particle2.zig");
const sokol = @import("sokol");

const ig = @import("cimgui");

pub fn renderEmitterGui(emitter: anytype) void {
    ig.igText("%d", emitter.emitting);
    ig.igText("Pos: (%d, %d)", emitter.pos[0], emitter.pos[1]);
    ig.igText("Time: %.4g", emitter.time);
    ig.igText("Spawn timer: %.4g", emitter.spawn_timer);
    ig.igText("Cycle timer: %.4g", emitter.cycle_timer);
    ig.igText("Cycle spawns: %d", emitter.cycle_spawns);
    ig.igText("Next spawn: %.4g", emitter.next_spawn);
}
