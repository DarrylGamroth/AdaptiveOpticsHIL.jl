using AdaptiveOpticsHIL.Placement
using AdaptiveOpticsHIL.Ports: OptionalResource, RequiredResource
using AdaptiveOpticsSim.Plant: OpticalPathID

function placement_test_provenance(; source=:placement_test, version=1)
    return FactProvenance(source, version)
end

function placement_test_resource(id::Symbol, domain::Symbol;
    capability_provenance=placement_test_provenance(),
    capabilities=(TargetCapability(:full_optical, CapabilitySupported()),),
    capacity=KnownMemoryBytes(4096),
    headroom=KnownMemoryBytes(512),
    workers=2,
)
    resource_id = ExecutionResourceID(id)
    memory_domain = MemoryDomain(
        MemoryDomainID(domain), resource_id, capacity, headroom)
    return ExecutionResource(
        resource_id,
        CPUExecutionResource(),
        id,
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
        AcceleratorExecutionResource(),
        id,
        MemoryDomain(MemoryDomainID(domain), resource_id,
            KnownMemoryBytes(8192), KnownMemoryBytes(1024)),
        AcceleratorExecutionFacts(AcceleratorContextID(Symbol(id, :_context))),
        CapabilitySnapshot(capability_provenance, capabilities))
end

placement_test_path(name::Symbol) = PathGroupSubject(OpticalPathID(name))
placement_test_output(name::Symbol) = AcquisitionOutputSubject(OpticalPathID(name))

@testset "Placement identifiers and explicit unknown values" begin
    @test ExecutionResourceID(:cpu) == ExecutionResourceID(:cpu)
    @test ExecutionResourceID(:cpu) != ExecutionResourceID(:gpu)
    @test isless(ExecutionResourceID(:cpu), ExecutionResourceID(:gpu))
    @test_throws PlacementError ExecutionResourceID(Symbol())
    @test_throws PlacementError MemoryDomainID(Symbol())
    @test_throws PlacementError ReservedContextID(Symbol())
    @test PlacementFactVersion(1).value == 1
    @test_throws PlacementError PlacementFactVersion(0)
    @test_throws PlacementError PlacementFactVersion(true)
    @test FactProvenance(:test, 2).version == PlacementFactVersion(2)
    @test_throws PlacementError FactProvenance(Symbol(), 1)

    known = KnownMemoryBytes(0)
    unknown = UnknownMemoryBytes()
    @test memory_bytes(known) == 0
    @test memory_bytes(unknown) === nothing
    @test_throws PlacementError KnownMemoryBytes(-1)
    @test_throws PlacementError KnownMemoryBytes(true)
    @test CPUWorkerFacts(3).numa_node == UnknownNUMANode()
    @test CPUWorkerFacts(3, NUMANodeID(1)).worker_count == 3
    @test_throws PlacementError CPUWorkerFacts(0)
    @test_throws PlacementError NUMANodeID(-1)
end

@testset "Placement resource inventory" begin
    provenance = placement_test_provenance()
    cpu = placement_test_resource(:cpu, :host; capability_provenance=provenance)
    gpu = placement_test_accelerator(:gpu, :gpu_memory;
        capability_provenance=provenance)
    contexts = [
        ReservedCoordinationContext(ReservedContextID(:coordinator),
            ExecutionResourceID(:cpu)),
        ReservedCoordinationContext(ReservedContextID(:gpu_submit),
            ExecutionResourceID(:gpu)),
    ]
    inventory = ResourceInventory([gpu, cpu], reverse(contexts))

    @test execution_resource_id.(resource_inventory_resources(inventory)) ==
        (ExecutionResourceID(:cpu), ExecutionResourceID(:gpu))
    @test reserved_context_id.(resource_inventory_contexts(inventory)) ==
        (ReservedContextID(:coordinator), ReservedContextID(:gpu_submit))
    @test resource_inventory_capability_provenance(inventory) == provenance
    @test execution_resource_kind(first(resource_inventory_resources(inventory))) ==
        CPUExecutionResource()
    @test execution_resource_device(last(resource_inventory_resources(inventory))) == :gpu
    @test execution_resource_memory_domain(cpu).id == MemoryDomainID(:host)
    @test execution_resource_facts(cpu).numa_node == NUMANodeID(0)
    @test memory_domain_capacity(execution_resource_memory_domain(cpu)) ==
        KnownMemoryBytes(4096)
    @test memory_domain_headroom(execution_resource_memory_domain(cpu)) ==
        KnownMemoryBytes(512)

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
        [cpu], [ReservedCoordinationContext(ReservedContextID(:missing),
            ExecutionResourceID(:not_an_inventory_resource))])
    @test_throws PlacementError ResourceInventory(
        [cpu], [
            ReservedCoordinationContext(ReservedContextID(:duplicate),
                ExecutionResourceID(:cpu)),
            ReservedCoordinationContext(ReservedContextID(:duplicate),
                ExecutionResourceID(:cpu)),
        ])
    @test_throws PlacementError MemoryDomain(
        MemoryDomainID(:bad), ExecutionResourceID(:cpu),
        KnownMemoryBytes(1), KnownMemoryBytes(2))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:wrong_owner), CPUExecutionResource(), :wrong_owner,
        execution_resource_memory_domain(cpu), CPUWorkerFacts(1),
        CapabilitySnapshot(provenance, ()))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:cpu), AcceleratorExecutionResource(), :cpu,
        MemoryDomain(MemoryDomainID(:wrong_facts), ExecutionResourceID(:cpu),
            KnownMemoryBytes(10), KnownMemoryBytes(1)), CPUWorkerFacts(1),
        CapabilitySnapshot(provenance, ()))
    @test_throws PlacementError ExecutionResource(
        ExecutionResourceID(:mutable), CPUExecutionResource(), [1],
        MemoryDomain(MemoryDomainID(:mutable), ExecutionResourceID(:mutable),
            KnownMemoryBytes(10), KnownMemoryBytes(1)), CPUWorkerFacts(1),
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
            KnownMemoryBytes(30), KnownMemoryBytes(12)),
        ResourceEstimate(wfs, ExecutionResourceID(:cpu), provenance,
            UnknownMemoryBytes(), KnownMemoryBytes(2)),
    ]
    handoffs = [
        AcquisitionOutputHandoff(placement_test_output(:science),
            KnownMemoryBytes(64), 2, provenance),
        AtmospherePathInputHandoff(science, KnownMemoryBytes(128), 3, provenance),
        CommandReplicaHandoff(science, UnknownMemoryBytes(), 1, provenance),
    ]
    facts = PlacementFacts(inventory, reverse(estimates), reverse(handoffs))
    @test resource_estimate_subject.(placement_estimates(facts)) == (science, wfs)
    @test handoff_subject.(placement_handoffs(facts)) ==
        (science, science, placement_test_output(:science))
    @test placement_estimate_provenance(facts) == provenance
    @test placement_handoff_provenance(facts) == provenance
    @test total_estimated_memory_bytes(placement_estimates(facts)[1]) ==
        KnownMemoryBytes(42)
    @test total_estimated_memory_bytes(placement_estimates(facts)[2]) ==
        UnknownMemoryBytes()
    @test handoff_payload_bytes(placement_handoffs(facts)[2]) == UnknownMemoryBytes()
    @test handoff_maximum_in_flight(placement_handoffs(facts)[1]) == 3
    @test handoff_provenance(placement_handoffs(facts)[3]) == provenance

    push!(estimates, ResourceEstimate(science, ExecutionResourceID(:cpu), provenance,
        KnownMemoryBytes(1), KnownMemoryBytes(1)))
    @test length(placement_estimates(facts)) == 2
    @test_throws PlacementError PlacementFacts(inventory, [
        ResourceEstimate(science, ExecutionResourceID(:cpu), provenance,
            KnownMemoryBytes(1), KnownMemoryBytes(1)),
        ResourceEstimate(science, ExecutionResourceID(:cpu), provenance,
            KnownMemoryBytes(2), KnownMemoryBytes(2)),
    ])
    @test_throws PlacementError PlacementFacts(inventory, [
        ResourceEstimate(science, ExecutionResourceID(:missing), provenance,
            KnownMemoryBytes(1), KnownMemoryBytes(1)),
    ])
    @test_throws PlacementError PlacementFacts(inventory, [
        ResourceEstimate(science, ExecutionResourceID(:cpu), provenance,
            KnownMemoryBytes(1), KnownMemoryBytes(1)),
        ResourceEstimate(wfs, ExecutionResourceID(:cpu),
            placement_test_provenance(source=:other), KnownMemoryBytes(1),
            KnownMemoryBytes(1)),
    ])
    @test_throws PlacementError PlacementFacts(inventory, (), [
        AtmospherePathInputHandoff(science, KnownMemoryBytes(1), 1, provenance),
        AtmospherePathInputHandoff(science, KnownMemoryBytes(1), 1, provenance),
    ])
    @test_throws PlacementError PlacementFacts(inventory, (), [
        AtmospherePathInputHandoff(science, KnownMemoryBytes(1), 1, provenance),
        CommandReplicaHandoff(science, KnownMemoryBytes(1), 1,
            placement_test_provenance(source=:other)),
    ])
    @test_throws PlacementError AtmospherePathInputHandoff(
        science, KnownMemoryBytes(1), 0, provenance)
    @test_throws PlacementError ResourceEstimate(
        science, ExecutionResourceID(:cpu), provenance,
        KnownMemoryBytes(typemax(UInt64)), KnownMemoryBytes(1))
    @test_throws PlacementError AtmospherePathInputHandoff(
        science, KnownMemoryBytes(typemax(UInt64)), 2, provenance)
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
            ConsumerOutput(science_output, cpu, host, RequiredResource()),
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
    @test output_criticality(acquisition_output_dispositions(values)[2]) ==
        OptionalResource()

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
            output_dispositions=[ConsumerOutput(science_output,
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
        ConsumerOutput(science_output, cpu, host, RequiredResource()),
    ])
    @test_throws PlacementError RequireCapability(science, Symbol())
    @test_throws PlacementError PreferExecutionResource(science, cpu, -1)
end
