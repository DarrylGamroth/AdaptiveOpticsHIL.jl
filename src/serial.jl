"""
    Serial

Deterministic, single-owner pacing of one prepared AdaptiveOpticsSim plant
event loop through transport-neutral HIL ports. This namespace never sleeps,
polls, invokes callbacks, creates workers, or chooses an RTC transport.
"""
module Serial

import Clocks

using AdaptiveOpticsSim.Plant: AcquisitionID, AcquisitionProducts
using AdaptiveOpticsSim.Plant: PlantTimestamp, PreparedPlant
using AdaptiveOpticsSim.Plant: PreparedPlantEventLoop
using AdaptiveOpticsSim.Plant: acquisition_product_sequence
using AdaptiveOpticsSim.Plant: acquisition_product_ready_timestamp
using AdaptiveOpticsSim.Plant: acquisition_products
using AdaptiveOpticsSim.Plant: command_disposition_count
using AdaptiveOpticsSim.Plant: copy_acquisition_product!
using AdaptiveOpticsSim.Plant: next_plant_event_timestamp
using AdaptiveOpticsSim.Plant: prepared_acquisition
using AdaptiveOpticsSim.Plant: step_plant_events!
using AdaptiveOpticsSim.Plant: validate_acquisition_product_contract

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError
using ..Ownership: PayloadLeaseRef, PayloadPoolAccounting, RingAccounting
using ..Ownership: PayloadTransitionSucceeded
using ..Ownership: ring_accounting
using ..Ports: AcquisitionCompletionPort, AdapterReadinessSnapshot
using ..Ports: AdapterReady, CommandBridgeState, CommandBridgeWorkspace
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
using ..Timing: execution_clock, execution_time_until_ns

export SerialRunError
export PreparedSerialRun, SerialRunState, SerialRunWorkspace, ArmedSerialRun
export prepare_serial_run, arm_serial_run, start_serial_run!, stop_serial_run!
export SerialRunLifecycle, SerialRunPrepared, SerialRunArmed
export SerialRunRunning, SerialRunStopped, SerialRunFailed
export SerialStepStatus, SerialCommandProcessed, SerialPlantEventProcessed
export SerialDeadlinePending, SerialEventLoopComplete
export SerialStepResult, serial_step_status, serial_step_timestamp
export serial_step_time_until_ns, step_serial_run!
export serial_run_lifecycle, serial_products_published
export SerialRunAccounting, AcquisitionPortAccounting
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

mutable struct _SerialRunBinding end

"""
Run-immutable serial composition of one core event loop, one event-loop command
bridge, and one or more complete-product publishers.
"""
struct PreparedSerialRun{
    L<:PreparedPlantEventLoop,
    B<:PreparedCommandBridge,
    P<:Tuple,
}
    binding::_SerialRunBinding
    event_loop::L
    command_bridge::B
    publishers::P
end

@enum SerialRunLifecycle::UInt8 begin
    SerialRunPrepared = 0x01
    SerialRunArmed = 0x02
    SerialRunRunning = 0x03
    SerialRunStopped = 0x04
    SerialRunFailed = 0x05
end

"""
Single-writer run state. The command bridge owns the event-loop state and its
bounded command-correlation state; acquisition sequences and lifecycle remain
separate semantic state.
"""
mutable struct SerialRunState{B<:CommandBridgeState}
    binding::_SerialRunBinding
    bridge::B
    published_sequences::Memory{UInt64}
    lifecycle::SerialRunLifecycle
    plant_event_steps::UInt64
    products_published::UInt64
end

"""
Preallocated event-loop, command-bridge, and acquisition-publication scratch
for one prepared serial run.
"""
struct SerialRunWorkspace{B<:CommandBridgeWorkspace}
    binding::_SerialRunBinding
    bridge::B
    product_leases::Memory{Base.RefValue{PayloadLeaseRef}}
end

"""
Run-immutable execution-clock mapping captured only after adapter readiness was
observed.
"""
struct ArmedSerialRun{
    R<:PreparedSerialRun,
    M<:ExecutionClockMapping,
}
    prepared::R
    timing::M
    readiness::AdapterReadinessSnapshot
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
serial_run_lifecycle(state::SerialRunState) = state.lifecycle
serial_products_published(state::SerialRunState) = state.products_published

function _serial_publisher(
    plant::PreparedPlant,
    port::AcquisitionCompletionPort)
    id = port.acquisition
    owner = prepared_acquisition(plant, id)
    source = acquisition_products(owner)
    validate_acquisition_product_contract(
        source, acquisition_product_contract(port))
    return PreparedAcquisitionPublisher(id, port, source)
end

@inline _serial_publishers(::PreparedPlant, ::Tuple{}) = ()

@inline function _serial_publishers(plant::PreparedPlant, ports::Tuple)
    return (
        _serial_publisher(plant, first(ports)),
        _serial_publishers(plant, Base.tail(ports))...,
    )
end

function _validate_serial_publishers(publishers::Tuple)
    isempty(publishers) && throw(SerialRunError(
        :serial_run, :empty_acquisition_ports,
        "a serial run requires at least one acquisition-completion port"))
    session = first(publishers).port.session
    @inbounds for right in 2:length(publishers)
        publisher = publishers[right]
        publisher.port.session == session || throw(SerialRunError(
            :serial_run, :session_mismatch,
            "every serial-run port must belong to one run/session"))
        for left in 1:(right - 1)
            publishers[left].id == publisher.id && throw(SerialRunError(
                :serial_run, :duplicate_acquisition,
                "a serial run cannot publish one acquisition through multiple ports"))
        end
    end
    return session
end

"""
    prepare_serial_run(plant, event_loop, command_bridge, acquisition_ports)

Resolve complete-product sources and validate one serial, transport-neutral
event-loop composition. `acquisition_ports` must be a nonempty tuple.
"""
function prepare_serial_run(
    plant::PreparedPlant,
    event_loop::PreparedPlantEventLoop,
    command_bridge::PreparedCommandBridge,
    acquisition_ports::Tuple)
    command_bridge_event_loop(command_bridge) === event_loop ||
        throw(SerialRunError(
            :serial_run, :command_target_mismatch,
            "the command bridge must target the exact prepared event loop"))
    publishers = _serial_publishers(plant, acquisition_ports)
    session = _validate_serial_publishers(publishers)
    command_submission_port(command_bridge).session == session ||
        throw(SerialRunError(
            :serial_run, :session_mismatch,
            "command and acquisition ports must belong to one run/session"))
    return PreparedSerialRun(
        _SerialRunBinding(), event_loop, command_bridge, publishers)
end

function SerialRunState(run::PreparedSerialRun)
    bridge = CommandBridgeState(run.command_bridge)
    sequences = Memory{UInt64}(undef, length(run.publishers))
    fill!(sequences, UInt64(0))
    return SerialRunState(
        run.binding, bridge, sequences, SerialRunPrepared,
        UInt64(0), UInt64(0))
end

function SerialRunWorkspace(run::PreparedSerialRun)
    bridge = CommandBridgeWorkspace(run.command_bridge)
    leases = Memory{Base.RefValue{PayloadLeaseRef}}(
        undef, length(run.publishers))
    for index in eachindex(leases)
        leases[index] = Ref(PayloadLeaseRef(0, 0, 0, 0))
    end
    return SerialRunWorkspace(run.binding, bridge, leases)
end

@inline function _require_serial_run_binding(
    run::PreparedSerialRun,
    state::SerialRunState)
    run.binding === state.binding || throw(SerialRunError(
        :serial_run, :prepared_binding,
        "serial-run state belongs to another prepared run"))
    return nothing
end

@inline function _require_serial_run_binding(
    run::PreparedSerialRun,
    workspace::SerialRunWorkspace)
    run.binding === workspace.binding || throw(SerialRunError(
        :serial_run, :prepared_binding,
        "serial-run workspace belongs to another prepared run"))
    return nothing
end

struct AcquisitionPortAccounting
    descriptors::RingAccounting
    products::PayloadPoolAccounting
end

struct SerialRunAccounting{C,A<:Tuple}
    command_submissions::RingAccounting
    command_completions::RingAccounting
    command_credits::PayloadPoolAccounting
    command_payloads::C
    command_dispositions::Int
    active_command_correlations::Int
    acquisitions::A
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
function serial_run_accounting(
    run::PreparedSerialRun,
    state::SerialRunState,
    workspace::SerialRunWorkspace)
    _require_serial_run_binding(run, state)
    _require_serial_run_binding(run, workspace)
    submission = command_submission_port(run.command_bridge)
    completion = command_completion_port(run.command_bridge)
    return SerialRunAccounting(
        ring_accounting(submission.ring),
        ring_accounting(completion.ring),
        outcome_credit_accounting(submission),
        _serial_command_payload_accounting(submission),
        command_disposition_count(
            command_disposition_workspace(workspace.bridge)),
        active_command_correlations(state.bridge),
        _serial_acquisition_accounting(run.publishers))
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
        _acquisitions_are_quiescent(accounting.acquisitions)
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
    submission = command_submission_port(run.command_bridge)
    return _reclaim_serial_command_payload_returns!(submission) +
        reclaim_outcome_credit_returns!(submission).count +
        _reclaim_serial_acquisition_returns!(run.publishers)
end

"""
Arm a prepared serial run after the user-owned integration reports its adapter
ready. The returned execution-clock mapping is immutable for the run.
"""
function arm_serial_run(
    run::PreparedSerialRun,
    state::SerialRunState,
    workspace::SerialRunWorkspace,
    clock::Clocks.AbstractNanoClock,
    readiness::AdapterReadinessSnapshot;
    plant_origin::PlantTimestamp=zero(PlantTimestamp))
    _require_serial_run_binding(run, state)
    _require_serial_run_binding(run, workspace)
    state.lifecycle == SerialRunPrepared || throw(SerialRunError(
        :serial_run, :invalid_lifecycle,
        "only a prepared serial run can be armed"))
    readiness.status == AdapterReady || throw(SerialRunError(
        :serial_run, :adapter_not_ready,
        "the RTC adapter must report ready before the serial run is armed"))
    readiness.observed_timestamp <= plant_origin ||
        throw(SerialRunError(
            :serial_run, :readiness_after_origin,
            "adapter readiness cannot be observed after the armed plant origin"))
    next_timestamp = next_plant_event_timestamp(
        run.event_loop,
        plant_event_loop_state(state.bridge),
        plant_event_loop_workspace(workspace.bridge))
    next_timestamp !== nothing && next_timestamp < plant_origin &&
        throw(SerialRunError(
            :serial_run, :plant_origin_after_next_event,
            "the armed plant origin cannot overtake an unprocessed plant event"))
    serial_run_is_quiescent(
        serial_run_accounting(run, state, workspace)) ||
        throw(SerialRunError(
            :serial_run, :ownership_not_quiescent,
            "every port and payload pool must be quiescent before arm"))
    mapping = arm_execution_clock(clock, plant_origin)
    state.lifecycle = SerialRunArmed
    return ArmedSerialRun(run, mapping, readiness)
end

function start_serial_run!(
    armed::ArmedSerialRun,
    state::SerialRunState)
    _require_serial_run_binding(armed.prepared, state)
    state.lifecycle == SerialRunArmed || throw(SerialRunError(
        :serial_run, :invalid_lifecycle,
        "only an armed serial run can enter the running phase"))
    state.lifecycle = SerialRunRunning
    return state
end

function stop_serial_run!(
    armed::ArmedSerialRun,
    state::SerialRunState,
    workspace::SerialRunWorkspace)
    _require_serial_run_binding(armed.prepared, state)
    _require_serial_run_binding(armed.prepared, workspace)
    state.lifecycle in (SerialRunArmed, SerialRunRunning) ||
        throw(SerialRunError(
            :serial_run, :invalid_lifecycle,
            "only an armed or running serial run can stop cleanly"))
    accounting = serial_run_accounting(
        armed.prepared, state, workspace)
    serial_run_is_quiescent(accounting) || throw(SerialRunError(
        :serial_run, :ownership_not_quiescent,
        "clean stop requires every descriptor, outcome, and payload lease to be accounted for"))
    state.lifecycle = SerialRunStopped
    return accounting
end

@noinline function _serial_publication_error(
    state::SerialRunState,
    reason::Symbol,
    message::String)
    state.lifecycle = SerialRunFailed
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
    event_loop = armed.prepared.event_loop
    event_state = plant_event_loop_state(state.bridge)
    sequence = acquisition_product_sequence(
        event_loop, event_state, publisher.id)
    last_sequence = @inbounds state.published_sequences[index]
    published = 0
    if sequence != last_sequence
        sequence == last_sequence + UInt64(1) ||
            _serial_publication_error(
                state, :acquisition_sequence_gap,
                "serial publication observed an unavailable acquisition-product history")
        lease_ref = @inbounds workspace.product_leases[index]
        claim_status = try_claim_product!(lease_ref, publisher.port)
        claim_status == PayloadTransitionSucceeded ||
            _serial_publication_error(
                state, :acquisition_product_capacity,
                "no prepared acquisition-product buffer was available")
        lease = lease_ref[]
        destination = producer_product(publisher.port, lease)
        _copy_serial_acquisition_products!(
            destination, publisher.source)
        timestamp = acquisition_product_ready_timestamp(
            event_loop, event_state, publisher.id)
        timestamp === nothing && _serial_publication_error(
            state, :missing_acquisition_timestamp,
            "a sequenced acquisition product has no readiness timestamp")
        completion = matching_acquisition_completion(
            publisher.port,
            StreamSequence(sequence),
            timestamp,
            armed.readiness,
            lease,
            publication_execution_ns)
        result = try_publish!(publisher.port, completion)
        if port_status(result) != PortTransferSucceeded
            abort_product!(publisher.port, lease)
            reason = port_status(result) == PortFull ?
                :acquisition_completion_full :
                :acquisition_publication_rejected
            _serial_publication_error(
                state, reason,
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
    workspace::SerialRunWorkspace)
    run = armed.prepared
    publication_execution_ns =
        Clocks.time_nanos(execution_clock(armed.timing))
    command_result = process_next_command!(
        run.command_bridge,
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
            state, :command_processing,
            "the command bridge returned an invalid processing status")

    event_state = plant_event_loop_state(state.bridge)
    event_workspace = plant_event_loop_workspace(workspace.bridge)
    timestamp = next_plant_event_timestamp(
        run.event_loop, event_state, event_workspace)
    timestamp === nothing && return SerialStepResult(
        SerialEventLoopComplete, nothing, Int64(0))
    time_until_ns = execution_time_until_ns(armed.timing, timestamp)
    time_until_ns > 0 && return SerialStepResult(
        SerialDeadlinePending, timestamp, time_until_ns)

    processed = step_plant_events!(
        run.event_loop, event_state, event_workspace)
    processed == timestamp || _serial_publication_error(
        state, :event_timestamp_mismatch,
        "the prepared event loop did not process its advertised timestamp")
    publication_execution_ns =
        Clocks.time_nanos(execution_clock(armed.timing))
    publish_command_dispositions!(
        run.command_bridge,
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
Perform one nonblocking command, deadline, or plant-event decision. A pending
deadline is returned to the caller; this function never sleeps or retries.
"""
function step_serial_run!(
    armed::ArmedSerialRun,
    state::SerialRunState,
    workspace::SerialRunWorkspace)
    _require_serial_run_binding(armed.prepared, state)
    _require_serial_run_binding(armed.prepared, workspace)
    state.lifecycle == SerialRunRunning || throw(SerialRunError(
        :serial_run, :invalid_lifecycle,
        "serial stepping requires the running lifecycle phase"))
    try
        return _step_serial_run!(armed, state, workspace)
    catch
        state.lifecycle = SerialRunFailed
        rethrow()
    end
end

end
