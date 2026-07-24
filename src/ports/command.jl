"""Small scalar command value carried directly in a submission descriptor."""
struct InlineCommandPayload{T}
    value::T
end

"""Generation-checked reference to a command buffer in prepared storage."""
struct LeasedCommandPayload
    lease::PayloadLeaseRef
end

"""
Caller-owned command submission before terminal-outcome credit is reserved.
Port and core schema identities remain explicit so incompatibilities are
observable rather than silently rewritten by the boundary.
"""
struct CommandSubmission{P}
    session::RunSessionID
    descriptor_schema_id::PortSchemaID
    descriptor_schema_version::PortSchemaVersion
    stream_sequence::StreamSequence
    endpoint::CommandEndpointID
    core_schema_id::PlantCommandSchemaID
    core_schema_version::PlantCommandSchemaVersion
    basis::CommandBasis
    basis_revision::CommandBasisRevision
    timing::CommandTimingMetadata
    command_sequence::PlantCommandSequence
    payload::P
end

struct _CommandSubmissionDescriptorToken end
const _COMMAND_SUBMISSION_DESCRIPTOR_TOKEN =
    _CommandSubmissionDescriptorToken()

"""
Transferred command descriptor. Construction is owned by
`CommandSubmissionPort` because every instance carries a reserved terminal
outcome credit.
"""
struct CommandSubmissionDescriptor{P}
    submission::CommandSubmission{P}
    outcome_credit::PayloadLeaseRef
    ingress_execution_ns::Int64

    function CommandSubmissionDescriptor(
        ::_CommandSubmissionDescriptorToken,
        submission::CommandSubmission{P},
        outcome_credit::PayloadLeaseRef,
        ingress_execution_ns::Int64) where {P}
        return new{P}(submission, outcome_credit, ingress_execution_ns)
    end
end

submission_session(value::Union{
    CommandSubmission,CommandSubmissionDescriptor}) =
    _command_submission(value).session
submission_stream_sequence(value::Union{
    CommandSubmission,CommandSubmissionDescriptor}) =
    _command_submission(value).stream_sequence
submission_endpoint(value::Union{
    CommandSubmission,CommandSubmissionDescriptor}) =
    _command_submission(value).endpoint
submission_schema_id(value::Union{
    CommandSubmission,CommandSubmissionDescriptor}) =
    _command_submission(value).core_schema_id
submission_schema_version(value::Union{
    CommandSubmission,CommandSubmissionDescriptor}) =
    _command_submission(value).core_schema_version
submission_command_sequence(value::Union{
    CommandSubmission,CommandSubmissionDescriptor}) =
    _command_submission(value).command_sequence
submission_timing(value::Union{
    CommandSubmission,CommandSubmissionDescriptor}) =
    _command_submission(value).timing
submission_payload(value::Union{
    CommandSubmission,CommandSubmissionDescriptor}) =
    _command_submission(value).payload

@inline _command_submission(value::CommandSubmission) = value
@inline _command_submission(value::CommandSubmissionDescriptor) =
    value.submission

@enum CommandOutcomeStage::UInt8 begin
    BoundaryCommandOutcome = 0x01
    CoreCommandOutcome = 0x02
end

"""
Exactly one terminal HIL outcome for one transferred command. Core disposition
fields are flattened so the descriptor remains concrete and allocation-free;
zero presentation/terminal-kind values identify a boundary outcome.
"""
struct CommandOutcome{P}
    session::RunSessionID
    stream_sequence::StreamSequence
    submitted_endpoint::CommandEndpointID
    model_endpoint::CommandEndpointID
    command_sequence::PlantCommandSequence
    timing::CommandTimingMetadata
    payload::P
    stage::CommandOutcomeStage
    boundary_reason::PortRejectionReason
    reason::Symbol
    presentation::UInt64
    terminal_kind_code::UInt8
    terminal_timestamp::PlantTimestamp
    lateness::PlantDuration
    superseding_presentation::UInt64
    outcome_credit::PayloadLeaseRef
    ingress_execution_ns::Int64
    publication_execution_ns::Int64
end

outcome_stage(outcome::CommandOutcome) = outcome.stage
outcome_boundary_reason(outcome::CommandOutcome) = outcome.boundary_reason
outcome_reason(outcome::CommandOutcome) = outcome.reason
outcome_session(outcome::CommandOutcome) = outcome.session
outcome_stream_sequence(outcome::CommandOutcome) = outcome.stream_sequence
outcome_endpoint(outcome::CommandOutcome) = outcome.submitted_endpoint
outcome_model_endpoint(outcome::CommandOutcome) = outcome.model_endpoint
outcome_command_sequence(outcome::CommandOutcome) = outcome.command_sequence
outcome_timing(outcome::CommandOutcome) = outcome.timing
outcome_ingress_execution_ns(outcome::CommandOutcome) =
    outcome.ingress_execution_ns
outcome_publication_execution_ns(outcome::CommandOutcome) =
    outcome.publication_execution_ns
outcome_requested_effective_timestamp(outcome::CommandOutcome) =
    outcome.timing.requested_effective_timestamp
outcome_terminal_timestamp(outcome::CommandOutcome) =
    outcome.terminal_timestamp
outcome_lateness(outcome::CommandOutcome) = outcome.lateness

@inline function outcome_presentation_id(outcome::CommandOutcome)
    iszero(outcome.presentation) && return nothing
    return CommandPresentationID(outcome.presentation)
end

@inline function outcome_terminal_kind(outcome::CommandOutcome)
    iszero(outcome.terminal_kind_code) && return nothing
    return CommandTerminalKind(outcome.terminal_kind_code)
end

@inline function outcome_superseding_presentation_id(
    outcome::CommandOutcome)
    iszero(outcome.superseding_presentation) && return nothing
    return CommandPresentationID(outcome.superseding_presentation)
end

struct CommandSubmissionPort{P,L,T<:AbstractCommandTimingContract}
    session::RunSessionID
    descriptor_schema_id::PortSchemaID
    descriptor_schema_version::PortSchemaVersion
    endpoint::CommandEndpointID
    core_schema_id::PlantCommandSchemaID
    core_schema_version::PlantCommandSchemaVersion
    basis::CommandBasis
    basis_revision::CommandBasisRevision
    timing_contract::T
    ring::SPSCDescriptorRing{CommandSubmissionDescriptor{P}}
    payload_pool::L
    outcome_credit_pool::PayloadPool{Nothing}
    credit_scratch::Base.RefValue{PayloadLeaseRef}
end

struct CommandCompletionPort{P,L}
    session::RunSessionID
    endpoint::CommandEndpointID
    ring::SPSCDescriptorRing{CommandOutcome{P}}
    payload_pool::L
    outcome_credit_pool::PayloadPool{Nothing}
end

"""Prepared paired ports sharing one bounded terminal-outcome credit pool."""
struct PreparedCommandPorts{S<:CommandSubmissionPort,
    C<:CommandCompletionPort}
    submission::S
    completion::C
end

command_submission_port(ports::PreparedCommandPorts) = ports.submission
command_completion_port(ports::PreparedCommandPorts) = ports.completion

@inline function _checked_port_capacity(capacity::Integer, component::Symbol)
    capacity > 0 || throw(PortError(component, :invalid_capacity,
        "port capacity must be positive"))
    capacity <= typemax(Int) || throw(PortError(
        component, :invalid_capacity,
        "port capacity exceeds the addressable range"))
    return Int(capacity)
end

@inline _checked_port_capacity(::Bool, component::Symbol) =
    throw(PortError(component, :invalid_capacity,
        "port capacity must be an integer count, not Bool"))

function _validate_inline_command_type(
    endpoint::PreparedCommandEndpoint,
    ::Type{T}) where {T}
    schema = command_schema(endpoint)
    isempty(command_dimensions(schema)) || throw(PortError(
        :command_port, :payload_shape,
        "inline command payloads require a scalar core command schema"))
    command_numeric_type(schema) === T || throw(PortError(
        :command_port, :payload_numeric_type,
        "inline command type does not match the core command schema"))
    isconcretetype(T) && Base.allocatedinline(T) || throw(PortError(
        :command_port, :boxed_inline_payload,
        "inline command payload type must be concrete and stored inline"))
    return T
end

function _validate_leased_command_buffer(
    endpoint::PreparedCommandEndpoint,
    payload::AbstractArray)
    schema = command_schema(endpoint)
    dimensions = command_dimensions(schema)
    isempty(dimensions) && throw(PortError(
        :command_port, :payload_shape,
        "leased command buffers require an array-valued core command schema"))
    size(payload) == dimensions || throw(PortError(
        :command_port, :payload_shape,
        "leased command payload shape does not match the core command schema"))
    eltype(payload) === command_numeric_type(schema) || throw(PortError(
        :command_port, :payload_numeric_type,
        "leased command payload element type does not match the core command schema"))
    typeof(backend(payload)) === typeof(backend(endpoint)) ||
        throw(PortError(:command_port, :payload_backend,
            "leased command payload backend does not match the prepared core endpoint"))
    return payload
end

function _validate_distinct_command_buffers(
    payload_buffers::AbstractVector{<:AbstractArray})
    @inbounds for right in 2:length(payload_buffers)
        for left in 1:(right - 1)
            Base.mightalias(
                payload_buffers[left], payload_buffers[right]) &&
                throw(PortError(
                    :command_port,
                    :aliased_payload_storage,
                    "prepared command payload buffers must not alias"))
        end
    end
    return payload_buffers
end

function _validate_leased_command_buffer(
    ::PreparedCommandEndpoint,
    payload)
    throw(PortError(
        :command_port, :payload_type,
        "leased command payload must be an AbstractArray; got $(typeof(payload))"))
end

function _prepare_command_ports(
    ::Type{P},
    payload_pool::L,
    endpoint::PreparedCommandEndpoint;
    session::RunSessionID,
    submission_capacity,
    completion_capacity,
    outcome_credit_pool_id::UInt64,
    descriptor_schema_id::PortSchemaID,
    descriptor_schema_version::PortSchemaVersion,
    timing_contract::T) where {
    P,L,T<:AbstractCommandTimingContract}
    checked_submission_capacity =
        _checked_port_capacity(submission_capacity, :command_submission)
    checked_completion_capacity =
        _checked_port_capacity(completion_capacity, :command_completion)
    credits = PayloadPool(
        fill(nothing, checked_completion_capacity),
        outcome_credit_pool_id,
        run_session_value(session))
    submission = CommandSubmissionPort{P,L,T}(
        session,
        descriptor_schema_id,
        descriptor_schema_version,
        command_endpoint_id(endpoint),
        command_schema_id(command_schema(endpoint)),
        command_schema_version(command_schema(endpoint)),
        command_basis(command_schema(endpoint)),
        command_basis_revision(command_schema(endpoint)),
        timing_contract,
        SPSCDescriptorRing{CommandSubmissionDescriptor{P}}(
            checked_submission_capacity),
        payload_pool,
        credits,
        Ref(PayloadLeaseRef(0, 0, 0, 0)))
    completion = CommandCompletionPort{P,L}(
        session,
        command_endpoint_id(endpoint),
        SPSCDescriptorRing{CommandOutcome{P}}(
            checked_completion_capacity),
        payload_pool,
        credits)
    return PreparedCommandPorts(submission, completion)
end

"""
    prepare_command_ports(endpoint, T; ...)

Prepare a paired submission/outcome boundary for scalar commands carried
inline. `completion_capacity` is also the exact terminal-outcome credit count.
"""
function prepare_command_ports(
    endpoint::PreparedCommandEndpoint,
    ::Type{T};
    session::RunSessionID,
    submission_capacity,
    completion_capacity=submission_capacity,
    outcome_credit_pool_id::UInt64,
    descriptor_schema_id::PortSchemaID=
        PortSchemaID(:command_submission),
    descriptor_schema_version::PortSchemaVersion=PortSchemaVersion(1),
    timing_contract::AbstractCommandTimingContract=
        ReceiveTimeTimingContract()) where {T}
    _validate_inline_command_type(endpoint, T)
    return _prepare_command_ports(
        InlineCommandPayload{T},
        nothing,
        endpoint;
        session,
        submission_capacity,
        completion_capacity,
        outcome_credit_pool_id,
        descriptor_schema_id,
        descriptor_schema_version,
        timing_contract)
end

"""
    prepare_command_ports(endpoint, payload_buffers; ...)

Prepare a paired command boundary over caller-supplied fixed-shape array
buffers. Every buffer is checked cold against the prepared core endpoint before
the generation-checked pool is armed.
"""
function prepare_command_ports(
    endpoint::PreparedCommandEndpoint,
    payload_buffers::AbstractVector{A};
    session::RunSessionID,
    payload_pool_id::UInt64,
    outcome_credit_pool_id::UInt64,
    submission_capacity=length(payload_buffers),
    completion_capacity=length(payload_buffers),
    descriptor_schema_id::PortSchemaID=
        PortSchemaID(:command_submission),
    descriptor_schema_version::PortSchemaVersion=PortSchemaVersion(1),
    timing_contract::AbstractCommandTimingContract=
        ReceiveTimeTimingContract()) where {A}
    isempty(payload_buffers) && throw(PortError(
        :command_port, :invalid_payload_capacity,
        "command payload-buffer capacity must be positive"))
    isconcretetype(A) || throw(PortError(
        :command_port, :abstract_payload_storage,
        "command payload-buffer vector must have one concrete storage type"))
    payload_pool_id != outcome_credit_pool_id || throw(PortError(
        :command_port, :duplicate_pool_id,
        "command payload and terminal-outcome credit pools require distinct identities"))
    for payload in payload_buffers
        _validate_leased_command_buffer(endpoint, payload)
    end
    _validate_distinct_command_buffers(payload_buffers)
    pool = PayloadPool(
        payload_buffers, payload_pool_id, run_session_value(session))
    return _prepare_command_ports(
        LeasedCommandPayload,
        pool,
        endpoint;
        session,
        submission_capacity,
        completion_capacity,
        outcome_credit_pool_id,
        descriptor_schema_id,
        descriptor_schema_version,
        timing_contract)
end

"""
Construct a submission whose boundary and core identities exactly match
`port`. Callers may construct `CommandSubmission` directly when intentionally
testing incompatible metadata.
"""
function matching_command_submission(
    port::CommandSubmissionPort{P},
    stream_sequence::StreamSequence,
    command_sequence::PlantCommandSequence,
    timing::CommandTimingMetadata,
    payload::P) where {P}
    return CommandSubmission(
        port.session,
        port.descriptor_schema_id,
        port.descriptor_schema_version,
        stream_sequence,
        port.endpoint,
        port.core_schema_id,
        port.core_schema_version,
        port.basis,
        port.basis_revision,
        timing,
        command_sequence,
        payload)
end

"""Claim one producer-owned command buffer from a leased command port."""
try_claim_command_payload!(
    output::Base.RefValue{PayloadLeaseRef},
    port::CommandSubmissionPort{LeasedCommandPayload}) =
    try_claim_payload!(output, port.payload_pool)

"""Access one producer-owned command buffer before submission."""
producer_command_payload(
    port::CommandSubmissionPort{LeasedCommandPayload},
    lease::PayloadLeaseRef) =
    producer_payload(port.payload_pool, lease)

"""Return an unpublished producer-owned command buffer to its pool."""
abort_command_payload!(
    port::CommandSubmissionPort{LeasedCommandPayload},
    lease::PayloadLeaseRef) =
    abort_payload!(port.payload_pool, lease)

command_payload_accounting(
    port::Union{
        CommandSubmissionPort{LeasedCommandPayload},
        CommandCompletionPort{LeasedCommandPayload}}) =
    payload_pool_accounting(port.payload_pool)

@inline _submission_payload_status(
    ::CommandSubmissionPort{<:InlineCommandPayload},
    ::InlineCommandPayload) = PayloadTransitionSucceeded

@inline function _submission_payload_status(
    port::CommandSubmissionPort{LeasedCommandPayload},
    payload::LeasedCommandPayload)
    return _lease_state_status(
        port.payload_pool, payload.lease, _PAYLOAD_PRODUCER_OWNED)
end

@inline _queue_submission_payload!(
    ::CommandSubmissionPort{<:InlineCommandPayload},
    ::InlineCommandPayload) = PayloadTransitionSucceeded

@inline function _queue_submission_payload!(
    port::CommandSubmissionPort{LeasedCommandPayload},
    payload::LeasedCommandPayload)
    return queue_payload!(port.payload_pool, payload.lease)
end

@inline function _lease_submission_payload!(
    ::CommandSubmissionPort{<:InlineCommandPayload},
    ::InlineCommandPayload)
    return PayloadTransitionSucceeded
end

@inline function _lease_submission_payload!(
    port::CommandSubmissionPort{LeasedCommandPayload},
    payload::LeasedCommandPayload)
    return lease_payload!(port.payload_pool, payload.lease)
end

@inline _ring_port_result(status::RingStatus) =
    status == RingTransferSucceeded ? PortResult(PortTransferSucceeded) :
    status == RingFull ? PortResult(PortFull) :
    status == RingEmpty ? PortResult(PortEmpty) :
    PortResult(PortClosed)

"""
    try_submit!(port, submission, ingress_execution_ns)

Attempt one command ownership transfer. Full, closed, session mismatch, and
invalid producer lease leave the command payload producer-owned. Success
reserves one outcome credit before release-publishing the descriptor and is not
semantic core admission.
"""
function try_submit!(
    port::CommandSubmissionPort{P},
    submission::CommandSubmission{P},
    ingress_execution_ns::Int64) where {P}
    submission.session == port.session ||
        return PortResult(PortRejected, SessionMismatch)

    payload_status =
        _submission_payload_status(port, submission.payload)
    payload_status == PayloadTransitionSucceeded || return PortResult(
        PortRejected, PayloadLeaseMismatch, payload_status)

    ring_status = _producer_submission_status(port.ring)
    ring_status == RingTransferSucceeded ||
        return _ring_port_result(ring_status)

    credit_status =
        try_claim_payload!(port.credit_scratch, port.outcome_credit_pool)
    if credit_status != PayloadTransitionSucceeded
        credit_status == PayloadPoolExhausted &&
            return PortResult(
                PortFull, OutcomeCreditUnavailable, credit_status)
        throw(PortError(:command_submission, :outcome_credit_failure,
            "terminal-outcome credit pool entered an invalid producer state"))
    end
    credit = port.credit_scratch[]

    payload_status =
        _queue_submission_payload!(port, submission.payload)
    # Producer ownership was checked above and no other legal owner can change
    # it before this transition.
    # COV_EXCL_START
    if payload_status != PayloadTransitionSucceeded
        abort_payload!(port.outcome_credit_pool, credit)
        return PortResult(
            PortRejected, PayloadLeaseMismatch, payload_status)
    end
    # COV_EXCL_STOP
    credit_status = queue_payload!(port.outcome_credit_pool, credit)
    credit_status == PayloadTransitionSucceeded || throw(PortError(
        :command_submission, :outcome_credit_failure,
        "reserved terminal-outcome credit could not be queued"))

    descriptor = CommandSubmissionDescriptor(
        _COMMAND_SUBMISSION_DESCRIPTOR_TOKEN,
        submission,
        credit,
        ingress_execution_ns)
    ring_status = try_submit!(port.ring, descriptor)
    ring_status == RingTransferSucceeded || throw(PortError(
        :command_submission, :publication_invariant,
        "descriptor publication failed after successful producer preflight"))
    return PortResult(PortTransferSucceeded)
end

"""
Take one transferred command descriptor for the HIL consumer. A leased command
buffer becomes consumer-owned before success is returned.
"""
function try_take!(
    output::Base.RefValue{CommandSubmissionDescriptor{P}},
    port::CommandSubmissionPort{P}) where {P}
    ring_status = try_take!(output, port.ring)
    ring_status == RingTransferSucceeded ||
        return _ring_port_result(ring_status)
    descriptor = output[]
    payload_status =
        _lease_submission_payload!(port, descriptor.submission.payload)
    payload_status == PayloadTransitionSucceeded || throw(PortError(
        :command_submission, :payload_lease_invariant,
        "published command payload could not be leased by the consumer"))
    return PortResult(PortTransferSucceeded)
end

@inline _consumer_submission_payload(
    ::CommandSubmissionPort{<:InlineCommandPayload},
    payload::InlineCommandPayload) = payload.value

@inline _consumer_submission_payload(
    port::CommandSubmissionPort{LeasedCommandPayload},
    payload::LeasedCommandPayload) =
    consumer_payload(port.payload_pool, payload.lease)

function try_take!(
    output::Base.RefValue{CommandOutcome{P}},
    port::CommandCompletionPort{P}) where {P}
    ring_status = try_take!(output, port.ring)
    ring_status == RingTransferSucceeded ||
        return _ring_port_result(ring_status)
    outcome = output[]
    credit_status =
        lease_payload!(port.outcome_credit_pool, outcome.outcome_credit)
    credit_status == PayloadTransitionSucceeded || throw(PortError(
        :command_completion, :outcome_credit_invariant,
        "published command outcome did not carry a queued credit"))
    return PortResult(PortTransferSucceeded)
end

@inline function _require_completion_outcome(
    port::CommandCompletionPort,
    outcome::CommandOutcome)
    outcome.session == port.session || throw(PortError(
        :command_completion, :session_mismatch,
        "command outcome belongs to another run/session"))
    outcome.model_endpoint == port.endpoint || throw(PortError(
        :command_completion, :endpoint_mismatch,
        "command outcome belongs to another prepared core endpoint"))
    return nothing
end

@inline function outcome_payload(
    port::CommandCompletionPort{<:InlineCommandPayload},
    outcome::CommandOutcome{<:InlineCommandPayload})
    _require_completion_outcome(port, outcome)
    return outcome.payload.value
end

@inline function outcome_payload(
    port::CommandCompletionPort{LeasedCommandPayload},
    outcome::CommandOutcome{LeasedCommandPayload})
    _require_completion_outcome(port, outcome)
    return consumer_payload(port.payload_pool, outcome.payload.lease)
end

@inline _outcome_payload_release_status(
    ::CommandCompletionPort{<:InlineCommandPayload},
    ::CommandOutcome{<:InlineCommandPayload}) =
    PayloadTransitionSucceeded

@inline _release_outcome_payload!(
    ::CommandCompletionPort{<:InlineCommandPayload},
    ::CommandOutcome{<:InlineCommandPayload}) =
    PayloadTransitionSucceeded

@inline function _outcome_payload_release_status(
    port::CommandCompletionPort{LeasedCommandPayload},
    outcome::CommandOutcome{LeasedCommandPayload})
    return _lease_state_status(
        port.payload_pool,
        outcome.payload.lease,
        _PAYLOAD_CONSUMER_LEASED)
end

@inline function _release_outcome_payload!(
    port::CommandCompletionPort{LeasedCommandPayload},
    outcome::CommandOutcome{LeasedCommandPayload})
    return release_payload!(port.payload_pool, outcome.payload.lease)
end

"""
Release a consumed outcome. For leased commands this atomically prevalidates
both resources, then returns the command buffer and its reserved outcome credit
to their pools.
"""
function release_outcome!(
    port::CommandCompletionPort{P},
    outcome::CommandOutcome{P}) where {P}
    outcome.session == port.session || return PortResult(
        PortRejected, SessionMismatch, WrongPayloadSession)
    outcome.model_endpoint == port.endpoint ||
        return PortResult(PortRejected, CommandEndpointMismatch)
    payload_status = _outcome_payload_release_status(port, outcome)
    payload_status == PayloadTransitionSucceeded || return PortResult(
        PortRejected, PayloadLeaseMismatch, payload_status)
    credit_status = _lease_state_status(
        port.outcome_credit_pool,
        outcome.outcome_credit,
        _PAYLOAD_CONSUMER_LEASED)
    credit_status == PayloadTransitionSucceeded || return PortResult(
        PortRejected, OutcomeCreditUnavailable, credit_status)

    payload_status = _release_outcome_payload!(port, outcome)
    payload_status == PayloadTransitionSucceeded || throw(PortError(
        :command_completion, :payload_release_invariant,
        "prevalidated command payload could not be released"))
    credit_status =
        release_payload!(port.outcome_credit_pool, outcome.outcome_credit)
    credit_status == PayloadTransitionSucceeded || throw(PortError(
        :command_completion, :credit_release_invariant,
        "prevalidated terminal-outcome credit could not be released"))
    return PortResult(PortTransferSucceeded)
end

outcome_credit_accounting(port::Union{
    CommandSubmissionPort,CommandCompletionPort}) =
    payload_pool_accounting(port.outcome_credit_pool)

struct PreparedCommandBridge{
    S<:CommandSubmissionPort,
    C<:CommandCompletionPort,
    E<:PreparedCommandEndpoint}
    submission::S
    completion::C
    endpoint::E
end

"""
Single-writer state for one command bridge and its core endpoint. Correlation
storage is bounded by the paired completion-credit count.
"""
mutable struct CommandBridgeState{
    E<:CommandEndpointState,
    W<:CommandDispositionWorkspace,
    D}
    endpoint_state::E
    disposition_workspace::W
    descriptor_scratch::Base.RefValue{D}
    presentations::Memory{CommandPresentationID}
    descriptors::Memory{D}
    active::Memory{Bool}
    active_count::Int
    last_stream_sequence::UInt64
    has_stream_sequence::Bool
end

"""
Bind a paired HIL command boundary to its exact prepared core endpoint.
"""
function prepare_command_bridge(
    ports::PreparedCommandPorts,
    endpoint::PreparedCommandEndpoint)
    submission = ports.submission
    submission.endpoint == command_endpoint_id(endpoint) ||
        throw(PortError(:command_bridge, :endpoint_mismatch,
            "command port does not target the prepared core endpoint"))
    submission.core_schema_id ==
        command_schema_id(command_schema(endpoint)) ||
        throw(PortError(:command_bridge, :schema_mismatch,
            "command port schema does not match the prepared core endpoint"))
    submission.core_schema_version ==
        command_schema_version(command_schema(endpoint)) ||
        throw(PortError(:command_bridge, :schema_version_mismatch,
            "command port schema version does not match the prepared core endpoint"))
    return PreparedCommandBridge(
        submission, ports.completion, endpoint)
end

function CommandBridgeState(
    bridge::PreparedCommandBridge;
    initial_timestamp::PlantTimestamp=zero(PlantTimestamp))
    endpoint_state =
        CommandEndpointState(bridge.endpoint; initial_timestamp)
    workspace = CommandDispositionWorkspace(bridge.endpoint)
    D = eltype(bridge.submission.ring.slots)
    capacity = payload_pool_capacity(
        bridge.submission.outcome_credit_pool)
    active = Memory{Bool}(undef, capacity)
    fill!(active, false)
    return CommandBridgeState(
        endpoint_state,
        workspace,
        Ref{D}(),
        Memory{CommandPresentationID}(undef, capacity),
        Memory{D}(undef, capacity),
        active,
        0,
        UInt64(0),
        false)
end

command_endpoint_state(state::CommandBridgeState) = state.endpoint_state
command_disposition_workspace(state::CommandBridgeState) =
    state.disposition_workspace
active_command_correlations(state::CommandBridgeState) = state.active_count

@inline function _command_boundary_reason(
    bridge::PreparedCommandBridge,
    state::CommandBridgeState,
    descriptor::CommandSubmissionDescriptor)
    submission = descriptor.submission
    submission.descriptor_schema_id ==
        bridge.submission.descriptor_schema_id ||
        return DescriptorSchemaMismatch
    submission.descriptor_schema_version ==
        bridge.submission.descriptor_schema_version ||
        return DescriptorSchemaMismatch

    sequence = stream_sequence_value(submission.stream_sequence)
    if state.has_stream_sequence &&
            sequence <= state.last_stream_sequence
        return CommandStreamSequenceNotIncreasing
    end
    state.last_stream_sequence = sequence
    state.has_stream_sequence = true

    submission.basis == bridge.submission.basis ||
        return CommandBasisMismatch
    submission.basis_revision == bridge.submission.basis_revision ||
        return CommandBasisRevisionMismatch
    return _timing_rejection_reason(
        bridge.submission.timing_contract, submission.timing)
end

@inline function _boundary_reason_symbol(
    reason::PortRejectionReason)
    reason == DescriptorSchemaMismatch &&
        return :descriptor_schema_mismatch
    reason == CommandBasisMismatch && return :command_basis_mismatch
    reason == CommandBasisRevisionMismatch &&
        return :command_basis_revision_mismatch
    reason == CommandStreamSequenceNotIncreasing &&
        return :command_stream_sequence_not_increasing
    reason == CommandTimestampMismatch &&
        return :command_timestamp_mismatch
    reason == CoreAdmissionUnavailable &&
        return :core_admission_unavailable
    return :boundary_rejected # COV_EXCL_LINE
end

@inline function _boundary_lateness(timing::CommandTimingMetadata)
    requested = timing.requested_effective_timestamp
    receive = timing.receive_timestamp
    requested < receive || return zero(PlantDuration)
    return receive - requested
end

@inline function _boundary_command_outcome(
    descriptor::CommandSubmissionDescriptor{P},
    model_endpoint::CommandEndpointID,
    reason::PortRejectionReason,
    publication_execution_ns::Int64) where {P}
    submission = descriptor.submission
    return CommandOutcome(
        submission.session,
        submission.stream_sequence,
        submission.endpoint,
        model_endpoint,
        submission.command_sequence,
        submission.timing,
        submission.payload,
        BoundaryCommandOutcome,
        reason,
        _boundary_reason_symbol(reason),
        UInt64(0),
        UInt8(0),
        submission.timing.receive_timestamp,
        _boundary_lateness(submission.timing),
        UInt64(0),
        descriptor.outcome_credit,
        descriptor.ingress_execution_ns,
        publication_execution_ns)
end

@inline function _core_command_outcome(
    descriptor::CommandSubmissionDescriptor{P},
    disposition::PlantCommandDisposition,
    publication_execution_ns::Int64) where {P}
    superseding = superseding_command_presentation_id(disposition)
    superseding_value =
        isnothing(superseding) ? UInt64(0) : getfield(superseding, :value)
    return CommandOutcome(
        descriptor.submission.session,
        descriptor.submission.stream_sequence,
        descriptor.submission.endpoint,
        command_endpoint_id(disposition),
        descriptor.submission.command_sequence,
        descriptor.submission.timing,
        descriptor.submission.payload,
        CoreCommandOutcome,
        NoPortRejection,
        getfield(command_disposition_reason(disposition), :name),
        getfield(command_presentation_id(disposition), :value),
        UInt8(command_terminal_kind(disposition)),
        command_terminal_timestamp(disposition),
        command_lateness(disposition),
        superseding_value,
        descriptor.outcome_credit,
        descriptor.ingress_execution_ns,
        publication_execution_ns)
end

@inline function _publish_command_outcome!(
    completion::CommandCompletionPort,
    outcome::CommandOutcome)
    status = try_submit!(completion.ring, outcome)
    status == RingTransferSucceeded || throw(PortError(
        :command_completion, :credit_capacity_invariant,
        "reserved terminal-outcome credit did not guarantee completion capacity"))
    return nothing
end

function _insert_command_correlation!(
    state::CommandBridgeState{E,W,D},
    presentation::CommandPresentationID,
    descriptor::D) where {E,W,D}
    @inbounds for slot in eachindex(state.active)
        state.active[slot] && continue
        state.presentations[slot] = presentation
        state.descriptors[slot] = descriptor
        state.active[slot] = true
        state.active_count += 1
        return slot
    end
    # Reserved outcome credit makes this unreachable through the public port
    # path; retain the guard for corrupted state.
    # COV_EXCL_START
    throw(PortError(:command_bridge, :correlation_capacity,
        "terminal-outcome credit exists without correlation capacity"))
    # COV_EXCL_STOP
end

@inline function _command_correlation_slot(
    state::CommandBridgeState,
    presentation::CommandPresentationID)
    @inbounds for slot in eachindex(state.active)
        state.active[slot] || continue
        state.presentations[slot] == presentation && return slot
    end
    return 0
end

"""
Publish and clear every core terminal disposition currently owned by the
bridge workspace. Each publication consumes one previously reserved command
credit and removes exactly one correlation record.
"""
function publish_command_dispositions!(
    bridge::PreparedCommandBridge,
    state::CommandBridgeState,
    publication_execution_ns::Int64)
    workspace = state.disposition_workspace
    count = command_disposition_count(workspace)

    # Validate the whole batch before any publication so a missing correlation
    # cannot leave the caller with a partially consumed core workspace.
    @inbounds for index in 1:count
        disposition = command_disposition(workspace, index)
        slot = _command_correlation_slot(
            state, command_presentation_id(disposition))
        iszero(slot) && throw(PortError(
            :command_bridge, :missing_correlation,
            "core disposition has no transferred HIL command correlation"))
    end

    @inbounds for index in 1:count
        disposition = command_disposition(workspace, index)
        slot = _command_correlation_slot(
            state, command_presentation_id(disposition))
        descriptor = state.descriptors[slot]
        outcome = _core_command_outcome(
            descriptor, disposition, publication_execution_ns)
        _publish_command_outcome!(bridge.completion, outcome)
        state.active[slot] = false
        state.active_count -= 1
    end
    clear_command_dispositions!(workspace)
    return count
end

function _try_insert_failed_admission_correlation!(
    state::CommandBridgeState,
    descriptor::CommandSubmissionDescriptor)
    workspace = state.disposition_workspace
    count = command_disposition_count(workspace)
    @inbounds for index in count:-1:1
        disposition = command_disposition(workspace, index)
        command_endpoint_id(disposition) ==
            descriptor.submission.endpoint || continue
        command_sequence(disposition) ==
            descriptor.submission.command_sequence || continue
        _insert_command_correlation!(
            state, command_presentation_id(disposition), descriptor)
        return true
    end
    return false
end

"""
Consume at most one submitted command. Boundary incompatibility produces a
terminal boundary outcome. A compatible command is mapped to `PlantCommand`
and admitted at its canonical receive time; core terminal dispositions are
then wrapped and published without making HIL types dependencies of the core.
"""
function process_next_command!(
    bridge::PreparedCommandBridge,
    state::CommandBridgeState,
    publication_execution_ns::Int64)
    if command_disposition_count(state.disposition_workspace) != 0
        publish_command_dispositions!(
            bridge, state, publication_execution_ns)
    end
    result = try_take!(
        state.descriptor_scratch, bridge.submission)
    result.status == PortTransferSucceeded || return result
    descriptor = state.descriptor_scratch[]

    boundary_reason =
        _command_boundary_reason(bridge, state, descriptor)
    if boundary_reason != NoPortRejection
        outcome = _boundary_command_outcome(
            descriptor,
            bridge.submission.endpoint,
            boundary_reason,
            publication_execution_ns)
        _publish_command_outcome!(bridge.completion, outcome)
        return PortResult(PortTransferSucceeded)
    end

    submission = descriptor.submission
    payload = _consumer_submission_payload(
        bridge.submission, submission.payload)
    command = PlantCommand(
        submission.endpoint,
        submission.core_schema_id,
        submission.core_schema_version,
        submission.command_sequence,
        submission.timing.requested_effective_timestamp,
        payload)

    local admission::PlantCommandAdmission
    try
        admission = admit_plant_command!(
            state.disposition_workspace,
            bridge.endpoint,
            state.endpoint_state,
            command,
            submission.timing.receive_timestamp)
    catch
        has_core_outcome =
            _try_insert_failed_admission_correlation!(state, descriptor)
        if has_core_outcome
            publish_command_dispositions!(
                bridge, state, publication_execution_ns)
        else
            outcome = _boundary_command_outcome(
                descriptor,
                bridge.submission.endpoint,
                CoreAdmissionUnavailable,
                publication_execution_ns)
            _publish_command_outcome!(bridge.completion, outcome)
        end
        rethrow()
    end

    _insert_command_correlation!(
        state, command_presentation_id(admission), descriptor)
    publish_command_dispositions!(
        bridge, state, publication_execution_ns)
    return PortResult(PortTransferSucceeded)
end
