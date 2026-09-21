//! Guest v3. Correct results, but far too slow to hold the cycle budget.
//! Exists to be rejected by qualification.

const abi = @import("abi.zig");

export fn step(iters: u32) void {
    const s = abi.state();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        // Burns time. The `if` keeps the optimizer from deleting the loop.
        var grind: f64 = 0;
        var k: u32 = 0;
        while (k < 5000) : (k += 1) grind += @floatFromInt(k);
        if (grind < 0) return;

        s.tick += 1;
        s.accum += 3.0;
        var p = s.phase + 0.75;
        while (p >= 1.0) p -= 1.0;
        s.phase = p;
        s.seq += 1;
    }
    s.running_version = 3;
}
