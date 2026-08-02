using AdaptiveOpticsHIL.Placement
using AdaptiveOpticsHIL.Ports: OptionalResource, RequiredResource
using AdaptiveOpticsSim.Backends: AbstractArrayBackend, AbstractComputeDevice
using AdaptiveOpticsSim.Backends: AcceleratorComputeDevice, HostComputeDevice
using AdaptiveOpticsSim.Plant: OpticalPathID

struct PlacementTestAcceleratorBackend <: AbstractArrayBackend end

mutable struct MutablePlacementTestBackend <: AbstractArrayBackend
    marker::Vector{Int}
end

struct UnsupportedPlacementTestDevice <: AbstractComputeDevice end
struct UnsupportedPlacementByteCount <:
       AdaptiveOpticsHIL.Placement._AbstractByteCount end
struct UnsupportedPlacementNUMANode <:
       AdaptiveOpticsHIL.Placement._AbstractNUMANodeFact end
struct UnsupportedPlacementResourceKind <:
       AdaptiveOpticsHIL.Placement._AbstractExecutionResourceKind end
struct UnsupportedPlacementCapabilityAvailability <:
       AdaptiveOpticsHIL.Placement._AbstractCapabilityAvailability end
struct UnsupportedPlacementSubject <:
       AdaptiveOpticsHIL.Placement._AbstractPlacementSubject end
struct UnsupportedPlacementHandoff <:
       AdaptiveOpticsHIL.Placement._AbstractHandoffFact end
struct UnsupportedPlacementOutputDisposition <:
       AdaptiveOpticsHIL.Placement._AbstractAcquisitionOutputDisposition end
struct UnsupportedPlacementConstraint <:
       AdaptiveOpticsHIL.Placement._AbstractHardConstraint end
struct UnsupportedPlacementPreference <:
       AdaptiveOpticsHIL.Placement._AbstractPlacementPreference end
struct UnsupportedPlacementCriticality <:
       AdaptiveOpticsHIL.Ports.AbstractResourceCriticality end

function placement_test_provenance(; source=:placement_test, version=1)
    return FactProvenance(source, version)
end

function placement_test_resource(id::Symbol, domain::Symbol;
    capability_provenance=placement_test_provenance(),
    capabilities=(TargetCapability(:full_optical, CapabilitySupported()),),
    capacity=KnownByteCount(4096),
    headroom=KnownByteCount(512),
    workers=2,
)
    resource_id = ExecutionResourceID(id)
    memory_domain = MemoryDomain(
        MemoryDomainID(domain), resource_id, capacity, headroom)
    return ExecutionResource(
        resource_id,
        CPUExecutionResourceKind(),
        HostComputeDevice(),
        memory_domain,
        CPUWorkerFacts(workers, NUMANodeID(0)),
        CapabilitySnapshot(capability_provenance, capabilities))
end

function placement_test_accelerator(id::Symbol, domain::Symbol;
    capability_provenance=placement_test_provenance(),
    capabilities=(TargetCapability(:full_optical, CapabilitySupported()),),
)
    resource_id = ExecutionResourceID(id)
    return ExecutionResource(
        resource_id,
        AcceleratorExecutionResourceKind(),
        AcceleratorComputeDevice(PlacementTestAcceleratorBackend(), UInt32(0)),
        MemoryDomain(MemoryDomainID(domain), resource_id,
            KnownByteCount(8192), KnownByteCount(1024)),
        AcceleratorExecutionFacts(AcceleratorContextID(Symbol(id, :_context))),
        CapabilitySnapshot(capability_provenance, capabilities))
end

placement_test_path(name::Symbol) = PathExecutionGroupSubject(OpticalPathID(name))
placement_test_output(name::Symbol) = AcquisitionOutputSubject(OpticalPathID(name))

@testset "Placement identifiers and explicit unknown values" begin
    cpu_id = ExecutionResourceID(:cpu)
    same_cpu_id = ExecutionResourceID(:cpu)
    gpu_id = ExecutionResourceID(:gpu)
    @test cpu_id == same_cpu_id
    @test cpu_id != gpu_id
    @test isequal(cpu_id, same_cpu_id)
    @test hash(cpu_id) == hash(same_cpu_id)
    @test isless(cpu_id, gpu_id)
    @test sprint(show, cpu_id) == "ExecutionResourceID(:cpu)"
    @test_throws PlacementError ExecutionResourceID(Symbol())
    @test_throws PlacementError MemoryDomainID(Symbol())
    @test_throws PlacementError ReservedCoordinationContextID(Symbol())
    version = PlacementFactVersion(1)
    same_version = PlacementFactVersion(1)
    @test version.value == 1
    @test isequal(version, same_version)
    @test hash(version) == hash(same_version)
    @test isless(version, PlacementFactVersion(2))
    @test sprint(show, version) == "PlacementFactVersion(1)"
    @test_throws PlacementError PlacementFactVersion(0)
    @test_throws PlacementError PlacementFactVersion(UInt32(0))
    @test_throws PlacementError PlacementFactVersion(true)
    provenance = FactProvenance(:test, 2)
    same_provenance = FactProvenance(:test, 2)
    @test provenance.version == PlacementFactVersion(2)
    @test isequal(provenance, same_provenance)
    @test hash(provenance) == hash(same_provenance)
    @test isless(FactProvenance(:a, 1), FactProvenance(:b, 1))
    @test_throws PlacementError FactProvenance(Symbol(), 1)

    known = KnownByteCount(0)
    same_known = KnownByteCount(0)
    unknown = UnknownByteCount()
    @test byte_count(known) == 0
    @test byte_count(unknown) === nothing
    @test isequal(known, same_known)
    @test hash(known) == hash(same_known)
    @test unknown == UnknownByteCount()
    @test isequal(unknown, UnknownByteCount())
    @test hash(unknown) == hash(UnknownByteCount())
    @test_throws PlacementError KnownByteCount(-1)
    @test_throws PlacementError KnownByteCount(true)
    unknown_numa = UnknownNUMANode()
    known_numa = NUMANodeID(1)
    @test CPUWorkerFacts(3).numa_node == unknown_numa
    @test CPUWorkerFacts(3, known_numa).worker_count == 3
    @test isequal(known_numa, NUMANodeID(1))
    @test hash(known_numa) == hash(NUMANodeID(1))
    @test unknown_numa == UnknownNUMANode()
    @test isequal(unknown_numa, UnknownNUMANode())
    @test hash(unknown_numa) == hash(UnknownNUMANode())
    @test_throws PlacementError CPUWorkerFacts(0)
    @test_throws PlacementError NUMANodeID(-1)

    accelerator_context = AcceleratorContextID(:accelerator)
    same_accelerator_context = AcceleratorContextID(:accelerator)
    @test accelerator_context == same_accelerator_context
    @test isequal(accelerator_context, same_accelerator_context)
    @test hash(accelerator_context) == hash(same_accelerator_context)
    @test isless(accelerator_context, AcceleratorContextID(:other))
end

@testset "Placement constructors and closed value families" begin
    provenance = placement_test_provenance()
    capability = TargetCapability(:full_optical, CapabilitySupported())
    duplicate_capabilities = (capability, capability)
    @test_throws PlacementError CapabilitySnapshot(
        provenance, duplicate_capabilities)
    @test_throws PlacementError TargetCapability(
        :unsupported, UnsupportedPlacementCapabilityAvailability())
    @test_throws PlacementError CPUWorkerFacts(1,
        UnsupportedPlacementNUMANode())
    @test_throws PlacementError MemoryDomain(
        MemoryDomainID(:unsupported), ExecutionResourceID(:cpu),
        UnsupportedPlacementByteCount(), KnownByteCount(0))
    @test_throws PlacementError byte_count(UnsupportedPlacementByteCount())

    cpu = placement_test_resource(:cpu, :host;
        capability_provenance=provenance)
    inventory = ResourceInventory((cpu,))
    @test_throws MethodError ResourceInventory(
        (cpu,), (), FactProvenance(:bypass, 99))
    @test_throws MethodError PlacementFacts(
        inventory, (), (), FactProvenance(:bypass, 99), nothing)
    @test_throws MethodError PlacementPolicyValues((), (), (), ())

    unsupported_subject = UnsupportedPlacementSubject()
    @test_throws PlacementError ResourceEstimate(
        unsupported_subject, ExecutionResourceID(:cpu), provenance,
        KnownByteCount(1), KnownByteCount(1))
    @test_throws PlacementError RequireExecutionResource(
        unsupported_subject, ExecutionResourceID(:cpu))
    @test_throws PlacementError RequireMemoryDomain(
        unsupported_subject, MemoryDomainID(:host))
    @test_throws PlacementError RequireCapability(
        unsupported_subject, :full_optical)
    @test_throws PlacementError PreferExecutionResource(
        unsupported_subject, ExecutionResourceID(:cpu), 0)
    @test_throws PlacementError ExplicitPlacementAssignment(
        unsupported_subject, ExecutionResourceID(:cpu))
    @test_throws PlacementError PlacementFacts(
        inventory, (), (UnsupportedPlacementHandoff(),))
    @test_throws PlacementError handoff_subject(UnsupportedPlacementHandoff())
    @test_throws PlacementError handoff_payload_bytes(UnsupportedPlacementHandoff())
    @test_throws PlacementError handoff_maximum_in_flight(
        UnsupportedPlacementHandoff())
    @test_throws PlacementError handoff_provenance(UnsupportedPlacementHandoff())
    @test_throws PlacementError PlacementPolicyValues(
        hard_constraints=(UnsupportedPlacementConstraint(),))
    @test_throws PlacementError PlacementPolicyValues(
        preferences=(UnsupportedPlacementPreference(),))
    @test_throws PlacementError PlacementPolicyValues(
        output_dispositions=(UnsupportedPlacementOutputDisposition(),))
    @test_throws PlacementError output_subject(
        UnsupportedPlacementOutputDisposition())
    @test_throws PlacementError output_criticality(
        UnsupportedPlacementOutputDisposition())
    @test_throws PlacementError output_consumer_resource(
        UnsupportedPlacementOutputDisposition())
    @test_throws PlacementError output_consumer_memory_domain(
        UnsupportedPlacementOutputDisposition())
    @test_throws PlacementError placement_subject(
        UnsupportedPlacementOutputDisposition())
    @test_throws PlacementError placement_subject(
        UnsupportedPlacementConstraint())
    @test_throws PlacementError placement_subject(
        UnsupportedPlacementPreference())
    @test_throws PlacementError placement_subject_path(unsupported_subject)
    @test_throws PlacementError isless(
        unsupported_subject, placement_test_path(:science))
    @test_throws PlacementError DeviceReadyOutput(
        placement_test_output(:science), UnsupportedPlacementCriticality())

    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:unsupported_kind),
        UnsupportedPlacementResourceKind(), HostComputeDevice(),
        MemoryDomain(MemoryDomainID(:unsupported_kind),
            ExecutionResourceID(:unsupported_kind), KnownByteCount(10),
            KnownByteCount(1)), CPUWorkerFacts(1),
        CapabilitySnapshot(provenance, ()))

    exported_names = Set(names(AdaptiveOpticsHIL.Placement))
    for name in (
        :_AbstractByteCount,
        :_AbstractNUMANodeFact,
        :_AbstractExecutionResourceKind,
        :_AbstractCapabilityAvailability,
        :_AbstractPlacementSubject,
        :_AbstractHandoffFact,
        :_AbstractAcquisitionOutputDisposition,
        :_AbstractHardConstraint,
        :_AbstractPlacementPreference,
    )
        @test name ∉ exported_names
    end
end

@testset "Placement resource inventory" begin
    provenance = placement_test_provenance()
    cpu = placement_test_resource(:cpu, :host; capability_provenance=provenance)
    gpu = placement_test_accelerator(:gpu, :gpu_memory;
        capability_provenance=provenance)
    contexts = [
        ReservedCoordinationContext(ReservedCoordinationContextID(:coordinator),
            ExecutionResourceID(:cpu)),
        ReservedCoordinationContext(ReservedCoordinationContextID(:gpu_submit),
            ExecutionResourceID(:gpu)),
    ]
    inventory = ResourceInventory([gpu, cpu], reverse(contexts))

    @test execution_resource_id.(resource_inventory_resources(inventory)) ==
        (ExecutionResourceID(:cpu), ExecutionResourceID(:gpu))
    @test reserved_context_id.(resource_inventory_contexts(inventory)) ==
        (ReservedCoordinationContextID(:coordinator), ReservedCoordinationContextID(:gpu_submit))
    @test resource_inventory_capability_provenance(inventory) == provenance
    @test execution_resource_kind(first(resource_inventory_resources(inventory))) ==
        CPUExecutionResourceKind()
    @test execution_resource_device(last(resource_inventory_resources(inventory))) ==
        AcceleratorComputeDevice(PlacementTestAcceleratorBackend(), UInt32(0))
    @test execution_resource_memory_domain(cpu).id == MemoryDomainID(:host)
    @test execution_resource_facts(cpu).numa_node == NUMANodeID(0)
    @test memory_domain_capacity(execution_resource_memory_domain(cpu)) ==
        KnownByteCount(4096)
    @test memory_domain_headroom(execution_resource_memory_domain(cpu)) ==
        KnownByteCount(512)
    unknown_memory = MemoryDomain(
        MemoryDomainID(:unknown_memory), ExecutionResourceID(:cpu),
        UnknownByteCount(), UnknownByteCount())
    @test memory_domain_capacity(unknown_memory) == UnknownByteCount()

    resources = ExecutionResource[cpu]
    snapshot = ResourceInventory(resources)
    push!(resources, gpu)
    @test length(resource_inventory_resources(snapshot)) == 1
    @test_throws PlacementError ResourceInventory(())
    @test_throws PlacementError ResourceInventory([cpu, cpu])
    @test_throws PlacementError ResourceInventory([
        cpu,
        placement_test_resource(:cpu_other, :host;
            capability_provenance=provenance),
    ])
    @test_throws PlacementError ResourceInventory([
        placement_test_resource(:a, :shared;
            capability_provenance=provenance),
        placement_test_resource(:b, :separate;
            capability_provenance=provenance),
        placement_test_resource(:c, :shared;
            capability_provenance=provenance),
    ])
    @test_throws PlacementError ResourceInventory([
        cpu,
        placement_test_accelerator(:gpu_a, :gpu_a_memory;
            capability_provenance=provenance),
        placement_test_accelerator(:gpu_b, :gpu_b_memory;
            capability_provenance=provenance),
    ])
    @test_throws PlacementError ResourceInventory([
        cpu,
        placement_test_resource(:cpu_other, :host_other;
            capability_provenance=placement_test_provenance(source=:other)),
    ])
    @test_throws PlacementError ResourceInventory(
        [cpu], [ReservedCoordinationContext(ReservedCoordinationContextID(:missing),
            ExecutionResourceID(:not_an_inventory_resource))])
    @test_throws PlacementError ResourceInventory(
        [cpu], [
            ReservedCoordinationContext(ReservedCoordinationContextID(:duplicate),
                ExecutionResourceID(:cpu)),
            ReservedCoordinationContext(ReservedCoordinationContextID(:duplicate),
                ExecutionResourceID(:cpu)),
        ])
    @test_throws PlacementError MemoryDomain(
        MemoryDomainID(:bad), ExecutionResourceID(:cpu),
        KnownByteCount(1), KnownByteCount(2))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:wrong_owner), CPUExecutionResourceKind(),
        HostComputeDevice(),
        execution_resource_memory_domain(cpu), CPUWorkerFacts(1),
        CapabilitySnapshot(provenance, ()))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:cpu), AcceleratorExecutionResourceKind(),
        AcceleratorComputeDevice(PlacementTestAcceleratorBackend(), UInt32(0)),
        MemoryDomain(MemoryDomainID(:wrong_facts), ExecutionResourceID(:cpu),
            KnownByteCount(10), KnownByteCount(1)), CPUWorkerFacts(1),
        CapabilitySnapshot(provenance, ()))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:mutable), CPUExecutionResourceKind(), [1],
        MemoryDomain(MemoryDomainID(:mutable), ExecutionResourceID(:mutable),
            KnownByteCount(10), KnownByteCount(1)), CPUWorkerFacts(1),
        CapabilitySnapshot(provenance, ()))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:nested_mutable), AcceleratorExecutionResourceKind(),
        AcceleratorComputeDevice(MutablePlacementTestBackend([1]), UInt32(0)),
        MemoryDomain(MemoryDomainID(:nested_mutable),
            ExecutionResourceID(:nested_mutable), KnownByteCount(10),
            KnownByteCount(1)),
        AcceleratorExecutionFacts(AcceleratorContextID(:nested_mutable)),
        CapabilitySnapshot(provenance, ()))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:cpu_mismatch), CPUExecutionResourceKind(),
        AcceleratorComputeDevice(PlacementTestAcceleratorBackend(), UInt32(0)),
        MemoryDomain(MemoryDomainID(:cpu_mismatch),
            ExecutionResourceID(:cpu_mismatch), KnownByteCount(10),
            KnownByteCount(1)), CPUWorkerFacts(1),
        CapabilitySnapshot(provenance, ()))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:gpu_mismatch), AcceleratorExecutionResourceKind(),
        HostComputeDevice(),
        MemoryDomain(MemoryDomainID(:gpu_mismatch),
            ExecutionResourceID(:gpu_mismatch), KnownByteCount(10),
            KnownByteCount(1)),
        AcceleratorExecutionFacts(AcceleratorContextID(:gpu_mismatch)),
        CapabilitySnapshot(provenance, ()))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:unsupported_device), CPUExecutionResourceKind(),
        UnsupportedPlacementTestDevice(),
        MemoryDomain(MemoryDomainID(:unsupported_device),
            ExecutionResourceID(:unsupported_device), KnownByteCount(10),
            KnownByteCount(1)), CPUWorkerFacts(1),
        CapabilitySnapshot(provenance, ()))
end

@testset "Placement capability snapshots" begin
    provenance = placement_test_provenance()
    capabilities = [
        TargetCapability(:synthetic, CapabilityUnknown()),
        TargetCapability(:full_optical, CapabilitySupported()),
        TargetCapability(:unsupported_mode, CapabilityUnsupported()),
    ]
    snapshot = CapabilitySnapshot(provenance, reverse(capabilities))
    @test capability_provenance(snapshot) == provenance
    @test capability_name.(snapshot.capabilities) ==
        (:full_optical, :synthetic, :unsupported_mode)
    @test capability_availability(snapshot.capabilities[1]) == CapabilitySupported()
    pop!(capabilities)
    @test length(snapshot.capabilities) == 3
    @test_throws PlacementError CapabilitySnapshot(provenance, [
        TargetCapability(:same, CapabilitySupported()),
        TargetCapability(:same, CapabilityUnknown()),
    ])
    @test_throws PlacementError CapabilitySnapshot(provenance, [:not_a_capability])
end

@testset "Placement facts preserve explicit unknowns" begin
    provenance = placement_test_provenance()
    cpu = placement_test_resource(:cpu, :host; capability_provenance=provenance)
    gpu = placement_test_accelerator(:gpu, :gpu_memory;
        capability_provenance=provenance)
    inventory = ResourceInventory([cpu, gpu])
    science = placement_test_path(:science)
    wfs = placement_test_path(:wfs)
    estimates = [
        ResourceEstimate(science, ExecutionResourceID(:gpu), provenance,
            KnownByteCount(30), KnownByteCount(12)),
        ResourceEstimate(wfs, ExecutionResourceID(:cpu), provenance,
            UnknownByteCount(), KnownByteCount(2)),
    ]
    handoffs = [
        AcquisitionOutputHandoff(placement_test_output(:science),
            KnownByteCount(64), 2, provenance),
        AtmospherePathInputHandoff(science, KnownByteCount(128), 3, provenance),
        CommandReplicaHandoff(science, UnknownByteCount(), 1, provenance),
    ]
    facts = PlacementFacts(inventory, reverse(estimates), reverse(handoffs))
    @test resource_estimate_subject.(placement_estimates(facts)) == (science, wfs)
    @test handoff_subject.(placement_handoffs(facts)) ==
        (science, science, placement_test_output(:science))
    @test placement_estimate_provenance(facts) == provenance
    @test placement_handoff_provenance(facts) == provenance
    @test total_estimated_memory_bytes(placement_estimates(facts)[1]) ==
        KnownByteCount(42)
    @test total_estimated_memory_bytes(placement_estimates(facts)[2]) ==
        UnknownByteCount()
    @test resident_memory_bytes(placement_estimates(facts)[1]) ==
        KnownByteCount(30)
    @test workspace_memory_bytes(placement_estimates(facts)[1]) ==
        KnownByteCount(12)
    @test placement_subject(placement_estimates(facts)[1]) == science
    @test handoff_payload_bytes(placement_handoffs(facts)[2]) == UnknownByteCount()
    @test handoff_maximum_in_flight(placement_handoffs(facts)[1]) == 3
    @test handoff_provenance(placement_handoffs(facts)[3]) == provenance
    atmosphere_handoff, command_handoff, output_handoff =
        placement_handoffs(facts)
    @test handoff_payload_bytes(atmosphere_handoff) == KnownByteCount(128)
    @test handoff_payload_bytes(output_handoff) == KnownByteCount(64)
    @test handoff_maximum_in_flight(command_handoff) == 1
    @test handoff_maximum_in_flight(output_handoff) == 2
    @test placement_subject(atmosphere_handoff) == science
    @test placement_subject(command_handoff) == science
    @test placement_subject(output_handoff) == placement_test_output(:science)

    science_output = placement_test_output(:science)
    @test placement_subject_path(science) == OpticalPathID(:science)
    @test placement_subject_path(science_output) == OpticalPathID(:science)
    @test placement_subject_path(AtmosphereAuthoritySubject()) === nothing
    @test placement_subject_path(CommandAuthoritySubject()) === nothing
    @test isequal(science, placement_test_path(:science))
    @test hash(science) == hash(placement_test_path(:science))
    @test isequal(science_output, placement_test_output(:science))
    @test hash(science_output) == hash(placement_test_output(:science))
    @test isless(science, wfs)
    output_estimate = ResourceEstimate(science_output,
        ExecutionResourceID(:cpu), provenance,
        KnownByteCount(1), KnownByteCount(1))
    @test resource_estimate_subject(output_estimate) == science_output

    push!(estimates, ResourceEstimate(science, ExecutionResourceID(:cpu), provenance,
        KnownByteCount(1), KnownByteCount(1)))
    @test length(placement_estimates(facts)) == 2
    @test_throws PlacementError PlacementFacts(inventory, [
        ResourceEstimate(science, ExecutionResourceID(:cpu), provenance,
            KnownByteCount(1), KnownByteCount(1)),
        ResourceEstimate(science, ExecutionResourceID(:cpu), provenance,
            KnownByteCount(2), KnownByteCount(2)),
    ])
    @test_throws PlacementError PlacementFacts(inventory, [
        ResourceEstimate(science, ExecutionResourceID(:missing), provenance,
            KnownByteCount(1), KnownByteCount(1)),
    ])
    @test_throws PlacementError PlacementFacts(inventory, [
        ResourceEstimate(science, ExecutionResourceID(:cpu), provenance,
            KnownByteCount(1), KnownByteCount(1)),
        ResourceEstimate(wfs, ExecutionResourceID(:cpu),
            placement_test_provenance(source=:other), KnownByteCount(1),
            KnownByteCount(1)),
    ])
    @test_throws PlacementError PlacementFacts(inventory, (), [
        AtmospherePathInputHandoff(science, KnownByteCount(1), 1, provenance),
        AtmospherePathInputHandoff(science, KnownByteCount(1), 1, provenance),
    ])
    @test_throws PlacementError PlacementFacts(inventory, (), [
        AtmospherePathInputHandoff(science, KnownByteCount(1), 1, provenance),
        CommandReplicaHandoff(science, KnownByteCount(1), 1,
            placement_test_provenance(source=:other)),
    ])
    @test_throws PlacementError AtmospherePathInputHandoff(
        science, KnownByteCount(1), 0, provenance)
    @test_throws PlacementError ResourceEstimate(
        science, ExecutionResourceID(:cpu), provenance,
        KnownByteCount(typemax(UInt64)), KnownByteCount(1))
    @test_throws PlacementError AtmospherePathInputHandoff(
        science, KnownByteCount(typemax(UInt64)), 2, provenance)
end

@testset "Placement policy values" begin
    cpu = ExecutionResourceID(:cpu)
    gpu = ExecutionResourceID(:gpu)
    host = MemoryDomainID(:host)
    science = placement_test_path(:science)
    wfs = placement_test_path(:wfs)
    science_output = placement_test_output(:science)
    wfs_output = placement_test_output(:wfs)
    values = PlacementPolicyValues(
        hard_constraints=[
            RequireCapability(science, :full_optical),
            RequireExecutionResource(wfs, cpu),
            RequireMemoryDomain(science, host),
        ],
        preferences=[
            PreferExecutionResource(science, gpu, 1),
            PreferExecutionResource(science, cpu, 0),
        ],
        assignments=[
            ExplicitPlacementAssignment(wfs, cpu),
            ExplicitPlacementAssignment(science, gpu),
            ExplicitPlacementAssignment(AtmosphereAuthoritySubject(), cpu),
            ExplicitPlacementAssignment(CommandAuthoritySubject(), gpu),
        ],
        output_dispositions=[
            ExplicitConsumerOutput(science_output, cpu, host, RequiredResource()),
            DeviceReadyOutput(wfs_output, OptionalResource()),
        ])
    @test placement_subject.(hard_constraints(values)) == (science, science, wfs)
    @test placement_preferences(values)[1].resource == cpu
    @test placement_preferences(values)[2].resource == gpu
    @test placement_subject.(explicit_assignments(values)) ==
        (science, wfs, AtmosphereAuthoritySubject(), CommandAuthoritySubject())
    @test output_subject.(acquisition_output_dispositions(values)) ==
        (science_output, wfs_output)
    @test output_consumer_resource(acquisition_output_dispositions(values)[1]) == cpu
    @test output_consumer_memory_domain(acquisition_output_dispositions(values)[1]) == host
    @test output_consumer_resource(acquisition_output_dispositions(values)[2]) === nothing
    @test output_consumer_memory_domain(
        acquisition_output_dispositions(values)[2]) === nothing
    @test output_criticality(acquisition_output_dispositions(values)[1]) ==
        RequiredResource()
    @test output_criticality(acquisition_output_dispositions(values)[2]) ==
        OptionalResource()
    @test placement_subject(acquisition_output_dispositions(values)[1]) ==
        science_output
    @test placement_subject(acquisition_output_dispositions(values)[2]) ==
        wfs_output

    provenance = placement_test_provenance()
    inventory = ResourceInventory([
        placement_test_resource(:cpu, :host; capability_provenance=provenance),
        placement_test_accelerator(:gpu, :gpu_memory;
            capability_provenance=provenance),
    ])
    inputs = PlacementInputs(PlacementFacts(inventory), values)
    @test placement_inventory(placement_facts(inputs)) === inventory
    @test placement_policy_values(inputs) === values
    @test_throws PlacementError PlacementInputs(
        PlacementFacts(inventory), PlacementPolicyValues(
            assignments=[ExplicitPlacementAssignment(science,
                ExecutionResourceID(:missing))]))
    @test_throws PlacementError PlacementInputs(
        PlacementFacts(inventory), PlacementPolicyValues(
            hard_constraints=[RequireMemoryDomain(science,
                MemoryDomainID(:missing))]))
    @test_throws PlacementError PlacementInputs(
        PlacementFacts(inventory), PlacementPolicyValues(
            output_dispositions=[ExplicitConsumerOutput(science_output,
                ExecutionResourceID(:cpu), MemoryDomainID(:gpu_memory),
                RequiredResource())]))

    assignments = [ExplicitPlacementAssignment(science, cpu)]
    snapshot = PlacementPolicyValues(assignments=assignments)
    empty!(assignments)
    @test length(explicit_assignments(snapshot)) == 1
    @test_throws PlacementError PlacementPolicyValues(assignments=[
        ExplicitPlacementAssignment(science, cpu),
        ExplicitPlacementAssignment(science, gpu),
    ])
    @test_throws PlacementError PlacementPolicyValues(hard_constraints=[
        RequireExecutionResource(science, cpu),
        RequireExecutionResource(science, cpu),
    ])
    @test_throws PlacementError PlacementPolicyValues(preferences=[
        PreferExecutionResource(science, cpu, 1),
        PreferExecutionResource(science, cpu, 1),
    ])
    @test_throws PlacementError PlacementPolicyValues(output_dispositions=[
        DeviceReadyOutput(science_output, RequiredResource()),
        ExplicitConsumerOutput(science_output, cpu, host, RequiredResource()),
    ])
    @test_throws PlacementError RequireCapability(science, Symbol())
    @test_throws PlacementError PreferExecutionResource(science, cpu, -1)
end
