"""Invalid external timestamp-domain identity, mapping, or lookup."""
struct TimestampMappingError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

struct _TimestampMappingToken end
const _TIMESTAMP_MAPPING_TOKEN = _TimestampMappingToken()

@inline function _checked_timestamp_uint32(value::Integer,
    component::Symbol, label::String)
    0 < value <= typemax(UInt32) || throw(TimestampMappingError(
        component,
        :invalid_version,
        "$label must be a positive UInt32-compatible integer"))
    return UInt32(value)
end

@inline _checked_timestamp_uint32(::Bool, component::Symbol, label::String) =
    throw(TimestampMappingError(
        component,
        :invalid_version,
        "$label must be an integer count, not Bool"))

@inline function _checked_external_timestamp(value::Integer,
    component::Symbol, label::String)
    typemin(Int64) <= value <= typemax(Int64) ||
        throw(TimestampMappingError(
            component,
            :source_timestamp_overflow,
            "$label exceeds the signed Int64 source-coordinate range"))
    return Int64(value)
end

@inline _checked_external_timestamp(::Bool, component::Symbol, label::String) =
    throw(TimestampMappingError(
        component,
        :invalid_source_timestamp,
        "$label must be an integer count, not Bool"))

@inline function _checked_positive_timestamp_integer(value::Integer,
    component::Symbol, label::String)
    0 < value <= typemax(Int64) || throw(TimestampMappingError(
        component,
        :invalid_rate,
        "$label must be a positive Int64-compatible integer"))
    return Int64(value)
end

@inline _checked_positive_timestamp_integer(
    ::Bool, component::Symbol, label::String) =
    throw(TimestampMappingError(
        component,
        :invalid_rate,
        "$label must be an integer count, not Bool"))

@inline function _checked_mapping_capacity(value::Integer)
    0 < value <= typemax(Int) || throw(TimestampMappingError(
        :timestamp_mapping_registry,
        :invalid_capacity,
        "timestamp-mapping registry capacity must be a positive addressable integer"))
    return Int(value)
end

@inline _checked_mapping_capacity(::Bool) = throw(TimestampMappingError(
    :timestamp_mapping_registry,
    :invalid_capacity,
    "timestamp-mapping registry capacity must be an integer count, not Bool"))

"""Stable identity of one external RTC, camera, or device timestamp domain."""
struct ExternalTimestampDomainID
    name::Symbol

    function ExternalTimestampDomainID(name::Symbol)
        isempty(String(name)) && throw(TimestampMappingError(
            :timestamp_domain,
            :empty_id,
            "external timestamp-domain identity must not be empty"))
        return new(name)
    end
end

"""Positive version of one mapping from an external domain into plant time."""
struct TimestampMappingVersion
    value::UInt32

    TimestampMappingVersion(value::UInt32, ::_TimestampMappingToken) =
        new(value)
end

TimestampMappingVersion(value::Integer) = TimestampMappingVersion(
    _checked_timestamp_uint32(
        value, :timestamp_mapping, "timestamp-mapping version"),
    _TIMESTAMP_MAPPING_TOKEN)

# Storage-only sentinels keep receive-time command metadata inline. Public
# timing accessors return `nothing`; a zero mapping version never leaves them.
const _NO_EXTERNAL_TIMESTAMP_DOMAIN =
    ExternalTimestampDomainID(:receive_timestamp_only)
const _NO_TIMESTAMP_MAPPING_VERSION =
    TimestampMappingVersion(UInt32(0), _TIMESTAMP_MAPPING_TOKEN)

"""Stable logical owner of prospective timestamp-mapping publication."""
struct TimestampMappingOwnerID
    name::Symbol

    function TimestampMappingOwnerID(name::Symbol)
        isempty(String(name)) && throw(TimestampMappingError(
            :timestamp_mapping_owner,
            :empty_id,
            "timestamp-mapping owner identity must not be empty"))
        return new(name)
    end
end

const _TimestampSymbolID =
    Union{ExternalTimestampDomainID,TimestampMappingOwnerID}

Base.:(==)(left::T, right::T) where {T<:_TimestampSymbolID} =
    left.name == right.name
Base.isequal(left::T, right::T) where {T<:_TimestampSymbolID} =
    isequal(left.name, right.name)
Base.hash(value::T, seed::UInt) where {T<:_TimestampSymbolID} =
    hash(value.name, hash(T, seed))

Base.:(==)(left::TimestampMappingVersion,
    right::TimestampMappingVersion) = left.value == right.value
Base.isequal(left::TimestampMappingVersion,
    right::TimestampMappingVersion) = isequal(left.value, right.value)
Base.hash(value::TimestampMappingVersion, seed::UInt) =
    hash(value.value, hash(TimestampMappingVersion, seed))
Base.isless(left::TimestampMappingVersion,
    right::TimestampMappingVersion) = isless(left.value, right.value)
Base.:(<)(left::TimestampMappingVersion,
    right::TimestampMappingVersion) = left.value < right.value
Base.:(<=)(left::TimestampMappingVersion,
    right::TimestampMappingVersion) = left.value <= right.value

function Base.show(io::IO, value::_TimestampSymbolID)
    print(io, nameof(typeof(value)), "(", repr(value.name), ")")
end

function Base.show(io::IO, value::TimestampMappingVersion)
    print(io, "TimestampMappingVersion(", value.value, ")")
end

"""
    ExternalTimestampMapping(domain, version, source_anchor_ticks, plant_anchor;
        rate_numerator=1, rate_denominator=1,
        uncertainty=zero(PlantDuration),
        valid_from_ticks, valid_through_ticks)

Immutable, versioned affine mapping from one external timestamp coordinate into
canonical plant nanoseconds:

```text
plant = plant_anchor +
    round((source - source_anchor) * rate_numerator / rate_denominator)
```

Rounding is nearest with ties to even. The positive reduced rational rate is
plant nanoseconds per source tick, incorporating both nominal tick scale and
constant fractional frequency offset. Time-varying drift requires a later
mapping version. The inclusive source validity interval and both of its mapped
endpoints must be representable.
"""
struct ExternalTimestampMapping
    domain::ExternalTimestampDomainID
    version::TimestampMappingVersion
    source_anchor_ticks::Int64
    plant_anchor::PlantTimestamp
    rate_numerator::Int64
    rate_denominator::Int64
    uncertainty::PlantDuration
    valid_from_ticks::Int64
    valid_through_ticks::Int64

    function ExternalTimestampMapping(
        domain::ExternalTimestampDomainID,
        version::TimestampMappingVersion,
        source_anchor_ticks::Int64,
        plant_anchor::PlantTimestamp,
        rate_numerator::Int64,
        rate_denominator::Int64,
        uncertainty::PlantDuration,
        valid_from_ticks::Int64,
        valid_through_ticks::Int64,
        ::_TimestampMappingToken)
        return new(
            domain,
            version,
            source_anchor_ticks,
            plant_anchor,
            rate_numerator,
            rate_denominator,
            uncertainty,
            valid_from_ticks,
            valid_through_ticks)
    end
end

function ExternalTimestampMapping(
    domain::ExternalTimestampDomainID,
    version::TimestampMappingVersion,
    source_anchor_ticks::Integer,
    plant_anchor::PlantTimestamp;
    rate_numerator::Integer=1,
    rate_denominator::Integer=1,
    uncertainty::PlantDuration=zero(PlantDuration),
    valid_from_ticks::Integer,
    valid_through_ticks::Integer)
    anchor = _checked_external_timestamp(
        source_anchor_ticks, :timestamp_mapping, "source anchor")
    valid_from = _checked_external_timestamp(
        valid_from_ticks, :timestamp_mapping, "valid-from timestamp")
    valid_through = _checked_external_timestamp(
        valid_through_ticks, :timestamp_mapping, "valid-through timestamp")
    valid_from <= anchor <= valid_through || throw(TimestampMappingError(
        :timestamp_mapping,
        :invalid_validity_interval,
        "source anchor must lie inside the inclusive mapping validity interval"))
    numerator = _checked_positive_timestamp_integer(
        rate_numerator, :timestamp_mapping, "timestamp rate numerator")
    denominator = _checked_positive_timestamp_integer(
        rate_denominator, :timestamp_mapping, "timestamp rate denominator")
    divisor = gcd(numerator, denominator)
    numerator = div(numerator, divisor)
    denominator = div(denominator, divisor)
    mapping = ExternalTimestampMapping(
        domain,
        version,
        anchor,
        plant_anchor,
        numerator,
        denominator,
        uncertainty,
        valid_from,
        valid_through,
        _TIMESTAMP_MAPPING_TOKEN)
    _mapped_plant_nanoseconds(mapping, valid_from)
    _mapped_plant_nanoseconds(mapping, valid_through)
    return mapping
end

@inline function _mapped_plant_nanoseconds(
    mapping::ExternalTimestampMapping,
    source_timestamp_ticks::Int64)
    # Promoting before subtraction bounds |delta| by 2^64 - 1. Multiplication
    # by a validated positive Int64 rate numerator therefore remains in Int128.
    delta =
        Int128(source_timestamp_ticks) - Int128(mapping.source_anchor_ticks)
    unit_rate =
        mapping.rate_numerator == 1 && mapping.rate_denominator == 1
    rounded = if unit_rate
        delta
    else
        scaled = delta * Int128(mapping.rate_numerator)
        div(scaled, Int128(mapping.rate_denominator), RoundNearest)
    end
    mapped = Int128(plant_nanoseconds(mapping.plant_anchor)) + rounded
    0 <= mapped <= typemax(Int64) || throw(TimestampMappingError(
        :timestamp_mapping,
        :plant_timestamp_overflow,
        "external timestamp maps outside the representable plant timeline"))
    return Int64(mapped)
end

struct _MappedExternalTimestampToken end
const _MAPPED_EXTERNAL_TIMESTAMP_TOKEN = _MappedExternalTimestampToken()

"""
Exact, immutable result of applying one mapping version to one external source
timestamp. Construction is restricted to [`map_external_timestamp`](@ref).
"""
struct MappedExternalTimestamp
    domain::ExternalTimestampDomainID
    source_timestamp_ticks::Int64
    mapping_version::TimestampMappingVersion
    plant_timestamp::PlantTimestamp
    uncertainty::PlantDuration

    function MappedExternalTimestamp(
        domain::ExternalTimestampDomainID,
        source_timestamp_ticks::Int64,
        mapping_version::TimestampMappingVersion,
        plant_timestamp::PlantTimestamp,
        uncertainty::PlantDuration,
        ::_MappedExternalTimestampToken)
        return new(
            domain,
            source_timestamp_ticks,
            mapping_version,
            plant_timestamp,
            uncertainty)
    end
end

"""
    map_external_timestamp(mapping, source_timestamp_ticks)

Apply `mapping` with checked exact arithmetic. The source timestamp must lie in
the mapping's inclusive validity interval.
"""
@inline function map_external_timestamp(
    mapping::ExternalTimestampMapping,
    source_timestamp_ticks::Int64)
    mapping.valid_from_ticks <= source_timestamp_ticks <=
        mapping.valid_through_ticks || throw(TimestampMappingError(
        :timestamp_mapping,
        :outside_validity_interval,
        "external timestamp lies outside the mapping validity interval"))
    mapped_ns = _mapped_plant_nanoseconds(mapping, source_timestamp_ticks)
    return MappedExternalTimestamp(
        mapping.domain,
        source_timestamp_ticks,
        mapping.version,
        PlantTimestamp(mapped_ns),
        mapping.uncertainty,
        _MAPPED_EXTERNAL_TIMESTAMP_TOKEN)
end

@inline function map_external_timestamp(
    mapping::ExternalTimestampMapping,
    source_timestamp_ticks::Integer)
    source = _checked_external_timestamp(
        source_timestamp_ticks, :timestamp_mapping, "external source timestamp")
    return map_external_timestamp(mapping, source)
end

"""
Fixed-capacity, append-only publication registry. One logical owner installs
immutable mappings; readers acquire a published count and never observe a
partially initialized record.
"""
mutable struct PreparedTimestampMappings
    const mappings::Memory{ExternalTimestampMapping}
    const owner::TimestampMappingOwnerID
    @atomic published_count::Int
end

function prepare_timestamp_mappings(
    capacity::Integer;
    owner::TimestampMappingOwnerID=
        TimestampMappingOwnerID(:timestamp_mapping_owner))
    checked_capacity = _checked_mapping_capacity(capacity)
    mappings = Memory{ExternalTimestampMapping}(undef, checked_capacity)
    return PreparedTimestampMappings(mappings, owner, 0)
end

@inline timestamp_mapping_capacity(registry::PreparedTimestampMappings) =
    length(registry.mappings)

@inline timestamp_mapping_owner(registry::PreparedTimestampMappings) =
    registry.owner

@inline timestamp_mapping_count(registry::PreparedTimestampMappings) =
    @atomic :acquire registry.published_count

function install_timestamp_mapping!(
    registry::PreparedTimestampMappings,
    owner::TimestampMappingOwnerID,
    mapping::ExternalTimestampMapping)
    owner == registry.owner || throw(TimestampMappingError(
        :timestamp_mapping_registry,
        :wrong_owner,
        "only the prepared timestamp-mapping owner may publish a mapping"))
    count = @atomic :acquire registry.published_count
    count < length(registry.mappings) || throw(TimestampMappingError(
        :timestamp_mapping_registry,
        :capacity_exhausted,
        "timestamp-mapping registry capacity is exhausted"))
    for index in count:-1:1
        installed = @inbounds registry.mappings[index]
        installed.domain == mapping.domain || continue
        mapping.version > installed.version ||
            throw(TimestampMappingError(
                :timestamp_mapping_registry,
                :nonincreasing_version,
                "a prospective mapping version must exceed every " *
                "installed version for its domain"))
        break
    end
    @inbounds registry.mappings[count + 1] = mapping
    @atomic :release registry.published_count = count + 1
    return mapping
end

@inline function timestamp_mapping_at(
    registry::PreparedTimestampMappings,
    index::Integer)
    count = timestamp_mapping_count(registry)
    1 <= index <= count || throw(TimestampMappingError(
        :timestamp_mapping_registry,
        :invalid_index,
        "timestamp-mapping metadata index is outside the published range"))
    return @inbounds registry.mappings[Int(index)]
end

timestamp_mapping_at(::PreparedTimestampMappings, ::Bool) =
    throw(TimestampMappingError(
        :timestamp_mapping_registry,
        :invalid_index,
        "timestamp-mapping metadata index must be an integer count, not Bool"))

function timestamp_mapping(
    registry::PreparedTimestampMappings,
    domain::ExternalTimestampDomainID,
    version::TimestampMappingVersion)
    count = timestamp_mapping_count(registry)
    found_domain = false
    for index in count:-1:1
        mapping = @inbounds registry.mappings[index]
        mapping.domain == domain || continue
        found_domain = true
        mapping.version == version && return mapping
    end
    reason = found_domain ? :unknown_version : :unknown_domain
    message = found_domain ?
        "timestamp-mapping version is not installed for the requested domain" :
        "external timestamp domain is not installed"
    throw(TimestampMappingError(
        :timestamp_mapping_registry, reason, message))
end

function latest_timestamp_mapping(
    registry::PreparedTimestampMappings,
    domain::ExternalTimestampDomainID)
    count = timestamp_mapping_count(registry)
    for index in count:-1:1
        mapping = @inbounds registry.mappings[index]
        mapping.domain == domain && return mapping
    end
    throw(TimestampMappingError(
        :timestamp_mapping_registry,
        :unknown_domain,
        "external timestamp domain is not installed"))
end

@inline function map_external_timestamp(
    registry::PreparedTimestampMappings,
    domain::ExternalTimestampDomainID,
    version::TimestampMappingVersion,
    source_timestamp_ticks::Integer)
    mapping = timestamp_mapping(registry, domain, version)
    return map_external_timestamp(mapping, source_timestamp_ticks)
end

@inline function map_external_timestamp(
    registry::PreparedTimestampMappings,
    domain::ExternalTimestampDomainID,
    source_timestamp_ticks::Integer)
    mapping = latest_timestamp_mapping(registry, domain)
    return map_external_timestamp(mapping, source_timestamp_ticks)
end

external_timestamp_domain(mapping::ExternalTimestampMapping) = mapping.domain
external_timestamp_domain(mapped::MappedExternalTimestamp) = mapped.domain
timestamp_mapping_version(mapping::ExternalTimestampMapping) = mapping.version
timestamp_mapping_version(mapped::MappedExternalTimestamp) =
    mapped.mapping_version
source_timestamp_ticks(mapped::MappedExternalTimestamp) =
    mapped.source_timestamp_ticks
mapped_plant_timestamp(mapped::MappedExternalTimestamp) =
    mapped.plant_timestamp
timestamp_mapping_uncertainty(mapping::ExternalTimestampMapping) =
    mapping.uncertainty
timestamp_mapping_uncertainty(mapped::MappedExternalTimestamp) =
    mapped.uncertainty
source_anchor_ticks(mapping::ExternalTimestampMapping) =
    mapping.source_anchor_ticks
plant_anchor_timestamp(mapping::ExternalTimestampMapping) =
    mapping.plant_anchor
timestamp_rate_numerator(mapping::ExternalTimestampMapping) =
    mapping.rate_numerator
timestamp_rate_denominator(mapping::ExternalTimestampMapping) =
    mapping.rate_denominator
timestamp_valid_from_ticks(mapping::ExternalTimestampMapping) =
    mapping.valid_from_ticks
timestamp_valid_through_ticks(mapping::ExternalTimestampMapping) =
    mapping.valid_through_ticks
