module Gate4ASerialWorkload

using AdaptiveOpticsHIL.Execution
using AdaptiveOpticsHIL.Lifecycle
using AdaptiveOpticsHIL.Ownership
using AdaptiveOpticsHIL.Ports
using AdaptiveOpticsHIL.Serial
using AdaptiveOpticsHIL.Timing: execution_clock_identity
import AdaptiveOpticsSim
using AdaptiveOpticsSim.Atmospheres
using AdaptiveOpticsSim.Atmospheres: MultiLayerAtmosphereDefinition
using AdaptiveOpticsSim.Backends
using AdaptiveOpticsSim.Backends: HostComputeDevice
using AdaptiveOpticsSim.Optics
using AdaptiveOpticsSim.Optics: TelescopeDefinition
using AdaptiveOpticsSim.Plant
using AdaptiveOpticsSim.WavefrontSensors
using AdaptiveOpticsSim.Plant: AbsoluteCommand, ClipInvalidCommand
using AdaptiveOpticsSim.Plant: AllPathVisibility
using AdaptiveOpticsSim.Plant: ColdPlantModelDefinition
using AdaptiveOpticsSim.Plant: CommandEffectiveTimePolicy
using AdaptiveOpticsSim.Plant: CommandSequencePolicy
using AdaptiveOpticsSim.Plant: CommandSilencePolicy, CommandValuePolicy
using AdaptiveOpticsSim.Plant: EnforceOnApplication
using AdaptiveOpticsSim.Plant: PreservePendingCommands
using AdaptiveOpticsSim.Plant: PreparedPathExecutor
using AdaptiveOpticsSim.Plant: PupilPlanePlacement
using AdaptiveOpticsSim.Plant: UniformCommandBounds
using AdaptiveOpticsSim.Plant: acquisition_product_sequence
using AdaptiveOpticsSim.Plant: acquisition_products
using AdaptiveOpticsSim.Plant: command_basis, command_basis_revision
using AdaptiveOpticsSim.Plant: command_dimensions, command_endpoint_id
using AdaptiveOpticsSim.Plant: command_schemas
using AdaptiveOpticsSim.Plant: command_sign_convention, command_units
using AdaptiveOpticsSim.Plant: prepare_pupil_opd_materialization
using AdaptiveOpticsSim.Plant: prepared_acquisition
using AdaptiveOpticsSim.Plant: prepared_command_endpoint
using Clocks

const Plant = AdaptiveOpticsSim.Plant
const _IDENTITY_2X2 = [1.0 0.0; 0.0 1.0]
const _HIL_WFS_ACQUISITION = Plant.AcquisitionID(:hil_wfs)
const _HIL_DM_FEEDBACK_ACQUISITION =
    Plant.AcquisitionID(:hil_dm_feedback)
const _HIL_SCIENCE_ACQUISITION =
    Plant.AcquisitionID(:hil_science)

struct Gate4AWorkloadConfig
    primary_period_ns::Int64
    primary_exposure_ns::Int64
    optical_sample_period_ns::Int64
    feedback_period_ns::Int64
    feedback_phase_ns::Int64
    feedback_exposure_ns::Int64
    science_enabled::Bool
    science_sample_period_ns::Int64
    science_period_ns::Int64
    science_exposure_ns::Int64
    command_capacity::Int
    primary_product_capacity::Int
    feedback_product_capacity::Int
    science_product_capacity::Int
    complete_product_lead_time_ns::Int64
    maximum_lease_hold_time_ns::Int64
    controller_gain::Float64
    run_seed::UInt64
end

function Gate4AWorkloadConfig(;
    primary_period_ns::Integer=500_000,
    primary_exposure_ns::Integer=100_000,
    optical_sample_period_ns::Integer=100_000,
    feedback_period_ns::Integer=750_000,
    feedback_phase_ns::Integer=125_000,
    feedback_exposure_ns::Integer=100_000,
    science_enabled::Bool=false,
    science_sample_period_ns::Integer=1_000_000,
    science_period_ns::Integer=2_000_000,
    science_exposure_ns::Integer=500_000,
    command_capacity::Integer=8,
    primary_product_capacity::Integer=64,
    feedback_product_capacity::Integer=64,
    science_product_capacity::Integer=8,
    complete_product_lead_time_ns::Integer=500_000,
    maximum_lease_hold_time_ns::Integer=2_000_000,
    controller_gain::Real=0.65,
    run_seed::Integer=0x7c00)
    primary_period_ns > 0 || error(
        "primary acquisition period must be positive")
    0 < primary_exposure_ns <= primary_period_ns || error(
        "primary exposure must be positive and no longer than its period")
    optical_sample_period_ns > 0 || error(
        "optical sample period must be positive")
    feedback_period_ns > 0 || error(
        "feedback acquisition period must be positive")
    0 <= feedback_phase_ns < feedback_period_ns || error(
        "feedback phase must lie inside one feedback period")
    0 < feedback_exposure_ns <= feedback_period_ns || error(
        "feedback exposure must be positive and no longer than its period")
    science_sample_period_ns > 0 || error(
        "science-path sample period must be positive")
    science_period_ns > 0 || error(
        "science acquisition period must be positive")
    0 < science_exposure_ns <= science_period_ns || error(
        "science exposure must be positive and no longer than its period")
    command_capacity > 0 || error(
        "command capacity must be positive")
    primary_product_capacity > 0 || error(
        "primary product capacity must be positive")
    feedback_product_capacity > 0 || error(
        "feedback product capacity must be positive")
    science_product_capacity > 0 || error(
        "science product capacity must be positive")
    complete_product_lead_time_ns >= 0 || error(
        "complete-product lead time must be nonnegative")
    maximum_lease_hold_time_ns > 0 || error(
        "maximum lease-hold time must be positive")
    isfinite(controller_gain) && controller_gain > 0 || error(
        "controller gain must be finite and positive")
    0 <= run_seed <= typemax(UInt64) || error(
        "run seed must fit UInt64")
    return Gate4AWorkloadConfig(
        Int64(primary_period_ns),
        Int64(primary_exposure_ns),
        Int64(optical_sample_period_ns),
        Int64(feedback_period_ns),
        Int64(feedback_phase_ns),
        Int64(feedback_exposure_ns),
        science_enabled,
        Int64(science_sample_period_ns),
        Int64(science_period_ns),
        Int64(science_exposure_ns),
        Int(command_capacity),
        Int(primary_product_capacity),
        Int(feedback_product_capacity),
        Int(science_product_capacity),
        Int64(complete_product_lead_time_ns),
        Int64(maximum_lease_hold_time_ns),
        Float64(controller_gain),
        UInt64(run_seed))
end

struct Gate4AReducedOrderPathModel end
struct Gate4AReducedOrderOpticModel end

struct Gate4AReducedOrderPathExecution{E}
    imaging::E
end

struct PreparedGate4AReducedOrderOptic
    endpoint::CommandEndpointID
    command_count::Int
end

mutable struct Gate4AReducedOrderOpticState{V<:AbstractVector}
    visible::V
end

mutable struct Gate4AReducedOrderOpticWorkspace{V<:AbstractVector}
    staged::V
end

Plant.plant_model_definition_style(
    ::Type{Gate4AReducedOrderPathModel}) =
    ColdPlantModelDefinition()
Plant.plant_model_definition_style(
    ::Type{Gate4AReducedOrderOpticModel}) = ColdPlantModelDefinition()

function Plant.validate_path_execution_binding(
    execution::Gate4AReducedOrderPathExecution,
    input,
    result)
    return Plant.validate_path_execution_binding(
        execution.imaging, input, result)
end

function Plant.execute_path!(
    result,
    input,
    execution::Gate4AReducedOrderPathExecution)
    return Plant.execute_path!(
        result, input, execution.imaging)
end

function Plant.validate_path_execution_target(
    execution::Gate4AReducedOrderPathExecution,
    target::AdaptiveOpticsSim.Backends.AbstractComputeDevice)
    Plant.validate_path_execution_target(execution.imaging, target)
    return execution
end

function Plant.validate_controllable_optic_target(
    prepared::PreparedGate4AReducedOrderOptic,
    ::AdaptiveOpticsSim.Backends.AbstractComputeDevice)
    # Endpoint identity and command cardinality are host configuration;
    # target-local arrays live in the separately validated state/workspace.
    return prepared
end

function Plant.validate_controllable_optic_state_target(
    ::PreparedGate4AReducedOrderOptic,
    state::Gate4AReducedOrderOpticState,
    target::AdaptiveOpticsSim.Backends.AbstractComputeDevice)
    compute_device(state.visible) == target || throw(PlantPreparationError(
        :controllable_optic, :wrong_device,
        "Gate 4A visible command occupies another target"))
    return state
end

function Plant.validate_controllable_optic_workspace_target(
    ::PreparedGate4AReducedOrderOptic,
    workspace::Gate4AReducedOrderOpticWorkspace,
    target::AdaptiveOpticsSim.Backends.AbstractComputeDevice)
    compute_device(workspace.staged) == target || throw(PlantPreparationError(
        :controllable_optic, :wrong_device,
        "Gate 4A staged command occupies another target"))
    return workspace
end

function Plant.prepare_path_executor(
    ::Gate4AReducedOrderPathModel,
    definition::OpticalPathDefinition,
    source::AdaptiveOpticsSim.Optics.AbstractSource,
    telescope::Telescope,
    atmosphere::AdaptiveOpticsSim.Atmospheres.AbstractTimedAtmosphere,
    context)
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
        Gate4AReducedOrderPathExecution(imaging);
        context=context,
        materialization=prepare_pupil_opd_materialization(
            atmosphere, telescope, source, pupil),
        optical_model=:gate4a_reduced_order_unused_direct_imaging,
        propagation_model=:fraunhofer_fft,
        model_revisions=UInt(1))
end

function Plant.prepare_controllable_optic(
    ::Gate4AReducedOrderOpticModel,
    definition::ControllableOpticDefinition,
    ::Telescope,
    ::AdaptiveOpticsSim.Atmospheres.AbstractAtmosphere)
    schema = only(command_schemas(definition))
    dimensions = command_dimensions(schema)
    length(dimensions) == 1 || throw(PlantPreparationError(
        :controllable_optic,
        :invalid_dimensions,
        "Gate 4A reduced-order optic requires a vector command"))
    return PreparedGate4AReducedOrderOptic(
        command_endpoint_id(schema), only(dimensions))
end

function Plant.prepare_controllable_optic_state(
    prepared::PreparedGate4AReducedOrderOptic,
    ::ControllableOpticDefinition,
    endpoint_ids::Tuple,
    initial_commands::Tuple)
    only(endpoint_ids) == prepared.endpoint || throw(
        PlantPreparationError(
            :controllable_optic,
            :prepared_binding,
            "Gate 4A reduced-order optic endpoint changed"))
    initial = only(initial_commands)
    length(initial) == prepared.command_count || throw(
        PlantPreparationError(
            :controllable_optic,
            :prepared_binding,
            "Gate 4A reduced-order optic command shape changed"))
    return Gate4AReducedOrderOpticState(initial)
end

function Plant.prepare_controllable_optic_workspace(
    prepared::PreparedGate4AReducedOrderOptic)
    return Gate4AReducedOrderOpticWorkspace(
        zeros(Float64, prepared.command_count))
end

function Plant.stage_controllable_optic_command!(
    prepared::PreparedGate4AReducedOrderOptic,
    ::Gate4AReducedOrderOpticState,
    workspace::Gate4AReducedOrderOpticWorkspace,
    endpoint::CommandEndpointID,
    command::AbstractVector,
    ::PlantTimestamp)
    endpoint == prepared.endpoint || throw(PlantCommandError(
        :physical_application,
        :endpoint_mismatch,
        "Gate 4A reduced-order optic received another endpoint"))
    copyto!(workspace.staged, command)
    return nothing
end

function Plant.commit_controllable_optic_command!(
    ::PreparedGate4AReducedOrderOptic,
    state::Gate4AReducedOrderOpticState,
    workspace::Gate4AReducedOrderOpticWorkspace,
    ::CommandEndpointID,
    ::PlantTimestamp)
    copyto!(state.visible, workspace.staged)
    return nothing
end

function gate4a_command_schema()
    T = Float64
    endpoint = :hil_dm
    return PlantCommandSchema(
        T,
        (2,);
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

function _command_response(schema, operator)
    return Plant.ReducedOrderCommandResponse(
        command_endpoint_id(schema), operator;
        units=command_units(schema),
        sign_convention=command_sign_convention(schema),
        basis=command_basis(schema),
        basis_revision=command_basis_revision(schema))
end

function _reduced_order_model(
    schema;
    disturbance,
    response_operator,
    measurement_kind,
    residual_kind,
    sample_period_ns)
    T = Float64
    return Plant.LinearReducedOrderAcquisitionModel(
        disturbance,
        Matrix{T}(_IDENTITY_2X2),
        Matrix{T}(_IDENTITY_2X2),
        (_command_response(schema, response_operator),);
        measurement_kind,
        measurement_units=:metre,
        residual_kind,
        residual_units=:metre,
        calibration_revision=1,
        operating_envelope=(
            maximum_absolute_residual_m=20.0,
            maximum_disturbance_frequency_hz=40.0,
            sample_period_ns),
        omitted_effects=(
            :diffraction,
            :spatial_aliasing,
            :detector_noise,
            :device_dynamics,
            :coronagraph_propagation))
end

function _prepare_gate4a_plant(config::Gate4AWorkloadConfig)
    T = Float64
    schema = gate4a_command_schema()
    disturbance = Plant.HarmonicDisturbanceModel(
        T[0.30, -0.22],
        T[19.0, 31.0];
        offsets=T[0.05, -0.03],
        phases_rad=T[0.2, -0.4])
    feedback_disturbance = Plant.HarmonicDisturbanceModel(
        zeros(T, 2),
        zeros(T, 2);
        offsets=zeros(T, 2),
        phases_rad=zeros(T, 2))
    residual_model = _reduced_order_model(
        schema;
        disturbance,
        response_operator=Matrix{T}(_IDENTITY_2X2),
        measurement_kind=:modal_residual,
        residual_kind=:modal_wavefront_error,
        sample_period_ns=config.optical_sample_period_ns)
    feedback_model = _reduced_order_model(
        schema;
        disturbance=feedback_disturbance,
        response_operator=Matrix{T}(_IDENTITY_2X2),
        measurement_kind=:sampled_actuator_state,
        residual_kind=:actuator_state,
        sample_period_ns=config.optical_sample_period_ns)
    science_model = _reduced_order_model(
        schema;
        disturbance,
        response_operator=Matrix{T}(_IDENTITY_2X2),
        measurement_kind=:science_modal_residual,
        residual_kind=:science_modal_wavefront_error,
        sample_period_ns=config.science_sample_period_ns)

    telescope = TelescopeDefinition(
        resolution=8,
        diameter=T(8),
        central_obstruction=zero(T),
        revision=1,
        T=T)
    atmosphere = MultiLayerAtmosphereDefinition(;
        r0=T(0.2),
        L0=T(25),
        fractional_cn2=T[1],
        wind_speed=T[0],
        wind_direction_deg=T[0],
        altitude=T[0],
        layer_ids=(:ground,),
        T=T)
    source = Source(
        band=:custom,
        wavelength=T(0.8e-6),
        photon_irradiance=T(1),
        T=T)
    path = OpticalPathDefinition(
        :hil_wfs_path,
        source,
        Gate4AReducedOrderPathModel())
    science_path = OpticalPathDefinition(
        :hil_science_path, source, Gate4AReducedOrderPathModel())
    residual_acquisition = AcquisitionDefinition(
        :hil_wfs, :hil_wfs_path, residual_model)
    feedback_acquisition = AcquisitionDefinition(
        :hil_dm_feedback, :hil_wfs_path, feedback_model)
    science_acquisition = AcquisitionDefinition(
        :hil_science, :hil_science_path, science_model)
    optic = ControllableOpticDefinition(
        :hil_dm,
        Gate4AReducedOrderOpticModel(),
        (schema,);
        placement=PupilPlanePlacement(),
        visibility=AllPathVisibility())
    paths = config.science_enabled ? (path, science_path) : (path,)
    acquisitions = config.science_enabled ?
        (
            residual_acquisition,
            feedback_acquisition,
            science_acquisition,
        ) :
        (residual_acquisition, feedback_acquisition)
    definition = PlantDefinition(
        ;
        telescope,
        atmosphere,
        controllable_optics=(optic,),
        paths,
        acquisitions)
    plant = prepare_plant(
        definition,
        HostComputeDevice();
        run_seed=config.run_seed,
        command_endpoints=(
            CommandEndpointConfiguration(
                :hil_dm,
                zeros(T, 2);
                capacity=config.command_capacity),
        ))
    optical_samples = config.science_enabled ?
        (
            OpticalSampleDefinition(
                :hil_wfs_path,
                PeriodicSchedule(
                    period_ns=config.optical_sample_period_ns,
                    phase_ns=0)),
            OpticalSampleDefinition(
                :hil_science_path,
                PeriodicSchedule(
                    period_ns=config.science_sample_period_ns,
                    phase_ns=0)),
        ) :
        (
            OpticalSampleDefinition(
                :hil_wfs_path,
                PeriodicSchedule(
                    period_ns=config.optical_sample_period_ns,
                    phase_ns=0)),
        )
    acquisition_events = config.science_enabled ?
        (
            AcquisitionEventDefinition(
                :hil_wfs,
                DirectMeasurementAcquisitionDefinition(
                    PlantDuration(config.primary_exposure_ns)),
                PeriodicAcquisitionStart(
                    PeriodicSchedule(
                        period_ns=config.primary_period_ns,
                        phase_ns=0))),
            AcquisitionEventDefinition(
                :hil_dm_feedback,
                DirectMeasurementAcquisitionDefinition(
                    PlantDuration(config.feedback_exposure_ns)),
                PeriodicAcquisitionStart(
                    PeriodicSchedule(
                        period_ns=config.feedback_period_ns,
                        phase_ns=config.feedback_phase_ns))),
            AcquisitionEventDefinition(
                :hil_science,
                DirectMeasurementAcquisitionDefinition(
                    PlantDuration(config.science_exposure_ns)),
                PeriodicAcquisitionStart(
                    PeriodicSchedule(
                        period_ns=config.science_period_ns,
                        phase_ns=0))),
        ) :
        (
            AcquisitionEventDefinition(
                :hil_wfs,
                DirectMeasurementAcquisitionDefinition(
                    PlantDuration(config.primary_exposure_ns)),
                PeriodicAcquisitionStart(
                    PeriodicSchedule(
                        period_ns=config.primary_period_ns,
                        phase_ns=0))),
            AcquisitionEventDefinition(
                :hil_dm_feedback,
                DirectMeasurementAcquisitionDefinition(
                    PlantDuration(config.feedback_exposure_ns)),
                PeriodicAcquisitionStart(
                    PeriodicSchedule(
                        period_ns=config.feedback_period_ns,
                        phase_ns=config.feedback_phase_ns))),
        )
    event_loop = prepare_plant_event_loop(
        plant,
        PlantEventLoopDefinition(
            optical_samples,
            acquisition_events))
    return (; plant, event_loop, schema)
end

function _product_buffers(plant, id, count)
    source = acquisition_products(prepared_acquisition(plant, id))
    return [deepcopy(source) for _ in 1:count]
end

function prepare_gate4a_fixture(
    clock::Clocks.AbstractNanoClock,
    config::Gate4AWorkloadConfig=Gate4AWorkloadConfig();
    optical_execution::AbstractOpticalExecutionConfiguration=
        SerialOpticalExecution(),
    arm_timeout_ns::Integer=1_000_000_000,
    shutdown_policy::RunShutdownPolicy=RunShutdownPolicy(
        acknowledgement_timeout_ns=1_000_000_000,
        drain_timeout_ns=2_000_000_000))
    fixture_start_ns = time_ns()
    core = _prepare_gate4a_plant(config)
    wfs_acquisition = prepared_acquisition(
        core.plant, :hil_wfs)
    session = RunSessionID(config.run_seed)
    endpoint = prepared_command_endpoint(core.plant, :hil_dm)
    command_ports = prepare_command_ports(
        endpoint,
        [
            zeros(Float64, 2)
            for _ in 1:config.command_capacity
        ];
        session,
        payload_pool_id=UInt64(0x7c10),
        outcome_credit_pool_id=UInt64(0x7c11),
        submission_capacity=config.command_capacity,
        completion_capacity=config.command_capacity)
    bridge = prepare_command_bridge(
        command_ports, endpoint, core.event_loop)
    delivery = AdapterDeliveryContract(
        PlantDuration(config.complete_product_lead_time_ns),
        PlantDuration(config.maximum_lease_hold_time_ns))
    required_acquisition_policy = AcquisitionOverloadPolicy(
        RequiredResource(),
        RetainProducerOnFull();
        maximum_lateness_ns=nothing,
        recovery_occupancy=0)
    wfs_port = prepare_acquisition_completion_port(
        AcquisitionID(:hil_wfs),
        _product_buffers(
            core.plant,
            :hil_wfs,
            config.primary_product_capacity);
        session,
        product_pool_id=UInt64(0x7c20),
        ring_capacity=config.primary_product_capacity,
        delivery_contract=delivery,
        overload_policy=required_acquisition_policy)
    feedback_port = prepare_acquisition_completion_port(
        AcquisitionID(:hil_dm_feedback),
        _product_buffers(
            core.plant,
            :hil_dm_feedback,
            config.feedback_product_capacity);
        session,
        product_pool_id=UInt64(0x7c21),
        ring_capacity=config.feedback_product_capacity,
        delivery_contract=delivery,
        overload_policy=required_acquisition_policy)
    optional_science_policy = AcquisitionOverloadPolicy(
        OptionalResource(),
        DropNewestOnFull();
        maximum_lateness_ns=nothing,
        recovery_occupancy=0)
    science_port = config.science_enabled ?
        prepare_acquisition_completion_port(
            AcquisitionID(:hil_science),
            _product_buffers(
                core.plant,
                :hil_science,
                config.science_product_capacity);
            session,
            product_pool_id=UInt64(0x7c22),
            ring_capacity=config.science_product_capacity,
            delivery_contract=delivery,
            overload_policy=optional_science_policy) :
        nothing
    acquisition_ports = config.science_enabled ?
        (wfs_port, feedback_port, science_port) :
        (wfs_port, feedback_port)
    configuration = configure_serial_run(
        bridge,
        acquisition_ports;
        optical_execution,
        arm_timeout_ns,
        shutdown_policy)
    configured_ns = time_ns()
    run = prepare_serial_run(configuration)
    precompile(
        begin_serial_arm!,
        (typeof(run), typeof(clock)))
    precompile(
        arm_serial_run!,
        (
            ArmingSerialRun{typeof(run),typeof(clock)},
            AdapterReadinessSnapshot,
        ))
    prepared_ns = time_ns()
    attempt = begin_serial_arm!(run, clock)
    readiness = AdapterReadinessSnapshot(
        session,
        execution_clock_identity(clock),
        AdapterReady,
        Clocks.time_nanos(clock))
    armed = arm_serial_run!(attempt, readiness)
    armed_ns = time_ns()
    running = start_serial_run!(armed)
    started_ns = time_ns()
    lifecycle_timings = (
        configuration_ns=Int(configured_ns - fixture_start_ns),
        preparation_ns=Int(prepared_ns - configured_ns),
        arm_ns=Int(armed_ns - prepared_ns),
        start_ns=Int(started_ns - armed_ns),
        total_ns=Int(started_ns - fixture_start_ns),
    )
    return merge(
        core,
        (;
            config,
            command_ports,
            bridge,
            wfs_port,
            feedback_port,
            science_port,
            wfs_acquisition,
            configuration,
            run,
            clock,
            attempt,
            readiness,
            armed,
            running,
            lifecycle_timings))
end

primary_product_sequence(fixture) = acquisition_product_sequence(
    fixture.event_loop,
    plant_event_loop_state(fixture.run.state.bridge),
    _HIL_WFS_ACQUISITION)

feedback_product_sequence(fixture) = acquisition_product_sequence(
    fixture.event_loop,
    plant_event_loop_state(fixture.run.state.bridge),
    _HIL_DM_FEEDBACK_ACQUISITION)

science_product_sequence(fixture) = fixture.science_port === nothing ?
    UInt64(0) :
    acquisition_product_sequence(
        fixture.event_loop,
        plant_event_loop_state(fixture.run.state.bridge),
        _HIL_SCIENCE_ACQUISITION)

function latest_optical_sample_timestamp(fixture)
    return Plant.reduced_order_sample_timestamp(
        fixture.wfs_acquisition)
end

end
