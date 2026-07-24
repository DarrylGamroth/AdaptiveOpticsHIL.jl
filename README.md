# AdaptiveOpticsHIL.jl

[![CI](https://github.com/DarrylGamroth/AdaptiveOpticsHIL.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/DarrylGamroth/AdaptiveOpticsHIL.jl/actions/workflows/ci.yml)
[![Coverage](https://codecov.io/gh/DarrylGamroth/AdaptiveOpticsHIL.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/DarrylGamroth/AdaptiveOpticsHIL.jl)

Transport-neutral hardware-in-the-loop orchestration for adaptive-optics
simulations.

AdaptiveOpticsHIL.jl is an early-stage companion to AdaptiveOpticsSim.jl. It
will provide deterministic timing and bounded in-process interfaces without
embedding an RTC-specific transport. RTC integrations remain free to use TCP,
UDP, Aeron, iceoryx2, ZeroMQ, shared memory, or another transport appropriate
to the target controller.

## Execution-clock mapping

`AdaptiveOpticsHIL.Timing` maps canonical
`AdaptiveOpticsSim.Plant.PlantTimestamp` values onto an injected monotonic
nanosecond clock:

```julia
using AdaptiveOpticsHIL.Timing
using AdaptiveOpticsSim.Plant: PlantTimestamp
import Clocks

clock = Clocks.CachedNanoClock(0)
mapping = arm_execution_clock(clock, PlantTimestamp(0))
deadline = PlantTimestamp(500_000)

execution_time_until_ns(mapping, deadline) # 500_000
Clocks.advance!(clock, 500_007)
execution_lateness_ns(mapping, deadline)   # 7
```

The timing API measures exact signed offsets but does not sleep, poll, advance
plant time, or own a scheduler. `Clocks.SystemNanoClock` is the production
provider; `Clocks.CachedNanoClock` supports deterministic tests. Epoch clocks
are deliberately excluded from pacing and deadline measurement.

## Bounded in-process ownership

`AdaptiveOpticsHIL.Ownership` provides the transport-neutral data-plane
foundation for later command and acquisition ports:

- a fixed-capacity SPSC ring for compact isbits descriptors
- explicit success, full, empty, and closed results with close-and-drain
  behavior
- release/acquire sequence publication with independently written cursors
  separated by a conservative 128-byte distance
- a fixed payload pool with immutable pool, session, slot, and generation
  references
- explicit producer-owned, queued, consumer-leased, and free transitions

The warmed transfer operations do not block, yield, retry, invoke callbacks, or
allocate. Caller code owns its idle/backoff policy. Mutable frame and command
buffers stay in the prepared pool rather than being copied through ring slots;
failed and stale transitions leave ownership unchanged.

These are intentionally low-level foundations, not RTC transport APIs.
Canonical command and acquisition ports will compose them without embedding
TCP, UDP, Aeron, iceoryx2, ZeroMQ, or another wire protocol.

## Development sources

This early-stage package pins its current unregistered dependencies by Git
commit in `Project.toml` rather than relying on local paths or committing a
`Manifest.toml`. These source pins apply when this repository is the active
project; downstream environments must add the unregistered repositories
explicitly until they are registered. The maintained architecture and timing
contracts live in the AdaptiveOpticsSim specifications:

- [HIL package boundaries](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl/blob/main/docs/hil/package-boundaries.md)
- [HIL time, scheduling, and causality](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl/blob/main/docs/hil/time-and-scheduling.md)
- [HIL RTC ports and bounded handoffs](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl/blob/main/docs/hil/rtc-ports.md)
- [HIL validation and acceptance](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl/blob/main/docs/hil/validation.md)

Requires Julia 1.12 or newer.
