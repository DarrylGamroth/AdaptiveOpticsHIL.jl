"""
    Lifecycle

Transport-neutral run identity, readiness, arm-window, phase, and termination
contracts. This namespace owns operational state transitions; it does not
prepare an optical plant, start workers, close ports, drain ownership, sleep,
poll, or choose an RTC transport.
"""
module Lifecycle

using AdaptiveOpticsSim.Plant: PlantTimestamp

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError
using ..Timing: ExecutionClockID

export RunLifecycleError
export RunSessionID, run_session_value
export run_session
export RunPhase, RunConfigured, RunPrepared, RunArming, RunArmed
export RunRunning, RunStopped, RunFailed
export run_phase, run_arm_window, run_termination
export run_adapter_readiness
export run_execution_clock_identity, run_armed_execution_ns
export ArmWindow, arm_opened_execution_ns, arm_deadline_execution_ns
export AdapterReadinessStatus, AdapterNotReady, AdapterReady, AdapterFailed
export AdapterReadinessSnapshot, adapter_readiness_status
export adapter_readiness_execution_ns
export RunStopRequest, RunTerminalEvent
export stop_request_execution_ns, stop_request_reason
export terminal_event_plant_timestamp
export terminal_event_execution_ns, terminal_event_reason
export RunTerminationKind, RequestedRunStop
export ConfiguredTerminalStop, ArmDeadlineExpired, AdapterReadinessFailed
export RuntimeRunFailure
export RunTermination, run_termination_kind
export run_termination_execution_ns, run_termination_plant_timestamp
export run_termination_component, run_termination_reason

"""Invalid run identity, readiness, phase transition, or terminal event."""
struct RunLifecycleError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

struct _RunSessionToken end
const _RUN_SESSION_TOKEN = _RunSessionToken()
struct _LifecycleConstructionToken end
const _LIFECYCLE_CONSTRUCTION_TOKEN = _LifecycleConstructionToken()

@inline function _checked_positive_session(value::Integer)
    value > 0 || throw(RunLifecycleError(
        :run_session,
        :invalid_identity,
        "run/session identity must be positive"))
    value <= typemax(UInt64) || throw(RunLifecycleError(
        :run_session,
        :invalid_identity,
        "run/session identity exceeds UInt64 range"))
    return UInt64(value)
end

@inline _checked_positive_session(::Bool) = throw(RunLifecycleError(
    :run_session,
    :invalid_identity,
    "run/session identity must be an integer count, not Bool"))

"""Positive epoch shared by every resource participating in one run."""
struct RunSessionID
    value::UInt64

    RunSessionID(value::UInt64, ::_RunSessionToken) = new(value)
end

RunSessionID(value::Integer) =
    RunSessionID(_checked_positive_session(value), _RUN_SESSION_TOKEN)

Base.:(==)(left::RunSessionID, right::RunSessionID) =
    left.value == right.value
Base.isequal(left::RunSessionID, right::RunSessionID) =
    isequal(left.value, right.value)
Base.hash(value::RunSessionID, seed::UInt) =
    hash(value.value, hash(RunSessionID, seed))

function Base.show(io::IO, value::RunSessionID)
    print(io, nameof(typeof(value)), "(", value.value, ")")
end

"""Return the numeric run/session epoch."""
run_session_value(value::RunSessionID) = value.value

@inline function _checked_int64_timestamp(
    value::Integer,
    component::Symbol,
    label::AbstractString)
    typemin(Int64) <= value <= typemax(Int64) || throw(RunLifecycleError(
        component,
        :timestamp_out_of_range,
        "$label must fit Int64 nanoseconds"))
    return Int64(value)
end

@inline _checked_int64_timestamp(
    ::Bool,
    component::Symbol,
    label::AbstractString) =
    throw(RunLifecycleError(
        component,
        :invalid_timestamp,
        "$label must be an integer nanosecond coordinate, not Bool"))

@inline function _checked_positive_timeout(value::Integer)
    0 < value <= typemax(Int64) || throw(RunLifecycleError(
        :run_lifecycle_parameters,
        :invalid_arm_timeout,
        "arm timeout must be a positive Int64-compatible nanosecond count"))
    return Int64(value)
end

@inline _checked_positive_timeout(::Bool) = throw(RunLifecycleError(
    :run_lifecycle_parameters,
    :invalid_arm_timeout,
    "arm timeout must be an integer nanosecond count, not Bool"))

"""
Immutable operational policy established during configuration.

The arm timeout is relative to the execution-clock reading captured when the
arm phase begins.
"""
struct RunLifecycleParameters
    session::RunSessionID
    arm_timeout_ns::Int64

    function RunLifecycleParameters(
        session::RunSessionID;
        arm_timeout_ns::Integer)
        return new(session, _checked_positive_timeout(arm_timeout_ns))
    end
end

run_session(parameters::RunLifecycleParameters) = parameters.session
arm_timeout_ns(parameters::RunLifecycleParameters) =
    parameters.arm_timeout_ns

"""
Operational run phase.

`RunConfigured` is represented by an immutable runtime-specific configuration.
Mutable lifecycle state begins at `RunPrepared`.
"""
@enum RunPhase::UInt8 begin
    RunConfigured = 0x01
    RunPrepared = 0x02
    RunArming = 0x03
    RunArmed = 0x04
    RunRunning = 0x05
    RunStopped = 0x06
    RunFailed = 0x07
end

"""
Absolute execution-clock window for one arm attempt.

The deadline is inclusive: readiness observed and validated exactly at the
deadline may arm; the first later execution-clock reading expires the attempt.
Elapsed comparisons use signed modular subtraction for intervals shorter than
`2^63` nanoseconds, matching the execution-clock mapping contract across the
`Int64` representation wrap.
"""
struct ArmWindow
    session::RunSessionID
    execution_clock::ExecutionClockID
    opened_execution_ns::Int64
    deadline_execution_ns::Int64

    ArmWindow(
        session::RunSessionID,
        execution_clock::ExecutionClockID,
        opened_execution_ns::Int64,
        deadline_execution_ns::Int64,
        ::_LifecycleConstructionToken) =
        new(
            session,
            execution_clock,
            opened_execution_ns,
            deadline_execution_ns)
end

function ArmWindow(
    parameters::RunLifecycleParameters,
    execution_clock::ExecutionClockID,
    opened_execution_ns::Integer)
    opened = _checked_int64_timestamp(
        opened_execution_ns,
        :run_arm,
        "arm-open execution timestamp")
    deadline = reinterpret(
        Int64,
        reinterpret(UInt64, opened) + UInt64(parameters.arm_timeout_ns))
    return ArmWindow(
        parameters.session,
        execution_clock,
        opened,
        deadline,
        _LIFECYCLE_CONSTRUCTION_TOKEN)
end

run_session(window::ArmWindow) = window.session
run_execution_clock_identity(window::ArmWindow) =
    window.execution_clock
arm_opened_execution_ns(window::ArmWindow) =
    window.opened_execution_ns
arm_deadline_execution_ns(window::ArmWindow) =
    window.deadline_execution_ns

@inline _arm_timeout_ns(window::ArmWindow) = reinterpret(
    Int64,
    reinterpret(UInt64, window.deadline_execution_ns) -
        reinterpret(UInt64, window.opened_execution_ns))

"""Adapter availability reported by user orchestration."""
@enum AdapterReadinessStatus::UInt8 begin
    AdapterNotReady = 0x01
    AdapterReady = 0x02
    AdapterFailed = 0x03
end

"""
Transport-neutral adapter-readiness observation on the monotonic execution
clock. The session prevents a prior run's readiness from arming a fresh run.
"""
struct AdapterReadinessSnapshot
    session::RunSessionID
    execution_clock::ExecutionClockID
    status::AdapterReadinessStatus
    observed_execution_ns::Int64

    AdapterReadinessSnapshot(
        session::RunSessionID,
        execution_clock::ExecutionClockID,
        status::AdapterReadinessStatus,
        observed_execution_ns::Int64,
        ::_LifecycleConstructionToken) =
        new(session, execution_clock, status, observed_execution_ns)
end

function AdapterReadinessSnapshot(
    session::RunSessionID,
    execution_clock::ExecutionClockID,
    status::AdapterReadinessStatus,
    observed_execution_ns::Integer)
    observed = _checked_int64_timestamp(
        observed_execution_ns,
        :adapter_readiness,
        "adapter-readiness execution timestamp")
    return AdapterReadinessSnapshot(
        session,
        execution_clock,
        status,
        observed,
        _LIFECYCLE_CONSTRUCTION_TOKEN)
end

run_session(snapshot::AdapterReadinessSnapshot) =
    snapshot.session
run_execution_clock_identity(
    snapshot::AdapterReadinessSnapshot) =
    snapshot.execution_clock
adapter_readiness_status(snapshot::AdapterReadinessSnapshot) =
    snapshot.status
adapter_readiness_execution_ns(snapshot::AdapterReadinessSnapshot) =
    snapshot.observed_execution_ns

@inline function _checked_reason(
    value::Symbol,
    component::Symbol,
    label::AbstractString)
    isempty(String(value)) && throw(RunLifecycleError(
        component,
        :empty_reason,
        "$label must not be empty"))
    return value
end

"""Typed user request for a clean run stop."""
struct RunStopRequest
    session::RunSessionID
    execution_clock::ExecutionClockID
    requested_execution_ns::Int64
    reason::Symbol

    RunStopRequest(
        session::RunSessionID,
        execution_clock::ExecutionClockID,
        requested_execution_ns::Int64,
        reason::Symbol,
        ::_LifecycleConstructionToken) =
        new(session, execution_clock, requested_execution_ns, reason)
end

function RunStopRequest(
    session::RunSessionID,
    execution_clock::ExecutionClockID,
    requested_execution_ns::Integer;
    reason::Symbol=:requested)
    requested = _checked_int64_timestamp(
        requested_execution_ns,
        :run_stop_request,
        "stop-request execution timestamp")
    return RunStopRequest(
        session,
        execution_clock,
        requested,
        _checked_reason(reason, :run_stop_request, "stop-request reason"),
        _LIFECYCLE_CONSTRUCTION_TOKEN)
end

run_session(event::RunStopRequest) = event.session
run_execution_clock_identity(event::RunStopRequest) =
    event.execution_clock
stop_request_execution_ns(event::RunStopRequest) =
    event.requested_execution_ns
stop_request_reason(event::RunStopRequest) = event.reason

"""Typed configured terminal event for a clean running-phase stop."""
struct RunTerminalEvent
    session::RunSessionID
    execution_clock::ExecutionClockID
    plant_timestamp::PlantTimestamp
    observed_execution_ns::Int64
    reason::Symbol

    RunTerminalEvent(
        session::RunSessionID,
        execution_clock::ExecutionClockID,
        plant_timestamp::PlantTimestamp,
        observed_execution_ns::Int64,
        reason::Symbol,
        ::_LifecycleConstructionToken) =
        new(
            session,
            execution_clock,
            plant_timestamp,
            observed_execution_ns,
            reason)
end

function RunTerminalEvent(
    session::RunSessionID,
    execution_clock::ExecutionClockID,
    plant_timestamp::PlantTimestamp,
    observed_execution_ns::Integer;
    reason::Symbol=:terminal_event)
    observed = _checked_int64_timestamp(
        observed_execution_ns,
        :run_terminal_event,
        "terminal-event execution timestamp")
    return RunTerminalEvent(
        session,
        execution_clock,
        plant_timestamp,
        observed,
        _checked_reason(
            reason, :run_terminal_event, "terminal-event reason"),
        _LIFECYCLE_CONSTRUCTION_TOKEN)
end

run_session(event::RunTerminalEvent) = event.session
run_execution_clock_identity(event::RunTerminalEvent) =
    event.execution_clock
terminal_event_plant_timestamp(event::RunTerminalEvent) =
    event.plant_timestamp
terminal_event_execution_ns(event::RunTerminalEvent) =
    event.observed_execution_ns
terminal_event_reason(event::RunTerminalEvent) = event.reason

"""Compact runtime failure observed at an owner boundary."""
struct RunFailureEvent
    session::RunSessionID
    execution_clock::ExecutionClockID
    observed_execution_ns::Union{Nothing,Int64}
    component::Symbol
    reason::Symbol

    RunFailureEvent(
        session::RunSessionID,
        execution_clock::ExecutionClockID,
        observed_execution_ns::Union{Nothing,Int64},
        component::Symbol,
        reason::Symbol,
        ::_LifecycleConstructionToken) =
        new(
            session,
            execution_clock,
            observed_execution_ns,
            component,
            reason)
end

function RunFailureEvent(
    session::RunSessionID,
    execution_clock::ExecutionClockID,
    observed_execution_ns::Union{Nothing,Integer},
    component::Symbol,
    reason::Symbol)
    observed = observed_execution_ns === nothing ? nothing :
        _checked_int64_timestamp(
            observed_execution_ns,
            :run_failure,
            "failure execution timestamp")
    return RunFailureEvent(
        session,
        execution_clock,
        observed,
        _checked_reason(component, :run_failure, "failure component"),
        _checked_reason(reason, :run_failure, "failure reason"),
        _LIFECYCLE_CONSTRUCTION_TOKEN)
end

run_session(event::RunFailureEvent) = event.session
run_execution_clock_identity(event::RunFailureEvent) =
    event.execution_clock
failure_event_execution_ns(event::RunFailureEvent) =
    event.observed_execution_ns
failure_event_component(event::RunFailureEvent) = event.component
failure_event_reason(event::RunFailureEvent) = event.reason

"""Terminal category retained after a clean or failed run transition."""
@enum RunTerminationKind::UInt8 begin
    RequestedRunStop = 0x01
    ConfiguredTerminalStop = 0x02
    ArmDeadlineExpired = 0x03
    AdapterReadinessFailed = 0x04
    RuntimeRunFailure = 0x05
end

"""Immutable cold-path terminal record for one run."""
struct RunTermination
    kind::RunTerminationKind
    session::RunSessionID
    execution_clock::ExecutionClockID
    observed_execution_ns::Union{Nothing,Int64}
    plant_timestamp::Union{Nothing,PlantTimestamp}
    component::Symbol
    reason::Symbol

    RunTermination(
        kind::RunTerminationKind,
        session::RunSessionID,
        execution_clock::ExecutionClockID,
        observed_execution_ns::Union{Nothing,Int64},
        plant_timestamp::Union{Nothing,PlantTimestamp},
        component::Symbol,
        reason::Symbol,
        ::_LifecycleConstructionToken) =
        new(
            kind,
            session,
            execution_clock,
            observed_execution_ns,
            plant_timestamp,
            component,
            reason)
end

run_termination_kind(value::RunTermination) = value.kind
run_session(value::RunTermination) = value.session
run_execution_clock_identity(value::RunTermination) =
    value.execution_clock
run_termination_execution_ns(value::RunTermination) =
    value.observed_execution_ns
run_termination_plant_timestamp(value::RunTermination) =
    value.plant_timestamp
run_termination_component(value::RunTermination) = value.component
run_termination_reason(value::RunTermination) = value.reason

"""
Single-writer operational lifecycle state. Runtime-specific params, mutable
simulation state, and workspaces remain separate.
"""
mutable struct RunLifecycleState
    const session::RunSessionID
    phase::RunPhase
    arm_window::Union{Nothing,ArmWindow}
    execution_clock::Union{Nothing,ExecutionClockID}
    armed_execution_ns::Union{Nothing,Int64}
    readiness::Union{Nothing,AdapterReadinessSnapshot}
    termination::Union{Nothing,RunTermination}

    RunLifecycleState(
        session::RunSessionID,
        phase::RunPhase,
        arm_window::Union{Nothing,ArmWindow},
        execution_clock::Union{Nothing,ExecutionClockID},
        armed_execution_ns::Union{Nothing,Int64},
        readiness::Union{Nothing,AdapterReadinessSnapshot},
        termination::Union{Nothing,RunTermination},
        ::_LifecycleConstructionToken) =
        new(
            session,
            phase,
            arm_window,
            execution_clock,
            armed_execution_ns,
            readiness,
            termination)
end

RunLifecycleState(parameters::RunLifecycleParameters) =
    RunLifecycleState(
        parameters.session,
        RunPrepared,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        _LIFECYCLE_CONSTRUCTION_TOKEN)

run_session(state::RunLifecycleState) = state.session
run_phase(state::RunLifecycleState) = state.phase
run_arm_window(state::RunLifecycleState) = state.arm_window
run_execution_clock_identity(state::RunLifecycleState) =
    state.execution_clock
run_armed_execution_ns(state::RunLifecycleState) =
    state.armed_execution_ns
run_adapter_readiness(state::RunLifecycleState) =
    state.readiness
run_termination(state::RunLifecycleState) = state.termination

const _RUN_TRANSITION_MATRIX = (
    # to: configured prepared arming armed running stopped failed
    (false, true,  false, false, false, false, false), # configured
    (false, false, true,  false, false, false, false), # prepared
    (false, false, false, true,  false, false, true),  # arming
    (false, false, false, false, true,  true,  true),  # armed
    (false, false, false, false, false, true,  true),  # running
    (false, false, false, false, false, false, false), # stopped
    (false, false, false, false, false, false, false), # failed
)

"""
Return whether the operational lifecycle permits one phase edge.

Configuration-to-preparation is represented by construction of a prepared
runtime; the remaining edges mutate its single-writer lifecycle state.
"""
@inline function run_transition_is_valid(
    from::RunPhase,
    to::RunPhase)
    return @inbounds _RUN_TRANSITION_MATRIX[Int(from)][Int(to)]
end

@inline function _require_session(
    state::RunLifecycleState,
    session::RunSessionID,
    component::Symbol)
    session == state.session || throw(RunLifecycleError(
        component,
        :stale_session,
        "lifecycle event belongs to another run/session"))
    return nothing
end

@inline function _require_phase(
    state::RunLifecycleState,
    expected::RunPhase,
    component::Symbol)
    state.phase == expected || throw(RunLifecycleError(
        component,
        :invalid_phase,
        "run phase $(state.phase) does not permit this transition"))
    return nothing
end

@inline function _require_transition(
    state::RunLifecycleState,
    target::RunPhase,
    component::Symbol)
    run_transition_is_valid(state.phase, target) ||
        throw(RunLifecycleError(
            component,
            :invalid_phase,
            "run phase $(state.phase) cannot transition to $target"))
    return nothing
end

@inline function _checked_lifecycle_elapsed_ns(
    earlier_ns::Int64,
    later_ns::Int64,
    component::Symbol,
    reason::Symbol,
    message::String)
    elapsed_bits =
        reinterpret(UInt64, later_ns) - reinterpret(UInt64, earlier_ns)
    elapsed_ns = reinterpret(Int64, elapsed_bits)
    elapsed_ns >= 0 ||
        throw(RunLifecycleError(component, reason, message))
    return elapsed_ns
end

function _begin_arm!(
    state::RunLifecycleState,
    parameters::RunLifecycleParameters,
    execution_clock::ExecutionClockID,
    opened_execution_ns::Int64)
    _require_session(state, parameters.session, :run_arm)
    _require_transition(state, RunArming, :run_arm)
    window = ArmWindow(
        parameters, execution_clock, opened_execution_ns)
    state.arm_window = window
    state.phase = RunArming
    return window
end

@noinline function _record_arm_failure!(
    state::RunLifecycleState,
    kind::RunTerminationKind,
    observed_execution_ns::Int64,
    reason::Symbol,
    message::String)
    _require_transition(state, RunFailed, :run_arm)
    state.termination = RunTermination(
        kind,
        state.session,
        state.arm_window.execution_clock,
        observed_execution_ns,
        nothing,
        :run_arm,
        reason,
        _LIFECYCLE_CONSTRUCTION_TOKEN)
    state.phase = RunFailed
    throw(RunLifecycleError(:run_arm, reason, message))
end

function _validate_arm_readiness!(
    state::RunLifecycleState,
    window::ArmWindow,
    readiness::AdapterReadinessSnapshot,
    current_execution_ns::Int64)
    _require_phase(state, RunArming, :run_arm)
    _require_session(state, window.session, :run_arm)
    _require_session(state, readiness.session, :run_arm)
    state.arm_window == window || throw(RunLifecycleError(
        :run_arm,
        :stale_arm_window,
        "arm attempt does not match the active arm window"))
    readiness.execution_clock == window.execution_clock ||
        throw(RunLifecycleError(
            :run_arm,
            :clock_identity_mismatch,
            "adapter readiness uses another execution-clock identity"))
    current_elapsed_ns = _checked_lifecycle_elapsed_ns(
        window.opened_execution_ns,
        current_execution_ns,
        :run_arm,
        :execution_clock_regressed,
        "execution clock regressed during the arm attempt or the arm interval reached 2^63 nanoseconds")
    readiness_elapsed_ns = _checked_lifecycle_elapsed_ns(
        window.opened_execution_ns,
        readiness.observed_execution_ns,
        :run_arm,
        :readiness_before_arm,
        "adapter readiness predates the arm attempt or is separated from it by at least 2^63 nanoseconds")
    readiness_elapsed_ns <= current_elapsed_ns ||
        throw(RunLifecycleError(
            :run_arm,
            :readiness_from_future,
            "adapter readiness cannot be observed after the current execution-clock reading"))
    timeout_ns = _arm_timeout_ns(window)
    if current_elapsed_ns > timeout_ns ||
        readiness_elapsed_ns > timeout_ns
        _record_arm_failure!(
            state,
            ArmDeadlineExpired,
            current_execution_ns,
            :arm_deadline_expired,
            "adapter readiness was not validated by the inclusive arm deadline")
    end
    readiness.status == AdapterNotReady && throw(RunLifecycleError(
        :run_arm,
        :adapter_not_ready,
        "the RTC adapter has not reported ready"))
    readiness.status == AdapterFailed && _record_arm_failure!(
        state,
        AdapterReadinessFailed,
        readiness.observed_execution_ns,
        :adapter_failed,
        "the RTC adapter reported failure while arming")
    return nothing
end

function _complete_arm!(
    state::RunLifecycleState,
    window::ArmWindow,
    readiness::AdapterReadinessSnapshot,
    armed_execution_ns::Int64)
    _validate_arm_readiness!(
        state, window, readiness, armed_execution_ns)
    _require_transition(state, RunArmed, :run_arm)
    state.execution_clock = window.execution_clock
    state.armed_execution_ns = armed_execution_ns
    state.readiness = readiness
    state.phase = RunArmed
    return state
end

function _start_run!(state::RunLifecycleState)
    _require_transition(state, RunRunning, :run_start)
    state.phase = RunRunning
    return state
end

@inline function _require_active_observation(
    state::RunLifecycleState,
    observed_execution_ns::Int64,
    current_execution_ns::Int64,
    component::Symbol)
    armed_execution_ns = state.armed_execution_ns
    armed_execution_ns === nothing && throw(RunLifecycleError(
        component,
        :missing_arm_timestamp,
        "active lifecycle state has no arm-completion timestamp"))
    current_elapsed_ns = _checked_lifecycle_elapsed_ns(
        armed_execution_ns,
        current_execution_ns,
        component,
        :execution_clock_regressed,
        "execution clock regressed after arm or the active interval reached 2^63 nanoseconds")
    observed_elapsed_ns = _checked_lifecycle_elapsed_ns(
        armed_execution_ns,
        observed_execution_ns,
        component,
        :event_before_arm,
        "lifecycle event predates arm completion or is separated from it by at least 2^63 nanoseconds")
    observed_elapsed_ns <= current_elapsed_ns ||
        throw(RunLifecycleError(
            component,
            :event_from_future,
            "lifecycle event cannot be observed after the current execution-clock reading"))
    return nothing
end

@inline function _require_execution_clock(
    state::RunLifecycleState,
    execution_clock::ExecutionClockID,
    component::Symbol)
    execution_clock == state.execution_clock ||
        throw(RunLifecycleError(
            component,
            :clock_identity_mismatch,
            "lifecycle event uses another execution-clock identity"))
    return nothing
end

function _validate_stop_event(
    state::RunLifecycleState,
    event::RunStopRequest,
    current_execution_ns::Int64)
    _require_session(state, event.session, :run_stop)
    _require_transition(state, RunStopped, :run_stop)
    _require_execution_clock(
        state, event.execution_clock, :run_stop)
    _require_active_observation(
        state,
        event.requested_execution_ns, current_execution_ns, :run_stop)
    return nothing
end

function _record_stop!(
    state::RunLifecycleState,
    event::RunStopRequest)
    termination = RunTermination(
        RequestedRunStop,
        state.session,
        event.execution_clock,
        event.requested_execution_ns,
        nothing,
        :run_stop,
        event.reason,
        _LIFECYCLE_CONSTRUCTION_TOKEN)
    state.termination = termination
    state.phase = RunStopped
    return termination
end

function _validate_stop_event(
    state::RunLifecycleState,
    event::RunTerminalEvent,
    current_execution_ns::Int64)
    _require_session(state, event.session, :run_stop)
    _require_phase(state, RunRunning, :run_stop)
    _require_transition(state, RunStopped, :run_stop)
    _require_execution_clock(
        state, event.execution_clock, :run_stop)
    _require_active_observation(
        state,
        event.observed_execution_ns, current_execution_ns, :run_stop)
    return nothing
end

function _record_stop!(
    state::RunLifecycleState,
    event::RunTerminalEvent)
    termination = RunTermination(
        ConfiguredTerminalStop,
        state.session,
        event.execution_clock,
        event.observed_execution_ns,
        event.plant_timestamp,
        :run_stop,
        event.reason,
        _LIFECYCLE_CONSTRUCTION_TOKEN)
    state.termination = termination
    state.phase = RunStopped
    return termination
end

function _stop_run!(
    state::RunLifecycleState,
    event::Union{RunStopRequest,RunTerminalEvent},
    current_execution_ns::Int64)
    _validate_stop_event(state, event, current_execution_ns)
    return _record_stop!(state, event)
end

function _fail_run!(
    state::RunLifecycleState,
    event::RunFailureEvent)
    _require_session(state, event.session, :run_failure)
    _require_transition(state, RunFailed, :run_failure)
    _require_execution_clock(
        state, event.execution_clock, :run_failure)
    armed_execution_ns = state.armed_execution_ns
    armed_execution_ns === nothing && throw(RunLifecycleError(
        :run_failure,
        :missing_arm_timestamp,
        "active lifecycle state has no arm-completion timestamp"))
    event.observed_execution_ns === nothing ||
        _checked_lifecycle_elapsed_ns(
            armed_execution_ns,
            event.observed_execution_ns,
            :run_failure,
            :event_before_arm,
            "failure observation predates arm completion or is separated from it by at least 2^63 nanoseconds")
    termination = RunTermination(
        RuntimeRunFailure,
        state.session,
        event.execution_clock,
        event.observed_execution_ns,
        nothing,
        event.component,
        event.reason,
        _LIFECYCLE_CONSTRUCTION_TOKEN)
    state.termination = termination
    state.phase = RunFailed
    return termination
end

public RunLifecycleParameters, RunLifecycleState, arm_timeout_ns
public run_transition_is_valid
public RunFailureEvent
public failure_event_execution_ns, failure_event_component
public failure_event_reason

end
