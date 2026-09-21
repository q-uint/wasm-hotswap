//! Hot-swap wasm guests over a linear memory the host owns.
//!
//! A candidate module is never swapped into the live loop on trust. It is first
//! run against a scratch copy of the live state, on its own store and its own
//! memory, under the real cycle budget. Only a module that holds the deadline,
//! never tears, and makes exactly the progress it promised gets promoted.
//!
//! Epoch is a watchdog here, not a scheduler: tripping it is a rejection.

const std = @import("std");
const abi = @import("abi.zig");
const wt = @import("wasmtime.zig");

const PAGES: u64 = 16;
const CYCLE_NS: u64 = 1_000_000;
const WORK: i32 = 20_000;
const QUALIFY_CYCLES = 200;

const v1_wasm = @embedFile("guest_v1.wasm");
const v2_wasm = @embedFile("guest_v2.wasm");
const v3_wasm = @embedFile("guest_v3.wasm");

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Advances the engine epoch once the armed deadline passes. Spins rather than
/// sleeps so the measurement reflects wasm's check granularity, not the OS
/// timer's.
const Watchdog = struct {
    engine: wt.Engine,
    start: u64,
    deadline: std.atomic.Value(u64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    fn elapsed(self: *const Watchdog) u64 {
        return nowNs() - self.start;
    }

    fn arm(self: *Watchdog, ns: u64) void {
        self.deadline.store(self.elapsed() + ns, .release);
    }

    fn disarm(self: *Watchdog) void {
        self.deadline.store(0, .release);
    }

    fn run(self: *Watchdog) void {
        while (!self.stop.load(.acquire)) {
            const d = self.deadline.load(.acquire);
            if (d != 0 and self.elapsed() >= d) {
                // Compare-and-swap, not a plain store: the main thread may have
                // disarmed and re-armed for the next cycle since the load above.
                // A failed exchange means exactly that, so the deadline we would
                // have cleared is gone and this increment belongs to nobody.
                // Dropping it keeps a fresh cycle from being killed before it
                // runs. Deadlines are monotonic, so there is no ABA.
                if (self.deadline.cmpxchgStrong(d, 0, .acq_rel, .acquire) == null) {
                    self.engine.incrementEpoch();
                }
            }
            std.atomic.spinLoopHint();
        }
    }
};

const Reject = enum {
    /// Tripped the epoch watchdog: cannot hold the cycle budget.
    overran,
    /// seq fell behind tick: published a half-applied update.
    torn,
    /// Did not advance tick by exactly the work it was handed.
    wrong_progress,
    /// Left a state field outside its declared range.
    out_of_range,
    /// Any other trap.
    trapped,
};

const Report = union(enum) {
    pass: u64,
    fail: struct { why: Reject, cycle: u32 },
};

/// Run `module` against a throwaway copy of `seed` and decide whether it may go
/// live. Its own store and memory, so a bad candidate cannot touch live state.
fn qualify(engine: wt.Engine, module: wt.Module, seed: abi.State, wd: *Watchdog) !Report {
    const memory = try wt.SharedMemory.init(engine, PAGES);
    defer memory.deinit();
    const store = wt.Store.init(engine);
    defer store.deinit();

    const st = memory.ptrAt(abi.State, abi.STATE_ADDR);
    st.* = seed;

    var instance = try wt.Instance.init(store, module, &.{.{ .shared_memory = memory }});
    const func = instance.getFunc("step") orelse return error.MissingStepExport;

    var worst: u64 = 0;
    var n: u32 = 0;
    while (n < QUALIFY_CYCLES) : (n += 1) {
        const tick_before = st.tick;

        store.setEpochDeadline(1);
        const t0 = wd.elapsed();
        wd.arm(CYCLE_NS);
        func.call(&.{.{ .i32 = WORK }}, &.{}) catch |err| {
            wd.disarm();
            return .{ .fail = .{
                .why = if (err == error.Interrupt) .overran else .trapped,
                .cycle = n,
            } };
        };
        wd.disarm();
        worst = @max(worst, wd.elapsed() - t0);

        if (st.seq != st.tick) return .{ .fail = .{ .why = .torn, .cycle = n } };
        if (st.tick - tick_before != WORK) {
            return .{ .fail = .{ .why = .wrong_progress, .cycle = n } };
        }
        if (!(st.phase >= 0.0 and st.phase < 1.0)) {
            return .{ .fail = .{ .why = .out_of_range, .cycle = n } };
        }
    }
    return .{ .pass = worst };
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn report(name: []const u8, r: Report) bool {
    switch (r) {
        .pass => |worst| {
            const headroom = 100.0 * (1.0 - ms(worst) / ms(CYCLE_NS));
            std.debug.print(
                "  {s}: PASS  worst {d:.3}ms of {d:.3}ms budget ({d:.0}% headroom)\n",
                .{ name, ms(worst), ms(CYCLE_NS), headroom },
            );
            return true;
        },
        .fail => |f| {
            std.debug.print("  {s}: REJECT  {s} on cycle {d}\n", .{ name, @tagName(f.why), f.cycle });
            return false;
        },
    }
}

/// One live cycle, with the watchdog armed at the budget.
fn cycle(func: wt.Func, store: wt.Store, wd: *Watchdog) !void {
    store.setEpochDeadline(1);
    wd.arm(CYCLE_NS);
    defer wd.disarm();
    try func.call(&.{.{ .i32 = WORK }}, &.{});
}

fn dump(label: []const u8, s: *volatile abi.State) void {
    std.debug.print("  {s}| v{d} tick={d} seq={d} accum={d:.1} phase={d:.2}\n", .{
        label, s.running_version, s.tick, s.seq, s.accum, s.phase,
    });
}

pub fn main() !void {
    const engine = wt.Engine.init(.{
        .epoch_interruption = true,
        .threads = true,
        .shared_memory = true,
    });
    defer engine.deinit();

    const store = wt.Store.init(engine);
    defer store.deinit();
    store.setEpochDeadline(1);

    const mod_v1 = try wt.Module.init(engine, v1_wasm);
    defer mod_v1.deinit();
    const mod_v2 = try wt.Module.init(engine, v2_wasm);
    defer mod_v2.deinit();
    const mod_v3 = try wt.Module.init(engine, v3_wasm);
    defer mod_v3.deinit();

    const memory = try wt.SharedMemory.init(engine, PAGES);
    defer memory.deinit();

    const st = memory.ptrAt(abi.State, abi.STATE_ADDR);
    st.* = .{ .running_version = 0, .tick = 0, .seq = 0, .accum = 0, .phase = 0 };

    var wd = Watchdog{ .engine = engine, .start = nowNs() };
    const thread = try std.Thread.spawn(.{}, Watchdog.run, .{&wd});
    defer {
        wd.stop.store(true, .release);
        thread.join();
    }

    var instance = try wt.Instance.init(store, mod_v1, &.{.{ .shared_memory = memory }});
    var func = instance.getFunc("step").?;

    std.debug.print("--- v1 live ---\n", .{});
    for (0..2) |_| try cycle(func, store, &wd);
    dump("after 2 cycles ", st);

    std.debug.print("\n--- candidate v2 ---\n", .{});
    if (report("v2", try qualify(engine, mod_v2, st.*, &wd))) {
        instance = try wt.Instance.init(store, mod_v2, &.{.{ .shared_memory = memory }});
        func = instance.getFunc("step").?;
        std.debug.print("  promoted\n", .{});
    }
    for (0..2) |_| try cycle(func, store, &wd);
    dump("after 2 cycles ", st);

    std.debug.print("\n--- candidate v3 ---\n", .{});
    if (report("v3", try qualify(engine, mod_v3, st.*, &wd))) {
        instance = try wt.Instance.init(store, mod_v3, &.{.{ .shared_memory = memory }});
        func = instance.getFunc("step").?;
        std.debug.print("  promoted\n", .{});
    } else {
        std.debug.print("  not promoted, v2 keeps running\n", .{});
    }
    for (0..2) |_| try cycle(func, store, &wd);
    dump("after 2 cycles ", st);

    std.debug.print("\n  live state never touched by a rejected candidate\n", .{});
    std.debug.print("  torn: {s}\n", .{if (st.seq == st.tick) "no" else "yes"});
}
