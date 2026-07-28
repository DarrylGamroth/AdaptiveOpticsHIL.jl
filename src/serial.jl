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
using AdaptiveOpticsSim.Plant: CommandDispositionReason
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
using ..Execution: ExecutionOwnerError
using ..Execution: SerialOpticalExecution
using ..Execution: _arm_optical_execution!
using ..Execution: _abandon_failed_optical_path_batch!
using ..Execution: _bind_optical_execution_timing
using ..Execution: _execution_accounting
using ..Execution: _execution_accounting_is_quiescent
using ..Execution: _execution_batch_active
using ..Execution: _execution_is_armed, _execution_is_quiescent
using ..Execution: _execution_ownership_is_drained
using ..Execution: _execution_failure_coordinator
using ..Execution: _begin_optical_execution_shutdown!
using ..Execution: _finalize_optical_execution_shutdown!
using ..Execution: _mark_optical_execution_failed!
using ..Execution: _prepare_optical_execution
using ..Execution: _progress_optical_execution_shutdown!
using ..Execution: _start_optical_execution!, _stop_optical_execution!
using ..Lifecycle: AcknowledgementTimeoutRunFailure
using ..Lifecycle: AdapterReadinessSnapshot
using ..Lifecycle: CoordinatorFailureBoundary
using ..Lifecycle: DeviceRunFailure, DrainTimeoutRunFailure
using ..Lifecycle: IngressWatchdogRunFailure
using ..Lifecycle: NoRTCIngressLiveness
using ..Lifecycle: OwnerExceptionRunFailure
using ..Lifecycle: PreparedRunFailureCoordinator
using ..Lifecycle: ResourcePolicyRunFailure
using ..Lifecycle: RTCIngressLivenessExpired
using ..Lifecycle: RTCIngressLivenessPolicy
using ..Lifecycle: RTCIngressLivenessState
using ..Lifecycle: RunFailureEvent
using ..Lifecycle: RunLifecycleParameters, RunLifecycleState
using ..Lifecycle: RunPrepared, RunRunning
using ..Lifecycle: RunShutdownPolicy, ShutdownAcknowledgement
using ..Lifecycle: ShutdownDrain
using ..Lifecycle: RunStopRequest, RunTerminalEvent
using ..Lifecycle: _acknowledge_run_stop!, _begin_run_shutdown!
using ..Lifecycle: _begin_arm!, _complete_arm!, _fail_run!
using ..Lifecycle: _admit_rtc_ingress_liveness!
using ..Lifecycle: _finalize_run_shutdown!
using ..Lifecycle: _observe_rtc_ingress_liveness!
using ..Lifecycle: _publish_run_failure!
using ..Lifecycle: _record_acknowledgement_timeouts!
using ..Lifecycle: _record_stop!, _require_phase
using ..Lifecycle: _run_shutdown_acknowledged
using ..Lifecycle: _run_shutdown_drain_expired!
using ..Lifecycle: _start_rtc_ingress_liveness!
using ..Lifecycle: _start_run!
using ..Lifecycle: _validate_stop_event
import ..Lifecycle: run_arm_window, run_execution_clock_identity
import ..Lifecycle: run_adapter_readiness
import ..Lifecycle: run_phase, run_session, run_termination
using ..Ownership: PayloadLeaseRef, PayloadPoolAccounting, RingAccounting
using ..Ownership: PayloadPoolClosed, PayloadPoolExhausted
using ..Ownership: PayloadTransitionSucceeded
using ..Ownership: ring_accounting
using ..Ports: AcquisitionCompletionPort
using ..Ports: AcquisitionOverloadPolicy
using ..Ports: DropNewestOnFull, OptionalResource
using ..Ports: CommandBridgeState, CommandBridgeWorkspace
using ..Ports: CommandSubmissionPort
using ..Ports: InlineCommandPayload, LeasedCommandPayload
using ..Ports: PortClosed, PortEmpty, PortFull, PortTransferSucceeded
using ..Ports: CommandSemanticallyAdmitted
using ..Ports: PreparedCommandBridge, StreamSequence
using ..Ports: abort_product!, acquisition_product_accounting
using ..Ports: acquisition_product_contract, active_command_correlations
using ..Ports: command_bridge_event_loop, command_completion_port
using ..Ports: command_processing_endpoint
using ..Ports: command_processing_port_result, command_processing_stage
using ..Ports: command_disposition_workspace, command_payload_accounting
using ..Ports: command_submission_port, matching_acquisition_completion
using ..Ports: outcome_credit_accounting, plant_event_loop_state
using ..Ports: plant_event_loop_workspace
using ..Ports: port_status, process_next_command!
using ..Ports: fail_pending_bridge_commands!
using ..Ports: reject_pending_bridge_commands!
using ..Ports: close_acquisition_completion!
using ..Ports: close_acquisition_return_path!
using ..Ports: close_command_completion!, close_command_ingress!
using ..Ports: close_command_return_paths!
using ..Ports: producer_product, publish_command_dispositions!
using ..Ports: reclaim_command_payload_returns!
using ..Ports: reclaim_outcome_credit_returns!, reclaim_product_returns!
using ..Ports: try_claim_product!, try_publish!
using ..Timing: ExecutionClockMapping, arm_execution_clock
using ..Timing: execution_clock, execution_clock_identity
using ..Timing: execution_clock_origin_ns
using ..Timing: execution_lateness_ns
using ..Timing: execution_time_until_ns
using ..Timing: _read_execution_clock

export SerialRunError
export ConfiguredSerialRun, PreparedSerialRun
export ArmingSerialRun, ArmedSerialRun, RunningSerialRun
export configure_serial_run, prepare_serial_run
export begin_serial_arm!, arm_serial_run!, start_serial_run!
export begin_serial_stop!, progress_serial_shutdown!
export SerialShutdownStatus, SerialShutdownInactive
export SerialShutdownDraining, SerialShutdownFinalized
export serial_shutdown_status, serial_failure_accounting
export SerialStepStatus, SerialCommandProcessed, SerialPlantEventProcessed
export SerialDeadlinePending, SerialEventLoopComplete
export SerialStepResult, serial_step_status, serial_step_timestamp
export serial_step_time_until_ns, step_serial_run!
export serial_products_published
export serial_optical_execution_configuration, serial_optical_execution
export SerialRunAccounting
export reclaim_serial_returns!, serial_run_accounting
export serial_run_is_quiescent
export AcquisitionOverloadDecision, AcquisitionNoOverloadDecision
export AcquisitionProductPublished, AcquisitionShedForCapacity
export AcquisitionShedForDeadline, AcquisitionFailedForCapacity
export AcquisitionFailedForDeadline, AcquisitionOverloadRecovered
export AcquisitionOverloadAccounting
export serial_acquisition_overload_accounting
export serial_rtc_ingress_liveness_accounting
export serial_rtc_ingress_liveness_policy
export serial_shutdown_policy

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

"""Last bounded overload decision for one acquisition completion path."""
@enum AcquisitionOverloadDecision::UInt8 begin
    AcquisitionNoOverloadDecision = 0x01
    AcquisitionProductPublished = 0x02
    AcquisitionShedForCapacity = 0x03
    AcquisitionShedForDeadline = 0x04
    AcquisitionFailedForCapacity = 0x05
    AcquisitionFailedForDeadline = 0x06
    AcquisitionOverloadRecovered = 0x07
end

"""Preallocated single-writer publication and overload evidence."""
mutable struct AcquisitionPublicationState
    last_sequence::UInt64
    products_published::UInt64
    products_shed::UInt64
    products_failed::UInt64
    overload_episodes::UInt64
    recovery_count::UInt64
    current_descriptor_occupancy::Int
    maximum_descriptor_occupancy::Int
    current_product_occupancy::Int
    maximum_product_occupancy::Int
    latest_lateness_ns::Int64
    maximum_lateness_ns::Int64
    overloaded::Bool
    recovered_to_threshold::Bool
    decision::AcquisitionOverloadDecision
end

AcquisitionPublicationState() = AcquisitionPublicationState(
    UInt64(0),
    UInt64(0),
    UInt64(0),
    UInt64(0),
    UInt64(0),
    UInt64(0),
    0,
    0,
    0,
    0,
    Int64(0),
    Int64(0),
    false,
    false,
    AcquisitionNoOverloadDecision)

"""Cold immutable overload evidence for one acquisition path."""
struct AcquisitionOverloadAccounting
    acquisition::AcquisitionID
    last_sequence::UInt64
    products_published::UInt64
    products_shed::UInt64
    products_failed::UInt64
    overload_episodes::UInt64
    recovery_count::UInt64
    current_descriptor_occupancy::Int
    maximum_descriptor_occupancy::Int
    current_product_occupancy::Int
    maximum_product_occupancy::Int
    latest_lateness_ns::Int64
    maximum_lateness_ns::Int64
    overloaded::Bool
    recovered_to_threshold::Bool
    decision::AcquisitionOverloadDecision
end

struct _SerialConstructionToken end
const _SERIAL_CONSTRUCTION_TOKEN = _SerialConstructionToken()

"""
Immutable configured topology for one deterministic serial runtime.

Model-supported runtime plant controls use the same prepared typed command
endpoints as every other RTC command. The serial configuration does not own a
second callback-like control surface.
"""
struct ConfiguredSerialRun{
    L<:PreparedPlantEventLoop,
    B<:PreparedCommandBridge,
    A<:Tuple,
    E<:AbstractOpticalExecutionConfiguration,
    I<:Lifecycle.AbstractRTCIngressLivenessPolicy,
}
    event_loop::L
    command_bridge::B
    acquisition_ports::A
    optical_execution::E
    lifecycle::RunLifecycleParameters
    ingress_liveness::I
    shutdown_policy::RunShutdownPolicy

    ConfiguredSerialRun(
        event_loop::L,
        command_bridge::B,
        acquisition_ports::A,
        optical_execution::E,
        lifecycle::RunLifecycleParameters,
        ingress_liveness::I,
        shutdown_policy::RunShutdownPolicy,
        ::_SerialConstructionToken) where {
        L<:PreparedPlantEventLoop,
        B<:PreparedCommandBridge,
        A<:Tuple,
        E<:AbstractOpticalExecutionConfiguration,
        I<:Lifecycle.AbstractRTCIngressLivenessPolicy,
    } = new{L,B,A,E,I}(
        event_loop,
        command_bridge,
        acquisition_ports,
        optical_execution,
        lifecycle,
        ingress_liveness,
        shutdown_policy)
end

"""Prepared serial shutdown coordination phase."""
@enum SerialShutdownStatus::UInt8 begin
    SerialShutdownInactive = 0x01
    SerialShutdownDraining = 0x02
    SerialShutdownFinalized = 0x03
end

mutable struct SerialShutdownState
    status::SerialShutdownStatus
    stop_event::Union{Nothing,RunStopRequest,RunTerminalEvent}
    command_ingress_closed::Bool
    command_completion_closed::Bool
    acquisition_completion_closed::Memory{Bool}
    command_returns_closed::Bool
    acquisition_returns_closed::Memory{Bool}
    execution_shutdown_begun::Bool
    clock_unavailable::Bool
end

function SerialShutdownState(acquisition_count::Int)
    acquisition_completion_closed =
        Memory{Bool}(undef, acquisition_count)
    acquisition_returns_closed =
        Memory{Bool}(undef, acquisition_count)
    fill!(acquisition_completion_closed, false)
    fill!(acquisition_returns_closed, false)
    return SerialShutdownState(
        SerialShutdownInactive,
        nothing,
        false,
        false,
        acquisition_completion_closed,
        false,
        acquisition_returns_closed,
        false,
        false)
end

"""
Single-writer run state. The command bridge owns the event-loop state and its
bounded command-correlation state; lifecycle and acquisition sequences remain
separate mutable state.
"""
mutable struct SerialRunState{
    B<:CommandBridgeState,
    I<:RTCIngressLivenessState,
}
    const bridge::B
    const publications::Memory{AcquisitionPublicationState}
    const ingress_liveness::I
    const lifecycle::RunLifecycleState
    const shutdown::SerialShutdownState
    plant_event_steps::UInt64
    products_published::UInt64

    SerialRunState(
        bridge::B,
        publications::Memory{AcquisitionPublicationState},
        ingress_liveness::I,
        lifecycle::RunLifecycleState,
        shutdown::SerialShutdownState,
        plant_event_steps::UInt64,
        products_published::UInt64,
        ::_SerialConstructionToken) where {
        B<:CommandBridgeState,
        I<:RTCIngressLivenessState,
    } =
        new{B,I}(
            bridge,
            publications,
            ingress_liveness,
            lifecycle,
            shutdown,
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
    failures::PreparedRunFailureCoordinator

    PreparedSerialRun(
        configuration::C,
        publishers::P,
        state::S,
        workspace::W,
        execution::E,
        failures::PreparedRunFailureCoordinator,
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
            execution,
            failures)
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
    E<:AbstractOpticalPathBatchExecutor,
}
    prepared::R
    timing::M
    execution::E

    ArmedSerialRun(
        prepared::R,
        timing::M,
        execution::E,
        ::_SerialConstructionToken) where {
        R<:PreparedSerialRun,
        M<:ExecutionClockMapping,
        E<:AbstractOpticalPathBatchExecutor,
    } = new{R,M,E}(prepared, timing, execution)
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

serial_rtc_ingress_liveness_policy(
    run::ConfiguredSerialRun) = run.ingress_liveness
serial_rtc_ingress_liveness_policy(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = _prepared_serial_run(run).configuration.ingress_liveness

serial_shutdown_policy(run::ConfiguredSerialRun) =
    run.shutdown_policy
serial_shutdown_policy(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = _prepared_serial_run(run).configuration.shutdown_policy

serial_shutdown_status(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = _prepared_serial_run(run).state.shutdown.status

serial_failure_accounting(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = Lifecycle.run_failure_accounting(
    _prepared_serial_run(run).failures)

serial_rtc_ingress_liveness_accounting(run::Union{
    PreparedSerialRun,
    ArmingSerialRun,
    ArmedSerialRun,
    RunningSerialRun,
}) = Lifecycle.rtc_ingress_liveness_accounting(
    _prepared_serial_run(run).state.ingress_liveness)

@inline function _acquisition_overload_accounting(
    publisher::PreparedAcquisitionPublisher,
    state::AcquisitionPublicationState)
    return AcquisitionOverloadAccounting(
        publisher.id,
        state.last_sequence,
        state.products_published,
        state.products_shed,
        state.products_failed,
        state.overload_episodes,
        state.recovery_count,
        state.current_descriptor_occupancy,
        state.maximum_descriptor_occupancy,
        state.current_product_occupancy,
        state.maximum_product_occupancy,
        state.latest_lateness_ns,
        state.maximum_lateness_ns,
        state.overloaded,
        state.recovered_to_threshold,
        state.decision)
end

@inline _serial_acquisition_overload_accounting(
    ::Tuple{},
    ::Memory{AcquisitionPublicationState},
    ::AcquisitionID,
    ::Int) = nothing

@inline function _serial_acquisition_overload_accounting(
    publishers::Tuple,
    publications::Memory{AcquisitionPublicationState},
    id::AcquisitionID,
    index::Int)
    publisher = first(publishers)
    publisher.id == id && return _acquisition_overload_accounting(
        publisher, @inbounds(publications[index]))
    return _serial_acquisition_overload_accounting(
        Base.tail(publishers), publications, id, index + 1)
end

function serial_acquisition_overload_accounting(
    run::Union{
        PreparedSerialRun,
        ArmingSerialRun,
        ArmedSerialRun,
        RunningSerialRun,
    },
    id::AcquisitionID)
    prepared = _prepared_serial_run(run)
    accounting = _serial_acquisition_overload_accounting(
        prepared.publishers, prepared.state.publications, id, 1)
    accounting === nothing || return accounting
    throw(SerialRunError(
        :serial_run,
        :unknown_acquisition,
        "serial run has no acquisition overload state for $id"))
end

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

@inline _validate_rtc_ingress_liveness(
    ::PreparedCommandBridge,
    ::Nothing) = NoRTCIngressLiveness()

function _validate_rtc_ingress_liveness(
    bridge::PreparedCommandBridge,
    policy::RTCIngressLivenessPolicy)
    submission = command_submission_port(bridge)
    policy.endpoint == submission.endpoint ||
        throw(SerialRunError(
            :rtc_ingress_liveness,
            :endpoint_mismatch,
            "RTC-ingress-liveness policy must target the serial command endpoint"))
    return policy
end

function _validate_rtc_ingress_liveness(
    ::PreparedCommandBridge,
    ::Any)
    throw(SerialRunError(
        :rtc_ingress_liveness,
        :invalid_policy,
        "RTC-ingress liveness must be nothing or RTCIngressLivenessPolicy"))
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
        ingress_liveness=nothing, shutdown_policy)

Validate and freeze the exact event-loop command route, acquisition-completion
ports, and relative arm deadline for one serial HIL topology. Runtime plant
state changes supported by the prepared model use typed command endpoints;
this lifecycle boundary does not add a parallel control queue or callback.
"""
function configure_serial_run(
    command_bridge::PreparedCommandBridge,
    acquisition_ports::Tuple;
    arm_timeout_ns::Integer,
    optical_execution=SerialOpticalExecution(),
    ingress_liveness=nothing,
    shutdown_policy::RunShutdownPolicy)
    execution = _validate_optical_execution(optical_execution)
    liveness = _validate_rtc_ingress_liveness(
        command_bridge, ingress_liveness)
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
        liveness,
        shutdown_policy,
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
    publications = Memory{AcquisitionPublicationState}(
        undef, length(publishers))
    for index in eachindex(publications)
        publications[index] = AcquisitionPublicationState()
    end
    state = SerialRunState(
        bridge,
        publications,
        RTCIngressLivenessState(configuration.ingress_liveness),
        RunLifecycleState(configuration.lifecycle),
        SerialShutdownState(length(publishers)),
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
        configuration.shutdown_policy,
    )
    failures = _execution_failure_coordinator(
        execution,
        configuration.lifecycle.session,
        configuration.shutdown_policy)
    return PreparedSerialRun(
        configuration,
        publishers,
        state,
        workspace,
        execution,
        failures,
        _SERIAL_CONSTRUCTION_TOKEN)
end

struct AcquisitionPortAccounting
    acquisition::AcquisitionID
    descriptors::RingAccounting
    products::PayloadPoolAccounting
end

"""
Cold ownership snapshot for one serial run.

`execution_owners` is `nothing` for the core serial oracle and a fixed
`Memory{ExecutionOwnerAccounting}` snapshot for prepared HIL owners.
After shutdown finalizes, every nonzero occupancy or nonfree ownership field
identifies an explicit resource deficit. `execution_batch_active` reports a
coordinator-held materialized optical batch that could not be safely
abandoned before the drain deadline.
"""
struct SerialRunAccounting{C,A<:Tuple,E}
    command_submissions::RingAccounting
    command_completions::RingAccounting
    command_credits::PayloadPoolAccounting
    command_payloads::C
    command_dispositions::Int
    active_command_correlations::Int
    acquisitions::A
    execution_batch_active::Bool
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
        publisher.id,
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
        _execution_batch_active(run.execution),
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
        !accounting.execution_batch_active &&
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
    try
        _arm_optical_execution!(attempt.prepared.execution)
    catch error
        failed = ArmedSerialRun(
            attempt.prepared,
            mapping,
            _bind_optical_execution_timing(
                attempt.prepared.execution, mapping),
            _SERIAL_CONSTRUCTION_TOKEN)
        _record_serial_failure!(failed, error)
        while _progress_serial_shutdown!(failed) !=
                SerialShutdownFinalized
            yield()
        end
        rethrow()
    end
    return ArmedSerialRun(
        attempt.prepared,
        mapping,
        _bind_optical_execution_timing(
            attempt.prepared.execution, mapping),
        _SERIAL_CONSTRUCTION_TOKEN)
end

function start_serial_run!(armed::ArmedSerialRun)
    _execution_is_armed(armed.prepared.execution) ||
        throw(SerialRunError(
            :serial_run,
            :execution_owners_not_armed,
            "optical execution owners must be armed before the run starts"))
    started_execution_ns =
        _read_execution_clock(execution_clock(armed.timing))
    _start_run!(armed.prepared.state.lifecycle)
    try
        _start_rtc_ingress_liveness!(
            armed.prepared.state.ingress_liveness,
            execution_clock_identity(armed.timing),
            started_execution_ns)
        _start_optical_execution!(armed.prepared.execution)
    catch error
        _record_serial_failure!(armed, error)
        rethrow()
    end
    return RunningSerialRun(armed, _SERIAL_CONSTRUCTION_TOKEN)
end

function _all_serial_shutdown_paths_closed(values::Memory{Bool})
    @inbounds for value in values
        value || return false
    end
    return true
end

@inline _close_serial_acquisition_completions!(
    ::Tuple{},
    ::SerialShutdownState,
    ::Int) = nothing

function _close_serial_acquisition_completions!(
    publishers::Tuple,
    shutdown::SerialShutdownState,
    index::Int)
    if !(@inbounds shutdown.acquisition_completion_closed[index])
        close_acquisition_completion!(first(publishers).port)
        @inbounds shutdown.acquisition_completion_closed[index] = true
    end
    _close_serial_acquisition_completions!(
        Base.tail(publishers), shutdown, index + 1)
    return nothing
end

function _begin_serial_shutdown_resources!(
    armed::ArmedSerialRun,
    stop_event::Union{Nothing,RunStopRequest,RunTerminalEvent},
    observed_execution_ns::Int64)
    run = armed.prepared
    state = run.state
    shutdown = state.shutdown
    if shutdown.status == SerialShutdownInactive
        shutdown.stop_event = stop_event
        shutdown.status = SerialShutdownDraining
        _begin_run_shutdown!(run.failures, observed_execution_ns)
    end

    if !shutdown.command_ingress_closed
        close_command_ingress!(
            command_submission_port(run.configuration.command_bridge))
        shutdown.command_ingress_closed = true
    end
    _close_serial_acquisition_completions!(
        run.publishers, shutdown, 1)
    reject_pending_bridge_commands!(
        run.configuration.command_bridge,
        state.bridge,
        run.workspace.bridge,
        observed_execution_ns)

    if !shutdown.execution_shutdown_begun
        _begin_optical_execution_shutdown!(run.execution)
        shutdown.execution_shutdown_begun = true
    end
    if shutdown.command_ingress_closed &&
            _all_serial_shutdown_paths_closed(
                shutdown.acquisition_completion_closed) &&
            shutdown.execution_shutdown_begun
        _acknowledge_run_stop!(run.failures, 1)
    end
    return shutdown.status
end

function _begin_serial_stop!(
    armed::ArmedSerialRun,
    event::Union{RunStopRequest,RunTerminalEvent})
    state = armed.prepared.state
    state.shutdown.status == SerialShutdownInactive ||
        return state.shutdown.status
    current_execution_ns =
        _read_execution_clock(execution_clock(armed.timing))
    _validate_stop_event(
        state.lifecycle,
        event,
        current_execution_ns)
    try
        return _begin_serial_shutdown_resources!(
            armed, event, current_execution_ns)
    catch error
        _record_serial_failure!(armed, error)
        rethrow()
    end
end

begin_serial_stop!(
    armed::ArmedSerialRun,
    event::Union{RunStopRequest,RunTerminalEvent}) =
    _begin_serial_stop!(armed, event)

begin_serial_stop!(
    running::RunningSerialRun,
    event::Union{RunStopRequest,RunTerminalEvent}) =
    _begin_serial_stop!(running.armed, event)

@inline function _command_return_paths_are_ready(
    run::PreparedSerialRun)
    bridge = run.configuration.command_bridge
    submission = command_submission_port(bridge)
    completion = command_completion_port(bridge)
    return iszero(ring_accounting(completion.ring).occupancy) &&
        _pool_is_quiescent(
            _serial_command_payload_accounting(submission)) &&
        _pool_is_quiescent(outcome_credit_accounting(submission))
end

@inline _progress_serial_acquisition_return_paths!( # COV_EXCL_LINE
    ::Tuple{},
    ::SerialShutdownState,
    ::Int) = true

function _progress_serial_acquisition_return_paths!(
    publishers::Tuple,
    shutdown::SerialShutdownState,
    index::Int)
    publisher = first(publishers)
    if !(@inbounds shutdown.acquisition_returns_closed[index]) &&
            iszero(ring_accounting(
                publisher.port.ring).occupancy) &&
            _pool_is_quiescent(
                acquisition_product_accounting(publisher.port))
        close_acquisition_return_path!(publisher.port)
        @inbounds shutdown.acquisition_returns_closed[index] = true
    end
    return (
        @inbounds(shutdown.acquisition_returns_closed[index]) &&
        _progress_serial_acquisition_return_paths!(
            Base.tail(publishers),
            shutdown,
            index + 1)
    )
end

@inline _serial_acquisition_ownership_is_drained( # COV_EXCL_LINE
    ::Tuple{}) = true

@inline function _serial_acquisition_ownership_is_drained(
    publishers::Tuple)
    port = first(publishers).port
    return iszero(ring_accounting(port.ring).occupancy) &&
        _pool_is_quiescent(acquisition_product_accounting(port)) &&
        _serial_acquisition_ownership_is_drained(
            Base.tail(publishers))
end

function _serial_shutdown_ownership_is_drained(
    run::PreparedSerialRun)
    bridge = run.configuration.command_bridge
    submission = command_submission_port(bridge)
    completion = command_completion_port(bridge)
    return (
        iszero(ring_accounting(submission.ring).occupancy) &&
        iszero(ring_accounting(completion.ring).occupancy) &&
        _pool_is_quiescent(outcome_credit_accounting(submission)) &&
        _pool_is_quiescent(
            _serial_command_payload_accounting(submission)) &&
        iszero(command_disposition_count(
            command_disposition_workspace(run.workspace.bridge))) &&
        iszero(active_command_correlations(run.state.bridge)) &&
        _serial_acquisition_ownership_is_drained(run.publishers) &&
        !_execution_batch_active(run.execution) &&
        _execution_ownership_is_drained(run.execution)
    )
end

function _progress_serial_shutdown_resources!(
    armed::ArmedSerialRun,
    observed_execution_ns::Int64)
    run = armed.prepared
    shutdown = run.state.shutdown
    _begin_serial_shutdown_resources!(
        armed, shutdown.stop_event, observed_execution_ns)
    reclaim_serial_returns!(run)
    execution_complete =
        _progress_optical_execution_shutdown!(run.execution)
    if execution_complete &&
            _abandon_failed_optical_path_batch!(run.execution) &&
            !shutdown.command_completion_closed
        fail_pending_bridge_commands!(
            run.configuration.command_bridge,
            run.state.bridge,
            run.workspace.bridge,
            observed_execution_ns;
            reason=CommandDispositionReason(:hil_run_shutdown))
        reject_pending_bridge_commands!(
            run.configuration.command_bridge,
            run.state.bridge,
            run.workspace.bridge,
            observed_execution_ns)
        close_command_completion!(
            command_completion_port(
                run.configuration.command_bridge))
        shutdown.command_completion_closed = true
    end
    if shutdown.command_completion_closed &&
            !shutdown.command_returns_closed &&
            _command_return_paths_are_ready(run)
        close_command_return_paths!(
            command_completion_port(
                run.configuration.command_bridge))
        shutdown.command_returns_closed = true
    end
    acquisition_returns_closed =
        _progress_serial_acquisition_return_paths!(
            run.publishers,
            shutdown,
            1)
    resources_closed =
        shutdown.command_ingress_closed &&
        shutdown.command_completion_closed &&
        _all_serial_shutdown_paths_closed(
            shutdown.acquisition_completion_closed) &&
        shutdown.command_returns_closed &&
        acquisition_returns_closed
    return (
        execution_complete &&
        resources_closed &&
        _run_shutdown_acknowledged(run.failures) &&
        _serial_shutdown_ownership_is_drained(run)
    )
end

function _finalize_serial_shutdown!(
    armed::ArmedSerialRun,
    drained::Bool)
    run = armed.prepared
    shutdown = run.state.shutdown
    if drained
        _finalize_optical_execution_shutdown!(run.execution)
    else
        _mark_optical_execution_failed!(run.execution)
    end
    _finalize_run_shutdown!(run.failures)
    failure = Lifecycle.first_run_failure(run.failures)
    if failure === nothing
        event = shutdown.stop_event
        event === nothing && throw(SerialRunError(
            :serial_shutdown,
            :missing_terminal_cause,
            "a clean serial shutdown has no stop or terminal event"))
        _record_stop!(run.state.lifecycle, event)
    else
        _fail_run!(
            run.state.lifecycle,
            RunFailureEvent(
                Lifecycle.run_failure_kind(failure),
                run_session(armed),
                execution_clock_identity(armed.timing),
                Lifecycle.run_failure_execution_ns(failure),
                Lifecycle.run_failure_component(failure),
                Lifecycle.run_failure_reason(failure)))
    end
    shutdown.status = SerialShutdownFinalized
    return shutdown.status
end

function _publish_serial_shutdown_timeout!(
    armed::ArmedSerialRun,
    kind,
    stage,
    observed_execution_ns::Int64,
    reason::Symbol)
    return _publish_run_failure!(
        armed.prepared.failures,
        1,
        kind,
        stage,
        observed_execution_ns,
        :serial_shutdown,
        reason)
end

function _progress_serial_shutdown!(
    armed::ArmedSerialRun)
    run = armed.prepared
    shutdown = run.state.shutdown
    shutdown.status == SerialShutdownFinalized &&
        return SerialShutdownFinalized
    shutdown.status == SerialShutdownDraining ||
        throw(SerialRunError(
            :serial_shutdown,
            :shutdown_not_started,
            "serial shutdown must begin before it can progress"))

    local current_execution_ns::Int64
    try
        current_execution_ns =
            _read_execution_clock(execution_clock(armed.timing))
    catch error
        shutdown.clock_unavailable = true
        _publish_run_failure!(
            run.failures,
            1,
            OwnerExceptionRunFailure,
            CoordinatorFailureBoundary,
            nothing,
            :execution_clock,
            :unavailable)
        return _finalize_serial_shutdown!(armed, false)
    end

    drained = false
    try
        drained = _progress_serial_shutdown_resources!(
            armed, current_execution_ns)
    catch error
        _publish_serial_coordinator_failure!(
            armed, error, current_execution_ns)
        _mark_optical_execution_failed!(run.execution)
    end

    timed_out = _record_acknowledgement_timeouts!(
        run.failures, current_execution_ns)
    if timed_out > 0
        _publish_serial_shutdown_timeout!(
            armed,
            AcknowledgementTimeoutRunFailure,
            ShutdownAcknowledgement,
            current_execution_ns,
            :acknowledgement_timeout)
    end

    if _run_shutdown_drain_expired!(
        run.failures, current_execution_ns)
        _publish_serial_shutdown_timeout!(
            armed,
            DrainTimeoutRunFailure,
            ShutdownDrain,
            current_execution_ns,
            :drain_timeout)
        return _finalize_serial_shutdown!(armed, false)
    end
    drained && return _finalize_serial_shutdown!(armed, true)
    return SerialShutdownDraining
end

progress_serial_shutdown!(armed::ArmedSerialRun) =
    _progress_serial_shutdown!(armed)
progress_serial_shutdown!(running::RunningSerialRun) =
    _progress_serial_shutdown!(running.armed)

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

@inline _serial_acquisition_may_shed(
    ::AcquisitionOverloadPolicy{
        OptionalResource,
        DropNewestOnFull,
    }) = true
@inline _serial_acquisition_may_shed(
    ::AcquisitionOverloadPolicy) = false

@inline function _observe_serial_acquisition_occupancy!(
    publication::AcquisitionPublicationState,
    port::AcquisitionCompletionPort)
    descriptor_occupancy = ring_accounting(port.ring).occupancy
    products = acquisition_product_accounting(port)
    product_occupancy = products.capacity - products.free
    publication.current_descriptor_occupancy =
        descriptor_occupancy
    publication.maximum_descriptor_occupancy = max(
        publication.maximum_descriptor_occupancy,
        descriptor_occupancy,
    )
    publication.current_product_occupancy = product_occupancy
    publication.maximum_product_occupancy = max(
        publication.maximum_product_occupancy,
        product_occupancy,
    )
    return nothing
end

@inline function _serial_lateness_is_recovered(
    policy::AcquisitionOverloadPolicy,
    publication::AcquisitionPublicationState)
    maximum = policy.maximum_lateness_ns
    return maximum === nothing ||
        publication.latest_lateness_ns <= maximum
end

@inline function _maybe_record_serial_overload_recovery!(
    policy::AcquisitionOverloadPolicy,
    publication::AcquisitionPublicationState)
    publication.overloaded || return false
    publication.current_descriptor_occupancy <=
        policy.recovery_occupancy ||
        return false
    publication.current_product_occupancy <=
        policy.recovery_occupancy ||
        return false
    _serial_lateness_is_recovered(policy, publication) ||
        return false
    publication.overloaded = false
    publication.recovered_to_threshold = true
    publication.recovery_count += UInt64(1)
    publication.decision = AcquisitionOverloadRecovered
    return true
end

@inline function _record_serial_acquisition_lateness!(
    publication::AcquisitionPublicationState,
    lateness_ns::Int64)
    nonnegative_lateness = max(Int64(0), lateness_ns)
    publication.latest_lateness_ns = nonnegative_lateness
    publication.maximum_lateness_ns =
        max(publication.maximum_lateness_ns, nonnegative_lateness)
    return nonnegative_lateness
end

@inline function _mark_serial_acquisition_overload!(
    publication::AcquisitionPublicationState,
    decision::AcquisitionOverloadDecision)
    if !publication.overloaded
        publication.overload_episodes += UInt64(1)
    end
    publication.overloaded = true
    publication.recovered_to_threshold = false
    publication.decision = decision
    return decision
end

@inline function _shed_serial_acquisition!(
    publication::AcquisitionPublicationState,
    decision::AcquisitionOverloadDecision)
    _mark_serial_acquisition_overload!(publication, decision)
    publication.products_shed += UInt64(1)
    return 0
end

@noinline function _fail_serial_acquisition!(
    publication::AcquisitionPublicationState,
    decision::AcquisitionOverloadDecision,
    reason::Symbol,
    message::String)
    _mark_serial_acquisition_overload!(publication, decision)
    publication.products_failed += UInt64(1)
    _serial_publication_error(reason, message)
end

@inline function _handle_serial_capacity_overload!(
    policy::AcquisitionOverloadPolicy,
    publication::AcquisitionPublicationState)
    _serial_acquisition_may_shed(policy) &&
        return _shed_serial_acquisition!(
            publication, AcquisitionShedForCapacity)
    return _fail_serial_acquisition!(
        publication,
        AcquisitionFailedForCapacity,
        :acquisition_product_capacity,
        "the prepared acquisition completion path exhausted its bounded capacity")
end

@inline function _handle_serial_deadline_overload!(
    policy::AcquisitionOverloadPolicy,
    publication::AcquisitionPublicationState)
    _serial_acquisition_may_shed(policy) &&
        return _shed_serial_acquisition!(
            publication, AcquisitionShedForDeadline)
    return _fail_serial_acquisition!(
        publication,
        AcquisitionFailedForDeadline,
        :acquisition_publication_deadline,
        "the acquisition product exceeded its prepared publication lateness")
end

@inline function _abort_serial_product!(
    port::AcquisitionCompletionPort,
    lease::PayloadLeaseRef)
    abort_product!(port, lease) == PayloadTransitionSucceeded ||
        _serial_publication_error(
            :acquisition_product_reclamation,
            "serial publication could not reclaim its producer-owned product")
    return nothing
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
    publication = @inbounds state.publications[index]
    policy = publisher.port.overload_policy
    _observe_serial_acquisition_occupancy!(
        publication, publisher.port)
    _maybe_record_serial_overload_recovery!(policy, publication)
    last_sequence = publication.last_sequence
    published = 0
    if sequence != last_sequence
        sequence == last_sequence + UInt64(1) ||
            _serial_publication_error(
                :acquisition_sequence_gap,
                "serial publication observed an unavailable acquisition-product history")
        publication.last_sequence = sequence
        timestamp = acquisition_product_ready_timestamp(
            event_loop, event_state, publisher.id)
        timestamp === nothing && _serial_publication_error(
            :missing_acquisition_timestamp,
            "a sequenced acquisition product has no readiness timestamp")
        lateness_ns = _record_serial_acquisition_lateness!(
            publication,
            execution_lateness_ns(
                armed.timing, timestamp, publication_execution_ns))
        _maybe_record_serial_overload_recovery!(policy, publication)
        maximum_lateness_ns = policy.maximum_lateness_ns
        if maximum_lateness_ns !== nothing &&
                lateness_ns > maximum_lateness_ns
            _handle_serial_deadline_overload!(policy, publication)
            return _publish_serial_products!(
                Base.tail(publishers),
                armed,
                state,
                workspace,
                publication_execution_ns,
                index + 1)
        end
        lease_ref = @inbounds workspace.product_leases[index]
        claim_status = try_claim_product!(lease_ref, publisher.port)
        if claim_status != PayloadTransitionSucceeded
            if claim_status == PayloadPoolExhausted
                _handle_serial_capacity_overload!(
                    policy, publication)
            elseif claim_status == PayloadPoolClosed
                _fail_serial_acquisition!(
                    publication,
                    AcquisitionFailedForCapacity,
                    :acquisition_publication_rejected,
                    "the acquisition product pool was closed while the run was active")
            else
                _serial_publication_error(
                    :acquisition_product_claim,
                    "acquisition product claim returned an invalid ownership status")
            end
            _observe_serial_acquisition_occupancy!(
                publication, publisher.port)
            return _publish_serial_products!(
                Base.tail(publishers),
                armed,
                state,
                workspace,
                publication_execution_ns,
                index + 1)
        end
        lease = lease_ref[]
        destination = producer_product(publisher.port, lease)
        try
            _copy_serial_acquisition_products!(
                destination, publisher.source)
        catch
            _abort_serial_product!(publisher.port, lease)
            rethrow()
        end
        completion = matching_acquisition_completion(
            publisher.port,
            StreamSequence(sequence),
            timestamp,
            lease,
            publication_execution_ns)
        result = try_publish!(publisher.port, completion)
        publication_status = port_status(result)
        if publication_status == PortFull
            if !_serial_acquisition_may_shed(policy)
                _abort_serial_product!(publisher.port, lease)
            end
            _handle_serial_capacity_overload!(policy, publication)
            _observe_serial_acquisition_occupancy!(
                publication, publisher.port)
            return _publish_serial_products!(
                Base.tail(publishers),
                armed,
                state,
                workspace,
                publication_execution_ns,
                index + 1)
        elseif publication_status != PortTransferSucceeded
            _abort_serial_product!(publisher.port, lease)
            _fail_serial_acquisition!(
                publication,
                AcquisitionFailedForCapacity,
                :acquisition_publication_rejected,
                "the complete acquisition product could not be published")
        end
        publication.products_published += UInt64(1)
        publication.decision = AcquisitionProductPublished
        state.products_published += UInt64(1)
        _observe_serial_acquisition_occupancy!(
            publication, publisher.port)
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

@noinline function _fail_serial_ingress_liveness!(
    armed::ArmedSerialRun,
    state::SerialRunState,
    workspace::SerialRunWorkspace,
    observed_execution_ns::Int64)
    fail_pending_bridge_commands!(
        armed.prepared.configuration.command_bridge,
        state.bridge,
        workspace.bridge,
        observed_execution_ns)
    throw(SerialRunError(
        :rtc_ingress_liveness,
        :deadline_expired,
        "RTC-ingress-liveness observation exceeded its inclusive execution-clock deadline"))
end

function _step_serial_run!(
    armed::ArmedSerialRun,
    state::SerialRunState,
    workspace::SerialRunWorkspace,
    execution::AbstractOpticalPathBatchExecutor)
    run = armed.prepared
    configuration = run.configuration
    publication_execution_ns =
        _read_execution_clock(execution_clock(armed.timing))
    liveness_status = _observe_rtc_ingress_liveness!(
        state.ingress_liveness,
        execution_clock_identity(armed.timing),
        publication_execution_ns)
    liveness_status == RTCIngressLivenessExpired &&
        _fail_serial_ingress_liveness!(
            armed, state, workspace, publication_execution_ns)
    command_result = process_next_command!(
        configuration.command_bridge,
        state.bridge,
        workspace.bridge,
        publication_execution_ns)
    command_status = port_status(
        command_processing_port_result(command_result))
    if command_status == PortTransferSucceeded
        admission_execution_ns =
            _read_execution_clock(execution_clock(armed.timing))
        if command_processing_stage(command_result) ==
                CommandSemanticallyAdmitted
            liveness_status = _admit_rtc_ingress_liveness!(
                state.ingress_liveness,
                command_processing_endpoint(command_result),
                execution_clock_identity(armed.timing),
                admission_execution_ns)
        else
            liveness_status = _observe_rtc_ingress_liveness!(
                state.ingress_liveness,
                execution_clock_identity(armed.timing),
                admission_execution_ns)
        end
        liveness_status == RTCIngressLivenessExpired &&
            _fail_serial_ingress_liveness!(
                armed, state, workspace, admission_execution_ns)
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
        _read_execution_clock(execution_clock(armed.timing))
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

@inline _serial_failure_kind(::Any) =
    OwnerExceptionRunFailure

@inline function _serial_failure_kind(error::SerialRunError)
    error.component == :rtc_ingress_liveness &&
        return IngressWatchdogRunFailure
    error.reason in (
        :acquisition_product_capacity,
        :acquisition_publication_deadline,
        :acquisition_publication_rejected,
    ) && return ResourcePolicyRunFailure
    return OwnerExceptionRunFailure
end

@inline function _serial_failure_kind(error::ExecutionOwnerError)
    error.reason in (
        :due_work_publication,
        :owner_deadline_exceeded,
    ) && return ResourcePolicyRunFailure
    return OwnerExceptionRunFailure
end

function _publish_serial_coordinator_failure!(
    armed::ArmedSerialRun,
    error,
    observed_execution_ns::Union{Nothing,Int64})
    failures = armed.prepared.failures
    if Lifecycle.first_run_failure(failures) === nothing
        _publish_run_failure!(
            failures,
            1,
            _serial_failure_kind(error),
            CoordinatorFailureBoundary,
            observed_execution_ns,
            _serial_failure_component(error),
            _serial_failure_reason(error))
    end
    # Freeze the first coordinator-observed record before a later timeout can
    # publish into an earlier-numbered free slot.
    Lifecycle.first_run_failure(failures)
    return nothing
end

@noinline function _record_serial_failure!(
    armed::ArmedSerialRun,
    error)
    observed_execution_ns = try
        _read_execution_clock(execution_clock(armed.timing))
    catch
        nothing
    end
    _publish_serial_coordinator_failure!(
        armed, error, observed_execution_ns)
    _mark_optical_execution_failed!(armed.prepared.execution)
    shutdown = armed.prepared.state.shutdown
    if shutdown.status == SerialShutdownInactive
        if observed_execution_ns === nothing
            shutdown.clock_unavailable = true
            observed_execution_ns =
                execution_clock_origin_ns(armed.timing)
        end
        try
            _begin_serial_shutdown_resources!(
                armed, nothing, observed_execution_ns)
        catch
            # Preserve the original first-failure record. Partially completed
            # closure remains visible to bounded progress/deficit accounting.
        end
    end
    return Lifecycle.first_run_failure(armed.prepared.failures)
end

_record_serial_failure!(
    running::RunningSerialRun,
    error,
) = _record_serial_failure!(running.armed, error)

function step_serial_run!(running::RunningSerialRun)
    run = running.armed.prepared
    state = run.state
    workspace = run.workspace
    state.shutdown.status == SerialShutdownInactive ||
        throw(SerialRunError(
            :serial_shutdown,
            :shutdown_in_progress,
            "serial event processing cannot continue after the stop epoch"))
    _require_phase(state.lifecycle, RunRunning, :serial_step)
    try
        return _step_serial_run!(
            running.armed,
            state,
            workspace,
            running.armed.execution)
    catch error
        _record_serial_failure!(running, error)
        rethrow()
    end
end

public SerialRunState, SerialRunWorkspace
public AcquisitionPublicationState
public AcquisitionPortAccounting

end
