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
using AdaptiveOpticsSim.Plant: CommandEndpointID, PlantTimestamp
using Clocks

const HIL_LIFECYCLE = AdaptiveOpticsHIL.Lifecycle
const LIFECYCLE_TEST_CLOCK =
    ExecutionClockID(:lifecycle_test_clock)
const LIFECYCLE_OTHER_CLOCK =
    ExecutionClockID(:lifecycle_other_clock)
const LIFECYCLE_TESTS_WITH_COVERAGE =
    Base.JLOptions().code_coverage != 0

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

@inline function liveness_reset_allocations!(
    state,
    endpoint,
    clock,
    observed_execution_ns)
    return @allocated HIL_LIFECYCLE._admit_rtc_ingress_liveness!(
        state, endpoint, clock, observed_execution_ns)
end

@inline function failure_publication_allocations!(
    coordinator,
    record)
    return @allocated HIL_LIFECYCLE._publish_run_failure!(
        coordinator, 1, record)
end

@inline function failure_shutdown_allocations!(
    coordinator,
    record)
    return @allocated begin
        HIL_LIFECYCLE._publish_run_failure!(
            coordinator, 1, record)
        first_run_failure(coordinator)
        HIL_LIFECYCLE._begin_run_shutdown!(coordinator, 100)
        HIL_LIFECYCLE._run_shutdown_requested(coordinator)
        HIL_LIFECYCLE._acknowledge_run_stop!(coordinator, 1)
        HIL_LIFECYCLE._run_shutdown_acknowledged(coordinator)
        HIL_LIFECYCLE._record_acknowledgement_timeouts!(
            coordinator, 110)
        HIL_LIFECYCLE._run_shutdown_drain_expired!(
            coordinator, 120)
    end
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
            OwnerExceptionRunFailure,
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
            OwnerExceptionRunFailure,
            session,
            LIFECYCLE_TEST_CLOCK,
            nothing,
            :clock,
            :unavailable)
        @test failure_event_execution_ns(unavailable_time) === nothing
        @test_throws RunLifecycleError RunFailureEvent(
            OwnerExceptionRunFailure,
            session,
            LIFECYCLE_TEST_CLOCK,
            false,
            :owner,
            :failed)
        @test_throws RunLifecycleError RunFailureEvent(
            OwnerExceptionRunFailure,
            session,
            LIFECYCLE_TEST_CLOCK,
            11,
            Symbol(""),
            :failed)
        @test_throws RunLifecycleError RunFailureEvent(
            OwnerExceptionRunFailure,
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

    @testset "Prepared first-failure and acknowledgement coordination" begin
        session = RunSessionID(411)
        policy = RunShutdownPolicy(
            acknowledgement_timeout_ns=10,
            drain_timeout_ns=20)
        @test acknowledgement_timeout_ns(policy) == 10
        @test drain_timeout_ns(policy) == 20
        @test_throws RunLifecycleError RunShutdownPolicy(
            acknowledgement_timeout_ns=false,
            drain_timeout_ns=20)
        @test_throws RunLifecycleError RunShutdownPolicy(
            acknowledgement_timeout_ns=0,
            drain_timeout_ns=20)
        @test_throws RunLifecycleError RunShutdownPolicy(
            acknowledgement_timeout_ns=10,
            drain_timeout_ns=big(typemax(Int64)) + 1)

        owners = Memory{RunOwnerID}(undef, 3)
        owners[1] = RunOwnerID(:serial_coordinator, 1)
        owners[2] = RunOwnerID(:path_execution_owner, 1)
        owners[3] = RunOwnerID(:device_submission_owner, 2)
        @test run_owner_component(owners[2]) ==
            :path_execution_owner
        @test run_owner_ordinal(owners[3]) == 2
        @test isequal(
            owners[2], RunOwnerID(:path_execution_owner, 1))
        @test hash(owners[2]) ==
            hash(RunOwnerID(:path_execution_owner, 1))
        @test_throws RunLifecycleError RunOwnerID(Symbol(""), 1)
        @test_throws RunLifecycleError RunOwnerID(:owner, false)
        @test_throws RunLifecycleError RunOwnerID(:owner, 0)

        coordinator =
            HIL_LIFECYCLE._prepare_run_failure_coordinator(
                session, policy, owners)
        prepared_coordinator_owner = owners[1]
        owners[1] = RunOwnerID(:mutated_input_owner, 1)
        @test HIL_LIFECYCLE._run_failure_owner(
            coordinator, 1) == prepared_coordinator_owner
        owners[1] = prepared_coordinator_owner
        @test_throws RunLifecycleError begin
            HIL_LIFECYCLE._prepare_run_failure_coordinator(
                session,
                policy,
                Memory{RunOwnerID}(undef, 0))
        end
        duplicate_owners = Memory{RunOwnerID}(undef, 2)
        duplicate_owners[1] = owners[1]
        duplicate_owners[2] = owners[1]
        @test_throws RunLifecycleError begin
            HIL_LIFECYCLE._prepare_run_failure_coordinator(
                session, policy, duplicate_owners)
        end
        owner_failure = ArgumentError("owner failure")
        record = RunFailureRecord(
            DeviceRunFailure,
            session,
            owners[3],
            OwnerDeviceCompletion,
            nothing,
            :execution_owner,
            :device_failure;
            work_sequence=7)
        @test Base.allocatedinline(RunFailureRecord)
        @test run_failure_kind(record) == DeviceRunFailure
        @test run_failure_owner(record) == owners[3]
        @test run_failure_stage(record) == OwnerDeviceCompletion
        @test run_failure_execution_ns(record) === nothing
        @test run_failure_component(record) == :execution_owner
        @test run_failure_reason(record) == :device_failure
        @test run_failure_work_sequence(record) == 7
        @test_throws RunLifecycleError RunFailureRecord(
            RequestedRunStop,
            session,
            owners[3],
            OwnerExecution,
            1,
            :owner,
            :failure)
        @test_throws RunLifecycleError RunFailureRecord(
            OwnerExceptionRunFailure,
            session,
            owners[3],
            OwnerExecution,
            1,
            :owner,
            :failure;
            work_sequence=false)
        stale_record = RunFailureRecord(
            DeviceRunFailure,
            RunSessionID(999),
            owners[3],
            OwnerDeviceCompletion,
            nothing,
            :execution_owner,
            :stale_session)
        @test_throws RunLifecycleError begin
            HIL_LIFECYCLE._publish_run_failure!(
                coordinator, 3, stale_record)
        end
        wrong_owner_record = RunFailureRecord(
            DeviceRunFailure,
            session,
            owners[2],
            OwnerDeviceCompletion,
            nothing,
            :execution_owner,
            :wrong_owner)
        @test_throws RunLifecycleError begin
            HIL_LIFECYCLE._publish_run_failure!(
                coordinator, 3, wrong_owner_record)
        end
        @test_throws RunLifecycleError begin
            HIL_LIFECYCLE._publish_run_failure!(
                coordinator, 0, record)
        end

        @test HIL_LIFECYCLE._publish_run_failure!(
            coordinator, 3, record)
        @test first_run_failure(coordinator) == record
        earlier_slot_record = RunFailureRecord(
            OwnerExceptionRunFailure,
            session,
            owners[2],
            OwnerExecution,
            99,
            :execution_owner,
            :later_observation)
        @test HIL_LIFECYCLE._publish_run_failure!(
            coordinator, 2, earlier_slot_record)
        @test first_run_failure(coordinator) == record
        @test !HIL_LIFECYCLE._publish_run_failure!(
            coordinator, 3, record)

        @test HIL_LIFECYCLE._begin_run_shutdown!(
            coordinator, 100) == 1
        @test HIL_LIFECYCLE._begin_run_shutdown!(
            coordinator, 101) == 1
        @test HIL_LIFECYCLE._acknowledge_run_stop!(
            coordinator, 1)
        @test HIL_LIFECYCLE._acknowledge_run_stop!(
            coordinator, 2)
        @test HIL_LIFECYCLE._record_acknowledgement_timeouts!(
            coordinator, 110) == 0
        @test HIL_LIFECYCLE._record_acknowledgement_timeouts!(
            coordinator, 111) == 1
        @test HIL_LIFECYCLE._acknowledge_run_stop!(
            coordinator, 3)
        @test HIL_LIFECYCLE._run_shutdown_acknowledged(
            coordinator)
        @test !HIL_LIFECYCLE._run_shutdown_drain_expired!(
            coordinator, 120)
        @test HIL_LIFECYCLE._run_shutdown_drain_expired!(
            coordinator, 121)

        accounting = run_failure_accounting(coordinator)
        @test accounting.stop_epoch == 1
        @test accounting.started_execution_ns == 100
        @test accounting.acknowledgement_deadline_execution_ns ==
            110
        @test accounting.drain_deadline_execution_ns == 120
        @test accounting.first_failure == record
        @test length(accounting.owners) == 3
        @test accounting.owners[3].failure == record
        @test accounting.owners[3].acknowledged
        @test accounting.owners[3].acknowledgement_timed_out
        @test accounting.drain_timed_out

        concurrent_owners = Memory{RunOwnerID}(undef, 3)
        concurrent_owners[1] = RunOwnerID(:serial_coordinator, 1)
        concurrent_owners[2] = RunOwnerID(:path_execution_owner, 1)
        concurrent_owners[3] = RunOwnerID(:device_submission_owner, 1)
        concurrent = HIL_LIFECYCLE._prepare_run_failure_coordinator(
            RunSessionID(412), policy, concurrent_owners)
        concurrent_records = Memory{RunFailureRecord}(undef, 3)
        @inbounds for slot in eachindex(concurrent_records)
            concurrent_records[slot] = RunFailureRecord(
                OwnerExceptionRunFailure,
                RunSessionID(412),
                concurrent_owners[slot],
                OwnerExecution,
                100 + slot,
                :injected_owner,
                Symbol(:failure_, slot))
        end
        tasks = map(eachindex(concurrent_records)) do slot
            Threads.@spawn HIL_LIFECYCLE._publish_run_failure!(
                concurrent, slot, concurrent_records[slot])
        end
        @test all(fetch, tasks)
        @test first_run_failure(concurrent) ==
            concurrent_records[1]
        concurrent_accounting =
            run_failure_accounting(concurrent)
        @test all(
            owner -> owner.failure !== nothing,
            concurrent_accounting.owners)

        if LIFECYCLE_TESTS_WITH_COVERAGE
            @test_skip "failure-publication allocation gate disabled under coverage instrumentation"
        else
            warm_owners = Memory{RunOwnerID}(undef, 1)
            warm_owners[1] = RunOwnerID(:serial_coordinator, 1)
            warm = HIL_LIFECYCLE._prepare_run_failure_coordinator(
                session, policy, warm_owners)
            measured = HIL_LIFECYCLE._prepare_run_failure_coordinator(
                session, policy, copy(warm_owners))
            coordinator_record = RunFailureRecord(
                OwnerExceptionRunFailure,
                session,
                warm_owners[1],
                CoordinatorFailureBoundary,
                100,
                :serial_coordinator,
                :injected)
            failure_publication_allocations!(
                warm, coordinator_record)
            @test @inferred(
                HIL_LIFECYCLE._publish_run_failure!(
                    measured,
                    1,
                    coordinator_record)) == true
            allocation_measured =
                HIL_LIFECYCLE._prepare_run_failure_coordinator(
                    session, policy, copy(warm_owners))
            @test failure_publication_allocations!(
                allocation_measured,
                coordinator_record) == 0

            warm_shutdown =
                HIL_LIFECYCLE._prepare_run_failure_coordinator(
                    session, policy, copy(warm_owners))
            measured_shutdown =
                HIL_LIFECYCLE._prepare_run_failure_coordinator(
                    session, policy, copy(warm_owners))
            failure_shutdown_allocations!(
                warm_shutdown, coordinator_record)
            @test failure_shutdown_allocations!(
                measured_shutdown, coordinator_record) == 0
        end
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
                    OwnerExceptionRunFailure,
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
                OwnerExceptionRunFailure,
                RunSessionID(51),
                LIFECYCLE_TEST_CLOCK,
                nothing,
                :cpu_owner,
                :injected))
        @test run_phase(runtime_state) == RunFailed
        @test run_termination_kind(runtime_failure) ==
            OwnerExceptionRunFailure
        @test run_termination_execution_ns(runtime_failure) === nothing
        @test run_termination_component(runtime_failure) == :cpu_owner
        @test run_termination_reason(runtime_failure) == :injected

        duplicate_failure = captured_lifecycle_error() do
            HIL_LIFECYCLE._fail_run!(
                runtime_state,
                RunFailureEvent(
                    OwnerExceptionRunFailure,
                    RunSessionID(51),
                    LIFECYCLE_TEST_CLOCK,
                    51,
                    :cpu_owner,
                    :again))
        end
        @test duplicate_failure isa RunLifecycleError
        @test duplicate_failure.reason == :invalid_phase
    end

    @testset "RTC-ingress-liveness inclusive deadline" begin
        endpoint = CommandEndpointID(:lifecycle_dm)
        policy = RTCIngressLivenessPolicy(
            endpoint,
            LIFECYCLE_TEST_CLOCK;
            timeout_ns=10)
        @test rtc_ingress_liveness_endpoint(policy) == endpoint
        @test rtc_ingress_liveness_clock(policy) ==
            LIFECYCLE_TEST_CLOCK
        @test rtc_ingress_liveness_timeout_ns(policy) == 10
        @test_throws RunLifecycleError RTCIngressLivenessPolicy(
            endpoint,
            LIFECYCLE_TEST_CLOCK;
            timeout_ns=false)
        @test_throws RunLifecycleError RTCIngressLivenessPolicy(
            endpoint,
            LIFECYCLE_TEST_CLOCK;
            timeout_ns=0)
        @test_throws RunLifecycleError RTCIngressLivenessPolicy(
            endpoint,
            LIFECYCLE_TEST_CLOCK;
            timeout_ns=big(typemax(Int64)) + 1)

        clock = CachedNanoClock(100)
        state = HIL_LIFECYCLE.RTCIngressLivenessState(policy)
        @test rtc_ingress_liveness_status(state) ==
            RTCIngressLivenessDisarmed
        @test HIL_LIFECYCLE._start_rtc_ingress_liveness!(
            state,
            LIFECYCLE_TEST_CLOCK,
            Clocks.time_nanos(clock)) == RTCIngressLivenessActive
        @test rtc_ingress_liveness_origin_ns(state) == 100
        @test rtc_ingress_liveness_deadline_ns(state) == 110

        Clocks.advance!(clock, 10)
        @test @inferred(
            HIL_LIFECYCLE._observe_rtc_ingress_liveness!(
                state,
                LIFECYCLE_TEST_CLOCK,
                Clocks.time_nanos(clock))) ==
            RTCIngressLivenessActive
        @test HIL_LIFECYCLE._admit_rtc_ingress_liveness!(
            state,
            endpoint,
            LIFECYCLE_TEST_CLOCK,
            Clocks.time_nanos(clock)) == RTCIngressLivenessActive
        @test rtc_ingress_liveness_origin_ns(state) == 110
        @test rtc_ingress_liveness_deadline_ns(state) == 120
        @test rtc_ingress_liveness_reset_count(state) == 1
        @test rtc_ingress_liveness_last_admission_ns(state) == 110

        Clocks.advance!(clock, 10)
        @test HIL_LIFECYCLE._observe_rtc_ingress_liveness!(
            state,
            LIFECYCLE_TEST_CLOCK,
            Clocks.time_nanos(clock)) == RTCIngressLivenessActive
        Clocks.advance!(clock, 1)
        @test HIL_LIFECYCLE._observe_rtc_ingress_liveness!(
            state,
            LIFECYCLE_TEST_CLOCK,
            Clocks.time_nanos(clock)) == RTCIngressLivenessExpired
        @test rtc_ingress_liveness_observation_ns(state) == 121
        @test rtc_ingress_liveness_expiry_count(state) == 1
        Clocks.advance!(clock, 1)
        @test HIL_LIFECYCLE._observe_rtc_ingress_liveness!(
            state,
            LIFECYCLE_TEST_CLOCK,
            Clocks.time_nanos(clock)) == RTCIngressLivenessExpired
        @test rtc_ingress_liveness_observation_ns(state) == 121
        @test rtc_ingress_liveness_expiry_count(state) == 1

        accounting = rtc_ingress_liveness_accounting(state)
        @test accounting.status == RTCIngressLivenessExpired
        @test accounting.endpoint == endpoint
        @test accounting.execution_clock == LIFECYCLE_TEST_CLOCK
        @test accounting.timeout_ns == 10
        @test accounting.origin_execution_ns == 110
        @test accounting.deadline_execution_ns == 120

        late = HIL_LIFECYCLE.RTCIngressLivenessState(policy)
        HIL_LIFECYCLE._start_rtc_ingress_liveness!(
            late, LIFECYCLE_TEST_CLOCK, Int64(0))
        @test HIL_LIFECYCLE._admit_rtc_ingress_liveness!(
            late, endpoint, LIFECYCLE_TEST_CLOCK, Int64(11)) ==
            RTCIngressLivenessExpired
        @test rtc_ingress_liveness_reset_count(late) == 0
        @test rtc_ingress_liveness_last_admission_ns(late) == 11

        mismatch = HIL_LIFECYCLE.RTCIngressLivenessState(policy)
        @test_throws RunLifecycleError begin
            HIL_LIFECYCLE._start_rtc_ingress_liveness!(
                mismatch, LIFECYCLE_OTHER_CLOCK, Int64(0))
        end
        HIL_LIFECYCLE._start_rtc_ingress_liveness!(
            mismatch, LIFECYCLE_TEST_CLOCK, Int64(0))
        @test_throws RunLifecycleError begin
            HIL_LIFECYCLE._admit_rtc_ingress_liveness!(
                mismatch,
                CommandEndpointID(:other_dm),
                LIFECYCLE_TEST_CLOCK,
                Int64(1))
        end

        wrapping = HIL_LIFECYCLE.RTCIngressLivenessState(policy)
        wrapping_origin = typemax(Int64) - Int64(5)
        HIL_LIFECYCLE._start_rtc_ingress_liveness!(
            wrapping, LIFECYCLE_TEST_CLOCK, wrapping_origin)
        exact_wrapped = reinterpret(
            Int64,
            reinterpret(UInt64, wrapping_origin) + UInt64(10))
        @test HIL_LIFECYCLE._observe_rtc_ingress_liveness!(
            wrapping, LIFECYCLE_TEST_CLOCK, exact_wrapped) ==
            RTCIngressLivenessActive

        allocation_state =
            HIL_LIFECYCLE.RTCIngressLivenessState(policy)
        HIL_LIFECYCLE._start_rtc_ingress_liveness!(
            allocation_state, LIFECYCLE_TEST_CLOCK, Int64(0))
        HIL_LIFECYCLE._admit_rtc_ingress_liveness!(
            allocation_state,
            endpoint,
            LIFECYCLE_TEST_CLOCK,
            Int64(1))
        if LIFECYCLE_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test liveness_reset_allocations!(
                allocation_state,
                endpoint,
                LIFECYCLE_TEST_CLOCK,
                Int64(2)) == 0
        end

        disabled = HIL_LIFECYCLE.RTCIngressLivenessState(
            HIL_LIFECYCLE.NoRTCIngressLiveness())
        @test HIL_LIFECYCLE._start_rtc_ingress_liveness!(
            disabled,
            LIFECYCLE_TEST_CLOCK,
            Int64(0)) == RTCIngressLivenessDisabled
        @test rtc_ingress_liveness_accounting(disabled).endpoint ===
            nothing
    end
end
