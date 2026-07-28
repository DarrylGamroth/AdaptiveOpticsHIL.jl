using AdaptiveOpticsHIL.Lifecycle
using AdaptiveOpticsHIL.Execution
using AdaptiveOpticsHIL.Ownership
using AdaptiveOpticsHIL.Ports
using AdaptiveOpticsHIL.Serial
using AdaptiveOpticsHIL.Timing: ExecutionClockID
using AdaptiveOpticsHIL.Timing: execution_clock_identity
using AdaptiveOpticsHIL.Timing: execution_clock_origin_ns
using AdaptiveOpticsHIL.Ports: command_bridge_event_loop
using AdaptiveOpticsSim
using AdaptiveOpticsSim.Plant
using AdaptiveOpticsSim.Plant: AbsoluteCommand, ClipInvalidCommand
using AdaptiveOpticsSim.Plant: AllPathVisibility
using AdaptiveOpticsSim.Plant: ColdPlantModelDefinition
using AdaptiveOpticsSim.Plant: CommandEffectiveTimePolicy
using AdaptiveOpticsSim.Plant: CommandSequencePolicy
using AdaptiveOpticsSim.Plant: CommandSilencePolicy, CommandValuePolicy
using AdaptiveOpticsSim.Plant: EnforceOnApplication
using AdaptiveOpticsSim.Plant: PreservePendingCommands
using AdaptiveOpticsSim.Plant: PlantEventLoopState
using AdaptiveOpticsSim.Plant: PreparedPathExecutor
using AdaptiveOpticsSim.Plant: PupilPlanePlacement
using AdaptiveOpticsSim.Plant: UniformCommandBounds
using AdaptiveOpticsSim.Plant: acquisition_products
using AdaptiveOpticsSim.Plant: command_basis, command_basis_revision
using AdaptiveOpticsSim.Plant: command_dimensions, command_endpoint_id
using AdaptiveOpticsSim.Plant: command_schemas, command_sign_convention
using AdaptiveOpticsSim.Plant: command_units
using AdaptiveOpticsSim.Plant: prepare_pupil_opd_materialization
using AdaptiveOpticsSim.Plant: prepared_acquisition
using AdaptiveOpticsSim.Plant: prepared_command_endpoint
using Clocks
using LinearAlgebra: BLAS

const SERIAL_TEST_PLANT = AdaptiveOpticsSim.Plant
const SERIAL_TESTS_WITH_COVERAGE =
    Base.JLOptions().code_coverage != 0
const SERIAL_IDENTITY_2X2 = [1.0 0.0; 0.0 1.0]
const SERIAL_DUE_STEP_ALLOCATION_BUDGET = 2_048
const SERIAL_COMMAND_STEP_ALLOCATION_BUDGET = 2_048
const SERIAL_TEST_SHUTDOWN_POLICY = RunShutdownPolicy(
    acknowledgement_timeout_ns=1_000_000_000,
    drain_timeout_ns=2_000_000_000)

struct SerialTestLifecycleFailureConfiguration <:
    AbstractOpticalExecutionConfiguration
    phase::Symbol
    failure::ExecutionOwnerError
end

mutable struct SerialTestLifecycleFailureExecutor <:
    AdaptiveOpticsSim.Plant.AbstractOpticalPathBatchExecutor
    configuration::SerialTestLifecycleFailureConfiguration
    armed::Bool
    failed::Bool
    shutdown_progress_count::Int
end

function AdaptiveOpticsHIL.Execution._prepare_optical_execution(
    configuration::SerialTestLifecycleFailureConfiguration,
    ::AdaptiveOpticsSim.Plant.PreparedPlantEventLoop,
    ::AdaptiveOpticsSim.Plant.PlantEventLoopState,
    ::AdaptiveOpticsSim.Plant.PlantEventLoopWorkspace,
    ::RunSessionID,
    ::RunShutdownPolicy,
)
    return SerialTestLifecycleFailureExecutor(
        configuration, false, false, 0)
end

AdaptiveOpticsHIL.Execution._execution_is_quiescent(
    ::SerialTestLifecycleFailureExecutor) = true
AdaptiveOpticsHIL.Execution._execution_accounting(
    ::SerialTestLifecycleFailureExecutor) = nothing
AdaptiveOpticsHIL.Execution._execution_is_armed(
    executor::SerialTestLifecycleFailureExecutor) = executor.armed

function AdaptiveOpticsHIL.Execution._arm_optical_execution!(
    executor::SerialTestLifecycleFailureExecutor,
)
    executor.configuration.phase == :arm &&
        throw(executor.configuration.failure)
    executor.armed = true
    return executor
end

function AdaptiveOpticsHIL.Execution._start_optical_execution!(
    executor::SerialTestLifecycleFailureExecutor,
)
    executor.configuration.phase == :start &&
        throw(executor.configuration.failure)
    return executor
end

AdaptiveOpticsHIL.Execution._stop_optical_execution!(
    executor::SerialTestLifecycleFailureExecutor) = executor

function AdaptiveOpticsHIL.Execution._progress_optical_execution_shutdown!(
    executor::SerialTestLifecycleFailureExecutor)
    executor.shutdown_progress_count += 1
    return executor.shutdown_progress_count > 1
end

function AdaptiveOpticsHIL.Execution._mark_optical_execution_failed!(
    executor::SerialTestLifecycleFailureExecutor,
)
    executor.failed = true
    return executor
end

function serial_test_execution_owner_configuration(
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
    budget = SERIAL_TEST_PLANT.grouped_cpu_execution_budget(
        cpu_context_count=contexts,
        julia_thread_count=julia_threads,
        outer_owner_count=outer_owner_count,
        group_julia_thread_count=1,
        fft_thread_count=fft_threads,
        blas_thread_count=blas_threads,
    )
    environment = SERIAL_TEST_PLANT.CPUExecutionEnvironment(
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

mutable struct MutableIdentityNanoClock <: Clocks.AbstractNanoClock
    value::Int64
    identity::ExecutionClockID
end

Clocks.time_nanos(clock::MutableIdentityNanoClock) = clock.value
AdaptiveOpticsHIL.Timing.execution_clock_identity(
    clock::MutableIdentityNanoClock) = clock.identity

mutable struct ToggleReadingNanoClock <: Clocks.AbstractNanoClock
    value::Int64
    invalid::Bool
end

Clocks.time_nanos(clock::ToggleReadingNanoClock) =
    clock.invalid ? Int32(0) : clock.value
AdaptiveOpticsHIL.Timing.execution_clock_identity(
    ::ToggleReadingNanoClock) =
    ExecutionClockID(:toggle_reading_test_clock)

struct HILReducedOrderPathModel end
struct HILReducedOrderOpticModel end

struct HILReducedOrderPathExecution{E}
    imaging::E
end

struct PreparedHILReducedOrderOptic
    endpoint::CommandEndpointID
    command_count::Int
end

mutable struct HILReducedOrderOpticState{V<:AbstractVector}
    visible::V
end

mutable struct HILReducedOrderOpticWorkspace{V<:AbstractVector}
    staged::V
end

SERIAL_TEST_PLANT.plant_model_definition_style(
    ::Type{HILReducedOrderPathModel}) = ColdPlantModelDefinition()
SERIAL_TEST_PLANT.plant_model_definition_style(
    ::Type{HILReducedOrderOpticModel}) = ColdPlantModelDefinition()

function SERIAL_TEST_PLANT.validate_path_execution_binding(
    execution::HILReducedOrderPathExecution, input, result)
    return SERIAL_TEST_PLANT.validate_path_execution_binding(
        execution.imaging, input, result)
end

function SERIAL_TEST_PLANT.execute_path!(
    result, input, execution::HILReducedOrderPathExecution)
    return SERIAL_TEST_PLANT.execute_path!(
        result, input, execution.imaging)
end

function SERIAL_TEST_PLANT.prepare_path_executor(
    ::HILReducedOrderPathModel,
    definition::OpticalPathDefinition,
    source::AdaptiveOpticsSim.AbstractSource,
    telescope::Telescope,
    atmosphere::AdaptiveOpticsSim.AbstractTimedAtmosphere)
    T = eltype(pupil_reflectivity(telescope))
    pupil = PupilFunction(telescope; T, backend=backend(telescope))
    imaging = prepare_direct_imaging(pupil, source; zero_padding=1)
    return PreparedPathExecutor(
        definition,
        source,
        telescope,
        atmosphere,
        pupil,
        direct_imaging_output(imaging),
        HILReducedOrderPathExecution(imaging);
        materialization=prepare_pupil_opd_materialization(
            atmosphere, telescope, source, pupil),
        optical_model=:hil_reduced_order_unused_direct_imaging,
        propagation_model=:fraunhofer_fft,
        model_revisions=UInt(1))
end

function SERIAL_TEST_PLANT.prepare_controllable_optic(
    ::HILReducedOrderOpticModel,
    definition::ControllableOpticDefinition,
    ::Telescope,
    ::AdaptiveOpticsSim.AbstractAtmosphere)
    schema = only(command_schemas(definition))
    dimensions = command_dimensions(schema)
    length(dimensions) == 1 || throw(PlantPreparationError(
        :controllable_optic, :invalid_dimensions,
        "HIL reduced-order test optic requires a vector command"))
    return PreparedHILReducedOrderOptic(
        command_endpoint_id(schema), only(dimensions))
end

function SERIAL_TEST_PLANT.prepare_controllable_optic_state(
    prepared::PreparedHILReducedOrderOptic,
    ::ControllableOpticDefinition,
    endpoint_ids::Tuple,
    initial_commands::Tuple)
    only(endpoint_ids) == prepared.endpoint || throw(PlantPreparationError(
        :controllable_optic, :prepared_binding,
        "HIL reduced-order test optic endpoint changed"))
    initial = only(initial_commands)
    length(initial) == prepared.command_count || throw(
        PlantPreparationError(
            :controllable_optic, :prepared_binding,
            "HIL reduced-order test optic command shape changed"))
    return HILReducedOrderOpticState(initial)
end

function SERIAL_TEST_PLANT.prepare_controllable_optic_workspace(
    prepared::PreparedHILReducedOrderOptic)
    return HILReducedOrderOpticWorkspace(
        zeros(Float64, prepared.command_count))
end

function SERIAL_TEST_PLANT.stage_controllable_optic_command!(
    prepared::PreparedHILReducedOrderOptic,
    ::HILReducedOrderOpticState,
    workspace::HILReducedOrderOpticWorkspace,
    endpoint::CommandEndpointID,
    command::AbstractVector,
    ::PlantTimestamp)
    endpoint == prepared.endpoint || throw(PlantCommandError(
        :physical_application, :endpoint_mismatch,
        "HIL reduced-order test optic received another endpoint"))
    copyto!(workspace.staged, command)
    return nothing
end

function SERIAL_TEST_PLANT.commit_controllable_optic_command!(
    ::PreparedHILReducedOrderOptic,
    state::HILReducedOrderOpticState,
    workspace::HILReducedOrderOpticWorkspace,
    ::CommandEndpointID,
    ::PlantTimestamp)
    copyto!(state.visible, workspace.staged)
    return nothing
end

function serial_test_schema(; dimensions=(2,))
    T = Float64
    endpoint = :hil_dm
    return PlantCommandSchema(
        T,
        dimensions;
        id=:hil_dm_schema,
        version=1,
        endpoint,
        units=:metre,
        sign_convention=:positive_command_increases_residual,
        basis=CommandBasis(:modal, endpoint),
        basis_revision=1,
        semantics=AbsoluteCommand,
        bounds=UniformCommandBounds(T(-20), T(20)),
        value_policy=CommandValuePolicy(
            range_stage=EnforceOnApplication,
            out_of_range=ClipInvalidCommand),
        sequence_policy=CommandSequencePolicy(),
        effective_time_policy=CommandEffectiveTimePolicy(
            supersession=PreservePendingCommands),
        silence_policy=CommandSilencePolicy())
end

function serial_test_response(schema, operator)
    return SERIAL_TEST_PLANT.ReducedOrderCommandResponse(
        command_endpoint_id(schema), operator;
        units=command_units(schema),
        sign_convention=command_sign_convention(schema),
        basis=command_basis(schema),
        basis_revision=command_basis_revision(schema))
end

function serial_test_model(
    schema;
    disturbance,
    response_operator,
    measurement_kind,
    residual_kind)
    T = Float64
    return SERIAL_TEST_PLANT.LinearReducedOrderAcquisitionModel(
        disturbance,
        Matrix{T}(SERIAL_IDENTITY_2X2),
        Matrix{T}(SERIAL_IDENTITY_2X2),
        (serial_test_response(schema, response_operator),);
        measurement_kind,
        measurement_units=:metre,
        residual_kind,
        residual_units=:metre,
        calibration_revision=1,
        operating_envelope=(
            maximum_absolute_residual_m=20.0,
            maximum_disturbance_frequency_hz=40.0,
            sample_period_ns=1_000_000),
        omitted_effects=(
            :diffraction,
            :spatial_aliasing,
            :detector_noise,
            :device_dynamics,
            :coronagraph_propagation))
end

function serial_test_plant()
    T = Float64
    schema = serial_test_schema()
    disturbance = SERIAL_TEST_PLANT.HarmonicDisturbanceModel(
        T[0.30, -0.22], T[19.0, 31.0];
        offsets=T[0.05, -0.03], phases_rad=T[0.2, -0.4])
    feedback_disturbance = SERIAL_TEST_PLANT.HarmonicDisturbanceModel(
        zeros(T, 2), zeros(T, 2);
        offsets=zeros(T, 2), phases_rad=zeros(T, 2))
    residual_model = serial_test_model(
        schema;
        disturbance,
        response_operator=Matrix{T}(SERIAL_IDENTITY_2X2),
        measurement_kind=:modal_residual,
        residual_kind=:modal_wavefront_error)
    feedback_model = serial_test_model(
        schema;
        disturbance=feedback_disturbance,
        response_operator=Matrix{T}(SERIAL_IDENTITY_2X2),
        measurement_kind=:sampled_actuator_state,
        residual_kind=:actuator_state)

    telescope = Telescope(
        resolution=8,
        diameter=T(8),
        central_obstruction=zero(T),
        T=T)
    atmosphere = MultiLayerAtmosphere(
        telescope;
        r0=T(0.2),
        L0=T(25),
        fractional_cn2=T[1],
        wind_speed=T[0],
        wind_direction=T[0],
        altitude=T[0],
        layer_ids=(:ground,),
        T=T)
    source = Source(
        band=:custom,
        wavelength=T(0.8e-6),
        photon_irradiance=T(1),
        T=T)
    path = OpticalPathDefinition(
        :hil_wfs_path, source, HILReducedOrderPathModel())
    residual_acquisition = AcquisitionDefinition(
        :hil_wfs, :hil_wfs_path, residual_model)
    feedback_acquisition = AcquisitionDefinition(
        :hil_dm_feedback, :hil_wfs_path, feedback_model)
    optic = ControllableOpticDefinition(
        :hil_dm,
        HILReducedOrderOpticModel(),
        (schema,);
        placement=PupilPlanePlacement(),
        visibility=AllPathVisibility())
    definition = PlantDefinition(
        ;
        telescope,
        atmosphere,
        controllable_optics=(optic,),
        paths=(path,),
        acquisitions=(residual_acquisition, feedback_acquisition))
    plant = prepare_plant(
        definition;
        run_seed=0x7c00,
        command_endpoints=(
            CommandEndpointConfiguration(
                :hil_dm, zeros(T, 2); capacity=64),
        ))
    event_loop = prepare_plant_event_loop(
        plant,
        PlantEventLoopDefinition(
            (
                OpticalSampleDefinition(
                    :hil_wfs_path,
                    PeriodicSchedule(
                        period_ns=1_000_000, phase_ns=0)),
            ),
            (
                AcquisitionEventDefinition(
                    :hil_wfs,
                    DirectMeasurementAcquisitionDefinition(
                        PlantDuration(1_000_000)),
                    PeriodicAcquisitionStart(
                        PeriodicSchedule(
                            period_ns=2_000_000, phase_ns=0))),
                AcquisitionEventDefinition(
                    :hil_dm_feedback,
                    DirectMeasurementAcquisitionDefinition(
                        PlantDuration(1_000_000)),
                    PeriodicAcquisitionStart(
                        PeriodicSchedule(
                            period_ns=3_000_000, phase_ns=500_000))),
            )))
    return (; plant, event_loop, schema)
end

function serial_product_buffers(plant, id, count)
    source = acquisition_products(prepared_acquisition(plant, id))
    return [deepcopy(source) for _ in 1:count]
end

function serial_test_fixture(;
    product_capacity=8,
    product_ring_capacity=product_capacity,
    session=RunSessionID(0x7c00),
    arm_timeout_ns=10_000_000,
    optical_execution=SerialOpticalExecution(),
    wfs_overload_policy=AcquisitionOverloadPolicy(
        RequiredResource(),
        RetainProducerOnFull();
        maximum_lateness_ns=nothing,
        recovery_occupancy=0),
    feedback_overload_policy=AcquisitionOverloadPolicy(
        RequiredResource(),
        RetainProducerOnFull();
        maximum_lateness_ns=nothing,
        recovery_occupancy=0),
    ingress_liveness=nothing,
    shutdown_policy=SERIAL_TEST_SHUTDOWN_POLICY,
    reverse_acquisition_ports=false,
    clock=CachedNanoClock(0),
    arm=true,
    start=true)
    core = serial_test_plant()
    endpoint = prepared_command_endpoint(core.plant, :hil_dm)
    command_ports = prepare_command_ports(
        endpoint,
        [zeros(Float64, 2) for _ in 1:16];
        session,
        payload_pool_id=UInt64(0x7c10),
        outcome_credit_pool_id=UInt64(0x7c11),
        submission_capacity=16,
        completion_capacity=16)
    bridge = prepare_command_bridge(
        command_ports, endpoint, core.event_loop)
    delivery = AdapterDeliveryContract(
        PlantDuration(100_000), PlantDuration(2_000_000))
    wfs_port = prepare_acquisition_completion_port(
        AcquisitionID(:hil_wfs),
        serial_product_buffers(
            core.plant, :hil_wfs, product_capacity);
        session,
        product_pool_id=UInt64(0x7c20),
        ring_capacity=product_ring_capacity,
        delivery_contract=delivery,
        overload_policy=wfs_overload_policy)
    feedback_port = prepare_acquisition_completion_port(
        AcquisitionID(:hil_dm_feedback),
        serial_product_buffers(
            core.plant, :hil_dm_feedback, product_capacity);
        session,
        product_pool_id=UInt64(0x7c21),
        ring_capacity=product_ring_capacity,
        delivery_contract=delivery,
        overload_policy=feedback_overload_policy)
    acquisition_ports = reverse_acquisition_ports ?
        (feedback_port, wfs_port) :
        (wfs_port, feedback_port)
    configuration = configure_serial_run(
        bridge,
        acquisition_ports;
        optical_execution,
        ingress_liveness,
        arm_timeout_ns,
        shutdown_policy)
    run = prepare_serial_run(configuration)
    attempt = arm ? begin_serial_arm!(run, clock) : nothing
    readiness = arm ? AdapterReadinessSnapshot(
        session,
        execution_clock_identity(clock),
        AdapterReady,
        Clocks.time_nanos(clock)) : nothing
    armed = arm ? arm_serial_run!(attempt, readiness) : nothing
    running = start ? start_serial_run!(armed) : nothing
    return merge(
        core,
        (; command_ports, bridge, wfs_port, feedback_port,
            configuration, run, clock, attempt, readiness, armed, running))
end

function take_all_command_outcomes!(fixture, trace)
    port = command_completion_port(fixture.command_ports)
    output = Ref{CommandOutcome{LeasedCommandPayload}}()
    while true
        result = try_take!(output, port)
        port_status(result) in (PortEmpty, PortClosed) &&
            return nothing
        @assert port_status(result) == PortTransferSucceeded
        outcome = output[]
        push!(trace.outcome_stream_sequences,
            stream_sequence_value(outcome_stream_sequence(outcome)))
        push!(trace.outcome_application_timestamps,
            plant_nanoseconds(outcome_terminal_timestamp(outcome)))
        push!(trace.outcome_publication_execution_ns,
            outcome_publication_execution_ns(outcome))
        push!(trace.outcome_ingress_execution_ns,
            outcome_ingress_execution_ns(outcome))
        @assert outcome_stage(outcome) == CoreCommandOutcome
        @assert release_outcome!(port, outcome).status ==
            PortTransferSucceeded
    end
end

function submit_fake_rtc_command!(
    fixture,
    trace,
    command,
    measurement,
    product_sequence;
    sign,
    delay_frames,
    processing_ns)
    @. command += sign * 0.65 * measurement
    Clocks.advance!(fixture.clock, processing_ns)
    submission_port = command_submission_port(fixture.command_ports)
    lease_ref = Ref(PayloadLeaseRef(0, 0, 0, 0))
    @assert try_claim_command_payload!(lease_ref, submission_port) ==
        PayloadTransitionSucceeded
    copyto!(
        producer_command_payload(submission_port, lease_ref[]), command)
    command_sequence = PlantCommandSequence(product_sequence)
    receive_ns = (2 * product_sequence - 1) * 1_000_000 +
        processing_ns
    receive = PlantTimestamp(receive_ns)
    effective = PlantTimestamp(
        (2 * product_sequence + 2 * delay_frames) * 1_000_000)
    timing = receive_time_command_timing(
        receive; requested_effective_timestamp=effective)
    submission = matching_command_submission(
        submission_port,
        StreamSequence(product_sequence),
        command_sequence,
        timing,
        LeasedCommandPayload(lease_ref[]))
    ingress_execution_ns = Clocks.time_nanos(fixture.clock)
    result = try_submit!(
        submission_port, submission, ingress_execution_ns)
    @assert port_status(result) == PortTransferSucceeded
    push!(trace.command_stream_sequences, UInt64(product_sequence))
    push!(trace.command_ingress_execution_ns, ingress_execution_ns)
    push!(trace.command_receive_plant_timestamps, receive_ns)
    return nothing
end

function take_all_wfs_products!(
    fixture,
    trace,
    command,
    frame_count;
    sign,
    delay_frames,
    processing_ns)
    output = Ref{AcquisitionCompletion}()
    while true
        result = try_take!(output, fixture.wfs_port)
        port_status(result) in (PortEmpty, PortClosed) &&
            return nothing
        @assert port_status(result) == PortTransferSucceeded
        completion = output[]
        product = completed_product(fixture.wfs_port, completion)
        measurement = measurement_storage(product.measurement)
        sequence = stream_sequence_value(
            acquisition_completion_sequence(completion))
        push!(trace.all_wfs_sequences, sequence)
        push!(trace.product_publication_execution_ns,
            acquisition_completion_publication_ns(completion))
        push!(trace.adapter_observation_execution_ns,
            Clocks.time_nanos(fixture.clock))
        if length(trace.residual_metric) < frame_count
            push!(trace.measurements, copy(measurement))
            push!(trace.residual_metric, sum(abs2, measurement))
            if sequence < frame_count
                submit_fake_rtc_command!(
                    fixture,
                    trace,
                    command,
                    measurement,
                    sequence;
                    sign,
                    delay_frames,
                    processing_ns)
            end
        end
        @assert release_product!(fixture.wfs_port, completion).status ==
            PortTransferSucceeded
    end
end

function take_all_feedback_products!(fixture, trace)
    output = Ref{AcquisitionCompletion}()
    while true
        result = try_take!(output, fixture.feedback_port)
        port_status(result) in (PortEmpty, PortClosed) &&
            return nothing
        @assert port_status(result) == PortTransferSucceeded
        completion = output[]
        product = completed_product(fixture.feedback_port, completion)
        push!(trace.feedback_sequences, stream_sequence_value(
            acquisition_completion_sequence(completion)))
        push!(trace.feedback_completion_timestamps, plant_nanoseconds(
            acquisition_completion_timestamp(completion)))
        push!(trace.feedback_values,
            copy(measurement_storage(product.measurement)))
        @assert release_product!(
            fixture.feedback_port, completion).status ==
            PortTransferSucceeded
    end
end

function release_all_serial_command_outcomes!(fixture)
    port = command_completion_port(fixture.command_ports)
    output = Ref{CommandOutcome{LeasedCommandPayload}}()
    count = 0
    while true
        result = try_take!(output, port)
        port_status(result) in (PortEmpty, PortClosed) &&
            return count
        @assert port_status(result) == PortTransferSucceeded
        @assert release_outcome!(port, output[]).status ==
            PortTransferSucceeded
        count += 1
    end
end

function release_all_serial_products!(port)
    output = Ref{AcquisitionCompletion}()
    count = 0
    while true
        result = try_take!(output, port)
        port_status(result) in (PortEmpty, PortClosed) &&
            return count
        @assert port_status(result) == PortTransferSucceeded
        @assert release_product!(port, output[]).status ==
            PortTransferSucceeded
        count += 1
    end
end

function finish_serial_shutdown!(fixture, handle=fixture.running)
    for _ in 1:10_000
        release_all_serial_command_outcomes!(fixture)
        release_all_serial_products!(fixture.wfs_port)
        release_all_serial_products!(fixture.feedback_port)
        reclaim_serial_returns!(fixture.run)
        status = progress_serial_shutdown!(handle)
        status == SerialShutdownFinalized &&
            return serial_run_accounting(fixture.run)
        yield()
    end
    error("serial shutdown did not finish within the test iteration bound")
end

function finish_serial_stop!(
    fixture,
    event,
    handle=fixture.running)
    @assert begin_serial_stop!(handle, event) ==
        SerialShutdownDraining
    return finish_serial_shutdown!(fixture, handle)
end

function fake_rtc_trace()
    return (
        measurements=Vector{Vector{Float64}}(),
        residual_metric=Float64[],
        all_wfs_sequences=UInt64[],
        product_publication_execution_ns=Int64[],
        adapter_observation_execution_ns=Int64[],
        command_stream_sequences=UInt64[],
        command_ingress_execution_ns=Int64[],
        command_receive_plant_timestamps=Int64[],
        command_admission_plant_timestamps=Int64[],
        command_admission_execution_ns=Int64[],
        outcome_stream_sequences=UInt64[],
        outcome_application_timestamps=Int64[],
        outcome_publication_execution_ns=Int64[],
        outcome_ingress_execution_ns=Int64[],
        feedback_sequences=UInt64[],
        feedback_completion_timestamps=Int64[],
        feedback_values=Vector{Vector{Float64}}(),
        event_sample_timestamps=Int64[],
        command_responsive_optical_sample_timestamps=Int64[])
end

function run_fake_rtc(;
    frame_count=36,
    sign=-1.0,
    delay_frames=0,
    processing_ns=1,
    optical_execution=SerialOpticalExecution())
    fixture = serial_test_fixture(; optical_execution)
    trace = fake_rtc_trace()
    command = zeros(Float64, 2)
    iterations = 0
    while true
        iterations += 1
        iterations <= 20_000 || error("fake RTC iteration bound exceeded")
        result = step_serial_run!(fixture.running)
        sample_timestamp_ns = nothing
        if serial_step_status(result) == SerialDeadlinePending
            Clocks.advance!(
                fixture.clock, serial_step_time_until_ns(result))
        elseif serial_step_status(result) == SerialCommandProcessed
            push!(trace.command_admission_plant_timestamps,
                plant_nanoseconds(serial_step_timestamp(result)))
            push!(trace.command_admission_execution_ns,
                Clocks.time_nanos(fixture.clock))
        elseif serial_step_status(result) == SerialPlantEventProcessed
            sample_timestamp = SERIAL_TEST_PLANT.reduced_order_sample_timestamp(
                prepared_acquisition(fixture.plant, :hil_wfs))
            if sample_timestamp !== nothing
                sample_timestamp_ns =
                    plant_nanoseconds(sample_timestamp)
                push!(trace.event_sample_timestamps, sample_timestamp_ns)
            end
        end

        take_all_command_outcomes!(fixture, trace)
        if sample_timestamp_ns !== nothing &&
                sample_timestamp_ns in
                    trace.outcome_application_timestamps
            push!(
                trace.command_responsive_optical_sample_timestamps,
                sample_timestamp_ns)
        end
        take_all_wfs_products!(
            fixture,
            trace,
            command,
            frame_count;
            sign,
            delay_frames,
            processing_ns)
        take_all_feedback_products!(fixture, trace)

        if length(trace.residual_metric) == frame_count &&
                active_command_correlations(fixture.run.state.bridge) == 0
            break
        end
    end
    reclaim_serial_returns!(fixture.run)
    stop_request = RunStopRequest(
        run_session(fixture.run),
        execution_clock_identity(fixture.armed.timing),
        Clocks.time_nanos(fixture.clock))
    accounting = finish_serial_stop!(
        fixture, stop_request)
    return (; fixture, trace, accounting)
end

function warm_serial_wait_allocations(fixture)
    result = step_serial_run!(fixture.running)
    @assert serial_step_status(result) == SerialPlantEventProcessed
    result = step_serial_run!(fixture.running)
    @assert serial_step_status(result) == SerialDeadlinePending
    return @allocated step_serial_run!(fixture.running)
end

function prepare_first_wfs_publication!(fixture)
    first_step = step_serial_run!(fixture.running)
    @assert serial_step_status(first_step) ==
        SerialPlantEventProcessed
    pending = step_serial_run!(fixture.running)
    @assert serial_step_status(pending) ==
        SerialDeadlinePending
    Clocks.advance!(
        fixture.clock, serial_step_time_until_ns(pending))
    second = step_serial_run!(fixture.running)
    @assert serial_step_status(second) ==
        SerialPlantEventProcessed
    pending = step_serial_run!(fixture.running)
    @assert serial_step_status(pending) ==
        SerialDeadlinePending
    Clocks.advance!(
        fixture.clock, serial_step_time_until_ns(pending))
    return fixture
end

@inline function serial_due_step_allocations(fixture)
    return @allocated step_serial_run!(fixture.running)
end

function queue_serial_test_command!(
    fixture;
    stream_sequence=1,
    command_sequence=1,
    receive_ns=1,
    effective_ns=2_000_000,
    advance_ns=1)
    submission_port = command_submission_port(fixture.command_ports)
    lease_ref = Ref(PayloadLeaseRef(0, 0, 0, 0))
    @assert try_claim_command_payload!(lease_ref, submission_port) ==
        PayloadTransitionSucceeded
    fill!(
        producer_command_payload(submission_port, lease_ref[]), 0.0)
    receive = PlantTimestamp(receive_ns)
    timing = receive_time_command_timing(
        receive;
        requested_effective_timestamp=PlantTimestamp(effective_ns))
    submission = matching_command_submission(
        submission_port,
        StreamSequence(stream_sequence),
        PlantCommandSequence(command_sequence),
        timing,
        LeasedCommandPayload(lease_ref[]))
    Clocks.advance!(fixture.clock, advance_ns)
    @assert port_status(try_submit!(
        submission_port, submission, Clocks.time_nanos(fixture.clock))) ==
        PortTransferSucceeded
    return fixture
end

@inline function serial_command_step_allocations(fixture)
    return @allocated step_serial_run!(fixture.running)
end

@inline function serial_optional_shed_allocations!(
    policy,
    publisher,
    publication)
    return @allocated AdaptiveOpticsHIL.Serial.
        _handle_serial_capacity_overload!(
            policy, publisher, publication)
end

@inline function serial_acquisition_accounting_allocations(
    run,
    id)
    return @allocated serial_acquisition_overload_accounting(
        run, id)
end

@inline serial_shutdown_progress_allocations!(handle) =
    @allocated progress_serial_shutdown!(handle)

function take_serial_acquisition_sequences!(port, sequences)
    output = Ref{AcquisitionCompletion}()
    while true
        result = try_take!(output, port)
        port_status(result) == PortEmpty && return sequences
        @assert port_status(result) == PortTransferSucceeded
        completion = output[]
        push!(
            sequences,
            stream_sequence_value(
                acquisition_completion_sequence(completion)))
        @assert port_status(release_product!(port, completion)) ==
            PortTransferSucceeded
    end
end

serial_test_mean(values) = sum(values) / length(values)

function captured_serial_error(f)
    try
        f()
    catch error
        return error
    end
    return nothing
end

function drive_until_serial_failure!(fixture; maximum_steps=128)
    for _ in 1:maximum_steps
        result = try
            step_serial_run!(fixture.running)
        catch error
            finish_serial_shutdown!(fixture)
            return error
        end
        serial_step_status(result) == SerialDeadlinePending &&
            Clocks.advance!(
                fixture.clock, serial_step_time_until_ns(result))
    end
    error("serial failure did not occur inside the test step bound")
end

@testset "Serial HIL vertical slice" begin
    @test Base.isexported(AdaptiveOpticsHIL, :Serial)
    @test !Base.isexported(
        AdaptiveOpticsHIL.Serial, :SerialRunState)
    @test Base.ispublic(
        AdaptiveOpticsHIL.Serial, :SerialRunState)
    @test isconst(
        AdaptiveOpticsHIL.Serial.SerialRunState, :bridge)
    @test isconst(
        AdaptiveOpticsHIL.Serial.SerialRunState, :publications)
    @test isconst(
        AdaptiveOpticsHIL.Serial.SerialRunState, :ingress_liveness)
    @test isconst(
        AdaptiveOpticsHIL.Serial.SerialRunState, :lifecycle)
    @test Base.ispublic(AdaptiveOpticsHIL.Ports,
        :command_bridge_event_loop)
    @test Base.ispublic(AdaptiveOpticsHIL.Ports,
        :pending_command_receive_timestamp)

    @testset "Preparation, readiness, and nonblocking pacing" begin
        fixture = serial_test_fixture()
        @test command_bridge_event_loop(fixture.bridge) ===
            fixture.event_loop
        @test plant_event_loop_state(fixture.run.state.bridge) isa
            PlantEventLoopState
        @test plant_event_loop_workspace(fixture.run.workspace.bridge) ===
            command_disposition_workspace(fixture.run.workspace.bridge)
        @test run_phase(fixture.configuration) == RunConfigured
        @test run_phase(fixture.running) == RunRunning
        @test run_session(fixture.configuration) ==
            RunSessionID(0x7c00)
        @test run_session(fixture.running) == RunSessionID(0x7c00)
        @test serial_shutdown_policy(fixture.configuration) ===
            SERIAL_TEST_SHUTDOWN_POLICY
        @test serial_shutdown_policy(fixture.run) ===
            SERIAL_TEST_SHUTDOWN_POLICY
        @test run_arm_window(fixture.configuration) === nothing
        @test run_execution_clock_identity(fixture.configuration) ===
            nothing
        @test run_execution_clock_identity(fixture.running) ==
            execution_clock_identity(fixture.clock)
        @test run_adapter_readiness(fixture.configuration) === nothing
        @test run_adapter_readiness(fixture.running) ===
            fixture.readiness
        @test run_termination(fixture.configuration) === nothing
        @test run_termination(fixture.running) === nothing
        direct_bridge = prepare_command_bridge(
            fixture.command_ports,
            prepared_command_endpoint(fixture.plant, :hil_dm))
        @test command_bridge_event_loop(direct_bridge) === nothing

        first_step = @inferred step_serial_run!(fixture.running)
        @test serial_step_status(first_step) ==
            SerialPlantEventProcessed
        @test serial_step_timestamp(first_step) == PlantTimestamp(0)
        pending = @inferred step_serial_run!(fixture.running)
        @test serial_step_status(pending) ==
            SerialDeadlinePending
        @test serial_step_timestamp(pending) == PlantTimestamp(500_000)
        @test serial_step_time_until_ns(pending) == 500_000

        chronological = serial_test_fixture(
            session=RunSessionID(0x7c45))
        @test serial_step_status(
            step_serial_run!(chronological.running)) ==
            SerialPlantEventProcessed
        Clocks.advance!(chronological.clock, 1_000_000)
        queue_serial_test_command!(
            chronological;
            receive_ns=1_000_000,
            effective_ns=2_000_000,
            advance_ns=0,
        )
        earlier_event =
            step_serial_run!(chronological.running)
        @test serial_step_status(earlier_event) ==
            SerialPlantEventProcessed
        @test serial_step_timestamp(earlier_event) ==
            PlantTimestamp(500_000)
        ordered_command =
            step_serial_run!(chronological.running)
        @test serial_step_status(ordered_command) ==
            SerialCommandProcessed
        @test serial_step_timestamp(ordered_command) ==
            PlantTimestamp(1_000_000)
        finish_serial_stop!(
            chronological,
            RunStopRequest(
                run_session(chronological.run),
                execution_clock_identity(
                    chronological.armed.timing),
                Clocks.time_nanos(chronological.clock);
                reason=:chronological_command_test,
            ),
        )

        if SERIAL_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            allocation_fixture = serial_test_fixture()
            @test warm_serial_wait_allocations(allocation_fixture) == 0
            warm_due = prepare_first_wfs_publication!(
                serial_test_fixture())
            serial_due_step_allocations(warm_due)
            measured_due = prepare_first_wfs_publication!(
                serial_test_fixture())
            # The HIL copy/publication path is allocation-free; this inclusive
            # budget covers the core reduced-order event step.
            @test serial_due_step_allocations(measured_due) <=
                SERIAL_DUE_STEP_ALLOCATION_BUDGET

            warm_command = serial_test_fixture()
            step_serial_run!(warm_command.running)
            queue_serial_test_command!(warm_command)
            serial_command_step_allocations(warm_command)
            measured_command = serial_test_fixture()
            step_serial_run!(measured_command.running)
            queue_serial_test_command!(measured_command)
            # The bounded HIL port path is allocation-free; this inclusive
            # budget covers routed core event-loop command admission.
            @test serial_command_step_allocations(measured_command) <=
                SERIAL_COMMAND_STEP_ALLOCATION_BUDGET
        end

        prepared = serial_test_fixture(arm=false, start=false)
        @test run_phase(prepared.run) == RunPrepared
        attempt = begin_serial_arm!(prepared.run, prepared.clock)
        @test run_phase(attempt) == RunArming
        @test arm_opened_execution_ns(run_arm_window(attempt)) == 0
        @test arm_deadline_execution_ns(run_arm_window(attempt)) ==
            10_000_000
        not_ready = captured_serial_error() do
            arm_serial_run!(
                attempt,
                AdapterReadinessSnapshot(
                    run_session(attempt),
                    execution_clock_identity(prepared.clock),
                    AdapterNotReady,
                    Clocks.time_nanos(prepared.clock)))
        end
        @test not_ready isa RunLifecycleError
        @test not_ready.reason == :adapter_not_ready
        @test run_phase(prepared.run) == RunArming

        exact = serial_test_fixture(
            arm=false,
            start=false,
            arm_timeout_ns=10)
        exact_attempt = begin_serial_arm!(exact.run, exact.clock)
        Clocks.advance!(exact.clock, 10)
        exact_armed = arm_serial_run!(
            exact_attempt,
            AdapterReadinessSnapshot(
                run_session(exact.run),
                execution_clock_identity(exact.clock),
                AdapterReady,
                Clocks.time_nanos(exact.clock)))
        @test run_phase(exact_armed) == RunArmed
        @test execution_clock_origin_ns(exact_armed.timing) == 10

        expired = serial_test_fixture(
            arm=false,
            start=false,
            arm_timeout_ns=10)
        expired_attempt =
            begin_serial_arm!(expired.run, expired.clock)
        Clocks.advance!(expired.clock, 11)
        expired_error = captured_serial_error() do
            arm_serial_run!(
                expired_attempt,
                AdapterReadinessSnapshot(
                    run_session(expired.run),
                    execution_clock_identity(expired.clock),
                    AdapterReady,
                    Clocks.time_nanos(expired.clock)))
        end
        @test expired_error isa RunLifecycleError
        @test expired_error.reason == :arm_deadline_expired
        @test run_phase(expired.run) == RunFailed

        stale = serial_test_fixture(arm=false, start=false)
        stale_attempt = begin_serial_arm!(stale.run, stale.clock)
        stale_error = captured_serial_error() do
            arm_serial_run!(
                stale_attempt,
                AdapterReadinessSnapshot(
                    RunSessionID(0x7c01),
                    execution_clock_identity(stale.clock),
                    AdapterReady,
                    Clocks.time_nanos(stale.clock)))
        end
        @test stale_error isa RunLifecycleError
        @test stale_error.reason == :stale_session
        @test run_phase(stale.run) == RunArming

        changed_identity =
            serial_test_fixture(arm=false, start=false)
        mutable_clock = MutableIdentityNanoClock(
            0, ExecutionClockID(:arm_clock_a))
        identity_attempt = begin_serial_arm!(
            changed_identity.run, mutable_clock)
        mutable_clock.identity = ExecutionClockID(:arm_clock_b)
        identity_error = captured_serial_error() do
            arm_serial_run!(
                identity_attempt,
                AdapterReadinessSnapshot(
                    run_session(changed_identity.run),
                    ExecutionClockID(:arm_clock_a),
                    AdapterReady,
                    0))
        end
        @test identity_error isa SerialRunError
        @test identity_error.reason ==
            :execution_clock_identity_changed
        @test run_phase(changed_identity.run) == RunArming

        adapter_failed =
            serial_test_fixture(arm=false, start=false)
        failed_attempt = begin_serial_arm!(
            adapter_failed.run, adapter_failed.clock)
        adapter_error = captured_serial_error() do
            arm_serial_run!(
                failed_attempt,
                AdapterReadinessSnapshot(
                    run_session(adapter_failed.run),
                    execution_clock_identity(adapter_failed.clock),
                    AdapterFailed,
                    Clocks.time_nanos(adapter_failed.clock)))
        end
        @test adapter_error isa RunLifecycleError
        @test adapter_error.reason == :adapter_failed
        @test run_phase(adapter_failed.run) == RunFailed

        origin_fixture =
            serial_test_fixture(arm=false, start=false)
        overtaken_origin = captured_serial_error() do
            begin_serial_arm!(
                origin_fixture.run,
                origin_fixture.clock;
                plant_origin=PlantTimestamp(1))
        end
        @test overtaken_origin isa SerialRunError
        @test overtaken_origin.reason ==
            :plant_origin_after_next_event
        @test run_phase(origin_fixture.run) == RunPrepared
    end

    @testset "RTC-ingress-liveness serial integration" begin
        endpoint = CommandEndpointID(:hil_dm)
        policy = RTCIngressLivenessPolicy(
            endpoint,
            ExecutionClockID(:execution_clock);
            timeout_ns=10)
        fixture = serial_test_fixture(; ingress_liveness=policy)
        @test serial_rtc_ingress_liveness_policy(
            fixture.configuration) === policy
        initial_liveness =
            serial_rtc_ingress_liveness_accounting(fixture.run)
        @test initial_liveness.status == RTCIngressLivenessActive
        @test initial_liveness.origin_execution_ns == 0
        @test initial_liveness.endpoint == endpoint

        @test serial_step_status(
            step_serial_run!(fixture.running)) ==
            SerialPlantEventProcessed
        queue_serial_test_command!(fixture)
        enqueued_liveness =
            serial_rtc_ingress_liveness_accounting(fixture.run)
        @test enqueued_liveness.reset_count == 0
        @test enqueued_liveness.origin_execution_ns == 0
        admitted = step_serial_run!(fixture.running)
        @test serial_step_status(admitted) ==
            SerialCommandProcessed
        admitted_liveness =
            serial_rtc_ingress_liveness_accounting(fixture.run)
        @test admitted_liveness.reset_count == 1
        @test admitted_liveness.origin_execution_ns == 1
        @test SERIAL_TEST_PLANT.effective_command(
            fixture.event_loop,
            plant_event_loop_state(fixture.run.state.bridge),
            endpoint) == zeros(Float64, 2)

        queue_serial_test_command!(
            fixture;
            stream_sequence=2,
            command_sequence=1,
            receive_ns=2,
            advance_ns=1)
        terminated = step_serial_run!(fixture.running)
        @test serial_step_status(terminated) ==
            SerialCommandProcessed
        @test serial_rtc_ingress_liveness_accounting(
            fixture.run).reset_count == 1

        outcome_ref =
            Ref{CommandOutcome{LeasedCommandPayload}}()
        @test port_status(try_take!(
            outcome_ref,
            command_completion_port(fixture.command_ports))) ==
            PortTransferSucceeded
        @test outcome_stage(outcome_ref[]) == CoreCommandOutcome
        @test outcome_reason(outcome_ref[]) == :duplicate_sequence
        @test port_status(release_outcome!(
            command_completion_port(fixture.command_ports),
            outcome_ref[])) == PortTransferSucceeded

        queue_serial_test_command!(
            fixture;
            stream_sequence=2,
            command_sequence=2,
            receive_ns=3,
            advance_ns=1)
        rejected = step_serial_run!(fixture.running)
        @test serial_step_status(rejected) ==
            SerialCommandProcessed
        @test serial_rtc_ingress_liveness_accounting(
            fixture.run).reset_count == 1
        @test port_status(try_take!(
            outcome_ref,
            command_completion_port(fixture.command_ports))) ==
            PortTransferSucceeded
        @test outcome_stage(outcome_ref[]) ==
            BoundaryCommandOutcome
        @test outcome_boundary_reason(outcome_ref[]) ==
            CommandStreamSequenceNotIncreasing
        @test port_status(release_outcome!(
            command_completion_port(fixture.command_ports),
            outcome_ref[])) == PortTransferSucceeded
        reclaim_serial_returns!(fixture.run)

        Clocks.advance!(fixture.clock, 8)
        exact = step_serial_run!(fixture.running)
        @test serial_step_status(exact) ==
            SerialDeadlinePending
        @test serial_rtc_ingress_liveness_accounting(
            fixture.run).status == RTCIngressLivenessActive

        Clocks.advance!(fixture.clock, 1)
        expiry = captured_serial_error() do
            step_serial_run!(fixture.running)
        end
        @test expiry isa SerialRunError
        @test expiry.component == :rtc_ingress_liveness
        @test expiry.reason == :deadline_expired
        expired_liveness =
            serial_rtc_ingress_liveness_accounting(fixture.run)
        @test expired_liveness.status ==
            RTCIngressLivenessExpired
        @test expired_liveness.observation_execution_ns == 12
        @test expired_liveness.deadline_execution_ns == 11
        @test expired_liveness.expiry_count == 1
        @test active_command_correlations(
            fixture.run.state.bridge) == 0
        @test SERIAL_TEST_PLANT.effective_command(
            fixture.event_loop,
            plant_event_loop_state(fixture.run.state.bridge),
            endpoint) == zeros(Float64, 2)

        @test port_status(try_take!(
            outcome_ref,
            command_completion_port(fixture.command_ports))) ==
            PortTransferSucceeded
        @test outcome_terminal_kind(outcome_ref[]) ==
            SERIAL_TEST_PLANT.FailedCommand
        @test outcome_reason(outcome_ref[]) ==
            :hil_ingress_liveness_expired
        @test port_status(release_outcome!(
            command_completion_port(fixture.command_ports),
            outcome_ref[])) == PortTransferSucceeded
        finish_serial_shutdown!(fixture)
        @test run_phase(fixture.run) == RunFailed
        termination = run_termination(fixture.run)
        @test run_termination_component(termination) ==
            :rtc_ingress_liveness
        @test run_termination_reason(termination) ==
            :deadline_expired
    end

    @testset "Prepared acquisition overload decisions" begin
        optional_policy = AcquisitionOverloadPolicy(
            OptionalResource(),
            DropNewestOnFull();
            maximum_lateness_ns=10_000_000,
            recovery_occupancy=0)
        fixture = serial_test_fixture(
            product_capacity=2,
            product_ring_capacity=1,
            feedback_overload_policy=optional_policy,
            reverse_acquisition_ports=true)
        feedback_source = first(fixture.run.publishers).source
        @test acquisition_overload_policy(
            fixture.feedback_port) === optional_policy
        wfs_sequences = UInt64[]
        for _ in 1:256
            result = step_serial_run!(fixture.running)
            serial_step_status(result) == SerialDeadlinePending &&
                Clocks.advance!(
                    fixture.clock,
                    serial_step_time_until_ns(result))
            take_serial_acquisition_sequences!(
                fixture.wfs_port, wfs_sequences)
            reclaim_serial_returns!(fixture.run)
            feedback = serial_acquisition_overload_accounting(
                fixture.run, AcquisitionID(:hil_dm_feedback))
            feedback.products_shed >= 1 && break
        end
        overloaded = serial_acquisition_overload_accounting(
            fixture.run, AcquisitionID(:hil_dm_feedback))
        @test overloaded.products_shed == 1
        @test overloaded.products_failed == 0
        @test overloaded.last_sequence == 2
        @test overloaded.decision ==
            AcquisitionShedForCapacity
        @test overloaded.overloaded
        @test overloaded.maximum_descriptor_occupancy >= 1
        @test overloaded.maximum_product_occupancy >= 1

        feedback_sequences = UInt64[]
        take_serial_acquisition_sequences!(
            fixture.feedback_port, feedback_sequences)
        @test feedback_sequences == UInt64[1]
        reclaim_serial_returns!(fixture.run)
        for _ in 1:256
            result = step_serial_run!(fixture.running)
            serial_step_status(result) == SerialDeadlinePending &&
                Clocks.advance!(
                    fixture.clock,
                    serial_step_time_until_ns(result))
            take_serial_acquisition_sequences!(
                fixture.wfs_port, wfs_sequences)
            reclaim_serial_returns!(fixture.run)
            feedback = serial_acquisition_overload_accounting(
                fixture.run, AcquisitionID(:hil_dm_feedback))
            feedback.last_sequence >= 3 &&
                ring_accounting(
                    fixture.feedback_port.ring).occupancy > 0 &&
                break
        end
        take_serial_acquisition_sequences!(
            fixture.feedback_port, feedback_sequences)
        @test feedback_sequences == UInt64[1, 3]
        recovered = serial_acquisition_overload_accounting(
            fixture.run, AcquisitionID(:hil_dm_feedback))
        @test recovered.recovery_count == 1
        @test recovered.recovered_to_threshold
        @test !recovered.overloaded
        @test recovered.products_published == 2
        @test acquisition_overload_policy(
            fixture.feedback_port) === optional_policy
        @test first(fixture.run.publishers).source ===
            feedback_source
        @test ring_accounting(
            fixture.feedback_port.ring).capacity == 1
        @test acquisition_product_accounting(
            fixture.feedback_port).capacity == 2
        @test wfs_sequences ==
            UInt64.(1:length(wfs_sequences))
        required_wfs = serial_acquisition_overload_accounting(
            fixture.run, AcquisitionID(:hil_wfs))
        @test required_wfs.products_shed == 0
        @test required_wfs.products_failed == 0

        if SERIAL_TESTS_WITH_COVERAGE
            @test_skip "accounting allocation gate disabled under coverage"
            @test_skip "overload allocation gate disabled under coverage"
        else
            @test serial_acquisition_accounting_allocations(
                fixture.run,
                AcquisitionID(:hil_dm_feedback)) == 0
            allocation_state =
                AdaptiveOpticsHIL.Serial.AcquisitionPublicationState()
            optional_publisher = only(
                publisher
                for publisher in fixture.run.publishers
                if publisher.id == AcquisitionID(:hil_dm_feedback)
            )
            AdaptiveOpticsHIL.Serial.
                _handle_serial_capacity_overload!(
                    optional_policy,
                    optional_publisher,
                    allocation_state)
            @test serial_optional_shed_allocations!(
                optional_policy,
                optional_publisher,
                allocation_state) == 0
        end

        deadline_policy = AcquisitionOverloadPolicy(
            RequiredResource(),
            RetainProducerOnFull();
            maximum_lateness_ns=0,
            recovery_occupancy=0)
        deadline = serial_test_fixture(
            wfs_overload_policy=deadline_policy)
        deadline_error = nothing
        for _ in 1:256
            result = try
                step_serial_run!(deadline.running)
            catch error
                deadline_error = error
                break
            end
            serial_step_status(result) == SerialDeadlinePending &&
                Clocks.advance!(
                    deadline.clock,
                    serial_step_time_until_ns(result) + 1)
        end
        @test deadline_error isa SerialRunError
        @test deadline_error.reason ==
            :acquisition_publication_deadline
        finish_serial_shutdown!(deadline)
        @test run_phase(deadline.run) == RunFailed
        deadline_accounting =
            serial_acquisition_overload_accounting(
                deadline.run, AcquisitionID(:hil_wfs))
        @test deadline_accounting.products_failed == 1
        @test deadline_accounting.decision ==
            AcquisitionFailedForDeadline
    end

    @testset "Prepared execution-owner policy" begin
        @test Base.isexported(AdaptiveOpticsHIL, :Execution)
        @test !Base.isexported(
            AdaptiveOpticsHIL, :PreparedExecutionOwnerExecutor)

        mode = DeterministicExecutionOwners()
        owner_configuration =
            serial_test_execution_owner_configuration(mode)
        fixture = serial_test_fixture(;
            optical_execution=owner_configuration)
        executor = @inferred serial_optical_execution(fixture.run)
        @test executor isa PreparedExecutionOwnerExecutor
        @test serial_optical_execution_configuration(
            fixture.configuration) === owner_configuration
        @test serial_optical_execution_configuration(
            fixture.run) === owner_configuration
        @test execution_owner_mode(executor) === mode
        @test execution_owner_idle_policy(executor) === nothing
        @test execution_cpu_budget(executor) ===
            owner_configuration.cpu_budget
        @test execution_cpu_environment(executor) ===
            owner_configuration.cpu_environment
        @test execution_owner_ring_capacity(executor) == 1
        @test execution_owner_count(executor) == 1
        @test execution_owners_phase(executor) ==
            ExecutionOwnersRunning
        @test execution_batches_completed(executor) == 0

        owner = @inferred execution_owner(executor, 1)
        @test execution_owner_id(owner) == ExecutionOwnerID(1)
        @test execution_owner_id_value(execution_owner_id(owner)) == 1
        @test sprint(show, execution_owner_id(owner)) ==
            "ExecutionOwnerID(1)"
        @test execution_owner_kind(owner) ==
            PathGroupExecutionOwner
        @test execution_owner_backend(owner) == CPUBackend()
        @test execution_owner_compute_device(owner) ==
            AdaptiveOpticsSim.HostComputeDevice()
        @test execution_owner_group_count(owner) == 1
        @test execution_owner_group_ordinal(owner, 1) == 1
        @test execution_owner_overload_policy(owner) ===
            owner_configuration.owner_policy
        @test resource_criticality(
            execution_owner_overload_policy(owner)) isa
            RequiredResource
        @test execution_owner_overload_action(owner) isa
            FailRunOnOwnerOverload
        @test maximum_resource_lateness_ns(
            execution_owner_overload_policy(owner)) === nothing
        @test overload_recovery_occupancy(
            execution_owner_overload_policy(owner)) == 0
        @test_throws BoundsError execution_owner(executor, 0)
        @test_throws BoundsError execution_owner_group_ordinal(owner, 2)

        before = execution_owner_accounting(executor, 1)
        @test before.work_submitted == 0
        @test before.work_taken == 0
        @test before.work_completed == 0
        @test before.completions_taken == 0
        @test execution_owners_are_quiescent(executor)
        before_run_accounting =
            serial_run_accounting(fixture.run)
        @test length(before_run_accounting.execution_owners) == 1
        @test first(
            before_run_accounting.execution_owners).work_submitted == 0
        @test serial_run_is_quiescent(before_run_accounting)

        first_step = @inferred step_serial_run!(fixture.running)
        @test serial_step_status(first_step) ==
            SerialPlantEventProcessed
        @test serial_step_timestamp(first_step) == PlantTimestamp(0)
        after = execution_owner_accounting(executor, 1)
        @test after.work_submitted == 2
        @test after.work_taken == 2
        @test after.work_completed == 2
        @test after.completions_taken == 2
        @test !after.failed
        @test iszero(after.task_id)
        @test after.last_thread_id == Threads.threadid()
        @test execution_batches_completed(executor) == 1
        @test execution_owners_are_quiescent(executor)
        after_run_accounting = serial_run_accounting(fixture.run)
        @test first(
            after_run_accounting.execution_owners).work_submitted == 2
        @test serial_run_is_quiescent(after_run_accounting)

        request = RunStopRequest(
            run_session(fixture.run),
            execution_clock_identity(fixture.armed.timing),
            Clocks.time_nanos(fixture.clock))
        stopped_run_accounting =
            finish_serial_stop!(fixture, request)
        @test execution_owners_phase(executor) ==
            ExecutionOwnersStopped
        stopped = execution_owner_accounting(executor, 1)
        @test stopped.due.closed
        @test stopped.completion.closed
        @test stopped.stop_acknowledged
        @test execution_owners_are_quiescent(executor)
        stopped_run_owner =
            first(stopped_run_accounting.execution_owners)
        @test stopped_run_owner.stop_acknowledged
        @test stopped_run_owner.due.closed

        optional_deadline_policy = ExecutionOwnerOverloadPolicy(
            OptionalResource(),
            FailRunOnOwnerOverload();
            maximum_lateness_ns=0,
            recovery_occupancy=0,
        )
        deadline_configuration =
            serial_test_execution_owner_configuration(
                DeterministicExecutionOwners();
                owner_policy=optional_deadline_policy,
            )
        owner_deadline = serial_test_fixture(
            session=RunSessionID(0x7c2f),
            optical_execution=deadline_configuration,
        )
        Clocks.advance!(owner_deadline.clock, 1)
        owner_deadline_error = captured_serial_error() do
            step_serial_run!(owner_deadline.running)
        end
        @test owner_deadline_error isa ExecutionOwnerError
        @test owner_deadline_error.reason ==
            :owner_deadline_exceeded
        finish_serial_shutdown!(owner_deadline)
        @test run_phase(owner_deadline.run) == RunFailed
        @test execution_owners_phase(
            serial_optical_execution(owner_deadline.run)) ==
            ExecutionOwnersFailed
        owner_deadline_accounting = execution_owner_accounting(
            serial_optical_execution(owner_deadline.run), 1)
        @test owner_deadline_accounting.overload_policy ===
            optional_deadline_policy
        @test owner_deadline_accounting.overload_episodes == 1
        @test owner_deadline_accounting.maximum_lateness_ns == 1
        @test owner_deadline_accounting.overload_decision ==
            ExecutionOwnerFailedForDeadline
        @test !serial_run_accounting(
            owner_deadline.run).execution_batch_active

        invalid_execution = captured_serial_error() do
            serial_test_fixture(
                optical_execution=:not_an_execution_policy,
                arm=false,
                start=false)
        end
        @test invalid_execution isa SerialRunError
        @test invalid_execution.reason ==
            :invalid_optical_execution

        arm_failure = ExecutionOwnerError(
            :execution_owners,
            :test_arm_failure,
            "test execution-owner arm failure")
        arm_failure_fixture = serial_test_fixture(
            session=RunSessionID(0x7c30),
            optical_execution=
                SerialTestLifecycleFailureConfiguration(
                    :arm, arm_failure),
            arm=false,
            start=false,
        )
        arm_attempt = begin_serial_arm!(
            arm_failure_fixture.run,
            arm_failure_fixture.clock)
        arm_readiness = AdapterReadinessSnapshot(
            run_session(arm_failure_fixture.run),
            execution_clock_identity(arm_failure_fixture.clock),
            AdapterReady,
            Clocks.time_nanos(arm_failure_fixture.clock))
        observed_arm_failure = captured_serial_error() do
            arm_serial_run!(arm_attempt, arm_readiness)
        end
        @test observed_arm_failure === arm_failure
        @test run_phase(arm_failure_fixture.run) == RunFailed
        @test run_termination_component(
            run_termination(
                arm_failure_fixture.run)) == :serial_run
        @test run_termination_reason(
            run_termination(
                arm_failure_fixture.run)) == :ExecutionOwnerError
        @test serial_optical_execution(
            arm_failure_fixture.run).failed

        start_failure = ExecutionOwnerError(
            :execution_owners,
            :test_start_failure,
            "test execution-owner start failure")
        start_failure_fixture = serial_test_fixture(
            session=RunSessionID(0x7c31),
            optical_execution=
                SerialTestLifecycleFailureConfiguration(
                    :start, start_failure),
            start=false,
        )
        observed_start_failure = captured_serial_error() do
            start_serial_run!(start_failure_fixture.armed)
        end
        @test observed_start_failure === start_failure
        finish_serial_shutdown!(
            start_failure_fixture,
            start_failure_fixture.armed)
        @test run_phase(start_failure_fixture.run) == RunFailed
        @test run_termination_component(
            run_termination(
                start_failure_fixture.run)) == :serial_run
        @test run_termination_reason(
            run_termination(
                start_failure_fixture.run)) == :ExecutionOwnerError
        @test serial_optical_execution(
            start_failure_fixture.run).failed

        serial_oracle = run_fake_rtc(frame_count=8)
        owner_oracle = run_fake_rtc(
            frame_count=8;
            optical_execution=owner_configuration)
        @test owner_oracle.trace == serial_oracle.trace
        @test serial_run_accounting(
            serial_oracle.fixture.run).execution_owners === nothing
        @test run_phase(owner_oracle.fixture.run) == RunStopped
        @test execution_owners_phase(serial_optical_execution(
            owner_oracle.fixture.run)) == ExecutionOwnersStopped

        threaded_configuration =
            serial_test_execution_owner_configuration(
                ThreadedExecutionOwners();
                outer_owner_count=1,
            )
        threaded_fixture = serial_test_fixture(
            optical_execution=threaded_configuration)
        threaded_executor =
            serial_optical_execution(threaded_fixture.run)
        @test execution_owners_phase(threaded_executor) ==
            ExecutionOwnersRunning
        threaded_before =
            execution_owner_accounting(threaded_executor, 1)
        @test threaded_before.startup_acknowledged
        @test !iszero(threaded_before.task_id)
        @test serial_step_status(step_serial_run!(
            threaded_fixture.running)) ==
            SerialPlantEventProcessed
        threaded_after =
            execution_owner_accounting(threaded_executor, 1)
        @test threaded_after.task_id == threaded_before.task_id
        threaded_request = RunStopRequest(
            run_session(threaded_fixture.run),
            execution_clock_identity(threaded_fixture.armed.timing),
            Clocks.time_nanos(threaded_fixture.clock))
        threaded_stopped_accounting = finish_serial_stop!(
            threaded_fixture, threaded_request)
        @test execution_owners_phase(threaded_executor) ==
            ExecutionOwnersStopped
        @test execution_owner_accounting(
            threaded_executor, 1).stop_acknowledged
        threaded_stopped_owner =
            first(threaded_stopped_accounting.execution_owners)
        @test threaded_stopped_owner.stop_acknowledged
    end

    @testset "Composition and lifecycle rejection" begin
        fixture = serial_test_fixture()
        @test !applicable(
            configure_serial_run,
            fixture.plant,
            fixture.event_loop,
            fixture.bridge,
            (fixture.wfs_port,))
        endpoint = prepared_command_endpoint(
            fixture.plant, :hil_dm)
        direct_bridge = prepare_command_bridge(
            fixture.command_ports, endpoint)

        empty_error = captured_serial_error() do
            configure_serial_run(
                fixture.bridge,
                ();
                arm_timeout_ns=10,
                shutdown_policy=SERIAL_TEST_SHUTDOWN_POLICY)
        end
        @test empty_error isa SerialRunError
        @test empty_error.reason == :empty_acquisition_ports

        target_error = captured_serial_error() do
            configure_serial_run(
                direct_bridge,
                (fixture.wfs_port,);
                arm_timeout_ns=10,
                shutdown_policy=SERIAL_TEST_SHUTDOWN_POLICY)
        end
        @test target_error isa SerialRunError
        @test target_error.reason ==
            :command_target_without_event_loop

        duplicate_error = captured_serial_error() do
            configure_serial_run(
                fixture.bridge,
                (fixture.wfs_port, fixture.wfs_port);
                arm_timeout_ns=10,
                shutdown_policy=SERIAL_TEST_SHUTDOWN_POLICY)
        end
        @test duplicate_error isa SerialRunError
        @test duplicate_error.reason == :duplicate_acquisition

        other_session = RunSessionID(0x7c01)
        delivery = acquisition_delivery_contract(
            fixture.wfs_port)
        other_acquisition_port =
            prepare_acquisition_completion_port(
                AcquisitionID(:hil_dm_feedback),
                serial_product_buffers(
                    fixture.plant, :hil_dm_feedback, 1);
                session=other_session,
                product_pool_id=UInt64(0x7c30),
                delivery_contract=delivery,
                overload_policy=AcquisitionOverloadPolicy(
                    RequiredResource(),
                    RetainProducerOnFull();
                    maximum_lateness_ns=nothing,
                    recovery_occupancy=0))
        session_error = captured_serial_error() do
            configure_serial_run(
                fixture.bridge,
                (fixture.wfs_port, other_acquisition_port);
                arm_timeout_ns=10,
                shutdown_policy=SERIAL_TEST_SHUTDOWN_POLICY)
        end
        @test session_error isa SerialRunError
        @test session_error.reason == :session_mismatch

        other_command_ports = prepare_command_ports(
            endpoint,
            [zeros(Float64, 2)];
            session=other_session,
            payload_pool_id=UInt64(0x7c31),
            outcome_credit_pool_id=UInt64(0x7c32))
        other_command_bridge = prepare_command_bridge(
            other_command_ports, endpoint, fixture.event_loop)
        command_session_error = captured_serial_error() do
            configure_serial_run(
                other_command_bridge,
                (fixture.wfs_port,);
                arm_timeout_ns=10,
                shutdown_policy=SERIAL_TEST_SHUTDOWN_POLICY)
        end
        @test command_session_error isa SerialRunError
        @test command_session_error.reason == :session_mismatch

        invalid_port = captured_serial_error() do
            configure_serial_run(
                fixture.bridge,
                (fixture.wfs_port, :not_a_port);
                arm_timeout_ns=10,
                shutdown_policy=SERIAL_TEST_SHUTDOWN_POLICY)
        end
        @test invalid_port isa SerialRunError
        @test invalid_port.reason == :invalid_acquisition_port

        liveness_endpoint_error = captured_serial_error() do
            serial_test_fixture(
                ingress_liveness=RTCIngressLivenessPolicy(
                    CommandEndpointID(:other_dm),
                    ExecutionClockID(:execution_clock);
                    timeout_ns=10),
                arm=false,
                start=false)
        end
        @test liveness_endpoint_error isa SerialRunError
        @test liveness_endpoint_error.reason == :endpoint_mismatch
        invalid_liveness = captured_serial_error() do
            serial_test_fixture(
                ingress_liveness=:not_a_watchdog,
                arm=false,
                start=false)
        end
        @test invalid_liveness isa SerialRunError
        @test invalid_liveness.reason == :invalid_policy

        wrong_liveness_clock = serial_test_fixture(
            ingress_liveness=RTCIngressLivenessPolicy(
                CommandEndpointID(:hil_dm),
                ExecutionClockID(:other_execution_clock);
                timeout_ns=10),
            start=false)
        liveness_clock_error = captured_serial_error() do
            start_serial_run!(wrong_liveness_clock.armed)
        end
        @test liveness_clock_error isa RunLifecycleError
        @test liveness_clock_error.reason ==
            :clock_identity_mismatch
        finish_serial_shutdown!(
            wrong_liveness_clock,
            wrong_liveness_clock.armed)
        @test run_phase(wrong_liveness_clock.run) == RunFailed

        start_error = captured_serial_error() do
            start_serial_run!(fixture.armed)
        end
        @test start_error isa RunLifecycleError
        @test start_error.reason == :invalid_phase
        arm_error = captured_serial_error() do
            begin_serial_arm!(
                fixture.run,
                fixture.clock)
        end
        @test arm_error isa RunLifecycleError
        @test arm_error.reason == :invalid_phase

        stale_stop = captured_serial_error() do
            begin_serial_stop!(
                fixture.running,
                RunStopRequest(
                    RunSessionID(0x7c01),
                    execution_clock_identity(fixture.armed.timing),
                    Clocks.time_nanos(fixture.clock)))
        end
        @test stale_stop isa RunLifecycleError
        @test stale_stop.reason == :stale_session
        @test run_phase(fixture.run) == RunRunning

        ownership_fixture =
            serial_test_fixture(arm=false, start=false)
        claimed = Ref(PayloadLeaseRef(0, 0, 0, 0))
        @test try_claim_product!(
            claimed, ownership_fixture.wfs_port) ==
            PayloadTransitionSucceeded
        ownership_error = captured_serial_error() do
            begin_serial_arm!(
                ownership_fixture.run,
                ownership_fixture.clock)
        end
        @test ownership_error isa SerialRunError
        @test ownership_error.reason ==
            :ownership_not_quiescent
        @test run_phase(ownership_fixture.run) == RunPrepared
        @test abort_product!(
            ownership_fixture.wfs_port, claimed[]) ==
            PayloadTransitionSucceeded

        scalar_schema = serial_test_schema(dimensions=())
        scalar_endpoint = prepare_command_endpoint(
            scalar_schema; capacity=1, ordinal=1)
        inline_ports = prepare_command_ports(
            scalar_endpoint,
            Float64;
            session=RunSessionID(0x7c02),
            submission_capacity=1,
            outcome_credit_pool_id=UInt64(0x7c33))
        @test Base.invokelatest(
            AdaptiveOpticsHIL.Serial._serial_command_payload_accounting,
            command_submission_port(inline_ports)) === nothing
        @test Base.invokelatest(
            AdaptiveOpticsHIL.Serial.
                _reclaim_serial_command_payload_returns!,
            command_submission_port(inline_ports)) == 0
        @test Base.invokelatest(
            AdaptiveOpticsHIL.Serial.
                _reclaim_serial_acquisition_returns!,
            ()) == 0
        accounting = serial_run_accounting(fixture.run)
        inline_accounting = SerialRunAccounting(
            accounting.command_submissions,
            accounting.command_completions,
            accounting.command_credits,
            nothing,
            accounting.command_dispositions,
            accounting.active_command_correlations,
            accounting.acquisitions,
            accounting.execution_batch_active,
            accounting.execution_owners)
        @test serial_run_is_quiescent(inline_accounting)
    end

    @testset "Clean-stop and bounded publication failures" begin
        busy = prepare_first_wfs_publication!(
            serial_test_fixture())
        step_serial_run!(busy.running)
        busy_accounting = serial_run_accounting(busy.run)
        @test !serial_run_is_quiescent(busy_accounting)
        busy_request = RunStopRequest(
            run_session(busy.run),
            execution_clock_identity(busy.armed.timing),
            Clocks.time_nanos(busy.clock))
        stale_busy_error = captured_serial_error() do
            begin_serial_stop!(
                busy.running,
                RunStopRequest(
                    RunSessionID(0x7c01),
                    execution_clock_identity(busy.armed.timing),
                    Clocks.time_nanos(busy.clock)))
        end
        @test stale_busy_error isa RunLifecycleError
        @test stale_busy_error.reason == :stale_session
        @test run_phase(busy.run) == RunRunning
        @test begin_serial_stop!(
            busy.running, busy_request) == SerialShutdownDraining
        @test serial_shutdown_status(busy.run) ==
            SerialShutdownDraining
        closed_claim = Ref(PayloadLeaseRef(0, 0, 0, 0))
        @test try_claim_command_payload!(
            closed_claim,
            command_submission_port(busy.command_ports)) ==
            PayloadPoolClosed
        stopped_accounting = finish_serial_shutdown!(busy)
        @test serial_run_is_quiescent(stopped_accounting)
        @test run_phase(busy.run) == RunStopped
        @test run_termination_kind(run_termination(busy.run)) ==
            RequestedRunStop

        begin_failure = serial_test_fixture()
        queue_serial_test_command!(begin_failure)
        close_ring!(
            command_completion_port(
                begin_failure.command_ports).ring)
        begin_failure_error = captured_serial_error() do
            begin_serial_stop!(
                begin_failure.running,
                RunStopRequest(
                    run_session(begin_failure.run),
                    execution_clock_identity(
                        begin_failure.armed.timing),
                    Clocks.time_nanos(begin_failure.clock);
                    reason=:injected_begin_failure))
        end
        @test begin_failure_error isa PortError
        @test begin_failure_error.reason ==
            :publication_after_close
        @test serial_shutdown_status(begin_failure.run) ==
            SerialShutdownDraining
        Clocks.advance!(
            begin_failure.clock,
            drain_timeout_ns(serial_shutdown_policy(
                begin_failure.run)) + 1)
        @test progress_serial_shutdown!(begin_failure.running) ==
            SerialShutdownFinalized
        @test run_phase(begin_failure.run) == RunFailed

        closure_failure = serial_test_fixture()
        queue_serial_test_command!(closure_failure)
        close_ring!(
            command_completion_port(
                closure_failure.command_ports).ring)
        original_closure_failure =
            ArgumentError("test shutdown closure failure")
        closure_record = Base.invokelatest(
            AdaptiveOpticsHIL.Serial._record_serial_failure!,
            closure_failure.running,
            original_closure_failure)
        @test run_failure_reason(closure_record) ==
            :ArgumentError
        @test serial_shutdown_status(closure_failure.run) ==
            SerialShutdownDraining
        Clocks.advance!(
            closure_failure.clock,
            drain_timeout_ns(serial_shutdown_policy(
                closure_failure.run)) + 1)
        @test progress_serial_shutdown!(closure_failure.running) ==
            SerialShutdownFinalized
        @test run_failure_reason(first_run_failure(
            closure_failure.run.failures)) == :ArgumentError

        exhausted = serial_test_fixture(product_capacity=1)
        exhausted_error =
            drive_until_serial_failure!(exhausted)
        @test exhausted_error isa SerialRunError
        @test exhausted_error.reason ==
            :acquisition_product_capacity
        @test exhausted_error.component == :hil_wfs
        @test exhausted_error.context.acquisition ==
            AcquisitionID(:hil_wfs)
        @test exhausted_error.context.sequence == UInt64(2)
        @test exhausted_error.context.product_occupancy ==
            exhausted_error.context.product_capacity
        @test run_phase(exhausted.run) == RunFailed
        @test run_termination_kind(run_termination(exhausted.run)) ==
            ResourcePolicyRunFailure
        exhausted_termination = run_termination(exhausted.run)
        @test begin_serial_stop!(
            exhausted.running,
            RunStopRequest(
                run_session(exhausted.run),
                execution_clock_identity(exhausted.armed.timing),
                Clocks.time_nanos(exhausted.clock))) ==
            SerialShutdownFinalized
        @test run_termination(exhausted.run) ===
            exhausted_termination

        full = serial_test_fixture(
            product_capacity=2, product_ring_capacity=1)
        full_error = drive_until_serial_failure!(full)
        @test full_error isa SerialRunError
        @test full_error.reason ==
            :acquisition_product_capacity
        @test run_phase(full.run) == RunFailed

        closed = serial_test_fixture()
        close_ring!(closed.wfs_port.ring)
        closed_error = drive_until_serial_failure!(closed)
        @test closed_error isa SerialRunError
        @test closed_error.reason ==
            :acquisition_publication_rejected
        @test run_phase(closed.run) == RunFailed

        copy_failure = prepare_first_wfs_publication!(
            serial_test_fixture())
        publisher = first(copy_failure.run.publishers)
        bad_source = SERIAL_TEST_PLANT.AcquisitionProducts(
            nothing,
            nothing;
            metadata=(source=:injected_copy_failure,))
        bad_publisher =
            AdaptiveOpticsHIL.Serial.PreparedAcquisitionPublisher(
                publisher.id,
                publisher.port,
                bad_source)
        # Advance the prepared plant directly to the due acquisition product,
        # leaving the serial publication operation uncalled so this
        # disposable fixture can inject a copy failure at its ownership
        # boundary.
        event_state = plant_event_loop_state(
            copy_failure.run.state.bridge)
        event_workspace = plant_event_loop_workspace(
            copy_failure.run.workspace.bridge)
        due_timestamp = next_plant_event_timestamp(
            copy_failure.run.configuration.event_loop,
            event_state,
            event_workspace)
        @test step_plant_events!(
            copy_failure.run.configuration.event_loop,
            event_state,
            event_workspace,
            copy_failure.run.execution) == due_timestamp
        products_before =
            acquisition_product_accounting(publisher.port)
        copy_failure_error = captured_serial_error() do
            AdaptiveOpticsHIL.Serial._publish_serial_products!(
                (bad_publisher,),
                copy_failure.armed,
                copy_failure.run.state,
                copy_failure.run.workspace,
                Clocks.time_nanos(copy_failure.clock),
                1)
        end
        @test copy_failure_error isa
            SERIAL_TEST_PLANT.PlantPreparationError
        products_after =
            acquisition_product_accounting(publisher.port)
        @test products_after.free == products_before.free
        Base.invokelatest(
            AdaptiveOpticsHIL.Serial._record_serial_failure!,
            copy_failure.running,
            copy_failure_error)
        finish_serial_shutdown!(copy_failure)

        generic_failure = serial_test_fixture()
        generic_error = ArgumentError("test generic runtime failure")
        failure_record = Base.invokelatest(
            AdaptiveOpticsHIL.Serial._record_serial_failure!,
            generic_failure.running,
            generic_error)
        @test failure_record isa RunFailureRecord
        finish_serial_shutdown!(generic_failure)
        @test run_phase(generic_failure.run) == RunFailed
        invalid_reading_termination =
            run_termination(generic_failure.run)
        @test run_termination_component(
            invalid_reading_termination) == :serial_run
        @test run_termination_reason(
            invalid_reading_termination) == :ArgumentError
        @test AdaptiveOpticsHIL.Serial._serial_failure_kind(
            SerialRunError(
                :serial_run,
                :injected_owner_exception,
                "test serial owner exception")) ==
            OwnerExceptionRunFailure

        unavailable_clock = ToggleReadingNanoClock(0, false)
        unavailable = serial_test_fixture(
            clock=unavailable_clock)
        unavailable_stop = RunStopRequest(
            run_session(unavailable.run),
            execution_clock_identity(unavailable.armed.timing),
            Clocks.time_nanos(unavailable.clock);
            reason=:execution_clock_failure)
        @test begin_serial_stop!(
            unavailable.running, unavailable_stop) ==
            SerialShutdownDraining
        unavailable_clock.invalid = true
        @test progress_serial_shutdown!(unavailable.running) ==
            SerialShutdownFinalized
        @test unavailable.run.state.shutdown.clock_unavailable
        @test run_phase(unavailable.run) == RunFailed
        @test run_termination_component(
            run_termination(unavailable.run)) == :execution_clock
        @test run_termination_reason(
            run_termination(unavailable.run)) == :unavailable

        failure_clock = ToggleReadingNanoClock(0, false)
        unavailable_failure = serial_test_fixture(
            clock=failure_clock)
        failure_clock.invalid = true
        unavailable_record = Base.invokelatest(
            AdaptiveOpticsHIL.Serial._record_serial_failure!,
            unavailable_failure.running,
            ArgumentError("test unavailable failure clock"))
        @test run_failure_execution_ns(unavailable_record) ===
            nothing
        @test unavailable_failure.run.state.shutdown.clock_unavailable
        failure_clock.invalid = false
        finish_serial_shutdown!(unavailable_failure)

        armed = serial_test_fixture(start=false)
        armed_request = RunStopRequest(
            run_session(armed.run),
            execution_clock_identity(armed.armed.timing),
            Clocks.time_nanos(armed.clock);
            reason=:stop_before_run)
        @test serial_run_is_quiescent(
            finish_serial_stop!(
                armed, armed_request, armed.armed))
        @test run_phase(armed.run) == RunStopped

        terminal = serial_test_fixture()
        terminal_event = RunTerminalEvent(
            run_session(terminal.run),
            execution_clock_identity(terminal.armed.timing),
            PlantTimestamp(0),
            Clocks.time_nanos(terminal.clock);
            reason=:configured_terminal)
        @test serial_run_is_quiescent(
            finish_serial_stop!(terminal, terminal_event))
        @test run_phase(terminal.run) == RunStopped
        @test run_termination_kind(run_termination(terminal.run)) ==
            ConfiguredTerminalStop

        fresh = serial_test_fixture(
            session=RunSessionID(0x7c03))
        @test run_session(fresh.run) != run_session(terminal.run)
        @test run_phase(fresh.run) == RunRunning
    end

    @testset "Bounded failure coordination and deficit evidence" begin
        commands = serial_test_fixture(
            session=RunSessionID(0x7c40))
        @test serial_step_status(
            step_serial_run!(commands.running)) ==
            SerialPlantEventProcessed
        queue_serial_test_command!(
            commands;
            stream_sequence=1,
            command_sequence=1,
            receive_ns=1,
            effective_ns=2_000_000,
            advance_ns=1)
        admitted = false
        for _ in 1:8
            result = step_serial_run!(commands.running)
            if serial_step_status(result) == SerialCommandProcessed
                admitted = true
                break
            end
            serial_step_status(result) == SerialDeadlinePending &&
                Clocks.advance!(
                    commands.clock,
                    serial_step_time_until_ns(result))
        end
        @test admitted
        queue_serial_test_command!(
            commands;
            stream_sequence=2,
            command_sequence=2,
            receive_ns=2,
            effective_ns=3_000_000,
            advance_ns=1)
        command_stop = RunStopRequest(
            run_session(commands.run),
            execution_clock_identity(commands.armed.timing),
            Clocks.time_nanos(commands.clock);
            reason=:command_drain_test)
        @test begin_serial_stop!(
            commands.running, command_stop) ==
            SerialShutdownDraining
        @test progress_serial_shutdown!(commands.running) ==
            SerialShutdownDraining
        if SERIAL_TESTS_WITH_COVERAGE
            @test_skip "shutdown-drain allocation gate disabled under coverage"
        else
            serial_shutdown_progress_allocations!(commands.running)
            @test serial_shutdown_progress_allocations!(
                commands.running) == 0
        end

        outcomes = Dict{UInt64,CommandOutcome{LeasedCommandPayload}}()
        outcome_ref =
            Ref{CommandOutcome{LeasedCommandPayload}}()
        completion =
            command_completion_port(commands.command_ports)
        while true
            result = try_take!(outcome_ref, completion)
            port_status(result) in (PortEmpty, PortClosed) &&
                break
            @test port_status(result) == PortTransferSucceeded
            outcome = outcome_ref[]
            sequence = stream_sequence_value(
                outcome_stream_sequence(outcome))
            @test !haskey(outcomes, sequence)
            outcomes[sequence] = outcome
        end
        @test sort!(collect(keys(outcomes))) == UInt64[1, 2]
        admitted_outcome = outcomes[1]
        @test outcome_stage(admitted_outcome) ==
            CoreCommandOutcome
        @test outcome_terminal_kind(admitted_outcome) ==
            SERIAL_TEST_PLANT.FailedCommand
        @test outcome_reason(admitted_outcome) ==
            :hil_run_shutdown
        transferred_outcome = outcomes[2]
        @test outcome_stage(transferred_outcome) ==
            BoundaryCommandOutcome
        @test outcome_boundary_reason(transferred_outcome) ==
            RunNotAccepting
        for outcome in values(outcomes)
            @test port_status(release_outcome!(
                completion, outcome)) ==
                PortTransferSucceeded
        end
        command_accounting =
            finish_serial_shutdown!(commands)
        @test serial_run_is_quiescent(command_accounting)
        @test run_phase(commands.run) == RunStopped
        @test SERIAL_TEST_PLANT.effective_command(
            commands.event_loop,
            plant_event_loop_state(commands.run.state.bridge),
            CommandEndpointID(:hil_dm)) == zeros(Float64, 2)

        timeout_policy = RunShutdownPolicy(
            acknowledgement_timeout_ns=10,
            drain_timeout_ns=20)
        lease_deficit = prepare_first_wfs_publication!(
            serial_test_fixture(
                session=RunSessionID(0x7c41),
                shutdown_policy=timeout_policy))
        @test serial_step_status(
            step_serial_run!(lease_deficit.running)) ==
            SerialPlantEventProcessed
        held_product = Ref{AcquisitionCompletion}()
        @test port_status(try_take!(
            held_product, lease_deficit.wfs_port)) ==
            PortTransferSucceeded
        release_all_serial_products!(
            lease_deficit.feedback_port)
        lease_stop = RunStopRequest(
            run_session(lease_deficit.run),
            execution_clock_identity(lease_deficit.armed.timing),
            Clocks.time_nanos(lease_deficit.clock);
            reason=:lease_deficit_test)
        @test begin_serial_stop!(
            lease_deficit.running, lease_stop) ==
            SerialShutdownDraining
        @test progress_serial_shutdown!(
            lease_deficit.running) ==
            SerialShutdownDraining
        Clocks.advance!(lease_deficit.clock, 21)
        @test progress_serial_shutdown!(
            lease_deficit.running) ==
            SerialShutdownFinalized
        @test run_phase(lease_deficit.run) == RunFailed
        @test run_termination_kind(
            run_termination(lease_deficit.run)) ==
            DrainTimeoutRunFailure
        lease_failure =
            serial_failure_accounting(lease_deficit.run)
        @test lease_failure.drain_timed_out
        @test run_failure_kind(lease_failure.first_failure) ==
            DrainTimeoutRunFailure
        lease_accounting =
            serial_run_accounting(lease_deficit.run)
        wfs_deficit = only(
            acquisition for acquisition in
                lease_accounting.acquisitions
            if acquisition.acquisition ==
                AcquisitionID(:hil_wfs))
        @test wfs_deficit.products.consumer_leased == 1
        @test wfs_deficit.products.free ==
            wfs_deficit.products.capacity - 1
        @test port_status(release_product!(
            lease_deficit.wfs_port,
            held_product[])) ==
            PortTransferSucceeded
        reclaim_serial_returns!(lease_deficit.run)
        reclaimed_wfs = only(
            acquisition for acquisition in
                serial_run_accounting(
                    lease_deficit.run).acquisitions
            if acquisition.acquisition ==
                AcquisitionID(:hil_wfs))
        @test reclaimed_wfs.products.free ==
            reclaimed_wfs.products.capacity

        exact_drain = serial_test_fixture(
            session=RunSessionID(0x7c43),
            shutdown_policy=timeout_policy)
        queue_serial_test_command!(
            exact_drain;
            stream_sequence=1,
            command_sequence=1,
            receive_ns=1,
            advance_ns=1)
        exact_stop = RunStopRequest(
            run_session(exact_drain.run),
            execution_clock_identity(exact_drain.armed.timing),
            Clocks.time_nanos(exact_drain.clock);
            reason=:exact_drain_deadline_test)
        @test begin_serial_stop!(
            exact_drain.running, exact_stop) ==
            SerialShutdownDraining
        @test progress_serial_shutdown!(
            exact_drain.running) ==
            SerialShutdownDraining
        @test release_all_serial_command_outcomes!(
            exact_drain) == 1
        reclaim_serial_returns!(exact_drain.run)
        Clocks.advance!(exact_drain.clock, 20)
        @test progress_serial_shutdown!(exact_drain.running) ==
            SerialShutdownFinalized
        @test run_phase(exact_drain.run) == RunStopped

        late_drain = serial_test_fixture(
            session=RunSessionID(0x7c44),
            shutdown_policy=timeout_policy)
        queue_serial_test_command!(
            late_drain;
            stream_sequence=1,
            command_sequence=1,
            receive_ns=1,
            advance_ns=1)
        late_stop = RunStopRequest(
            run_session(late_drain.run),
            execution_clock_identity(late_drain.armed.timing),
            Clocks.time_nanos(late_drain.clock);
            reason=:late_drain_observation_test)
        @test begin_serial_stop!(
            late_drain.running, late_stop) ==
            SerialShutdownDraining
        @test progress_serial_shutdown!(late_drain.running) ==
            SerialShutdownDraining
        @test release_all_serial_command_outcomes!(
            late_drain) == 1
        reclaim_serial_returns!(late_drain.run)
        Clocks.advance!(late_drain.clock, 21)
        @test progress_serial_shutdown!(late_drain.running) ==
            SerialShutdownFinalized
        @test run_phase(late_drain.run) == RunFailed
        @test run_termination_kind(
            run_termination(late_drain.run)) ==
            DrainTimeoutRunFailure

        missing_ack_configuration =
            serial_test_execution_owner_configuration(
                DeterministicExecutionOwners())
        missing_ack = serial_test_fixture(
            session=RunSessionID(0x7c42),
            optical_execution=missing_ack_configuration,
            shutdown_policy=timeout_policy)
        acknowledgement_stop = RunStopRequest(
            run_session(missing_ack.run),
            execution_clock_identity(missing_ack.armed.timing),
            Clocks.time_nanos(missing_ack.clock);
            reason=:acknowledgement_deficit_test)
        @test begin_serial_stop!(
            missing_ack.running, acknowledgement_stop) ==
            SerialShutdownDraining
        owner_signal = missing_ack.run.failures.signals[2]
        @atomic :release owner_signal.acknowledged_stop_epoch =
            UInt64(0)
        Clocks.advance!(missing_ack.clock, 11)
        @test progress_serial_shutdown!(missing_ack.running) ==
            SerialShutdownDraining
        acknowledgement_failure =
            serial_failure_accounting(missing_ack.run)
        @test run_failure_kind(
            acknowledgement_failure.first_failure) ==
            AcknowledgementTimeoutRunFailure
        acknowledgement_owner =
            acknowledgement_failure.owners[2]
        @test !acknowledgement_owner.acknowledged
        @test acknowledgement_owner.acknowledgement_timed_out
        @test run_owner_component(
            acknowledgement_owner.owner) ==
            :path_execution_owner
        @test run_owner_ordinal(
            acknowledgement_owner.owner) == 1
        Clocks.advance!(missing_ack.clock, 10)
        @test progress_serial_shutdown!(missing_ack.running) ==
            SerialShutdownFinalized
        @test run_phase(missing_ack.run) == RunFailed
        @test run_termination_kind(
            run_termination(missing_ack.run)) ==
            AcknowledgementTimeoutRunFailure
        final_ack_accounting =
            serial_failure_accounting(missing_ack.run)
        @test final_ack_accounting.drain_timed_out
        final_ack_owner = final_ack_accounting.owners[2]
        @test final_ack_owner.acknowledgement_timed_out
    end

    @testset "Deterministic fake RTC closes the reduced-order loop" begin
        matched_a = run_fake_rtc()
        matched_b = run_fake_rtc()
        open_loop = run_fake_rtc(sign=0.0)
        wrong_sign = run_fake_rtc(sign=1.0)
        delayed = run_fake_rtc(delay_frames=2)

        @test matched_a.trace == matched_b.trace

        matched_tail = serial_test_mean(
            last(matched_a.trace.residual_metric, 8))
        open_tail = serial_test_mean(
            last(open_loop.trace.residual_metric, 8))
        wrong_tail = serial_test_mean(
            last(wrong_sign.trace.residual_metric, 8))
        delayed_tail = serial_test_mean(
            last(delayed.trace.residual_metric, 8))
        @test matched_tail < open_tail
        @test matched_tail < wrong_tail
        @test matched_tail < delayed_tail

        expected_commands = UInt64.(1:35)
        @test matched_a.trace.command_stream_sequences ==
            expected_commands
        @test length(
            matched_a.trace.command_admission_execution_ns) ==
            length(expected_commands)
        @test matched_a.trace.outcome_stream_sequences ==
            expected_commands
        @test matched_a.trace.outcome_ingress_execution_ns ==
            matched_a.trace.command_ingress_execution_ns
        @test matched_a.trace.command_admission_plant_timestamps ==
            matched_a.trace.command_receive_plant_timestamps
        @test matched_a.trace.command_admission_execution_ns ==
            matched_a.trace.command_ingress_execution_ns
        @test all(
            matched_a.trace.outcome_application_timestamps .<=
            matched_a.trace.outcome_publication_execution_ns)
        @test all(
            matched_a.trace.product_publication_execution_ns .<=
            matched_a.trace.adapter_observation_execution_ns)

        first_application =
            first(matched_a.trace.outcome_application_timestamps)
        @test first_application == 2_000_000
        @test first(
            matched_a.trace.command_responsive_optical_sample_timestamps) ==
            first_application
        @test first_application in
            matched_a.trace.event_sample_timestamps
        @test matched_a.trace.measurements[2] !=
            open_loop.trace.measurements[2]

        @test !isempty(matched_a.trace.feedback_sequences)
        @test matched_a.trace.feedback_sequences ==
            UInt64.(1:length(matched_a.trace.feedback_sequences))
        @test diff(matched_a.trace.feedback_completion_timestamps) ==
            fill(3_000_000,
                length(matched_a.trace.feedback_completion_timestamps) - 1)
        @test first(
            matched_a.trace.feedback_completion_timestamps) ==
            1_500_000
        @test any(value -> !all(iszero, value),
            matched_a.trace.feedback_values)
        @test matched_a.trace.feedback_completion_timestamps !=
            matched_a.trace.outcome_application_timestamps

        @test serial_run_is_quiescent(matched_a.accounting)
        @test serial_products_published(matched_a.fixture.run) ==
            length(matched_a.trace.all_wfs_sequences) +
            length(matched_a.trace.feedback_sequences)
        @test matched_a.accounting.command_credits.free ==
            matched_a.accounting.command_credits.capacity
        @test all(
            acquisition -> acquisition.products.free ==
                acquisition.products.capacity,
            matched_a.accounting.acquisitions)
        @test run_phase(matched_a.fixture.run) == RunStopped
    end
end
