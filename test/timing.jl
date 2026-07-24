using AdaptiveOpticsHIL.Timing
using AdaptiveOpticsSim.Plant: PlantTimestamp
using Clocks

struct WrongWidthNanoClock <: Clocks.AbstractNanoClock end
Clocks.time_nanos(::WrongWidthNanoClock) = Int32(0)

const TIMING_TESTS_WITH_COVERAGE =
    Base.JLOptions().code_coverage != 0

function timing_allocation_bytes(mapping, target)
    execution_lateness_ns(mapping, target)
    execution_time_until_ns(mapping, target)
    lateness_bytes = @allocated execution_lateness_ns(mapping, target)
    time_until_bytes = @allocated execution_time_until_ns(mapping, target)
    return lateness_bytes, time_until_bytes
end

@testset "Execution-clock mapping" begin
    @testset "Exact deterministic timing" begin
        clock = CachedNanoClock(1_000)
        origin = PlantTimestamp(100)
        mapping = @inferred arm_execution_clock(clock, origin)
        target = PlantTimestamp(350)

        @test mapping isa ExecutionClockMapping{CachedNanoClock}
        @test @inferred(execution_clock(mapping)) === clock
        @test @inferred(plant_time_origin(mapping)) == origin
        @test @inferred(execution_clock_origin_ns(mapping)) == 1_000

        @test @inferred(execution_lateness_ns(mapping, target)) == -250
        @test @inferred(execution_time_until_ns(mapping, target)) == 250

        advance!(clock, 250)
        @test execution_lateness_ns(mapping, target) == 0
        @test execution_time_until_ns(mapping, target) == 0

        advance!(clock, 7)
        @test execution_lateness_ns(mapping, target) == 7
        @test execution_time_until_ns(mapping, target) == -7
        if TIMING_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test timing_allocation_bytes(mapping, target) == (0, 0)
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
            SystemNanoClock(), PlantTimestamp(0))
        first_elapsed = @inferred execution_lateness_ns(
            mapping, PlantTimestamp(0))
        second_elapsed = @inferred execution_lateness_ns(
            mapping, PlantTimestamp(0))
        @test first_elapsed >= 0
        @test second_elapsed >= first_elapsed
    end
end
