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
- consumer-owned non-transferring inspection of the next descriptor when a
  scheduler must choose work before taking ownership
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

## Prepared optical execution owners

`AdaptiveOpticsHIL.Execution` binds the core's prepared optical path groups to
fixed HIL execution owners. Every owner has a stable run-local identity, exact
path-group/product slots, one bounded SPSC due-work ring, and one bounded SPSC
completion ring. A compatible core device batch remains one owner on its exact
prepared backend and compute device; descriptors never copy optical products
through host storage.

The default `SerialOpticalExecution()` retains
`AdaptiveOpticsSim.Plant.SerialOpticalPathBatchExecutor` as the canonical
oracle. An explicit `ExecutionOwnerConfiguration` selects either:

- `DeterministicExecutionOwners()`, which drives the same bounded owner paths
  synchronously and can vary completion order without creating tasks; or
- `AgentExecutionOwners(factory; placement)`, which creates one long-lived
  Agrona-style Agent.jl duty-cycle agent per owner during arm and reuses it
  until nominal stop.

The factory creates one independent Agent.jl idle strategy for every owner and
one for the coordinator wait path. Scheduler-managed placement is portable and
cooperative. `ThreadAssignedExecutionOwnerPlacement` assigns owners to unique
Julia default-pool threads. This mode must be armed, started, and run from one
sticky coordinator task on a different managed Julia thread; arm rejects a
coordinator/owner thread collision. The coordinator may use the default or
interactive pool. Optional CPU IDs use Agent.jl's ThreadPinning.jl extension
when the caller has loaded ThreadPinning.jl. Assignment or affinity does not
reserve a physical core, establish OS scheduling priority, or prove
SMT/interrupt isolation.
Preparation validates a declared core `CPUExecutionBudget` against an observed
`CPUExecutionEnvironment` without changing Julia, FFT, or BLAS thread settings.
Busy-spin strategies are appropriate only when the deployment has separately
reserved the corresponding cores and accepted their power and thermal cost.

Every `ExecutionOwnerConfiguration` also requires one immutable
`ExecutionOwnerOverloadPolicy`. A base policy classifies all owners as
required or optional and binds a concrete overload action, optional
execution-clock lateness limit, and recovery occupancy; stable
`ExecutionOwnerID` overrides may replace it for selected owners. The current
owner action is `FailRunOnOwnerOverload()` for both criticalities. Optional
work is never revoked after dispatch or mislabeled as shed without a core skip
disposition and an ownership-safe retained-product contract.

The HIL coordinator remains the sole plant-timeline and atmosphere writer. For
each due timestamp it performs the core
begin → materialize → seal → execute → complete contract, so independently
owned WFS and optional science paths may execute concurrently only after all
current-epoch inputs are materialized. Nominal stop closes every owner input,
collects one stop acknowledgement per owner, joins Agent runner tasks, and
verifies empty ring/accounting state. `serial_run_accounting` includes a cold snapshot
of these owners alongside port, pool, and lease accounting. Each coordinator,
path owner, and device-submission owner has one preallocated compact
first-failure slot and stop acknowledgement. Failure never retries or rolls
back a possibly mutated optical batch; the failed prepared run is discarded.
Deterministic fault tests exercise every owner-boundary stage and synthetic
device-owner failure classification. Vendor-specific accelerator
completion-fault injection is not generalized by this transport-neutral
package; hardware/backend tests must provide it where the vendor runtime
supports a controlled fault.

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

Command submission and its reserved terminal-outcome path are required
resources: pre-transfer `full` retains producer ownership, while every
transferred command must receive one outcome. Each acquisition port instead
requires an `AcquisitionOverloadPolicy` that declares required/optional
criticality, concrete full behavior, optional publication-lateness limit, and
recovery occupancy. Required acquisition loss fails the run. An optional
`DropNewestOnFull()` path may shed only the newly completed product, preserving
its assigned stream-sequence gap and reclaiming only producer-owned storage.
Raw frames are not implicitly coalesced and no runtime overload path changes
the prepared provider or fidelity.

The core future-effective command calendar is also bounded. When it cannot
admit another pending command, the HIL boundary publishes one correlated core
`RejectedCommand` outcome with reason `:calendar_capacity`; it never backdates
or silently discards the command. The initial single-host Gate 8 profile
selects no command-observation or telemetry taps. Independent bounded observer
taps remain Gate 10A work and therefore neither gate the canonical RTC
consumer nor participate in its buffer-reclamation path.

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
- same-session adapter readiness observed on that execution clock;
- typed stop requests, configured terminal events, failures, and immutable
  terminal records; and
- required execution-clock acknowledgement and ownership-drain deadlines.

User integration may establish readiness through any transport or local
mechanism, but the snapshot contains no connection, client/server, or health
protocol semantics. A prior session or another execution clock cannot arm a
run, and the selected execution-clock identity cannot change during an arm
attempt. Readiness exactly at the arm deadline is accepted; the first later
clock reading records an arm-timeout failure. Arm and active-run interval
checks use the same bounded modular arithmetic as execution-clock pacing,
including `Int64` representation wrap.

An optional `RTCIngressLivenessPolicy` binds the run's command endpoint, exact
execution-clock identity, and an inclusive timeout shorter than `2^63`
nanoseconds. Its origin is the transition to running. Only successful semantic
core admission resets it; enqueue, mapping, malformed/duplicate/rejected
traffic, application, and transport-health messages do not. The first
observation later than the deadline fails the operational run, terminally
accounts pending admitted commands, and leaves the held effective command and
physical optic unchanged. This is deliberately separate from replayable
plant-time command-silence behavior.

The serial path exposes the complete breaking lifecycle directly:

```julia
configuration = configure_serial_run(
    command_bridge, acquisition_ports;
    arm_timeout_ns=1_000_000_000,
    shutdown_policy=RunShutdownPolicy(
        acknowledgement_timeout_ns=100_000_000,
        drain_timeout_ns=500_000_000),
    ingress_liveness=RTCIngressLivenessPolicy(
        command_endpoint,
        execution_clock_identity(clock);
        timeout_ns=100_000_000))
run = prepare_serial_run(configuration)
attempt = begin_serial_arm!(run, clock)
readiness = AdapterReadinessSnapshot(
    run_session(run),
    execution_clock_identity(clock),
    AdapterReady,
    Clocks.time_nanos(clock))
armed = arm_serial_run!(attempt, readiness)
running = start_serial_run!(armed)

request = RunStopRequest(
    run_session(running),
    execution_clock_identity(clock),
    Clocks.time_nanos(clock))
begin_serial_stop!(running, request)
# Drain transport-facing completions and release leases between polls.
while progress_serial_shutdown!(running) != SerialShutdownFinalized
    yield()
end
```

Configuration derives the exact event loop from the command bridge and freezes
the serial topology and policies; it accepts no independent plant/event-loop
pair that could be mixed. Preparation resolves product sources from that same
event loop and allocates the command state, acquisition sequence state, and
workspaces without reading the clock or accepting traffic. An explicitly
configured Agent execution policy creates one task per already-prepared, stable
owner only during arm.
Runtime handles retain the exact prepared run, so state and workspace from
different runs cannot be combined. Clean stop requires quiescent current
resources and records either a typed request or terminal event. Runtime errors
release-publish the first compact owner record, close command and acquisition
ingress, stop semantic admission, and begin bounded acknowledgement and drain.
Transferred but unadmitted commands receive `RunNotAccepting`; admitted
commands receive one correlated failed core disposition without changing the
held optic. Completion and lease-return paths remain drainable until their
ordered closure point. The accepted readiness snapshot is retained once in
lifecycle state rather than copied into each product descriptor.

`serial_failure_accounting` identifies the stable first failure, concurrent
owner records, missing acknowledgements, and deadline state.
`serial_run_accounting` is the cold resource snapshot: after finalization, any
nonzero ring occupancy, nonfree payload state, active command correlation,
owner work imbalance, or retained optical-batch claim is an explicit deficit
owned by the named command, acquisition, path, or device owner. A deficit or
deadline violation produces `RunFailed`, never a clean stop. Recovery requires
a newly prepared run.

Runtime plant controls use the canonical typed command boundary. A prepared
core model may expose acquisition enablement, trigger start/stop,
shutter/calibration-source state, autonomous-optic enablement, or safe/hold
behavior through command endpoints with explicit schema, effective-time,
capacity, and state semantics. The companion does not add a second control
queue, accept callbacks, or mutate optical state itself. A change unsupported
by the prepared model requires another configure/prepare/arm cycle.

## Deterministic serial runtime

`AdaptiveOpticsHIL.Serial` composes one prepared
`AdaptiveOpticsSim.Plant` event loop with an event-loop command bridge and a
nonempty tuple of acquisition-completion ports. Arming captures one immutable
execution-clock mapping only after lifecycle validation; it does not add
wall-clock state to AdaptiveOpticsSim.

Each `step_serial_run!` call makes one bounded scheduling decision:

- process at most one already-transferred command whose receive timestamp does
  not follow the next plant event;
- report the time remaining until the next plant event; or
- process one complete plant timestamp, publish terminal command outcomes, and
  copy each newly complete acquisition into its prepared product pool.

The coordinator non-consumingly compares the next command receive timestamp
with the next plant event. A later command remains queue-owned while earlier
optical events are processed, then transfers exactly once when it is
chronologically next. An RTC adapter may therefore submit while the simulator
is catching up without forcing the command to overtake already scheduled
optical work or requiring the adapter to wait for a transient future-deadline
gap.

The step call never sleeps for a pending deadline, invokes callbacks, creates
tasks, or chooses transport. The default serial executor starts no workers.
With an explicit Agent execution-owner mode, an optical event waits at its prepared
materialization and execution barriers while the coordinator and already-armed
tasks poll only their bounded owner rings according to the selected idle
strategy. A caller may advance a `CachedNanoClock` exactly in deterministic tests
or apply its own pacing policy around a `SystemNanoClock` in production.

Acquisition publication observes descriptor and product-pool occupancy
separately, records exact execution-clock lateness and overload episodes, and
continues publishing independent required streams when an optional
drop-newest stream is full. A selected owner deadline is checked against the
same armed execution-clock mapping. Deadline/capacity policy failure records
bounded owner evidence and enters the same coordinated acknowledgement,
completion, outcome, and lease drain as a requested stop. Missing ownership or
acknowledgement at the configured execution-clock deadline remains visible in
the final accounting and fails the run.

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

## Fast development test loops

Package tests are split into `timing`, `lifecycle`, `ownership`, `ports`,
`serial`, and `execution` groups. Run only the groups affected by a change
during development:

```sh
timeout 120s julia --startup-file=no --project=. \
    test/runtests.jl execution
timeout 120s julia --startup-file=no --project=. \
    test/runtests.jl ports serial
```

`Pkg.test()` remains the complete package and Aqua gate. The benchmark-contract
tests are deterministic and bounded:

```sh
julia --compile=min -O0 --startup-file=no --project=benchmarks \
    benchmarks/test/runtests.jl gate8
julia --compile=min -O0 --startup-file=no --project=benchmarks \
    benchmarks/test/runtests.jl gate4a
julia --startup-file=no --project=benchmarks \
    benchmarks/test/runtests.jl gate4a-allocation
```

The four-thread Gate 8 runtime smoke covers the operational topology, burst,
shedding, overload, failure, and drain paths with small workloads. It is the
development and CI check; it is not durable latency evidence:

```sh
env JULIA_NUM_THREADS=4,0 OPENBLAS_NUM_THREADS=1 \
    OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 \
    timeout 120s julia --compile=min -O0 --startup-file=no \
    --project=benchmarks \
    benchmarks/test/gate8_runtime.jl runtime
env JULIA_NUM_THREADS=4,0 OPENBLAS_NUM_THREADS=1 \
    OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 \
    timeout 120s julia --compile=min -O0 --startup-file=no \
    --project=benchmarks \
    benchmarks/test/gate8_runtime.jl failure
```

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

The maintained Gate 8.9 contract separately qualifies the single-host,
in-memory, two-owner CPU runtime over the same reduced-order boundary. It
preserves exact serial/deterministic/Agent-owner replay and records fixed 2 kHz
target load, consumer interruption, optional-stream shedding, calibrated
capacity, near-saturation, saturation, required overload, fresh recovery,
injected owner failure, a named drain deficit, clean lifecycle timing, and a
300 s soak. This remains a runtime and lifecycle claim: external transport,
RTC-process latency, accelerator execution, full optical propagation, and
instrument-scale capacity are explicitly excluded. The frozen protocol and
claim limits are maintained in
[Gate 8.9 issue #25](https://github.com/DarrylGamroth/AdaptiveOpticsHIL.jl/issues/25).
The selected low-tail candidate assigns each owner to a distinct Julia thread
and CPU, pins all four Julia default-pool threads to distinct physical cores
with ThreadPinning.jl, and uses `Agent.BusySpinIdleStrategy` for owner and
coordinator barrier waits. It consumes CPU continuously while idle. The
qualifying process runs under Linux `SCHED_FIFO` priority 20; the benchmark
verifies the policy and priority on every Julia default-pool thread and records
their Linux thread and CPU IDs. This profile still does not reserve cores or
claim CPU/IRQ isolation.

CI runs the bounded benchmark-contract suite plus the focused four-thread
Gate 8.9 runtime smoke. The full Gate 8 campaign is a deliberate qualification
run, not a development test. It evaluates completed phases before entering the
300 s soak and generates durable evidence only from a clean revision after
every frozen gate passes. Gate 4A requires one Julia and BLAS thread:

```sh
julia --startup-file=no --project=benchmarks \
    benchmarks/benchmark_gate4a_serial_boundary.jl \
    --output benchmarks/results/gate4a/YYYY-MM-DD-serial-boundary.toml
```

Gate 8.9 requires four default-pool threads, no interactive-pool thread, and
one BLAS/FFT-provider thread:

```sh
JULIA_NUM_THREADS=4,0 OPENBLAS_NUM_THREADS=1 \
OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 \
chrt --fifo 20 julia --startup-file=no --project=benchmarks \
    benchmarks/benchmark_gate8_operational_runtime.jl \
    --output benchmarks/results/gate8/YYYY-MM-DD-operational-runtime.toml
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
- [HIL execution and placement](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl/blob/main/docs/hil/execution-and-placement.md)
- [HIL validation and acceptance](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl/blob/main/docs/hil/validation.md)

Requires Julia 1.12 or newer.
