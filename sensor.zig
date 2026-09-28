//! Guest-side sensor access.
//!
//! A call, not memory: there is no sensor region in the guest's address space,
//! so no guest can write one. Roughly 33 ns against a 1 ms cycle, so hoist it
//! out of hot loops as these guests do.

extern "env" fn sensorValue() f64;

pub inline fn value() f64 {
    return sensorValue();
}
