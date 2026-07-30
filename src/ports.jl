"""
    Ports

Transport-neutral command submission/outcome and complete-acquisition
boundaries. Ports compose bounded ownership primitives with canonical
`AdaptiveOpticsSim.Plant` identities; they define no wire protocol, socket,
client/server role, worker, or polling policy.
"""
module Ports

using AdaptiveOpticsSim.Backends: backend
using AdaptiveOpticsSim.Optics: IntensityMap, intensity_values
using AdaptiveOpticsSim.WavefrontSensors: WFSMeasurement, WFSObservation
using AdaptiveOpticsSim.WavefrontSensors: measurement_storage
using AdaptiveOpticsSim.WavefrontSensors: observation_storage
using AdaptiveOpticsSim.Plant: AcquisitionID
using AdaptiveOpticsSim.Plant: AcquisitionProductContract
using AdaptiveOpticsSim.Plant: AcquisitionProducts
using AdaptiveOpticsSim.Plant: CommandBasis, CommandBasisRevision
using AdaptiveOpticsSim.Plant: CommandDispositionReason
using AdaptiveOpticsSim.Plant: CommandEndpointID, CommandEndpointState
using AdaptiveOpticsSim.Plant: CommandDispositionWorkspace
using AdaptiveOpticsSim.Plant: CommandPresentationID, CommandTerminalKind
using AdaptiveOpticsSim.Plant: PlantEventLoopState
using AdaptiveOpticsSim.Plant: PlantEventLoopWorkspace
using AdaptiveOpticsSim.Plant: PlantCommand, PlantCommandAdmission
using AdaptiveOpticsSim.Plant: PlantCommandDisposition
using AdaptiveOpticsSim.Plant: CommandAdmittedPending, CommandAdmittedReady
using AdaptiveOpticsSim.Plant: CommandTerminatedOnAdmission
using AdaptiveOpticsSim.Plant: PlantCommandSchemaID
using AdaptiveOpticsSim.Plant: PlantCommandSchemaVersion
using AdaptiveOpticsSim.Plant: PlantCommandSequence
using AdaptiveOpticsSim.Plant: PlantDuration, PlantTimestamp
using AdaptiveOpticsSim.Plant: PreparedCommandEndpoint
using AdaptiveOpticsSim.Plant: PreparedPlantEventLoop
using AdaptiveOpticsSim.Plant: admit_plant_command!
using AdaptiveOpticsSim.Plant: clear_command_dispositions!
using AdaptiveOpticsSim.Plant: command_basis, command_basis_revision
using AdaptiveOpticsSim.Plant: command_admission_status
using AdaptiveOpticsSim.Plant: command_dimensions
using AdaptiveOpticsSim.Plant: command_disposition
using AdaptiveOpticsSim.Plant: command_disposition_count
using AdaptiveOpticsSim.Plant: command_disposition_reason
using AdaptiveOpticsSim.Plant: command_endpoint_id
using AdaptiveOpticsSim.Plant: command_lateness
using AdaptiveOpticsSim.Plant: command_numeric_type
using AdaptiveOpticsSim.Plant: command_presentation_id
using AdaptiveOpticsSim.Plant: command_requested_effective_timestamp
using AdaptiveOpticsSim.Plant: command_schema
using AdaptiveOpticsSim.Plant: command_schema_id, command_schema_version
using AdaptiveOpticsSim.Plant: command_sequence
using AdaptiveOpticsSim.Plant: command_terminal_kind
using AdaptiveOpticsSim.Plant: command_terminal_timestamp
using AdaptiveOpticsSim.Plant: effective_command
using AdaptiveOpticsSim.Plant: fail_pending_plant_commands!
using AdaptiveOpticsSim.Plant: plant_nanoseconds
using AdaptiveOpticsSim.Plant: superseding_command_presentation_id
using AdaptiveOpticsSim.Plant: validate_acquisition_product_contract
import AdaptiveOpticsSim.Plant: acquisition_product_contract

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError
using ..Lifecycle: RunSessionID, run_session_value
using ..Timing: ExternalTimestampDomainID, MappedExternalTimestamp
using ..Timing: TimestampMappingVersion
using ..Timing: _NO_EXTERNAL_TIMESTAMP_DOMAIN
using ..Timing: _NO_TIMESTAMP_MAPPING_VERSION
using ..Timing: external_timestamp_domain, mapped_plant_timestamp
import ..Timing: source_timestamp_ticks, timestamp_mapping_uncertainty
import ..Timing: timestamp_mapping_version
using ..Ownership: PayloadLeaseRef
using ..Ownership: PayloadPool, PayloadPoolExhausted, PayloadStatus
using ..Ownership: PayloadPoolDeficit
using ..Ownership: PayloadPoolAlreadyClosed, PayloadPoolCloseStatus
using ..Ownership: PayloadPoolCloseSucceeded
using ..Ownership: PayloadPoolAccepting, PayloadPoolClosed
using ..Ownership: PayloadPoolDrained, PayloadPoolDraining
using ..Ownership: PayloadPoolLifecycleState
using ..Ownership: PayloadReturnCreditUnavailable
using ..Ownership: PayloadReturnPathClosed
using ..Ownership: PayloadTransitionSucceeded
using ..Ownership: RingAccounting, WrongPayloadSession
using ..Ownership: RingClosed, RingEmpty, RingFull, RingStatus
using ..Ownership: RingTransferSucceeded, SPSCDescriptorRing
using ..Ownership: abort_payload!, consumer_payload, lease_payload!
using ..Ownership: close_payload_pool!, close_payload_returns!, close_ring!
using ..Ownership: payload_pool_accounting, payload_pool_capacity
using ..Ownership: payload_pool_capacity_contract, payload_return_accounting
using ..Ownership: payload_pool_deficit
using ..Ownership: payload_pool_lifecycle_state
using ..Ownership: producer_payload
using ..Ownership: queue_payload!, reclaim_payload_returns!
using ..Ownership: release_payload!, ring_accounting, ring_capacity
using ..Ownership: ring_is_closed
using ..Ownership: try_claim_payload!
import ..Ownership: _lease_state_status, _payload_return_status
import ..Ownership: _producer_submission_status, _publish_payload_return!
import ..Ownership: _PAYLOAD_PRODUCER_OWNED
import ..Ownership: try_peek!, try_submit!, try_take!

include("ports/contracts.jl")
include("ports/command.jl")
include("ports/acquisition.jl")

"""
Return a point-in-time accounting snapshot for a port's bounded descriptor
ring. The snapshot is allocation-free and does not transfer ownership.
"""
descriptor_accounting(port::Union{
    CommandSubmissionPort,
    CommandCompletionPort,
    AcquisitionCompletionPort,
})::RingAccounting = ring_accounting(port.ring)

"""Return the cold accepting/draining/drained lifecycle of a port."""
function port_lifecycle_state(port::Union{
    CommandSubmissionPort,
    CommandCompletionPort,
    AcquisitionCompletionPort,
})
    accounting = descriptor_accounting(port)
    accounting.closed || return PortAccepting
    iszero(accounting.occupancy) && return PortDrained
    return PortDraining
end

@inline function _require_drained_completion(
    port::Union{CommandCompletionPort,AcquisitionCompletionPort},
    component::Symbol)
    accounting = descriptor_accounting(port)
    accounting.closed || throw(PortError(
        component,
        :completion_still_accepting,
        "completion publication must close before its lease-return path"))
    iszero(accounting.occupancy) || throw(PortError(
        component,
        :completion_not_drained,
        "completion descriptors must drain before the lease-return path closes"))
    return nothing
end

@inline function _return_lifecycle_state(pool::PayloadPool)
    accounting = payload_return_accounting(pool)
    accounting.closed || return PortAccepting
    iszero(accounting.occupancy) && return PortDrained
    return PortDraining
end

@inline function _payload_resource_policy(pool::PayloadPool)
    capacity = payload_pool_capacity(pool)
    return PortResourcePolicy(
        capacity,
        capacity,
        RetainProducerOnFull())
end

@inline function _lease_return_policy(pool::PayloadPool)
    contract = payload_pool_capacity_contract(pool)
    return PortResourcePolicy(
        contract.return_capacity,
        contract.maximum_consumer_leases,
        ReservedFullIsInvariant())
end

@inline _optional_payload_policy(::Nothing) = nothing # COV_EXCL_LINE
@inline _optional_payload_policy(pool::PayloadPool) =
    _payload_resource_policy(pool)

@inline _optional_payload_lifecycle(::Nothing) = nothing
@inline _optional_payload_lifecycle(pool::PayloadPool) =
    payload_pool_lifecycle_state(pool)

@inline _optional_lease_return_policy(::Nothing) = nothing # COV_EXCL_LINE
@inline _optional_lease_return_policy(pool::PayloadPool) =
    _lease_return_policy(pool)

@inline _optional_return_lifecycle(::Nothing) = nothing
@inline _optional_return_lifecycle(pool::PayloadPool) = # COV_EXCL_LINE
    _return_lifecycle_state(pool)

@inline _optional_payload_deficit(::Nothing) = nothing # COV_EXCL_LINE
@inline _optional_payload_deficit(pool::PayloadPool) =
    payload_pool_deficit(pool)

"""Return the prepared payload-slot capacity and full policy for `port`."""
function payload_resource_policy(port::AcquisitionCompletionPort)
    capacity = payload_pool_capacity(port.product_pool)
    return PortResourcePolicy(
        capacity,
        capacity,
        port.overload_policy.full_policy)
end

"""Return the cold claim lifecycle for each payload pool owned by `port`."""
payload_lifecycle_state(port::AcquisitionCompletionPort) =
    payload_pool_lifecycle_state(port.product_pool)

"""Return the reserved lease-return capacity policy for `port`."""
lease_return_policy(port::AcquisitionCompletionPort) =
    _lease_return_policy(port.product_pool)

"""Return the cold accepting/draining/drained lease-return lifecycle."""
lease_return_lifecycle_state(port::AcquisitionCompletionPort) =
    _return_lifecycle_state(port.product_pool)

"""
Return bounded cold deficit accounting for each payload pool. Interpret it as
a shutdown deficit only after publication and bounded drain have ended.
"""
payload_ownership_deficit(port::AcquisitionCompletionPort) =
    payload_pool_deficit(port.product_pool)

function payload_resource_policy(port::Union{
    CommandSubmissionPort,
    CommandCompletionPort,
})
    return (
        payload=_optional_payload_policy(port.payload_pool),
        outcome_credit=
            _payload_resource_policy(port.outcome_credit_pool))
end

function payload_lifecycle_state(port::Union{
    CommandSubmissionPort,
    CommandCompletionPort,
})
    return (
        payload=_optional_payload_lifecycle(port.payload_pool),
        outcome_credit=
            payload_pool_lifecycle_state(port.outcome_credit_pool))
end

function lease_return_policy(port::Union{
    CommandSubmissionPort,
    CommandCompletionPort,
})
    return (
        payload=_optional_lease_return_policy(port.payload_pool),
        outcome_credit=_lease_return_policy(port.outcome_credit_pool))
end

function lease_return_lifecycle_state(port::Union{
    CommandSubmissionPort,
    CommandCompletionPort,
})
    return (
        payload=_optional_return_lifecycle(port.payload_pool),
        outcome_credit=
            _return_lifecycle_state(port.outcome_credit_pool))
end

function payload_ownership_deficit(port::Union{
    CommandSubmissionPort,
    CommandCompletionPort,
})
    return (
        payload=_optional_payload_deficit(port.payload_pool),
        outcome_credit=payload_pool_deficit(port.outcome_credit_pool))
end

export PortError
export StreamSequence, PortSchemaID, PortSchemaVersion
export stream_sequence_value
export PortStatus, PortTransferSucceeded, PortFull, PortEmpty, PortClosed
export PortRejected, PortRejectionReason, NoPortRejection
export SessionMismatch, DescriptorSchemaMismatch, CommandBasisMismatch
export CommandBasisRevisionMismatch, CommandStreamSequenceNotIncreasing
export CommandTimestampMismatch, PayloadLeaseMismatch
export OutcomeCreditUnavailable, AcquisitionMismatch
export CoreAdmissionUnavailable
export CommandEndpointMismatch
export LeaseReturnUnavailable
export RunNotAccepting
export PortResult, port_status, port_rejection_reason, port_payload_status
export AbstractPortFullPolicy, RetainProducerOnFull, DropNewestOnFull
export ReservedFullIsInvariant, PortResourcePolicy
export resource_capacity, maximum_outstanding, resource_full_policy
export AbstractResourceCriticality, RequiredResource, OptionalResource
export AcquisitionOverloadPolicy, resource_criticality
export maximum_resource_lateness_ns, overload_recovery_occupancy
export resource_is_required
export PortLifecycleState, PortAccepting, PortDraining, PortDrained
export port_lifecycle_state, port_resource_policy
export payload_resource_policy, lease_return_policy
export payload_lifecycle_state, lease_return_lifecycle_state
export payload_ownership_deficit
export PayloadLeaseRef, PayloadStatus
export PayloadTransitionSucceeded, PayloadPoolExhausted
export PayloadPoolClosed, PayloadPoolLifecycleState
export PayloadPoolAccepting, PayloadPoolDraining, PayloadPoolDrained
export PayloadPoolDeficit
export PayloadReturnCreditUnavailable, PayloadReturnPathClosed
export SourceTimestampKind, ReceiveTimestampOnly, MappedSourceTimestamp
export CommandTimingMetadata, receive_time_command_timing
export mapped_source_command_timing
export source_timestamp_kind, source_timestamp_domain
export source_timestamp_ticks, timestamp_mapping_version
export mapped_source_timestamp, command_receive_timestamp
export command_effective_timestamp, timestamp_mapping_uncertainty
export AbstractCommandTimingContract, ReceiveTimeTimingContract
export MappedSourceTimingContract
export AdapterDeliveryContract
export complete_product_lead_time, maximum_lease_hold_time

export InlineCommandPayload, LeasedCommandPayload, CommandSubmission
export CommandSubmissionPort, CommandCompletionPort, PreparedCommandPorts
export prepare_command_ports, matching_command_submission
export close_command_ingress!, close_command_completion!
export close_command_return_paths!
export try_claim_command_payload!, producer_command_payload
export abort_command_payload!, command_payload_accounting
export reclaim_command_payload_returns!, reclaim_outcome_credit_returns!
export submission_session, submission_stream_sequence
export submission_endpoint, submission_schema_id, submission_schema_version
export submission_command_sequence, submission_timing, submission_payload
export CommandOutcomeStage, BoundaryCommandOutcome, CoreCommandOutcome
export CommandOutcome, outcome_stage, outcome_boundary_reason, outcome_reason
export outcome_session, outcome_stream_sequence, outcome_endpoint
export outcome_model_endpoint
export outcome_command_sequence, outcome_presentation_id
export outcome_timing, outcome_ingress_execution_ns
export outcome_publication_execution_ns
export outcome_terminal_kind, outcome_terminal_timestamp
export outcome_requested_effective_timestamp, outcome_lateness
export outcome_superseding_presentation_id, outcome_payload
export release_outcome!, outcome_credit_accounting
export PreparedCommandBridge, CommandBridgeState, CommandBridgeWorkspace
export prepare_command_bridge, command_endpoint_state
export CommandProcessingStage, CommandNotProcessed, CommandBoundaryRejected
export CommandTerminatedDuringAdmission, CommandSemanticallyAdmitted
export CommandProcessingResult, command_processing_port_result
export command_processing_stage, command_processing_endpoint
export command_processing_presentation
export command_disposition_workspace, process_next_command!
export publish_command_dispositions!, active_command_correlations
export fail_pending_bridge_commands!
export reject_pending_bridge_commands!
export plant_event_loop_state, plant_event_loop_workspace
export command_submission_port, command_completion_port
export descriptor_accounting
export try_submit!, try_take!

export AcquisitionCompletion, AcquisitionCompletionPort
export prepare_acquisition_completion_port, matching_acquisition_completion
export close_acquisition_completion!, close_acquisition_return_path!
export acquisition_completion_session, acquisition_completion_sequence
export acquisition_completion_id, acquisition_completion_timestamp
export acquisition_completion_publication_ns
export try_claim_product!, producer_product, abort_product!, completed_product
export try_publish!, release_product!, acquisition_product_accounting
export reclaim_product_returns!
export acquisition_delivery_contract, acquisition_product_contract
export acquisition_overload_policy

public CommandSubmissionDescriptor
public command_bridge_event_loop
public pending_command_receive_timestamp

end
