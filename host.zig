//! Hot-swap wasm guests over a linear memory the host owns.
//!
//! A candidate module is never swapped into the live loop on trust. It is first
//! run against a scratch copy of the live state, on its own store and its own
//! memory, under the real cycle budget. Only a module that holds the deadline,
//! never tears, and makes exactly the progress it promised gets promoted.
//!
//! A candidate built against a different `State` layout migrates the scratch
//! copy first and is then qualified on the result, so a migration is judged by
//! how the state it produced behaves, not by whether it returned zero.
//!
//! Sensor samples arrive as a host call, so a guest has no way to write them.
//!
//! Epoch is a watchdog here, not a scheduler: tripping it is a rejection.

const std = @import("std");
const abi = @import("abi.zig");
const wt = @import("wasmtime.zig");

const PAGES: u64 = 16;
const CYCLE_NS: u64 = 1_000_000;
/// Migration is swap latency rather than cycle latency, so it gets its own,
/// larger budget. Still bounded: a swap that never finishes is a failed swap.
const MIGRATE_NS: u64 = 10_000_000;
const WORK: i32 = 20_000;
const QUALIFY_CYCLES = 200;

const v1_wasm = @embedFile("guest_v1.wasm");
const v2_wasm = @embedFile("guest_v2.wasm");
const v3_wasm = @embedFile("guest_v3.wasm");
const v4_wasm = @embedFile("guest_v4.wasm");

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
    /// Wants a different layout but ships no way to get there.
    no_migration,
    /// Its migration declined the layout it was handed.
    migration_refused,
    /// Migration returned success without leaving the declared layout behind.
    migration_incomplete,
    /// Migration could not hold its own, larger budget.
    migration_overran,
    /// Any other trap.
    trapped,
};

const Report = union(enum) {
    pass: struct { worst: u64, migrated: bool },
    /// `from` and `want` are only meaningful for the migration rejections, and
    /// are what make those messages actionable rather than a bare tag.
    fail: struct { why: Reject, cycle: u32, from: u32 = 0, want: u32 = 0 },
};

/// A guest's declared layout, or null if it does not say. Every guest here
/// exports it, so null means a module that does not meet the ABI at all.
///
/// Needs its own deadline like any other call: with epoch interruption on, a
/// store whose deadline has not been armed traps immediately.
fn declaredLayout(inst: *const wt.Instance, store: wt.Store) ?u32 {
    const f = inst.getFunc("layout") orelse return null;
    store.setEpochDeadline(1);
    var out: [1]wt.Val = undefined;
    f.call(&.{}, &out) catch return null;
    return @bitCast(out[0].i32);
}

/// Bring the memory `inst` was instantiated against up to the layout it
/// declares. `hdr` points into that same memory, which is scratch during
/// qualification and live during promotion.
fn migrate(
    inst: *const wt.Instance,
    store: wt.Store,
    hdr: *volatile abi.Header,
    want: u32,
    wd: *Watchdog,
) ?Reject {
    const f = inst.getFunc("migrate") orelse return .no_migration;

    store.setEpochDeadline(1);
    wd.arm(MIGRATE_NS);
    defer wd.disarm();

    var out: [1]wt.Val = undefined;
    f.call(&.{.{ .i32 = @bitCast(hdr.layout) }}, &out) catch |err| {
        return if (err == error.Interrupt) .migration_overran else .trapped;
    };
    if (out[0].i32 != 0) return .migration_refused;
    // Success is not the migration's word for it. The header has to show it.
    if (hdr.layout != want) return .migration_incomplete;
    return null;
}

/// Run `module` against a throwaway copy of the live region and decide whether
/// it may go live. Its own store and memory, so a bad candidate cannot touch
/// live state, and neither can a bad migration.
///
/// `sample` is held fixed for the run: a candidate's timing must not depend on
/// what the sensor happened to read.
fn qualify(
    engine: wt.Engine,
    module: wt.Module,
    live: wt.SharedMemory,
    sample: f64,
    wd: *Watchdog,
) !Report {
    const memory = try wt.SharedMemory.init(engine, PAGES);
    defer memory.deinit();
    const store = wt.Store.init(engine);
    defer store.deinit();

    copyRegion(memory, live);
    const hdr = memory.ptrAt(abi.Header, abi.REGION_ADDR);

    var scratch = sample;
    var instance = try wt.Instance.init(store, module, &.{
        .{ .shared_memory = memory },
        wt.funcReadF64(store, &scratch),
    });
    const want = declaredLayout(&instance, store) orelse return error.MissingLayoutExport;

    var migrated = false;
    if (want != hdr.layout) {
        // The scratch memory is what `migrate` sees, because the guest's fixed
        // address resolves inside whichever memory it was instantiated against.
        const from = hdr.layout;
        if (migrate(&instance, store, hdr, want, wd)) |why| {
            // For an incomplete migration the useful number is where the header
            // was left, not where it started.
            const shown = if (why == .migration_incomplete) hdr.layout else from;
            return .{ .fail = .{ .why = why, .cycle = 0, .from = shown, .want = want } };
        }
        migrated = true;
    }

    const func = instance.getFunc("step") orelse return error.MissingStepExport;

    var worst: u64 = 0;
    var n: u32 = 0;
    while (n < QUALIFY_CYCLES) : (n += 1) {
        const tick_before = hdr.tick;

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

        if (hdr.seq != hdr.tick) return .{ .fail = .{ .why = .torn, .cycle = n } };
        if (hdr.tick - tick_before != WORK) {
            return .{ .fail = .{ .why = .wrong_progress, .cycle = n } };
        }
    }
    return .{ .pass = .{ .worst = worst, .migrated = migrated } };
}

fn copyRegion(dst: wt.SharedMemory, src: wt.SharedMemory) void {
    const d = dst.data() + abi.REGION_ADDR;
    const s = src.data() + abi.REGION_ADDR;
    @memcpy(d[0..abi.REGION_SIZE], s[0..abi.REGION_SIZE]);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn report(name: []const u8, r: Report) bool {
    switch (r) {
        .pass => |p| {
            const headroom = 100.0 * (1.0 - ms(p.worst) / ms(CYCLE_NS));
            std.debug.print(
                "  {s}: PASS  worst {d:.3}ms of {d:.3}ms budget ({d:.0}% headroom){s}\n",
                .{ name, ms(p.worst), ms(CYCLE_NS), headroom, if (p.migrated) ", migrated" else "" },
            );
            return true;
        },
        .fail => |f| {
            std.debug.print("  {s}: REJECT  {s} on cycle {d}\n", .{ name, @tagName(f.why), f.cycle });
            switch (f.why) {
                .no_migration => std.debug.print(
                    \\      live state is layout {x:0>8}, {s} was built against {x:0>8}
                    \\      it exports no `migrate`, so there is no way to get from one to the other
                    \\      add: export fn migrate(from: u32) i32
                    \\
                , .{ f.from, name, f.want }),
                .migration_refused => std.debug.print(
                    \\      {s}.migrate({x:0>8}) returned nonzero: it does not know that source layout
                    \\      it can only migrate state it recognises, and live state is not it
                    \\
                , .{ name, f.from }),
                .migration_incomplete => std.debug.print(
                    \\      {s}.migrate returned 0 but left the header at {x:0>8}, expected {x:0>8}
                    \\      a migration must write the new layout hash into the header itself
                    \\
                , .{ name, f.from, f.want }),
                .migration_overran => std.debug.print(
                    "      {s}.migrate exceeded its {d:.0}ms budget\n",
                    .{ name, ms(MIGRATE_NS) },
                ),
                else => {},
            }
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

fn publish(sensors: *abi.Sensors, value: f64) void {
    sensors.frame +%= 1;
    sensors.value = value;
}

/// Prints the header, which is all the host can see. `accum`, `phase` and
/// anything else a guest keeps is private to it.
fn dump(label: []const u8, running: []const u8, mem: wt.SharedMemory, sensors: abi.Sensors) void {
    const hdr = mem.ptrAt(abi.Header, abi.REGION_ADDR);
    std.debug.print("  {s}| {s} tick={d} seq={d} frame={d} layout={x:0>8}\n", .{
        label, running, hdr.tick, hdr.seq, sensors.frame, hdr.layout,
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
    const mod_v4 = try wt.Module.init(engine, v4_wasm);
    defer mod_v4.deinit();

    const memory = try wt.SharedMemory.init(engine, PAGES);
    defer memory.deinit();

    const region = memory.data() + abi.REGION_ADDR;
    @memset(region[0..abi.REGION_SIZE], 0);

    // Lives in host memory, not linear memory. The guest sees only the value.
    var sensors: abi.Sensors = .{ .frame = 0, .value = 1.0 };

    var wd = Watchdog{ .engine = engine, .start = nowNs() };
    const thread = try std.Thread.spawn(.{}, Watchdog.run, .{&wd});
    defer {
        wd.stop.store(true, .release);
        thread.join();
    }

    const imports = [_]wt.Extern{
        .{ .shared_memory = memory },
        wt.funcReadF64(store, &sensors.value),
    };

    var instance = try wt.Instance.init(store, mod_v1, &imports);
    var func = instance.getFunc("step").?;

    // The host never learns what a layout *is*, only whether two of them agree.
    // State starts zeroed, and whichever guest boots first decides what those
    // zeros mean by declaring its own.
    memory.ptrAt(abi.Header, abi.REGION_ADDR).layout =
        declaredLayout(&instance, store) orelse return error.MissingLayoutExport;

    // The host promoted it, so the host knows what is running. Asking the guest
    // to write its own version into shared state would be it reporting back
    // something already known here.
    var running: []const u8 = "v1";

    std.debug.print("--- v1 live ---\n", .{});
    for (0..2) |_| {
        publish(&sensors, 1.0);
        try cycle(func, store, &wd);
    }
    dump("after 2 cycles ", running, memory, sensors);

    const candidates = [_]struct { name: []const u8, module: wt.Module }{
        .{ .name = "v2", .module = mod_v2 },
        .{ .name = "v3", .module = mod_v3 },
        .{ .name = "v4", .module = mod_v4 },
    };

    for (candidates) |cand| {
        std.debug.print("\n--- candidate {s} ---\n", .{cand.name});
        if (report(cand.name, try qualify(engine, cand.module, memory, sensors.value, &wd))) {
            var next = try wt.Instance.init(store, cand.module, &imports);
            const want = declaredLayout(&next, store).?;
            const hdr = memory.ptrAt(abi.Header, abi.REGION_ADDR);

            if (want != hdr.layout) {
                // State is 48 bytes, so keeping a copy costs nothing and buys
                // the rollback a zero-copy swap otherwise cannot have.
                var snapshot: [abi.REGION_SIZE]u8 = undefined;
                @memcpy(&snapshot, region[0..abi.REGION_SIZE]);

                if (migrate(&next, store, hdr, want, &wd)) |why| {
                    @memcpy(region[0..abi.REGION_SIZE], &snapshot);
                    std.debug.print("  live migration {s}, rolled back\n", .{@tagName(why)});
                    continue;
                }
                std.debug.print("  live state migrated\n", .{});
            }
            instance = next;
            func = instance.getFunc("step").?;
            running = cand.name;
            std.debug.print("  promoted\n", .{});
        } else {
            std.debug.print("  not promoted, {s} keeps running\n", .{running});
        }
        for (0..2) |_| {
            publish(&sensors, 1.0);
            try cycle(func, store, &wd);
        }
        dump("after 2 cycles ", running, memory, sensors);
    }

    std.debug.print("\n  live state never touched by a rejected candidate\n", .{});
    const hdr = memory.ptrAt(abi.Header, abi.REGION_ADDR);
    std.debug.print("  torn: {s}\n", .{if (hdr.seq == hdr.tick) "no" else "yes"});
}
