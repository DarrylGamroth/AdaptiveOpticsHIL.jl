"""
    Placement

Immutable, transport-neutral input values for static HIL execution-resource
placement. This namespace records caller-supplied inventory, capability,
estimate, handoff, constraint, preference, and explicit-assignment facts. It
does not discover hardware, select a plan, allocate transfer storage, bind an
Agent owner, or change run lifecycle state.
"""
module Placement

using AdaptiveOpticsSim.Plant: OpticalPathID

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError
using ..Ports: AbstractResourceCriticality

export PlacementError
export ExecutionResourceID, MemoryDomainID, ReservedContextID
export PlacementFactVersion, FactProvenance
export AbstractMemoryBytes, KnownMemoryBytes, UnknownMemoryBytes
export memory_bytes
export AbstractNUMANodeFact, NUMANodeID, UnknownNUMANode
export CPUWorkerFacts, AcceleratorContextID, AcceleratorExecutionFacts
export AbstractExecutionResourceKind, CPUExecutionResource
export AcceleratorExecutionResource, ExecutionResource
export execution_resource_id, execution_resource_kind, execution_resource_device
export execution_resource_memory_domain, execution_resource_facts
export AbstractCapabilityAvailability, CapabilitySupported, CapabilityUnsupported
export CapabilityUnknown, TargetCapability, CapabilitySnapshot
export capability_name, capability_availability, capability_provenance
export MemoryDomain, memory_domain_id, memory_domain_owner
export memory_domain_capacity, memory_domain_headroom
export ReservedCoordinationContext, reserved_context_id, reserved_context_resource
export ResourceInventory, resource_inventory_resources, resource_inventory_contexts
export resource_inventory_capability_provenance
export AbstractPlacementSubject, PathGroupSubject, AtmosphereAuthoritySubject
export CommandAuthoritySubject, AcquisitionOutputSubject
export placement_subject_path
export ResourceEstimate, resource_estimate_subject, resource_estimate_resource
export resource_estimate_provenance, resident_memory_bytes, workspace_memory_bytes
export total_estimated_memory_bytes
export AbstractHandoffFact, AtmospherePathInputHandoff
export CommandReplicaHandoff, AcquisitionOutputHandoff
export handoff_subject, handoff_payload_bytes, handoff_maximum_in_flight
export handoff_provenance
export PlacementFacts, placement_inventory, placement_estimates, placement_handoffs
export placement_estimate_provenance, placement_handoff_provenance
export AbstractAcquisitionOutputDisposition, DeviceReadyOutput
export ConsumerOutput, output_subject, output_criticality
export output_consumer_resource, output_consumer_memory_domain
export AbstractHardConstraint, RequireExecutionResource, RequireMemoryDomain
export RequireCapability
export AbstractPlacementPreference, PreferExecutionResource
export ExplicitPlacementAssignment
export placement_subject, assigned_execution_resource
export PlacementPolicyValues, hard_constraints, placement_preferences
export explicit_assignments, acquisition_output_dispositions
export PlacementInputs, placement_facts, placement_policy_values

"""Invalid static-placement inventory or policy input."""
struct PlacementError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

@inline _is_bool(::Bool) = true # COV_EXCL_LINE
@inline _is_bool(::Integer) = false # COV_EXCL_LINE

@inline function _checked_positive_uint32(value::Integer, component::Symbol,
    label::AbstractString)
    _is_bool(value) && throw(PlacementError(
        component, :invalid_version, "$label must be an integer, not Bool"))
    0 < value <= typemax(UInt32) || throw(PlacementError(
        component, :invalid_version,
        "$label must be a positive UInt32-compatible integer"))
    return UInt32(value)
end

@inline function _checked_nonnegative_uint64(value::Integer, component::Symbol,
    label::AbstractString)
    _is_bool(value) && throw(PlacementError(
        component, :invalid_memory_bytes, "$label must be an integer, not Bool"))
    0 <= value <= typemax(UInt64) || throw(PlacementError(
        component, :invalid_memory_bytes,
        "$label must be a nonnegative UInt64-compatible byte count"))
    return UInt64(value)
end

@inline function _checked_positive_int(value::Integer, component::Symbol,
    label::AbstractString)
    _is_bool(value) && throw(PlacementError(
        component, :invalid_count, "$label must be an integer, not Bool"))
    0 < value <= typemax(Int) || throw(PlacementError(
        component, :invalid_count,
        "$label must be a positive addressable count"))
    return Int(value)
end

@inline function _checked_nonnegative_int(value::Integer, component::Symbol,
    label::AbstractString)
    _is_bool(value) && throw(PlacementError(
        component, :invalid_count, "$label must be an integer, not Bool"))
    0 <= value <= typemax(Int) || throw(PlacementError(
        component, :invalid_count,
        "$label must be a nonnegative addressable count"))
    return Int(value)
end

@inline function _require_name(name::Symbol, component::Symbol,
    label::AbstractString)
    isempty(String(name)) && throw(PlacementError(
        component, :empty_identity, "$label must not be empty"))
    return name
end

"""Stable declared identity of one HIL execution resource."""
struct ExecutionResourceID
    name::Symbol

    function ExecutionResourceID(name::Symbol)
        return new(_require_name(name, :execution_resource, "execution-resource identity"))
    end
end

"""Stable declared identity of one inventory memory domain."""
struct MemoryDomainID
    name::Symbol

    function MemoryDomainID(name::Symbol)
        return new(_require_name(name, :memory_domain, "memory-domain identity"))
    end
end

"""Stable declared identity of one reserved HIL coordination context."""
struct ReservedContextID
    name::Symbol

    function ReservedContextID(name::Symbol)
        return new(_require_name(name, :reserved_context, "reserved-context identity"))
    end
end

const _PlacementSymbolID = Union{ExecutionResourceID,MemoryDomainID,ReservedContextID}

Base.:(==)(left::T, right::T) where {T<:_PlacementSymbolID} = left.name == right.name
Base.isequal(left::T, right::T) where {T<:_PlacementSymbolID} = isequal(left.name, right.name)
Base.hash(value::T, seed::UInt) where {T<:_PlacementSymbolID} =
    hash(value.name, hash(T, seed))
Base.isless(left::T, right::T) where {T<:_PlacementSymbolID} =
    isless(String(left.name), String(right.name))

function Base.show(io::IO, value::_PlacementSymbolID)
    print(io, nameof(typeof(value)), "(", repr(value.name), ")")
end

"""Positive version of one caller-supplied placement fact procedure."""
struct PlacementFactVersion
    value::UInt32

    PlacementFactVersion(value::UInt32) = new(value)
end

PlacementFactVersion(value::Integer) = PlacementFactVersion(
    _checked_positive_uint32(value, :placement_fact, "placement-fact version"))

Base.:(==)(left::PlacementFactVersion, right::PlacementFactVersion) =
    left.value == right.value
Base.isequal(left::PlacementFactVersion, right::PlacementFactVersion) =
    isequal(left.value, right.value)
Base.hash(value::PlacementFactVersion, seed::UInt) =
    hash(value.value, hash(PlacementFactVersion, seed))
Base.isless(left::PlacementFactVersion, right::PlacementFactVersion) =
    isless(left.value, right.value)

function Base.show(io::IO, value::PlacementFactVersion)
    print(io, "PlacementFactVersion(", value.value, ")")
end

"""Immutable source identity and version of one placement-fact snapshot."""
struct FactProvenance
    source::Symbol
    version::PlacementFactVersion

    function FactProvenance(source::Symbol, version::PlacementFactVersion)
        return new(_require_name(source, :fact_provenance, "fact-provenance source"),
            version)
    end
end

FactProvenance(source::Symbol, version::Integer) =
    FactProvenance(source, PlacementFactVersion(version))

Base.:(==)(left::FactProvenance, right::FactProvenance) =
    left.source == right.source && left.version == right.version
Base.isequal(left::FactProvenance, right::FactProvenance) =
    isequal(left.source, right.source) && isequal(left.version, right.version)
Base.hash(value::FactProvenance, seed::UInt) =
    hash(value.version, hash(value.source, hash(FactProvenance, seed)))
Base.isless(left::FactProvenance, right::FactProvenance) =
    isless((String(left.source), left.version.value),
        (String(right.source), right.version.value))

"""Explicit known-or-unknown byte quantity; unknown is never zero bytes."""
abstract type AbstractMemoryBytes end

struct KnownMemoryBytes <: AbstractMemoryBytes
    value::UInt64

    KnownMemoryBytes(value::UInt64) = new(value)
end

KnownMemoryBytes(value::Integer) = KnownMemoryBytes(
    _checked_nonnegative_uint64(value, :memory_bytes, "memory byte count"))

"""A byte quantity that has not been measured or derived by the caller."""
struct UnknownMemoryBytes <: AbstractMemoryBytes end

memory_bytes(value::KnownMemoryBytes) = value.value
memory_bytes(::UnknownMemoryBytes) = nothing

Base.:(==)(left::KnownMemoryBytes, right::KnownMemoryBytes) = left.value == right.value
Base.isequal(left::KnownMemoryBytes, right::KnownMemoryBytes) = isequal(left.value, right.value)
Base.hash(value::KnownMemoryBytes, seed::UInt) = hash(value.value, hash(KnownMemoryBytes, seed))
Base.:(==)(::UnknownMemoryBytes, ::UnknownMemoryBytes) = true
Base.isequal(::UnknownMemoryBytes, ::UnknownMemoryBytes) = true
Base.hash(::UnknownMemoryBytes, seed::UInt) = hash(UnknownMemoryBytes, seed)

@inline function _sum_memory_bytes(left::KnownMemoryBytes, right::KnownMemoryBytes,
    component::Symbol)
    left.value <= typemax(UInt64) - right.value || throw(PlacementError(
        component, :memory_arithmetic_overflow,
        "memory-byte arithmetic exceeds UInt64 range"))
    return KnownMemoryBytes(left.value + right.value)
end

@inline _sum_memory_bytes(::AbstractMemoryBytes, ::AbstractMemoryBytes,
    ::Symbol) = UnknownMemoryBytes()

"""One supplied or explicitly unknown NUMA-node fact."""
abstract type AbstractNUMANodeFact end

"""A supplied NUMA node identity for one CPU execution resource."""
struct NUMANodeID <: AbstractNUMANodeFact
    value::UInt64

    NUMANodeID(value::UInt64) = new(value)
end

NUMANodeID(value::Integer) = NUMANodeID(
    _checked_nonnegative_uint64(value, :numa_node, "NUMA-node identity"))

"""Explicit absence of an observed NUMA-node assignment."""
struct UnknownNUMANode <: AbstractNUMANodeFact end

Base.:(==)(left::NUMANodeID, right::NUMANodeID) = left.value == right.value
Base.isequal(left::NUMANodeID, right::NUMANodeID) = isequal(left.value, right.value)
Base.hash(value::NUMANodeID, seed::UInt) = hash(value.value, hash(NUMANodeID, seed))
Base.:(==)(::UnknownNUMANode, ::UnknownNUMANode) = true
Base.isequal(::UnknownNUMANode, ::UnknownNUMANode) = true
Base.hash(::UnknownNUMANode, seed::UInt) = hash(UnknownNUMANode, seed)

"""Caller-supplied CPU worker count and NUMA-node fact for one resource."""
struct CPUWorkerFacts{N<:AbstractNUMANodeFact}
    worker_count::Int
    numa_node::N

    function CPUWorkerFacts(worker_count::Integer,
        numa_node::N=UnknownNUMANode()) where {N<:AbstractNUMANodeFact}
        return new{N}(_checked_positive_int(
            worker_count, :cpu_worker_facts, "CPU worker count"), numa_node)
    end
end

"""Stable identity of the prepared accelerator context admitted to a resource."""
struct AcceleratorContextID
    name::Symbol

    function AcceleratorContextID(name::Symbol)
        return new(_require_name(name, :accelerator_context,
            "accelerator-context identity"))
    end
end

Base.:(==)(left::AcceleratorContextID, right::AcceleratorContextID) =
    left.name == right.name
Base.isequal(left::AcceleratorContextID, right::AcceleratorContextID) =
    isequal(left.name, right.name)
Base.hash(value::AcceleratorContextID, seed::UInt) =
    hash(value.name, hash(AcceleratorContextID, seed))
Base.isless(left::AcceleratorContextID, right::AcceleratorContextID) =
    isless(String(left.name), String(right.name))

"""Caller-supplied prepared accelerator-context fact for one resource."""
struct AcceleratorExecutionFacts
    context::AcceleratorContextID
end

"""Resource class used only to state CPU versus accelerator placement facts."""
abstract type AbstractExecutionResourceKind end

"""A CPU execution resource with supplied CPU-worker and NUMA facts."""
struct CPUExecutionResource <: AbstractExecutionResourceKind end

"""One accelerator execution resource; Gate 9A admits at most one."""
struct AcceleratorExecutionResource <: AbstractExecutionResourceKind end

"""Explicit availability status for one named target capability."""
abstract type AbstractCapabilityAvailability end

struct CapabilitySupported <: AbstractCapabilityAvailability end
struct CapabilityUnsupported <: AbstractCapabilityAvailability end
struct CapabilityUnknown <: AbstractCapabilityAvailability end

"""One named capability result in a versioned target-capability snapshot."""
struct TargetCapability{A<:AbstractCapabilityAvailability}
    name::Symbol
    availability::A

    function TargetCapability(name::Symbol, availability::A) where {
        A<:AbstractCapabilityAvailability,
    }
        return new{A}(_require_name(name, :target_capability,
            "target-capability name"), availability)
    end
end

capability_name(capability::TargetCapability) = capability.name
capability_availability(capability::TargetCapability) = capability.availability

@inline _capability_key(capability::TargetCapability) = String(capability.name)

"""Defensively snapshotted, versioned capability values for one target."""
struct CapabilitySnapshot
    provenance::FactProvenance
    capabilities::Tuple
end

capability_provenance(snapshot::CapabilitySnapshot) = snapshot.provenance

@inline _is_target_capability(::TargetCapability) = true
@inline _is_target_capability(::Any) = false

function _canonical_capabilities(capabilities)
    snapshot = collect(capabilities)
    all(_is_target_capability, snapshot) || throw(PlacementError(
        :target_capabilities, :invalid_capability,
        "capability snapshots must contain TargetCapability values"))
    sort!(snapshot; by=_capability_key)
    for index in 2:length(snapshot)
        _capability_key(snapshot[index - 1]) == _capability_key(snapshot[index]) &&
            throw(PlacementError(:target_capabilities, :duplicate_capability,
                "a capability snapshot cannot contain duplicate capability names"))
    end
    return Tuple(snapshot)
end

CapabilitySnapshot(provenance::FactProvenance, capabilities) =
    CapabilitySnapshot(provenance, _canonical_capabilities(capabilities))

"""One memory domain owned by exactly one execution resource."""
struct MemoryDomain{C<:AbstractMemoryBytes,H<:AbstractMemoryBytes}
    id::MemoryDomainID
    owner::ExecutionResourceID
    capacity::C
    headroom::H

    function MemoryDomain(id::MemoryDomainID, owner::ExecutionResourceID,
        capacity::C, headroom::H) where {
        C<:AbstractMemoryBytes,H<:AbstractMemoryBytes,
    }
        _validate_memory_domain_capacity(capacity, headroom)
        return new{C,H}(id, owner, capacity, headroom)
    end
end

@inline _validate_memory_domain_capacity(::AbstractMemoryBytes,
    ::AbstractMemoryBytes) = nothing

@inline function _validate_memory_domain_capacity(capacity::KnownMemoryBytes,
    headroom::KnownMemoryBytes)
    headroom.value <= capacity.value || throw(PlacementError(
        :memory_domain, :headroom_exceeds_capacity,
        "memory-domain headroom cannot exceed capacity"))
    return nothing
end

memory_domain_id(domain::MemoryDomain) = domain.id
memory_domain_owner(domain::MemoryDomain) = domain.owner
memory_domain_capacity(domain::MemoryDomain) = domain.capacity
memory_domain_headroom(domain::MemoryDomain) = domain.headroom

"""One reserved coordination context assigned to an execution resource."""
struct ReservedCoordinationContext
    id::ReservedContextID
    resource::ExecutionResourceID
end

reserved_context_id(context::ReservedCoordinationContext) = context.id
reserved_context_resource(context::ReservedCoordinationContext) = context.resource

"""One immutable execution-resource record in the placement inventory."""
struct ExecutionResource{
    K<:AbstractExecutionResourceKind,
    D,
    F,
}
    id::ExecutionResourceID
    kind::K
    device::D
    memory_domain::MemoryDomain
    facts::F
    capabilities::CapabilitySnapshot

    function ExecutionResource(id::ExecutionResourceID, kind::K, device::D,
        memory_domain::MemoryDomain, facts::F,
        capabilities::CapabilitySnapshot) where {
        K<:AbstractExecutionResourceKind,D,F,
    }
        _validate_device_identity(device)
        _validate_execution_resource_facts(kind, facts)
        memory_domain.owner == id || throw(PlacementError(
            :execution_resource, :inconsistent_memory_domain_owner,
            "an execution resource must own its declared memory domain"))
        return new{K,D,F}(id, kind, device, memory_domain, facts, capabilities)
    end
end

@inline _validate_device_identity(::Symbol) = nothing
@inline function _validate_device_identity(device)
    isimmutable(device) || throw(PlacementError(
        :execution_resource, :mutable_compute_device,
        "execution-resource device identities must be immutable values"))
    return nothing
end

@inline _validate_execution_resource_facts(::CPUExecutionResource,
    ::CPUWorkerFacts) = nothing
@inline _validate_execution_resource_facts(::AcceleratorExecutionResource,
    ::AcceleratorExecutionFacts) = nothing
@inline _validate_execution_resource_facts(::AbstractExecutionResourceKind,
    ::Any) = throw(PlacementError(:execution_resource, :invalid_resource_facts,
        "resource facts do not match the declared execution-resource kind"))

execution_resource_id(resource::ExecutionResource) = resource.id
execution_resource_kind(resource::ExecutionResource) = resource.kind
execution_resource_device(resource::ExecutionResource) = resource.device
execution_resource_memory_domain(resource::ExecutionResource) = resource.memory_domain
execution_resource_facts(resource::ExecutionResource) = resource.facts
capability_provenance(resource::ExecutionResource) =
    capability_provenance(resource.capabilities)

@inline _accelerator_resource_count(::CPUExecutionResource) = 0
@inline _accelerator_resource_count(::AcceleratorExecutionResource) = 1

@inline _is_execution_resource(::ExecutionResource) = true
@inline _is_execution_resource(::Any) = false
@inline _is_reserved_context(::ReservedCoordinationContext) = true
@inline _is_reserved_context(::Any) = false

function _canonical_resources(resources)
    snapshot = collect(resources)
    all(_is_execution_resource, snapshot) || throw(PlacementError(
        :resource_inventory, :invalid_resource,
        "resource inventories must contain ExecutionResource values"))
    isempty(snapshot) && throw(PlacementError(
        :resource_inventory, :empty_inventory,
        "a resource inventory must contain at least one execution resource"))
    sort!(snapshot; by=execution_resource_id)
    accelerator_count = 0
    memory_domain_ids = Set{MemoryDomainID}()
    for index in eachindex(snapshot)
        resource = snapshot[index]
        accelerator_count += _accelerator_resource_count(resource.kind)
        accelerator_count <= 1 || throw(PlacementError(
            :resource_inventory, :too_many_accelerators,
            "Gate 9A inventories admit at most one accelerator resource"))
        domain_id = memory_domain_id(execution_resource_memory_domain(resource))
        domain_id in memory_domain_ids && throw(PlacementError(
            :resource_inventory, :duplicate_memory_domain,
            "a memory domain cannot be owned by more than one resource"))
        push!(memory_domain_ids, domain_id)
        index == firstindex(snapshot) && continue
        execution_resource_id(snapshot[index - 1]) == execution_resource_id(resource) &&
            throw(PlacementError(:resource_inventory, :duplicate_resource,
                "a resource inventory cannot contain duplicate resource identities"))
    end
    return Tuple(snapshot)
end

function _common_capability_provenance(resources::Tuple)
    provenance = capability_provenance(first(resources))
    all(resource -> capability_provenance(resource) == provenance, resources) ||
        throw(PlacementError(:resource_inventory, :inconsistent_capability_provenance,
            "all resource capabilities must use one exact provenance and version"))
    return provenance
end

function _canonical_contexts(contexts, resources::Tuple)
    snapshot = collect(contexts)
    all(_is_reserved_context, snapshot) || throw(PlacementError(
        :resource_inventory, :invalid_reserved_context,
        "reserved coordination contexts must use ReservedCoordinationContext values"))
    resource_ids = Set(execution_resource_id(resource) for resource in resources)
    all(context -> reserved_context_resource(context) in resource_ids, snapshot) ||
        throw(PlacementError(:resource_inventory, :unknown_context_resource,
            "each reserved coordination context must refer to an inventory resource"))
    sort!(snapshot; by=reserved_context_id)
    for index in 2:length(snapshot)
        reserved_context_id(snapshot[index - 1]) == reserved_context_id(snapshot[index]) &&
            throw(PlacementError(:resource_inventory, :duplicate_reserved_context,
                "a resource inventory cannot contain duplicate reserved-context identities"))
    end
    return Tuple(snapshot)
end

"""Immutable, canonically ordered Gate 9A execution-resource inventory."""
struct ResourceInventory
    resources::Tuple
    contexts::Tuple
    capability_provenance::FactProvenance
end

function ResourceInventory(resources, contexts=())
    canonical_resources = _canonical_resources(resources)
    canonical_contexts = _canonical_contexts(contexts, canonical_resources)
    return ResourceInventory(canonical_resources, canonical_contexts,
        _common_capability_provenance(canonical_resources))
end

resource_inventory_resources(inventory::ResourceInventory) = inventory.resources
resource_inventory_contexts(inventory::ResourceInventory) = inventory.contexts
resource_inventory_capability_provenance(inventory::ResourceInventory) =
    inventory.capability_provenance

"""One placement subject; subject values do not resolve a resource."""
abstract type AbstractPlacementSubject end

"""The complete path and acquisition group identified by one optical path."""
struct PathGroupSubject <: AbstractPlacementSubject
    path::OpticalPathID
end

"""The unique atmosphere-authority placement subject in one Gate 9A plant."""
struct AtmosphereAuthoritySubject <: AbstractPlacementSubject end

"""The unique command-authority placement subject in one Gate 9A plant."""
struct CommandAuthoritySubject <: AbstractPlacementSubject end

"""The output disposition for the complete group identified by one path."""
struct AcquisitionOutputSubject <: AbstractPlacementSubject
    path::OpticalPathID
end

placement_subject_path(subject::PathGroupSubject) = subject.path
placement_subject_path(subject::AcquisitionOutputSubject) = subject.path
placement_subject_path(::AbstractPlacementSubject) = nothing

Base.:(==)(left::PathGroupSubject, right::PathGroupSubject) = left.path == right.path
Base.isequal(left::PathGroupSubject, right::PathGroupSubject) = isequal(left.path, right.path)
Base.hash(value::PathGroupSubject, seed::UInt) = hash(value.path, hash(PathGroupSubject, seed))
Base.:(==)(left::AcquisitionOutputSubject, right::AcquisitionOutputSubject) =
    left.path == right.path
Base.isequal(left::AcquisitionOutputSubject, right::AcquisitionOutputSubject) =
    isequal(left.path, right.path)
Base.hash(value::AcquisitionOutputSubject, seed::UInt) =
    hash(value.path, hash(AcquisitionOutputSubject, seed))

@inline _placement_subject_key(subject::PathGroupSubject) = (UInt8(1), String(subject.path.name))
@inline _placement_subject_key(::AtmosphereAuthoritySubject) = (UInt8(2), "")
@inline _placement_subject_key(::CommandAuthoritySubject) = (UInt8(3), "")
@inline _placement_subject_key(subject::AcquisitionOutputSubject) = (UInt8(4), String(subject.path.name))

Base.isless(left::AbstractPlacementSubject, right::AbstractPlacementSubject) =
    isless(_placement_subject_key(left), _placement_subject_key(right))

@inline _is_placement_subject(::AbstractPlacementSubject) = true
@inline _is_placement_subject(::Any) = false

"""Resource-byte estimate for one subject on one candidate resource."""
struct ResourceEstimate{
    S<:AbstractPlacementSubject,
    R<:AbstractMemoryBytes,
    W<:AbstractMemoryBytes,
}
    subject::S
    resource::ExecutionResourceID
    provenance::FactProvenance
    resident_bytes::R
    workspace_bytes::W

    function ResourceEstimate(subject::S, resource::ExecutionResourceID,
        provenance::FactProvenance, resident_bytes::R,
        workspace_bytes::W) where {
        S<:AbstractPlacementSubject,
        R<:AbstractMemoryBytes,
        W<:AbstractMemoryBytes,
    }
        _sum_memory_bytes(resident_bytes, workspace_bytes, :resource_estimate)
        return new{S,R,W}(subject, resource, provenance, resident_bytes,
            workspace_bytes)
    end
end

resource_estimate_subject(estimate::ResourceEstimate) = estimate.subject
resource_estimate_resource(estimate::ResourceEstimate) = estimate.resource
resource_estimate_provenance(estimate::ResourceEstimate) = estimate.provenance
resident_memory_bytes(estimate::ResourceEstimate) = estimate.resident_bytes
workspace_memory_bytes(estimate::ResourceEstimate) = estimate.workspace_bytes
total_estimated_memory_bytes(estimate::ResourceEstimate) = _sum_memory_bytes(
    estimate.resident_bytes, estimate.workspace_bytes, :resource_estimate)

@inline _is_resource_estimate(::ResourceEstimate) = true
@inline _is_resource_estimate(::Any) = false
@inline _resource_estimate_key(estimate::ResourceEstimate) =
    (_placement_subject_key(estimate.subject), String(estimate.resource.name))

function _canonical_estimates(estimates)
    snapshot = collect(estimates)
    all(_is_resource_estimate, snapshot) || throw(PlacementError(
        :placement_facts, :invalid_resource_estimate,
        "resource estimates must use ResourceEstimate values"))
    sort!(snapshot; by=_resource_estimate_key)
    for index in 2:length(snapshot)
        _resource_estimate_key(snapshot[index - 1]) == _resource_estimate_key(snapshot[index]) &&
            throw(PlacementError(:placement_facts, :duplicate_resource_estimate,
                "a subject/resource pair can have only one resource estimate"))
    end
    return Tuple(snapshot)
end

function _common_estimate_provenance(estimates::Tuple)
    isempty(estimates) && return nothing
    provenance = resource_estimate_provenance(first(estimates))
    all(estimate -> resource_estimate_provenance(estimate) == provenance, estimates) ||
        throw(PlacementError(:placement_facts, :inconsistent_estimate_provenance,
            "all resource estimates must use one exact provenance and version"))
    return provenance
end

@inline _validate_handoff_footprint(::UnknownMemoryBytes, ::Int,
    ::Symbol) = nothing

@inline function _validate_handoff_footprint(payload_bytes::KnownMemoryBytes,
    maximum_in_flight::Int, component::Symbol)
    payload_bytes.value <= div(typemax(UInt64), UInt64(maximum_in_flight)) ||
        throw(PlacementError(
            component, :memory_arithmetic_overflow,
            "payload bytes times maximum in-flight handoffs exceeds UInt64 range"))
    return nothing
end

"""Caller-supplied abstract transfer requirement; it allocates no handoff."""
abstract type AbstractHandoffFact end

struct AtmospherePathInputHandoff{B<:AbstractMemoryBytes} <: AbstractHandoffFact
    destination::PathGroupSubject
    payload_bytes::B
    maximum_in_flight::Int
    provenance::FactProvenance

    function AtmospherePathInputHandoff(destination::PathGroupSubject,
        payload_bytes::B, maximum_in_flight::Integer,
        provenance::FactProvenance) where {B<:AbstractMemoryBytes}
        checked_in_flight = _checked_positive_int(
            maximum_in_flight, :atmosphere_path_input_handoff,
            "maximum in-flight handoffs")
        _validate_handoff_footprint(payload_bytes, checked_in_flight,
            :atmosphere_path_input_handoff)
        return new{B}(destination, payload_bytes, checked_in_flight, provenance)
    end
end

struct CommandReplicaHandoff{B<:AbstractMemoryBytes} <: AbstractHandoffFact
    destination::PathGroupSubject
    payload_bytes::B
    maximum_in_flight::Int
    provenance::FactProvenance

    function CommandReplicaHandoff(destination::PathGroupSubject,
        payload_bytes::B, maximum_in_flight::Integer,
        provenance::FactProvenance) where {B<:AbstractMemoryBytes}
        checked_in_flight = _checked_positive_int(
            maximum_in_flight, :command_replica_handoff,
            "maximum in-flight handoffs")
        _validate_handoff_footprint(payload_bytes, checked_in_flight,
            :command_replica_handoff)
        return new{B}(destination, payload_bytes, checked_in_flight, provenance)
    end
end

struct AcquisitionOutputHandoff{B<:AbstractMemoryBytes} <: AbstractHandoffFact
    source::AcquisitionOutputSubject
    payload_bytes::B
    maximum_in_flight::Int
    provenance::FactProvenance

    function AcquisitionOutputHandoff(source::AcquisitionOutputSubject,
        payload_bytes::B, maximum_in_flight::Integer,
        provenance::FactProvenance) where {B<:AbstractMemoryBytes}
        checked_in_flight = _checked_positive_int(
            maximum_in_flight, :acquisition_output_handoff,
            "maximum in-flight handoffs")
        _validate_handoff_footprint(payload_bytes, checked_in_flight,
            :acquisition_output_handoff)
        return new{B}(source, payload_bytes, checked_in_flight, provenance)
    end
end

handoff_subject(handoff::AtmospherePathInputHandoff) = handoff.destination
handoff_subject(handoff::CommandReplicaHandoff) = handoff.destination
handoff_subject(handoff::AcquisitionOutputHandoff) = handoff.source
handoff_payload_bytes(handoff::AbstractHandoffFact) = handoff.payload_bytes
handoff_maximum_in_flight(handoff::AbstractHandoffFact) = handoff.maximum_in_flight
handoff_provenance(handoff::AbstractHandoffFact) = handoff.provenance

@inline _is_handoff_fact(::AbstractHandoffFact) = true
@inline _is_handoff_fact(::Any) = false
@inline _handoff_kind(::AtmospherePathInputHandoff) = UInt8(1)
@inline _handoff_kind(::CommandReplicaHandoff) = UInt8(2)
@inline _handoff_kind(::AcquisitionOutputHandoff) = UInt8(3)
@inline _handoff_key(handoff::AbstractHandoffFact) =
    (_handoff_kind(handoff), _placement_subject_key(handoff_subject(handoff)))

function _canonical_handoffs(handoffs)
    snapshot = collect(handoffs)
    all(_is_handoff_fact, snapshot) || throw(PlacementError(
        :placement_facts, :invalid_handoff_fact,
        "handoff requirements must use typed AbstractHandoffFact values"))
    sort!(snapshot; by=_handoff_key)
    for index in 2:length(snapshot)
        _handoff_key(snapshot[index - 1]) == _handoff_key(snapshot[index]) &&
            throw(PlacementError(:placement_facts, :duplicate_handoff_fact,
                "one abstract handoff fact is permitted for each kind and subject"))
    end
    return Tuple(snapshot)
end

function _common_handoff_provenance(handoffs::Tuple)
    isempty(handoffs) && return nothing
    provenance = handoff_provenance(first(handoffs))
    all(handoff -> handoff_provenance(handoff) == provenance, handoffs) ||
        throw(PlacementError(:placement_facts, :inconsistent_handoff_provenance,
            "all abstract handoff facts must use one exact provenance and version"))
    return provenance
end

"""Immutable input facts consumed by a later static-placement planner."""
struct PlacementFacts
    inventory::ResourceInventory
    estimates::Tuple
    handoffs::Tuple
    estimate_provenance::Union{Nothing,FactProvenance}
    handoff_provenance::Union{Nothing,FactProvenance}
end

function PlacementFacts(inventory::ResourceInventory, estimates=(), handoffs=())
    canonical_estimates = _canonical_estimates(estimates)
    canonical_handoffs = _canonical_handoffs(handoffs)
    inventory_resource_ids = Set(execution_resource_id(resource) for resource in
        resource_inventory_resources(inventory))
    all(estimate -> resource_estimate_resource(estimate) in inventory_resource_ids,
        canonical_estimates) || throw(PlacementError(
            :placement_facts, :unknown_estimate_resource,
            "every resource estimate must name an inventory resource"))
    return PlacementFacts(inventory, canonical_estimates, canonical_handoffs,
        _common_estimate_provenance(canonical_estimates),
        _common_handoff_provenance(canonical_handoffs))
end

placement_inventory(facts::PlacementFacts) = facts.inventory
placement_estimates(facts::PlacementFacts) = facts.estimates
placement_handoffs(facts::PlacementFacts) = facts.handoffs
placement_estimate_provenance(facts::PlacementFacts) = facts.estimate_provenance
placement_handoff_provenance(facts::PlacementFacts) = facts.handoff_provenance

"""Output placement policy for one complete acquisition group."""
abstract type AbstractAcquisitionOutputDisposition end

struct DeviceReadyOutput{C<:AbstractResourceCriticality} <:
       AbstractAcquisitionOutputDisposition
    subject::AcquisitionOutputSubject
    criticality::C
end

struct ConsumerOutput{C<:AbstractResourceCriticality} <:
       AbstractAcquisitionOutputDisposition
    subject::AcquisitionOutputSubject
    consumer_resource::ExecutionResourceID
    consumer_memory_domain::MemoryDomainID
    criticality::C
end

output_subject(disposition::AbstractAcquisitionOutputDisposition) = disposition.subject
output_criticality(disposition::AbstractAcquisitionOutputDisposition) =
    disposition.criticality
output_consumer_resource(::DeviceReadyOutput) = nothing
output_consumer_memory_domain(::DeviceReadyOutput) = nothing
output_consumer_resource(disposition::ConsumerOutput) = disposition.consumer_resource
output_consumer_memory_domain(disposition::ConsumerOutput) =
    disposition.consumer_memory_domain

@inline _is_output_disposition(::AbstractAcquisitionOutputDisposition) = true
@inline _is_output_disposition(::Any) = false
@inline _output_key(disposition::AbstractAcquisitionOutputDisposition) =
    _placement_subject_key(output_subject(disposition))

function _canonical_output_dispositions(dispositions)
    snapshot = collect(dispositions)
    all(_is_output_disposition, snapshot) || throw(PlacementError(
        :placement_policy, :invalid_output_disposition,
        "acquisition outputs must use typed output dispositions"))
    sort!(snapshot; by=_output_key)
    for index in 2:length(snapshot)
        _output_key(snapshot[index - 1]) == _output_key(snapshot[index]) &&
            throw(PlacementError(:placement_policy, :duplicate_output_disposition,
                "each complete acquisition group has one output disposition"))
    end
    return Tuple(snapshot)
end

"""A concrete hard placement constraint; it cannot be weakened by a preference."""
abstract type AbstractHardConstraint end

struct RequireExecutionResource{S<:AbstractPlacementSubject} <: AbstractHardConstraint
    subject::S
    resource::ExecutionResourceID
end

struct RequireMemoryDomain{S<:AbstractPlacementSubject} <: AbstractHardConstraint
    subject::S
    domain::MemoryDomainID
end

struct RequireCapability{S<:AbstractPlacementSubject} <: AbstractHardConstraint
    subject::S
    capability::Symbol

    function RequireCapability(subject::S, capability::Symbol) where {
        S<:AbstractPlacementSubject,
    }
        return new{S}(_require_capability_subject(subject), _require_name(
            capability, :hard_constraint, "required capability name"))
    end
end

@inline _require_capability_subject(subject::S) where {S<:AbstractPlacementSubject} = subject

"""A deterministic preference; it does not select a resource itself."""
abstract type AbstractPlacementPreference end

struct PreferExecutionResource{S<:AbstractPlacementSubject} <:
       AbstractPlacementPreference
    subject::S
    resource::ExecutionResourceID
    rank::Int

    function PreferExecutionResource(subject::S, resource::ExecutionResourceID,
        rank::Integer) where {S<:AbstractPlacementSubject}
        return new{S}(subject, resource, _checked_nonnegative_int(
            rank, :placement_preference, "preference rank"))
    end
end

"""One caller-selected placement assignment, without a plan lifecycle."""
struct ExplicitPlacementAssignment{S<:AbstractPlacementSubject}
    subject::S
    resource::ExecutionResourceID
end

placement_subject(value::ResourceEstimate) = value.subject
placement_subject(value::AbstractAcquisitionOutputDisposition) = value.subject
placement_subject(value::AbstractHardConstraint) = value.subject
placement_subject(value::AbstractPlacementPreference) = value.subject
placement_subject(value::ExplicitPlacementAssignment) = value.subject
placement_subject(value::AtmospherePathInputHandoff) = value.destination
placement_subject(value::CommandReplicaHandoff) = value.destination
placement_subject(value::AcquisitionOutputHandoff) = value.source

assigned_execution_resource(value::ExplicitPlacementAssignment) = value.resource

@inline _is_hard_constraint(::AbstractHardConstraint) = true
@inline _is_hard_constraint(::Any) = false
@inline _constraint_kind(::RequireExecutionResource) = UInt8(1)
@inline _constraint_kind(::RequireMemoryDomain) = UInt8(2)
@inline _constraint_kind(::RequireCapability) = UInt8(3)
@inline _constraint_name(constraint::RequireExecutionResource) = String(constraint.resource.name)
@inline _constraint_name(constraint::RequireMemoryDomain) = String(constraint.domain.name)
@inline _constraint_name(constraint::RequireCapability) = String(constraint.capability)
@inline _constraint_key(constraint::AbstractHardConstraint) =
    (_placement_subject_key(placement_subject(constraint)),
        _constraint_kind(constraint), _constraint_name(constraint))

function _canonical_constraints(constraints)
    snapshot = collect(constraints)
    all(_is_hard_constraint, snapshot) || throw(PlacementError(
        :placement_policy, :invalid_hard_constraint,
        "hard constraints must use typed AbstractHardConstraint values"))
    sort!(snapshot; by=_constraint_key)
    for index in 2:length(snapshot)
        _constraint_key(snapshot[index - 1]) == _constraint_key(snapshot[index]) &&
            throw(PlacementError(:placement_policy, :duplicate_hard_constraint,
                "placement policy cannot retain duplicate hard constraints"))
    end
    return Tuple(snapshot)
end

@inline _is_preference(::AbstractPlacementPreference) = true
@inline _is_preference(::Any) = false
@inline _preference_key(preference::PreferExecutionResource) =
    (_placement_subject_key(placement_subject(preference)),
        preference.rank, String(preference.resource.name))

function _canonical_preferences(preferences)
    snapshot = collect(preferences)
    all(_is_preference, snapshot) || throw(PlacementError(
        :placement_policy, :invalid_preference,
        "placement preferences must use typed AbstractPlacementPreference values"))
    sort!(snapshot; by=_preference_key)
    for index in 2:length(snapshot)
        _preference_key(snapshot[index - 1]) == _preference_key(snapshot[index]) &&
            throw(PlacementError(:placement_policy, :duplicate_preference,
                "placement policy cannot retain duplicate preferences"))
    end
    return Tuple(snapshot)
end

@inline _is_explicit_assignment(::ExplicitPlacementAssignment) = true
@inline _is_explicit_assignment(::Any) = false
@inline _assignment_key(assignment::ExplicitPlacementAssignment) =
    _placement_subject_key(placement_subject(assignment))

function _canonical_assignments(assignments)
    snapshot = collect(assignments)
    all(_is_explicit_assignment, snapshot) || throw(PlacementError(
        :placement_policy, :invalid_explicit_assignment,
        "explicit assignments must use ExplicitPlacementAssignment values"))
    sort!(snapshot; by=_assignment_key)
    for index in 2:length(snapshot)
        _assignment_key(snapshot[index - 1]) == _assignment_key(snapshot[index]) &&
            throw(PlacementError(:placement_policy, :duplicate_explicit_assignment,
                "each placement subject can have only one explicit assignment"))
    end
    return Tuple(snapshot)
end

"""Immutable, canonically ordered policy values for the later Gate 9A planner."""
struct PlacementPolicyValues
    hard_constraints::Tuple
    preferences::Tuple
    assignments::Tuple
    output_dispositions::Tuple
end

function PlacementPolicyValues(; hard_constraints=(), preferences=(),
    assignments=(), output_dispositions=())
    return PlacementPolicyValues(
        _canonical_constraints(hard_constraints),
        _canonical_preferences(preferences),
        _canonical_assignments(assignments),
        _canonical_output_dispositions(output_dispositions))
end

hard_constraints(values::PlacementPolicyValues) = values.hard_constraints
placement_preferences(values::PlacementPolicyValues) = values.preferences
explicit_assignments(values::PlacementPolicyValues) = values.assignments
acquisition_output_dispositions(values::PlacementPolicyValues) =
    values.output_dispositions

@inline function _inventory_has_resource(inventory::ResourceInventory,
    resource::ExecutionResourceID)
    return any(candidate -> execution_resource_id(candidate) == resource,
        resource_inventory_resources(inventory))
end

function _inventory_memory_domain_owner(inventory::ResourceInventory,
    domain::MemoryDomainID)
    for resource in resource_inventory_resources(inventory)
        memory = execution_resource_memory_domain(resource)
        memory_domain_id(memory) == domain && return memory_domain_owner(memory)
    end
    return nothing
end

@inline function _require_inventory_resource(inventory::ResourceInventory,
    resource::ExecutionResourceID, component::Symbol)
    _inventory_has_resource(inventory, resource) || throw(PlacementError(
        component, :unknown_resource,
        "a placement value refers to a resource absent from its inventory"))
    return nothing
end

@inline function _require_inventory_domain(inventory::ResourceInventory,
    domain::MemoryDomainID, component::Symbol)
    isnothing(_inventory_memory_domain_owner(inventory, domain)) &&
        throw(PlacementError(component, :unknown_memory_domain,
            "a placement value refers to a memory domain absent from its inventory"))
    return nothing
end

@inline function _validate_constraint_inventory(::RequireCapability,
    ::ResourceInventory)
    return nothing
end

@inline function _validate_constraint_inventory(constraint::RequireExecutionResource,
    inventory::ResourceInventory)
    return _require_inventory_resource(inventory, constraint.resource,
        :placement_inputs)
end

@inline function _validate_constraint_inventory(constraint::RequireMemoryDomain,
    inventory::ResourceInventory)
    return _require_inventory_domain(inventory, constraint.domain,
        :placement_inputs)
end

@inline function _validate_preference_inventory(preference::PreferExecutionResource,
    inventory::ResourceInventory)
    return _require_inventory_resource(inventory, preference.resource,
        :placement_inputs)
end

@inline function _validate_output_inventory(::DeviceReadyOutput,
    ::ResourceInventory)
    return nothing
end

@inline function _validate_output_inventory(disposition::ConsumerOutput,
    inventory::ResourceInventory)
    _require_inventory_resource(inventory, disposition.consumer_resource,
        :placement_inputs)
    owner = _inventory_memory_domain_owner(inventory,
        disposition.consumer_memory_domain)
    isnothing(owner) && throw(PlacementError(:placement_inputs,
        :unknown_memory_domain,
        "an acquisition consumer refers to a memory domain absent from its inventory"))
    owner == disposition.consumer_resource || throw(PlacementError(
        :placement_inputs, :inconsistent_memory_domain_owner,
        "an acquisition consumer resource must own its declared memory domain"))
    return nothing
end

"""
    PlacementInputs(facts, policy)

Immutable composition of placement facts and policy values. Construction only
validates inventory references and domain ownership; it does not resolve or
admit any assignment.
"""
struct _PlacementInputsToken end
const _PLACEMENT_INPUTS_TOKEN = _PlacementInputsToken()

struct PlacementInputs
    facts::PlacementFacts
    policy::PlacementPolicyValues

    PlacementInputs(facts::PlacementFacts, policy::PlacementPolicyValues,
        ::_PlacementInputsToken) = new(facts, policy)
end

function PlacementInputs(facts::PlacementFacts, policy::PlacementPolicyValues)
    inventory = placement_inventory(facts)
    for constraint in hard_constraints(policy)
        _validate_constraint_inventory(constraint, inventory)
    end
    for preference in placement_preferences(policy)
        _validate_preference_inventory(preference, inventory)
    end
    for assignment in explicit_assignments(policy)
        _require_inventory_resource(inventory,
            assigned_execution_resource(assignment), :placement_inputs)
    end
    for disposition in acquisition_output_dispositions(policy)
        _validate_output_inventory(disposition, inventory)
    end
    return PlacementInputs(facts, policy, _PLACEMENT_INPUTS_TOKEN)
end

placement_facts(inputs::PlacementInputs) = inputs.facts
placement_policy_values(inputs::PlacementInputs) = inputs.policy

end
