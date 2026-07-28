import AdaptiveOpticsHIL

using AdaptiveOpticsHIL.Execution
using AdaptiveOpticsHIL.Lifecycle
using AdaptiveOpticsHIL.Ownership: RingTransferSucceeded
using AdaptiveOpticsHIL.Ownership: close_ring!
using AdaptiveOpticsHIL.Ownership: try_submit!, try_take!
using AdaptiveOpticsHIL.Ports: OptionalResource, RequiredResource
using AdaptiveOpticsHIL.Timing
using AdaptiveOpticsSim
using AdaptiveOpticsSim.Plant
using AdaptiveOpticsSim.Plant: ColdPlantModelDefinition
using AdaptiveOpticsSim.Plant: PreparedPathExecutor
using AdaptiveOpticsSim.Plant: prepare_pupil_opd_materialization
using LinearAlgebra: BLAS
using Clocks
using Test

const EXECUTION_TEST_PLANT = AdaptiveOpticsSim.Plant
const EXECUTION_TESTS_WITH_COVERAGE =
    Base.JLOptions().code_coverage != 0
const EXECUTION_TEST_BATCH_ALLOCATION_BUDGET = 2_048
const EXECUTION_TEST_SHUTDOWN_POLICY = RunShutdownPolicy(
    acknowledgement_timeout_ns=1_000_000_000,
    drain_timeout_ns=2_000_000_000)

struct ExecutionTestUnsupportedMode <: AbstractExecutionOwnerMode end
struct ExecutionTestUnsupportedIdle <: AbstractExecutionOwnerIdlePolicy end
struct ExecutionTestUnsupportedOverloadAction <:
    AbstractExecutionOwnerOverloadAction end
struct ExecutionTestUnsupportedConfiguration <:
    AbstractOpticalExecutionConfiguration
end

struct ExecutionBeforeDequeueFailureIdle{E} <:
    AbstractExecutionOwnerIdlePolicy
    error::E
    coordinator_task_id::UInt
end

ExecutionBeforeDequeueFailureIdle(error) =
    ExecutionBeforeDequeueFailureIdle(
        error, objectid(current_task()))

AdaptiveOpticsHIL.Execution._validate_execution_owner_idle_policy(
    ::ExecutionBeforeDequeueFailureIdle) = nothing

function AdaptiveOpticsHIL.Execution._next_idle_poll(
    policy::ExecutionBeforeDequeueFailureIdle,
    ::UInt32)
    objectid(current_task()) == policy.coordinator_task_id &&
        return (yield(); zero(UInt32))
    throw(policy.error)
end

function execution_test_owner_configuration(
    mode::AbstractExecutionOwnerMode;
    outer_owner_count::Integer=1,
    owner_policy=ExecutionOwnerOverloadPolicy(
        RequiredResource(),
        FailRunOnOwnerOverload();
        maximum_lateness_ns=nothing,
        recovery_occupancy=0),
    owner_policy_overrides=(),
)
    julia_threads = Threads.nthreads()
    blas_threads = BLAS.get_num_threads()
    fft_threads = 1
    contexts = max(
        julia_threads,
        Int(outer_owner_count) * fft_threads,
        Int(outer_owner_count) * blas_threads,
    )
    budget = EXECUTION_TEST_PLANT.grouped_cpu_execution_budget(
        cpu_context_count=contexts,
        julia_thread_count=julia_threads,
        outer_owner_count=outer_owner_count,
        group_julia_thread_count=1,
        fft_thread_count=fft_threads,
        blas_thread_count=blas_threads,
    )
    environment = EXECUTION_TEST_PLANT.CPUExecutionEnvironment(
        available_cpu_context_count=contexts,
        julia_thread_count=julia_threads,
        fft_thread_count=fft_threads,
        blas_thread_count=blas_threads,
    )
    return ExecutionOwnerConfiguration(
        mode,
        budget,
        environment;
        owner_policy,
        owner_policy_overrides,
    )
end

mutable struct ExecutionConcurrencyProbe
    expected::Int
    arrivals::Threads.Atomic{Int}
    release::Threads.Atomic{Bool}
    thread_ids::Memory{Int}
    timeout_ns::UInt64
end

function ExecutionConcurrencyProbe(
    expected::Integer;
    timeout_seconds::Real=5,
)
    expected > 1 || throw(ArgumentError(
        "execution probe requires at least two owners"))
    timeout_seconds > 0 || throw(ArgumentError(
        "execution probe timeout must be positive"))
    thread_ids = Memory{Int}(undef, Int(expected))
    fill!(thread_ids, 0)
    return ExecutionConcurrencyProbe(
        Int(expected),
        Threads.Atomic{Int}(0),
        Threads.Atomic{Bool}(false),
        thread_ids,
        UInt64(round(Int, timeout_seconds * 1.0e9)),
    )
end

@inline execution_concurrency_probe!(::Nothing) = nothing

function execution_concurrency_probe!(
    probe::ExecutionConcurrencyProbe,
)
    slot = Threads.atomic_add!(probe.arrivals, 1) + 1
    slot <= probe.expected || return nothing
    @inbounds probe.thread_ids[slot] = Threads.threadid()
    if slot == probe.expected
        probe.release[] = true
        return nothing
    end
    start = time_ns()
    while !probe.release[]
        GC.safepoint()
        time_ns() - start <= probe.timeout_ns || error(
            "execution owners did not overlap before the probe timeout")
    end
    return nothing
end

mutable struct ExecutionIndependenceState
    science_started::Threads.Atomic{Bool}
    required_wfs_completed::Threads.Atomic{Bool}
    science_released::Threads.Atomic{Bool}
    timeout_ns::UInt64
end

function ExecutionIndependenceState(; timeout_seconds::Real=5)
    timeout_seconds > 0 || throw(ArgumentError(
        "execution-independence timeout must be positive"))
    return ExecutionIndependenceState(
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(false),
        UInt64(round(Int, timeout_seconds * 1.0e9)),
    )
end

struct ExecutionOptionalScienceStall
    state::ExecutionIndependenceState
end

struct ExecutionOptionalScienceDeadlineStall{C}
    state::ExecutionIndependenceState
    clock::C
end

struct ExecutionRequiredWFSCompletion
    state::ExecutionIndependenceState
end

struct ExecutionFailureProbe{E}
    error::E
end

struct ExecutionMaterializationFailureProbe{E}
    error::E
end

struct ExecutionFailingMaterialization{M,E}
    implementation::M
    error::E
end

function EXECUTION_TEST_PLANT.validate_path_materialization_binding(
    materialization::ExecutionFailingMaterialization,
    input,
    atmosphere,
    source)
    return EXECUTION_TEST_PLANT.validate_path_materialization_binding(
        materialization.implementation,
        input,
        atmosphere,
        source)
end

function EXECUTION_TEST_PLANT.validate_path_materialization(
    materialization::ExecutionFailingMaterialization,
    input,
    atmosphere,
    epoch)
    return EXECUTION_TEST_PLANT.validate_path_materialization(
        materialization.implementation,
        input,
        atmosphere,
        epoch)
end

function EXECUTION_TEST_PLANT.materialize_path_input!(
    materialization::ExecutionFailingMaterialization,
    input,
    atmosphere,
    epoch)
    throw(materialization.error)
end

@inline execution_test_materialization(::Any, implementation) =
    implementation

@inline function execution_test_materialization(
    probe::ExecutionMaterializationFailureProbe,
    implementation)
    return ExecutionFailingMaterialization(
        implementation, probe.error)
end

function wait_for_execution_test_flag(
    flag::Threads.Atomic{Bool},
    timeout_ns::UInt64,
    message::AbstractString,
)
    start = time_ns()
    while !flag[]
        yield()
        time_ns() - start <= timeout_ns || error(message)
    end
    return nothing
end

@inline execution_probe_before!(probe) =
    execution_concurrency_probe!(probe)
@inline execution_probe_after!(probe) = nothing

function execution_probe_before!(
    probe::ExecutionOptionalScienceStall,
)
    state = probe.state
    state.science_started[] = true
    wait_for_execution_test_flag(
        state.required_wfs_completed,
        state.timeout_ns,
        "required WFS did not complete while optional science was stalled",
    )
    state.science_released[] = true
    return nothing
end

function execution_probe_before!(
    probe::ExecutionOptionalScienceDeadlineStall,
)
    state = probe.state
    state.science_started[] = true
    wait_for_execution_test_flag(
        state.required_wfs_completed,
        state.timeout_ns,
        "required WFS did not complete while optional science was stalled",
    )
    Clocks.advance!(probe.clock, 1)
    state.science_released[] = true
    return nothing
end

function execution_probe_before!(
    probe::ExecutionRequiredWFSCompletion,
)
    state = probe.state
    wait_for_execution_test_flag(
        state.science_started,
        state.timeout_ns,
        "optional science did not enter its prepared stall",
    )
    return nothing
end

function execution_probe_after!(
    probe::ExecutionRequiredWFSCompletion,
)
    probe.state.required_wfs_completed[] = true
    return nothing
end

execution_probe_before!(probe::ExecutionFailureProbe) =
    throw(probe.error)
execution_probe_before!(
    ::ExecutionMaterializationFailureProbe) = nothing

struct ExecutionTestPathModel{P}
    probe::P
end

struct ExecutionBatchTestPathModel end

struct ExecutionTestPathExecution{E,P}
    imaging::E
    probe::P
    executions::Base.RefValue{Int}
end

struct ExecutionTestAcquisitionModel{T<:AbstractFloat}
    exposure_s::T
end

EXECUTION_TEST_PLANT.plant_model_definition_style(
    ::Type{<:ExecutionTestPathModel}) = ColdPlantModelDefinition()
EXECUTION_TEST_PLANT.plant_model_definition_style(
    ::Type{ExecutionBatchTestPathModel}) = ColdPlantModelDefinition()
EXECUTION_TEST_PLANT.plant_model_definition_style(
    ::Type{<:ExecutionTestAcquisitionModel}) = ColdPlantModelDefinition()

function EXECUTION_TEST_PLANT.validate_path_execution_binding(
    execution::ExecutionTestPathExecution,
    input,
    result,
)
    return EXECUTION_TEST_PLANT.validate_path_execution_binding(
        execution.imaging, input, result)
end

function EXECUTION_TEST_PLANT.execute_path!(
    result,
    input,
    execution::ExecutionTestPathExecution,
)
    execution_probe_before!(execution.probe)
    execution.executions[] += 1
    executed = EXECUTION_TEST_PLANT.execute_path!(
        result, input, execution.imaging)
    execution_probe_after!(execution.probe)
    return executed
end

@inline execution_test_count(execution) = nothing
@inline execution_test_count(
    execution::ExecutionTestPathExecution,
) = execution.executions[]

function EXECUTION_TEST_PLANT.prepare_path_executor(
    model::ExecutionTestPathModel,
    definition::OpticalPathDefinition,
    source::AdaptiveOpticsSim.AbstractSource,
    telescope::Telescope,
    atmosphere::AdaptiveOpticsSim.AbstractTimedAtmosphere,
)
    T = eltype(pupil_reflectivity(telescope))
    pupil = PupilFunction(telescope; T, backend=backend(telescope))
    imaging = prepare_direct_imaging(pupil, source; zero_padding=1)
    materialization = execution_test_materialization(
        model.probe,
        prepare_pupil_opd_materialization(
            atmosphere, telescope, source, pupil))
    return PreparedPathExecutor(
        definition,
        source,
        telescope,
        atmosphere,
        pupil,
        direct_imaging_output(imaging),
        ExecutionTestPathExecution(imaging, model.probe, Ref(0));
        materialization,
        optical_model=:execution_owner_direct_imaging,
        propagation_model=:fraunhofer_fft,
        model_revisions=UInt(1),
    )
end

function EXECUTION_TEST_PLANT.prepare_path_executor(
    ::ExecutionBatchTestPathModel,
    definition::OpticalPathDefinition,
    source::AdaptiveOpticsSim.AbstractSource,
    telescope::Telescope,
    atmosphere::AdaptiveOpticsSim.AbstractTimedAtmosphere,
)
    T = eltype(pupil_reflectivity(telescope))
    pupil = PupilFunction(telescope; T, backend=backend(telescope))
    execution = prepare_direct_imaging(
        pupil, source; zero_padding=1)
    return PreparedPathExecutor(
        definition,
        source,
        telescope,
        atmosphere,
        pupil,
        direct_imaging_output(execution),
        execution;
        materialization=prepare_pupil_opd_materialization(
            atmosphere, telescope, source, pupil),
        optical_model=:execution_owner_direct_imaging_batch,
        propagation_model=:fraunhofer_fft,
        model_revisions=UInt(1),
    )
end

function EXECUTION_TEST_PLANT.prepare_acquisition_provider(
    model::ExecutionTestAcquisitionModel,
    ::AcquisitionDefinition,
    path::PreparedPathExecutor,
)
    EXECUTION_TEST_PLANT.require_path_result(path)
    result = EXECUTION_TEST_PLANT.path_result(path)
    T = eltype(result.values)
    detector = Detector(
        integration_time=T(model.exposure_s),
        noise=NoiseNone(),
        qe=one(T),
        gain=one(T),
        response_model=NullFrameResponse(),
        sensor=CMOSSensor(timing_model=GlobalShutter(), T=T),
        T=T,
        backend=EXECUTION_TEST_PLANT.path_result_key(path).backend,
    )
    execution = EXECUTION_TEST_PLANT.FrameAcquisitionExecution(
        detector, result)
    products = EXECUTION_TEST_PLANT.AcquisitionProducts(
        execution.observation;
        metadata=(
            kind=:execution_owner_frame,
            units=:detected_electrons,
            geometry=result.metadata,
            detector=detector_export_metadata(detector),
        ),
    )
    return EXECUTION_TEST_PLANT.prepare_full_optical_provider(
        execution, products)
end

function execution_test_fixture(;
    probe=nothing,
    path_probes=nothing,
    device_batch_selection::Val=Val(:none),
    batchable::Bool=false,
)
    T = Float64
    telescope = Telescope(
        resolution=4,
        diameter=T(4),
        central_obstruction=zero(T),
        T=T,
    )
    atmosphere = MultiLayerAtmosphere(
        telescope;
        r0=T(0.2),
        L0=T(25),
        fractional_cn2=T[0.7, 0.3],
        wind_speed=T[7, 11],
        wind_direction=T[20, 125],
        altitude=T[0, 5_000],
        layer_ids=(:ground, :high),
        T=T,
    )
    science_source = Source(
        band=:custom,
        wavelength=T(0.8e-6),
        photon_irradiance=T(80),
        coordinates=(T(0), T(0)),
        T=T,
    )
    ngs_source = Source(
        band=:custom,
        wavelength=T(0.8e-6),
        photon_irradiance=T(65),
        coordinates=(T(2), T(35)),
        T=T,
    )
    lgs_source = if batchable
        Source(
            band=:custom,
            wavelength=T(0.8e-6),
            photon_irradiance=T(55),
            coordinates=(T(-3), T(80)),
            T=T,
        )
    else
        LGSSource(
            wavelength=T(589e-9),
            photon_irradiance=T(55),
            coordinates=(T(3), T(80)),
            altitude=T(90_000),
            T=T,
        )
    end
    sources = (
        science_source,
        ngs_source,
        lgs_source,
    )
    path_ids = (:optional_science, :ngs_wfs, :lgs_wfs)
    acquisition_ids = (:science_camera, :ngs_camera, :lgs_camera)
    probes = path_probes === nothing ?
        ntuple(_ -> probe, 3) : path_probes
    length(probes) == 3 || throw(ArgumentError(
        "execution fixture requires one probe per path"))
    paths = ntuple(
        index -> OpticalPathDefinition(
            path_ids[index],
            sources[index],
            batchable ?
                ExecutionBatchTestPathModel() :
                ExecutionTestPathModel(probes[index]),
        ),
        3,
    )
    acquisitions = ntuple(
        index -> AcquisitionDefinition(
            acquisition_ids[index],
            path_ids[index],
            ExecutionTestAcquisitionModel(T(0.2)),
        ),
        3,
    )
    plant = prepare_plant(
        PlantDefinition(; telescope, atmosphere, paths, acquisitions);
        run_seed=0x8a00,
    )
    sample_periods = batchable ?
        (100_000_000, 100_000_000, 100_000_000) :
        (100_000_000, 125_000_000, 200_000_000)
    samples = ntuple(3) do index
        OpticalSampleDefinition(
            path_ids[index],
            PeriodicSchedule(
                period_ns=sample_periods[index],
                phase_ns=0,
            ),
        )
    end
    events = (
        AcquisitionEventDefinition(
            :science_camera,
            GlobalShutterAcquisitionDefinition(
                PlantDuration(200_000_000)),
            PeriodicAcquisitionStart(PeriodicSchedule(
                period_ns=400_000_000, phase_ns=10_000_000)),
        ),
        AcquisitionEventDefinition(
            :ngs_camera,
            GlobalShutterAcquisitionDefinition(
                PlantDuration(200_000_000)),
            PeriodicAcquisitionStart(PeriodicSchedule(
                period_ns=500_000_000, phase_ns=10_000_000)),
        ),
        AcquisitionEventDefinition(
            :lgs_camera,
            GlobalShutterAcquisitionDefinition(
                PlantDuration(200_000_000)),
            PeriodicAcquisitionStart(PeriodicSchedule(
                period_ns=600_000_000, phase_ns=10_000_000)),
        ),
    )
    definition = PlantEventLoopDefinition(samples, events)
    prepared = if device_batch_selection == Val(:none)
        EXECUTION_TEST_PLANT._prepare_plant_event_loop(
            plant, definition, Val(:none))
    else
        EXECUTION_TEST_PLANT._prepare_plant_event_loop(
            plant, definition, device_batch_selection)
    end
    return (
        plant=plant,
        prepared=prepared,
        state=EXECUTION_TEST_PLANT.PlantEventLoopState(prepared),
        workspace=EXECUTION_TEST_PLANT.PlantEventLoopWorkspace(prepared),
        path_ids=path_ids,
        acquisition_ids=acquisition_ids,
    )
end

function prepare_execution_test_executor(
    fixture,
    mode::AbstractExecutionOwnerMode;
    outer_owner_count::Integer,
    session::RunSessionID=RunSessionID(0x8a00),
    owner_policy=ExecutionOwnerOverloadPolicy(
        RequiredResource(),
        FailRunOnOwnerOverload();
        maximum_lateness_ns=nothing,
        recovery_occupancy=0),
    owner_policy_overrides=(),
)
    configuration = execution_test_owner_configuration(
        mode;
        outer_owner_count,
        owner_policy,
        owner_policy_overrides,
    )
    executor = AdaptiveOpticsHIL.Execution._prepare_optical_execution(
        configuration,
        fixture.prepared,
        fixture.state,
        fixture.workspace,
        session,
        EXECUTION_TEST_SHUTDOWN_POLICY,
    )
    AdaptiveOpticsHIL.Execution._arm_optical_execution!(executor)
    AdaptiveOpticsHIL.Execution._start_optical_execution!(executor)
    return executor
end

function compare_execution_test_runs(serial, owned)
    @test owned.state.scheduler.revision ==
        serial.state.scheduler.revision
    @test owned.state.scheduler.cursors ==
        serial.state.scheduler.cursors
    @test owned.state.path_sampled == serial.state.path_sampled
    @test owned.state.product_sequences ==
        serial.state.product_sequences
    @test owned.state.product_ready_timestamps ==
        serial.state.product_ready_timestamps

    serial_epoch = current_epoch(serial.prepared.atmosphere)
    owned_epoch = current_epoch(owned.prepared.atmosphere)
    @test epoch_time(owned_epoch) == epoch_time(serial_epoch)
    @test epoch_sequence(owned_epoch) == epoch_sequence(serial_epoch)
    for index in eachindex(owned.prepared.atmosphere_rng.streams)
        @test copy(owned.prepared.atmosphere_rng.streams[index].state) ==
            copy(serial.prepared.atmosphere_rng.streams[index].state)
    end

    for id in serial.path_ids
        serial_path = EXECUTION_TEST_PLANT.prepared_path(
            serial.plant, id)
        owned_path = EXECUTION_TEST_PLANT.prepared_path(
            owned.plant, id)
        @test owned_path.input.opd == serial_path.input.opd
        @test owned_path.result.values == serial_path.result.values
        @test execution_test_count(owned_path.execution) ==
            execution_test_count(serial_path.execution)
    end
    for ordinal in
            1:EXECUTION_TEST_PLANT.path_execution_group_count(
                serial.prepared)
        serial_group = EXECUTION_TEST_PLANT.path_execution_group(
            serial.prepared, ordinal)
        owned_group = EXECUTION_TEST_PLANT.path_execution_group(
            owned.prepared, ordinal)
        @test copy(EXECUTION_TEST_PLANT.rng_stream_state(
            owned_group.rngs, Val(:provider))) ==
            copy(EXECUTION_TEST_PLANT.rng_stream_state(
                serial_group.rngs, Val(:provider)))
    end
    for id in serial.acquisition_ids
        @test EXECUTION_TEST_PLANT.acquisition_product_sequence(
            owned.prepared, owned.state, id) ==
            EXECUTION_TEST_PLANT.acquisition_product_sequence(
                serial.prepared, serial.state, id)
        @test EXECUTION_TEST_PLANT.acquisition_product_ready_timestamp(
            owned.prepared, owned.state, id) ==
            EXECUTION_TEST_PLANT.acquisition_product_ready_timestamp(
                serial.prepared, serial.state, id)
        @test EXECUTION_TEST_PLANT.acquisition_observation(
            EXECUTION_TEST_PLANT.prepared_acquisition(
                owned.plant, id)) ==
            EXECUTION_TEST_PLANT.acquisition_observation(
                EXECUTION_TEST_PLANT.prepared_acquisition(
                    serial.plant, id))
    end
    for index in eachindex(owned.prepared.acquisitions)
        @test copy(owned.prepared.acquisitions[index].rng) ==
            copy(serial.prepared.acquisitions[index].rng)
    end
    return nothing
end

function stop_execution_test_executor!(executor)
    @test execution_owners_are_quiescent(executor)
    AdaptiveOpticsHIL.Execution._stop_optical_execution!(executor)
    @test execution_owners_phase(executor) == ExecutionOwnersStopped
    @test execution_owners_are_quiescent(executor)
    return executor
end

function settle_execution_test_owner_completions!(executor)
    deadline_ns = time_ns() + UInt64(5_000_000_000)
    while true
        settled = all(
            ordinal -> begin
                accounting =
                    execution_owner_accounting(executor, ordinal)
                !accounting.failed &&
                    accounting.work_taken ==
                        accounting.work_completed
            end,
            1:execution_owner_count(executor),
        )
        settled && break
        time_ns() <= deadline_ns || error(
            "execution owners did not settle after policy failure")
        yield()
    end

    completion_type =
        AdaptiveOpticsHIL.Execution._ExecutionOwnerCompletion
    scratch = Ref{completion_type}()
    for ordinal in 1:execution_owner_count(executor)
        owner = execution_owner(executor, ordinal)
        while true
            status = try_take!(scratch, owner.completion)
            status == AdaptiveOpticsHIL.Ownership.RingEmpty && break
            status == RingTransferSucceeded || error(
                "failed owner completion path did not remain drainable")
            AdaptiveOpticsHIL.Execution.
                _record_owner_completion_consumption!(
                    executor.owner_overload_states[ordinal],
                    owner,
                )
            executor.coordinator.completions[ordinal] += UInt64(1)
        end
    end
    return executor
end

function captured_execution_test_error(f)
    try
        f()
    catch error
        return error
    end
    return nothing
end

function wait_for_execution_failure_record(executor)
    deadline_ns = time_ns() + UInt64(5_000_000_000)
    while true
        record = first_run_failure(executor.failures)
        record === nothing || return record
        time_ns() <= deadline_ns || error(
            "execution owner did not publish its injected failure")
        yield()
    end
end

function finish_execution_failure_shutdown!(executor)
    AdaptiveOpticsHIL.Lifecycle._begin_run_shutdown!(
        executor.failures, 0)
    AdaptiveOpticsHIL.Execution.
        _begin_optical_execution_shutdown!(executor)
    deadline_ns = time_ns() + UInt64(5_000_000_000)
    while !AdaptiveOpticsHIL.Execution.
            _progress_optical_execution_shutdown!(executor)
        time_ns() <= deadline_ns || error(
            "failed execution owners did not stop inside the test bound")
        yield()
    end
    AdaptiveOpticsHIL.Execution.
        _finalize_optical_execution_shutdown!(executor)
    return executor
end

@noinline function execute_execution_test_batch!(fixture, executor)
    return EXECUTION_TEST_PLANT.execute_optical_path_batch!(
        executor,
        fixture.prepared,
        fixture.state,
        fixture.workspace,
        PlantTimestamp(0),
    )
end

@noinline function execution_test_batch_allocations(
    fixture,
    executor,
)
    return @allocated execute_execution_test_batch!(fixture, executor)
end

@inline function execution_owner_deadline_allocations!(
    executor,
    mapping,
)
    return @allocated AdaptiveOpticsHIL.Execution.
        _observe_execution_owner_deadline!(
            executor,
            1,
            mapping,
            PlantTimestamp(0),
        )
end

@testset "Long-lived optical execution owners" begin
    @test_throws ExecutionOwnerError ExecutionOwnerID(0)
    @test_throws ExecutionOwnerError ExecutionOwnerID(true)
    owner_id = ExecutionOwnerID(7)
    equivalent_owner_id = ExecutionOwnerID(7)
    @test isequal(owner_id, equivalent_owner_id)
    @test hash(owner_id) == hash(equivalent_owner_id)
    @test AdaptiveOpticsHIL.Execution._is_cpu_execution_owner(
        CPUBackend())
    @test !AdaptiveOpticsHIL.Execution._is_cpu_execution_owner(
        AdaptiveOpticsSim.CUDABackend())
    serial_executor =
        EXECUTION_TEST_PLANT.SerialOpticalPathBatchExecutor()
    @test AdaptiveOpticsHIL.Execution._execution_is_armed(
        serial_executor)
    @test AdaptiveOpticsHIL.Execution._execution_is_quiescent(
        serial_executor)
    @test AdaptiveOpticsHIL.Execution._execution_ownership_is_drained(
        serial_executor)
    @test AdaptiveOpticsHIL.Execution.
        _progress_optical_execution_shutdown!(serial_executor)
    @test !AdaptiveOpticsHIL.Execution._execution_batch_active(
        serial_executor)
    @test AdaptiveOpticsHIL.Execution.
        _abandon_failed_optical_path_batch!(serial_executor)
    @test AdaptiveOpticsHIL.Execution._execution_accounting_is_quiescent(
        nothing)
    @test_throws ExecutionOwnerError HybridExecutionOwnerIdle(0)
    @test_throws ExecutionOwnerError HybridExecutionOwnerIdle(true)
    @test HybridExecutionOwnerIdle(4).spin_count == 4
    @test ThreadedExecutionOwners().idle_policy isa
        YieldingExecutionOwnerIdle
    @test ThreadedExecutionOwners(
        HybridExecutionOwnerIdle(4)).idle_policy.spin_count == 4
    capacity_configuration =
        execution_test_owner_configuration(
            DeterministicExecutionOwners())
    optional_owner_policy = ExecutionOwnerOverloadPolicy(
        OptionalResource(),
        FailRunOnOwnerOverload();
        maximum_lateness_ns=0,
        recovery_occupancy=0,
    )
    @test optional_owner_policy.criticality isa OptionalResource
    @test optional_owner_policy.action isa FailRunOnOwnerOverload
    @test optional_owner_policy.maximum_lateness_ns == 0
    @test optional_owner_policy.recovery_occupancy == 0
    @test !resource_is_required(optional_owner_policy)
    @test resource_is_required(capacity_configuration.owner_policy)
    @test_throws ExecutionOwnerError ExecutionOwnerOverloadPolicy(
        RequiredResource(),
        FailRunOnOwnerOverload();
        maximum_lateness_ns=true,
        recovery_occupancy=0,
    )
    @test_throws ExecutionOwnerError ExecutionOwnerOverloadPolicy(
        RequiredResource(),
        FailRunOnOwnerOverload();
        maximum_lateness_ns=nothing,
        recovery_occupancy=true,
    )
    unsupported_owner_policy = ExecutionOwnerOverloadPolicy(
        RequiredResource(),
        ExecutionTestUnsupportedOverloadAction();
        maximum_lateness_ns=nothing,
        recovery_occupancy=0,
    )
    @test_throws ExecutionOwnerError ExecutionOwnerConfiguration(
        capacity_configuration.mode,
        capacity_configuration.cpu_budget,
        capacity_configuration.cpu_environment;
        owner_policy=unsupported_owner_policy,
    )
    duplicate_override = ExecutionOwnerPolicyOverride(
        ExecutionOwnerID(1), optional_owner_policy)
    one_override_configuration = ExecutionOwnerConfiguration(
        capacity_configuration.mode,
        capacity_configuration.cpu_budget,
        capacity_configuration.cpu_environment;
        owner_policy=capacity_configuration.owner_policy,
        owner_policy_overrides=(ExecutionOwnerPolicyOverride(
            ExecutionOwnerID(1),
            capacity_configuration.owner_policy,
        ),),
    )
    @test typeof(one_override_configuration) ===
        typeof(capacity_configuration)
    @test length(
        one_override_configuration.owner_policy_overrides) == 1
    @test_throws ExecutionOwnerError ExecutionOwnerConfiguration(
        capacity_configuration.mode,
        capacity_configuration.cpu_budget,
        capacity_configuration.cpu_environment;
        owner_policy=capacity_configuration.owner_policy,
        owner_policy_overrides=(
            duplicate_override,
            duplicate_override,
        ),
    )
    @test !applicable(
        ExecutionOwnerConfiguration,
        capacity_configuration.mode,
        capacity_configuration.cpu_budget,
        capacity_configuration.cpu_environment,
        1,
    )
    @test ExecutionOwnerConfiguration(
        capacity_configuration.mode,
        capacity_configuration.cpu_budget,
        capacity_configuration.cpu_environment;
        ring_capacity=2,
        owner_policy=capacity_configuration.owner_policy,
    ).ring_capacity == 2
    @test_throws ExecutionOwnerError ExecutionOwnerConfiguration(
        capacity_configuration.mode,
        capacity_configuration.cpu_budget,
        capacity_configuration.cpu_environment;
        ring_capacity=0,
        owner_policy=capacity_configuration.owner_policy,
    )
    @test_throws ExecutionOwnerError ExecutionOwnerConfiguration(
        capacity_configuration.mode,
        capacity_configuration.cpu_budget,
        capacity_configuration.cpu_environment;
        ring_capacity=true,
        owner_policy=capacity_configuration.owner_policy,
    )
    @test_throws ExecutionOwnerError ExecutionOwnerConfiguration(
        ExecutionTestUnsupportedMode(),
        capacity_configuration.cpu_budget,
        capacity_configuration.cpu_environment,
        owner_policy=capacity_configuration.owner_policy,
    )
    @test_throws ExecutionOwnerError ExecutionOwnerConfiguration(
        ThreadedExecutionOwners(ExecutionTestUnsupportedIdle()),
        capacity_configuration.cpu_budget,
        capacity_configuration.cpu_environment,
        owner_policy=capacity_configuration.owner_policy,
    )
    unsupported = execution_test_fixture()
    unsupported_error = captured_execution_test_error() do
        AdaptiveOpticsHIL.Execution._prepare_optical_execution(
            ExecutionTestUnsupportedConfiguration(),
            unsupported.prepared,
            unsupported.state,
            unsupported.workspace,
            RunSessionID(0x89df),
            EXECUTION_TEST_SHUTDOWN_POLICY,
        )
    end
    @test unsupported_error isa ExecutionOwnerError
    @test unsupported_error.reason ==
        :unsupported_execution_configuration
    unknown_policy_configuration =
        execution_test_owner_configuration(
            DeterministicExecutionOwners();
            owner_policy_overrides=(
                ExecutionOwnerPolicyOverride(
                    ExecutionOwnerID(4),
                    optional_owner_policy,
                ),
            ),
        )
    unknown_policy_error = captured_execution_test_error() do
        AdaptiveOpticsHIL.Execution._prepare_optical_execution(
            unknown_policy_configuration,
            unsupported.prepared,
            unsupported.state,
            unsupported.workspace,
            RunSessionID(0x89df),
            EXECUTION_TEST_SHUTDOWN_POLICY,
        )
    end
    @test unknown_policy_error isa ExecutionOwnerError
    @test unknown_policy_error.reason == :unknown_owner_policy
    invalid_recovery_policy = ExecutionOwnerOverloadPolicy(
        RequiredResource(),
        FailRunOnOwnerOverload();
        maximum_lateness_ns=nothing,
        recovery_occupancy=1,
    )
    invalid_recovery_configuration =
        execution_test_owner_configuration(
            DeterministicExecutionOwners();
            owner_policy=invalid_recovery_policy,
        )
    invalid_recovery_error = captured_execution_test_error() do
        AdaptiveOpticsHIL.Execution._prepare_optical_execution(
            invalid_recovery_configuration,
            unsupported.prepared,
            unsupported.state,
            unsupported.workspace,
            RunSessionID(0x89df),
            EXECUTION_TEST_SHUTDOWN_POLICY,
        )
    end
    @test invalid_recovery_error isa ExecutionOwnerError
    @test invalid_recovery_error.reason ==
        :invalid_recovery_occupancy
    deadline_probe_fixture = execution_test_fixture()
    deadline_probe_executor = prepare_execution_test_executor(
        deadline_probe_fixture,
        DeterministicExecutionOwners();
        outer_owner_count=1,
        session=RunSessionID(0x89e0),
        owner_policy=optional_owner_policy,
    )
    deadline_probe_owner = execution_owner(
        deadline_probe_executor, 1)
    @test resource_criticality(deadline_probe_owner) isa OptionalResource
    @test !resource_is_required(deadline_probe_owner)
    @test maximum_resource_lateness_ns(deadline_probe_owner) == 0
    @test overload_recovery_occupancy(deadline_probe_owner) == 0
    deadline_probe_clock = CachedNanoClock(0)
    deadline_probe_mapping = arm_execution_clock(
        deadline_probe_clock, PlantTimestamp(0))
    @test @inferred(
        AdaptiveOpticsHIL.Execution.
            _observe_execution_owner_deadline!(
                deadline_probe_executor,
                1,
                deadline_probe_mapping,
                PlantTimestamp(0),
            )) == false
    if EXECUTION_TESTS_WITH_COVERAGE
        @test_skip "owner deadline allocation gate disabled under coverage instrumentation"
    else
        execution_owner_deadline_allocations!(
            deadline_probe_executor,
            deadline_probe_mapping,
        )
        @test execution_owner_deadline_allocations!(
            deadline_probe_executor,
            deadline_probe_mapping,
        ) == 0
    end
    stop_execution_test_executor!(deadline_probe_executor)
    undersized = execution_test_fixture()
    undersized_configuration =
        execution_test_owner_configuration(
            ThreadedExecutionOwners();
            outer_owner_count=1,
        )
    undersized_error = captured_execution_test_error() do
        AdaptiveOpticsHIL.Execution._prepare_optical_execution(
            undersized_configuration,
            undersized.prepared,
            undersized.state,
            undersized.workspace,
            RunSessionID(0x89e1),
            EXECUTION_TEST_SHUTDOWN_POLICY,
        )
    end
    @test undersized_error isa ExecutionOwnerError
    @test undersized_error.reason == :cpu_owner_capacity

    missing = execution_test_fixture()
    missing_executor =
        AdaptiveOpticsHIL.Execution._prepare_optical_execution(
            execution_test_owner_configuration(
                DeterministicExecutionOwners()),
            missing.prepared,
            missing.state,
            missing.workspace,
            RunSessionID(0x89e2),
            EXECUTION_TEST_SHUTDOWN_POLICY,
        )
    missing_error = captured_execution_test_error() do
        AdaptiveOpticsHIL.Execution._take_expected_completion!(
            missing_executor,
            1,
            UInt64(0),
            AdaptiveOpticsHIL.Execution._ExecutionOwnerStartup,
        )
    end
    @test missing_error isa ExecutionOwnerError
    @test missing_error.reason ==
        :missing_deterministic_completion

    capacity = execution_test_fixture()
    capacity_executor = prepare_execution_test_executor(
        capacity,
        DeterministicExecutionOwners();
        outer_owner_count=1,
        session=RunSessionID(0x89e2),
    )
    capacity_claim = EXECUTION_TEST_PLANT.begin_optical_path_batch!(
        capacity.prepared,
        capacity.state,
        capacity.workspace,
        PlantTimestamp(0),
    )
    capacity_owner_count =
        AdaptiveOpticsHIL.Execution.
            _collect_due_execution_owners!(
                capacity_executor, capacity_claim)
    capacity_owner_ordinal = Int(
        capacity_executor.coordinator_workspace.
            due_owner_ordinals[1])
    capacity_owner =
        execution_owner(
            capacity_executor, capacity_owner_ordinal)
    work_type =
        AdaptiveOpticsHIL.Execution.
            _ExecutionOwnerWorkDescriptor
    occupied_work = work_type(
        capacity_executor.session,
        execution_owner_id(capacity_owner),
        UInt64(1),
        AdaptiveOpticsHIL.Execution.
            _ExecutionOwnerMaterialization,
        capacity_claim,
    )
    @test try_submit!(
        capacity_owner.due, occupied_work) ==
        RingTransferSucceeded
    capacity_error = captured_execution_test_error() do
        AdaptiveOpticsHIL.Execution._submit_owner_phase!(
            capacity_executor,
            capacity_claim,
            UInt64(1),
            capacity_owner_count,
            AdaptiveOpticsHIL.Execution.
                _ExecutionOwnerMaterialization,
        )
    end
    @test capacity_error isa ExecutionOwnerError
    @test capacity_error.reason == :due_work_publication
    capacity_accounting = execution_owner_accounting(
        capacity_executor, capacity_owner_ordinal)
    @test capacity_accounting.overload_policy.criticality isa
        RequiredResource
    @test capacity_accounting.overload_episodes == 1
    @test capacity_accounting.maximum_due_occupancy == 1
    @test capacity_accounting.overload_decision ==
        ExecutionOwnerFailedForCapacity
    occupied_scratch = Ref{work_type}()
    @test try_take!(
        occupied_scratch, capacity_owner.due) ==
        RingTransferSucceeded
    @test try_submit!(
        capacity_owner.due, occupied_work) ==
        RingTransferSucceeded
    AdaptiveOpticsHIL.Execution._drain_cancelled_owner_work!(
        capacity_executor, capacity_owner_ordinal)
    @test execution_owner_accounting(
        capacity_executor,
        capacity_owner_ordinal).work_cancelled == 1
    completion_type =
        AdaptiveOpticsHIL.Execution._ExecutionOwnerCompletion
    injected_completion = completion_type(
        capacity_executor.session,
        execution_owner_id(capacity_owner),
        UInt64(1),
        AdaptiveOpticsHIL.Execution._ExecutionOwnerMaterialization,
        AdaptiveOpticsHIL.Execution._ExecutionOwnerWorkCompleted,
    )
    @test try_submit!(
        capacity_owner.completion, injected_completion) ==
        RingTransferSucceeded
    AdaptiveOpticsHIL.Execution._drain_execution_owner_completions!(
        capacity_executor, capacity_owner_ordinal)
    @test capacity_executor.coordinator.completions[
        capacity_owner_ordinal] == 1
    capacity_executor.coordinator.completions[
        capacity_owner_ordinal] = 0
    @test execution_owners_are_quiescent(capacity_executor)
    stop_execution_test_executor!(capacity_executor)
    @test AdaptiveOpticsHIL.Execution.
        _execution_owner_stops_are_acknowledged(capacity_executor)

    materialization_failure =
        ArgumentError("test owner materialization failure")
    failing_materialization = execution_test_fixture(
        path_probes=(
            ExecutionMaterializationFailureProbe(
                materialization_failure),
            nothing,
            nothing,
        ),
    )
    materialization_executor = prepare_execution_test_executor(
        failing_materialization,
        DeterministicExecutionOwners();
        outer_owner_count=1,
        session=RunSessionID(0x89e3),
    )
    observed_materialization_failure =
        captured_execution_test_error() do
            execute_execution_test_batch!(
                failing_materialization,
                materialization_executor)
        end
    @test observed_materialization_failure ===
        materialization_failure
    materialization_record = first_run_failure(
        materialization_executor.failures)
    @test run_failure_stage(materialization_record) ==
        OwnerMaterialization
    @test run_failure_kind(materialization_record) ==
        OwnerExceptionRunFailure
    @test !AdaptiveOpticsHIL.Execution._execution_batch_active(
        materialization_executor)
    finish_execution_failure_shutdown!(materialization_executor)
    @test AdaptiveOpticsHIL.Execution.
        _execution_ownership_is_drained(materialization_executor)

    owner_failure = ArgumentError("test execution-owner model failure")
    failing = execution_test_fixture(
        path_probes=(
            ExecutionFailureProbe(owner_failure),
            nothing,
            nothing,
        ),
    )
    failing_executor = prepare_execution_test_executor(
        failing,
        DeterministicExecutionOwners();
        outer_owner_count=1,
        session=RunSessionID(0x89e4),
    )
    observed_failure = captured_execution_test_error() do
        execute_execution_test_batch!(failing, failing_executor)
    end
    @test observed_failure === owner_failure
    @test count(
        ordinal -> execution_owner_accounting(
            failing_executor, ordinal).failed,
        1:execution_owner_count(failing_executor),
    ) == 1
    @test !execution_owners_are_quiescent(failing_executor)
    @test !AdaptiveOpticsHIL.Execution._execution_batch_active(
        failing_executor)
    failing_record = first_run_failure(
        failing_executor.failures)
    @test run_failure_kind(failing_record) ==
        OwnerExceptionRunFailure
    @test run_failure_stage(failing_record) == OwnerExecution
    @test run_owner_component(
        run_failure_owner(failing_record)) ==
        :path_execution_owner
    AdaptiveOpticsHIL.Execution._mark_optical_execution_failed!(
        failing_executor)
    @test execution_owners_phase(failing_executor) ==
        ExecutionOwnersFailed
    AdaptiveOpticsHIL.Lifecycle._begin_run_shutdown!(
        failing_executor.failures, 0)
    AdaptiveOpticsHIL.Execution.
        _begin_optical_execution_shutdown!(failing_executor)
    @test AdaptiveOpticsHIL.Execution.
        _progress_optical_execution_shutdown!(failing_executor)
    AdaptiveOpticsHIL.Execution.
        _finalize_optical_execution_shutdown!(failing_executor)
    @test execution_owners_phase(failing_executor) ==
        ExecutionOwnersFailed
    @test AdaptiveOpticsHIL.Execution.
        _execution_ownership_is_drained(failing_executor)

    if Threads.nthreads() < 4
        @test_skip "before-dequeue owner fault requires four Julia threads"
        @test_skip "after-dequeue owner fault requires four Julia threads"
    else
        before_dequeue_failure =
            ErrorException("test failure before owner dequeue")
        before_dequeue = execution_test_fixture()
        before_dequeue_executor = prepare_execution_test_executor(
            before_dequeue,
            ThreadedExecutionOwners(
                ExecutionBeforeDequeueFailureIdle(
                    before_dequeue_failure));
            outer_owner_count=3,
            session=RunSessionID(0x89e5),
        )
        before_dequeue_record = wait_for_execution_failure_record(
            before_dequeue_executor)
        @test run_failure_stage(before_dequeue_record) ==
            OwnerBeforeDequeue
        @test run_failure_kind(before_dequeue_record) ==
            OwnerExceptionRunFailure
        @test run_owner_component(
            run_failure_owner(before_dequeue_record)) ==
            :path_execution_owner
        finish_execution_failure_shutdown!(before_dequeue_executor)
        @test AdaptiveOpticsHIL.Execution.
            _execution_ownership_is_drained(before_dequeue_executor)

        after_dequeue = execution_test_fixture()
        after_dequeue_executor = prepare_execution_test_executor(
            after_dequeue,
            ThreadedExecutionOwners();
            outer_owner_count=3,
            session=RunSessionID(0x89e6),
        )
        after_dequeue_executor.owner_states[1].activity =
            AdaptiveOpticsHIL.Execution._ExecutionOwnerStoppedActivity
        after_dequeue_error = captured_execution_test_error() do
            execute_execution_test_batch!(
                after_dequeue, after_dequeue_executor)
        end
        @test after_dequeue_error isa ExecutionOwnerError
        after_dequeue_record = wait_for_execution_failure_record(
            after_dequeue_executor)
        @test run_failure_stage(after_dequeue_record) ==
            OwnerAfterDequeue
        @test run_owner_ordinal(
            run_failure_owner(after_dequeue_record)) == 1
        after_dequeue_accounting = execution_owner_accounting(
            after_dequeue_executor, 1)
        @test after_dequeue_accounting.work_submitted == 1
        @test after_dequeue_accounting.work_taken == 0
        @test after_dequeue_accounting.work_cancelled == 0
        @test AdaptiveOpticsHIL.Execution._execution_batch_active(
            after_dequeue_executor)
        finish_execution_failure_shutdown!(after_dequeue_executor)
        @test !AdaptiveOpticsHIL.Execution.
            _execution_ownership_is_drained(after_dequeue_executor)
        @test AdaptiveOpticsHIL.Execution._execution_batch_active(
            after_dequeue_executor)
    end

    publication_failure = execution_test_fixture()
    publication_executor = prepare_execution_test_executor(
        publication_failure,
        DeterministicExecutionOwners();
        outer_owner_count=1,
        session=RunSessionID(0x89e7),
    )
    publication_owner = execution_owner(
        publication_executor, 1)
    close_ring!(publication_owner.completion)
    publication_error = captured_execution_test_error() do
        execute_execution_test_batch!(
            publication_failure, publication_executor)
    end
    @test publication_error isa ExecutionOwnerError
    @test publication_error.reason == :completion_publication
    publication_record = first_run_failure(
        publication_executor.failures)
    @test run_failure_stage(publication_record) ==
        OwnerCompletionPublication
    @test run_failure_reason(publication_record) ==
        :completion_publication
    publication_accounting =
        execution_owner_accounting(publication_executor, 1)
    @test publication_accounting.work_completed == 1
    @test publication_accounting.completions_taken == 0
    @test publication_accounting.failed
    @test AdaptiveOpticsHIL.Execution._execution_batch_active(
        publication_executor)

    if Threads.nthreads() < 4
        @test_skip "threaded stop-publication fault requires four Julia threads"
    else
        stop_publication_failure = execution_test_fixture()
        stop_publication_executor = prepare_execution_test_executor(
            stop_publication_failure,
            ThreadedExecutionOwners();
            outer_owner_count=3,
            session=RunSessionID(0x89e9),
        )
        stop_publication_owner = execution_owner(
            stop_publication_executor, 1)
        close_ring!(stop_publication_owner.completion)
        AdaptiveOpticsHIL.Lifecycle._begin_run_shutdown!(
            stop_publication_executor.failures, 0)
        AdaptiveOpticsHIL.Execution._begin_optical_execution_shutdown!(
            stop_publication_executor)
        stop_publication_record = wait_for_execution_failure_record(
            stop_publication_executor)
        @test run_failure_stage(stop_publication_record) ==
            OwnerCompletionPublication
        @test run_failure_reason(stop_publication_record) ==
            :completion_publication
        finish_execution_failure_shutdown!(stop_publication_executor)
    end

    device_failure = execution_test_fixture(
        device_batch_selection=Val(:all),
        batchable=true)
    device_failure_executor = prepare_execution_test_executor(
        device_failure,
        DeterministicExecutionOwners();
        outer_owner_count=1,
        session=RunSessionID(0x89e8),
    )
    device_claim = EXECUTION_TEST_PLANT.begin_optical_path_batch!(
        device_failure.prepared,
        device_failure.state,
        device_failure.workspace,
        PlantTimestamp(0))
    device_failure_executor.coordinator.active_claim = device_claim
    device_owner_count = AdaptiveOpticsHIL.Execution.
        _collect_due_execution_owners!(
            device_failure_executor, device_claim)
    device_batch_sequence = AdaptiveOpticsHIL.Execution.
        _next_batch_sequence!(device_failure_executor)
    AdaptiveOpticsHIL.Execution._submit_owner_phase!(
        device_failure_executor,
        device_claim,
        device_batch_sequence,
        device_owner_count,
        AdaptiveOpticsHIL.Execution._ExecutionOwnerMaterialization)
    AdaptiveOpticsHIL.Execution._collect_owner_phase!(
        device_failure_executor,
        device_batch_sequence,
        device_owner_count,
        AdaptiveOpticsHIL.Execution._ExecutionOwnerMaterialization,
        nothing,
        PlantTimestamp(0))
    EXECUTION_TEST_PLANT.seal_optical_path_batch_materialization!(
        device_failure.prepared,
        device_failure.state,
        device_failure.workspace,
        device_claim)
    original_device_owner = execution_owner(
        device_failure_executor, 1)
    device_failure_executor.owners[1] = PreparedExecutionOwner(
        original_device_owner.id,
        original_device_owner.kind,
        typemax(UInt32),
        original_device_owner.group_ordinals,
        AdaptiveOpticsSim.CUDABackend(),
        original_device_owner.compute_device,
        original_device_owner.overload_policy,
        original_device_owner.deadline,
        original_device_owner.due,
        original_device_owner.completion)
    AdaptiveOpticsHIL.Execution._submit_owner_phase!(
        device_failure_executor,
        device_claim,
        device_batch_sequence,
        device_owner_count,
        AdaptiveOpticsHIL.Execution._ExecutionOwnerExecution)
    observed_device_failure = captured_execution_test_error() do
        AdaptiveOpticsHIL.Execution._collect_owner_phase!(
            device_failure_executor,
            device_batch_sequence,
            device_owner_count,
            AdaptiveOpticsHIL.Execution._ExecutionOwnerExecution,
            nothing,
            PlantTimestamp(0))
    end
    @test observed_device_failure isa BoundsError
    device_record = first_run_failure(
        device_failure_executor.failures)
    @test run_failure_kind(device_record) == DeviceRunFailure
    @test run_failure_stage(device_record) ==
        OwnerDeviceCompletion
    @test run_owner_component(
        run_failure_owner(device_record)) ==
        :device_submission_owner
    @test AdaptiveOpticsHIL.Execution.
        _abandon_failed_optical_path_batch!(
            device_failure_executor)
    finish_execution_failure_shutdown!(device_failure_executor)

    if EXECUTION_TESTS_WITH_COVERAGE
        @test_skip "execution-owner allocation gate disabled under coverage instrumentation"
    else
        warm_serial = execution_test_fixture()
        execution_test_batch_allocations(
            warm_serial,
            EXECUTION_TEST_PLANT.SerialOpticalPathBatchExecutor(),
        )
        warm_owned = execution_test_fixture()
        warm_executor = prepare_execution_test_executor(
            warm_owned,
            DeterministicExecutionOwners();
            outer_owner_count=1,
            session=RunSessionID(0x89f0),
        )
        execution_test_batch_allocations(
            warm_owned, warm_executor)
        stop_execution_test_executor!(warm_executor)
        inferred_owned = execution_test_fixture()
        inferred_executor = prepare_execution_test_executor(
            inferred_owned,
            DeterministicExecutionOwners();
            outer_owner_count=1,
            session=RunSessionID(0x89f1),
        )
        @test @inferred(execute_execution_test_batch!(
            inferred_owned, inferred_executor)) == PlantTimestamp(0)
        stop_execution_test_executor!(inferred_executor)

        measured_serial = execution_test_fixture()
        serial_bytes = execution_test_batch_allocations(
            measured_serial,
            EXECUTION_TEST_PLANT.SerialOpticalPathBatchExecutor(),
        )
        measured_owned = execution_test_fixture()
        measured_executor = prepare_execution_test_executor(
            measured_owned,
            DeterministicExecutionOwners();
            outer_owner_count=1,
            session=RunSessionID(0x89f2),
        )
        owned_bytes = execution_test_batch_allocations(
            measured_owned, measured_executor)
        # The core's heterogeneous full-optical group calls retain their
        # existing ceiling; owner descriptors, SPSC transfers, barriers, and
        # accounting add no warmed coordinator-side allocation.
        @test serial_bytes <=
            EXECUTION_TEST_BATCH_ALLOCATION_BUDGET
        @test owned_bytes <=
            EXECUTION_TEST_BATCH_ALLOCATION_BUDGET
        @test owned_bytes == serial_bytes
        stop_execution_test_executor!(measured_executor)
    end

    serial = execution_test_fixture()
    deterministic = execution_test_fixture()
    executor = prepare_execution_test_executor(
        deterministic,
        DeterministicExecutionOwners(alternate_order=true);
        outer_owner_count=1,
    )
    @test execution_owner_count(executor) == 3
    @test all(
        ordinal -> execution_owner_kind(
            execution_owner(executor, ordinal)) ==
            PathGroupExecutionOwner,
        1:3,
    )
    horizon = PlantTimestamp(800_000_000)
    serial_count = run_plant_events_until!(
        serial.prepared,
        serial.state,
        serial.workspace,
        horizon,
    )
    deterministic_count = run_plant_events_until!(
        deterministic.prepared,
        deterministic.state,
        deterministic.workspace,
        horizon,
        executor,
    )
    @test deterministic_count == serial_count
    compare_execution_test_runs(serial, deterministic)
    for ordinal in 1:execution_owner_count(executor)
        accounting = execution_owner_accounting(executor, ordinal)
        @test accounting.work_submitted > 0
        @test accounting.work_submitted == accounting.work_taken
        @test accounting.work_taken == accounting.work_completed
        @test accounting.work_completed == accounting.completions_taken
        @test !accounting.startup_acknowledged
        @test !accounting.failed
    end
    foreign = execution_test_fixture()
    foreign_error = captured_execution_test_error() do
        EXECUTION_TEST_PLANT.execute_optical_path_batch!(
            executor,
            foreign.prepared,
            foreign.state,
            foreign.workspace,
            PlantTimestamp(0),
        )
    end
    @test foreign_error isa ExecutionOwnerError
    @test foreign_error.reason == :foreign_prepared_plant
    stop_execution_test_executor!(executor)
    stopped_error = captured_execution_test_error() do
        EXECUTION_TEST_PLANT.execute_optical_path_batch!(
            executor,
            deterministic.prepared,
            deterministic.state,
            deterministic.workspace,
            PlantTimestamp(900_000_000),
        )
    end
    @test stopped_error isa ExecutionOwnerError
    @test stopped_error.reason == :invalid_phase

    serial_batch = execution_test_fixture(; batchable=true)
    owned_batch = execution_test_fixture(
        device_batch_selection=Val(:all),
        batchable=true,
    )
    batch_executor = prepare_execution_test_executor(
        owned_batch,
        DeterministicExecutionOwners();
        outer_owner_count=1,
        session=RunSessionID(0x8a01),
    )
    @test execution_owner_count(batch_executor) == 1
    batch_owner = execution_owner(batch_executor, 1)
    @test execution_owner_kind(batch_owner) ==
        DeviceBatchExecutionOwner
    @test execution_owner_group_count(batch_owner) == 3
    @test Tuple(execution_owner_group_ordinal(
        batch_owner, index) for index in 1:3) == (1, 2, 3)
    serial_batch_count = run_plant_events_until!(
        serial_batch.prepared,
        serial_batch.state,
        serial_batch.workspace,
        horizon,
    )
    owned_batch_count = run_plant_events_until!(
        owned_batch.prepared,
        owned_batch.state,
        owned_batch.workspace,
        horizon,
        batch_executor,
    )
    @test owned_batch_count == serial_batch_count
    compare_execution_test_runs(serial_batch, owned_batch)
    stop_execution_test_executor!(batch_executor)

    if Threads.nthreads() < 4
        @test_skip "three overlapping owners require four Julia threads"
    else
        backpressure = execution_test_fixture()
        backpressure_executor =
            AdaptiveOpticsHIL.Execution._prepare_optical_execution(
                execution_test_owner_configuration(
                    ThreadedExecutionOwners();
                    outer_owner_count=3,
                ),
                backpressure.prepared,
                backpressure.state,
                backpressure.workspace,
                RunSessionID(0x8a01),
                EXECUTION_TEST_SHUTDOWN_POLICY,
            )
        backpressure_owner =
            execution_owner(backpressure_executor, 1)
        completion_type =
            AdaptiveOpticsHIL.Execution._ExecutionOwnerCompletion
        startup_completion = completion_type(
            backpressure_executor.session,
            execution_owner_id(backpressure_owner),
            UInt64(0),
            AdaptiveOpticsHIL.Execution._ExecutionOwnerStartup,
            AdaptiveOpticsHIL.Execution._ExecutionOwnerWorkCompleted,
        )
        @test try_submit!(
            backpressure_owner.completion,
            startup_completion,
        ) == RingTransferSucceeded
        completion_ref = Ref{typeof(startup_completion)}()
        completion_consumer = @async begin
            @test try_take!(
                completion_ref,
                backpressure_owner.completion,
            ) == RingTransferSucceeded
        end
        AdaptiveOpticsHIL.Execution._submit_completion!(
            backpressure_executor,
            backpressure_owner,
            startup_completion,
        )
        wait(completion_consumer)
        @test completion_ref[] == startup_completion
        @test try_take!(
            completion_ref,
            backpressure_owner.completion,
        ) == RingTransferSucceeded

        threaded_serial = execution_test_fixture()
        probe = ExecutionConcurrencyProbe(3)
        threaded = execution_test_fixture(; probe)
        threaded_executor = prepare_execution_test_executor(
            threaded,
            ThreadedExecutionOwners(HybridExecutionOwnerIdle(32));
            outer_owner_count=3,
            session=RunSessionID(0x8a02),
        )
        initial_task_ids = Tuple(
            execution_owner_accounting(
                threaded_executor, ordinal).task_id
            for ordinal in 1:3
        )
        @test execution_owner_idle_policy(
            threaded_executor).spin_count == 32
        threaded_serial_count = run_plant_events_until!(
            threaded_serial.prepared,
            threaded_serial.state,
            threaded_serial.workspace,
            horizon,
        )
        threaded_count = run_plant_events_until!(
            threaded.prepared,
            threaded.state,
            threaded.workspace,
            horizon,
            threaded_executor,
        )
        @test threaded_count == threaded_serial_count
        compare_execution_test_runs(threaded_serial, threaded)
        @test probe.arrivals[] >= 3
        @test all(!iszero, probe.thread_ids)
        @test length(unique(collect(probe.thread_ids))) == 3
        task_ids = UInt[]
        for ordinal in 1:3
            accounting =
                execution_owner_accounting(threaded_executor, ordinal)
            @test accounting.startup_acknowledged
            @test !iszero(accounting.task_id)
            @test accounting.work_submitted ==
                accounting.work_completed
            push!(task_ids, accounting.task_id)
        end
        @test length(unique(task_ids)) == 3
        @test Tuple(task_ids) == initial_task_ids
        stop_execution_test_executor!(threaded_executor)
        @test all(
            ordinal -> execution_owner_accounting(
                threaded_executor, ordinal).stop_acknowledged,
            1:3,
        )

        independence_state = ExecutionIndependenceState()
        independent = execution_test_fixture(
            path_probes=(
                ExecutionOptionalScienceStall(independence_state),
                ExecutionRequiredWFSCompletion(independence_state),
                nothing,
            ),
        )
        independent_executor = prepare_execution_test_executor(
            independent,
            ThreadedExecutionOwners();
            outer_owner_count=3,
            session=RunSessionID(0x8a03),
        )
        @test execution_owner_group_ordinal(
            execution_owner(independent_executor, 1), 1) == 1
        @test execution_owner_group_ordinal(
            execution_owner(independent_executor, 2), 1) == 2
        @test execute_execution_test_batch!(
            independent, independent_executor) == PlantTimestamp(0)
        @test independence_state.science_started[]
        @test independence_state.required_wfs_completed[]
        @test independence_state.science_released[]
        stop_execution_test_executor!(independent_executor)

        deadline_clock = CachedNanoClock(0)
        deadline_state = ExecutionIndependenceState()
        deadline_fixture = execution_test_fixture(
            path_probes=(
                ExecutionOptionalScienceDeadlineStall(
                    deadline_state, deadline_clock),
                ExecutionRequiredWFSCompletion(deadline_state),
                nothing,
            ),
        )
        optional_deadline_policy = ExecutionOwnerOverloadPolicy(
            OptionalResource(),
            FailRunOnOwnerOverload();
            maximum_lateness_ns=0,
            recovery_occupancy=0,
        )
        deadline_executor = prepare_execution_test_executor(
            deadline_fixture,
            ThreadedExecutionOwners();
            outer_owner_count=3,
            session=RunSessionID(0x8a04),
            owner_policy_overrides=(
                ExecutionOwnerPolicyOverride(
                    ExecutionOwnerID(3),
                    optional_deadline_policy,
                ),
            ),
        )
        deadline_mapping = arm_execution_clock(
            deadline_clock, PlantTimestamp(0))
        deadline_runtime =
            AdaptiveOpticsHIL.Execution.
                _bind_optical_execution_timing(
                    deadline_executor, deadline_mapping)
        deadline_error = captured_execution_test_error() do
            execute_execution_test_batch!(
                deadline_fixture, deadline_runtime)
        end
        @test deadline_error isa ExecutionOwnerError
        @test deadline_error.reason == :owner_deadline_exceeded
        @test deadline_state.science_started[]
        @test deadline_state.required_wfs_completed[]
        @test deadline_state.science_released[]
        settle_execution_test_owner_completions!(
            deadline_executor)
        optional_accounting =
            execution_owner_accounting(deadline_executor, 3)
        @test optional_accounting.overload_policy ===
            optional_deadline_policy
        @test optional_accounting.overload_episodes == 1
        @test optional_accounting.recovery_count == 0
        @test optional_accounting.latest_lateness_ns == 1
        @test optional_accounting.maximum_lateness_ns == 1
        @test optional_accounting.overloaded
        @test !optional_accounting.recovered_to_threshold
        @test optional_accounting.overload_decision ==
            ExecutionOwnerFailedForDeadline
        @test optional_accounting.current_due_occupancy == 0
        @test optional_accounting.current_completion_occupancy == 0
        @test optional_accounting.maximum_due_occupancy == 1
        @test optional_accounting.maximum_completion_occupancy == 1
        required_accounting =
            execution_owner_accounting(deadline_executor, 2)
        @test required_accounting.work_completed == 2
        @test !required_accounting.overloaded
        @test execution_owners_are_quiescent(deadline_executor)
        stop_execution_test_executor!(deadline_executor)
    end
end
