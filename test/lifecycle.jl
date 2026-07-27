using AdaptiveOpticsHIL
using AdaptiveOpticsHIL.Lifecycle
using AdaptiveOpticsHIL.Lifecycle: RunFailureEvent
using AdaptiveOpticsHIL.Lifecycle: RunLifecycleParameters
using AdaptiveOpticsHIL.Lifecycle: RunLifecycleState
using AdaptiveOpticsHIL.Lifecycle: arm_timeout_ns
using AdaptiveOpticsHIL.Lifecycle: failure_event_component
using AdaptiveOpticsHIL.Lifecycle: failure_event_execution_ns
using AdaptiveOpticsHIL.Lifecycle: failure_event_reason
using AdaptiveOpticsHIL.Timing: ExecutionClockID
using AdaptiveOpticsSim.Plant: PlantTimestamp
using Clocks

const HIL_LIFECYCLE = AdaptiveOpticsHIL.Lifecycle
const LIFECYCLE_TEST_CLOCK =
    ExecutionClockID(:lifecycle_test_clock)
const LIFECYCLE_OTHER_CLOCK =
    ExecutionClockID(:lifecycle_other_clock)

function captured_lifecycle_error(f)
    try
        f()
    catch error
        return error
    end
    return nothing
end

function lifecycle_state(
    session_value;
    arm_timeout_ns=10)
    parameters = RunLifecycleParameters(
        RunSessionID(session_value);
        arm_timeout_ns)
    return parameters, RunLifecycleState(parameters)
end

@testset "Operational run lifecycle" begin
    @test Base.isexported(AdaptiveOpticsHIL, :Lifecycle)
    @test !Base.isexported(
        AdaptiveOpticsHIL.Lifecycle, :RunLifecycleState)
    @test Base.ispublic(
        AdaptiveOpticsHIL.Lifecycle, :RunLifecycleState)
    @test !Base.isexported(
        AdaptiveOpticsHIL.Lifecycle, :RunFailureEvent)
    @test Base.ispublic(
        AdaptiveOpticsHIL.Lifecycle, :RunFailureEvent)
    @test !Base.isexported(
        AdaptiveOpticsHIL.Lifecycle, :run_transition_is_valid)
    @test Base.ispublic(
        AdaptiveOpticsHIL.Lifecycle, :run_transition_is_valid)

    @testset "Identity, parameters, and typed events" begin
        session = RunSessionID(41)
        parameters = RunLifecycleParameters(
            session;
            arm_timeout_ns=25)
        @test isconst(RunLifecycleState, :session)
        @test run_session_value(session) == 41
        @test run_session(parameters) == session
        @test arm_timeout_ns(parameters) == 25
        @test sprint(show, session) == "RunSessionID(41)"
        @test isequal(session, RunSessionID(41))
        @test hash(session) == hash(RunSessionID(41))

        @test_throws RunLifecycleError RunSessionID(false)
        @test_throws RunLifecycleError RunSessionID(0)
        @test_throws RunLifecycleError RunSessionID(
            big(typemax(UInt64)) + 1)
        @test_throws RunLifecycleError RunLifecycleParameters(
            session; arm_timeout_ns=false)
        @test_throws RunLifecycleError RunLifecycleParameters(
            session; arm_timeout_ns=0)
        @test_throws RunLifecycleError RunLifecycleParameters(
            session; arm_timeout_ns=big(typemax(Int64)) + 1)

        readiness = AdapterReadinessSnapshot(
            session,
            LIFECYCLE_TEST_CLOCK,
            AdapterReady,
            Int32(7))
        @test run_session(readiness) == session
        @test run_execution_clock_identity(readiness) ==
            LIFECYCLE_TEST_CLOCK
        @test adapter_readiness_status(readiness) == AdapterReady
        @test adapter_readiness_execution_ns(readiness) == 7
        @test_throws RunLifecycleError AdapterReadinessSnapshot(
            session, LIFECYCLE_TEST_CLOCK, AdapterReady, false)
        @test_throws RunLifecycleError AdapterReadinessSnapshot(
            session,
            LIFECYCLE_TEST_CLOCK,
            AdapterReady,
            big(typemax(Int64)) + 1)

        request = RunStopRequest(
            session,
            LIFECYCLE_TEST_CLOCK,
            Int32(8);
            reason=:operator_request)
        @test run_session(request) == session
        @test run_execution_clock_identity(request) ==
            LIFECYCLE_TEST_CLOCK
        @test stop_request_execution_ns(request) == 8
        @test stop_request_reason(request) == :operator_request
        @test_throws RunLifecycleError RunStopRequest(
            session, LIFECYCLE_TEST_CLOCK, false)
        @test_throws RunLifecycleError RunStopRequest(
            session,
            LIFECYCLE_TEST_CLOCK,
            8;
            reason=Symbol(""))

        terminal = RunTerminalEvent(
            session,
            LIFECYCLE_TEST_CLOCK,
            PlantTimestamp(9),
            Int32(10);
            reason=:scenario_complete)
        @test run_session(terminal) == session
        @test run_execution_clock_identity(terminal) ==
            LIFECYCLE_TEST_CLOCK
        @test terminal_event_plant_timestamp(terminal) ==
            PlantTimestamp(9)
        @test terminal_event_execution_ns(terminal) == 10
        @test terminal_event_reason(terminal) == :scenario_complete
        @test_throws RunLifecycleError RunTerminalEvent(
            session,
            LIFECYCLE_TEST_CLOCK,
            PlantTimestamp(9),
            false)
        @test_throws RunLifecycleError RunTerminalEvent(
            session,
            LIFECYCLE_TEST_CLOCK,
            PlantTimestamp(9),
            10;
            reason=Symbol(""))

        failure = RunFailureEvent(
            session,
            LIFECYCLE_TEST_CLOCK,
            Int32(11),
            :serial_owner,
            :injected)
        @test run_session(failure) == session
        @test run_execution_clock_identity(failure) ==
            LIFECYCLE_TEST_CLOCK
        @test failure_event_execution_ns(failure) == 11
        @test failure_event_component(failure) == :serial_owner
        @test failure_event_reason(failure) == :injected
        unavailable_time = RunFailureEvent(
            session,
            LIFECYCLE_TEST_CLOCK,
            nothing,
            :clock,
            :unavailable)
        @test failure_event_execution_ns(unavailable_time) === nothing
        @test_throws RunLifecycleError RunFailureEvent(
            session,
            LIFECYCLE_TEST_CLOCK,
            false,
            :owner,
            :failed)
        @test_throws RunLifecycleError RunFailureEvent(
            session,
            LIFECYCLE_TEST_CLOCK,
            11,
            Symbol(""),
            :failed)
        @test_throws RunLifecycleError RunFailureEvent(
            session,
            LIFECYCLE_TEST_CLOCK,
            11,
            :owner,
            Symbol(""))

        @test Base.allocatedinline(ArmWindow)
        @test Base.allocatedinline(AdapterReadinessSnapshot)
        @test Base.allocatedinline(RunStopRequest)
        @test Base.allocatedinline(RunTerminalEvent)
        @test Base.allocatedinline(RunFailureEvent)
        @test Base.allocatedinline(RunTermination)
    end

    @testset "Deterministic transition matrix and exact arm boundary" begin
        valid_edges = Set((
            (RunConfigured, RunPrepared),
            (RunPrepared, RunArming),
            (RunArming, RunArmed),
            (RunArming, RunFailed),
            (RunArmed, RunRunning),
            (RunArmed, RunStopped),
            (RunArmed, RunFailed),
            (RunRunning, RunStopped),
            (RunRunning, RunFailed),
        ))
        for from in instances(RunPhase), to in instances(RunPhase)
            @test HIL_LIFECYCLE.run_transition_is_valid(from, to) ==
                ((from, to) in valid_edges)
        end

        parameters, state = lifecycle_state(42; arm_timeout_ns=10)
        @test run_session(state) == RunSessionID(42)
        @test run_phase(state) == RunPrepared
        @test run_arm_window(state) === nothing
        @test run_adapter_readiness(state) === nothing
        @test run_termination(state) === nothing

        clock = CachedNanoClock(100)
        window = HIL_LIFECYCLE._begin_arm!(
            state,
            parameters,
            LIFECYCLE_TEST_CLOCK,
            Clocks.time_nanos(clock))
        @test run_phase(state) == RunArming
        @test run_session(window) == RunSessionID(42)
        @test run_execution_clock_identity(window) ==
            LIFECYCLE_TEST_CLOCK
        @test arm_opened_execution_ns(window) == 100
        @test arm_deadline_execution_ns(window) == 110
        @test run_arm_window(state) == window

        duplicate_begin = captured_lifecycle_error() do
            HIL_LIFECYCLE._begin_arm!(
                state,
                parameters,
                LIFECYCLE_TEST_CLOCK,
                Clocks.time_nanos(clock))
        end
        @test duplicate_begin isa RunLifecycleError
        @test duplicate_begin.reason == :invalid_phase
        @test run_phase(state) == RunArming

        not_ready = captured_lifecycle_error() do
            HIL_LIFECYCLE._validate_arm_readiness!(
                state,
                window,
                AdapterReadinessSnapshot(
                    RunSessionID(42),
                    LIFECYCLE_TEST_CLOCK,
                    AdapterNotReady,
                    Clocks.time_nanos(clock)),
                Clocks.time_nanos(clock))
        end
        @test not_ready isa RunLifecycleError
        @test not_ready.reason == :adapter_not_ready
        @test run_phase(state) == RunArming

        stale_readiness = captured_lifecycle_error() do
            HIL_LIFECYCLE._validate_arm_readiness!(
                state,
                window,
                AdapterReadinessSnapshot(
                    RunSessionID(43),
                    LIFECYCLE_TEST_CLOCK,
                    AdapterReady,
                    Clocks.time_nanos(clock)),
                Clocks.time_nanos(clock))
        end
        @test stale_readiness isa RunLifecycleError
        @test stale_readiness.reason == :stale_session
        @test run_phase(state) == RunArming

        future_readiness = captured_lifecycle_error() do
            HIL_LIFECYCLE._validate_arm_readiness!(
                state,
                window,
                AdapterReadinessSnapshot(
                    RunSessionID(42),
                    LIFECYCLE_TEST_CLOCK,
                    AdapterReady,
                    101),
                Clocks.time_nanos(clock))
        end
        @test future_readiness isa RunLifecycleError
        @test future_readiness.reason == :readiness_from_future
        @test run_phase(state) == RunArming

        before_arm_readiness = captured_lifecycle_error() do
            HIL_LIFECYCLE._validate_arm_readiness!(
                state,
                window,
                AdapterReadinessSnapshot(
                    RunSessionID(42),
                    LIFECYCLE_TEST_CLOCK,
                    AdapterReady,
                    99),
                Clocks.time_nanos(clock))
        end
        @test before_arm_readiness isa RunLifecycleError
        @test before_arm_readiness.reason == :readiness_before_arm
        @test run_phase(state) == RunArming

        wrong_clock = captured_lifecycle_error() do
            HIL_LIFECYCLE._validate_arm_readiness!(
                state,
                window,
                AdapterReadinessSnapshot(
                    RunSessionID(42),
                    LIFECYCLE_OTHER_CLOCK,
                    AdapterReady,
                    100),
                100)
        end
        @test wrong_clock isa RunLifecycleError
        @test wrong_clock.reason == :clock_identity_mismatch
        @test run_phase(state) == RunArming

        same_parameters, same_state =
            lifecycle_state(42; arm_timeout_ns=10)
        same_session_window = HIL_LIFECYCLE._begin_arm!(
            same_state,
            same_parameters,
            LIFECYCLE_TEST_CLOCK,
            99)
        stale_same_session_window =
            captured_lifecycle_error() do
                HIL_LIFECYCLE._validate_arm_readiness!(
                    state,
                    same_session_window,
                    AdapterReadinessSnapshot(
                        RunSessionID(42),
                        LIFECYCLE_TEST_CLOCK,
                        AdapterReady,
                        100),
                    100)
            end
        @test stale_same_session_window isa RunLifecycleError
        @test stale_same_session_window.reason ==
            :stale_arm_window

        other_parameters, other_state =
            lifecycle_state(44; arm_timeout_ns=10)
        other_window = HIL_LIFECYCLE._begin_arm!(
            other_state,
            other_parameters,
            LIFECYCLE_TEST_CLOCK,
            100)
        stale_window = captured_lifecycle_error() do
            HIL_LIFECYCLE._validate_arm_readiness!(
                state,
                other_window,
                AdapterReadinessSnapshot(
                    RunSessionID(42),
                    LIFECYCLE_TEST_CLOCK,
                    AdapterReady,
                    100),
                100)
        end
        @test stale_window isa RunLifecycleError
        @test stale_window.reason == :stale_session

        Clocks.advance!(clock, 10)
        accepted_readiness = AdapterReadinessSnapshot(
            RunSessionID(42),
            LIFECYCLE_TEST_CLOCK,
            AdapterReady,
            Clocks.time_nanos(clock))
        HIL_LIFECYCLE._validate_arm_readiness!(
            state,
            window,
            accepted_readiness,
            Clocks.time_nanos(clock))
        HIL_LIFECYCLE._complete_arm!(
            state,
            window,
            accepted_readiness,
            Clocks.time_nanos(clock))
        @test run_phase(state) == RunArmed
        @test run_execution_clock_identity(state) ==
            LIFECYCLE_TEST_CLOCK
        @test run_armed_execution_ns(state) == 110
        @test run_adapter_readiness(state) === accepted_readiness
        HIL_LIFECYCLE._start_run!(state)
        @test run_phase(state) == RunRunning

        request = RunStopRequest(
            RunSessionID(42),
            LIFECYCLE_TEST_CLOCK,
            Clocks.time_nanos(clock);
            reason=:matrix_complete)
        termination = HIL_LIFECYCLE._stop_run!(
            state, request, Clocks.time_nanos(clock))
        @test run_phase(state) == RunStopped
        @test run_termination(state) == termination
        @test run_termination_kind(termination) == RequestedRunStop
        @test run_session(termination) ==
            RunSessionID(42)
        @test run_execution_clock_identity(termination) ==
            LIFECYCLE_TEST_CLOCK
        @test run_termination_execution_ns(termination) == 110
        @test run_termination_plant_timestamp(termination) === nothing
        @test run_termination_component(termination) == :run_stop
        @test run_termination_reason(termination) == :matrix_complete

        duplicate_stop = captured_lifecycle_error() do
            HIL_LIFECYCLE._stop_run!(
                state, request, Clocks.time_nanos(clock))
        end
        @test duplicate_stop isa RunLifecycleError
        @test duplicate_stop.reason == :invalid_phase
        @test run_termination(state) == termination
    end

    @testset "Arm, clean-stop, and failure rejection paths" begin
        timeout_parameters, timeout_state =
            lifecycle_state(45; arm_timeout_ns=5)
        timeout_window = HIL_LIFECYCLE._begin_arm!(
            timeout_state,
            timeout_parameters,
            LIFECYCLE_TEST_CLOCK,
            10)
        timeout = captured_lifecycle_error() do
            HIL_LIFECYCLE._validate_arm_readiness!(
                timeout_state,
                timeout_window,
                AdapterReadinessSnapshot(
                    RunSessionID(45),
                    LIFECYCLE_TEST_CLOCK,
                    AdapterNotReady,
                    10),
                16)
        end
        @test timeout isa RunLifecycleError
        @test timeout.reason == :arm_deadline_expired
        @test run_phase(timeout_state) == RunFailed
        timeout_termination = run_termination(timeout_state)
        @test run_termination_kind(timeout_termination) ==
            ArmDeadlineExpired
        @test run_termination_execution_ns(timeout_termination) == 16
        @test run_termination_reason(timeout_termination) ==
            :arm_deadline_expired

        failed_parameters, failed_state = lifecycle_state(46)
        failed_window = HIL_LIFECYCLE._begin_arm!(
            failed_state,
            failed_parameters,
            LIFECYCLE_TEST_CLOCK,
            20)
        adapter_failure = captured_lifecycle_error() do
            HIL_LIFECYCLE._validate_arm_readiness!(
                failed_state,
                failed_window,
                AdapterReadinessSnapshot(
                    RunSessionID(46),
                    LIFECYCLE_TEST_CLOCK,
                    AdapterFailed,
                    21),
                21)
        end
        @test adapter_failure isa RunLifecycleError
        @test adapter_failure.reason == :adapter_failed
        @test run_phase(failed_state) == RunFailed
        @test run_termination_kind(run_termination(failed_state)) ==
            AdapterReadinessFailed

        wrap_parameters, wrap_state = lifecycle_state(
            47; arm_timeout_ns=10)
        wrap_window = HIL_LIFECYCLE._begin_arm!(
            wrap_state,
            wrap_parameters,
            LIFECYCLE_TEST_CLOCK,
            typemax(Int64) - 5)
        @test arm_deadline_execution_ns(wrap_window) ==
            typemin(Int64) + 4
        wrap_readiness = AdapterReadinessSnapshot(
            RunSessionID(47),
            LIFECYCLE_TEST_CLOCK,
            AdapterReady,
            typemin(Int64) + 4)
        HIL_LIFECYCLE._validate_arm_readiness!(
            wrap_state,
            wrap_window,
            wrap_readiness,
            typemin(Int64) + 4)
        HIL_LIFECYCLE._complete_arm!(
            wrap_state,
            wrap_window,
            wrap_readiness,
            typemin(Int64) + 4)
        @test run_phase(wrap_state) == RunArmed

        wrapped_timeout_parameters, wrapped_timeout_state =
            lifecycle_state(471; arm_timeout_ns=10)
        wrapped_timeout_window = HIL_LIFECYCLE._begin_arm!(
            wrapped_timeout_state,
            wrapped_timeout_parameters,
            LIFECYCLE_TEST_CLOCK,
            typemax(Int64) - 5)
        wrapped_timeout = captured_lifecycle_error() do
            HIL_LIFECYCLE._validate_arm_readiness!(
                wrapped_timeout_state,
                wrapped_timeout_window,
                AdapterReadinessSnapshot(
                    RunSessionID(471),
                    LIFECYCLE_TEST_CLOCK,
                    AdapterReady,
                    typemin(Int64) + 4),
                typemin(Int64) + 5)
        end
        @test wrapped_timeout isa RunLifecycleError
        @test wrapped_timeout.reason == :arm_deadline_expired
        @test run_phase(wrapped_timeout_state) == RunFailed

        armed_parameters, armed_state = lifecycle_state(48)
        armed_window = HIL_LIFECYCLE._begin_arm!(
            armed_state,
            armed_parameters,
            LIFECYCLE_TEST_CLOCK,
            30)
        armed_readiness = AdapterReadinessSnapshot(
            RunSessionID(48),
            LIFECYCLE_TEST_CLOCK,
            AdapterReady,
            30)
        HIL_LIFECYCLE._validate_arm_readiness!(
            armed_state,
            armed_window,
            armed_readiness,
            30)
        HIL_LIFECYCLE._complete_arm!(
            armed_state, armed_window, armed_readiness, 30)
        armed_stop = HIL_LIFECYCLE._stop_run!(
            armed_state,
            RunStopRequest(
                RunSessionID(48),
                LIFECYCLE_TEST_CLOCK,
                30;
                reason=:stop_before_run),
            30)
        @test run_phase(armed_state) == RunStopped
        @test run_termination_kind(armed_stop) == RequestedRunStop

        terminal_parameters, terminal_state = lifecycle_state(49)
        terminal_window = HIL_LIFECYCLE._begin_arm!(
            terminal_state,
            terminal_parameters,
            LIFECYCLE_TEST_CLOCK,
            40)
        terminal_readiness = AdapterReadinessSnapshot(
            RunSessionID(49),
            LIFECYCLE_TEST_CLOCK,
            AdapterReady,
            40)
        HIL_LIFECYCLE._validate_arm_readiness!(
            terminal_state,
            terminal_window,
            terminal_readiness,
            40)
        HIL_LIFECYCLE._complete_arm!(
            terminal_state,
            terminal_window,
            terminal_readiness,
            40)
        terminal_while_armed = captured_lifecycle_error() do
            HIL_LIFECYCLE._stop_run!(
                terminal_state,
                RunTerminalEvent(
                    RunSessionID(49),
                    LIFECYCLE_TEST_CLOCK,
                    PlantTimestamp(4),
                    40),
                40)
        end
        @test terminal_while_armed isa RunLifecycleError
        @test terminal_while_armed.reason == :invalid_phase
        HIL_LIFECYCLE._start_run!(terminal_state)

        wrong_clock_stop = captured_lifecycle_error() do
            HIL_LIFECYCLE._stop_run!(
                terminal_state,
                RunStopRequest(
                    RunSessionID(49),
                    LIFECYCLE_OTHER_CLOCK,
                    40),
                40)
        end
        @test wrong_clock_stop isa RunLifecycleError
        @test wrong_clock_stop.reason == :clock_identity_mismatch
        stale_stop = captured_lifecycle_error() do
            HIL_LIFECYCLE._stop_run!(
                terminal_state,
                RunStopRequest(
                    RunSessionID(50),
                    LIFECYCLE_TEST_CLOCK,
                    40),
                40)
        end
        @test stale_stop isa RunLifecycleError
        @test stale_stop.reason == :stale_session
        future_stop = captured_lifecycle_error() do
            HIL_LIFECYCLE._stop_run!(
                terminal_state,
                RunStopRequest(
                    RunSessionID(49),
                    LIFECYCLE_TEST_CLOCK,
                    41),
                40)
        end
        @test future_stop isa RunLifecycleError
        @test future_stop.reason == :event_from_future
        before_arm_stop = captured_lifecycle_error() do
            HIL_LIFECYCLE._stop_run!(
                terminal_state,
                RunStopRequest(
                    RunSessionID(49),
                    LIFECYCLE_TEST_CLOCK,
                    39),
                40)
        end
        @test before_arm_stop isa RunLifecycleError
        @test before_arm_stop.reason == :event_before_arm
        terminal_stop = HIL_LIFECYCLE._stop_run!(
            terminal_state,
            RunTerminalEvent(
                RunSessionID(49),
                LIFECYCLE_TEST_CLOCK,
                PlantTimestamp(4),
                40;
                reason=:terminal),
            40)
        @test run_termination_kind(terminal_stop) ==
            ConfiguredTerminalStop
        @test run_termination_plant_timestamp(terminal_stop) ==
            PlantTimestamp(4)

        runtime_parameters, runtime_state = lifecycle_state(51)
        runtime_window = HIL_LIFECYCLE._begin_arm!(
            runtime_state,
            runtime_parameters,
            LIFECYCLE_TEST_CLOCK,
            50)
        runtime_readiness = AdapterReadinessSnapshot(
            RunSessionID(51),
            LIFECYCLE_TEST_CLOCK,
            AdapterReady,
            50)
        HIL_LIFECYCLE._validate_arm_readiness!(
            runtime_state,
            runtime_window,
            runtime_readiness,
            50)
        HIL_LIFECYCLE._complete_arm!(
            runtime_state,
            runtime_window,
            runtime_readiness,
            50)
        HIL_LIFECYCLE._start_run!(runtime_state)
        wrong_clock_failure = captured_lifecycle_error() do
            HIL_LIFECYCLE._fail_run!(
                runtime_state,
                RunFailureEvent(
                    RunSessionID(51),
                    LIFECYCLE_OTHER_CLOCK,
                    50,
                    :cpu_owner,
                    :wrong_clock))
        end
        @test wrong_clock_failure isa RunLifecycleError
        @test wrong_clock_failure.reason ==
            :clock_identity_mismatch
        runtime_failure = HIL_LIFECYCLE._fail_run!(
            runtime_state,
            RunFailureEvent(
                RunSessionID(51),
                LIFECYCLE_TEST_CLOCK,
                nothing,
                :cpu_owner,
                :injected))
        @test run_phase(runtime_state) == RunFailed
        @test run_termination_kind(runtime_failure) ==
            RuntimeRunFailure
        @test run_termination_execution_ns(runtime_failure) === nothing
        @test run_termination_component(runtime_failure) == :cpu_owner
        @test run_termination_reason(runtime_failure) == :injected

        duplicate_failure = captured_lifecycle_error() do
            HIL_LIFECYCLE._fail_run!(
                runtime_state,
                RunFailureEvent(
                    RunSessionID(51),
                    LIFECYCLE_TEST_CLOCK,
                    51,
                    :cpu_owner,
                    :again))
        end
        @test duplicate_failure isa RunLifecycleError
        @test duplicate_failure.reason == :invalid_phase
    end
end
