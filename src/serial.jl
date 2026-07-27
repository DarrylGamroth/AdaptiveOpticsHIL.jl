"""
    Serial

Deterministic, single-owner pacing of one prepared AdaptiveOpticsSim plant
event loop through transport-neutral HIL ports. This namespace never sleeps,
invokes callbacks, creates a task per event, or chooses an RTC transport. An
explicit execution policy may arm stable long-lived optical owners.
"""
module Serial

import Clocks
import ..Lifecycle

using AdaptiveOpticsSim.Plant: AcquisitionID, AcquisitionProducts
using AdaptiveOpticsSim.Plant: AbstractOpticalPathBatchExecutor
using AdaptiveOpticsSim.Plant: PlantTimestamp
using AdaptiveOpticsSim.Plant: PreparedPlantEventLoop
using AdaptiveOpticsSim.Plant: acquisition_product_sequence
using AdaptiveOpticsSim.Plant: acquisition_product_ready_timestamp
using AdaptiveOpticsSim.Plant: acquisition_products
using AdaptiveOpticsSim.Plant: command_disposition_count
using AdaptiveOpticsSim.Plant: copy_acquisition_product!
using AdaptiveOpticsSim.Plant: next_plant_event_timestamp
using AdaptiveOpticsSim.Plant: step_plant_events!
using AdaptiveOpticsSim.Plant: validate_acquisition_product_contract

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError
using ..Execution: AbstractOpticalExecutionConfiguration
using ..Execution: SerialOpticalExecution
using ..Execution: _arm_optical_execution!
using ..Execution: _execution_accounting
using ..Execution: _execution_accounting_is_quiescent
using ..Execution: _execution_is_armed, _execution_is_quiescent
using ..Execution: _mark_optical_execution_failed!
using ..Execution: _prepare_optical_execution
using ..Execution: _start_optical_execution!, _stop_optical_execution!
using ..Lifecycle: AdapterReadinessSnapshot
using ..Lifecycle: RunFailureEvent
using ..Lifecycle: RunLifecycleParameters, RunLifecycleState
using ..Lifecycle: RunPrepared, RunRunning
using ..Lifecycle: RunStopRequest, RunTerminalEvent
using ..Lifecycle: _begin_arm!, _complete_arm!, _fail_run!
using ..Lifecycle: _record_stop!, _require_phase
using ..Lifecycle: _start_run!
using ..Lifecycle: _validate_stop_event
import ..Lifecycle: run_arm_window, run_execution_clock_identity
import ..Lifecycle: run_adapter_readiness
import ..Lifecycle: run_phase, run_session, run_termination
using ..Ownership: PayloadLeaseRef, PayloadPoolAccounting, RingAccounting
using ..Ownership: PayloadTransitionSucceeded
using ..Ownership: ring_accounting
using ..Ports: AcquisitionCompletionPort
using ..Ports: CommandBridgeState, CommandBridgeWorkspace
using ..Ports: CommandSubmissionPort
using ..Ports: InlineCommandPayload, LeasedCommandPayload
using ..Ports: PortClosed, PortEmpty, PortFull, PortTransferSucceeded
using ..Ports: PreparedCommandBridge, StreamSequence
using ..Ports: abort_product!, acquisition_product_accounting
using ..Ports: acquisition_product_contract, active_command_correlations
using ..Ports: command_bridge_event_loop, command_completion_port
using ..Ports: command_disposition_workspace, command_payload_accounting
using ..Ports: command_submission_port, matching_acquisition_completion
using ..Ports: outcome_credit_accounting, plant_event_loop_state
using ..Ports: plant_event_loop_workspace
using ..Ports: port_status, process_next_command!
using ..Ports: producer_product, publish_command_dispositions!
using ..Ports: reclaim_command_payload_returns!
using ..Ports: reclaim_outcome_credit_returns!, reclaim_product_returns!
using ..Ports: try_claim_product!, try_publish!
using ..Timing: ExecutionClockMapping, arm_execution_clock
using ..Timing: execution_clock, execution_clock_identity
using ..Timing: execution_clock_origin_ns
using ..Timing: execution_time_until_ns
using ..Timing: _read_execution_clock

export SerialRunError
export ConfiguredSerialRun, PreparedSerialRun
export ArmingSerialRun, ArmedSerialRun, RunningSerialRun
export configure_serial_run, prepare_serial_run
export begin_serial_arm!, arm_serial_run!, start_serial_run!, stop_serial_run!
export SerialStepStatus, SerialCommandProcessed, SerialPlantEventProcessed
export SerialDeadlinePending, SerialEventLoopComplete
export SerialStepResult, serial_step_status, serial_step_timestamp
export serial_step_time_until_ns, step_serial_run!
export serial_products_published
export serial_optical_execution_configuration, serial_optical_execution
export SerialRunAccounting
export reclaim_serial_returns!, serial_run_accounting
export serial_run_is_quiescent

"""Invalid serial-run preparation, lifecycle, pacing, or accounting."""
struct SerialRunError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

struct PreparedAcquisitionPublisher{
    P<:AcquisitionCompletionPort,
    S<:AcquisitionProducts,
}
    id::AcquisitionID
    port::P
    source::S
end

struct _SerialConstructionToken end
const _SERIAL_CONSTRUCTION_TOKEN = _SerialConstructionToken()

"""
Immutable configured topology for one deterministic serial runtime.

The current core exposes no prepared nonstructural acquisition, trigger,
shutter, calibration-source, or optic-mode control seam, so this configuration
admits none. Such controls are added only with concrete preallocated core
support, never as arbitrary callbacks.
"""
struct ConfiguredSerialRun{
    L<:PreparedPlantEventLoop,
    B<:PreparedCommandBridge,
    A<:Tuple,
    E<:AbstractOpticalExecutionConfiguration,
}
    event_loop::L
    command_bridge::B
    acquisition_ports::A
    optical_execution::E
    lifecycle::RunLifecycleParameters
    nonstructural_controls::Tuple{}

    ConfiguredSerialRun(
        event_loop::L,
        command_bridge::B,
        acquisition_ports::A,
        optical_execution::E,
        lifecycle::RunLifecycleParameters,
        nonstructural_controls::Tuple{},
        ::_SerialConstructionToken) where {
        L<:PreparedPlantEventLoop,
        B<:PreparedCommandBridge,
        A<:Tuple,
        E<:AbstractOpticalExecutionConfiguration,
    } = new{L,B,A,E}(
        event_loop,
        command_bridge,
        acquisition_ports,
        optical_execution,
        lifecycle,
        nonstructural_controls)
end

"""
Single-writer run state. The command bridge owns the event-loop state and its
bounded command-correlation state; lifecycle and acquisition sequences remain
separate mutable state.
"""
mutable struct SerialRunState{B<:CommandBridgeState}
    const bridge::B
    const published_sequences::Memory{UInt64}
    const lifecycle::RunLifecycleState
    plant_event_steps::UInt64
    products_published::UInt64

    SerialRunState(
        bridge::B,
        published_sequences::Memory{UInt64},
        lifecycle::RunLifecycleState,
        plant_event_steps::UInt64,
        products_published::UInt64,
        ::_SerialConstructionToken) where {B<:CommandBridgeState} =
        new{B}(
            bridge,
            published_sequences,
            lifecycle,
            plant_event_steps,
            products_published)
end

"""
Preallocated event-loop, command-bridge, and acquisition-publication scratch
for one prepared serial run.
"""
struct SerialRunWorkspace{B<:CommandBridgeWorkspace}
    bridge::B
    product_leases::Memory{Base.RefValue{PayloadLeaseRef}}

    SerialRunWorkspace(
        bridge::B,
        product_leases::Memory{Base.RefValue{PayloadLeaseRef}},
        ::_SerialConstructionToken) where {B<:CommandBridgeWorkspace} =
        new{B}(bridge, product_leases)
end

"""
Prepared serial parameters, mutable state, and preallocated workspace. Runtime
handles retain this exact object, so state/workspace from different runs cannot
be mixed.
"""
struct PreparedSerialRun{
    C<:ConfiguredSerialRun,
    P<:Tuple,
    S<:SerialRunState,
    W<:SerialRunWorkspace,
    E<:AbstractOpticalPathBatchExecutor,
}
    configuration::C
    publishers::P
    state::S
    workspace::W
    execution::E

    PreparedSerialRun(
        configuration::C,
        publishers::P,
        state::S,
        workspace::W,
        execution::E,
        ::_SerialConstructionToken) where {
        C<:ConfiguredSerialRun,
        P<:Tuple,
        S<:SerialRunState,
        W<:SerialRunWorkspace,
        E<:AbstractOpticalPathBatchExecutor,
    } = new{C,P,S,W,E}(
        configuration,
        publishers,
        state,
        workspace,
        execution)
end

"""One active, inclusive-deadline arm attempt."""
struct ArmingSerialRun{
    R<:PreparedSerialRun,
    C<:Clocks.AbstractNanoClock,
}
    prepared::R
    clock::C
    plant_origin::PlantTimestamp
    window::Lifecycle.ArmWindow

    ArmingSerialRun(
        prepared::R,
        clock::C,
        plant_origin::PlantTimestamp,
        window::Lifecycle.ArmWindow,
        ::_SerialConstructionToken) where {
        R<:PreparedSerialRun,
        C<:Clocks.AbstractNanoClock,
    } = new{R,C}(prepared, clock, plant_origin, window)
end

"""
Run-immutable execution-clock mapping captured only after same-session adapter
readiness succeeds inside the arm window.
"""
struct ArmedSerialRun{
    R<:PreparedSerialRun,
    M<:ExecutionClockMapping,
}
    prepared::R
    timing::M

    ArmedSerialRun(
        prepared::R,
        timing::M,
        ::_SerialConstructionToken) where {
        R<:PreparedSerialRun,
        M<:ExecutionClockMapping,
    } = new{R,M}(prepared, timing)
end

"""Typed running handle accepted by the serial hot path."""
struct RunningSerialRun{A<:ArmedSerialRun}
    armed::A

    RunningSerialRun(
        armed::A,
        ::_SerialConstructionToken) where {A<:ArmedSerialRun} =
        new{A}(armed)
end

@enum SerialStepStatus::UInt8 begin
    SerialCommandProcessed = 0x01
    SerialPlantEventProcessed = 0x02
    SerialDeadlinePending = 0x03
    SerialEventLoopComplete = 0x04
end

"""One nonblocking serial orchestration decision."""
struct SerialStepResult
    status::SerialStepStatus
    timestamp::Union{Nothing,PlantTimestamp}
    time_until_ns::Int64
end

serial_step_status(result::SerialStepResult) = result.status
serial_step_timestamp(result::SerialStepResult) = result.timestamp
serial_step_time_until_ns(result::SerialStepResult) = result.time_until_ns

@inline _prepared_serial_run(run::PreparedSerialRun) = run
@inline _prepared_serial_run(run::ArmingSerialRun) = run.prepared
@inline _prepared_serial_run(run::ArmedSerialRun) = run.prepared
@inline _prepared_serial_run(run::RunningSerialRun) =
    run.armed.prepared

run_session(run::ConfiguredSerialRun) = run.lifecycle.session
run_session(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = run_session(_prepared_serial_run(run).state.lifecycle)

run_phase(::ConfiguredSerialRun) = Lifecycle.RunConfigured
run_phase(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = run_phase(_prepared_serial_run(run).state.lifecycle)

run_arm_window(::ConfiguredSerialRun) = nothing
run_arm_window(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = run_arm_window(_prepared_serial_run(run).state.lifecycle)

run_execution_clock_identity(::ConfiguredSerialRun) = nothing
run_execution_clock_identity(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = run_execution_clock_identity(
    _prepared_serial_run(run).state.lifecycle)

run_adapter_readiness(::ConfiguredSerialRun) = nothing
run_adapter_readiness(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = run_adapter_readiness(
    _prepared_serial_run(run).state.lifecycle)

run_termination(::ConfiguredSerialRun) = nothing
run_termination(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = run_termination(_prepared_serial_run(run).state.lifecycle)

serial_products_published(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = _prepared_serial_run(run).state.products_published

serial_optical_execution_configuration(
    run::ConfiguredSerialRun) = run.optical_execution
serial_optical_execution_configuration(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = _prepared_serial_run(run).configuration.optical_execution

serial_optical_execution(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = _prepared_serial_run(run).execution

function _serial_publisher(
    event_loop::PreparedPlantEventLoop,
    port::AcquisitionCompletionPort)
    id = port.acquisition
    source = acquisition_products(event_loop, id)
    validate_acquisition_product_contract(
        source, acquisition_product_contract(port))
    return PreparedAcquisitionPublisher(id, port, source)
end

@inline _serial_publishers(::PreparedPlantEventLoop, ::Tuple{}) = ()

@inline function _serial_publishers(
    event_loop::PreparedPlantEventLoop,
    ports::Tuple)
    return (
        _serial_publisher(event_loop, first(ports)),
        _serial_publishers(event_loop, Base.tail(ports))...,
    )
end

@inline _validate_serial_acquisition_port(
    ::AcquisitionCompletionPort) = nothing

function _validate_serial_acquisition_port(::Any)
    throw(SerialRunError(
        :serial_run,
        :invalid_acquisition_port,
        "every serial-run acquisition port must be an AcquisitionCompletionPort"))
end

function _validate_serial_acquisition_ports(ports::Tuple)
    isempty(ports) && throw(SerialRunError(
        :serial_run, :empty_acquisition_ports,
        "a serial run requires at least one acquisition-completion port"))
    first_port = first(ports)
    _validate_serial_acquisition_port(first_port)
    session = first_port.session
    @inbounds for right in 2:length(ports)
        port = ports[right]
        _validate_serial_acquisition_port(port)
        port.session == session || throw(SerialRunError(
            :serial_run, :session_mismatch,
            "every serial-run port must belong to one run/session"))
        for left in 1:(right - 1)
            ports[left].acquisition == port.acquisition &&
                throw(SerialRunError(
                :serial_run, :duplicate_acquisition,
                "a serial run cannot publish one acquisition through multiple ports"))
        end
    end
    return session
end

@inline _validate_nonstructural_controls(::Tuple{}) = ()

function _validate_nonstructural_controls(::Tuple)
    throw(SerialRunError(
        :serial_run,
        :unsupported_nonstructural_control,
        "the prepared serial core exposes no nonstructural control seam"))
end

function _validate_nonstructural_controls(::Any)
    throw(SerialRunError(
        :serial_run,
        :invalid_nonstructural_controls,
        "nonstructural control declarations must be a tuple"))
end

@inline _validate_optical_execution(
    execution::AbstractOpticalExecutionConfiguration) = execution

function _validate_optical_execution(::Any)
    throw(SerialRunError(
        :serial_run,
        :invalid_optical_execution,
        "optical execution must be an AbstractOpticalExecutionConfiguration"))
end

"""
    configure_serial_run(command_bridge, acquisition_ports;
        arm_timeout_ns, optical_execution=SerialOpticalExecution(),
        nonstructural_controls=())

Validate and freeze the exact event-loop command route, acquisition-completion
ports, and relative arm deadline for one serial HIL topology. Prepared
nonstructural controls are currently unsupported by the core serial event loop,
so only the empty tuple is accepted.
"""
function configure_serial_run(
    command_bridge::PreparedCommandBridge,
    acquisition_ports::Tuple;
    arm_timeout_ns::Integer,
    optical_execution=SerialOpticalExecution(),
    nonstructural_controls=())
    controls = _validate_nonstructural_controls(
        nonstructural_controls)
    execution = _validate_optical_execution(optical_execution)
    event_loop = command_bridge_event_loop(command_bridge)
    event_loop === nothing && throw(SerialRunError(
        :serial_run, :command_target_without_event_loop,
        "a serial run requires a command bridge bound to a prepared event loop"))
    session = _validate_serial_acquisition_ports(acquisition_ports)
    command_submission_port(command_bridge).session == session ||
        throw(SerialRunError(
            :serial_run, :session_mismatch,
            "command and acquisition ports must belong to one run/session"))
    lifecycle = RunLifecycleParameters(session; arm_timeout_ns)
    return ConfiguredSerialRun(
        event_loop,
        command_bridge,
        acquisition_ports,
        execution,
        lifecycle,
        controls,
        _SERIAL_CONSTRUCTION_TOKEN)
end

"""
    prepare_serial_run(configuration)

Resolve complete-product sources and allocate all mutable state and workspace
without starting workers, accepting traffic, or reading an execution clock.
"""
function prepare_serial_run(configuration::ConfiguredSerialRun)
    publishers = _serial_publishers(
        configuration.event_loop,
        configuration.acquisition_ports)
    bridge = CommandBridgeState(configuration.command_bridge)
    sequences = Memory{UInt64}(undef, length(publishers))
    fill!(sequences, UInt64(0))
    state = SerialRunState(
        bridge,
        sequences,
        RunLifecycleState(configuration.lifecycle),
        UInt64(0),
        UInt64(0),
        _SERIAL_CONSTRUCTION_TOKEN)
    bridge_workspace =
        CommandBridgeWorkspace(configuration.command_bridge)
    leases = Memory{Base.RefValue{PayloadLeaseRef}}(
        undef, length(publishers))
    for index in eachindex(leases)
        leases[index] = Ref(PayloadLeaseRef(0, 0, 0, 0))
    end
    workspace = SerialRunWorkspace(
        bridge_workspace,
        leases,
        _SERIAL_CONSTRUCTION_TOKEN)
    execution = _prepare_optical_execution(
        configuration.optical_execution,
        configuration.event_loop,
        plant_event_loop_state(state.bridge),
        plant_event_loop_workspace(workspace.bridge),
        configuration.lifecycle.session,
    )
    return PreparedSerialRun(
        configuration,
        publishers,
        state,
        workspace,
        execution,
        _SERIAL_CONSTRUCTION_TOKEN)
end

struct AcquisitionPortAccounting
    descriptors::RingAccounting
    products::PayloadPoolAccounting
end

"""
Cold ownership snapshot for one serial run.

`execution_owners` is `nothing` for the core serial oracle and a fixed
`Memory{ExecutionOwnerAccounting}` snapshot for prepared HIL owners.
"""
struct SerialRunAccounting{C,A<:Tuple,E}
    command_submissions::RingAccounting
    command_completions::RingAccounting
    command_credits::PayloadPoolAccounting
    command_payloads::C
    command_dispositions::Int
    active_command_correlations::Int
    acquisitions::A
    execution_owners::E
end

@inline _serial_command_payload_accounting(
    ::CommandSubmissionPort{<:InlineCommandPayload}) = nothing

@inline _serial_command_payload_accounting(
    port::CommandSubmissionPort{LeasedCommandPayload}) =
    command_payload_accounting(port)

@inline _serial_acquisition_accounting(::Tuple{}) = ()

@inline function _serial_acquisition_accounting(publishers::Tuple)
    publisher = first(publishers)
    accounting = AcquisitionPortAccounting(
        ring_accounting(publisher.port.ring),
        acquisition_product_accounting(publisher.port))
    return (
        accounting,
        _serial_acquisition_accounting(Base.tail(publishers))...,
    )
end

"""Return a cold, quiescent accounting snapshot for the whole serial run."""
function serial_run_accounting(run::PreparedSerialRun)
    state = run.state
    workspace = run.workspace
    bridge = run.configuration.command_bridge
    submission = command_submission_port(bridge)
    completion = command_completion_port(bridge)
    return SerialRunAccounting(
        ring_accounting(submission.ring),
        ring_accounting(completion.ring),
        outcome_credit_accounting(submission),
        _serial_command_payload_accounting(submission),
        command_disposition_count(
            command_disposition_workspace(workspace.bridge)),
        active_command_correlations(state.bridge),
        _serial_acquisition_accounting(run.publishers),
        _execution_accounting(run.execution))
end

# Julia emits no coverage counters for these exercised constant dispatch leaves.
@inline _pool_is_quiescent(::Nothing) = true # COV_EXCL_LINE
@inline _pool_is_quiescent(value::PayloadPoolAccounting) =
    value.free == value.capacity

@inline _acquisitions_are_quiescent(::Tuple{}) = true # COV_EXCL_LINE

@inline function _acquisitions_are_quiescent(values::Tuple)
    value = first(values)
    return value.descriptors.occupancy == 0 &&
        _pool_is_quiescent(value.products) &&
        _acquisitions_are_quiescent(Base.tail(values))
end

function serial_run_is_quiescent(accounting::SerialRunAccounting)
    return accounting.command_submissions.occupancy == 0 &&
        accounting.command_completions.occupancy == 0 &&
        _pool_is_quiescent(accounting.command_credits) &&
        _pool_is_quiescent(accounting.command_payloads) &&
        iszero(accounting.command_dispositions) &&
        iszero(accounting.active_command_correlations) &&
        _acquisitions_are_quiescent(accounting.acquisitions) &&
        _execution_accounting_is_quiescent(
            accounting.execution_owners)
end

# Direct dispatch tests cover these inlined recursion leaves, but Julia's
# coverage instrumentation does not retain a source counter for either line.
@inline _reclaim_serial_command_payload_returns!( # COV_EXCL_LINE
    ::CommandSubmissionPort{<:InlineCommandPayload}) = 0

@inline function _reclaim_serial_command_payload_returns!(
    port::CommandSubmissionPort{LeasedCommandPayload})
    return reclaim_command_payload_returns!(port).count
end

@inline _reclaim_serial_acquisition_returns!(::Tuple{}) = 0 # COV_EXCL_LINE

@inline function _reclaim_serial_acquisition_returns!(publishers::Tuple)
    return reclaim_product_returns!(first(publishers).port).count +
        _reclaim_serial_acquisition_returns!(Base.tail(publishers))
end

"""
    reclaim_serial_returns!(run)

Boundedly reclaim every already released command payload, outcome credit, and
acquisition product in a deterministic single-owner serial run. Callers must
not invoke this while another logical owner is operating a corresponding pool.
The returned count is the exact number of slots reclaimed by this call.
"""
function reclaim_serial_returns!(run::PreparedSerialRun)
    submission =
        command_submission_port(run.configuration.command_bridge)
    return _reclaim_serial_command_payload_returns!(submission) +
        reclaim_outcome_credit_returns!(submission).count +
        _reclaim_serial_acquisition_returns!(run.publishers)
end

"""
    begin_serial_arm!(run, clock; plant_origin=zero(PlantTimestamp))

Validate quiescence and open one inclusive execution-clock arm window. This
does not wait for adapter readiness.
"""
function begin_serial_arm!(
    run::PreparedSerialRun,
    clock::C;
    plant_origin::PlantTimestamp=zero(PlantTimestamp)) where {
    C<:Clocks.AbstractNanoClock}
    state = run.state
    workspace = run.workspace
    configuration = run.configuration
    _require_phase(state.lifecycle, RunPrepared, :run_arm)
    next_timestamp = next_plant_event_timestamp(
        configuration.event_loop,
        plant_event_loop_state(state.bridge),
        plant_event_loop_workspace(workspace.bridge))
    next_timestamp !== nothing && next_timestamp < plant_origin &&
        throw(SerialRunError(
            :serial_run, :plant_origin_after_next_event,
            "the armed plant origin cannot overtake an unprocessed plant event"))
    serial_run_is_quiescent(serial_run_accounting(run)) ||
        throw(SerialRunError(
            :serial_run, :ownership_not_quiescent,
            "every port and payload pool must be quiescent before arm"))
    _execution_is_quiescent(run.execution) ||
        throw(SerialRunError(
            :serial_run,
            :execution_ownership_not_quiescent,
            "every execution-owner handoff must be quiescent before arm"))
    opened_execution_ns = _read_execution_clock(clock)
    window = _begin_arm!(
        state.lifecycle,
        configuration.lifecycle,
        execution_clock_identity(clock),
        opened_execution_ns)
    return ArmingSerialRun(
        run,
        clock,
        plant_origin,
        window,
        _SERIAL_CONSTRUCTION_TOKEN)
end

"""
    arm_serial_run!(attempt, readiness)

Complete an active arm attempt after user orchestration reports same-session
adapter readiness. The execution-clock mapping is immutable for the run.
"""
function arm_serial_run!(
    attempt::ArmingSerialRun,
    readiness::AdapterReadinessSnapshot)
    selected_identity =
        run_execution_clock_identity(attempt.window)
    execution_clock_identity(attempt.clock) == selected_identity ||
        throw(SerialRunError(
            :serial_run,
            :execution_clock_identity_changed,
            "the execution-clock identity changed during the arm attempt"))
    mapping = arm_execution_clock(
        attempt.clock,
        attempt.plant_origin;
        identity=selected_identity)
    current_execution_ns = execution_clock_origin_ns(mapping)
    _complete_arm!(
        attempt.prepared.state.lifecycle,
        attempt.window,
        readiness,
        current_execution_ns)
    armed = ArmedSerialRun(
        attempt.prepared,
        mapping,
        _SERIAL_CONSTRUCTION_TOKEN)
    try
        _arm_optical_execution!(attempt.prepared.execution)
    catch error
        _record_serial_failure!(armed, error)
        rethrow()
    end
    return armed
end

function start_serial_run!(armed::ArmedSerialRun)
    _execution_is_armed(armed.prepared.execution) ||
        throw(SerialRunError(
            :serial_run,
            :execution_owners_not_armed,
            "optical execution owners must be armed before the run starts"))
    _start_run!(armed.prepared.state.lifecycle)
    try
        _start_optical_execution!(armed.prepared.execution)
    catch error
        _record_serial_failure!(armed, error)
        rethrow()
    end
    return RunningSerialRun(armed, _SERIAL_CONSTRUCTION_TOKEN)
end

@inline function _stop_serial_run!(
    armed::ArmedSerialRun,
    event::Union{RunStopRequest,RunTerminalEvent})
    current_execution_ns =
        _read_execution_clock(execution_clock(armed.timing))
    _validate_stop_event(
        armed.prepared.state.lifecycle,
        event,
        current_execution_ns)
    accounting = serial_run_accounting(armed.prepared)
    serial_run_is_quiescent(accounting) || throw(SerialRunError(
        :serial_run, :ownership_not_quiescent,
        "clean stop requires every descriptor, outcome, and payload lease to be accounted for"))
    _execution_is_quiescent(armed.prepared.execution) ||
        throw(SerialRunError(
            :serial_run,
            :execution_ownership_not_quiescent,
            "clean stop requires every execution-owner handoff to be accounted for"))
    _stop_optical_execution!(armed.prepared.execution)
    _record_stop!(armed.prepared.state.lifecycle, event)
    return serial_run_accounting(armed.prepared)
end

stop_serial_run!(
    armed::ArmedSerialRun,
    event::Union{RunStopRequest,RunTerminalEvent}) =
    _stop_serial_run!(armed, event)

stop_serial_run!(
    running::RunningSerialRun,
    event::Union{RunStopRequest,RunTerminalEvent}) =
    _stop_serial_run!(running.armed, event)

@noinline function _serial_publication_error(
    reason::Symbol,
    message::String)
    throw(SerialRunError(:serial_run, reason, message))
end

@inline function _copy_serial_acquisition_products!(
    destination::AcquisitionProducts,
    source::AcquisitionProducts)
    copy_acquisition_product!(
        destination.observation, source.observation)
    copy_acquisition_product!(
        destination.measurement, source.measurement)
    return destination
end

# Julia emits no coverage counter for this exercised constant dispatch leaf.
# COV_EXCL_START
@inline _publish_serial_products!(
    ::Tuple{},
    ::ArmedSerialRun,
    ::SerialRunState,
    ::SerialRunWorkspace,
    ::Int64,
    ::Int) = 0
# COV_EXCL_STOP

function _publish_serial_products!(
    publishers::Tuple,
    armed::ArmedSerialRun,
    state::SerialRunState,
    workspace::SerialRunWorkspace,
    publication_execution_ns::Int64,
    index::Int)
    publisher = first(publishers)
    event_loop = armed.prepared.configuration.event_loop
    event_state = plant_event_loop_state(state.bridge)
    sequence = acquisition_product_sequence(
        event_loop, event_state, publisher.id)
    last_sequence = @inbounds state.published_sequences[index]
    published = 0
    if sequence != last_sequence
        sequence == last_sequence + UInt64(1) ||
            _serial_publication_error(
                :acquisition_sequence_gap,
                "serial publication observed an unavailable acquisition-product history")
        lease_ref = @inbounds workspace.product_leases[index]
        claim_status = try_claim_product!(lease_ref, publisher.port)
        claim_status == PayloadTransitionSucceeded ||
            _serial_publication_error(
                :acquisition_product_capacity,
                "no prepared acquisition-product buffer was available")
        lease = lease_ref[]
        destination = producer_product(publisher.port, lease)
        _copy_serial_acquisition_products!(
            destination, publisher.source)
        timestamp = acquisition_product_ready_timestamp(
            event_loop, event_state, publisher.id)
        timestamp === nothing && _serial_publication_error(
            :missing_acquisition_timestamp,
            "a sequenced acquisition product has no readiness timestamp")
        completion = matching_acquisition_completion(
            publisher.port,
            StreamSequence(sequence),
            timestamp,
            lease,
            publication_execution_ns)
        result = try_publish!(publisher.port, completion)
        if port_status(result) != PortTransferSucceeded
            abort_product!(publisher.port, lease)
            reason = port_status(result) == PortFull ?
                :acquisition_completion_full :
                :acquisition_publication_rejected
            _serial_publication_error(
                reason,
                "the complete acquisition product could not be published")
        end
        @inbounds state.published_sequences[index] = sequence
        state.products_published += UInt64(1)
        published = 1
    end
    return published + _publish_serial_products!(
        Base.tail(publishers),
        armed,
        state,
        workspace,
        publication_execution_ns,
        index + 1)
end

function _step_serial_run!(
    armed::ArmedSerialRun,
    state::SerialRunState,
    workspace::SerialRunWorkspace,
    execution::AbstractOpticalPathBatchExecutor)
    run = armed.prepared
    configuration = run.configuration
    publication_execution_ns =
        Clocks.time_nanos(execution_clock(armed.timing))
    command_result = process_next_command!(
        configuration.command_bridge,
        state.bridge,
        workspace.bridge,
        publication_execution_ns)
    command_status = port_status(command_result)
    if command_status == PortTransferSucceeded
        descriptor = workspace.bridge.descriptor_scratch[]
        timestamp = descriptor.submission.timing.receive_timestamp
        return SerialStepResult(
            SerialCommandProcessed, timestamp, Int64(0))
    end
    command_status in (PortEmpty, PortClosed) ||
        _serial_publication_error(
            :command_processing,
            "the command bridge returned an invalid processing status")

    event_state = plant_event_loop_state(state.bridge)
    event_workspace = plant_event_loop_workspace(workspace.bridge)
    timestamp = next_plant_event_timestamp(
        configuration.event_loop, event_state, event_workspace)
    timestamp === nothing && return SerialStepResult(
        SerialEventLoopComplete, nothing, Int64(0))
    time_until_ns = execution_time_until_ns(armed.timing, timestamp)
    time_until_ns > 0 && return SerialStepResult(
        SerialDeadlinePending, timestamp, time_until_ns)

    processed = step_plant_events!(
        configuration.event_loop,
        event_state,
        event_workspace,
        execution)
    processed == timestamp || _serial_publication_error(
        :event_timestamp_mismatch,
        "the prepared event loop did not process its advertised timestamp")
    publication_execution_ns =
        Clocks.time_nanos(execution_clock(armed.timing))
    publish_command_dispositions!(
        configuration.command_bridge,
        state.bridge,
        workspace.bridge,
        publication_execution_ns)
    _publish_serial_products!(
        run.publishers,
        armed,
        state,
        workspace,
        publication_execution_ns,
        1)
    state.plant_event_steps += UInt64(1)
    return SerialStepResult(
        SerialPlantEventProcessed, timestamp, time_until_ns)
end

"""
Perform one command, deadline, or plant-event scheduling decision. A pending
deadline is returned without sleeping. A due optical event completes the
selected executor's prepared materialization and execution barriers before
returning.
"""
@inline _serial_failure_component(::Any) = :serial_run # COV_EXCL_LINE
@inline _serial_failure_component(error::SerialRunError) =
    error.component

@inline _serial_failure_reason(error) = nameof(typeof(error))
@inline _serial_failure_reason(error::SerialRunError) =
    error.reason

@noinline function _record_serial_failure!(
    armed::ArmedSerialRun,
    error)
    observed_execution_ns = try
        _read_execution_clock(execution_clock(armed.timing))
    catch
        nothing
    end
    event = RunFailureEvent(
        run_session(armed),
        execution_clock_identity(armed.timing),
        observed_execution_ns,
        _serial_failure_component(error),
        _serial_failure_reason(error))
    _mark_optical_execution_failed!(armed.prepared.execution)
    return _fail_run!(armed.prepared.state.lifecycle, event)
end

_record_serial_failure!(
    running::RunningSerialRun,
    error,
) = _record_serial_failure!(running.armed, error)

function step_serial_run!(running::RunningSerialRun)
    run = running.armed.prepared
    state = run.state
    workspace = run.workspace
    _require_phase(state.lifecycle, RunRunning, :serial_step)
    try
        return _step_serial_run!(
            running.armed,
            state,
            workspace,
            run.execution)
    catch error
        _record_serial_failure!(running, error)
        rethrow()
    end
end

public SerialRunState, SerialRunWorkspace
public AcquisitionPortAccounting

end
