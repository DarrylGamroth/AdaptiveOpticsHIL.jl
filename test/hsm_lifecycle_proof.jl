using Hsm
using InteractiveUtils: code_lowered
using AdaptiveOpticsSim.Plant: PlantTimestamp

module HsmLifecycleProof

using Hsm

import AdaptiveOpticsHIL.Lifecycle
import AdaptiveOpticsHIL.Timing: ExecutionClockID

const _LIFECYCLE_TOKEN = Lifecycle._LIFECYCLE_CONSTRUCTION_TOKEN

"""
Test-only Hsm representation of `RunLifecycleState`.

The active Hsm state is the only phase representation. The remaining fields
are the existing typed lifecycle payload and do not duplicate the phase.
"""
@hsmdef mutable struct ProbeLifecycleState
    const session::Lifecycle.RunSessionID
    arm_window::Union{Nothing,Lifecycle.ArmWindow}
    execution_clock::Union{Nothing,ExecutionClockID}
    armed_execution_ns::Union{Nothing,Int64}
    readiness::Union{Nothing,Lifecycle.AdapterReadinessSnapshot}
    termination::Union{Nothing,Lifecycle.RunTermination}
end

@statedef ProbeLifecycleState :Prepared
@statedef ProbeLifecycleState :Active
@statedef ProbeLifecycleState :Arming :Active
@statedef ProbeLifecycleState :Armed :Active
@statedef ProbeLifecycleState :Running :Active
@statedef ProbeLifecycleState :Stopped
@statedef ProbeLifecycleState :Failed

struct CompleteArmInput
    window::Lifecycle.ArmWindow
    readiness::Lifecycle.AdapterReadinessSnapshot
    armed_execution_ns::Int64
end

struct RequestedStopInput
    event::Lifecycle.RunStopRequest
    current_execution_ns::Int64
end

struct TerminalStopInput
    event::Lifecycle.RunTerminalEvent
    current_execution_ns::Int64
end

@on_initial function (state::ProbeLifecycleState, ::Root)
    return Hsm.transition!(state, :Prepared)
end

@on_event function (
    state::ProbeLifecycleState,
    ::Prepared,
    ::BeginArm,
    window::Lifecycle.ArmWindow,
)
    return Hsm.transition!(state, :Arming) do
        state.arm_window = window
    end
end

@on_event function (
    state::ProbeLifecycleState,
    ::Arming,
    ::CompleteArm,
    input::CompleteArmInput,
)
    return Hsm.transition!(state, :Armed) do
        state.execution_clock = input.window.execution_clock
        state.armed_execution_ns = input.armed_execution_ns
        state.readiness = input.readiness
    end
end

@on_event function (
    state::ProbeLifecycleState,
    ::Arming,
    ::ArmFailure,
    termination::Lifecycle.RunTermination,
)
    return Hsm.transition!(state, :Failed) do
        state.termination = termination
    end
end

@on_event function (
    state::ProbeLifecycleState,
    ::Armed,
    ::StartRun,
    _,
)
    return Hsm.transition!(state, :Running)
end

@on_event function (
    state::ProbeLifecycleState,
    ::Armed,
    ::RequestedStop,
    input::RequestedStopInput,
)
    _validate_active_observation(
        state,
        input.event.requested_execution_ns,
        input.current_execution_ns,
        :run_stop)
    _require_execution_clock(
        state, input.event.execution_clock, :run_stop)
    termination = _requested_stop_termination(state, input.event)
    return Hsm.transition!(state, :Stopped) do
        state.termination = termination
    end
end

@on_event function (
    state::ProbeLifecycleState,
    ::Running,
    ::RequestedStop,
    input::RequestedStopInput,
)
    _validate_active_observation(
        state,
        input.event.requested_execution_ns,
        input.current_execution_ns,
        :run_stop)
    _require_execution_clock(
        state, input.event.execution_clock, :run_stop)
    termination = _requested_stop_termination(state, input.event)
    return Hsm.transition!(state, :Stopped) do
        state.termination = termination
    end
end

@on_event function (
    state::ProbeLifecycleState,
    ::Running,
    ::TerminalStop,
    input::TerminalStopInput,
)
    _require_execution_clock(
        state, input.event.execution_clock, :run_stop)
    _validate_active_observation(
        state,
        input.event.observed_execution_ns,
        input.current_execution_ns,
        :run_stop)
    termination = _terminal_stop_termination(state, input.event)
    return Hsm.transition!(state, :Stopped) do
        state.termination = termination
    end
end

@on_event function (
    state::ProbeLifecycleState,
    ::Active,
    ::FailRun,
    event::Lifecycle.RunFailureEvent,
)
    _require_execution_clock(state, event.execution_clock, :run_failure)
    armed_execution_ns = state.armed_execution_ns
    armed_execution_ns === nothing && throw(Lifecycle.RunLifecycleError(
        :run_failure,
        :missing_arm_timestamp,
        "active lifecycle state has no arm-completion timestamp"))
    event.observed_execution_ns === nothing ||
        Lifecycle._checked_lifecycle_elapsed_ns(
            armed_execution_ns,
            event.observed_execution_ns,
            :run_failure,
            :event_before_arm,
            "failure observation predates arm completion or is separated from it by at least 2^63 nanoseconds")
    termination = _failure_termination(state, event)
    return Hsm.transition!(state, :Failed) do
        state.termination = termination
    end
end

function ProbeLifecycleState(
    parameters::Lifecycle.RunLifecycleParameters)
    state = ProbeLifecycleState(
        parameters.session,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        UInt8(0),
        UInt8(0),
        nothing,
        :Root,
        :Root)
    Hsm._initialize_machine!(state)
    return state
end

@inline function run_phase(state::ProbeLifecycleState)
    current = Hsm.current(state)
    current === :Prepared && return Lifecycle.RunPrepared
    current === :Arming && return Lifecycle.RunArming
    current === :Armed && return Lifecycle.RunArmed
    current === :Running && return Lifecycle.RunRunning
    current === :Stopped && return Lifecycle.RunStopped
    current === :Failed && return Lifecycle.RunFailed
    throw(Lifecycle.RunLifecycleError(
        :run_lifecycle,
        :invalid_phase,
        "Hsm lifecycle has no canonical phase for $current"))
end

run_session(state::ProbeLifecycleState) = state.session
run_arm_window(state::ProbeLifecycleState) = state.arm_window
run_execution_clock_identity(state::ProbeLifecycleState) =
    state.execution_clock
run_armed_execution_ns(state::ProbeLifecycleState) =
    state.armed_execution_ns
run_adapter_readiness(state::ProbeLifecycleState) = state.readiness
run_termination(state::ProbeLifecycleState) = state.termination

@noinline function _invalid_phase(
    state::ProbeLifecycleState,
    component::Symbol)
    throw(Lifecycle.RunLifecycleError(
        component,
        :invalid_phase,
        "run phase $(run_phase(state)) does not permit this transition"))
end

@inline function _require_handled(
    result::Hsm.EventReturn,
    state::ProbeLifecycleState,
    component::Symbol)
    result === Hsm.EventHandled || _invalid_phase(state, component)
    return nothing
end

@inline function _require_session(
    state::ProbeLifecycleState,
    session::Lifecycle.RunSessionID,
    component::Symbol)
    session == state.session || throw(Lifecycle.RunLifecycleError(
        component,
        :stale_session,
        "lifecycle event belongs to another run/session"))
    return nothing
end

@inline function _require_phase(
    state::ProbeLifecycleState,
    expected::Lifecycle.RunPhase,
    component::Symbol)
    run_phase(state) == expected || throw(Lifecycle.RunLifecycleError(
        component,
        :invalid_phase,
        "run phase $(run_phase(state)) does not permit this transition"))
    return nothing
end

@inline function _require_execution_clock(
    state::ProbeLifecycleState,
    execution_clock::ExecutionClockID,
    component::Symbol)
    execution_clock == state.execution_clock ||
        throw(Lifecycle.RunLifecycleError(
            component,
            :clock_identity_mismatch,
            "lifecycle event uses another execution-clock identity"))
    return nothing
end

function begin_arm!(
    state::ProbeLifecycleState,
    parameters::Lifecycle.RunLifecycleParameters,
    execution_clock::ExecutionClockID,
    opened_execution_ns::Int64)
    _require_session(state, parameters.session, :run_arm)
    result = Hsm.dispatch!(
        state,
        :BeginArm,
        Lifecycle.ArmWindow(
            parameters, execution_clock, opened_execution_ns))
    _require_handled(result, state, :run_arm)
    return state.arm_window::Lifecycle.ArmWindow
end

@noinline function _record_arm_failure!(
    state::ProbeLifecycleState,
    kind::Lifecycle.RunTerminationKind,
    observed_execution_ns::Int64,
    reason::Symbol,
    message::String)
    window = state.arm_window::Lifecycle.ArmWindow
    termination = Lifecycle.RunTermination(
        kind,
        state.session,
        window.execution_clock,
        observed_execution_ns,
        nothing,
        :run_arm,
        reason,
        _LIFECYCLE_TOKEN)
    result = Hsm.dispatch!(state, :ArmFailure, termination)
    _require_handled(result, state, :run_arm)
    throw(Lifecycle.RunLifecycleError(:run_arm, reason, message))
end

function validate_arm_readiness!(
    state::ProbeLifecycleState,
    window::Lifecycle.ArmWindow,
    readiness::Lifecycle.AdapterReadinessSnapshot,
    current_execution_ns::Int64)
    _require_phase(state, Lifecycle.RunArming, :run_arm)
    _require_session(state, window.session, :run_arm)
    _require_session(state, readiness.session, :run_arm)
    state.arm_window == window || throw(Lifecycle.RunLifecycleError(
        :run_arm,
        :stale_arm_window,
        "arm attempt does not match the active arm window"))
    readiness.execution_clock == window.execution_clock ||
        throw(Lifecycle.RunLifecycleError(
            :run_arm,
            :clock_identity_mismatch,
            "adapter readiness uses another execution-clock identity"))
    current_elapsed_ns = Lifecycle._checked_lifecycle_elapsed_ns(
        window.opened_execution_ns,
        current_execution_ns,
        :run_arm,
        :execution_clock_regressed,
        "execution clock regressed during the arm attempt or the arm interval reached 2^63 nanoseconds")
    readiness_elapsed_ns = Lifecycle._checked_lifecycle_elapsed_ns(
        window.opened_execution_ns,
        readiness.observed_execution_ns,
        :run_arm,
        :readiness_before_arm,
        "adapter readiness predates the arm attempt or is separated from it by at least 2^63 nanoseconds")
    readiness_elapsed_ns <= current_elapsed_ns ||
        throw(Lifecycle.RunLifecycleError(
            :run_arm,
            :readiness_from_future,
            "adapter readiness cannot be observed after the current execution-clock reading"))
    timeout_ns = Lifecycle._arm_timeout_ns(window)
    if current_elapsed_ns > timeout_ns ||
        readiness_elapsed_ns > timeout_ns
        _record_arm_failure!(
            state,
            Lifecycle.ArmDeadlineExpired,
            current_execution_ns,
            :arm_deadline_expired,
            "adapter readiness was not validated by the inclusive arm deadline")
    end
    readiness.status == Lifecycle.AdapterNotReady &&
        throw(Lifecycle.RunLifecycleError(
            :run_arm,
            :adapter_not_ready,
            "the RTC adapter has not reported ready"))
    readiness.status == Lifecycle.AdapterFailed &&
        _record_arm_failure!(
            state,
            Lifecycle.AdapterReadinessFailed,
            readiness.observed_execution_ns,
            :adapter_failed,
            "the RTC adapter reported failure while arming")
    return nothing
end

function complete_arm!(
    state::ProbeLifecycleState,
    window::Lifecycle.ArmWindow,
    readiness::Lifecycle.AdapterReadinessSnapshot,
    armed_execution_ns::Int64)
    validate_arm_readiness!(
        state, window, readiness, armed_execution_ns)
    result = Hsm.dispatch!(
        state,
        :CompleteArm,
        CompleteArmInput(window, readiness, armed_execution_ns))
    _require_handled(result, state, :run_arm)
    return state
end

function start_run!(state::ProbeLifecycleState)
    result = Hsm.dispatch!(state, :StartRun, nothing)
    _require_handled(result, state, :run_start)
    return state
end

@inline function _validate_active_observation(
    state::ProbeLifecycleState,
    observed_execution_ns::Int64,
    current_execution_ns::Int64,
    component::Symbol)
    armed_execution_ns = state.armed_execution_ns
    armed_execution_ns === nothing && throw(Lifecycle.RunLifecycleError(
        component,
        :missing_arm_timestamp,
        "active lifecycle state has no arm-completion timestamp"))
    current_elapsed_ns = Lifecycle._checked_lifecycle_elapsed_ns(
        armed_execution_ns,
        current_execution_ns,
        component,
        :execution_clock_regressed,
        "execution clock regressed after arm or the active interval reached 2^63 nanoseconds")
    observed_elapsed_ns = Lifecycle._checked_lifecycle_elapsed_ns(
        armed_execution_ns,
        observed_execution_ns,
        component,
        :event_before_arm,
        "lifecycle event predates arm completion or is separated from it by at least 2^63 nanoseconds")
    observed_elapsed_ns <= current_elapsed_ns ||
        throw(Lifecycle.RunLifecycleError(
            component,
            :event_from_future,
            "lifecycle event cannot be observed after the current execution-clock reading"))
    return nothing
end

function _requested_stop_termination(
    state::ProbeLifecycleState,
    event::Lifecycle.RunStopRequest)
    return Lifecycle.RunTermination(
        Lifecycle.RequestedRunStop,
        state.session,
        event.execution_clock,
        event.requested_execution_ns,
        nothing,
        :run_stop,
        event.reason,
        _LIFECYCLE_TOKEN)
end

function _terminal_stop_termination(
    state::ProbeLifecycleState,
    event::Lifecycle.RunTerminalEvent)
    return Lifecycle.RunTermination(
        Lifecycle.ConfiguredTerminalStop,
        state.session,
        event.execution_clock,
        event.observed_execution_ns,
        event.plant_timestamp,
        :run_stop,
        event.reason,
        _LIFECYCLE_TOKEN)
end

function stop_run!(
    state::ProbeLifecycleState,
    event::Lifecycle.RunStopRequest,
    current_execution_ns::Int64)
    _require_session(state, event.session, :run_stop)
    result = Hsm.dispatch!(
        state,
        :RequestedStop,
        RequestedStopInput(event, current_execution_ns))
    _require_handled(result, state, :run_stop)
    return state.termination::Lifecycle.RunTermination
end

function stop_run!(
    state::ProbeLifecycleState,
    event::Lifecycle.RunTerminalEvent,
    current_execution_ns::Int64)
    _require_session(state, event.session, :run_stop)
    result = Hsm.dispatch!(
        state,
        :TerminalStop,
        TerminalStopInput(event, current_execution_ns))
    _require_handled(result, state, :run_stop)
    return state.termination::Lifecycle.RunTermination
end

function _failure_termination(
    state::ProbeLifecycleState,
    event::Lifecycle.RunFailureEvent)
    return Lifecycle.RunTermination(
        event.kind,
        state.session,
        event.execution_clock,
        event.observed_execution_ns,
        nothing,
        event.component,
        event.reason,
        _LIFECYCLE_TOKEN)
end

function fail_run!(
    state::ProbeLifecycleState,
    event::Lifecycle.RunFailureEvent)
    _require_session(state, event.session, :run_failure)
    result = Hsm.dispatch!(state, :FailRun, event)
    _require_handled(result, state, :run_failure)
    return state.termination::Lifecycle.RunTermination
end

end

using .HsmLifecycleProof

const HSM_PROOF_CLOCK =
    AdaptiveOpticsHIL.Timing.ExecutionClockID(:hsm_proof_clock)
const HSM_PROOF_OTHER_CLOCK =
    AdaptiveOpticsHIL.Timing.ExecutionClockID(:hsm_proof_other_clock)
const HSM_PROOF_TESTS_WITH_COVERAGE =
    Base.JLOptions().code_coverage != 0

struct HsmProofSnapshot
    session::AdaptiveOpticsHIL.Lifecycle.RunSessionID
    phase::AdaptiveOpticsHIL.Lifecycle.RunPhase
    arm_window::Union{Nothing,AdaptiveOpticsHIL.Lifecycle.ArmWindow}
    clock::Union{
        Nothing,
        AdaptiveOpticsHIL.Timing.ExecutionClockID,
    }
    armed_execution_ns::Union{Nothing,Int64}
    readiness::Union{
        Nothing,
        AdaptiveOpticsHIL.Lifecycle.AdapterReadinessSnapshot,
    }
    termination::Union{
        Nothing,
        AdaptiveOpticsHIL.Lifecycle.RunTermination,
    }
end

Base.:(==)(left::HsmProofSnapshot, right::HsmProofSnapshot) =
    isequal(left.session, right.session) &&
    left.phase == right.phase &&
    isequal(left.arm_window, right.arm_window) &&
    isequal(left.clock, right.clock) &&
    isequal(left.armed_execution_ns, right.armed_execution_ns) &&
    isequal(left.readiness, right.readiness) &&
    isequal(left.termination, right.termination)

function hsm_proof_capture(f)
    try
        f()
    catch error
        return error::AdaptiveOpticsHIL.Lifecycle.RunLifecycleError
    end
    return nothing
end

function hsm_proof_parameters(
    session::Integer;
    timeout_ns::Integer=10)
    return AdaptiveOpticsHIL.Lifecycle.RunLifecycleParameters(
        AdaptiveOpticsHIL.Lifecycle.RunSessionID(session);
        arm_timeout_ns=timeout_ns)
end

function hsm_proof_termination_snapshot(::Nothing)
    return nothing
end

function hsm_proof_termination_snapshot(
    termination::AdaptiveOpticsHIL.Lifecycle.RunTermination)
    return (
        kind=AdaptiveOpticsHIL.Lifecycle.
            run_termination_kind(termination),
        session=AdaptiveOpticsHIL.Lifecycle.run_session(termination),
        clock=AdaptiveOpticsHIL.Lifecycle.
            run_execution_clock_identity(termination),
        execution_ns=AdaptiveOpticsHIL.Lifecycle.
            run_termination_execution_ns(termination),
        plant_timestamp=AdaptiveOpticsHIL.Lifecycle.
            run_termination_plant_timestamp(termination),
        component=AdaptiveOpticsHIL.Lifecycle.
            run_termination_component(termination),
        reason=AdaptiveOpticsHIL.Lifecycle.
            run_termination_reason(termination),
    )
end

function hsm_proof_snapshot(
    state::AdaptiveOpticsHIL.Lifecycle.RunLifecycleState)
    lifecycle = AdaptiveOpticsHIL.Lifecycle
    return HsmProofSnapshot(
        lifecycle.run_session(state),
        lifecycle.run_phase(state),
        lifecycle.run_arm_window(state),
        lifecycle.run_execution_clock_identity(state),
        lifecycle.run_armed_execution_ns(state),
        lifecycle.run_adapter_readiness(state),
        lifecycle.run_termination(state),
    )
end

function hsm_proof_snapshot(
    state::HsmLifecycleProof.ProbeLifecycleState)
    return HsmProofSnapshot(
        HsmLifecycleProof.run_session(state),
        HsmLifecycleProof.run_phase(state),
        HsmLifecycleProof.run_arm_window(state),
        HsmLifecycleProof.run_execution_clock_identity(state),
        HsmLifecycleProof.run_armed_execution_ns(state),
        HsmLifecycleProof.run_adapter_readiness(state),
        HsmLifecycleProof.run_termination(state),
    )
end

function hsm_proof_error_snapshot(::Nothing)
    return nothing
end

function hsm_proof_error_snapshot(
    error::AdaptiveOpticsHIL.Lifecycle.RunLifecycleError)
    return (
        type=typeof(error),
        component=error.component,
        reason=error.reason,
        message=error.msg,
    )
end

function hsm_proof_armed_pair(session::Integer)
    lifecycle = AdaptiveOpticsHIL.Lifecycle
    parameters = hsm_proof_parameters(session)
    oracle = lifecycle.RunLifecycleState(parameters)
    probe = HsmLifecycleProof.ProbeLifecycleState(parameters)
    oracle_window = lifecycle._begin_arm!(
        oracle, parameters, HSM_PROOF_CLOCK, Int64(100))
    probe_window = HsmLifecycleProof.begin_arm!(
        probe, parameters, HSM_PROOF_CLOCK, Int64(100))
    readiness = lifecycle.AdapterReadinessSnapshot(
        parameters.session,
        HSM_PROOF_CLOCK,
        lifecycle.AdapterReady,
        100)
    lifecycle._complete_arm!(
        oracle, oracle_window, readiness, Int64(100))
    HsmLifecycleProof.complete_arm!(
        probe, probe_window, readiness, Int64(100))
    return oracle, probe
end

@inline function hsm_proof_start_allocations!(
    state::HsmLifecycleProof.ProbeLifecycleState)
    return @allocated HsmLifecycleProof.start_run!(state)
end

@inline function hsm_proof_begin_arm_allocations!(
    state::HsmLifecycleProof.ProbeLifecycleState,
    parameters::AdaptiveOpticsHIL.Lifecycle.RunLifecycleParameters)
    return @allocated HsmLifecycleProof.begin_arm!(
        state, parameters, HSM_PROOF_CLOCK, Int64(100))
end

@inline function hsm_proof_oracle_begin_arm_allocations!(
    state::AdaptiveOpticsHIL.Lifecycle.RunLifecycleState,
    parameters::AdaptiveOpticsHIL.Lifecycle.RunLifecycleParameters)
    return @allocated AdaptiveOpticsHIL.Lifecycle._begin_arm!(
        state, parameters, HSM_PROOF_CLOCK, Int64(100))
end

function hsm_proof_has_core_box(f, types)
    return any(
        occursin("Core.Box", sprint(show, code))
        for code in code_lowered(f, types))
end

@testset "Hsm lifecycle proof of fit" begin
    lifecycle = AdaptiveOpticsHIL.Lifecycle

    @testset "Static graph matches the canonical phase matrix" begin
        model = Hsm.diagram_model(
            HsmLifecycleProof.ProbeLifecycleState)
        event_edges = Set(
            (transition.source, transition.target, transition.trigger)
            for transition in model.transitions
            if transition.trigger_kind === :event)
        @test event_edges == Set((
            (:Prepared, :Arming, :BeginArm),
            (:Arming, :Armed, :CompleteArm),
            (:Arming, :Failed, :ArmFailure),
            (:Armed, :Running, :StartRun),
            (:Armed, :Stopped, :RequestedStop),
            (:Running, :Stopped, :RequestedStop),
            (:Running, :Stopped, :TerminalStop),
            (:Active, :Failed, :FailRun),
        ))
        initial_edges = filter(
            transition -> transition.trigger_kind === :initial,
            model.transitions)
        @test length(initial_edges) == 1
        @test only(initial_edges).target === :Prepared

        hsm_phase_edges = Set((
            (lifecycle.RunConfigured, lifecycle.RunPrepared),
            (lifecycle.RunPrepared, lifecycle.RunArming),
            (lifecycle.RunArming, lifecycle.RunArmed),
            (lifecycle.RunArming, lifecycle.RunFailed),
            (lifecycle.RunArmed, lifecycle.RunRunning),
            (lifecycle.RunArmed, lifecycle.RunStopped),
            (lifecycle.RunArmed, lifecycle.RunFailed),
            (lifecycle.RunRunning, lifecycle.RunStopped),
            (lifecycle.RunRunning, lifecycle.RunFailed),
        ))
        for from in instances(lifecycle.RunPhase)
            for to in instances(lifecycle.RunPhase)
                @test lifecycle.run_transition_is_valid(from, to) ==
                    ((from, to) in hsm_phase_edges)
            end
        end
    end

    @testset "Single phase authority and exact happy trace" begin
        parameters = hsm_proof_parameters(1)
        oracle = lifecycle.RunLifecycleState(parameters)
        probe = HsmLifecycleProof.ProbeLifecycleState(parameters)
        @test isconst(
            HsmLifecycleProof.ProbeLifecycleState, :session)
        @test :phase ∉ fieldnames(
            HsmLifecycleProof.ProbeLifecycleState)
        @test Hsm.current(probe) === :Prepared
        @test !applicable(
            HsmLifecycleProof.ProbeLifecycleState,
            parameters.session,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing)

        oracle_trace = HsmProofSnapshot[hsm_proof_snapshot(oracle)]
        probe_trace = HsmProofSnapshot[hsm_proof_snapshot(probe)]
        @test eltype(oracle_trace) === HsmProofSnapshot
        @test eltype(probe_trace) === HsmProofSnapshot

        oracle_window = lifecycle._begin_arm!(
            oracle, parameters, HSM_PROOF_CLOCK, Int64(100))
        probe_window = HsmLifecycleProof.begin_arm!(
            probe, parameters, HSM_PROOF_CLOCK, Int64(100))
        push!(oracle_trace, hsm_proof_snapshot(oracle))
        push!(probe_trace, hsm_proof_snapshot(probe))

        readiness = lifecycle.AdapterReadinessSnapshot(
            parameters.session,
            HSM_PROOF_CLOCK,
            lifecycle.AdapterReady,
            110)
        lifecycle._complete_arm!(
            oracle, oracle_window, readiness, Int64(110))
        HsmLifecycleProof.complete_arm!(
            probe, probe_window, readiness, Int64(110))
        push!(oracle_trace, hsm_proof_snapshot(oracle))
        push!(probe_trace, hsm_proof_snapshot(probe))

        lifecycle._start_run!(oracle)
        HsmLifecycleProof.start_run!(probe)
        push!(oracle_trace, hsm_proof_snapshot(oracle))
        push!(probe_trace, hsm_proof_snapshot(probe))

        request = lifecycle.RunStopRequest(
            parameters.session,
            HSM_PROOF_CLOCK,
            110;
            reason=:proof_complete)
        lifecycle._stop_run!(oracle, request, Int64(110))
        HsmLifecycleProof.stop_run!(probe, request, Int64(110))
        push!(oracle_trace, hsm_proof_snapshot(oracle))
        push!(probe_trace, hsm_proof_snapshot(probe))

        @test probe_trace == oracle_trace
        @test [snapshot.phase for snapshot in probe_trace] == [
            lifecycle.RunPrepared,
            lifecycle.RunArming,
            lifecycle.RunArmed,
            lifecycle.RunRunning,
            lifecycle.RunStopped,
        ]
    end

    @testset "Arm deadline and adapter-failure traces" begin
        for (
            session,
            status,
            current_execution_ns,
            expected_reason,
        ) in (
            (2, lifecycle.AdapterNotReady, 106, :arm_deadline_expired),
            (3, lifecycle.AdapterFailed, 101, :adapter_failed),
        )
            parameters = hsm_proof_parameters(session; timeout_ns=5)
            oracle = lifecycle.RunLifecycleState(parameters)
            probe = HsmLifecycleProof.ProbeLifecycleState(parameters)
            oracle_window = lifecycle._begin_arm!(
                oracle, parameters, HSM_PROOF_CLOCK, Int64(100))
            probe_window = HsmLifecycleProof.begin_arm!(
                probe, parameters, HSM_PROOF_CLOCK, Int64(100))
            readiness = lifecycle.AdapterReadinessSnapshot(
                parameters.session,
                HSM_PROOF_CLOCK,
                status,
                status === lifecycle.AdapterFailed ? 101 : 100)
            oracle_error = hsm_proof_capture() do
                lifecycle._validate_arm_readiness!(
                    oracle,
                    oracle_window,
                    readiness,
                    Int64(current_execution_ns))
            end
            probe_error = hsm_proof_capture() do
                HsmLifecycleProof.validate_arm_readiness!(
                    probe,
                    probe_window,
                    readiness,
                    Int64(current_execution_ns))
            end
            @test hsm_proof_error_snapshot(probe_error) ==
                hsm_proof_error_snapshot(oracle_error)
            @test probe_error.reason == expected_reason
            @test hsm_proof_snapshot(probe) ==
                hsm_proof_snapshot(oracle)
        end
    end

    @testset "Invalid readiness and transition rejection" begin
        parameters = hsm_proof_parameters(4)
        oracle = lifecycle.RunLifecycleState(parameters)
        probe = HsmLifecycleProof.ProbeLifecycleState(parameters)
        oracle_window = lifecycle._begin_arm!(
            oracle, parameters, HSM_PROOF_CLOCK, Int64(100))
        probe_window = HsmLifecycleProof.begin_arm!(
            probe, parameters, HSM_PROOF_CLOCK, Int64(100))

        invalid_readiness = (
            lifecycle.AdapterReadinessSnapshot(
                lifecycle.RunSessionID(404),
                HSM_PROOF_CLOCK,
                lifecycle.AdapterReady,
                100),
            lifecycle.AdapterReadinessSnapshot(
                parameters.session,
                HSM_PROOF_OTHER_CLOCK,
                lifecycle.AdapterReady,
                100),
            lifecycle.AdapterReadinessSnapshot(
                parameters.session,
                HSM_PROOF_CLOCK,
                lifecycle.AdapterReady,
                101),
            lifecycle.AdapterReadinessSnapshot(
                parameters.session,
                HSM_PROOF_CLOCK,
                lifecycle.AdapterReady,
                99),
            lifecycle.AdapterReadinessSnapshot(
                parameters.session,
                HSM_PROOF_CLOCK,
                lifecycle.AdapterNotReady,
                100),
        )
        for readiness in invalid_readiness
            oracle_error = hsm_proof_capture() do
                lifecycle._validate_arm_readiness!(
                    oracle, oracle_window, readiness, Int64(100))
            end
            probe_error = hsm_proof_capture() do
                HsmLifecycleProof.validate_arm_readiness!(
                    probe, probe_window, readiness, Int64(100))
            end
            @test hsm_proof_error_snapshot(probe_error) ==
                hsm_proof_error_snapshot(oracle_error)
            @test hsm_proof_snapshot(probe) ==
                hsm_proof_snapshot(oracle)
        end

        duplicate_oracle = hsm_proof_capture() do
            lifecycle._begin_arm!(
                oracle, parameters, HSM_PROOF_CLOCK, Int64(100))
        end
        duplicate_probe = hsm_proof_capture() do
            HsmLifecycleProof.begin_arm!(
                probe, parameters, HSM_PROOF_CLOCK, Int64(100))
        end
        @test duplicate_probe.reason == duplicate_oracle.reason ==
            :invalid_phase
        @test hsm_proof_snapshot(probe) == hsm_proof_snapshot(oracle)
    end

    @testset "Armed stop, running terminal stop, and failure" begin
        armed_oracle, armed_probe = hsm_proof_armed_pair(5)
        armed_request = lifecycle.RunStopRequest(
            lifecycle.RunSessionID(5),
            HSM_PROOF_CLOCK,
            100;
            reason=:armed_stop)
        @test hsm_proof_termination_snapshot(
            HsmLifecycleProof.stop_run!(
                armed_probe, armed_request, Int64(100))) ==
            hsm_proof_termination_snapshot(
                lifecycle._stop_run!(
                    armed_oracle, armed_request, Int64(100)))
        @test hsm_proof_snapshot(armed_probe) ==
            hsm_proof_snapshot(armed_oracle)

        terminal_oracle, terminal_probe = hsm_proof_armed_pair(6)
        lifecycle._start_run!(terminal_oracle)
        HsmLifecycleProof.start_run!(terminal_probe)
        terminal = lifecycle.RunTerminalEvent(
            lifecycle.RunSessionID(6),
            HSM_PROOF_CLOCK,
            PlantTimestamp(4),
            100;
            reason=:terminal)
        lifecycle._stop_run!(terminal_oracle, terminal, Int64(100))
        HsmLifecycleProof.stop_run!(
            terminal_probe, terminal, Int64(100))
        @test hsm_proof_snapshot(terminal_probe) ==
            hsm_proof_snapshot(terminal_oracle)

        failed_oracle, failed_probe = hsm_proof_armed_pair(7)
        lifecycle._start_run!(failed_oracle)
        HsmLifecycleProof.start_run!(failed_probe)
        failure = lifecycle.RunFailureEvent(
            lifecycle.OwnerExceptionRunFailure,
            lifecycle.RunSessionID(7),
            HSM_PROOF_CLOCK,
            nothing,
            :cpu_owner,
            :injected)
        lifecycle._fail_run!(failed_oracle, failure)
        HsmLifecycleProof.fail_run!(failed_probe, failure)
        @test hsm_proof_snapshot(failed_probe) ==
            hsm_proof_snapshot(failed_oracle)

        duplicate_oracle = hsm_proof_capture() do
            lifecycle._fail_run!(failed_oracle, failure)
        end
        duplicate_probe = hsm_proof_capture() do
            HsmLifecycleProof.fail_run!(failed_probe, failure)
        end
        @test duplicate_probe.reason == duplicate_oracle.reason ==
            :invalid_phase
    end

    @testset "Inference, allocation, and lowered-code evidence" begin
        begin_parameters = hsm_proof_parameters(8)
        begin_probe =
            HsmLifecycleProof.ProbeLifecycleState(begin_parameters)
        @test @inferred(HsmLifecycleProof.run_phase(begin_probe)) ==
            lifecycle.RunPrepared
        @test @inferred(HsmLifecycleProof.begin_arm!(
            begin_probe,
            begin_parameters,
            HSM_PROOF_CLOCK,
            Int64(100))) isa lifecycle.ArmWindow
        measured_begin_parameters = hsm_proof_parameters(9)
        measured_begin_probe =
            HsmLifecycleProof.ProbeLifecycleState(
                measured_begin_parameters)
        measured_begin_oracle =
            lifecycle.RunLifecycleState(measured_begin_parameters)
        if HSM_PROOF_TESTS_WITH_COVERAGE
            @test_skip "Hsm proof allocation assertions are disabled under coverage"
        else
            @test hsm_proof_begin_arm_allocations!(
                measured_begin_probe, measured_begin_parameters) ==
                hsm_proof_oracle_begin_arm_allocations!(
                    measured_begin_oracle, measured_begin_parameters)
        end

        _, warm_start_probe = hsm_proof_armed_pair(10)
        @test @inferred(
            HsmLifecycleProof.start_run!(warm_start_probe)) ===
            warm_start_probe
        _, measured_start_probe = hsm_proof_armed_pair(11)
        if HSM_PROOF_TESTS_WITH_COVERAGE
            @test_skip "Hsm proof allocation assertions are disabled under coverage"
        else
            @test hsm_proof_start_allocations!(
                measured_start_probe) == 0
        end

        @test !hsm_proof_has_core_box(
            HsmLifecycleProof.start_run!,
            Tuple{HsmLifecycleProof.ProbeLifecycleState})
        @test !hsm_proof_has_core_box(
            HsmLifecycleProof.begin_arm!,
            Tuple{
                HsmLifecycleProof.ProbeLifecycleState,
                lifecycle.RunLifecycleParameters,
                AdaptiveOpticsHIL.Timing.ExecutionClockID,
                Int64,
            })
    end

    @testset "Failure coordination and fresh preparation remain orthogonal" begin
        session = lifecycle.RunSessionID(12)
        owners = Memory{lifecycle.RunOwnerID}(undef, 1)
        owners[1] = lifecycle.RunOwnerID(:serial_coordinator, 1)
        coordinator = lifecycle._prepare_run_failure_coordinator(
            session,
            lifecycle.RunShutdownPolicy(
                acknowledgement_timeout_ns=10,
                drain_timeout_ns=20),
            owners)
        record = lifecycle.RunFailureRecord(
            lifecycle.OwnerExceptionRunFailure,
            session,
            owners[1],
            lifecycle.CoordinatorFailureBoundary,
            100,
            :serial_coordinator,
            :injected)
        @test lifecycle._publish_run_failure!(coordinator, 1, record)
        @test lifecycle.first_run_failure(coordinator) == record
        @test lifecycle._begin_run_shutdown!(coordinator, 100) == 1
        @test lifecycle._acknowledge_run_stop!(coordinator, 1)
        @test lifecycle._run_shutdown_acknowledged(coordinator)
        @test !lifecycle._run_shutdown_drain_expired!(
            coordinator, 120)

        fresh_parameters = hsm_proof_parameters(13)
        fresh_probe =
            HsmLifecycleProof.ProbeLifecycleState(fresh_parameters)
        @test HsmLifecycleProof.run_phase(fresh_probe) ==
            lifecycle.RunPrepared
        @test HsmLifecycleProof.run_termination(fresh_probe) === nothing
    end
end
