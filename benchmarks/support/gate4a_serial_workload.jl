module Gate4ASerialWorkload

using AdaptiveOpticsHIL.Lifecycle
using AdaptiveOpticsHIL.Ownership
using AdaptiveOpticsHIL.Ports
using AdaptiveOpticsHIL.Serial
using AdaptiveOpticsHIL.Timing: execution_clock_identity
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

struct Gate4AWorkloadConfig
    primary_period_ns::Int64
    primary_exposure_ns::Int64
    optical_sample_period_ns::Int64
    feedback_period_ns::Int64
    feedback_phase_ns::Int64
    feedback_exposure_ns::Int64
    command_capacity::Int
    primary_product_capacity::Int
    feedback_product_capacity::Int
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
    command_capacity::Integer=8,
    primary_product_capacity::Integer=64,
    feedback_product_capacity::Integer=64,
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
    command_capacity > 0 || error(
        "command capacity must be positive")
    primary_product_capacity > 0 || error(
        "primary product capacity must be positive")
    feedback_product_capacity > 0 || error(
        "feedback product capacity must be positive")
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
        Int(command_capacity),
        Int(primary_product_capacity),
        Int(feedback_product_capacity),
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
    ::Type{Gate4AReducedOrderPathModel}) = ColdPlantModelDefinition()
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

function Plant.prepare_path_executor(
    ::Gate4AReducedOrderPathModel,
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
        Gate4AReducedOrderPathExecution(imaging);
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
    ::AdaptiveOpticsSim.AbstractAtmosphere)
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
        :hil_wfs_path, source, Gate4AReducedOrderPathModel())
    residual_acquisition = AcquisitionDefinition(
        :hil_wfs, :hil_wfs_path, residual_model)
    feedback_acquisition = AcquisitionDefinition(
        :hil_dm_feedback, :hil_wfs_path, feedback_model)
    optic = ControllableOpticDefinition(
        :hil_dm,
        Gate4AReducedOrderOpticModel(),
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
        run_seed=config.run_seed,
        command_endpoints=(
            CommandEndpointConfiguration(
                :hil_dm,
                zeros(T, 2);
                capacity=config.command_capacity),
        ))
    event_loop = prepare_plant_event_loop(
        plant,
        PlantEventLoopDefinition(
            (
                OpticalSampleDefinition(
                    :hil_wfs_path,
                    PeriodicSchedule(
                        period_ns=config.optical_sample_period_ns,
                        phase_ns=0)),
            ),
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
            )))
    return (; plant, event_loop, schema)
end

function _product_buffers(plant, id, count)
    source = acquisition_products(prepared_acquisition(plant, id))
    return [deepcopy(source) for _ in 1:count]
end

function prepare_gate4a_fixture(
    clock::Clocks.AbstractNanoClock,
    config::Gate4AWorkloadConfig=Gate4AWorkloadConfig())
    core = _prepare_gate4a_plant(config)
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
    wfs_port = prepare_acquisition_completion_port(
        AcquisitionID(:hil_wfs),
        _product_buffers(
            core.plant,
            :hil_wfs,
            config.primary_product_capacity);
        session,
        product_pool_id=UInt64(0x7c20),
        ring_capacity=config.primary_product_capacity,
        delivery_contract=delivery)
    feedback_port = prepare_acquisition_completion_port(
        AcquisitionID(:hil_dm_feedback),
        _product_buffers(
            core.plant,
            :hil_dm_feedback,
            config.feedback_product_capacity);
        session,
        product_pool_id=UInt64(0x7c21),
        ring_capacity=config.feedback_product_capacity,
        delivery_contract=delivery)
    configuration = configure_serial_run(
        bridge,
        (wfs_port, feedback_port);
        arm_timeout_ns=1_000_000_000)
    run = prepare_serial_run(configuration)
    attempt = begin_serial_arm!(run, clock)
    readiness = AdapterReadinessSnapshot(
        session,
        execution_clock_identity(clock),
        AdapterReady,
        Clocks.time_nanos(clock))
    armed = arm_serial_run!(attempt, readiness)
    running = start_serial_run!(armed)
    return merge(
        core,
        (;
            config,
            command_ports,
            bridge,
            wfs_port,
            feedback_port,
            configuration,
            run,
            clock,
            attempt,
            readiness,
            armed,
            running))
end

primary_product_sequence(fixture) = acquisition_product_sequence(
    fixture.event_loop,
    plant_event_loop_state(fixture.run.state.bridge),
    :hil_wfs)

feedback_product_sequence(fixture) = acquisition_product_sequence(
    fixture.event_loop,
    plant_event_loop_state(fixture.run.state.bridge),
    :hil_dm_feedback)

function latest_optical_sample_timestamp(fixture)
    return Plant.reduced_order_sample_timestamp(
        prepared_acquisition(fixture.plant, :hil_wfs))
end

end
