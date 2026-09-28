//! The contract between the host and every guest version.
//!
//! Guests import `env.memory` and `env.sensorValue`, nothing else.
//!
//! A fixed-address header records which `State` layout the bytes after it are
//! in. Without it a swap between guests built against different layouts would
//! reinterpret the same bytes silently, because zero-copy means nothing looks.
//!
//! The header itself never changes shape. Everything after it may.
//!
//! Sensor data has no address at all, so no guest can write it.

const std = @import("std");

pub const REGION_ADDR: usize = 0x8_0000; // 512 KiB, above data and shadow stack

/// The host/guest protocol block. Host-owned and never changes shape, which is
/// what lets everything after it version freely.
///
/// `tick` and `seq` live here rather than in `State` because they are not the
/// guest's data. They answer the host's question, "I handed you this much work,
/// did you complete exactly that much and commit all of it". The guest writes
/// them because only it knows where it got to mid-loop.
pub const Header = extern struct {
    /// Fingerprint of the layout the state bytes are currently in.
    layout: u32,
    /// Monotonic work counter.
    tick: u64,
    /// Bumped once per fully-applied iteration. Behind `tick` means the guest
    /// was interrupted mid-update and the state is torn.
    seq: u64,
};

/// Bump when the meaning of a field changes at a stable shape, which the
/// fingerprint cannot see: turns into radians, milliseconds into seconds. It is
/// mixed into every hash, so a bump reads as a layout change and demands a
/// migration like any other.
pub const SCHEMA: u32 = 1;

pub inline fn header() *volatile Header {
    return @ptrFromInt(REGION_ADDR);
}

pub inline fn state(comptime T: type) *volatile T {
    return @ptrFromInt(REGION_ADDR + @sizeOf(Header));
}

fn feed(acc: *u32, bytes: []const u8) void {
    for (bytes) |b| {
        acc.* ^= b;
        acc.* *%= 16777619;
    }
}

/// Fingerprint of a struct's shape, computed at compile time. Changes whenever
/// a field is added, removed, renamed, retyped or moved, so a layout change
/// cannot be forgotten. A change of meaning at a stable shape is invisible to
/// it, which is what `SCHEMA` is for.
pub fn layoutHash(comptime T: type) u32 {
    return comptime blk: {
        var h: u32 = 2166136261;
        feed(&h, std.mem.asBytes(&SCHEMA));
        for (@typeInfo(T).@"struct".fields) |fld| {
            feed(&h, fld.name);
            feed(&h, @typeName(fld.type));
            feed(&h, std.mem.asBytes(&@as(u32, @offsetOf(T, fld.name))));
            feed(&h, std.mem.asBytes(&@as(u32, @sizeOf(fld.type))));
        }
        feed(&h, std.mem.asBytes(&@as(u32, @sizeOf(T))));
        break :blk h;
    };
}

/// Guest-owned domain state. The host never reads a byte of it, which is what
/// lets it change shape between versions. A guest enforcing its own invariants
/// traps, and a trap is already a rejection.
pub const State = extern struct {
    accum: f64,
    phase: f64,
};

/// Appends a derived field. Migrated from `State` by the guests that use it.
pub const StateV2 = extern struct {
    accum: f64,
    phase: f64,
    /// Mean accumulation per tick, computed at migration.
    drift: f64,
};

/// Enough for any layout so far. The host copies this much when seeding a
/// candidate's scratch memory, without knowing which layout it holds.
pub const REGION_SIZE: usize = 64;

/// Host-side sensor frame. Published between `step()` calls, the only moment no
/// guest is running, so no seqlock is needed.
pub const Sensors = struct {
    frame: u64,
    value: f64,
};
