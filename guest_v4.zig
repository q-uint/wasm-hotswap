//! Guest v4. New layout, and fast enough to keep it. Tracks `drift` forward
//! instead of leaving it at its migrated value.

const abi = @import("abi.zig");
const sensor = @import("sensor.zig");
const migration = @import("migrate_v2.zig");

const S = abi.StateV2;

export fn layout() u32 {
    return abi.layoutHash(S);
}

export fn migrate(from: u32) i32 {
    return migration.run(from);
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
    s.drift = s.accum / @as(f64, @floatFromInt(h.tick));
}
