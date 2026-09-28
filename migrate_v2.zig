//! Migration from `abi.State` to `abi.StateV2`, shared by the guests built
//! against the newer layout.
//!
//! Runs at the yield point with no guest executing, first on the candidate's
//! scratch copy and only later on live state, so it must be deterministic.

const abi = @import("abi.zig");

/// Returns 0 on success, nonzero to refuse. Refusing is a rejection, not a
/// trap: the host leaves live state alone and keeps the running guest.
pub fn run(from: u32) i32 {
    if (from != abi.layoutHash(abi.State)) return 1;

    // Read before writing: the two layouts overlap in memory.
    const old = abi.state(abi.State);
    const accum = old.accum;
    const phase = old.phase;
    const tick = abi.header().tick;

    abi.state(abi.StateV2).* = .{
        .accum = accum,
        .phase = phase,
        .drift = if (tick != 0) accum / @as(f64, @floatFromInt(tick)) else 0,
    };
    abi.header().layout = abi.layoutHash(abi.StateV2);
    return 0;
}
