"""
    Ports

Transport-neutral command submission/outcome and complete-acquisition
boundaries. Ports compose bounded ownership primitives with canonical
`AdaptiveOpticsSim.Plant` identities; they define no wire protocol, socket,
client/server role, worker, or polling policy.
"""
module Ports

using AdaptiveOpticsSim: IntensityMap, WFSMeasurement, WFSObservation
using AdaptiveOpticsSim: backend, intensity_values
using AdaptiveOpticsSim: measurement_storage, observation_storage
using AdaptiveOpticsSim.Plant: AcquisitionID
using AdaptiveOpticsSim.Plant: AcquisitionProductContract
using AdaptiveOpticsSim.Plant: AcquisitionProducts
using AdaptiveOpticsSim.Plant: CommandBasis, CommandBasisRevision
using AdaptiveOpticsSim.Plant: CommandDispositionReason
using AdaptiveOpticsSim.Plant: CommandEndpointID, CommandEndpointState
using AdaptiveOpticsSim.Plant: CommandDispositionWorkspace
using AdaptiveOpticsSim.Plant: CommandPresentationID, CommandTerminalKind
using AdaptiveOpticsSim.Plant: PlantCommand, PlantCommandAdmission
using AdaptiveOpticsSim.Plant: PlantCommandDisposition
using AdaptiveOpticsSim.Plant: PlantCommandSchemaID
using AdaptiveOpticsSim.Plant: PlantCommandSchemaVersion
using AdaptiveOpticsSim.Plant: PlantCommandSequence
using AdaptiveOpticsSim.Plant: PlantDuration, PlantTimestamp
using AdaptiveOpticsSim.Plant: PreparedCommandEndpoint
using AdaptiveOpticsSim.Plant: admit_plant_command!
using AdaptiveOpticsSim.Plant: clear_command_dispositions!
using AdaptiveOpticsSim.Plant: command_basis, command_basis_revision
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
using AdaptiveOpticsSim.Plant: plant_nanoseconds
using AdaptiveOpticsSim.Plant: superseding_command_presentation_id
using AdaptiveOpticsSim.Plant: validate_acquisition_product_contract
import AdaptiveOpticsSim.Plant: acquisition_product_contract

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError
using ..Ownership: PayloadGenerationExhausted, PayloadLeaseRef
using ..Ownership: PayloadPool, PayloadPoolExhausted, PayloadStatus
using ..Ownership: PayloadTransitionSucceeded
using ..Ownership: WrongPayloadSession
using ..Ownership: RingClosed, RingEmpty, RingFull, RingStatus
using ..Ownership: RingTransferSucceeded, SPSCDescriptorRing
using ..Ownership: abort_payload!, consumer_payload, lease_payload!
using ..Ownership: payload_pool_accounting, payload_pool_capacity
using ..Ownership: payload_pool_id, payload_session_id, producer_payload
using ..Ownership: queue_payload!, release_payload!, try_claim_payload!
import ..Ownership: _lease_state_status, _producer_submission_status
import ..Ownership: _PAYLOAD_CONSUMER_LEASED, _PAYLOAD_PRODUCER_OWNED
import ..Ownership: try_submit!, try_take!

include("ports/contracts.jl")
include("ports/command.jl")
include("ports/acquisition.jl")

export PortError
export RunSessionID, StreamSequence, PortSchemaID, PortSchemaVersion
export ExternalTimestampDomainID, TimestampMappingVersion
export run_session_value, stream_sequence_value
export PortStatus, PortTransferSucceeded, PortFull, PortEmpty, PortClosed
export PortRejected, PortRejectionReason, NoPortRejection
export SessionMismatch, DescriptorSchemaMismatch, CommandBasisMismatch
export CommandBasisRevisionMismatch, CommandStreamSequenceNotIncreasing
export CommandTimestampMismatch, PayloadLeaseMismatch
export OutcomeCreditUnavailable, AcquisitionMismatch
export CoreAdmissionUnavailable
export CommandEndpointMismatch
export PortResult, port_status, port_rejection_reason, port_payload_status
export PayloadLeaseRef, PayloadStatus
export PayloadTransitionSucceeded, PayloadPoolExhausted
export SourceTimestampKind, ReceiveTimestampOnly, MappedSourceTimestamp
export CommandTimingMetadata, receive_time_command_timing
export mapped_source_command_timing
export source_timestamp_kind, source_timestamp_domain
export source_timestamp_nanoseconds, timestamp_mapping_version
export mapped_source_timestamp, command_receive_timestamp
export command_effective_timestamp, timestamp_mapping_uncertainty
export AbstractCommandTimingContract, ReceiveTimeTimingContract
export MappedSourceTimingContract
export AdapterReadinessStatus, AdapterNotReady, AdapterReady, AdapterFailed
export AdapterReadinessSnapshot, AdapterDeliveryContract
export adapter_readiness_status, adapter_readiness_timestamp
export complete_product_lead_time, maximum_lease_hold_time

export InlineCommandPayload, LeasedCommandPayload, CommandSubmission
export CommandSubmissionPort, CommandCompletionPort, PreparedCommandPorts
export prepare_command_ports, matching_command_submission
export try_claim_command_payload!, producer_command_payload
export abort_command_payload!, command_payload_accounting
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
export PreparedCommandBridge, CommandBridgeState
export prepare_command_bridge, command_endpoint_state
export command_disposition_workspace, process_next_command!
export publish_command_dispositions!, active_command_correlations
export command_submission_port, command_completion_port
export try_submit!, try_take!

export AcquisitionCompletion, AcquisitionCompletionPort
export prepare_acquisition_completion_port, matching_acquisition_completion
export acquisition_completion_session, acquisition_completion_sequence
export acquisition_completion_id, acquisition_completion_timestamp
export acquisition_completion_readiness
export acquisition_completion_publication_ns
export try_claim_product!, producer_product, abort_product!, completed_product
export try_publish!, release_product!, acquisition_product_accounting
export acquisition_delivery_contract, acquisition_product_contract

public CommandSubmissionDescriptor

end
