module Gate8OperationalHarness

import AdaptiveOpticsHIL
using AdaptiveOpticsHIL.Execution
using AdaptiveOpticsHIL.Lifecycle
using AdaptiveOpticsHIL.Ownership
using AdaptiveOpticsHIL.Ports
using AdaptiveOpticsHIL.Serial
using AdaptiveOpticsHIL.Timing
import AdaptiveOpticsSim
import Agent
using Clocks
using HdrHistogram
using LinearAlgebra

using ..Gate4ABoundaryHarness

const Boundary = Gate4ABoundaryHarness
const Plant = AdaptiveOpticsSim.Plant

finish_operational_observer!(
    ::Boundary.AbstractBoundaryObserver,
    ::Any) = nothing
reset_operational_observer!(
    ::Boundary.AbstractBoundaryObserver) = nothing

include("gate8_system_metrics.jl")

struct Gate8InjectedOwnerFailure <: Exception
    trigger_batch_sequence::UInt64
end

struct Gate8InjectedOwnerFailureObserved <: Exception
    trigger_batch_sequence::UInt64
end

function Base.showerror(
    io::IO,
    error::Gate8InjectedOwnerFailure)
    print(
        io,
        "injected Gate 8 execution-owner failure after optical batch ",
        error.trigger_batch_sequence)
end

function Base.showerror(
    io::IO,
    error::Gate8InjectedOwnerFailureObserved)
    print(
        io,
        "observed injected Gate 8 execution-owner failure after optical batch ",
        error.trigger_batch_sequence)
end

mutable struct Gate8FailureControl
    trigger::Threads.Atomic{Bool}
    fired::Threads.Atomic{Bool}
    trigger_batch_sequence::Threads.Atomic{UInt64}
    injection_wall_ns::Threads.Atomic{UInt64}
end

Gate8FailureControl() = Gate8FailureControl(
    Threads.Atomic{Bool}(false),
    Threads.Atomic{Bool}(false),
    Threads.Atomic{UInt64}(0),
    Threads.Atomic{UInt64}(0))

struct Gate8FailureIdleStrategy <: Agent.IdleStrategy
    control::Gate8FailureControl
    coordinator_task_id::UInt
    yielding::Agent.YieldingIdleStrategy
end

struct Gate8FailureIdleStrategyFactory
    control::Gate8FailureControl
    coordinator_task_id::UInt
end

function Gate8FailureIdleStrategyFactory(
    control::Gate8FailureControl,
)
    return Gate8FailureIdleStrategyFactory(
        control,
        objectid(current_task()),
    )
end

function (factory::Gate8FailureIdleStrategyFactory)()
    return Gate8FailureIdleStrategy(
        factory.control,
        factory.coordinator_task_id,
        Agent.YieldingIdleStrategy(),
    )
end

function Agent.idle(strategy::Gate8FailureIdleStrategy)
    if objectid(current_task()) !=
            strategy.coordinator_task_id &&
            strategy.control.trigger[] &&
            Threads.atomic_cas!(
                strategy.control.fired, false, true) == false
        injection_wall_ns = time_ns()
        strategy.control.injection_wall_ns[] = injection_wall_ns
        throw(Gate8InjectedOwnerFailure(
            strategy.control.trigger_batch_sequence[]))
    end
    return Agent.idle(strategy.yielding)
end

Agent.reset(strategy::Gate8FailureIdleStrategy) =
    Agent.reset(strategy.yielding)

struct Gate8FailureTriggerObserver <:
    Boundary.AbstractBoundaryObserver
    control::Gate8FailureControl
    target_batch_sequence::UInt64
end

function Boundary.observe_boundary_step!(
    observer::Gate8FailureTriggerObserver,
    driver,
    ::Any,
    ::Int64)
    executor = serial_optical_execution(driver.fixture.run)
    sequence = executor.coordinator.batch_sequence
    sequence < observer.target_batch_sequence &&
        return nothing
    observer.control.trigger_batch_sequence[] = sequence
    observer.control.trigger[] = true
    wall_deadline_ns = time_ns() + UInt64(60_000_000_000)
    while !observer.control.fired[]
        time_ns() <= wall_deadline_ns || error(
            "execution-owner fault trigger was not observed")
        yield()
    end
    while first_run_failure(driver.fixture.run.failures) === nothing
        time_ns() <= wall_deadline_ns || error(
            "execution-owner fault was not published")
        yield()
    end
    throw(Gate8InjectedOwnerFailureObserved(sequence))
end

function workload_from_contract(contract)
    workload = contract["workload"]
    return Boundary.Gate4AWorkloadConfig(
        primary_period_ns=workload["primary_period_ns"],
        primary_exposure_ns=workload["primary_exposure_ns"],
        optical_sample_period_ns=
            workload["primary_optical_sample_period_ns"],
        feedback_period_ns=workload["feedback_period_ns"],
        feedback_phase_ns=workload["feedback_phase_ns"],
        feedback_exposure_ns=workload["feedback_exposure_ns"],
        science_enabled=true,
        science_sample_period_ns=
            workload["science_optical_sample_period_ns"],
        science_period_ns=workload["science_period_ns"],
        science_exposure_ns=workload["science_exposure_ns"],
        command_capacity=workload[
            "command_payload_pool_capacity"],
        primary_product_capacity=workload[
            "primary_product_capacity"],
        feedback_product_capacity=workload[
            "feedback_product_capacity"],
        science_product_capacity=workload[
            "science_product_capacity"],
        complete_product_lead_time_ns=workload[
            "complete_product_lead_time_ns"],
        maximum_lease_hold_time_ns=workload[
            "maximum_lease_hold_time_ns"],
        controller_gain=workload["controller_gain"],
        run_seed=workload["run_seed"])
end

function histogram_config_from_contract(contract)
    return Boundary.HistogramConfig(
        contract["histogram_lowest_ns"],
        contract["histogram_highest_ns"],
        contract["histogram_significant_figures"])
end

function execution_owner_configuration(
    mode::AbstractExecutionOwnerMode,
    contract)
    julia_threads = Threads.nthreads()
    blas_threads = BLAS.get_num_threads()
    fft_threads = contract["fft_threads"]
    owner_count = contract["execution_owner_count"]
    contexts = max(
        julia_threads,
        owner_count * fft_threads,
        owner_count * blas_threads)
    budget = Plant.grouped_cpu_execution_budget(
        cpu_context_count=contexts,
        julia_thread_count=julia_threads,
        outer_owner_count=owner_count,
        group_julia_thread_count=1,
        fft_thread_count=fft_threads,
        blas_thread_count=blas_threads)
    environment = Plant.CPUExecutionEnvironment(
        available_cpu_context_count=contexts,
        julia_thread_count=julia_threads,
        fft_thread_count=fft_threads,
        blas_thread_count=blas_threads)
    owner_policy = ExecutionOwnerOverloadPolicy(
        RequiredResource(),
        FailRunOnOwnerOverload();
        maximum_lateness_ns=contract[
            "execution_owner_maximum_lateness_ns"],
        recovery_occupancy=0)
    return ExecutionOwnerConfiguration(
        mode,
        budget,
        environment;
        ring_capacity=contract["execution_owner_ring_capacity"],
        owner_policy)
end

function gate8_owner_thread_ids(contract)
    owner_count = contract["execution_owner_count"]
    default_threads = filter(
        thread_id -> Threads.threadpool(thread_id) === :default,
        1:Threads.maxthreadid(),
    )
    length(default_threads) > owner_count ||
        error(
            "Gate 8 Agent owners require one coordinator context " *
            "beyond the assigned owner threads")
    return Tuple(default_threads[(end - owner_count + 1):end])
end

gate8_owner_idle_strategy_factory(::Any) =
    Agent.YieldingIdleStrategy

agent_execution_configuration(contract) =
    execution_owner_configuration(
        AgentExecutionOwners(
            gate8_owner_idle_strategy_factory(contract);
            placement=ThreadAssignedExecutionOwnerPlacement(
                gate8_owner_thread_ids(contract))),
        contract)

deterministic_execution_configuration(contract) =
    execution_owner_configuration(
        DeterministicExecutionOwners(),
        contract)

function prepare_driver(
    clock::Clocks.AbstractNanoClock,
    workload::Boundary.Gate4AWorkloadConfig,
    run_config::Boundary.BoundaryRunConfig,
    histogram_config::Boundary.HistogramConfig,
    optical_execution;
    observer::Boundary.AbstractBoundaryObserver=
        Boundary.NoBoundaryObserver(),
    arm_timeout_ns::Integer=5_000_000_000)
    return Boundary.prepare_boundary_driver(
        clock,
        workload,
        run_config,
        histogram_config;
        optical_execution,
        observer,
        arm_timeout_ns)
end

function execute_run(
    clock::Clocks.AbstractNanoClock,
    workload::Boundary.Gate4AWorkloadConfig,
    run_config::Boundary.BoundaryRunConfig,
    histogram_config::Boundary.HistogramConfig,
    optical_execution;
    observer::Boundary.AbstractBoundaryObserver=
        Boundary.NoBoundaryObserver())
    driver = prepare_driver(
        clock,
        workload,
        run_config,
        histogram_config,
        optical_execution;
        observer)
    reset_operational_observer!(observer)
    result = Boundary.execute_boundary_run!(driver)
    finish_operational_observer!(observer, driver)
    Boundary.validate_boundary_result(result, run_config)
    return result
end

function precompile_and_discard_driver!(driver)
    precompile(
        Boundary.execute_boundary_run!,
        (typeof(driver),))
    request = RunStopRequest(
        run_session(driver.fixture.run),
        execution_clock_identity(driver.fixture.armed.timing),
        Clocks.time_nanos(driver.fixture.clock);
        reason=:benchmark_specialization_precompile)
    accounting = Boundary._finish_boundary_stop!(
        driver, request)
    serial_run_is_quiescent(accounting) || error(
        "discarded specialization driver retained ownership")
    return nothing
end

function validate_agent_owner_result(result, expected_count::Integer)
    owners = result.accounting.execution_owners
    owners === nothing && error(
        "Agent-owner qualification did not retain execution-owner accounting")
    length(owners) == expected_count || error(
        "Agent-owner qualification prepared an unexpected owner count")
    task_ids = UInt64[]
    for owner in owners
        owner.startup_acknowledged || error(
            "an execution owner did not acknowledge startup")
        owner.stop_acknowledged || error(
            "an execution owner did not acknowledge stop")
        iszero(owner.task_id) && error(
            "an Agent execution owner did not retain a task identity")
        push!(task_ids, owner.task_id)
    end
    allunique(task_ids) || error(
        "execution owners did not retain distinct task identities")
    serial_run_is_quiescent(result.accounting) || error(
        "Agent-owner result retained ownership after clean stop")
    return true
end

function _drain_acquisition_products!(
    scratch::Base.RefValue{AcquisitionCompletion},
    port)
    drained = 0
    while true
        result = try_take!(scratch, port)
        port_status(result) in (PortEmpty, PortClosed) &&
            return drained
        port_status(result) == PortTransferSucceeded || error(
            "failure drain observed an invalid acquisition status")
        port_status(release_product!(port, scratch[])) ==
            PortTransferSucceeded || error(
                "failure drain could not release an acquisition product")
        drained += 1
    end
end

function _drain_command_outcomes!(
    scratch::Base.RefValue{
        CommandOutcome{LeasedCommandPayload}},
    port)
    drained = 0
    while true
        result = try_take!(scratch, port)
        port_status(result) in (PortEmpty, PortClosed) &&
            return drained
        port_status(result) == PortTransferSucceeded || error(
            "failure drain observed an invalid command-outcome status")
        port_status(release_outcome!(port, scratch[])) ==
            PortTransferSucceeded || error(
                "failure drain could not release a command outcome")
        drained += 1
    end
end

function drain_failure_adapter_products!(driver)
    drained = 0
    drained += _drain_acquisition_products!(
        driver.primary_completion,
        driver.fixture.wfs_port)
    drained += _drain_acquisition_products!(
        driver.feedback_completion,
        driver.fixture.feedback_port)
    if driver.fixture.science_port !== nothing
        drained += _drain_acquisition_products!(
            driver.science_completion,
            driver.fixture.science_port)
    end
    drained += _drain_command_outcomes!(
        driver.command_outcome,
        command_completion_port(
            driver.fixture.command_ports))
    reclaim_serial_returns!(driver.fixture.run)
    return drained
end

function finish_failed_run!(driver)
    wall_deadline_ns = time_ns() + UInt64(60_000_000_000)
    acknowledgement_wall_ns = UInt64(0)
    while true
        drain_failure_adapter_products!(driver)
        status = progress_serial_shutdown!(driver.fixture.running)
        if iszero(acknowledgement_wall_ns)
            failure = serial_failure_accounting(
                driver.fixture.run)
            all(owner -> owner.acknowledged, failure.owners) &&
                (acknowledgement_wall_ns = time_ns())
        end
        status == SerialShutdownFinalized && break
        time_ns() <= wall_deadline_ns || error(
            "injected failure did not finish bounded shutdown")
        yield()
    end
    drain_failure_adapter_products!(driver)
    reclaim_serial_returns!(driver.fixture.run)
    iszero(acknowledgement_wall_ns) && error(
        "failed run finalized without complete owner acknowledgement")
    return (
        accounting=serial_run_accounting(driver.fixture.run),
        acknowledgement_wall_ns)
end

function execute_injected_owner_failure(
    contract,
    histogram_config::Boundary.HistogramConfig;
    clock::Clocks.AbstractNanoClock=Clocks.SystemNanoClock())
    workload = workload_from_contract(contract)
    control = Gate8FailureControl()
    idle_strategy_factory = Gate8FailureIdleStrategyFactory(
        control)
    optical_execution = execution_owner_configuration(
        AgentExecutionOwners(
            idle_strategy_factory;
            placement=ThreadAssignedExecutionOwnerPlacement(
                gate8_owner_thread_ids(contract))),
        contract)
    observer = Gate8FailureTriggerObserver(
        control,
        UInt64(contract[
            "injected_failure_batch_sequence"]))
    run_config = Boundary.BoundaryRunConfig(
        samples=max(
            contract["correctness_frames"],
            contract["injected_failure_batch_sequence"]),
        checkpoint_stride=contract["checkpoint_stride"])
    driver = prepare_driver(
        clock,
        workload,
        run_config,
        histogram_config,
        optical_execution;
        observer)
    caught = nothing
    observed_wall_ns = UInt64(0)
    try
        Boundary.execute_boundary_run!(driver)
    catch error
        caught = error
        observed_wall_ns = time_ns()
    end
    caught isa Gate8InjectedOwnerFailureObserved || error(
        "the predeclared execution-owner failure was not injected; " *
        "observed $(typeof(caught)): " *
        (caught === nothing ? "run completed" :
         sprint(showerror, caught)))
    injection_wall_ns = control.injection_wall_ns[]
    iszero(injection_wall_ns) && error(
        "the execution-owner fault did not retain its injection time")
    failure_before = first_run_failure(
        driver.fixture.run.failures)
    failure_before === nothing && error(
        "the injected owner failure was not published")
    AdaptiveOpticsHIL.Serial._record_serial_failure!(
        driver.fixture.running,
        caught)
    ingress_closed_wall_ns = time_ns()
    ingress_closed = ring_accounting(
        command_submission_port(
            driver.fixture.command_ports).ring).closed
    ingress_closed || error(
        "the injected owner failure did not close command ingress")
    finish = finish_failed_run!(driver)
    accounting = finish.accounting
    shutdown_end_ns = time_ns()
    failure_after = first_run_failure(
        driver.fixture.run.failures)
    failure_after == failure_before || error(
        "the first injected failure changed during shutdown")
    run_phase(driver.fixture.run) == RunFailed || error(
        "the injected failure did not leave the run failed")
    return (
        error=caught,
        owner_maximum_lateness_ns=Int(
            contract[
                "execution_owner_maximum_lateness_ns"]),
        trigger_batch_sequence=
            Int(control.trigger_batch_sequence[]),
        injection_to_observation_ns=Int(
            observed_wall_ns - injection_wall_ns),
        observation_to_ingress_closure_ns=Int(
            ingress_closed_wall_ns - observed_wall_ns),
        observation_to_acknowledgement_ns=Int(
            finish.acknowledgement_wall_ns -
                observed_wall_ns),
        observation_to_shutdown_ns=Int(
            shutdown_end_ns - observed_wall_ns),
        ingress_closed,
        failure=failure_after,
        failure_accounting=
            serial_failure_accounting(driver.fixture.run),
        accounting)
end

function warm_injected_owner_failure_specialization!(
    contract,
    histogram_config::Boundary.HistogramConfig)
    warm_contract = deepcopy(contract)
    warm_contract["injected_failure_batch_sequence"] = 16
    warm_contract["correctness_frames"] = 32
    warm_contract["execution_owner_maximum_lateness_ns"] =
        600_000_000_000
    warm_histogram_config = Boundary.HistogramConfig(
        histogram_config.lowest_ns,
        600_000_000_000,
        histogram_config.significant_figures)
    execute_injected_owner_failure(
        warm_contract,
        warm_histogram_config;
        clock=Clocks.SystemNanoClock())
    GC.gc()
    return nothing
end

function execute_named_drain_deficit(contract)
    clock = Clocks.CachedNanoClock(0)
    workload = workload_from_contract(contract)
    fixture =
        Boundary.Gate4ASerialWorkload.prepare_gate4a_fixture(
            clock,
            workload;
            optical_execution=
                agent_execution_configuration(contract),
            arm_timeout_ns=contract["arm_timeout_ns"],
            shutdown_policy=RunShutdownPolicy(
                acknowledgement_timeout_ns=contract[
                    "acknowledgement_timeout_ns"],
                drain_timeout_ns=contract[
                    "deficit_drain_timeout_ns"]))
    held = Ref{AcquisitionCompletion}()
    feedback = Ref{AcquisitionCompletion}()
    science = Ref{AcquisitionCompletion}()
    outcome = Ref{CommandOutcome{LeasedCommandPayload}}()
    wall_deadline_ns = time_ns() + UInt64(60_000_000_000)
    while true
        result = step_serial_run!(fixture.running)
        if serial_step_status(result) == SerialDeadlinePending
            Clocks.advance!(
                clock,
                serial_step_time_until_ns(result))
        end
        take = try_take!(held, fixture.wfs_port)
        port_status(take) == PortTransferSucceeded && break
        port_status(take) in (PortEmpty, PortClosed) || error(
            "deficit setup observed an invalid WFS status")
        _drain_acquisition_products!(
            feedback, fixture.feedback_port)
        _drain_acquisition_products!(
            science, fixture.science_port)
        _drain_command_outcomes!(
            outcome,
            command_completion_port(fixture.command_ports))
        reclaim_serial_returns!(fixture.run)
        time_ns() <= wall_deadline_ns || error(
            "deficit setup did not acquire its retained WFS lease")
        yield()
    end

    stop = RunStopRequest(
        run_session(fixture.run),
        execution_clock_identity(fixture.armed.timing),
        Clocks.time_nanos(clock);
        reason=:gate8_named_drain_deficit)
    begin_serial_stop!(fixture.running, stop) ==
        SerialShutdownDraining || error(
            "deficit phase did not enter bounded shutdown")

    acknowledgement_deadline =
        time_ns() + UInt64(60_000_000_000)
    while true
        _drain_acquisition_products!(
            feedback, fixture.feedback_port)
        _drain_acquisition_products!(
            science, fixture.science_port)
        _drain_command_outcomes!(
            outcome,
            command_completion_port(fixture.command_ports))
        reclaim_serial_returns!(fixture.run)
        status = progress_serial_shutdown!(fixture.running)
        status == SerialShutdownFinalized && error(
            "retained WFS lease was incorrectly reported as a clean drain")
        failure = serial_failure_accounting(fixture.run)
        all(owner -> owner.acknowledged, failure.owners) && break
        time_ns() <= acknowledgement_deadline || error(
            "execution owners did not acknowledge the deficit stop")
        yield()
    end

    Clocks.advance!(
        clock,
        contract["deficit_drain_timeout_ns"] + 1)
    progress_serial_shutdown!(fixture.running) ==
        SerialShutdownFinalized || error(
            "retained WFS lease did not finalize at the drain deadline")
    run_phase(fixture.run) == RunFailed || error(
        "retained WFS lease did not preserve a failed run")
    failure = serial_failure_accounting(fixture.run)
    failure.drain_timed_out || error(
        "retained WFS lease did not publish a drain timeout")
    accounting = serial_run_accounting(fixture.run)
    wfs = only(
        acquisition
        for acquisition in accounting.acquisitions
        if acquisition.acquisition ==
            Plant.AcquisitionID(:hil_wfs))
    wfs.products.consumer_leased == 1 || error(
        "drain deficit did not name the retained WFS consumer lease")

    port_status(release_product!(fixture.wfs_port, held[])) ==
        PortTransferSucceeded || error(
            "post-evidence cleanup could not return the retained WFS lease")
    reclaim_serial_returns!(fixture.run)
    cleanup_accounting = serial_run_accounting(fixture.run)
    return (; failure, accounting, cleanup_accounting)
end

function execute_required_overload(
    contract,
    workload::Boundary.Gate4AWorkloadConfig,
    histogram_config::Boundary.HistogramConfig)
    run_config = Boundary.BoundaryRunConfig(
        samples=contract["overload_maximum_offered"],
        checkpoint_stride=contract["checkpoint_stride"])
    maximum_wall_ns = cld(
        run_config.samples * 1_000_000_000,
        contract["minimum_calibrated_rate_hz"])
    observer = OperationalIntervalObserver(
        max(
            4,
            cld(
                maximum_wall_ns,
                contract["interval_ns"]) + 8),
        contract["interval_ns"])
    driver = prepare_driver(
        Clocks.SystemNanoClock(),
        workload,
        run_config,
        histogram_config,
        agent_execution_configuration(contract);
        observer)
    reset_operational_observer!(observer)
    wall_start_ns = time_ns()
    caught = nothing
    observed_wall_ns = UInt64(0)
    try
        Boundary.execute_boundary_run!(driver)
    catch error
        caught = error
        observed_wall_ns = time_ns()
    end
    caught === nothing && error(
        "bounded overload completed without its required policy failure")
    failure_before = first_run_failure(driver.fixture.run.failures)
    failure_before === nothing && error(
        "bounded overload did not publish a first failure")
    ingress_closed = ring_accounting(
        command_submission_port(
            driver.fixture.command_ports).ring).closed
    ingress_closed || error(
        "bounded overload did not close command ingress")
    finish = finish_failed_run!(driver)
    accounting = finish.accounting
    shutdown_end_ns = time_ns()
    failure_after = first_run_failure(driver.fixture.run.failures)
    failure_after == failure_before || error(
        "bounded overload changed its first failure during drain")
    run_phase(driver.fixture.run) == RunFailed || error(
        "bounded overload did not preserve a failed run")
    finish_operational_observer!(observer, driver)
    return (
        error=caught,
        start_to_failure_ns=Int(
            observed_wall_ns - wall_start_ns),
        # Owner lateness and ring-capacity policies fail in the same call
        # that first observes the violated bound. There is therefore no
        # separately sampled detection interval to estimate.
        violation_observation_is_failure_boundary=true,
        violation_to_failure_ns=Int(0),
        failure_to_acknowledgement_ns=Int(
            finish.acknowledgement_wall_ns -
                observed_wall_ns),
        failure_to_shutdown_ns=Int(
            shutdown_end_ns - observed_wall_ns),
        ingress_closed,
        offered_primary=driver.counters.offered_primary,
        completed_primary=driver.counters.command_responses,
        intervals=collect(interval_records(observer)),
        failure=failure_after,
        failure_accounting=
            serial_failure_accounting(driver.fixture.run),
        accounting)
end

end
