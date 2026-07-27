# AdaptiveOpticsHIL.jl

[![CI](https://github.com/DarrylGamroth/AdaptiveOpticsHIL.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/DarrylGamroth/AdaptiveOpticsHIL.jl/actions/workflows/ci.yml)
[![Coverage](https://codecov.io/gh/DarrylGamroth/AdaptiveOpticsHIL.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/DarrylGamroth/AdaptiveOpticsHIL.jl)

Transport-neutral hardware-in-the-loop orchestration for adaptive-optics
simulations.

AdaptiveOpticsHIL.jl is an early-stage companion to AdaptiveOpticsSim.jl. It
provides deterministic timing and bounded in-process interfaces without
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
foundation for command and acquisition ports:

- a fixed-capacity SPSC ring for compact, concrete, immutable descriptors
- explicit success, full, empty, and closed results with close-and-drain
  behavior
- release/acquire sequence publication with producer, consumer, and closure
  state isolated under a prepared 64- or 128-byte cache-line upper-bound
  contract
- cold layout evidence derived from both Julia field offsets and the actual
  cursor-object address before a ring is admitted
- owner-local slot cursors that preserve arbitrary-capacity indexing across
  `UInt64` publication-sequence wrap without division in descriptor transfer
- a fixed payload pool with immutable pool, session, slot, and generation
  references
- explicit producer-owned, queued, consumer-leased, return-queued, and free
  transitions
- one reserved SPSC return descriptor for every legally consumer-held lease;
  release publishes ownership back and the single pool owner reclaims storage

The warmed transfer operations do not block, yield, retry, invoke callbacks, or
allocate. Caller code owns its idle/backoff policy. Mutable frame and command
buffers stay in the prepared pool rather than being copied through ring slots;
failed and stale transitions leave ownership unchanged.
Pool identities are caller-declared and must be unique within one run/session;
ports reject the most immediate payload/credit collision during preparation.
Prepared port pools also require one concrete storage type and reject aliased
command buffers or acquisition-product storage.

Ports and payload claims expose typed full policies and cold
accepting/draining/drained lifecycle state. Command ingress closes before
terminal-outcome drain; completion and lease-return paths remain consumable
until their owners close and drain them. A pool must close new claims before
its return path can close. A valid first release cannot see ordinary full
backpressure because return capacity covers the pool's complete legal lease
set. Return-path full is an invariant result that preserves consumer ownership
and remains visible in bounded deficit accounting.

These are intentionally low-level foundations, not RTC transport APIs.

## RTC-facing ports

`AdaptiveOpticsHIL.Ports` composes the bounded primitives into three canonical
in-process boundaries:

- `CommandSubmissionPort` transfers an inline scalar or generation-checked
  command-buffer lease and reserves one terminal-outcome credit. Successful
  transfer is distinct from core validation, admission, effective
  application, and terminal disposition.
- `CommandCompletionPort` returns exactly one correlated boundary or core
  outcome. Consuming and releasing that outcome returns both the command
  buffer, when leased, and its reserved outcome credit.
- `AcquisitionCompletionPort` transfers complete
  `AdaptiveOpticsSim.Plant.AcquisitionProducts` values through an exact
  prepared product contract. Sampled controllable-optic/device feedback uses
  this same acquisition contract rather than command outcomes.

Command timing records either canonical plant receive time or an already
mapped, versioned external timestamp. Mapping estimation remains the
integration owner's responsibility. Complete-product lead time and maximum
lease hold time are explicit port data; run identity and adapter readiness
belong to `AdaptiveOpticsHIL.Lifecycle`. Acquisition-completion descriptors
carry the run/session identity but do not duplicate the run-level readiness
snapshot.

The ports contain no TCP, UDP, Aeron, iceoryx2, ZeroMQ, packet, client/server,
or progressive-readout semantics. Integration code decodes its chosen
transport into these descriptors and owns its own blocking, polling, or
backoff policy.

## Operational lifecycle

`AdaptiveOpticsHIL.Lifecycle` owns the transport-neutral operational contract:

- one positive `RunSessionID` shared by every resource in a run;
- immutable lifecycle parameters with a required relative arm timeout;
- configured, prepared, arming, armed, running, stopped, and failed phases;
- an inclusive arm window tied to the selected execution-clock identity;
- same-session adapter readiness observed on that execution clock; and
- typed stop requests, configured terminal events, failures, and immutable
  terminal records.

User integration may establish readiness through any transport or local
mechanism, but the snapshot contains no connection, client/server, or health
protocol semantics. A prior session or another execution clock cannot arm a
run, and the selected execution-clock identity cannot change during an arm
attempt. Readiness exactly at the arm deadline is accepted; the first later
clock reading records an arm-timeout failure. Arm and active-run interval
checks use the same bounded modular arithmetic as execution-clock pacing,
including `Int64` representation wrap.

The serial path exposes the complete breaking lifecycle directly:

```julia
configuration = configure_serial_run(
    command_bridge, acquisition_ports;
    arm_timeout_ns=1_000_000_000)
run = prepare_serial_run(configuration)
attempt = begin_serial_arm!(run, clock)
readiness = AdapterReadinessSnapshot(
    run_session(run),
    execution_clock_identity(clock),
    AdapterReady,
    Clocks.time_nanos(clock))
armed = arm_serial_run!(attempt, readiness)
running = start_serial_run!(armed)
```

Configuration derives the exact event loop from the command bridge and freezes
the serial topology and policies; it accepts no independent plant/event-loop
pair that could be mixed. Preparation resolves product sources from that same
event loop and allocates the command state, acquisition sequence state, and
workspaces without reading the clock, starting workers, or accepting traffic.
Runtime handles retain the exact prepared run, so state and workspace from
different runs cannot be combined. Clean stop requires quiescent current
resources and records either a typed request or terminal event; runtime errors
record failed termination. The accepted readiness snapshot is retained once
in lifecycle state rather than copied into each product descriptor.
Coordinated port closure, owner acknowledgement, bounded drain, and
ownership-deficit finalization remain later Gate 8 work and are not claimed by
this phase.

The current core serial event loop exposes no prepared nonstructural
acquisition, trigger, shutter, calibration-source, or optic-mode control seam,
so serial configuration rejects such declarations instead of accepting
callbacks or mutable structural changes.

## Deterministic serial runtime

`AdaptiveOpticsHIL.Serial` composes one prepared
`AdaptiveOpticsSim.Plant` event loop with an event-loop command bridge and a
nonempty tuple of acquisition-completion ports. Arming captures one immutable
execution-clock mapping only after lifecycle validation; it does not add
wall-clock state to AdaptiveOpticsSim.

Each `step_serial_run!` call makes one bounded, nonblocking decision:

- process at most one already-transferred command;
- report the time remaining until the next plant event; or
- process one complete plant timestamp, publish terminal command outcomes, and
  copy each newly complete acquisition into its prepared product pool.

The runtime never sleeps, retries, polls, invokes callbacks, starts workers, or
chooses placement or transport. A caller may advance a `CachedNanoClock`
exactly in deterministic tests or apply its own idle policy around a
`SystemNanoClock` in production.

Sampled actuator/device feedback is simply another independently scheduled
acquisition-completion stream. It does not share command cadence and never
masquerades as a command outcome.

The maintained vertical-slice test uses an in-memory fake RTC and a calibrated
reduced-order plant. It verifies exact cached-clock replay, equal-time command
causality, one terminal outcome per transferred command, complete lease
accounting at clean stop, and better residual rejection than open-loop,
wrong-sign, or delayed control. Warmed HIL-only port and publication operations
remain allocation-free. Inclusive serial event and routed-command steps have
2 KiB allocation ceilings because they include the current core reduced-order
event and event-loop admission work.

## Qualified benchmark evidence

The dedicated `benchmarks/` environment keeps HdrHistogram.jl and reporting
dependencies out of the runtime package. Its maintained Gate 4A contract
separates two questions over the same serial CPU, in-memory, reduced-order HIL
boundary:

- schedule-preserving 2 kHz fixed arrivals, including an injected fake-RTC
  consumer stall while absolute offered deadlines continue; and
- a separately labeled unpaced maximum-useful-throughput diagnostic.

Fixed-arrival evidence records complete-product publication, adapter
observation, RTC processing, command admission and application, first
command-responsive optical sample, bounded occupancy, sequence continuity,
drops/rejections, and quiescent lease/credit accounting. The artifact includes
raw sparse HdrHistogram data, supported percentiles, the exact source and
dependency revisions, machine/thread configuration, calibration, and claim
limits. The benchmark does not qualify a transport, external RTC, GPU,
multi-core placement, full optical propagation, or production instrument
capacity. The
[maintained Gate 4A artifact](benchmarks/results/gate4a/2026-07-24-serial-boundary.toml)
contains the current qualified baseline.

CI runs the short deterministic benchmark-contract suite. Durable evidence is
generated deliberately from a clean revision with one Julia and BLAS thread:

```sh
julia --startup-file=no --project=benchmarks \
    benchmarks/benchmark_gate4a_serial_boundary.jl \
    --output benchmarks/results/gate4a/YYYY-MM-DD-serial-boundary.toml
```

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
