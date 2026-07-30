import AdaptiveOpticsHIL
using AdaptiveOpticsHIL.Lifecycle
using AdaptiveOpticsHIL.Ownership
using AdaptiveOpticsHIL.Ports
using AdaptiveOpticsHIL.Ports: pending_command_receive_timestamp
using AdaptiveOpticsHIL.Timing
import AdaptiveOpticsSim

const PORT_TEST_PLANT = AdaptiveOpticsSim.Plant
const PORT_TESTS_WITH_COVERAGE =
    Base.JLOptions().code_coverage != 0
const PORT_TEST_EXECUTION_CLOCK =
    ExecutionClockID(:port_test_clock)

port_test_readiness(session, execution_ns) =
    AdapterReadinessSnapshot(
        session,
        PORT_TEST_EXECUTION_CLOCK,
        AdapterReady,
        execution_ns)

function port_test_mapped_timestamp(
    domain::ExternalTimestampDomainID,
    source_timestamp_ticks::Integer,
    version::TimestampMappingVersion,
    plant_timestamp::PORT_TEST_PLANT.PlantTimestamp;
    uncertainty::PORT_TEST_PLANT.PlantDuration=
        zero(PORT_TEST_PLANT.PlantDuration))
    mapping = ExternalTimestampMapping(
        domain,
        version,
        source_timestamp_ticks,
        plant_timestamp;
        uncertainty,
        valid_from_ticks=source_timestamp_ticks,
        valid_through_ticks=source_timestamp_ticks)
    return map_external_timestamp(mapping, source_timestamp_ticks)
end

function port_value_bytes(reference::Ref{T}) where {T}
    bytes = Vector{UInt8}(undef, sizeof(T))
    GC.@preserve reference unsafe_copyto!(
        pointer(bytes),
        Ptr{UInt8}(Base.unsafe_convert(Ptr{T}, reference)),
        sizeof(T))
    return bytes
end

function port_test_schema(::Type{T}=Float64;
    id=:hil_command,
    version=1,
    endpoint=:hil_dm,
    dimensions=(3,),
    basis=PORT_TEST_PLANT.CommandBasis(:actuator, :hil_actuators),
    basis_revision=1,
    value_policy=PORT_TEST_PLANT.CommandValuePolicy(),
    sequence_policy=PORT_TEST_PLANT.CommandSequencePolicy(),
    effective_time_policy=
        PORT_TEST_PLANT.CommandEffectiveTimePolicy(),
) where {T}
    return PORT_TEST_PLANT.PlantCommandSchema(
        T,
        dimensions;
        id,
        version,
        endpoint,
        units=:metre,
        sign_convention=:positive_surface_increases_opd,
        basis,
        basis_revision,
        semantics=PORT_TEST_PLANT.AbsoluteCommand,
        bounds=PORT_TEST_PLANT.UniformCommandBounds(T(-1), T(1)),
        value_policy,
        sequence_policy,
        effective_time_policy,
        silence_policy=PORT_TEST_PLANT.CommandSilencePolicy())
end

function port_test_endpoint(schema; capacity=8, ordinal=1)
    return PORT_TEST_PLANT.prepare_command_endpoint(
        schema;
        capacity,
        sequence_window=capacity,
        ordinal)
end

function replace_submission(
    submission::CommandSubmission{P};
    session=submission.session,
    descriptor_schema_id=submission.descriptor_schema_id,
    descriptor_schema_version=submission.descriptor_schema_version,
    stream_sequence=submission.stream_sequence,
    endpoint=submission.endpoint,
    core_schema_id=submission.core_schema_id,
    core_schema_version=submission.core_schema_version,
    basis=submission.basis,
    basis_revision=submission.basis_revision,
    timing=submission.timing,
    command_sequence=submission.command_sequence,
    payload=submission.payload) where {P}
    return CommandSubmission(
        session,
        descriptor_schema_id,
        descriptor_schema_version,
        stream_sequence,
        endpoint,
        core_schema_id,
        core_schema_version,
        basis,
        basis_revision,
        timing,
        command_sequence,
        payload)
end

function claim_command_submission(
    port::CommandSubmissionPort{LeasedCommandPayload},
    values,
    stream_sequence,
    command_sequence,
    timestamp)
    lease_ref = Ref(PayloadLeaseRef(0, 0, 0, 0))
    @assert try_claim_command_payload!(lease_ref, port) ==
        PayloadTransitionSucceeded
    lease = lease_ref[]
    copyto!(producer_command_payload(port, lease), values)
    timing = receive_time_command_timing(timestamp)
    submission = matching_command_submission(
        port,
        StreamSequence(stream_sequence),
        PORT_TEST_PLANT.PlantCommandSequence(command_sequence),
        timing,
        LeasedCommandPayload(lease))
    return submission
end

function take_command_outcome(port::CommandCompletionPort{P}) where {P}
    output = Ref{CommandOutcome{P}}()
    @assert try_take!(output, port).status == PortTransferSucceeded
    return output[]
end

command_processing_status(result::CommandProcessingResult) =
    port_status(command_processing_port_result(result))

function finish_ready_command!(
    bridge,
    state,
    bridge_workspace,
    timestamp,
    publication_execution_ns)
    endpoint_state = command_endpoint_state(state)
    workspace = command_disposition_workspace(bridge_workspace)
    claim = PORT_TEST_PLANT.claim_next_application_ready_command!(
        bridge.endpoint, endpoint_state, timestamp)
    @assert !isnothing(claim)
    PORT_TEST_PLANT.mark_plant_command_applied!(
        workspace, bridge.endpoint, endpoint_state, claim)
    return publish_command_dispositions!(
        bridge, state, bridge_workspace, publication_execution_ns)
end

function inline_command_cycle!(
    ports,
    bridge,
    state,
    bridge_workspace,
    outcome_ref,
    stream::Int,
    timestamp_ns::Int)
    timestamp = PORT_TEST_PLANT.PlantTimestamp(timestamp_ns)
    submission = matching_command_submission(
        command_submission_port(ports),
        StreamSequence(stream),
        PORT_TEST_PLANT.PlantCommandSequence(stream),
        receive_time_command_timing(timestamp),
        InlineCommandPayload(0.25))
    submit_result = try_submit!(
        command_submission_port(ports),
        submission,
        Int64(timestamp_ns + 1))
    process_result = process_next_command!(
        bridge, state, bridge_workspace, Int64(timestamp_ns + 2))
    endpoint_state = command_endpoint_state(state)
    workspace = command_disposition_workspace(bridge_workspace)
    claim = PORT_TEST_PLANT.claim_next_application_ready_command!(
        bridge.endpoint, endpoint_state, timestamp)
    PORT_TEST_PLANT.mark_plant_command_applied!(
        workspace, bridge.endpoint, endpoint_state, claim)
    disposition_count = publish_command_dispositions!(
        bridge, state, bridge_workspace, Int64(timestamp_ns + 3))
    take_result = try_take!(
        outcome_ref, command_completion_port(ports))
    payload_value =
        outcome_payload(command_completion_port(ports), outcome_ref[])
    release_result = release_outcome!(
        command_completion_port(ports), outcome_ref[])
    return (
        submit_result.status,
        command_processing_status(process_result),
        disposition_count,
        take_result.status,
        payload_value,
        release_result.status)
end

function leased_command_cycle!(
    ports,
    bridge,
    state,
    bridge_workspace,
    lease_ref,
    outcome_ref,
    stream::Int,
    timestamp_ns::Int)
    submission_port = command_submission_port(ports)
    completion_port = command_completion_port(ports)
    claim_status =
        try_claim_command_payload!(lease_ref, submission_port)
    fill!(producer_command_payload(submission_port, lease_ref[]), 0.25)
    timestamp = PORT_TEST_PLANT.PlantTimestamp(timestamp_ns)
    submission = matching_command_submission(
        submission_port,
        StreamSequence(stream),
        PORT_TEST_PLANT.PlantCommandSequence(stream),
        receive_time_command_timing(timestamp),
        LeasedCommandPayload(lease_ref[]))
    submit_result =
        try_submit!(submission_port, submission, Int64(timestamp_ns))
    process_result =
        process_next_command!(
            bridge, state, bridge_workspace, Int64(timestamp_ns + 1))
    endpoint_state = command_endpoint_state(state)
    workspace = command_disposition_workspace(bridge_workspace)
    claim = PORT_TEST_PLANT.claim_next_application_ready_command!(
        bridge.endpoint, endpoint_state, timestamp)
    PORT_TEST_PLANT.mark_plant_command_applied!(
        workspace, bridge.endpoint, endpoint_state, claim)
    disposition_count = publish_command_dispositions!(
        bridge, state, bridge_workspace, Int64(timestamp_ns + 2))
    take_result = try_take!(outcome_ref, completion_port)
    release_result = release_outcome!(completion_port, outcome_ref[])
    return (
        claim_status,
        submit_result.status,
        command_processing_status(process_result),
        disposition_count,
        take_result.status,
        release_result.status)
end

function acquisition_port_cycle!(
    port,
    lease_ref,
    completion_ref,
    stream::Int,
    timestamp_ns::Int)
    claim_status = try_claim_product!(lease_ref, port)
    fill!(producer_product(port, lease_ref[]).observation, Float32(stream))
    timestamp = PORT_TEST_PLANT.PlantTimestamp(timestamp_ns)
    completion = matching_acquisition_completion(
        port,
        StreamSequence(stream),
        timestamp,
        lease_ref[],
        Int64(timestamp_ns))
    publish_result = try_publish!(port, completion)
    take_result = try_take!(completion_ref, port)
    product = completed_product(port, completion_ref[])
    value = product.observation[1]
    release_result = release_product!(port, completion_ref[])
    return (
        claim_status,
        publish_result.status,
        take_result.status,
        value,
        release_result.status)
end

@testset "Port contracts and command bridge" begin
    @testset "Canonical identities and timing" begin
        @test Base.isexported(
            AdaptiveOpticsHIL.Timing, :ExternalTimestampDomainID)
        @test Base.isexported(
            AdaptiveOpticsHIL.Timing, :TimestampMappingVersion)
        @test !Base.isexported(
            AdaptiveOpticsHIL.Ports, :ExternalTimestampDomainID)
        @test !Base.isexported(
            AdaptiveOpticsHIL.Ports, :TimestampMappingVersion)
        @test Base.isexported(
            AdaptiveOpticsHIL.Lifecycle, :RunSessionID)
        @test !Base.isexported(
            AdaptiveOpticsHIL.Ports, :RunSessionID)
        @test_throws PortError PortResourcePolicy(
            true, 1, RetainProducerOnFull())
        @test_throws PortError PortResourcePolicy(
            1, true, RetainProducerOnFull())
        @test_throws PortError PortResourcePolicy(
            0, 0, RetainProducerOnFull())
        @test_throws PortError PortResourcePolicy(
            1, 2, RetainProducerOnFull())
        @test_throws RunLifecycleError RunSessionID(0)
        @test_throws PortError StreamSequence(false)
        @test_throws PortError PortSchemaID(Symbol(""))
        @test_throws PortError PortSchemaVersion(0)
        @test_throws PortError PortSchemaVersion(false)
        session = RunSessionID(7)
        sequence = StreamSequence(8)
        schema_id = PortSchemaID(:command_submission)
        schema_version = PortSchemaVersion(9)
        timestamp_domain = ExternalTimestampDomainID(:rtc_ptp)
        @test isequal(session, RunSessionID(7))
        @test hash(session) == hash(RunSessionID(7))
        @test isequal(sequence, StreamSequence(8))
        @test hash(sequence) == hash(StreamSequence(8))
        @test isequal(schema_id, PortSchemaID(:command_submission))
        @test hash(schema_id) == hash(PortSchemaID(:command_submission))
        @test isequal(schema_version, PortSchemaVersion(9))
        @test isequal(
            timestamp_domain, ExternalTimestampDomainID(:rtc_ptp))
        @test hash(timestamp_domain) ==
            hash(ExternalTimestampDomainID(:rtc_ptp))
        @test sprint(show, session) == "RunSessionID(7)"
        @test sprint(show, sequence) == "StreamSequence(8)"
        @test sprint(show, schema_version) == "PortSchemaVersion(9)"
        @test sprint(show, schema_id) ==
            "PortSchemaID(:command_submission)"

        rejected = PortResult(PortRejected, SessionMismatch)
        @test port_status(rejected) == PortRejected
        @test port_rejection_reason(rejected) == SessionMismatch
        @test port_payload_status(rejected) === nothing

        receive = PORT_TEST_PLANT.PlantTimestamp(100)
        receive_only = receive_time_command_timing(receive)
        @test source_timestamp_kind(receive_only) == ReceiveTimestampOnly
        @test source_timestamp_domain(receive_only) === nothing
        @test source_timestamp_ticks(receive_only) === nothing
        @test timestamp_mapping_version(receive_only) === nothing
        @test mapped_source_timestamp(receive_only) == receive
        @test command_receive_timestamp(receive_only) == receive
        @test command_effective_timestamp(receive_only) == receive
        @test timestamp_mapping_uncertainty(receive_only) ==
            zero(PORT_TEST_PLANT.PlantDuration)

        mapped_result = port_test_mapped_timestamp(
            timestamp_domain,
            Int64(9_000),
            TimestampMappingVersion(3),
            PORT_TEST_PLANT.PlantTimestamp(95);
            uncertainty=PORT_TEST_PLANT.PlantDuration(5))
        mapped = mapped_source_command_timing(
            mapped_result,
            receive;
            requested_effective_timestamp=
                PORT_TEST_PLANT.PlantTimestamp(95))
        @test Base.allocatedinline(CommandTimingMetadata)
        if PORT_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test @allocated(mapped_source_command_timing(
                mapped_result,
                receive;
                requested_effective_timestamp=
                    PORT_TEST_PLANT.PlantTimestamp(95))) == 0
        end
        @test source_timestamp_kind(mapped) == MappedSourceTimestamp
        @test source_timestamp_domain(mapped) == timestamp_domain
        @test source_timestamp_ticks(mapped) == 9_000
        @test timestamp_mapping_version(mapped) ==
            TimestampMappingVersion(3)
        @test mapped_source_timestamp(mapped) ==
            PORT_TEST_PLANT.PlantTimestamp(95)
        @test command_receive_timestamp(mapped) == receive
        @test command_effective_timestamp(mapped) ==
            PORT_TEST_PLANT.PlantTimestamp(95)
        @test timestamp_mapping_uncertainty(mapped) ==
            PORT_TEST_PLANT.PlantDuration(5)
        exact_uncertainty_lead = mapped_source_command_timing(
            port_test_mapped_timestamp(
                timestamp_domain,
                Int64(9_002),
                TimestampMappingVersion(3),
                PORT_TEST_PLANT.PlantTimestamp(105);
                uncertainty=PORT_TEST_PLANT.PlantDuration(5)),
            receive)
        @test mapped_source_timestamp(exact_uncertainty_lead) ==
            PORT_TEST_PLANT.PlantTimestamp(105)
        mapped_from_narrow_integer = mapped_source_command_timing(
            port_test_mapped_timestamp(
                timestamp_domain,
                Int32(9_001),
                TimestampMappingVersion(3),
                PORT_TEST_PLANT.PlantTimestamp(95);
                uncertainty=PORT_TEST_PLANT.PlantDuration(5)),
            receive;
            requested_effective_timestamp=
                PORT_TEST_PLANT.PlantTimestamp(95))
        @test source_timestamp_ticks(
            mapped_from_narrow_integer) == 9_001
        @test_throws PortError mapped_source_command_timing(
            port_test_mapped_timestamp(
                ExternalTimestampDomainID(:rtc_ptp),
                Int64(9_000),
                TimestampMappingVersion(3),
                PORT_TEST_PLANT.PlantTimestamp(106);
                uncertainty=PORT_TEST_PLANT.PlantDuration(5)),
            receive;
            requested_effective_timestamp=
                PORT_TEST_PLANT.PlantTimestamp(106))
        @test !applicable(
            mapped_source_command_timing,
            timestamp_domain,
            Int64(9_000),
            TimestampMappingVersion(3),
            PORT_TEST_PLANT.PlantTimestamp(95),
            receive)

        delivery = AdapterDeliveryContract(
            PORT_TEST_PLANT.PlantDuration(25),
            PORT_TEST_PLANT.PlantDuration(1_000))
        readiness =
            port_test_readiness(RunSessionID(1), Int64(90))
        @test adapter_readiness_status(readiness) == AdapterReady
        @test run_session(readiness) == RunSessionID(1)
        @test run_execution_clock_identity(readiness) ==
            PORT_TEST_EXECUTION_CLOCK
        @test adapter_readiness_execution_ns(readiness) == 90
        @test complete_product_lead_time(delivery) ==
            PORT_TEST_PLANT.PlantDuration(25)
        @test maximum_lease_hold_time(delivery) ==
            PORT_TEST_PLANT.PlantDuration(1_000)
        @test_throws PortError AdapterDeliveryContract(
            PORT_TEST_PLANT.PlantDuration(0),
            PORT_TEST_PLANT.PlantDuration(0))
    end

    @testset "Leased command lifecycle and exact core outcome" begin
        schema = port_test_schema()
        endpoint = port_test_endpoint(schema)
        session = RunSessionID(41)
        ports = prepare_command_ports(
            endpoint,
            [zeros(3) for _ in 1:8];
            session,
            payload_pool_id=UInt64(100),
            outcome_credit_pool_id=UInt64(101),
            submission_capacity=4,
            completion_capacity=8)
        submission_port = command_submission_port(ports)
        completion_port = command_completion_port(ports)
        submission_accounting =
            @inferred descriptor_accounting(submission_port)
        @test submission_accounting.capacity == 4
        @test descriptor_accounting(completion_port).capacity == 8
        @test submission_accounting.occupancy == 0
        @test port_lifecycle_state(submission_port) == PortAccepting
        submission_policy = port_resource_policy(submission_port)
        @test resource_capacity(submission_policy) == 4
        @test maximum_outstanding(submission_policy) == 4
        @test resource_full_policy(submission_policy) isa
              RetainProducerOnFull
        @test resource_criticality(submission_port) isa
            RequiredResource
        @test resource_is_required(submission_port)
        completion_policy = port_resource_policy(completion_port)
        @test resource_capacity(completion_policy) == 8
        @test maximum_outstanding(completion_policy) == 8
        @test resource_full_policy(completion_policy) isa
              ReservedFullIsInvariant
        @test resource_criticality(completion_port) isa
            RequiredResource
        @test resource_is_required(completion_port)
        payload_policy = payload_resource_policy(submission_port)
        @test resource_capacity(payload_policy.payload) == 8
        @test resource_capacity(payload_policy.outcome_credit) == 8
        payload_lifecycle = payload_lifecycle_state(submission_port)
        @test payload_lifecycle.payload == PayloadPoolAccepting
        @test payload_lifecycle.outcome_credit == PayloadPoolAccepting
        returns_policy = lease_return_policy(completion_port)
        @test resource_capacity(returns_policy.payload) == 8
        @test maximum_outstanding(returns_policy.payload) == 8
        @test resource_full_policy(returns_policy.payload) isa
              ReservedFullIsInvariant
        @test resource_capacity(returns_policy.outcome_credit) == 8
        if !PORT_TESTS_WITH_COVERAGE
            @test @allocated(
                descriptor_accounting(submission_port)) == 0
        end
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)

        timestamp = PORT_TEST_PLANT.PlantTimestamp(10)
        submission = claim_command_submission(
            submission_port, [0.1, 0.2, 0.3], 1, 1, timestamp)
        @test submission_session(submission) == session
        @test submission_stream_sequence(submission) == StreamSequence(1)
        @test submission_endpoint(submission) ==
            PORT_TEST_PLANT.CommandEndpointID(:hil_dm)
        @test submission_schema_id(submission) ==
            PORT_TEST_PLANT.command_schema_id(schema)
        @test submission_schema_version(submission) ==
            PORT_TEST_PLANT.command_schema_version(schema)
        @test submission_command_sequence(submission) ==
            PORT_TEST_PLANT.PlantCommandSequence(1)
        @test submission_timing(submission) ==
            receive_time_command_timing(timestamp)
        @test submission_payload(submission) == submission.payload
        @test try_submit!(
            submission_port, submission, Int64(1_000)).status ==
            PortTransferSucceeded
        @test outcome_credit_accounting(submission_port).queued == 1
        processing = process_next_command!(
            bridge, state, bridge_workspace, Int64(1_100))
        @test command_processing_status(processing) ==
            PortTransferSucceeded
        @test command_processing_stage(processing) ==
            CommandSemanticallyAdmitted
        @test command_processing_endpoint(processing) ==
            PORT_TEST_PLANT.CommandEndpointID(:hil_dm)
        @test command_processing_presentation(processing) !== nothing
        descriptor = bridge_workspace.descriptor_scratch[]
        @test submission_session(descriptor) == submission_session(submission)
        @test submission_stream_sequence(descriptor) ==
            submission_stream_sequence(submission)
        @test submission_endpoint(descriptor) ==
            submission_endpoint(submission)
        @test submission_schema_id(descriptor) ==
            submission_schema_id(submission)
        @test submission_schema_version(descriptor) ==
            submission_schema_version(submission)
        @test submission_command_sequence(descriptor) ==
            submission_command_sequence(submission)
        @test submission_timing(descriptor) == submission_timing(submission)
        @test submission_payload(descriptor) == submission_payload(submission)
        @test active_command_correlations(state) == 1
        @test command_payload_accounting(submission_port).consumer_leased == 1

        @test finish_ready_command!(
            bridge, state, bridge_workspace, timestamp,
            Int64(1_200)) == 1
        @test active_command_correlations(state) == 0
        outcome = take_command_outcome(completion_port)
        @test outcome_stage(outcome) == CoreCommandOutcome
        @test outcome_boundary_reason(outcome) == NoPortRejection
        @test outcome_reason(outcome) == :applied
        @test outcome_session(outcome) == session
        @test outcome_stream_sequence(outcome) == StreamSequence(1)
        @test outcome_terminal_kind(outcome) ==
            PORT_TEST_PLANT.AppliedCommand
        @test outcome_presentation_id(outcome) !== nothing
        @test outcome_superseding_presentation_id(outcome) === nothing
        @test outcome_endpoint(outcome) ==
            PORT_TEST_PLANT.CommandEndpointID(:hil_dm)
        @test outcome_model_endpoint(outcome) == outcome_endpoint(outcome)
        @test outcome_timing(outcome) == submission.timing
        @test outcome_requested_effective_timestamp(outcome) == timestamp
        @test outcome_terminal_timestamp(outcome) == timestamp
        @test outcome_lateness(outcome) ==
            zero(PORT_TEST_PLANT.PlantDuration)
        @test outcome_ingress_execution_ns(outcome) == 1_000
        @test outcome_publication_execution_ns(outcome) == 1_200
        @test outcome_payload(completion_port, outcome) ≈
            [0.1, 0.2, 0.3]
        other_schema = port_test_schema(
            id=:other_hil_command,
            endpoint=:other_hil_dm)
        other_endpoint = port_test_endpoint(other_schema; ordinal=2)
        other_ports = prepare_command_ports(
            other_endpoint,
            [zeros(3)];
            session,
            payload_pool_id=UInt64(102),
            outcome_credit_pool_id=UInt64(103))
        @test release_outcome!(
            command_completion_port(other_ports), outcome).reason ==
            CommandEndpointMismatch
        @test_throws PortError outcome_payload(
            command_completion_port(other_ports), outcome)
        @test release_outcome!(completion_port, outcome).status ==
            PortTransferSucceeded
        empty_outcome = Ref{CommandOutcome{LeasedCommandPayload}}()
        @test try_take!(empty_outcome, completion_port).status == PortEmpty
        @test command_payload_accounting(completion_port).return_queued == 1
        @test outcome_credit_accounting(completion_port).return_queued == 1
        command_deficit = payload_ownership_deficit(completion_port)
        @test command_deficit.payload.deficit == 1
        @test command_deficit.outcome_credit.deficit == 1
        @test reclaim_command_payload_returns!(submission_port) ==
              RingBatchResult(RingTransferSucceeded, 1)
        @test reclaim_outcome_credit_returns!(submission_port) ==
              RingBatchResult(RingTransferSucceeded, 1)
        @test command_payload_accounting(completion_port).free == 8
        @test outcome_credit_accounting(completion_port).free == 8
        @test release_outcome!(completion_port, outcome).status ==
              PortRejected
        @test close_command_ingress!(ports).status ==
              PortTransferSucceeded
        @test close_command_completion!(ports).status ==
              PortTransferSucceeded
        leased_close = close_command_return_paths!(ports)
        @test leased_close.payload_status == RingTransferSucceeded
        @test leased_close.credit_status == RingTransferSucceeded
    end

    @testset "Boundary and core mismatch outcomes" begin
        schema = port_test_schema()
        endpoint = port_test_endpoint(schema; capacity=12)
        session = RunSessionID(51)
        ports = prepare_command_ports(
            endpoint,
            [zeros(3) for _ in 1:12];
            session,
            payload_pool_id=UInt64(110),
            outcome_credit_pool_id=UInt64(111),
            submission_capacity=12,
            completion_capacity=12)
        submission_port = command_submission_port(ports)
        completion_port = command_completion_port(ports)
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)

        wrong_session = claim_command_submission(
            submission_port,
            [0.0, 0.0, 0.0],
            1,
            1,
            PORT_TEST_PLANT.PlantTimestamp(1))
        wrong_session = replace_submission(
            wrong_session; session=RunSessionID(999))
        @test try_submit!(
            submission_port, wrong_session, Int64(1)).reason ==
            SessionMismatch
        @test producer_command_payload(
            submission_port, wrong_session.payload.lease) ==
            [0.0, 0.0, 0.0]
        @test abort_command_payload!(
            submission_port, wrong_session.payload.lease) ==
            PayloadTransitionSucceeded

        cases = (
            (DescriptorSchemaMismatch,
             s -> replace_submission(
                 s; descriptor_schema_version=PortSchemaVersion(2))),
            (CommandBasisMismatch,
             s -> replace_submission(
                 s; basis=PORT_TEST_PLANT.CommandBasis(
                     :modal, :other_basis))),
            (CommandBasisRevisionMismatch,
             s -> replace_submission(
                 s; basis_revision=
                     PORT_TEST_PLANT.CommandBasisRevision(2))),
            (CommandTimestampMismatch,
             s -> replace_submission(
                 s; timing=mapped_source_command_timing(
                     port_test_mapped_timestamp(
                         ExternalTimestampDomainID(:rtc),
                         Int64(20),
                         TimestampMappingVersion(1),
                         PORT_TEST_PLANT.PlantTimestamp(
                             PORT_TEST_PLANT.plant_nanoseconds(
                                 s.timing.receive_timestamp) - 1)),
                     s.timing.receive_timestamp))),
        )
        stream = 2
        command_sequence = 2
        timestamp_ns = 2
        for (expected_reason, modify) in cases
            submission = claim_command_submission(
                submission_port,
                [0.1, 0.1, 0.1],
                stream,
                command_sequence,
                PORT_TEST_PLANT.PlantTimestamp(timestamp_ns))
            submission = modify(submission)
            @test try_submit!(
                submission_port, submission, Int64(timestamp_ns)).status ==
                PortTransferSucceeded
            processing = process_next_command!(
                bridge, state, bridge_workspace,
                Int64(timestamp_ns))
            @test command_processing_status(processing) ==
                PortTransferSucceeded
            @test command_processing_stage(processing) ==
                CommandBoundaryRejected
            outcome = take_command_outcome(completion_port)
            @test outcome_stage(outcome) == BoundaryCommandOutcome
            @test outcome.boundary_reason == expected_reason
            @test outcome_presentation_id(outcome) === nothing
            @test outcome_superseding_presentation_id(outcome) === nothing
            @test release_outcome!(completion_port, outcome).status ==
                PortTransferSucceeded
            stream += 1
            command_sequence += 1
            timestamp_ns += 1
        end

        # A stale stream sequence is a boundary error. Gaps remain legal so a
        # deliberately dropped command remains observable without poisoning
        # all later submissions.
        stale = claim_command_submission(
            submission_port,
            [0.1, 0.1, 0.1],
            stream - 1,
            command_sequence,
            PORT_TEST_PLANT.PlantTimestamp(timestamp_ns))
        @test try_submit!(
            submission_port, stale, Int64(timestamp_ns)).status ==
            PortTransferSucceeded
        process_next_command!(
            bridge, state, bridge_workspace, Int64(timestamp_ns))
        stale_outcome = take_command_outcome(completion_port)
        @test stale_outcome.boundary_reason ==
            CommandStreamSequenceNotIncreasing
        release_outcome!(completion_port, stale_outcome)
        stream += 1
        command_sequence += 1
        timestamp_ns += 1

        wrong_endpoint = claim_command_submission(
            submission_port,
            [0.1, 0.1, 0.1],
            stream,
            command_sequence,
            PORT_TEST_PLANT.PlantTimestamp(timestamp_ns))
        wrong_endpoint = replace_submission(
            wrong_endpoint;
            endpoint=PORT_TEST_PLANT.CommandEndpointID(:wrong_endpoint))
        @test try_submit!(
            submission_port, wrong_endpoint, Int64(timestamp_ns)).status ==
            PortTransferSucceeded
        process_next_command!(
            bridge, state, bridge_workspace, Int64(timestamp_ns))
        endpoint_outcome = take_command_outcome(completion_port)
        @test outcome_stage(endpoint_outcome) == CoreCommandOutcome
        @test outcome_reason(endpoint_outcome) == :endpoint_mismatch
        @test outcome_endpoint(endpoint_outcome) ==
            PORT_TEST_PLANT.CommandEndpointID(:wrong_endpoint)
        @test outcome_model_endpoint(endpoint_outcome) ==
            PORT_TEST_PLANT.CommandEndpointID(:hil_dm)
        release_outcome!(completion_port, endpoint_outcome)
        stream += 1
        command_sequence += 1
        timestamp_ns += 1

        wrong_schema = claim_command_submission(
            submission_port,
            [0.1, 0.1, 0.1],
            stream,
            command_sequence,
            PORT_TEST_PLANT.PlantTimestamp(timestamp_ns))
        wrong_schema = replace_submission(
            wrong_schema;
            core_schema_id=
                PORT_TEST_PLANT.PlantCommandSchemaID(:wrong_schema))
        try_submit!(submission_port, wrong_schema, Int64(timestamp_ns))
        process_next_command!(
            bridge, state, bridge_workspace, Int64(timestamp_ns))
        schema_outcome = take_command_outcome(completion_port)
        @test outcome_reason(schema_outcome) == :schema_mismatch
        release_outcome!(completion_port, schema_outcome)
        stream += 1
        command_sequence += 1
        timestamp_ns += 1

        wrong_schema_version = claim_command_submission(
            submission_port,
            [0.1, 0.1, 0.1],
            stream,
            command_sequence,
            PORT_TEST_PLANT.PlantTimestamp(timestamp_ns))
        wrong_schema_version = replace_submission(
            wrong_schema_version;
            core_schema_version=
                PORT_TEST_PLANT.PlantCommandSchemaVersion(2))
        try_submit!(
            submission_port, wrong_schema_version, Int64(timestamp_ns))
        process_next_command!(
            bridge, state, bridge_workspace, Int64(timestamp_ns))
        version_outcome = take_command_outcome(completion_port)
        @test outcome_reason(version_outcome) ==
            :schema_version_mismatch
        release_outcome!(completion_port, version_outcome)
        stream += 1
        command_sequence += 1
        timestamp_ns += 1

        accepted_sequence = command_sequence
        accepted_timestamp =
            PORT_TEST_PLANT.PlantTimestamp(timestamp_ns)
        accepted = claim_command_submission(
            submission_port,
            [0.1, 0.1, 0.1],
            stream,
            accepted_sequence,
            accepted_timestamp)
        try_submit!(submission_port, accepted, Int64(timestamp_ns))
        process_next_command!(
            bridge, state, bridge_workspace, Int64(timestamp_ns))
        finish_ready_command!(
            bridge, state, bridge_workspace, accepted_timestamp,
            Int64(timestamp_ns))
        accepted_outcome = take_command_outcome(completion_port)
        @test outcome_reason(accepted_outcome) == :applied
        release_outcome!(completion_port, accepted_outcome)
        stream += 1
        timestamp_ns += 1

        duplicate = claim_command_submission(
            submission_port,
            [0.2, 0.2, 0.2],
            stream,
            accepted_sequence,
            PORT_TEST_PLANT.PlantTimestamp(timestamp_ns))
        try_submit!(submission_port, duplicate, Int64(timestamp_ns))
        duplicate_processing = process_next_command!(
            bridge, state, bridge_workspace, Int64(timestamp_ns))
        @test command_processing_stage(duplicate_processing) ==
            CommandTerminatedDuringAdmission
        @test command_processing_presentation(
            duplicate_processing) !== nothing
        duplicate_outcome = take_command_outcome(completion_port)
        @test outcome_stage(duplicate_outcome) == CoreCommandOutcome
        @test outcome_reason(duplicate_outcome) == :duplicate_sequence
        release_outcome!(completion_port, duplicate_outcome)
    end

    @testset "Core supersession preserves HIL correlation" begin
        schema = port_test_schema(
            sequence_policy=PORT_TEST_PLANT.CommandSequencePolicy(
                reordered=PORT_TEST_PLANT.AcceptSequence),
            effective_time_policy=
                PORT_TEST_PLANT.CommandEffectiveTimePolicy(
                    supersession=
                        PORT_TEST_PLANT.SupersedeOlderPendingCommands))
        endpoint = port_test_endpoint(schema; capacity=3)
        ports = prepare_command_ports(
            endpoint,
            [zeros(3) for _ in 1:3];
            session=RunSessionID(57),
            payload_pool_id=UInt64(116),
            outcome_credit_pool_id=UInt64(117),
            submission_capacity=3,
            completion_capacity=3)
        submission_port = command_submission_port(ports)
        completion_port = command_completion_port(ports)
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)

        for (stream, sequence, receive_ns, effective_ns) in (
            (1, 3, 1, 100),
            (2, 2, 2, 80),
            (3, 4, 3, 90),
        )
            lease_ref = Ref(PayloadLeaseRef(0, 0, 0, 0))
            @test try_claim_command_payload!(lease_ref, submission_port) ==
                PayloadTransitionSucceeded
            fill!(
                producer_command_payload(submission_port, lease_ref[]),
                sequence / 10)
            receive = PORT_TEST_PLANT.PlantTimestamp(receive_ns)
            timing = receive_time_command_timing(
                receive;
                requested_effective_timestamp=
                    PORT_TEST_PLANT.PlantTimestamp(effective_ns))
            submission = matching_command_submission(
                submission_port,
                StreamSequence(stream),
                PORT_TEST_PLANT.PlantCommandSequence(sequence),
                timing,
                LeasedCommandPayload(lease_ref[]))
            @test try_submit!(
                submission_port, submission, Int64(receive_ns)).status ==
                PortTransferSucceeded
            processing = process_next_command!(
                bridge, state, bridge_workspace,
                Int64(receive_ns))
            @test command_processing_status(processing) ==
                PortTransferSucceeded
        end

        @test active_command_correlations(state) == 1
        superseded = (
            take_command_outcome(completion_port),
            take_command_outcome(completion_port),
        )
        @test Set(map(outcome_command_sequence, superseded)) == Set((
            PORT_TEST_PLANT.PlantCommandSequence(2),
            PORT_TEST_PLANT.PlantCommandSequence(3),
        ))
        superseding_presentations =
            map(outcome_superseding_presentation_id, superseded)
        @test all(!isnothing, superseding_presentations)
        @test superseding_presentations[1] ==
            superseding_presentations[2]
        for outcome in superseded
            @test outcome_terminal_kind(outcome) ==
                PORT_TEST_PLANT.SupersededCommand
            @test outcome_presentation_id(outcome) !== nothing
            @test release_outcome!(completion_port, outcome).status ==
                PortTransferSucceeded
        end

        @test finish_ready_command!(
            bridge,
            state,
            bridge_workspace,
            PORT_TEST_PLANT.PlantTimestamp(90),
            Int64(90)) == 1
        applied = take_command_outcome(completion_port)
        @test outcome_command_sequence(applied) ==
            PORT_TEST_PLANT.PlantCommandSequence(4)
        @test outcome_superseding_presentation_id(applied) === nothing
        @test release_outcome!(completion_port, applied).status ==
            PortTransferSucceeded
    end

    @testset "Future-effective calendar capacity is terminal" begin
        schema = port_test_schema()
        endpoint = port_test_endpoint(schema; capacity=1)
        ports = prepare_command_ports(
            endpoint,
            [zeros(3), zeros(3)];
            session=RunSessionID(58),
            payload_pool_id=UInt64(118),
            outcome_credit_pool_id=UInt64(119),
            submission_capacity=2,
            completion_capacity=2)
        submission_port = command_submission_port(ports)
        completion_port = command_completion_port(ports)
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)

        first = claim_command_submission(
            submission_port,
            [0.1, 0.1, 0.1],
            1,
            1,
            PORT_TEST_PLANT.PlantTimestamp(1))
        first = replace_submission(
            first;
            timing=receive_time_command_timing(
                PORT_TEST_PLANT.PlantTimestamp(1);
                requested_effective_timestamp=
                    PORT_TEST_PLANT.PlantTimestamp(100)))
        @test try_submit!(
            submission_port, first, Int64(1)).status ==
            PortTransferSucceeded
        first_processing = process_next_command!(
            bridge, state, bridge_workspace, Int64(1))
        @test command_processing_stage(first_processing) ==
            CommandSemanticallyAdmitted

        second = claim_command_submission(
            submission_port,
            [0.2, 0.2, 0.2],
            2,
            2,
            PORT_TEST_PLANT.PlantTimestamp(2))
        second = replace_submission(
            second;
            timing=receive_time_command_timing(
                PORT_TEST_PLANT.PlantTimestamp(2);
                requested_effective_timestamp=
                    PORT_TEST_PLANT.PlantTimestamp(200)))
        @test try_submit!(
            submission_port, second, Int64(2)).status ==
            PortTransferSucceeded
        second_processing = process_next_command!(
            bridge, state, bridge_workspace, Int64(2))
        @test command_processing_stage(second_processing) ==
            CommandTerminatedDuringAdmission
        @test active_command_correlations(state) == 1
        @test PORT_TEST_PLANT.pending_command_count(
            command_endpoint_state(state)) == 1

        rejected = take_command_outcome(completion_port)
        @test outcome_stage(rejected) == CoreCommandOutcome
        @test outcome_reason(rejected) == :calendar_capacity
        @test outcome_terminal_kind(rejected) ==
            PORT_TEST_PLANT.RejectedCommand
        @test outcome_stream_sequence(rejected) == StreamSequence(2)
        @test outcome_command_sequence(rejected) ==
            PORT_TEST_PLANT.PlantCommandSequence(2)
        @test outcome_payload(completion_port, rejected) ≈
            [0.2, 0.2, 0.2]
        @test release_outcome!(completion_port, rejected).status ==
            PortTransferSucceeded
        @test reclaim_command_payload_returns!(submission_port) ==
            RingBatchResult(RingTransferSucceeded, 1)
        @test reclaim_outcome_credit_returns!(submission_port) ==
            RingBatchResult(RingTransferSucceeded, 1)

        @test finish_ready_command!(
            bridge,
            state,
            bridge_workspace,
            PORT_TEST_PLANT.PlantTimestamp(100),
            Int64(100)) == 1
        applied = take_command_outcome(completion_port)
        @test outcome_reason(applied) == :applied
        @test outcome_stream_sequence(applied) == StreamSequence(1)
        @test release_outcome!(completion_port, applied).status ==
            PortTransferSucceeded
        @test reclaim_command_payload_returns!(submission_port) ==
            RingBatchResult(RingTransferSucceeded, 1)
        @test reclaim_outcome_credit_returns!(submission_port) ==
            RingBatchResult(RingTransferSucceeded, 1)
        @test command_payload_accounting(submission_port).free == 2
        @test outcome_credit_accounting(submission_port).free == 2
        @test active_command_correlations(state) == 0
        @test PORT_TEST_PLANT.pending_command_count(
            command_endpoint_state(state)) == 0
    end

    @testset "Preparation, lease, and full backpressure" begin
        schema = port_test_schema()
        endpoint = port_test_endpoint(schema)
        session = RunSessionID(61)
        @test_throws PortError prepare_command_ports(
            endpoint,
            [zeros(2), zeros(2)];
            session,
            payload_pool_id=UInt64(120),
            outcome_credit_pool_id=UInt64(121))
        @test_throws PortError prepare_command_ports(
            endpoint,
            [zeros(Float32, 3), zeros(Float32, 3)];
            session,
            payload_pool_id=UInt64(120),
            outcome_credit_pool_id=UInt64(121))
        abstract_buffers =
            AbstractVector{Float64}[zeros(3), zeros(3)]
        @test_throws PortError prepare_command_ports(
            endpoint,
            abstract_buffers;
            session,
            payload_pool_id=UInt64(120),
            outcome_credit_pool_id=UInt64(121))
        @test_throws PortError prepare_command_ports(
            endpoint,
            [1.0, 2.0];
            session,
            payload_pool_id=UInt64(120),
            outcome_credit_pool_id=UInt64(121))
        shared_command_buffer = zeros(3)
        @test_throws PortError prepare_command_ports(
            endpoint,
            [shared_command_buffer, shared_command_buffer];
            session,
            payload_pool_id=UInt64(120),
            outcome_credit_pool_id=UInt64(121))
        @test_throws PortError prepare_command_ports(
            endpoint,
            [zeros(3), zeros(3)];
            session,
            payload_pool_id=UInt64(120),
            outcome_credit_pool_id=UInt64(120))
        @test_throws PortError prepare_command_ports(
            endpoint,
            [zeros(3)];
            session,
            payload_pool_id=UInt64(120),
            outcome_credit_pool_id=UInt64(121),
            submission_capacity=true)
        @test_throws OwnershipError prepare_command_ports(
            endpoint,
            [zeros(3), zeros(3)];
            session,
            payload_pool_id=UInt64(120),
            outcome_credit_pool_id=UInt64(121),
            payload_return_capacity=1)
        @test_throws OwnershipError prepare_command_ports(
            endpoint,
            [zeros(3), zeros(3)];
            session,
            payload_pool_id=UInt64(120),
            outcome_credit_pool_id=UInt64(121),
            completion_capacity=2,
            outcome_return_capacity=1)

        ports = prepare_command_ports(
            endpoint,
            [zeros(3), zeros(3)];
            session,
            payload_pool_id=UInt64(122),
            outcome_credit_pool_id=UInt64(123),
            submission_capacity=1,
            completion_capacity=2)
        submission_port = command_submission_port(ports)
        first = claim_command_submission(
            submission_port,
            [0.1, 0.1, 0.1],
            1,
            1,
            PORT_TEST_PLANT.PlantTimestamp(1))
        second = claim_command_submission(
            submission_port,
            [0.2, 0.2, 0.2],
            2,
            2,
            PORT_TEST_PLANT.PlantTimestamp(2))
        @test try_submit!(submission_port, first, Int64(1)).status ==
            PortTransferSucceeded
        @test try_submit!(submission_port, second, Int64(2)).status ==
            PortFull
        @test producer_command_payload(
            submission_port, second.payload.lease) == [0.2, 0.2, 0.2]

        other_ports = prepare_command_ports(
            endpoint,
            [zeros(3)];
            session,
            payload_pool_id=UInt64(124),
            outcome_credit_pool_id=UInt64(125))
        other_port = command_submission_port(other_ports)
        foreign_ref = Ref(PayloadLeaseRef(0, 0, 0, 0))
        @test try_claim_command_payload!(foreign_ref, other_port) ==
            PayloadTransitionSucceeded
        foreign = replace_submission(
            second; payload=LeasedCommandPayload(foreign_ref[]))
        foreign_result =
            try_submit!(submission_port, foreign, Int64(2))
        @test foreign_result.status == PortRejected
        @test foreign_result.reason == PayloadLeaseMismatch
        @test abort_command_payload!(other_port, foreign_ref[]) ==
            PayloadTransitionSucceeded
        @test abort_command_payload!(
            submission_port, second.payload.lease) ==
            PayloadTransitionSucceeded

        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)
        queued_before = descriptor_accounting(submission_port)
        pending_timestamp = pending_command_receive_timestamp(
            bridge, bridge_workspace)
        @test pending_timestamp ==
            PORT_TEST_PLANT.PlantTimestamp(1)
        @test descriptor_accounting(submission_port) == queued_before
        process_next_command!(
            bridge, state, bridge_workspace, Int64(3))
        @test pending_command_receive_timestamp(
            bridge, bridge_workspace) === nothing
        @test PORT_TEST_PLANT.pending_command_count(
            command_endpoint_state(state)) == 1
        @test active_command_correlations(state) == 1
        finish_ready_command!(
            bridge, state, bridge_workspace,
            PORT_TEST_PLANT.PlantTimestamp(1), Int64(4))
        outcome = take_command_outcome(command_completion_port(ports))
        release_outcome!(command_completion_port(ports), outcome)
    end

    @testset "Outcome-credit and correlation invariants" begin
        schema = port_test_schema()
        endpoint = port_test_endpoint(schema; capacity=2)
        ports = prepare_command_ports(
            endpoint,
            [zeros(3), zeros(3)];
            session=RunSessionID(65),
            payload_pool_id=UInt64(126),
            outcome_credit_pool_id=UInt64(127),
            submission_capacity=2,
            completion_capacity=1)
        submission_port = command_submission_port(ports)
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)
        first = claim_command_submission(
            submission_port,
            [0.1, 0.1, 0.1],
            1,
            1,
            PORT_TEST_PLANT.PlantTimestamp(1))
        second = claim_command_submission(
            submission_port,
            [0.2, 0.2, 0.2],
            2,
            2,
            PORT_TEST_PLANT.PlantTimestamp(2))
        @test try_submit!(submission_port, first, Int64(1)).status ==
            PortTransferSucceeded
        process_next_command!(
            bridge, state, bridge_workspace, Int64(1))
        no_credit = try_submit!(submission_port, second, Int64(2))
        @test no_credit.status == PortFull
        @test no_credit.reason == OutcomeCreditUnavailable
        @test port_payload_status(no_credit) == PayloadPoolExhausted
        @test abort_command_payload!(
            submission_port, second.payload.lease) ==
            PayloadTransitionSucceeded
        finish_ready_command!(
            bridge, state, bridge_workspace,
            PORT_TEST_PLANT.PlantTimestamp(1), Int64(2))
        outcome = take_command_outcome(command_completion_port(ports))
        release_outcome!(command_completion_port(ports), outcome)

        # A core disposition not produced from a transferred descriptor must
        # fail before any partial completion publication.
        foreign_command = PORT_TEST_PLANT.PlantCommand(
            PORT_TEST_PLANT.CommandEndpointID(:foreign),
            PORT_TEST_PLANT.command_schema_id(schema),
            PORT_TEST_PLANT.command_schema_version(schema),
            PORT_TEST_PLANT.PlantCommandSequence(3),
            PORT_TEST_PLANT.PlantTimestamp(3),
            zeros(3))
        PORT_TEST_PLANT.admit_plant_command!(
            command_disposition_workspace(bridge_workspace),
            endpoint,
            command_endpoint_state(state),
            foreign_command,
            PORT_TEST_PLANT.PlantTimestamp(3))
        @test_throws PortError publish_command_dispositions!(
            bridge, state, bridge_workspace, Int64(3))
        PORT_TEST_PLANT.clear_command_dispositions!(
            command_disposition_workspace(bridge_workspace))

        exhausted_ports = prepare_command_ports(
            port_test_endpoint(
                port_test_schema(Float64; dimensions=());
                capacity=1,
                ordinal=3),
            Float64;
            session=RunSessionID(651),
            submission_capacity=1,
            completion_capacity=1,
            outcome_credit_pool_id=UInt64(1_260))
        exhausted_submission_port =
            command_submission_port(exhausted_ports)
        exhausted_submission_port.outcome_credit_pool.generations[1] =
            typemax(UInt64)
        exhausted_submission = matching_command_submission(
            exhausted_submission_port,
            StreamSequence(1),
            PORT_TEST_PLANT.PlantCommandSequence(1),
            receive_time_command_timing(
                PORT_TEST_PLANT.PlantTimestamp(1)),
            InlineCommandPayload(0.1))
        @test_throws PortError try_submit!(
            exhausted_submission_port, exhausted_submission, Int64(1))
    end

    @testset "Pending core dispositions flush before new ingress" begin
        schema = port_test_schema(Float64; dimensions=())
        endpoint = port_test_endpoint(schema; capacity=2)
        ports = prepare_command_ports(
            endpoint,
            Float64;
            session=RunSessionID(652),
            submission_capacity=2,
            completion_capacity=2,
            outcome_credit_pool_id=UInt64(1_261))
        submission_port = command_submission_port(ports)
        completion_port = command_completion_port(ports)
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)

        first_time = PORT_TEST_PLANT.PlantTimestamp(1)
        first = matching_command_submission(
            submission_port,
            StreamSequence(1),
            PORT_TEST_PLANT.PlantCommandSequence(1),
            receive_time_command_timing(first_time),
            InlineCommandPayload(0.1))
        try_submit!(submission_port, first, Int64(1))
        process_next_command!(
            bridge, state, bridge_workspace, Int64(1))
        claim = PORT_TEST_PLANT.claim_next_application_ready_command!(
            endpoint, command_endpoint_state(state), first_time)
        PORT_TEST_PLANT.mark_plant_command_applied!(
            command_disposition_workspace(bridge_workspace),
            endpoint,
            command_endpoint_state(state),
            claim)

        second_time = PORT_TEST_PLANT.PlantTimestamp(2)
        second = matching_command_submission(
            submission_port,
            StreamSequence(2),
            PORT_TEST_PLANT.PlantCommandSequence(2),
            receive_time_command_timing(second_time),
            InlineCommandPayload(0.2))
        try_submit!(submission_port, second, Int64(2))
        processing = process_next_command!(
            bridge, state, bridge_workspace,
            Int64(2))
        @test command_processing_status(processing) ==
            PortTransferSucceeded
        first_outcome = take_command_outcome(completion_port)
        @test outcome_command_sequence(first_outcome) ==
            PORT_TEST_PLANT.PlantCommandSequence(1)
        release_outcome!(completion_port, first_outcome)

        finish_ready_command!(
            bridge, state, bridge_workspace, second_time, Int64(3))
        second_outcome = take_command_outcome(completion_port)
        @test outcome_command_sequence(second_outcome) ==
            PORT_TEST_PLANT.PlantCommandSequence(2)
        release_outcome!(completion_port, second_outcome)
    end

    @testset "Structural core failure still returns its outcome" begin
        schema = port_test_schema(
            value_policy=PORT_TEST_PLANT.CommandValuePolicy(
                out_of_range=PORT_TEST_PLANT.FailOnInvalidCommand))
        endpoint = port_test_endpoint(schema; capacity=2)
        ports = prepare_command_ports(
            endpoint,
            [zeros(3), zeros(3)];
            session=RunSessionID(66),
            payload_pool_id=UInt64(128),
            outcome_credit_pool_id=UInt64(129),
            submission_capacity=2,
            completion_capacity=2)
        submission_port = command_submission_port(ports)
        completion_port = command_completion_port(ports)
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)
        submission = claim_command_submission(
            submission_port,
            [2.0, 0.0, 0.0],
            1,
            1,
            PORT_TEST_PLANT.PlantTimestamp(1))
        try_submit!(submission_port, submission, Int64(1))
        @test_throws PORT_TEST_PLANT.PlantCommandError begin
            process_next_command!(
                bridge, state, bridge_workspace, Int64(2))
        end
        outcome = take_command_outcome(completion_port)
        @test outcome_stage(outcome) == CoreCommandOutcome
        @test outcome_reason(outcome) == :out_of_range_failure
        @test outcome_terminal_kind(outcome) ==
            PORT_TEST_PLANT.FailedCommand
        @test release_outcome!(completion_port, outcome).status ==
            PortTransferSucceeded

        # A core lifecycle rejection before presentation still returns the HIL
        # lease/credit while preserving the original core exception.
        regressed = claim_command_submission(
            submission_port,
            [0.0, 0.0, 0.0],
            2,
            2,
            PORT_TEST_PLANT.PlantTimestamp(0))
        try_submit!(submission_port, regressed, Int64(3))
        @test_throws PORT_TEST_PLANT.PlantCommandError begin
            process_next_command!(
                bridge, state, bridge_workspace, Int64(4))
        end
        regressed_outcome = take_command_outcome(completion_port)
        @test outcome_stage(regressed_outcome) ==
            BoundaryCommandOutcome
        @test outcome_boundary_reason(regressed_outcome) ==
            CoreAdmissionUnavailable
        @test outcome_reason(regressed_outcome) ==
            :core_admission_unavailable
        @test release_outcome!(
            completion_port, regressed_outcome).status ==
            PortTransferSucceeded
    end

    @testset "Mapped external timestamp contract" begin
        schema = port_test_schema(Float64; dimensions=())
        endpoint = port_test_endpoint(schema; capacity=3)
        domain = ExternalTimestampDomainID(:rtc_ptp)
        ports = prepare_command_ports(
            endpoint,
            Float64;
            session=RunSessionID(67),
            submission_capacity=3,
            completion_capacity=3,
            outcome_credit_pool_id=UInt64(133),
            timing_contract=MappedSourceTimingContract(
                domain;
                minimum_mapping_version=TimestampMappingVersion(2)))
        submission_port = command_submission_port(ports)
        completion_port = command_completion_port(ports)
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)
        receive = PORT_TEST_PLANT.PlantTimestamp(10)
        mapping_owner = TimestampMappingOwnerID(:rtc_synchronization)
        mappings = prepare_timestamp_mappings(2; owner=mapping_owner)
        mapping_v2 = ExternalTimestampMapping(
            domain,
            TimestampMappingVersion(2),
            Int64(5_000),
            PORT_TEST_PLANT.PlantTimestamp(9);
            uncertainty=PORT_TEST_PLANT.PlantDuration(1),
            valid_from_ticks=Int64(5_000),
            valid_through_ticks=Int64(5_000))
        install_timestamp_mapping!(mappings, mapping_owner, mapping_v2)
        accounting_before_mapping_failure =
            descriptor_accounting(submission_port)
        @test_throws TimestampMappingError map_external_timestamp(
            mappings,
            domain,
            TimestampMappingVersion(1),
            Int64(5_000))
        accounting_after_mapping_failure =
            descriptor_accounting(submission_port)
        @test accounting_after_mapping_failure.capacity ==
            accounting_before_mapping_failure.capacity
        @test accounting_after_mapping_failure.occupancy ==
            accounting_before_mapping_failure.occupancy
        @test accounting_after_mapping_failure.producer_sequence ==
            accounting_before_mapping_failure.producer_sequence
        @test accounting_after_mapping_failure.consumer_sequence ==
            accounting_before_mapping_failure.consumer_sequence
        timing = mapped_source_command_timing(
            map_external_timestamp(
                mappings,
                domain,
                TimestampMappingVersion(2),
                Int64(5_000)),
            receive;
            requested_effective_timestamp=receive)
        timing_reference = Ref(timing)
        timing_bytes = port_value_bytes(timing_reference)
        submission = matching_command_submission(
            submission_port,
            StreamSequence(1),
            PORT_TEST_PLANT.PlantCommandSequence(1),
            timing,
            InlineCommandPayload(0.1))
        mapping_v3 = ExternalTimestampMapping(
            domain,
            TimestampMappingVersion(3),
            Int64(5_000),
            PORT_TEST_PLANT.PlantTimestamp(8);
            uncertainty=PORT_TEST_PLANT.PlantDuration(1),
            valid_from_ticks=Int64(5_000),
            valid_through_ticks=Int64(5_000))
        install_timestamp_mapping!(mappings, mapping_owner, mapping_v3)
        @test port_value_bytes(timing_reference) == timing_bytes
        @test mapped_source_timestamp(timing) ==
            PORT_TEST_PLANT.PlantTimestamp(9)
        @test timestamp_mapping_version(timing) ==
            TimestampMappingVersion(2)
        @test timestamp_mapping_version(submission_timing(submission)) ==
            TimestampMappingVersion(2)
        @test mapped_source_timestamp(submission_timing(submission)) ==
            PORT_TEST_PLANT.PlantTimestamp(9)
        try_submit!(submission_port, submission, Int64(10))
        process_next_command!(
            bridge, state, bridge_workspace, Int64(11))
        finish_ready_command!(
            bridge, state, bridge_workspace, receive, Int64(12))
        outcome = take_command_outcome(completion_port)
        @test outcome_stage(outcome) == CoreCommandOutcome
        @test source_timestamp_domain(outcome_timing(outcome)) == domain
        @test timestamp_mapping_version(outcome_timing(outcome)) ==
            TimestampMappingVersion(2)
        @test mapped_source_timestamp(outcome_timing(outcome)) ==
            PORT_TEST_PLANT.PlantTimestamp(9)
        release_outcome!(completion_port, outcome)

        stale_timing = mapped_source_command_timing(
            port_test_mapped_timestamp(
                domain,
                Int64(5_001),
                TimestampMappingVersion(1),
                PORT_TEST_PLANT.PlantTimestamp(10)),
            PORT_TEST_PLANT.PlantTimestamp(11);
            requested_effective_timestamp=
                PORT_TEST_PLANT.PlantTimestamp(11))
        stale = matching_command_submission(
            submission_port,
            StreamSequence(2),
            PORT_TEST_PLANT.PlantCommandSequence(2),
            stale_timing,
            InlineCommandPayload(0.1))
        try_submit!(submission_port, stale, Int64(13))
        process_next_command!(
            bridge, state, bridge_workspace, Int64(14))
        stale_outcome = take_command_outcome(completion_port)
        @test outcome_stage(stale_outcome) == BoundaryCommandOutcome
        @test outcome_boundary_reason(stale_outcome) ==
            CommandTimestampMismatch
        release_outcome!(completion_port, stale_outcome)
    end

    @testset "Inline inference and warmed allocation" begin
        schema = port_test_schema(Float64; dimensions=())
        endpoint = port_test_endpoint(schema; capacity=4)
        ports = prepare_command_ports(
            endpoint,
            Float64;
            session=RunSessionID(71),
            submission_capacity=4,
            completion_capacity=4,
            outcome_credit_pool_id=UInt64(130))
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)
        outcome_ref = Ref{CommandOutcome{InlineCommandPayload{Float64}}}()
        expected = (
            PortTransferSucceeded,
            PortTransferSucceeded,
            1,
            PortTransferSucceeded,
            0.25,
            PortTransferSucceeded)
        @test inline_command_cycle!(
            ports, bridge, state, bridge_workspace,
            outcome_ref, 1, 1) == expected
        @test @inferred(inline_command_cycle!(
            ports, bridge, state, bridge_workspace,
            outcome_ref, 2, 2)) == expected
        if PORT_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test @allocated(inline_command_cycle!(
                ports, bridge, state, bridge_workspace,
                outcome_ref, 3, 3)) == 0
        end
    end

    @testset "Leased inference and warmed allocation" begin
        schema = port_test_schema()
        endpoint = port_test_endpoint(schema; capacity=4)
        ports = prepare_command_ports(
            endpoint,
            [zeros(3) for _ in 1:4];
            session=RunSessionID(72),
            payload_pool_id=UInt64(131),
            outcome_credit_pool_id=UInt64(132),
            submission_capacity=4,
            completion_capacity=4)
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        bridge_workspace = CommandBridgeWorkspace(bridge)
        lease_ref = Ref(PayloadLeaseRef(0, 0, 0, 0))
        outcome_ref = Ref{CommandOutcome{LeasedCommandPayload}}()
        expected = (
            PayloadTransitionSucceeded,
            PortTransferSucceeded,
            PortTransferSucceeded,
            1,
            PortTransferSucceeded,
            PortTransferSucceeded)
        @test leased_command_cycle!(
            ports, bridge, state, bridge_workspace,
            lease_ref, outcome_ref, 1, 1) ==
            expected
        @test @inferred(leased_command_cycle!(
            ports, bridge, state, bridge_workspace,
            lease_ref, outcome_ref, 2, 2)) ==
            expected
        if PORT_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test @allocated(leased_command_cycle!(
                ports, bridge, state, bridge_workspace,
                lease_ref, outcome_ref, 3, 3)) == 0
        end
    end

    @testset "Command close and bounded drain ordering" begin
        schema = port_test_schema(Float64; dimensions=())
        endpoint = port_test_endpoint(schema; capacity=2)
        ports = prepare_command_ports(
            endpoint,
            Float64;
            session=RunSessionID(73),
            submission_capacity=2,
            completion_capacity=2,
            outcome_credit_pool_id=UInt64(134))
        submission_port = command_submission_port(ports)
        completion_port = command_completion_port(ports)
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)
        workspace = CommandBridgeWorkspace(bridge)
        inline_policy = port_resource_policy(submission_port)
        @test maximum_outstanding(inline_policy) == 2
        inline_payload_policy = payload_resource_policy(submission_port)
        @test inline_payload_policy.payload === nothing
        inline_return_policy = lease_return_policy(completion_port)
        @test inline_return_policy.payload === nothing
        @test lease_return_lifecycle_state(
            completion_port).payload === nothing
        @test payload_ownership_deficit(
            completion_port).payload === nothing
        @test Base.invokelatest(
            reclaim_command_payload_returns!,
            submission_port,
            1) === nothing
        @test_throws PortError close_command_completion!(ports)

        for sequence in 1:2
            timestamp = PORT_TEST_PLANT.PlantTimestamp(sequence)
            submission = matching_command_submission(
                submission_port,
                StreamSequence(sequence),
                PORT_TEST_PLANT.PlantCommandSequence(sequence),
                receive_time_command_timing(timestamp),
                InlineCommandPayload(0.1 * sequence))
            submission = replace_submission(
                submission;
                descriptor_schema_version=PortSchemaVersion(2))
            @test try_submit!(
                submission_port,
                submission,
                Int64(sequence)).status == PortTransferSucceeded
        end
        @test close_command_ingress!(ports).status ==
              PortTransferSucceeded
        @test port_lifecycle_state(submission_port) == PortDraining
        closed_payloads = payload_lifecycle_state(submission_port)
        @test closed_payloads.payload === nothing
        @test closed_payloads.outcome_credit ==
              PayloadPoolDraining
        @test_throws PortError close_command_completion!(ports)
        @test_throws PortError close_command_return_paths!(ports)

        rejected_after_close = matching_command_submission(
            submission_port,
            StreamSequence(3),
            PORT_TEST_PLANT.PlantCommandSequence(3),
            receive_time_command_timing(
                PORT_TEST_PLANT.PlantTimestamp(3)),
            InlineCommandPayload(0.3))
        @test try_submit!(
            submission_port,
            rejected_after_close,
            Int64(3)).status == PortClosed

        first_processing = process_next_command!(
            bridge, state, workspace, Int64(10))
        @test command_processing_status(first_processing) ==
              PortTransferSucceeded
        second_processing = process_next_command!(
            bridge, state, workspace, Int64(11))
        @test command_processing_status(second_processing) ==
              PortTransferSucceeded
        closed_processing = process_next_command!(
            bridge, state, workspace, Int64(12))
        @test command_processing_status(closed_processing) == PortClosed
        @test command_processing_stage(closed_processing) ==
            CommandNotProcessed
        @test port_lifecycle_state(submission_port) == PortDrained

        @test close_command_completion!(ports).status ==
              PortTransferSucceeded
        @test port_lifecycle_state(completion_port) == PortDraining
        @test_throws PortError close_command_return_paths!(ports)
        output = Ref{CommandOutcome{InlineCommandPayload{Float64}}}()
        observed = StreamSequence[]
        for _ in 1:2
            @test try_take!(output, completion_port).status ==
                  PortTransferSucceeded
            push!(observed, outcome_stream_sequence(output[]))
            @test outcome_stage(output[]) == BoundaryCommandOutcome
            @test release_outcome!(completion_port, output[]).status ==
                  PortTransferSucceeded
        end
        @test observed == StreamSequence[StreamSequence(1), StreamSequence(2)]
        @test try_take!(output, completion_port).status == PortClosed
        @test port_lifecycle_state(completion_port) == PortDrained
        @test lease_return_lifecycle_state(
            completion_port).outcome_credit == PortAccepting

        close_results = close_command_return_paths!(ports)
        @test close_results.payload_status === nothing
        @test close_results.credit_status == RingTransferSucceeded
        @test lease_return_lifecycle_state(
            completion_port).outcome_credit == PortDraining
        @test reclaim_outcome_credit_returns!(submission_port) ==
              RingBatchResult(RingTransferSucceeded, 2)
        @test payload_lifecycle_state(
            completion_port).outcome_credit == PayloadPoolDrained
        @test lease_return_lifecycle_state(
            completion_port).outcome_credit == PortDrained
        @test outcome_credit_accounting(completion_port).free == 2
        @test close_command_ingress!(ports).status == PortClosed
        @test close_command_completion!(ports).status == PortClosed

        leased_ports = prepare_command_ports(
            port_test_endpoint(port_test_schema(); capacity=1),
            [zeros(3)];
            session=RunSessionID(74),
            payload_pool_id=UInt64(135),
            outcome_credit_pool_id=UInt64(136))
        leased_submission_port = command_submission_port(leased_ports)
        closed_submission = claim_command_submission(
            leased_submission_port,
            [0.1, 0.2, 0.3],
            1,
            1,
            PORT_TEST_PLANT.PlantTimestamp(1))
        @test close_command_ingress!(leased_ports).status ==
              PortTransferSucceeded
        @test payload_lifecycle_state(
            leased_submission_port).payload == PayloadPoolDraining
        @test try_submit!(
            leased_submission_port,
            closed_submission,
            Int64(1)).status == PortClosed
        @test producer_command_payload(
            leased_submission_port,
            closed_submission.payload.lease) == [0.1, 0.2, 0.3]
        @test abort_command_payload!(
            leased_submission_port,
            closed_submission.payload.lease) ==
              PayloadTransitionSucceeded
        @test payload_lifecycle_state(
            leased_submission_port).payload == PayloadPoolDrained

        fault_endpoint = port_test_endpoint(
            port_test_schema(Float64; dimensions=());
            capacity=1)
        fault_ports = prepare_command_ports(
            fault_endpoint,
            Float64;
            session=RunSessionID(75),
            submission_capacity=1,
            completion_capacity=1,
            outcome_credit_pool_id=UInt64(137))
        fault_submission_port = command_submission_port(fault_ports)
        fault_completion_port = command_completion_port(fault_ports)
        fault_submission = matching_command_submission(
            fault_submission_port,
            StreamSequence(1),
            PORT_TEST_PLANT.PlantCommandSequence(1),
            receive_time_command_timing(
                PORT_TEST_PLANT.PlantTimestamp(1)),
            InlineCommandPayload(0.1))
        fault_submission = replace_submission(
            fault_submission;
            descriptor_schema_version=PortSchemaVersion(2))
        @test try_submit!(
            fault_submission_port,
            fault_submission,
            Int64(1)).status == PortTransferSucceeded
        @test close_ring!(fault_completion_port.ring) ==
              RingTransferSucceeded
        fault_bridge = prepare_command_bridge(
            fault_ports, fault_endpoint)
        publication_error = try
            process_next_command!(
                fault_bridge,
                CommandBridgeState(fault_bridge),
                CommandBridgeWorkspace(fault_bridge),
                Int64(2))
            nothing
        catch error
            error
        end
        @test publication_error isa PortError
        @test publication_error.reason == :publication_after_close
        capacity_error = try
            Base.invokelatest(
                AdaptiveOpticsHIL.Ports.
                    _command_outcome_publication_error,
                RingFull)
            nothing
        catch error
            error
        end
        @test capacity_error isa PortError
        @test capacity_error.reason == :credit_capacity_invariant
    end
end

@testset "Complete acquisition ports" begin
    @test !Base.isexported(
        AdaptiveOpticsHIL.Ports, :acquisition_completion_readiness)
    @test !hasfield(AcquisitionCompletion, :readiness)
    products = [
        PORT_TEST_PLANT.AcquisitionProducts(
            zeros(Float32, 2, 2); metadata=(kind=:pixels,)),
        PORT_TEST_PLANT.AcquisitionProducts(
            zeros(Float32, 2, 2); metadata=(kind=:pixels,)),
    ]
    session = RunSessionID(81)
    delivery = AdapterDeliveryContract(
        PORT_TEST_PLANT.PlantDuration(50),
        PORT_TEST_PLANT.PlantDuration(10_000))
    required_overload = AcquisitionOverloadPolicy(
        RequiredResource(),
        RetainProducerOnFull();
        maximum_lateness_ns=nothing,
        recovery_occupancy=0)
    @test_throws PortError AcquisitionOverloadPolicy(
        RequiredResource(),
        RetainProducerOnFull();
        maximum_lateness_ns=false,
        recovery_occupancy=0)
    @test_throws PortError AcquisitionOverloadPolicy(
        RequiredResource(),
        RetainProducerOnFull();
        maximum_lateness_ns=-1,
        recovery_occupancy=0)
    @test_throws PortError AcquisitionOverloadPolicy(
        RequiredResource(),
        RetainProducerOnFull();
        maximum_lateness_ns=nothing,
        recovery_occupancy=false)
    @test_throws PortError AcquisitionOverloadPolicy(
        RequiredResource(),
        RetainProducerOnFull();
        maximum_lateness_ns=nothing,
        recovery_occupancy=-1)
    port = prepare_acquisition_completion_port(
        PORT_TEST_PLANT.AcquisitionID(:wfs_pixels),
        products;
        session,
        product_pool_id=UInt64(140),
        ring_capacity=1,
        delivery_contract=delivery,
        overload_policy=required_overload)
    @test acquisition_delivery_contract(port) == delivery
    @test acquisition_product_contract(port) isa
        PORT_TEST_PLANT.AcquisitionProductContract
    @test acquisition_overload_policy(port) === required_overload
    @test resource_is_required(required_overload)
    @test resource_criticality(required_overload) isa RequiredResource
    @test maximum_resource_lateness_ns(required_overload) === nothing
    @test overload_recovery_occupancy(required_overload) == 0
    @test resource_is_required(port)
    @test maximum_resource_lateness_ns(port) === nothing
    @test overload_recovery_occupancy(port) == 0
    @test descriptor_accounting(port).capacity == 1
    @test descriptor_accounting(port).occupancy == 0
    @test port_lifecycle_state(port) == PortAccepting
    completion_policy = port_resource_policy(port)
    @test resource_capacity(completion_policy) == 1
    @test maximum_outstanding(completion_policy) == 1
    @test resource_full_policy(completion_policy) isa
          RetainProducerOnFull
    product_policy = payload_resource_policy(port)
    @test resource_capacity(product_policy) == 2
    @test payload_lifecycle_state(port) == PayloadPoolAccepting
    return_policy = lease_return_policy(port)
    @test resource_capacity(return_policy) == 2
    @test maximum_outstanding(return_policy) == 2
    @test resource_full_policy(return_policy) isa
          ReservedFullIsInvariant

    leases = (
        Ref(PayloadLeaseRef(0, 0, 0, 0)),
        Ref(PayloadLeaseRef(0, 0, 0, 0)))
    @test try_claim_product!(leases[1], port) ==
        PayloadTransitionSucceeded
    @test try_claim_product!(leases[2], port) ==
        PayloadTransitionSucceeded
    producer_product(port, leases[1][]).observation .= 1
    producer_product(port, leases[2][]).observation .= 2
    first = matching_acquisition_completion(
        port,
        StreamSequence(1),
        PORT_TEST_PLANT.PlantTimestamp(100),
        leases[1][],
        Int64(1_000))
    second = matching_acquisition_completion(
        port,
        StreamSequence(2),
        PORT_TEST_PLANT.PlantTimestamp(200),
        leases[2][],
        Int64(2_000))
    @test acquisition_completion_session(first) == session
    @test acquisition_completion_sequence(first) == StreamSequence(1)
    @test acquisition_completion_id(first) ==
        PORT_TEST_PLANT.AcquisitionID(:wfs_pixels)
    @test acquisition_completion_timestamp(first) ==
        PORT_TEST_PLANT.PlantTimestamp(100)
    @test acquisition_completion_publication_ns(first) == 1_000
    @test try_publish!(port, first).status == PortTransferSucceeded
    @test try_publish!(port, second).status == PortFull
    @test producer_product(port, leases[2][]).observation ==
        fill(Float32(2), 2, 2)

    output = Ref{AcquisitionCompletion}()
    @test try_take!(output, port).status == PortTransferSucceeded
    completion = output[]
    @test completed_product(port, completion).observation ==
        fill(Float32(1), 2, 2)
    @test release_product!(port, completion).status ==
        PortTransferSucceeded
    @test try_publish!(port, second).status == PortTransferSucceeded
    @test try_take!(output, port).status == PortTransferSucceeded
    @test completed_product(port, output[]).observation ==
        fill(Float32(2), 2, 2)
    @test release_product!(port, output[]).status ==
        PortTransferSucceeded
    @test acquisition_product_accounting(port).return_queued == 2
    @test reclaim_product_returns!(port) ==
          RingBatchResult(RingTransferSucceeded, 2)
    @test acquisition_product_accounting(port).free == 2

    lease_ref = Ref(PayloadLeaseRef(0, 0, 0, 0))
    completion_ref = Ref{AcquisitionCompletion}()
    expected_cycle = (
        PayloadTransitionSucceeded,
        PortTransferSucceeded,
        PortTransferSucceeded,
        Float32(3),
        PortTransferSucceeded)
    @test acquisition_port_cycle!(
        port, lease_ref, completion_ref, 3, 300) == expected_cycle
    expected_cycle = (
        PayloadTransitionSucceeded,
        PortTransferSucceeded,
        PortTransferSucceeded,
        Float32(4),
        PortTransferSucceeded)
    @test @inferred(acquisition_port_cycle!(
        port, lease_ref, completion_ref, 4, 400)) == expected_cycle
    if PORT_TESTS_WITH_COVERAGE
        @test_skip "allocation assertions are disabled under coverage"
    else
        @test @allocated(acquisition_port_cycle!(
            port, lease_ref, completion_ref, 5, 500)) == 0
    end

    mismatch_lease = Ref(PayloadLeaseRef(0, 0, 0, 0))
    @test try_claim_product!(mismatch_lease, port) ==
        PayloadTransitionSucceeded
    base_completion = matching_acquisition_completion(
        port,
        StreamSequence(6),
        PORT_TEST_PLANT.PlantTimestamp(600),
        mismatch_lease[],
        Int64(600))
    wrong_session = AcquisitionCompletion(
        RunSessionID(999),
        base_completion.descriptor_schema_id,
        base_completion.descriptor_schema_version,
        base_completion.stream_sequence,
        base_completion.acquisition,
        base_completion.completion_timestamp,
        base_completion.product_lease,
        base_completion.publication_execution_ns)
    @test try_publish!(port, wrong_session).reason == SessionMismatch
    wrong_schema = AcquisitionCompletion(
        base_completion.session,
        PortSchemaID(:wrong_completion),
        base_completion.descriptor_schema_version,
        base_completion.stream_sequence,
        base_completion.acquisition,
        base_completion.completion_timestamp,
        base_completion.product_lease,
        base_completion.publication_execution_ns)
    @test try_publish!(port, wrong_schema).reason ==
        DescriptorSchemaMismatch
    wrong_acquisition = AcquisitionCompletion(
        base_completion.session,
        base_completion.descriptor_schema_id,
        base_completion.descriptor_schema_version,
        base_completion.stream_sequence,
        PORT_TEST_PLANT.AcquisitionID(:other_acquisition),
        base_completion.completion_timestamp,
        base_completion.product_lease,
        base_completion.publication_execution_ns)
    @test try_publish!(port, wrong_acquisition).reason ==
        AcquisitionMismatch
    @test release_product!(port, wrong_acquisition).reason ==
        AcquisitionMismatch
    retained_product = producer_product(port, mismatch_lease[])
    fill!(retained_product.observation, Float32(6))
    @test retained_product.observation == fill(Float32(6), 2, 2)
    @test try_publish!(port, base_completion).status ==
        PortTransferSucceeded
    @test try_take!(completion_ref, port).status == PortTransferSucceeded
    @test release_product!(port, completion_ref[]).status ==
        PortTransferSucceeded
    @test release_product!(port, completion_ref[]).status == PortRejected
    abort_ref = Ref(PayloadLeaseRef(0, 0, 0, 0))
    @test try_claim_product!(abort_ref, port) ==
        PayloadTransitionSucceeded
        @test abort_product!(port, abort_ref[]) ==
        PayloadTransitionSucceeded

    @testset "Drop-newest policy and close/drain" begin
        drop_products = [
            PORT_TEST_PLANT.AcquisitionProducts(
                zeros(Float32, 1); metadata=(kind=:pixels,)),
            PORT_TEST_PLANT.AcquisitionProducts(
                zeros(Float32, 1); metadata=(kind=:pixels,)),
        ]
        drop_port = prepare_acquisition_completion_port(
            PORT_TEST_PLANT.AcquisitionID(:drop_pixels),
            drop_products;
            session=RunSessionID(82),
            product_pool_id=UInt64(145),
            ring_capacity=1,
            delivery_contract=delivery,
            overload_policy=AcquisitionOverloadPolicy(
                OptionalResource(),
                DropNewestOnFull();
                maximum_lateness_ns=10,
                recovery_occupancy=0))
        @test !resource_is_required(
            acquisition_overload_policy(drop_port))
        @test resource_criticality(drop_port) isa OptionalResource
        @test resource_full_policy(
            port_resource_policy(drop_port)) isa DropNewestOnFull
        @test resource_full_policy(
            payload_resource_policy(drop_port)) isa DropNewestOnFull

        drop_leases = (
            Ref{PayloadLeaseRef}(),
            Ref{PayloadLeaseRef}())
        for lease in drop_leases
            @test try_claim_product!(lease, drop_port) ==
                  PayloadTransitionSucceeded
        end
        @test_throws PortError close_acquisition_return_path!(
            drop_port)
        first_drop_completion = matching_acquisition_completion(
            drop_port,
            StreamSequence(1),
            PORT_TEST_PLANT.PlantTimestamp(1),
            drop_leases[1][],
            Int64(1))
        dropped_completion = matching_acquisition_completion(
            drop_port,
            StreamSequence(2),
            PORT_TEST_PLANT.PlantTimestamp(2),
            drop_leases[2][],
            Int64(2))
        @test try_publish!(drop_port, first_drop_completion).status ==
              PortTransferSucceeded
        @test try_publish!(drop_port, dropped_completion).status ==
              PortFull
        @test acquisition_product_accounting(drop_port).free == 1

        drop_output = Ref{AcquisitionCompletion}()
        @test try_take!(drop_output, drop_port).status ==
              PortTransferSucceeded
        @test acquisition_completion_sequence(drop_output[]) ==
              StreamSequence(1)
        @test release_product!(drop_port, drop_output[]).status ==
              PortTransferSucceeded
        @test reclaim_product_returns!(drop_port) ==
              RingBatchResult(RingTransferSucceeded, 1)

        third_lease = Ref{PayloadLeaseRef}()
        @test try_claim_product!(third_lease, drop_port) ==
              PayloadTransitionSucceeded
        third_completion = matching_acquisition_completion(
            drop_port,
            StreamSequence(3),
            PORT_TEST_PLANT.PlantTimestamp(3),
            third_lease[],
            Int64(3))
        @test try_publish!(drop_port, third_completion).status ==
              PortTransferSucceeded

        closed_lease = Ref{PayloadLeaseRef}()
        @test try_claim_product!(closed_lease, drop_port) ==
              PayloadTransitionSucceeded
        @test close_acquisition_completion!(drop_port).status ==
              PortTransferSucceeded
        @test port_lifecycle_state(drop_port) == PortDraining
        @test payload_lifecycle_state(drop_port) ==
              PayloadPoolDraining
        closed_completion = matching_acquisition_completion(
            drop_port,
            StreamSequence(4),
            PORT_TEST_PLANT.PlantTimestamp(4),
            closed_lease[],
            Int64(4))
        @test try_publish!(drop_port, closed_completion).status ==
              PortClosed
        @test producer_product(drop_port, closed_lease[]) ===
              drop_products[2]
        @test abort_product!(drop_port, closed_lease[]) ==
              PayloadTransitionSucceeded
        @test_throws PortError close_acquisition_return_path!(
            drop_port)
        @test try_take!(drop_output, drop_port).status ==
              PortTransferSucceeded
        @test acquisition_completion_sequence(drop_output[]) ==
              StreamSequence(3)
        @test release_product!(drop_port, drop_output[]).status ==
              PortTransferSucceeded
        @test try_take!(drop_output, drop_port).status == PortClosed
        @test port_lifecycle_state(drop_port) == PortDrained
        @test close_acquisition_return_path!(drop_port) ==
              RingTransferSucceeded
        @test lease_return_lifecycle_state(drop_port) == PortDraining
        @test reclaim_product_returns!(drop_port) ==
              RingBatchResult(RingTransferSucceeded, 1)
        @test lease_return_lifecycle_state(drop_port) == PortDrained
        @test acquisition_product_accounting(drop_port).free == 2
        @test payload_lifecycle_state(drop_port) ==
              PayloadPoolDrained
        @test payload_ownership_deficit(drop_port).deficit == 0
        post_close_claim = Ref(PayloadLeaseRef(1, 1, 1, 1))
        @test try_claim_product!(post_close_claim, drop_port) ==
              PayloadPoolClosed
        @test post_close_claim[] == PayloadLeaseRef(1, 1, 1, 1)
    end

    @testset "Lease-return invariant preserves consumer ownership" begin
        invariant_products = [
            PORT_TEST_PLANT.AcquisitionProducts(
                zeros(Float32, 1); metadata=(kind=:pixels,)),
        ]
        invariant_port = prepare_acquisition_completion_port(
            PORT_TEST_PLANT.AcquisitionID(:return_invariant),
            invariant_products;
            session=RunSessionID(83),
            product_pool_id=UInt64(148),
            delivery_contract=delivery,
            overload_policy=required_overload)
        invariant_lease = Ref{PayloadLeaseRef}()
        @test try_claim_product!(invariant_lease, invariant_port) ==
              PayloadTransitionSucceeded
        invariant_completion = matching_acquisition_completion(
            invariant_port,
            StreamSequence(1),
            PORT_TEST_PLANT.PlantTimestamp(1),
            invariant_lease[],
            Int64(1))
        @test try_publish!(
            invariant_port, invariant_completion).status ==
              PortTransferSucceeded
        invariant_output = Ref{AcquisitionCompletion}()
        @test try_take!(invariant_output, invariant_port).status ==
              PortTransferSucceeded

        @test try_submit!(
            invariant_port.product_pool.return_ring,
            invariant_lease[]) == RingTransferSucceeded
        invariant_release =
            release_product!(invariant_port, invariant_output[])
        @test invariant_release.status == PortRejected
        @test invariant_release.reason == LeaseReturnUnavailable
        @test port_payload_status(invariant_release) ==
              PayloadReturnCreditUnavailable
        @test completed_product(
            invariant_port,
            invariant_output[]) === invariant_products[1]
        @test payload_ownership_deficit(
            invariant_port).consumer_leased == 1
    end

    @testset "Product-storage alias dispatch" begin
        storage = zeros(Float32, 2, 2)
        plane_metadata = AdaptiveOpticsSim.Optics.OpticalPlaneMetadata(
            AdaptiveOpticsSim.Optics.DetectorPlane(),
            storage;
            coordinate_domain=AdaptiveOpticsSim.Optics.MetricCoordinates(),
            sampling=(1.0f0, 1.0f0))
        intensity = AdaptiveOpticsSim.Optics.IntensityMap(
            plane_metadata, storage)
        observation = AdaptiveOpticsSim.WavefrontSensors.WFSObservation(
            storage; units=:electrons, layout=:detector_pixels)
        measurement = AdaptiveOpticsSim.WavefrontSensors.WFSMeasurement(
            storage; units=:radian, kind=:wavefront_estimate)
        product_storage =
            AdaptiveOpticsHIL.Ports._acquisition_product_storage
        @test Base.invokelatest(product_storage, intensity) === storage
        @test Base.invokelatest(product_storage, observation) === storage
        @test Base.invokelatest(product_storage, measurement) === storage

        # A dispatch barrier prevents the compiler from folding these
        # constant-false ambiguity resolvers out of coverage instrumentation.
        may_alias = AdaptiveOpticsHIL.Ports._product_storage_may_alias
        @test !Base.invokelatest(may_alias, nothing, nothing)
        @test !Base.invokelatest(may_alias, nothing, ())
        @test !Base.invokelatest(may_alias, (), nothing)
        @test !Base.invokelatest(may_alias, nothing, Ref(1))
        @test !Base.invokelatest(may_alias, Ref(1), nothing)
        shared_ref = Ref(1)
        @test Base.invokelatest(may_alias, shared_ref, shared_ref)
        shared_array = zeros(1)
        @test Base.invokelatest(
            may_alias, (shared_array,), shared_array)
        @test Base.invokelatest(
            may_alias, shared_array, (shared_array,))
        @test !Base.invokelatest(
            may_alias, (zeros(1),), zeros(1))
        @test !Base.invokelatest(
            may_alias, zeros(1), (zeros(1),))
        @test !Base.invokelatest(may_alias, :left, :right)

        shared_observation =
            AdaptiveOpticsSim.WavefrontSensors.WFSObservation(
            zeros(Float32, 2, 2);
            units=:electrons,
            layout=:detector_pixels)
        wrapped_aliases = [
            PORT_TEST_PLANT.AcquisitionProducts(
                shared_observation; metadata=(kind=:wfs_pixels,)),
            PORT_TEST_PLANT.AcquisitionProducts(
                shared_observation; metadata=(kind=:wfs_pixels,)),
        ]
        @test_throws PortError prepare_acquisition_completion_port(
            PORT_TEST_PLANT.AcquisitionID(:wrapped_aliases),
            wrapped_aliases;
            session,
            product_pool_id=UInt64(144),
            delivery_contract=delivery,
            overload_policy=required_overload)
    end

    bad_products = [
        PORT_TEST_PLANT.AcquisitionProducts(
            zeros(Float32, 2, 2); metadata=(kind=:pixels,)),
        PORT_TEST_PLANT.AcquisitionProducts(
            zeros(Float32, 3, 2); metadata=(kind=:pixels,)),
    ]
    @test_throws PORT_TEST_PLANT.PlantPreparationError begin
        prepare_acquisition_completion_port(
            PORT_TEST_PLANT.AcquisitionID(:bad_pixels),
            bad_products;
            session,
            product_pool_id=UInt64(141),
            delivery_contract=delivery,
            overload_policy=required_overload)
    end
    abstract_products = PORT_TEST_PLANT.AcquisitionProducts[
        PORT_TEST_PLANT.AcquisitionProducts(
            zeros(Float32, 2, 2); metadata=(kind=:pixels,)),
    ]
    @test_throws PortError prepare_acquisition_completion_port(
        PORT_TEST_PLANT.AcquisitionID(:abstract_pixels),
        abstract_products;
        session,
        product_pool_id=UInt64(142),
        delivery_contract=delivery,
        overload_policy=required_overload)
    shared_observation = zeros(Float32, 2, 2)
    aliased_products = [
        PORT_TEST_PLANT.AcquisitionProducts(
            shared_observation; metadata=(kind=:pixels,)),
        PORT_TEST_PLANT.AcquisitionProducts(
            shared_observation; metadata=(kind=:pixels,)),
    ]
    @test_throws PortError prepare_acquisition_completion_port(
        PORT_TEST_PLANT.AcquisitionID(:aliased_pixels),
        aliased_products;
        session,
        product_pool_id=UInt64(143),
        delivery_contract=delivery,
        overload_policy=required_overload)
    @test_throws OwnershipError prepare_acquisition_completion_port(
        PORT_TEST_PLANT.AcquisitionID(:undersized_returns),
        products;
        session,
        product_pool_id=UInt64(146),
        product_return_capacity=1,
        delivery_contract=delivery,
        overload_policy=required_overload)
    @test_throws PortError prepare_acquisition_completion_port(
        PORT_TEST_PLANT.AcquisitionID(:invalid_full_policy),
        products;
        session,
        product_pool_id=UInt64(147),
        delivery_contract=delivery,
        overload_policy=AcquisitionOverloadPolicy(
            OptionalResource(),
            ReservedFullIsInvariant();
            maximum_lateness_ns=nothing,
            recovery_occupancy=0))
    @test_throws PortError prepare_acquisition_completion_port(
        PORT_TEST_PLANT.AcquisitionID(:required_drop),
        products;
        session,
        product_pool_id=UInt64(150),
        ring_capacity=1,
        delivery_contract=delivery,
        overload_policy=AcquisitionOverloadPolicy(
            RequiredResource(),
            DropNewestOnFull();
            maximum_lateness_ns=nothing,
            recovery_occupancy=0))
    @test_throws PortError prepare_acquisition_completion_port(
        PORT_TEST_PLANT.AcquisitionID(:invalid_recovery_threshold),
        products;
        session,
        product_pool_id=UInt64(151),
        ring_capacity=1,
        delivery_contract=delivery,
        overload_policy=AcquisitionOverloadPolicy(
            OptionalResource(),
            DropNewestOnFull();
            maximum_lateness_ns=nothing,
            recovery_occupancy=1))
    oversized_ring_port = prepare_acquisition_completion_port(
        PORT_TEST_PLANT.AcquisitionID(:oversized_ring),
        products;
        session,
        product_pool_id=UInt64(149),
        ring_capacity=4,
        delivery_contract=delivery,
        overload_policy=required_overload)
    oversized_ring_policy =
        port_resource_policy(oversized_ring_port)
    @test resource_capacity(oversized_ring_policy) == 4
    @test maximum_outstanding(oversized_ring_policy) == 2

    # Sampled device feedback deliberately uses this same complete-product
    # contract; it is not a CommandOutcome or a separate instrument API.
    @test first isa AcquisitionCompletion
    @test !(first isa CommandOutcome)
end
