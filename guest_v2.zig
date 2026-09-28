//! Guest v2. Same layout as v1, different behaviour: phase advances by 0.75 and
//! the sensor is integrated three times as fast.

const abi = @import("abi.zig");
const sensor = @import("sensor.zig");

const S = abi.State;

export fn layout() u32 {
    return abi.layoutHash(S);
}

export fn step(iters: u32) void {
    const h = abi.header();
    const s = abi.state(S);
    const sample = sensor.value();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        h.tick += 1;
        s.accum += 3.0 * sample;
        var p = s.phase + 0.75;
        while (p >= 1.0) p -= 1.0;
        s.phase = p;
        h.seq += 1;
    }
}
