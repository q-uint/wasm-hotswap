# wasm-hotswap

Swap a running wasm module for another without losing state. A candidate is
qualified against the real cycle budget before it is allowed to go live.

Sensor data arrives as a host call, so guests have no way to write it. A
candidate on a different state layout migrates a scratch copy and is qualified
on the result before live state is touched.

```
nix develop
zig build run -Doptimize=ReleaseFast
```

zig 0.16.0, wasmtime 48.0.0, aarch64-darwin. wasmtime is linked statically.

## Mechanism

| | |
|---|---|
| Shared state | Both modules are built `--import-memory --shared-memory`. The host creates one `wasmtime_sharedmemory_t` and passes it to every instance |
| Swap | Instantiate the new module against that memory, repoint the `step` handle. No serialization, no memcpy |
| State location | `abi.zig` pins a `Header` to `0x80000`, above the data segments and the 16 KiB shadow stack. Guest state follows it |
| Ownership | The header is the host/guest protocol and never changes shape. Everything after it is guest-owned and the host never reads a byte of it |
| Layout | The header records which layout the state is in. Guests declare theirs via a `layout()` export, and the host only ever compares the two |
| Sensors | `env.sensorValue`, a host call. The frame lives in host memory, never in linear memory |
| Yield point | Between `step()` calls. Also the only point sensor frames are published, which is why the frame needs no seqlock |
| Qualification | Candidate runs on its own store and its own memory, seeded with a copy of live state, for 200 cycles at the real budget |
| Promotion | Only on pass. A rejected candidate never touches live state |
| Epoch | Watchdog, not scheduler. Tripping it is a rejection, not a yield |

## Sensors

Injecting sensor data into linear memory needs a way to stop guests writing it,
and wasm has no intra-memory permissions. A second memory would give one, since
a memory index is an immediate operand and never computed, but nothing produces
multi-memory from source. LLVM's wasm loads and stores carry no memory index at
all, so it takes a wat shim, a post-link merge, and a validator to hold the
property.

A host call gets the same guarantee for none of that. There is no sensor region
in the guest's address space, so no guest can write one and nothing has to check
that it did not. The frame stays in host memory, outside wasm, so a bad guest
cannot corrupt it for its successors either.

The cost is a call. Measured against a 1 ms cycle:

| reads | cost |
|---|---|
| Once per `step()`, as these guests do | ~33 ns, 0.003% of budget |
| Per iteration, 20k per step | 0.66 ms, 66% of budget |

So this holds only while the sample is hoisted out of hot loops. A guest needing
bulk data per iteration wants a `read_frame(dst, len)` call that copies into the
guest's own memory once per cycle, where it can only corrupt its own copy.

## State migrations

Zero-copy swapping works because both modules read the same bytes as the same
struct. Change the struct and that stops being true, silently, because nothing
looks.

So the header carries a layout fingerprint: a compile-time hash over every
field's name, type, offset and size, mixed with a hand-bumped `SCHEMA`. It is
derived, so a structural change cannot fail to change it. `SCHEMA` covers the
one thing a hash cannot see, meaning changing at a stable shape, such as `phase`
moving from turns to radians.

A guest whose layout differs from the live state must export
`migrate(from: u32) i32`. Not exporting one is how a guest says it needs no
migration, and is caught rather than assumed:

```
  v2: REJECT  no_migration on cycle 0
      live state is layout 65f42c5c, v2 was built against c44c1389
      it exports no `migrate`, so there is no way to get from one to the other
      add: export fn migrate(from: u32) i32
```

Migration is not a separate trust question. It runs inside the gate that already
exists, on the scratch copy:

| | |
|---|---|
| 1 | Copy the live region into the candidate's own memory |
| 2 | Run `migrate` there, under its own 10 ms budget. Swap latency, not cycle latency, but still bounded |
| 3 | Require the header to show the new layout. Returning zero is not proof |
| 4 | Run the 200 qualification cycles **on the migrated state** |
| 5 | Only then snapshot live state, migrate it, and repoint |

A migration is therefore judged by how the state it produced behaves, not by
whether it returned success.

Step 5 also buys back rollback. A migrating swap is not zero-copy anyway, and
the region is 64 bytes, so the snapshot is free and a failed live migration is
restored.

### What the host is allowed to know

Nothing about guest state. It holds no layout constants and no struct for the
bytes after the header, so changing a layout never means rebuilding the host.
State starts zeroed and the first guest to boot declares what those zeros mean
through the same `layout()` export.

`tick` and `seq` live in the header rather than in guest state because they are
not the guest's data. They answer the host's question, "I handed you this much
work, did you complete exactly that much and commit all of it". The guest writes
them because only it knows where it got to mid-loop.

## Rejection criteria

| | |
|---|---|
| `overran` | Tripped the epoch watchdog: cannot hold the cycle budget |
| `torn` | `seq` fell behind `tick`: published a half-applied update |
| `wrong_progress` | Did not advance `tick` by exactly the work it was handed |
| `no_migration` | Wants a different layout but ships no way to get there |
| `migration_refused` | Its `migrate` declined the layout it was handed |
| `migration_incomplete` | `migrate` returned 0 without leaving the declared layout behind |
| `migration_overran` | `migrate` could not hold its own, larger budget |
| `trapped` | Any other trap |

## Output

```
--- v1 live ---
  after 2 cycles | v1 tick=40000 seq=40000 frame=2 layout=004db944

--- candidate v2 ---
  v2: PASS  worst 0.379ms of 1.000ms budget (62% headroom)
  promoted
  after 2 cycles | v2 tick=80000 seq=80000 frame=4 layout=004db944

--- candidate v3 ---
  v3: REJECT  overran on cycle 0
  not promoted, v2 keeps running
  after 2 cycles | v2 tick=120000 seq=120000 frame=6 layout=004db944

--- candidate v4 ---
  v4: PASS  worst 0.254ms of 1.000ms budget (75% headroom), migrated
  live state migrated
  promoted
  after 2 cycles | v4 tick=160000 seq=160000 frame=8 layout=05f01399

  live state never touched by a rejected candidate
  torn: no
```

Only the header is printed, because it is the only thing the host can see.
`accum` and `phase` are guest-owned and do not appear.

`tick` is continuous across every swap, including the migrating one. `frame` is
host-written and advances whether or not a swap happened. `torn: no` because a
qualified guest is never preempted.

v3 and v4 are both built against the newer layout. v3 migrated its scratch copy
and then failed on timing, which is why `layout` is still `004db944` afterwards
with v2 still running. v4 passed, so live state moved to `05f01399`.

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
| Minimal capability surface | Guests import one memory and one function. There is no way to grant a guest anything else yet, and no backpressure |
| Sensors are synchronous | Frames are published at the yield point. An asynchronous source would need a seqlock, and would make a candidate's timing depend on arrival, which qualification is trying to hold still |
| Sensor cost scales with reads | Free at one read per cycle, fatal at one per iteration. Nothing enforces that a guest hoists it |
| Migration correctness is not checked | Qualification judges the state a migration produced, not whether it produced the right one. A migration that mangles a field and still advances `tick` cleanly passes |
| Meaning changes need a hand | `SCHEMA` catches what the fingerprint cannot see, and nothing catches forgetting to bump `SCHEMA` |
| One migration hop | A guest migrates from the layout it was given or refuses. Skipping versions needs a chain, which nothing composes yet |
| Instances live as long as their store | Cannot free an instance, only a store. Long runs need store rotation |
| Rollback only covers migration | A migrating swap snapshots first, so a failed live migration is restored. A plain swap is still zero-copy with no prior state to return to, mitigated by qualifying first rather than solved |
| Trap-based memory safety | wasmtime uses signal handlers for OOB. `signals_based_traps` can be turned off for determinism, at a throughput cost |

## Layout

| | |
|---|---|
| `abi.zig` | `Header` and its fixed address, the state layouts, the fingerprint, host-side `Sensors` frame |
| `sensor.zig` | Guest-side sensor read. One import |
| `guest_v1.zig` | `phase += 0.25`, `accum += 1x` sensor |
| `guest_v2.zig` | `phase += 0.75`, `accum += 3x` sensor. Same layout as v1 |
| `guest_v3.zig` | New layout, migrates correctly, too slow to keep it. Exists to be rejected after migrating |
| `guest_v4.zig` | New layout, fast enough. Exists to be promoted |
| `migrate_v2.zig` | `State` to `StateV2`, shared by the guests on the newer layout |
| `wasmtime.zig` | Zig wrapper: errors, ownership, traps as error values |
| `host.zig` | Engine config, shared memory, sensor call, qualification, promotion |
| `build.zig` | Builds the guests, embeds them in the host, links wasmtime static |
| `flake.nix` | zig + wasmtime C API (upstream tarball, for the static archive) |

## License

Apache License 2.0, see [LICENSE](LICENSE).

The host statically links wasmtime, which is Apache-2.0 WITH LLVM-exception.
That exception waives the attribution conditions for portions embedded into
object form by compilation, so the built binary carries no notice obligation.
