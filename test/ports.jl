using AdaptiveOpticsHIL.Ownership
using AdaptiveOpticsHIL.Ports
import AdaptiveOpticsSim

const PORT_TEST_PLANT = AdaptiveOpticsSim.Plant
const PORT_TESTS_WITH_COVERAGE =
    Base.JLOptions().code_coverage != 0

function port_test_schema(::Type{T}=Float64;
    id=:hil_command,
    version=1,
    endpoint=:hil_dm,
    dimensions=(3,),
    basis=PORT_TEST_PLANT.CommandBasis(:actuator, :hil_actuators),
    basis_revision=1,
    value_policy=PORT_TEST_PLANT.CommandValuePolicy(),
    sequence_policy=PORT_TEST_PLANT.CommandSequencePolicy(),
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
        effective_time_policy=
            PORT_TEST_PLANT.CommandEffectiveTimePolicy(),
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

function finish_ready_command!(
    bridge,
    state,
    timestamp,
    publication_execution_ns)
    endpoint_state = command_endpoint_state(state)
    workspace = command_disposition_workspace(state)
    claim = PORT_TEST_PLANT.claim_next_application_ready_command!(
        bridge.endpoint, endpoint_state, timestamp)
    @assert !isnothing(claim)
    PORT_TEST_PLANT.mark_plant_command_applied!(
        workspace, bridge.endpoint, endpoint_state, claim)
    return publish_command_dispositions!(
        bridge, state, publication_execution_ns)
end

function inline_command_cycle!(
    ports,
    bridge,
    state,
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
        bridge, state, Int64(timestamp_ns + 2))
    endpoint_state = command_endpoint_state(state)
    workspace = command_disposition_workspace(state)
    claim = PORT_TEST_PLANT.claim_next_application_ready_command!(
        bridge.endpoint, endpoint_state, timestamp)
    PORT_TEST_PLANT.mark_plant_command_applied!(
        workspace, bridge.endpoint, endpoint_state, claim)
    disposition_count = publish_command_dispositions!(
        bridge, state, Int64(timestamp_ns + 3))
    take_result = try_take!(
        outcome_ref, command_completion_port(ports))
    release_result = release_outcome!(
        command_completion_port(ports), outcome_ref[])
    return (
        submit_result.status,
        process_result.status,
        disposition_count,
        take_result.status,
        release_result.status)
end

function leased_command_cycle!(
    ports,
    bridge,
    state,
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
        process_next_command!(bridge, state, Int64(timestamp_ns + 1))
    endpoint_state = command_endpoint_state(state)
    workspace = command_disposition_workspace(state)
    claim = PORT_TEST_PLANT.claim_next_application_ready_command!(
        bridge.endpoint, endpoint_state, timestamp)
    PORT_TEST_PLANT.mark_plant_command_applied!(
        workspace, bridge.endpoint, endpoint_state, claim)
    disposition_count = publish_command_dispositions!(
        bridge, state, Int64(timestamp_ns + 2))
    take_result = try_take!(outcome_ref, completion_port)
    release_result = release_outcome!(completion_port, outcome_ref[])
    return (
        claim_status,
        submit_result.status,
        process_result.status,
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
        AdapterReadinessSnapshot(AdapterReady, timestamp),
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
        @test_throws PortError RunSessionID(0)
        @test_throws PortError StreamSequence(false)
        @test_throws PortError PortSchemaID(Symbol(""))
        @test_throws PortError PortSchemaVersion(0)
        @test_throws PortError ExternalTimestampDomainID(Symbol(""))
        @test_throws PortError TimestampMappingVersion(0)

        receive = PORT_TEST_PLANT.PlantTimestamp(100)
        receive_only = receive_time_command_timing(receive)
        @test receive_only.source_kind == ReceiveTimestampOnly
        @test receive_only.receive_timestamp == receive

        mapped = mapped_source_command_timing(
            ExternalTimestampDomainID(:rtc_ptp),
            Int64(9_000),
            TimestampMappingVersion(3),
            PORT_TEST_PLANT.PlantTimestamp(95),
            receive;
            mapping_uncertainty=PORT_TEST_PLANT.PlantDuration(5))
        @test mapped.source_kind == MappedSourceTimestamp
        @test mapped.mapping_version == TimestampMappingVersion(3)
        mapped_from_narrow_integer = mapped_source_command_timing(
            ExternalTimestampDomainID(:rtc_ptp),
            Int32(9_001),
            TimestampMappingVersion(3),
            PORT_TEST_PLANT.PlantTimestamp(95),
            receive;
            mapping_uncertainty=PORT_TEST_PLANT.PlantDuration(5))
        @test source_timestamp_nanoseconds(
            mapped_from_narrow_integer) == 9_001
        @test_throws PortError mapped_source_command_timing(
            ExternalTimestampDomainID(:rtc_ptp),
            Int64(9_000),
            TimestampMappingVersion(3),
            PORT_TEST_PLANT.PlantTimestamp(106),
            receive;
            mapping_uncertainty=PORT_TEST_PLANT.PlantDuration(5))
        @test_throws PortError mapped_source_command_timing(
            ExternalTimestampDomainID(:rtc_ptp),
            typemax(UInt64),
            TimestampMappingVersion(3),
            receive,
            receive)

        delivery = AdapterDeliveryContract(
            PORT_TEST_PLANT.PlantDuration(25),
            PORT_TEST_PLANT.PlantDuration(1_000))
        @test delivery.complete_product_lead_time ==
            PORT_TEST_PLANT.PlantDuration(25)
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
        bridge = prepare_command_bridge(ports, endpoint)
        state = CommandBridgeState(bridge)

        timestamp = PORT_TEST_PLANT.PlantTimestamp(10)
        submission = claim_command_submission(
            submission_port, [0.1, 0.2, 0.3], 1, 1, timestamp)
        @test try_submit!(
            submission_port, submission, Int64(1_000)).status ==
            PortTransferSucceeded
        @test outcome_credit_accounting(submission_port).queued == 1
        @test process_next_command!(
            bridge, state, Int64(1_100)).status ==
            PortTransferSucceeded
        @test active_command_correlations(state) == 1
        @test command_payload_accounting(submission_port).consumer_leased == 1

        @test finish_ready_command!(
            bridge, state, timestamp, Int64(1_200)) == 1
        @test active_command_correlations(state) == 0
        outcome = take_command_outcome(completion_port)
        @test outcome_stage(outcome) == CoreCommandOutcome
        @test outcome_boundary_reason(outcome) == NoPortRejection
        @test outcome_reason(outcome) == :applied
        @test outcome_terminal_kind(outcome) ==
            PORT_TEST_PLANT.AppliedCommand
        @test outcome_endpoint(outcome) ==
            PORT_TEST_PLANT.CommandEndpointID(:hil_dm)
        @test outcome_model_endpoint(outcome) == outcome_endpoint(outcome)
        @test outcome_timing(outcome) == submission.timing
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
        @test command_payload_accounting(completion_port).free == 8
        @test outcome_credit_accounting(completion_port).free == 8
        @test release_outcome!(completion_port, outcome).status ==
            PortRejected
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
                     ExternalTimestampDomainID(:rtc),
                     Int64(20),
                     TimestampMappingVersion(1),
                     PORT_TEST_PLANT.PlantTimestamp(
                         PORT_TEST_PLANT.plant_nanoseconds(
                             s.timing.receive_timestamp) - 1),
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
            @test process_next_command!(
                bridge, state, Int64(timestamp_ns)).status ==
                PortTransferSucceeded
            outcome = take_command_outcome(completion_port)
            @test outcome_stage(outcome) == BoundaryCommandOutcome
            @test outcome.boundary_reason == expected_reason
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
        process_next_command!(bridge, state, Int64(timestamp_ns))
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
        process_next_command!(bridge, state, Int64(timestamp_ns))
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
        process_next_command!(bridge, state, Int64(timestamp_ns))
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
        process_next_command!(bridge, state, Int64(timestamp_ns))
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
        process_next_command!(bridge, state, Int64(timestamp_ns))
        finish_ready_command!(
            bridge, state, accepted_timestamp, Int64(timestamp_ns))
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
        process_next_command!(bridge, state, Int64(timestamp_ns))
        duplicate_outcome = take_command_outcome(completion_port)
        @test outcome_stage(duplicate_outcome) == CoreCommandOutcome
        @test outcome_reason(duplicate_outcome) == :duplicate_sequence
        release_outcome!(completion_port, duplicate_outcome)
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
        process_next_command!(bridge, state, Int64(3))
        @test PORT_TEST_PLANT.pending_command_count(
            command_endpoint_state(state)) == 1
        @test active_command_correlations(state) == 1
        finish_ready_command!(
            bridge, state, PORT_TEST_PLANT.PlantTimestamp(1), Int64(4))
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
        process_next_command!(bridge, state, Int64(1))
        no_credit = try_submit!(submission_port, second, Int64(2))
        @test no_credit.status == PortFull
        @test no_credit.reason == OutcomeCreditUnavailable
        @test port_payload_status(no_credit) == PayloadPoolExhausted
        @test abort_command_payload!(
            submission_port, second.payload.lease) ==
            PayloadTransitionSucceeded
        finish_ready_command!(
            bridge, state, PORT_TEST_PLANT.PlantTimestamp(1), Int64(2))
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
            command_disposition_workspace(state),
            endpoint,
            command_endpoint_state(state),
            foreign_command,
            PORT_TEST_PLANT.PlantTimestamp(3))
        @test_throws PortError publish_command_dispositions!(
            bridge, state, Int64(3))
        PORT_TEST_PLANT.clear_command_dispositions!(
            command_disposition_workspace(state))

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

        first_time = PORT_TEST_PLANT.PlantTimestamp(1)
        first = matching_command_submission(
            submission_port,
            StreamSequence(1),
            PORT_TEST_PLANT.PlantCommandSequence(1),
            receive_time_command_timing(first_time),
            InlineCommandPayload(0.1))
        try_submit!(submission_port, first, Int64(1))
        process_next_command!(bridge, state, Int64(1))
        claim = PORT_TEST_PLANT.claim_next_application_ready_command!(
            endpoint, command_endpoint_state(state), first_time)
        PORT_TEST_PLANT.mark_plant_command_applied!(
            command_disposition_workspace(state),
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
        @test process_next_command!(
            bridge, state, Int64(2)).status == PortTransferSucceeded
        first_outcome = take_command_outcome(completion_port)
        @test outcome_command_sequence(first_outcome) ==
            PORT_TEST_PLANT.PlantCommandSequence(1)
        release_outcome!(completion_port, first_outcome)

        finish_ready_command!(bridge, state, second_time, Int64(3))
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
        submission = claim_command_submission(
            submission_port,
            [2.0, 0.0, 0.0],
            1,
            1,
            PORT_TEST_PLANT.PlantTimestamp(1))
        try_submit!(submission_port, submission, Int64(1))
        @test_throws PORT_TEST_PLANT.PlantCommandError begin
            process_next_command!(bridge, state, Int64(2))
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
            process_next_command!(bridge, state, Int64(4))
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
        receive = PORT_TEST_PLANT.PlantTimestamp(10)
        timing = mapped_source_command_timing(
            domain,
            Int64(5_000),
            TimestampMappingVersion(2),
            PORT_TEST_PLANT.PlantTimestamp(9),
            receive;
            requested_effective_timestamp=receive,
            mapping_uncertainty=PORT_TEST_PLANT.PlantDuration(1))
        submission = matching_command_submission(
            submission_port,
            StreamSequence(1),
            PORT_TEST_PLANT.PlantCommandSequence(1),
            timing,
            InlineCommandPayload(0.1))
        try_submit!(submission_port, submission, Int64(10))
        process_next_command!(bridge, state, Int64(11))
        finish_ready_command!(bridge, state, receive, Int64(12))
        outcome = take_command_outcome(completion_port)
        @test outcome_stage(outcome) == CoreCommandOutcome
        @test source_timestamp_domain(outcome_timing(outcome)) == domain
        @test timestamp_mapping_version(outcome_timing(outcome)) ==
            TimestampMappingVersion(2)
        release_outcome!(completion_port, outcome)

        stale_timing = mapped_source_command_timing(
            domain,
            Int64(5_001),
            TimestampMappingVersion(1),
            PORT_TEST_PLANT.PlantTimestamp(10),
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
        process_next_command!(bridge, state, Int64(14))
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
        outcome_ref = Ref{CommandOutcome{InlineCommandPayload{Float64}}}()
        expected = (
            PortTransferSucceeded,
            PortTransferSucceeded,
            1,
            PortTransferSucceeded,
            PortTransferSucceeded)
        @test inline_command_cycle!(
            ports, bridge, state, outcome_ref, 1, 1) == expected
        @test @inferred(inline_command_cycle!(
            ports, bridge, state, outcome_ref, 2, 2)) == expected
        if PORT_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test @allocated(inline_command_cycle!(
                ports, bridge, state, outcome_ref, 3, 3)) == 0
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
            ports, bridge, state, lease_ref, outcome_ref, 1, 1) ==
            expected
        @test @inferred(leased_command_cycle!(
            ports, bridge, state, lease_ref, outcome_ref, 2, 2)) ==
            expected
        if PORT_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test @allocated(leased_command_cycle!(
                ports, bridge, state, lease_ref, outcome_ref, 3, 3)) == 0
        end
    end
end

@testset "Complete acquisition ports" begin
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
    port = prepare_acquisition_completion_port(
        PORT_TEST_PLANT.AcquisitionID(:wfs_pixels),
        products;
        session,
        product_pool_id=UInt64(140),
        ring_capacity=1,
        delivery_contract=delivery)
    @test acquisition_delivery_contract(port) == delivery
    @test acquisition_product_contract(port) isa
        PORT_TEST_PLANT.AcquisitionProductContract

    leases = (
        Ref(PayloadLeaseRef(0, 0, 0, 0)),
        Ref(PayloadLeaseRef(0, 0, 0, 0)))
    @test try_claim_product!(leases[1], port) ==
        PayloadTransitionSucceeded
    @test try_claim_product!(leases[2], port) ==
        PayloadTransitionSucceeded
    producer_product(port, leases[1][]).observation .= 1
    producer_product(port, leases[2][]).observation .= 2
    readiness = AdapterReadinessSnapshot(
        AdapterReady, PORT_TEST_PLANT.PlantTimestamp(100))
    first = matching_acquisition_completion(
        port,
        StreamSequence(1),
        PORT_TEST_PLANT.PlantTimestamp(100),
        readiness,
        leases[1][],
        Int64(1_000))
    second = matching_acquisition_completion(
        port,
        StreamSequence(2),
        PORT_TEST_PLANT.PlantTimestamp(200),
        readiness,
        leases[2][],
        Int64(2_000))
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
        AdapterReadinessSnapshot(
            AdapterReady, PORT_TEST_PLANT.PlantTimestamp(600)),
        mismatch_lease[],
        Int64(600))
    wrong_session = AcquisitionCompletion(
        RunSessionID(999),
        base_completion.descriptor_schema_id,
        base_completion.descriptor_schema_version,
        base_completion.stream_sequence,
        base_completion.acquisition,
        base_completion.completion_timestamp,
        base_completion.readiness,
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
        base_completion.readiness,
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
        base_completion.readiness,
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
            delivery_contract=delivery)
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
        delivery_contract=delivery)
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
        delivery_contract=delivery)

    # Sampled device feedback deliberately uses this same complete-product
    # contract; it is not a CommandOutcome or a separate instrument API.
    @test first isa AcquisitionCompletion
    @test !(first isa CommandOutcome)
end
