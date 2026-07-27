"""Invalid port configuration, descriptor, or ownership transition."""
struct PortError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

"""
Dispatch policy for an exhausted bounded resource.

The policy is prepared, concrete, and resource-specific. It never introduces
an implicit retry queue.
"""
abstract type AbstractPortFullPolicy end

"""Return `full` without transferring or reclaiming producer ownership."""
struct RetainProducerOnFull <: AbstractPortFullPolicy end

"""
Drop the newest acquisition on `full`, reclaiming its producer lease when one
has already been claimed.
"""
struct DropNewestOnFull <: AbstractPortFullPolicy end

"""Treat `full` as a violated capacity proof rather than ordinary pressure."""
struct ReservedFullIsInvariant <: AbstractPortFullPolicy end

"""Prepared operational importance of one bounded runtime resource."""
abstract type AbstractResourceCriticality end

"""Capacity or deadline loss on this resource fails the run."""
struct RequiredResource <: AbstractResourceCriticality end

"""This resource may shed only when its prepared full policy permits loss."""
struct OptionalResource <: AbstractResourceCriticality end

@inline _checked_maximum_resource_lateness(::Nothing) = nothing

@inline function _checked_maximum_resource_lateness(
    value::Integer)
    0 <= value <= typemax(Int64) ||
        throw(PortError(
            :acquisition_overload_policy,
            :invalid_maximum_lateness,
            "maximum acquisition lateness must be a nonnegative Int64-compatible nanosecond count"))
    return Int64(value)
end

@inline _checked_maximum_resource_lateness(::Bool) =
    throw(PortError(
        :acquisition_overload_policy,
        :invalid_maximum_lateness,
        "maximum acquisition lateness must be an integer nanosecond count, not Bool"))

@inline function _checked_overload_recovery_occupancy(
    value::Integer)
    0 <= value <= typemax(Int) ||
        throw(PortError(
            :acquisition_overload_policy,
            :invalid_recovery_occupancy,
            "overload recovery occupancy must be a nonnegative addressable count"))
    return Int(value)
end

@inline _checked_overload_recovery_occupancy(::Bool) =
    throw(PortError(
        :acquisition_overload_policy,
        :invalid_recovery_occupancy,
        "overload recovery occupancy must be an integer count, not Bool"))

"""
Immutable overload contract for one acquisition completion path.

`maximum_lateness_ns === nothing` declares that no execution-clock publication
deadline applies. The recovery occupancy is validated against the prepared
port and product capacities.
"""
struct AcquisitionOverloadPolicy{
    C<:AbstractResourceCriticality,
    F<:AbstractPortFullPolicy,
}
    criticality::C
    full_policy::F
    maximum_lateness_ns::Union{Nothing,Int64}
    recovery_occupancy::Int

    function AcquisitionOverloadPolicy(
        criticality::C,
        full_policy::F;
        maximum_lateness_ns::Union{Nothing,Integer},
        recovery_occupancy::Integer) where {
        C<:AbstractResourceCriticality,
        F<:AbstractPortFullPolicy,
    }
        return new{C,F}(
            criticality,
            full_policy,
            _checked_maximum_resource_lateness(
                maximum_lateness_ns),
            _checked_overload_recovery_occupancy(
                recovery_occupancy))
    end
end

resource_criticality(policy::AcquisitionOverloadPolicy) =
    policy.criticality
resource_full_policy(policy::AcquisitionOverloadPolicy) =
    policy.full_policy
maximum_resource_lateness_ns(policy::AcquisitionOverloadPolicy) =
    policy.maximum_lateness_ns
overload_recovery_occupancy(policy::AcquisitionOverloadPolicy) =
    policy.recovery_occupancy

@inline resource_is_required(::RequiredResource) = true
@inline resource_is_required(::OptionalResource) = false
@inline resource_is_required(policy::AcquisitionOverloadPolicy) =
    resource_is_required(resource_criticality(policy))

# Public constructor tests cover both dispatch leaves, but coverage
# instrumentation cannot retain counters for these compile-time-inlined traits.
@inline _resource_capacity_is_bool(::Bool) = true # COV_EXCL_LINE
@inline _resource_capacity_is_bool(::Integer) = false # COV_EXCL_LINE

"""Prepared capacity and full-policy proof for one bounded port resource."""
struct PortResourcePolicy{F<:AbstractPortFullPolicy}
    capacity::Int
    maximum_outstanding::Int
    full_policy::F

    function PortResourcePolicy(
        capacity::Integer,
        maximum_outstanding::Integer,
        full_policy::F) where {F<:AbstractPortFullPolicy}
        (
            _resource_capacity_is_bool(capacity) ||
            _resource_capacity_is_bool(maximum_outstanding)
        ) &&
            throw(PortError(
                :port_resource_policy,
                :invalid_capacity,
                "bounded resource capacities must be integer counts, not Bool"))
        capacity > 0 || throw(PortError(
            :port_resource_policy,
            :invalid_capacity,
            "bounded resource capacity must be positive"))
        capacity <= typemax(Int) || throw(PortError(
            :port_resource_policy,
            :capacity_exceeds_address_space,
            "bounded resource capacity exceeds the addressable range"))
        0 <= maximum_outstanding <= capacity || throw(PortError(
            :port_resource_policy,
            :invalid_outstanding_bound,
            "maximum outstanding ownership must fit the bounded resource"))
        return new{F}(
            Int(capacity),
            Int(maximum_outstanding),
            full_policy)
    end
end

resource_capacity(policy::PortResourcePolicy) = policy.capacity
maximum_outstanding(policy::PortResourcePolicy) =
    policy.maximum_outstanding
resource_full_policy(policy::PortResourcePolicy) = policy.full_policy

"""
Cold lifecycle derived from a port's close flag and descriptor occupancy.

`PortDraining` and `PortDrained` are both closed to new producer transfer;
already published descriptors remain consumable in the draining state.
"""
@enum PortLifecycleState::UInt8 begin
    PortAccepting = 0x01
    PortDraining = 0x02
    PortDrained = 0x03
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

const _PortCounter = Union{
    StreamSequence,
    PortSchemaVersion,
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

function Base.show(io::IO, value::_PortCounter)
    print(io, nameof(typeof(value)), "(", value.value, ")")
end

function Base.show(io::IO, value::PortSchemaID)
    print(io, nameof(typeof(value)), "(", repr(value.name), ")")
end

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
    LeaseReturnUnavailable = 0x0c
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

struct _CommandTimingToken end
const _COMMAND_TIMING_TOKEN = _CommandTimingToken()

"""
Canonical command timing after the HIL timing boundary has mapped any external
timestamp onto the plant timeline. User integration supplies synchronization
observations; it does not supply an arbitrary mapped plant timestamp.
"""
struct CommandTimingMetadata
    source_kind::SourceTimestampKind
    source_domain::ExternalTimestampDomainID
    source_timestamp_ticks::Int64
    mapping_version::TimestampMappingVersion
    mapped_source_timestamp::PlantTimestamp
    receive_timestamp::PlantTimestamp
    requested_effective_timestamp::PlantTimestamp
    mapping_uncertainty::PlantDuration

    function CommandTimingMetadata(
        ::_CommandTimingToken,
        source_kind::SourceTimestampKind,
        source_domain::ExternalTimestampDomainID,
        source_timestamp_ticks::Int64,
        mapping_version::TimestampMappingVersion,
        mapped_source_timestamp::PlantTimestamp,
        receive_timestamp::PlantTimestamp,
        requested_effective_timestamp::PlantTimestamp,
        mapping_uncertainty::PlantDuration)
        return new(
            source_kind,
            source_domain,
            source_timestamp_ticks,
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
        _NO_EXTERNAL_TIMESTAMP_DOMAIN,
        Int64(0),
        _NO_TIMESTAMP_MAPPING_VERSION,
        receive_timestamp,
        receive_timestamp,
        requested_effective_timestamp,
        zero(PlantDuration))
end

"""
    mapped_source_command_timing(mapped, receive_timestamp;
        requested_effective_timestamp=mapped_plant_timestamp(mapped))

Carry the exact result of a HIL-owned, versioned external timestamp mapping. A
mapped source instant may lead receive time only within the mapping's declared
uncertainty.
"""
function mapped_source_command_timing(
    mapped::MappedExternalTimestamp,
    receive_timestamp::PlantTimestamp;
    requested_effective_timestamp::PlantTimestamp=
        mapped_plant_timestamp(mapped))
    mapped_source_timestamp = mapped_plant_timestamp(mapped)
    mapping_uncertainty = timestamp_mapping_uncertainty(mapped)
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
        external_timestamp_domain(mapped),
        source_timestamp_ticks(mapped),
        timestamp_mapping_version(mapped),
        mapped_source_timestamp,
        receive_timestamp,
        requested_effective_timestamp,
        mapping_uncertainty)
end

source_timestamp_kind(timing::CommandTimingMetadata) = timing.source_kind

@inline function source_timestamp_domain(timing::CommandTimingMetadata)
    timing.source_kind == ReceiveTimestampOnly && return nothing
    return timing.source_domain
end

@inline function source_timestamp_ticks(timing::CommandTimingMetadata)
    timing.source_kind == ReceiveTimestampOnly && return nothing
    return timing.source_timestamp_ticks
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
    timing.mapping_version >= contract.minimum_mapping_version ||
        return CommandTimestampMismatch
    return NoPortRejection
end

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
