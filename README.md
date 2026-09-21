# wasm-hotswap

Swap a running wasm module for another without losing state. A candidate is
qualified against the real cycle budget before it is allowed to go live.

```
nix develop
zig build run -Doptimize=ReleaseFast
```

zig 0.16.0, wasmtime 48.0.0, aarch64-darwin. wasmtime is linked statically.

## Mechanism

| | |
|---|---|
| Shared state | Both modules are built `--import-memory --shared-memory`. The host creates one `wasmtime_sharedmemory_t` and passes it to every instance |
| Swap | Instantiate the new module against that memory, repoint the `step` handle. No serialization, no memcpy, no migration |
| State location | `abi.zig` pins `State` to `0x80000`, above the data segments and the 16 KiB shadow stack |
| Yield point | Between `step()` calls |
| Qualification | Candidate runs on its own store and its own memory, seeded with a copy of live state, for 200 cycles at the real budget |
| Promotion | Only on pass. A rejected candidate never touches live state |
| Epoch | Watchdog, not scheduler. Tripping it is a rejection, not a yield |

## Rejection criteria

| | |
|---|---|
| `overran` | Tripped the epoch watchdog: cannot hold the cycle budget |
| `torn` | `seq` fell behind `tick`: published a half-applied update |
| `wrong_progress` | Did not advance `tick` by exactly the work it was handed |
| `out_of_range` | Left a state field outside its declared range |
| `trapped` | Any other trap |

## Output

```
--- v1 live ---
  after 2 cycles | v1 tick=40000 seq=40000 accum=40000.0 phase=0.00

--- candidate v2 ---
  v2: PASS  worst 0.378ms of 1.000ms budget (62% headroom)
  promoted
  after 2 cycles | v2 tick=80000 seq=80000 accum=160000.0 phase=0.00

--- candidate v3 ---
  v3: REJECT  overran on cycle 0
  not promoted, v2 keeps running
  after 2 cycles | v2 tick=120000 seq=120000 accum=280000.0 phase=0.00

  live state never touched by a rejected candidate
  torn: no
```

`tick` is continuous across the swap. `accum` changes slope from +1/iter to
+3/iter. `torn: no` because a qualified guest is never preempted.

## Size

| | binary | stripped |
|---|---|---|
| ReleaseFast | 13.5 MB | 12.5 MB |
| ReleaseSmall | 13.5 MB | 12.5 MB |

Almost entirely wasmtime, mostly Cranelift. Shipping AOT `.cwasm` and building
wasmtime without the compiler should reach low single-digit MB. Upstream's own
trimmed build is a 1.8 MB static archive against 39 MB for the full one.

## Known limits

| | |
|---|---|
| Qualification is not proof | 200 cycles of observed behaviour, not a bound. Worst case may be outside the sample |
| Timing measured on darwin | Not an RT kernel. Numbers do not transfer to the target |
| No RT setup | No `mlockall`, no `SCHED_FIFO`, no core pinning, no pre-faulting |
| Cranelift runs on target | JIT compilation in-process. AOT + a compiler-less build is the RT-correct shape |
| `module_deserialize` is not a sandbox | Upstream: "not safe to receive arbitrary user input". AOT must happen on trusted infra, signed |
| No capability surface | Guests import exactly one thing, `env.memory`. No host functions yet |
| Instances live as long as their store | Cannot free an instance, only a store. Long runs need store rotation |
| No rollback | Zero-copy swap means no prior state to return to. Mitigated by qualifying first, not solved |
| Trap-based memory safety | wasmtime uses signal handlers for OOB. `signals_based_traps` can be turned off for determinism, at a throughput cost |

## Layout

| | |
|---|---|
| `abi.zig` | `State` struct + fixed address |
| `guest_v1.zig` | `phase += 0.25`, `accum += 1` |
| `guest_v2.zig` | `phase += 0.75`, `accum += 3` |
| `guest_v3.zig` | Correct but too slow. Exists to be rejected |
| `wasmtime.zig` | Zig wrapper: errors, ownership, traps as error values |
| `host.zig` | Engine config, shared memory, qualification, promotion |
| `build.zig` | Builds the guests, embeds them in the host, links wasmtime static |
| `flake.nix` | zig + wasmtime C API (upstream tarball, for the static archive) |

## License

Apache License 2.0, see [LICENSE](LICENSE).

The host statically links wasmtime, which is Apache-2.0 WITH LLVM-exception.
That exception waives the attribution conditions for portions embedded into
object form by compilation, so the built binary carries no notice obligation.
