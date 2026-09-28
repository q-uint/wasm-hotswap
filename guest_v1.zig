//! Guest v1. Advances phase by 0.25 and integrates the sensor once per unit.

const abi = @import("abi.zig");
const sensor = @import("sensor.zig");

const S = abi.State;

export fn layout() u32 {
    return abi.layoutHash(S);
}

/// Do `iters` units of work.
///
/// This is the yield point: the host may swap the module out between calls, or
/// cut the loop short by advancing the epoch.
export fn step(iters: u32) void {
    const h = abi.header();
    const s = abi.state(S);
    const sample = sensor.value();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        h.tick += 1;
        s.accum += sample;
        var p = s.phase + 0.25;
        if (p >= 1.0) p -= 1.0;
        s.phase = p;
        // Published last: seq == tick means the iteration completed.
        h.seq += 1;
    }
}
