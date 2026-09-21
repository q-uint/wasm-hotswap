//! Guest v2. Same ABI, different behaviour: phase advances by 0.75 and accum
//! climbs three times as fast. Separately compiled, separately instantiated.

const abi = @import("abi.zig");

export fn step(iters: u32) void {
    const s = abi.state();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        s.tick += 1;
        s.accum += 3.0;
        var p = s.phase + 0.75;
        while (p >= 1.0) p -= 1.0;
        s.phase = p;
        s.seq += 1;
    }
    s.running_version = 2;
}
