//! Guest v1. Advances phase by 0.25 per iteration.

const abi = @import("abi.zig");

/// Do `iters` units of work.
///
/// This is the yield point: the host may swap the module out between calls, or
/// cut the loop short by exhausting fuel or advancing the epoch.
export fn step(iters: u32) void {
    const s = abi.state();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        s.tick += 1;
        s.accum += 1.0;
        var p = s.phase + 0.25;
        if (p >= 1.0) p -= 1.0;
        s.phase = p;
        // Published last: seq == tick means the iteration completed.
        s.seq += 1;
    }
    s.running_version = 1;
}
