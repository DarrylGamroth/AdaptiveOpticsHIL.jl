"""Invalid port configuration, descriptor, or ownership transition."""
struct PortError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

struct _PositiveCounterToken end
const _POSITIVE_COUNTER_TOKEN = _PositiveCounterToken()

@inline function _checked_positive_uint64(
    value::Integer,
    component::Symbol,
    label::AbstractString)
    value > 0 || throw(PortError(component, :invalid_identity,
        "$label must be positive"))
    value <= typemax(UInt64) || throw(PortError(component, :invalid_identity,
        "$label exceeds UInt64 range"))
    return UInt64(value)
end

@inline _checked_positive_uint64(
    ::Bool,
    component::Symbol,
    label::AbstractString) =
    throw(PortError(component, :invalid_identity,
        "$label must be an integer count, not Bool"))

@inline function _checked_positive_uint32(
    value::Integer,
    component::Symbol,
    label::AbstractString)
    value > 0 || throw(PortError(component, :invalid_version,
        "$label must be positive"))
    value <= typemax(UInt32) || throw(PortError(component, :invalid_version,
        "$label exceeds UInt32 range"))
    return UInt32(value)
end

@inline _checked_positive_uint32(
    ::Bool,
    component::Symbol,
    label::AbstractString) =
    throw(PortError(component, :invalid_version,
        "$label must be an integer count, not Bool"))

"""Positive run-local epoch shared by every port and payload pool in a run."""
struct RunSessionID
    value::UInt64

    RunSessionID(value::UInt64, ::_PositiveCounterToken) = new(value)
end

RunSessionID(value::Integer) = RunSessionID(
    _checked_positive_uint64(value, :session, "run/session identity"),
    _POSITIVE_COUNTER_TOKEN)

"""Positive producer-assigned sequence within one session and one stream."""
struct StreamSequence
    value::UInt64

    StreamSequence(value::UInt64, ::_PositiveCounterToken) = new(value)
end

StreamSequence(value::Integer) = StreamSequence(
    _checked_positive_uint64(value, :stream, "stream sequence"),
    _POSITIVE_COUNTER_TOKEN)

"""Stable semantic identity of one HIL descriptor schema."""
struct PortSchemaID
    name::Symbol

    function PortSchemaID(name::Symbol)
        isempty(String(name)) && throw(PortError(
            :descriptor_schema, :empty_id,
            "port descriptor-schema identity must not be empty"))
        return new(name)
    end
end

"""Positive process-stable version of one HIL descriptor schema."""
struct PortSchemaVersion
    value::UInt32

    PortSchemaVersion(value::UInt32, ::_PositiveCounterToken) = new(value)
end

PortSchemaVersion(value::Integer) = PortSchemaVersion(
    _checked_positive_uint32(
        value, :descriptor_schema, "port descriptor-schema version"),
    _POSITIVE_COUNTER_TOKEN)

"""Stable identity of one external timestamp coordinate."""
struct ExternalTimestampDomainID
    name::Symbol

    function ExternalTimestampDomainID(name::Symbol)
        isempty(String(name)) && throw(PortError(
            :timestamp_domain, :empty_id,
            "external timestamp-domain identity must not be empty"))
        return new(name)
    end
end

"""Positive version of the mapping from an external domain into plant time."""
struct TimestampMappingVersion
    value::UInt32

    TimestampMappingVersion(value::UInt32, ::_PositiveCounterToken) =
        new(value)
end

TimestampMappingVersion(value::Integer) = TimestampMappingVersion(
    _checked_positive_uint32(
        value, :timestamp_mapping, "timestamp-mapping version"),
    _POSITIVE_COUNTER_TOKEN)

const _PortCounter = Union{
    RunSessionID,
    StreamSequence,
    PortSchemaVersion,
    TimestampMappingVersion,
}

Base.:(==)(left::T, right::T) where {T<:_PortCounter} =
    left.value == right.value
Base.isequal(left::T, right::T) where {T<:_PortCounter} =
    isequal(left.value, right.value)
Base.hash(value::T, seed::UInt) where {T<:_PortCounter} =
    hash(value.value, hash(T, seed))

Base.:(==)(left::PortSchemaID, right::PortSchemaID) =
    left.name == right.name
Base.isequal(left::PortSchemaID, right::PortSchemaID) =
    isequal(left.name, right.name)
Base.hash(value::PortSchemaID, seed::UInt) =
    hash(value.name, hash(PortSchemaID, seed))

Base.:(==)(left::ExternalTimestampDomainID,
    right::ExternalTimestampDomainID) = left.name == right.name
Base.isequal(left::ExternalTimestampDomainID,
    right::ExternalTimestampDomainID) = isequal(left.name, right.name)
Base.hash(value::ExternalTimestampDomainID, seed::UInt) =
    hash(value.name, hash(ExternalTimestampDomainID, seed))

function Base.show(io::IO, value::_PortCounter)
    print(io, nameof(typeof(value)), "(", value.value, ")")
end

function Base.show(io::IO, value::Union{
    PortSchemaID,ExternalTimestampDomainID})
    print(io, nameof(typeof(value)), "(", repr(value.name), ")")
end

"""Return the numeric run/session epoch."""
run_session_value(value::RunSessionID) = value.value

"""Return the numeric per-stream sequence."""
stream_sequence_value(value::StreamSequence) = value.value

"""Result category for a nonblocking port operation."""
@enum PortStatus::UInt8 begin
    PortTransferSucceeded = 0x01
    PortFull = 0x02
    PortEmpty = 0x03
    PortClosed = 0x04
    PortRejected = 0x05
end

"""Exact boundary reason for a rejected or unavailable port operation."""
@enum PortRejectionReason::UInt8 begin
    NoPortRejection = 0x00
    SessionMismatch = 0x01
    DescriptorSchemaMismatch = 0x02
    CommandBasisMismatch = 0x03
    CommandBasisRevisionMismatch = 0x04
    CommandStreamSequenceNotIncreasing = 0x05
    CommandTimestampMismatch = 0x06
    PayloadLeaseMismatch = 0x07
    OutcomeCreditUnavailable = 0x08
    AcquisitionMismatch = 0x09
    CoreAdmissionUnavailable = 0x0a
    CommandEndpointMismatch = 0x0b
end

"""
Nonallocating result of one port operation. `payload_status_code` is zero
unless an ownership check supplied a more specific `Ownership.PayloadStatus`.
"""
struct PortResult
    status::PortStatus
    reason::PortRejectionReason
    payload_status_code::UInt8
end

port_status(result::PortResult) = result.status
port_rejection_reason(result::PortResult) = result.reason

@inline PortResult(status::PortStatus) =
    PortResult(status, NoPortRejection, UInt8(0))

@inline PortResult(
    status::PortStatus,
    reason::PortRejectionReason) =
    PortResult(status, reason, UInt8(0))

@inline PortResult(
    status::PortStatus,
    reason::PortRejectionReason,
    payload_status::PayloadStatus) =
    PortResult(status, reason, UInt8(payload_status))

"""Return the specific payload status, or `nothing` when none was recorded."""
@inline function port_payload_status(result::PortResult)
    iszero(result.payload_status_code) && return nothing
    return PayloadStatus(result.payload_status_code)
end

@enum SourceTimestampKind::UInt8 begin
    ReceiveTimestampOnly = 0x01
    MappedSourceTimestamp = 0x02
end

const _NO_TIMESTAMP_DOMAIN =
    ExternalTimestampDomainID(:receive_timestamp_only)
const _NO_MAPPING_VERSION =
    TimestampMappingVersion(UInt32(0), _POSITIVE_COUNTER_TOKEN)

struct _CommandTimingToken end
const _COMMAND_TIMING_TOKEN = _CommandTimingToken()

"""
Canonical command timing after any external timestamp has already been mapped
onto the plant timeline. Mapping estimation remains user-integration work.
"""
struct CommandTimingMetadata
    source_kind::SourceTimestampKind
    source_domain::ExternalTimestampDomainID
    source_timestamp_ns::Int64
    mapping_version::TimestampMappingVersion
    mapped_source_timestamp::PlantTimestamp
    receive_timestamp::PlantTimestamp
    requested_effective_timestamp::PlantTimestamp
    mapping_uncertainty::PlantDuration

    function CommandTimingMetadata(
        ::_CommandTimingToken,
        source_kind::SourceTimestampKind,
        source_domain::ExternalTimestampDomainID,
        source_timestamp_ns::Int64,
        mapping_version::TimestampMappingVersion,
        mapped_source_timestamp::PlantTimestamp,
        receive_timestamp::PlantTimestamp,
        requested_effective_timestamp::PlantTimestamp,
        mapping_uncertainty::PlantDuration)
        return new(
            source_kind,
            source_domain,
            source_timestamp_ns,
            mapping_version,
            mapped_source_timestamp,
            receive_timestamp,
            requested_effective_timestamp,
            mapping_uncertainty)
    end
end

"""
    receive_time_command_timing(receive_timestamp;
        requested_effective_timestamp=receive_timestamp)

Declare a command without a trusted external source timestamp. Its mapped
arrival is its canonical plant receive time.
"""
function receive_time_command_timing(
    receive_timestamp::PlantTimestamp;
    requested_effective_timestamp::PlantTimestamp=receive_timestamp)
    return CommandTimingMetadata(
        _COMMAND_TIMING_TOKEN,
        ReceiveTimestampOnly,
        _NO_TIMESTAMP_DOMAIN,
        Int64(0),
        _NO_MAPPING_VERSION,
        receive_timestamp,
        receive_timestamp,
        requested_effective_timestamp,
        zero(PlantDuration))
end

"""
    mapped_source_command_timing(domain, source_timestamp_ns, mapping_version,
        mapped_source_timestamp, receive_timestamp;
        requested_effective_timestamp=mapped_source_timestamp,
        mapping_uncertainty=zero(PlantDuration))

Carry a user-supplied, versioned mapping of an external timestamp. A mapped
source instant may lead receive time only within the declared uncertainty.
"""
function mapped_source_command_timing(
    source_domain::ExternalTimestampDomainID,
    source_timestamp_ns::Int64,
    mapping_version::TimestampMappingVersion,
    mapped_source_timestamp::PlantTimestamp,
    receive_timestamp::PlantTimestamp;
    requested_effective_timestamp::PlantTimestamp=mapped_source_timestamp,
    mapping_uncertainty::PlantDuration=zero(PlantDuration))
    mapped_ns = Int128(plant_nanoseconds(mapped_source_timestamp))
    receive_ns = Int128(plant_nanoseconds(receive_timestamp))
    uncertainty_ns = Int128(plant_nanoseconds(mapping_uncertainty))
    mapped_ns <= receive_ns + uncertainty_ns || throw(PortError(
        :command_timing,
        :source_after_receive,
        "mapped source timestamp leads receive time by more than its declared uncertainty"))
    return CommandTimingMetadata(
        _COMMAND_TIMING_TOKEN,
        MappedSourceTimestamp,
        source_domain,
        source_timestamp_ns,
        mapping_version,
        mapped_source_timestamp,
        receive_timestamp,
        requested_effective_timestamp,
        mapping_uncertainty)
end

function mapped_source_command_timing(
    source_domain::ExternalTimestampDomainID,
    source_timestamp_ns::Integer,
    mapping_version::TimestampMappingVersion,
    mapped_source_timestamp::PlantTimestamp,
    receive_timestamp::PlantTimestamp;
    kwargs...)
    typemin(Int64) <= source_timestamp_ns <= typemax(Int64) ||
        throw(PortError(:command_timing, :source_timestamp_overflow,
            "external source timestamp exceeds Int64 range"))
    return mapped_source_command_timing(
        source_domain,
        Int64(source_timestamp_ns),
        mapping_version,
        mapped_source_timestamp,
        receive_timestamp;
        kwargs...)
end

mapped_source_command_timing(
    ::ExternalTimestampDomainID,
    ::Bool,
    ::TimestampMappingVersion,
    ::PlantTimestamp,
    ::PlantTimestamp;
    kwargs...) =
    throw(PortError(:command_timing, :invalid_source_timestamp,
        "external source timestamp must be an integer count, not Bool"))

source_timestamp_kind(timing::CommandTimingMetadata) = timing.source_kind

@inline function source_timestamp_domain(timing::CommandTimingMetadata)
    timing.source_kind == ReceiveTimestampOnly && return nothing
    return timing.source_domain
end

@inline function source_timestamp_nanoseconds(timing::CommandTimingMetadata)
    timing.source_kind == ReceiveTimestampOnly && return nothing
    return timing.source_timestamp_ns
end

@inline function timestamp_mapping_version(timing::CommandTimingMetadata)
    timing.source_kind == ReceiveTimestampOnly && return nothing
    return timing.mapping_version
end

mapped_source_timestamp(timing::CommandTimingMetadata) =
    timing.mapped_source_timestamp
command_receive_timestamp(timing::CommandTimingMetadata) =
    timing.receive_timestamp
command_effective_timestamp(timing::CommandTimingMetadata) =
    timing.requested_effective_timestamp
timestamp_mapping_uncertainty(timing::CommandTimingMetadata) =
    timing.mapping_uncertainty

abstract type AbstractCommandTimingContract end

"""Accept only commands timed from their canonical plant receive instant."""
struct ReceiveTimeTimingContract <: AbstractCommandTimingContract end

"""
Accept mapped source timestamps from one declared domain and no mapping version
older than `minimum_mapping_version`.
"""
struct MappedSourceTimingContract <: AbstractCommandTimingContract
    source_domain::ExternalTimestampDomainID
    minimum_mapping_version::TimestampMappingVersion
end

MappedSourceTimingContract(
    source_domain::ExternalTimestampDomainID;
    minimum_mapping_version::TimestampMappingVersion=
        TimestampMappingVersion(1)) =
    MappedSourceTimingContract(source_domain, minimum_mapping_version)

@inline function _timing_rejection_reason(
    ::ReceiveTimeTimingContract,
    timing::CommandTimingMetadata)
    timing.source_kind == ReceiveTimestampOnly ||
        return CommandTimestampMismatch
    timing.mapped_source_timestamp == timing.receive_timestamp ||
        return CommandTimestampMismatch
    return NoPortRejection
end

@inline function _timing_rejection_reason(
    contract::MappedSourceTimingContract,
    timing::CommandTimingMetadata)
    timing.source_kind == MappedSourceTimestamp ||
        return CommandTimestampMismatch
    timing.source_domain == contract.source_domain ||
        return CommandTimestampMismatch
    timing.mapping_version.value >= contract.minimum_mapping_version.value ||
        return CommandTimestampMismatch
    return NoPortRejection
end

"""Adapter availability reported to orchestration without transport semantics."""
@enum AdapterReadinessStatus::UInt8 begin
    AdapterNotReady = 0x01
    AdapterReady = 0x02
    AdapterFailed = 0x03
end

"""Run-time readiness observation on the canonical plant timeline."""
struct AdapterReadinessSnapshot
    status::AdapterReadinessStatus
    observed_timestamp::PlantTimestamp
end

adapter_readiness_status(snapshot::AdapterReadinessSnapshot) =
    snapshot.status
adapter_readiness_timestamp(snapshot::AdapterReadinessSnapshot) =
    snapshot.observed_timestamp

"""
Adapter-side delivery bounds consumed by orchestration. Lead time begins when a
complete product is published; maximum hold bounds the product lease.
"""
struct AdapterDeliveryContract
    complete_product_lead_time::PlantDuration
    maximum_lease_hold_time::PlantDuration

    function AdapterDeliveryContract(
        complete_product_lead_time::PlantDuration,
        maximum_lease_hold_time::PlantDuration)
        plant_nanoseconds(maximum_lease_hold_time) > 0 || throw(PortError(
            :adapter_delivery,
            :invalid_maximum_lease_hold,
            "maximum adapter lease-hold time must be positive"))
        return new(complete_product_lead_time, maximum_lease_hold_time)
    end
end

complete_product_lead_time(contract::AdapterDeliveryContract) =
    contract.complete_product_lead_time
maximum_lease_hold_time(contract::AdapterDeliveryContract) =
    contract.maximum_lease_hold_time
