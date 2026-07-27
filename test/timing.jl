using AdaptiveOpticsHIL.Timing
using AdaptiveOpticsSim.Plant: PlantDuration, PlantTimestamp
using Clocks
using InteractiveUtils

struct WrongWidthNanoClock <: Clocks.AbstractNanoClock end
Clocks.time_nanos(::WrongWidthNanoClock) = Int32(0)

struct IdentifiedNanoClock <: Clocks.AbstractNanoClock
    value::Int64
end
Clocks.time_nanos(clock::IdentifiedNanoClock) = clock.value
AdaptiveOpticsHIL.Timing.execution_clock_identity(
    ::IdentifiedNanoClock) =
    ExecutionClockID(:identified_test_clock)

const TIMING_TESTS_WITH_COVERAGE =
    Base.JLOptions().code_coverage != 0

function timing_allocation_bytes(mapping, target)
    execution_lateness_ns(mapping, target)
    execution_time_until_ns(mapping, target)
    lateness_bytes = @allocated execution_lateness_ns(mapping, target)
    time_until_bytes = @allocated execution_time_until_ns(mapping, target)
    return lateness_bytes, time_until_bytes
end

function external_mapping_allocation_bytes(mapping, source_timestamp_ticks)
    map_external_timestamp(mapping, source_timestamp_ticks)
    return @allocated map_external_timestamp(mapping, source_timestamp_ticks)
end

function timing_llvm_text(f, types)
    output = IOBuffer()
    code_llvm(
        output,
        f,
        types;
        optimize=true,
        raw=true,
        debuginfo=:none)
    return String(take!(output))
end

function value_bytes(reference::Ref{T}) where {T}
    bytes = Vector{UInt8}(undef, sizeof(T))
    GC.@preserve reference unsafe_copyto!(
        pointer(bytes),
        Ptr{UInt8}(Base.unsafe_convert(Ptr{T}, reference)),
        sizeof(T))
    return bytes
end

@testset "External timestamp-domain mapping" begin
    @testset "Exact affine conversion and metadata" begin
        rtc = ExternalTimestampDomainID(:rtc_ptp)
        camera = ExternalTimestampDomainID(:camera_ticks)
        version = TimestampMappingVersion(3)
        @test isequal(rtc, ExternalTimestampDomainID(:rtc_ptp))
        @test hash(rtc) == hash(ExternalTimestampDomainID(:rtc_ptp))
        @test isequal(version, TimestampMappingVersion(3))
        @test hash(version) == hash(TimestampMappingVersion(3))
        @test TimestampMappingVersion(2) < version
        @test TimestampMappingVersion(2) <= version
        @test !isless(version, TimestampMappingVersion(2))
        @test sprint(show, rtc) == "ExternalTimestampDomainID(:rtc_ptp)"
        @test sprint(show, version) == "TimestampMappingVersion(3)"
        mapping = ExternalTimestampMapping(
            rtc,
            version,
            1_000,
            PlantTimestamp(10_000);
            rate_numerator=11,
            rate_denominator=10,
            uncertainty=PlantDuration(7),
            valid_from_ticks=900,
            valid_through_ticks=1_100)

        @test Base.allocatedinline(ExternalTimestampMapping)
        @test Base.allocatedinline(MappedExternalTimestamp)
        mapped = @inferred map_external_timestamp(mapping, Int64(1_010))
        @test external_timestamp_domain(mapping) == rtc
        @test external_timestamp_domain(mapped) == rtc
        @test timestamp_mapping_version(mapping) == version
        @test timestamp_mapping_version(mapped) == version
        @test source_anchor_ticks(mapping) == 1_000
        @test plant_anchor_timestamp(mapping) == PlantTimestamp(10_000)
        @test timestamp_rate_numerator(mapping) == 11
        @test timestamp_rate_denominator(mapping) == 10
        @test timestamp_valid_from_ticks(mapping) == 900
        @test timestamp_valid_through_ticks(mapping) == 1_100
        @test timestamp_mapping_uncertainty(mapping) == PlantDuration(7)
        @test source_timestamp_ticks(mapped) == 1_010
        @test mapped_plant_timestamp(mapped) == PlantTimestamp(10_011)
        @test timestamp_mapping_uncertainty(mapped) == PlantDuration(7)

        negative_rate_error = ExternalTimestampMapping(
            camera,
            TimestampMappingVersion(1),
            2_000,
            PlantTimestamp(20_000);
            rate_numerator=9,
            rate_denominator=10,
            valid_from_ticks=1_900,
            valid_through_ticks=2_100)
        @test mapped_plant_timestamp(
            map_external_timestamp(negative_rate_error, 2_010)) ==
            PlantTimestamp(20_009)

        ties_to_even = ExternalTimestampMapping(
            ExternalTimestampDomainID(:half_ticks),
            TimestampMappingVersion(1),
            0,
            PlantTimestamp(100);
            rate_numerator=1,
            rate_denominator=2,
            valid_from_ticks=-10,
            valid_through_ticks=10)
        @test mapped_plant_timestamp(
            map_external_timestamp(ties_to_even, -1)) == PlantTimestamp(100)
        @test mapped_plant_timestamp(
            map_external_timestamp(ties_to_even, -3)) == PlantTimestamp(98)
        @test mapped_plant_timestamp(
            map_external_timestamp(ties_to_even, 1)) == PlantTimestamp(100)
        @test mapped_plant_timestamp(
            map_external_timestamp(ties_to_even, 3)) == PlantTimestamp(102)

        reduced_rate = ExternalTimestampMapping(
            ExternalTimestampDomainID(:reduced),
            TimestampMappingVersion(1),
            0,
            PlantTimestamp(0);
            rate_numerator=10,
            rate_denominator=20,
            valid_from_ticks=0,
            valid_through_ticks=10)
        @test timestamp_rate_numerator(reduced_rate) == 1
        @test timestamp_rate_denominator(reduced_rate) == 2

        if TIMING_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test external_mapping_allocation_bytes(mapping, Int64(1_010)) ==
                0
        end
    end

    @testset "Validity and checked construction" begin
        domain = ExternalTimestampDomainID(:rtc)
        version = TimestampMappingVersion(1)
        mapping = ExternalTimestampMapping(
            domain,
            version,
            100,
            PlantTimestamp(100);
            valid_from_ticks=50,
            valid_through_ticks=150)

        @test mapped_plant_timestamp(
            map_external_timestamp(mapping, 50)) == PlantTimestamp(50)
        @test mapped_plant_timestamp(
            map_external_timestamp(mapping, 150)) == PlantTimestamp(150)
        @test_throws TimestampMappingError map_external_timestamp(mapping, 49)
        @test_throws TimestampMappingError map_external_timestamp(mapping, 151)
        @test_throws TimestampMappingError map_external_timestamp(
            mapping, typemax(UInt64))
        @test_throws TimestampMappingError map_external_timestamp(mapping, true)
        @test_throws TimestampMappingError ExternalTimestampDomainID(Symbol(""))
        @test_throws TimestampMappingError TimestampMappingOwnerID(Symbol(""))
        @test_throws TimestampMappingError TimestampMappingVersion(0)
        @test_throws TimestampMappingError TimestampMappingVersion(false)
        @test_throws TimestampMappingError ExternalTimestampMapping(
            domain,
            version,
            100,
            PlantTimestamp(100);
            rate_numerator=0,
            valid_from_ticks=50,
            valid_through_ticks=150)
        @test_throws TimestampMappingError ExternalTimestampMapping(
            domain,
            version,
            100,
            PlantTimestamp(100);
            rate_denominator=false,
            valid_from_ticks=50,
            valid_through_ticks=150)
        @test_throws TimestampMappingError ExternalTimestampMapping(
            domain,
            version,
            100,
            PlantTimestamp(100);
            valid_from_ticks=101,
            valid_through_ticks=150)
        @test_throws TimestampMappingError ExternalTimestampMapping(
            domain,
            version,
            0,
            PlantTimestamp(0);
            valid_from_ticks=-1,
            valid_through_ticks=1)
        @test_throws TimestampMappingError ExternalTimestampMapping(
            domain,
            version,
            0,
            PlantTimestamp(typemax(Int64));
            rate_numerator=2,
            valid_from_ticks=0,
            valid_through_ticks=1)
        expired_error = try
            map_external_timestamp(mapping, 151)
            nothing
        catch error
            error
        end
        @test expired_error isa TimestampMappingError
        @test expired_error.reason == :outside_validity_interval
        overflow_error = try
            ExternalTimestampMapping(
                domain,
                version,
                0,
                PlantTimestamp(typemax(Int64));
                rate_numerator=2,
                valid_from_ticks=0,
                valid_through_ticks=1)
            nothing
        catch error
            error
        end
        @test overflow_error isa TimestampMappingError
        @test overflow_error.reason == :plant_timestamp_overflow
    end

    @testset "Bounded prospective versions" begin
        owner = TimestampMappingOwnerID(:synchronization_owner)
        registry = prepare_timestamp_mappings(4; owner)
        rtc = ExternalTimestampDomainID(:rtc)
        camera = ExternalTimestampDomainID(:camera)
        rtc_v1 = ExternalTimestampMapping(
            rtc,
            TimestampMappingVersion(1),
            1_000,
            PlantTimestamp(100);
            uncertainty=PlantDuration(4),
            valid_from_ticks=950,
            valid_through_ticks=1_050)
        camera_v1 = ExternalTimestampMapping(
            camera,
            TimestampMappingVersion(1),
            1_000,
            PlantTimestamp(200);
            valid_from_ticks=950,
            valid_through_ticks=1_050)
        rtc_v2 = ExternalTimestampMapping(
            rtc,
            TimestampMappingVersion(2),
            1_000,
            PlantTimestamp(110);
            uncertainty=PlantDuration(2),
            valid_from_ticks=950,
            valid_through_ticks=1_050)

        @test timestamp_mapping_capacity(registry) == 4
        @test timestamp_mapping_count(registry) == 0
        @test timestamp_mapping_owner(registry) == owner
        @test_throws TimestampMappingError install_timestamp_mapping!(
            registry, TimestampMappingOwnerID(:intruder), rtc_v1)

        @test @inferred(install_timestamp_mapping!(
            registry, owner, rtc_v1)) === rtc_v1
        @test install_timestamp_mapping!(registry, owner, camera_v1) ===
            camera_v1
        old_result = @inferred map_external_timestamp(
            registry, rtc, 1_010)
        old_reference = Ref(old_result)
        old_bytes = value_bytes(old_reference)
        @test mapped_plant_timestamp(old_result) == PlantTimestamp(110)
        @test mapped_plant_timestamp(
            @inferred(map_external_timestamp(
                registry, camera, TimestampMappingVersion(1), 1_010))) ==
            PlantTimestamp(210)

        install_timestamp_mapping!(registry, owner, rtc_v2)
        new_result = @inferred map_external_timestamp(
            registry, rtc, 1_010)
        @test mapped_plant_timestamp(new_result) == PlantTimestamp(120)
        @test timestamp_mapping_version(new_result) ==
            TimestampMappingVersion(2)
        @test value_bytes(old_reference) == old_bytes
        @test mapped_plant_timestamp(old_result) == PlantTimestamp(110)
        @test timestamp_mapping(
            registry, rtc, TimestampMappingVersion(1)) === rtc_v1
        @test latest_timestamp_mapping(registry, rtc) === rtc_v2
        @test timestamp_mapping_at(registry, 2) === camera_v1
        map_external_timestamp(
            registry, rtc, TimestampMappingVersion(1), 1_010)
        map_external_timestamp(registry, rtc, 1_010)
        if TIMING_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test @allocated(map_external_timestamp(
                registry,
                rtc,
                TimestampMappingVersion(1),
                1_010)) == 0
            @test @allocated(map_external_timestamp(
                registry, rtc, 1_010)) == 0
        end
        @test_throws TimestampMappingError timestamp_mapping_at(registry, 4)
        @test_throws TimestampMappingError timestamp_mapping_at(registry, true)
        @test_throws TimestampMappingError timestamp_mapping(
            registry, rtc, TimestampMappingVersion(3))
        @test_throws TimestampMappingError latest_timestamp_mapping(
            registry, ExternalTimestampDomainID(:unknown))
        @test_throws TimestampMappingError install_timestamp_mapping!(
            registry, owner, rtc_v2)
        stale_error = try
            install_timestamp_mapping!(registry, owner, rtc_v2)
            nothing
        catch error
            error
        end
        @test stale_error isa TimestampMappingError
        @test stale_error.reason == :nonincreasing_version
        unknown_error = try
            timestamp_mapping(
                registry, rtc, TimestampMappingVersion(4))
            nothing
        catch error
            error
        end
        @test unknown_error isa TimestampMappingError
        @test unknown_error.reason == :unknown_version

        full_registry = prepare_timestamp_mappings(
            1; owner=TimestampMappingOwnerID(:full_owner))
        install_timestamp_mapping!(
            full_registry, TimestampMappingOwnerID(:full_owner), rtc_v1)
        @test_throws TimestampMappingError install_timestamp_mapping!(
            full_registry, TimestampMappingOwnerID(:full_owner), camera_v1)
        @test_throws TimestampMappingError prepare_timestamp_mappings(false)
        @test_throws TimestampMappingError prepare_timestamp_mappings(0)
    end

    @testset "Generated mapping boundary" begin
        mapping_llvm = timing_llvm_text(
            map_external_timestamp,
            Tuple{ExternalTimestampMapping,Int64})
        count_llvm = timing_llvm_text(
            timestamp_mapping_count,
            Tuple{PreparedTimestampMappings})
        install_llvm = timing_llvm_text(
            install_timestamp_mapping!,
            Tuple{
                PreparedTimestampMappings,
                TimestampMappingOwnerID,
                ExternalTimestampMapping})
        @test occursin(
            r"load atomic i64, ptr .* acquire",
            count_llvm)
        @test occursin(
            r"store atomic i64 .* release",
            install_llvm)
        @test !occursin("jl_apply_generic", mapping_llvm)
        @test !occursin("jl_gc_alloc", mapping_llvm)
    end
end

@testset "Execution-clock mapping" begin
    @testset "Exact deterministic timing" begin
        clock = CachedNanoClock(1_000)
        origin = PlantTimestamp(100)
        mapping = @inferred arm_execution_clock(clock, origin)
        target = PlantTimestamp(350)

        @test mapping isa ExecutionClockMapping{CachedNanoClock}
        @test @inferred(execution_clock(mapping)) === clock
        @test @inferred(execution_clock_identity(clock)) ==
            ExecutionClockID(:execution_clock)
        @test @inferred(execution_clock_identity(mapping)) ==
            ExecutionClockID(:execution_clock)
        @test @inferred(plant_time_origin(mapping)) == origin
        @test @inferred(execution_clock_origin_ns(mapping)) == 1_000

        identified = IdentifiedNanoClock(2_000)
        identified_mapping = @inferred arm_execution_clock(identified)
        @test execution_clock_identity(identified_mapping) ==
            ExecutionClockID(:identified_test_clock)

        @test @inferred(execution_lateness_ns(mapping, target)) == -250
        @test @inferred(execution_time_until_ns(mapping, target)) == 250

        advance!(clock, 250)
        @test execution_lateness_ns(mapping, target) == 0
        @test execution_time_until_ns(mapping, target) == 0

        advance!(clock, 7)
        @test execution_lateness_ns(mapping, target) == 7
        @test @inferred(execution_lateness_ns(
            mapping, target, Int64(1_257))) == 7
        @test execution_time_until_ns(mapping, target) == -7
        if TIMING_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test timing_allocation_bytes(mapping, target) == (0, 0)
            execution_lateness_ns(
                mapping, target, Int64(1_257))
            @test @allocated(execution_lateness_ns(
                mapping, target, Int64(1_257))) == 0
        end
    end

    @testset "Domain and provider validation" begin
        epoch_clock = CachedEpochClock(0)
        @test !applicable(arm_execution_clock, epoch_clock)
        @test_throws MethodError arm_execution_clock(epoch_clock)

        invalid_reading_error = try
            arm_execution_clock(WrongWidthNanoClock())
            nothing
        catch error
            error
        end
        @test invalid_reading_error isa ExecutionClockError
        @test invalid_reading_error.component == :execution_clock
        @test invalid_reading_error.reason == :invalid_reading_type
        @test sprint(showerror, invalid_reading_error) ==
              "Clocks.time_nanos must return Int64 for an execution clock"

        clock = CachedNanoClock(0)
        mapping = arm_execution_clock(clock, PlantTimestamp(10))
        target_error = try
            execution_lateness_ns(mapping, PlantTimestamp(9))
            nothing
        catch error
            error
        end
        @test target_error isa ExecutionClockError
        @test target_error.component == :plant_target
        @test target_error.reason == :before_mapping_origin
    end

    @testset "Modular elapsed-time bound" begin
        wrapping_clock = CachedNanoClock(typemax(Int64) - 4)
        wrapping_mapping = arm_execution_clock(wrapping_clock)
        advance!(wrapping_clock, 10)
        wrapping_target = PlantTimestamp(10)
        @test execution_lateness_ns(
            wrapping_mapping, wrapping_target) == 0
        @test execution_time_until_ns(
            wrapping_mapping, wrapping_target) == 0

        regressing_clock = CachedNanoClock(100)
        regressing_mapping = arm_execution_clock(regressing_clock)
        update!(regressing_clock, 99)
        regression_error = try
            execution_lateness_ns(
                regressing_mapping, PlantTimestamp(0))
            nothing
        catch error
            error
        end
        @test regression_error isa ExecutionClockError
        @test regression_error.reason == :regression_or_interval_exceeded

        bounded_clock = CachedNanoClock(0)
        bounded_mapping = arm_execution_clock(bounded_clock)
        update!(bounded_clock, typemax(Int64))
        bounded_target = PlantTimestamp(typemax(Int64))
        @test execution_lateness_ns(
            bounded_mapping, bounded_target) == 0
        @test execution_time_until_ns(
            bounded_mapping, bounded_target) == 0

        update!(bounded_clock, typemin(Int64))
        bound_error = try
            execution_lateness_ns(bounded_mapping, PlantTimestamp(0))
            nothing
        catch error
            error
        end
        @test bound_error isa ExecutionClockError
        @test bound_error.reason == :regression_or_interval_exceeded
    end

    @testset "Production provider smoke test" begin
        mapping = @inferred arm_execution_clock(
            SystemNanoClock(),
            PlantTimestamp(0);
            identity=ExecutionClockID(:production_monotonic))
        first_elapsed = @inferred execution_lateness_ns(
            mapping, PlantTimestamp(0))
        second_elapsed = @inferred execution_lateness_ns(
            mapping, PlantTimestamp(0))
        @test first_elapsed >= 0
        @test second_elapsed >= first_elapsed
        metadata = execution_clock_metadata(mapping)
        @test metadata.identity == ExecutionClockID(:production_monotonic)
        @test metadata.source_provider == :SystemNanoClock
        @test metadata.update_owner === nothing
        @test metadata.update_cadence_ns === nothing
        @test metadata.maximum_observed_staleness_ns === nothing
        @test metadata.refresh_count === nothing
    end

    @testset "Single-owner cached execution clock" begin
        source = CachedNanoClock(1_000)
        owner = ExecutionClockUpdateOwnerID(:clock_owner)
        @test isequal(owner, ExecutionClockUpdateOwnerID(:clock_owner))
        @test hash(owner) ==
            hash(ExecutionClockUpdateOwnerID(:clock_owner))
        @test sprint(show, owner) ==
            "ExecutionClockUpdateOwnerID(:clock_owner)"
        @test_throws ExecutionClockError ExecutionClockID(Symbol(""))
        @test_throws ExecutionClockError ExecutionClockUpdateOwnerID(Symbol(""))
        controller = prepare_cached_execution_clock(
            source;
            identity=ExecutionClockID(:scheduler_cache),
            update_owner=owner,
            update_cadence_ns=100)
        clock = cached_execution_clock(controller)
        @test clock isa CachedExecutionClock
        @test execution_clock_identity(clock) ==
            ExecutionClockID(:scheduler_cache)
        @test time_nanos(clock) == 1_000
        @test cached_clock_update_owner(clock) == owner
        @test cached_clock_update_owner(controller) == owner
        @test cached_clock_update_cadence_ns(clock) == 100
        @test cached_clock_update_cadence_ns(controller) == 100
        @test cached_clock_maximum_observed_staleness_ns(clock) == 0
        @test cached_clock_refresh_count(clock) == 0
        @test !applicable(Clocks.update!, clock, Int64(2_000))
        @test !applicable(Clocks.advance!, clock, Int64(1))

        advance!(source, 90)
        @test_throws ExecutionClockError refresh_cached_execution_clock!(
            controller, ExecutionClockUpdateOwnerID(:intruder))
        @test time_nanos(clock) == 1_000
        @test cached_clock_maximum_observed_staleness_ns(controller) == 0
        @test cached_clock_refresh_count(controller) == 0
        owner_error = try
            refresh_cached_execution_clock!(
                controller, ExecutionClockUpdateOwnerID(:intruder))
            nothing
        catch error
            error
        end
        @test owner_error isa ExecutionClockError
        @test owner_error.reason == :wrong_update_owner

        @test @inferred(refresh_cached_execution_clock!(
            controller, owner)) == 1_090
        @test time_nanos(clock) == 1_090
        @test cached_clock_maximum_observed_staleness_ns(clock) == 90
        @test cached_clock_refresh_count(clock) == 1

        advance!(source, 125)
        refresh_cached_execution_clock!(controller, owner)
        @test cached_clock_maximum_observed_staleness_ns(clock) == 125
        @test cached_clock_refresh_count(clock) == 2

        mapping = arm_execution_clock(clock, PlantTimestamp(20))
        @test execution_clock_identity(mapping) ==
            ExecutionClockID(:scheduler_cache)
        metadata = execution_clock_metadata(mapping)
        @test metadata.identity == ExecutionClockID(:scheduler_cache)
        @test metadata.source_provider == :CachedNanoClock
        @test metadata.update_owner == owner
        @test metadata.update_cadence_ns == 100
        @test metadata.maximum_observed_staleness_ns == 125
        @test metadata.refresh_count == 2
        @test execution_clock_identity(metadata) ==
            ExecutionClockID(:scheduler_cache)
        @test execution_clock_source_provider(metadata) == :CachedNanoClock
        @test execution_clock_update_owner(metadata) == owner
        @test execution_clock_update_cadence_ns(metadata) == 100
        @test execution_clock_maximum_observed_staleness_ns(metadata) == 125
        @test execution_clock_refresh_count(metadata) == 2
        if TIMING_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test timing_allocation_bytes(
                mapping, PlantTimestamp(20)) == (0, 0)
        end
        refresh_llvm = timing_llvm_text(
            refresh_cached_execution_clock!,
            Tuple{typeof(controller),ExecutionClockUpdateOwnerID})
        @test occursin(
            r"load atomic i64, ptr .* acquire",
            refresh_llvm)
        @test occursin(
            r"store atomic i64 .* release",
            refresh_llvm)
        @test !occursin("jl_apply_generic", refresh_llvm)
        @test !occursin("jl_gc_alloc", refresh_llvm)
        @test_throws ExecutionClockError arm_execution_clock(
            clock,
            PlantTimestamp(20);
            identity=ExecutionClockID(:other_cache))

        update!(source, 500)
        @test_throws ExecutionClockError refresh_cached_execution_clock!(
            controller, owner)
        @test time_nanos(clock) == 1_215

        @test !applicable(
            prepare_cached_execution_clock,
            CachedEpochClock(0))
        @test_throws MethodError prepare_cached_execution_clock(
            CachedEpochClock(0);
            update_cadence_ns=1)
        @test_throws ExecutionClockError prepare_cached_execution_clock(
            CachedNanoClock(0);
            update_cadence_ns=false)

        allocation_source = CachedNanoClock(0)
        allocation_owner = ExecutionClockUpdateOwnerID(:allocation_owner)
        allocation_controller = prepare_cached_execution_clock(
            allocation_source;
            update_owner=allocation_owner,
            update_cadence_ns=1)
        advance!(allocation_source, 1)
        refresh_cached_execution_clock!(
            allocation_controller, allocation_owner)
        advance!(allocation_source, 1)
        if TIMING_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test @allocated(refresh_cached_execution_clock!(
                allocation_controller, allocation_owner)) == 0
        end
    end
end
