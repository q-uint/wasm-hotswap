//! The contract between the host and every guest version.
//!
//! The state struct is pinned to a fixed absolute address in linear memory, so
//! two independently compiled modules importing the *same* wasmtime memory see
//! literally the same bytes. The address sits above the guest's data segments
//! and 16 KiB shadow stack, so re-instantiating cannot clobber it.

pub const STATE_ADDR: usize = 0x8_0000; // 512 KiB

pub const State = extern struct {
    /// Which guest version last executed. Written by the guest.
    running_version: u32,
    _pad: u32 = 0,
    /// Monotonic work counter.
    tick: u64,
    /// Bumped once per fully-applied iteration. If seq is behind tick, the
    /// guest was interrupted mid-update and the state is torn.
    seq: u64,
    accum: f64,
    phase: f64,
};

pub inline fn state() *volatile State {
    return @ptrFromInt(STATE_ADDR);
}
