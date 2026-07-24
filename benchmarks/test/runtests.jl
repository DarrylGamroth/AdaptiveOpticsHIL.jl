using AdaptiveOpticsHIL
using Clocks
using HdrHistogram
using Test

include(joinpath(
    normpath(joinpath(@__DIR__, "..")),
    "benchmark_gate4a_serial_boundary.jl"))

function cached_boundary_run(config)
    driver = Harness.prepare_boundary_driver(
        CachedNanoClock(0),
        Harness.Gate4AWorkloadConfig(),
        config)
    result = Harness.execute_boundary_run!(driver)
    @test Harness.validate_boundary_result(result, config)
    return result
end

function counter_signature(counters)
    return Tuple(
        getfield(counters, field)
        for field in fieldnames(typeof(counters)))
end

function deterministic_histogram_signature(result)
    return (
        HistogramArtifact.encode_sparse_histogram(
            result.histograms.publication_lateness),
        HistogramArtifact.encode_sparse_histogram(
            result.histograms.adapter_observation_delay),
        HistogramArtifact.encode_sparse_histogram(
            result.histograms.rtc_processing),
        HistogramArtifact.encode_sparse_histogram(
            result.histograms.command_admission_delay),
        HistogramArtifact.encode_sparse_histogram(
            result.histograms.command_application_delay),
        HistogramArtifact.encode_sparse_histogram(
            result.histograms.closed_loop_response),
    )
end

@testset "Gate 4A benchmark contract" begin
    contract = TOML.parsefile(DEFAULT_CONTRACT)
    @test validate_contract(contract)
    inconsistent_contract = deepcopy(contract)
    inconsistent_contract["workload"][
        "command_completion_capacity"] += 1
    @test_throws ErrorException validate_contract(
        inconsistent_contract)

    @test_throws ErrorException Harness.BoundaryRunConfig(samples=0)
    @test_throws ErrorException Harness.BoundaryRunConfig(
        samples=32, stall_start_sequence=16, stall_frames=17)
    @test_throws ErrorException Harness.Gate4AWorkloadConfig(
        primary_period_ns=0)

    histogram_config = Harness.HistogramConfig()
    histogram = HdrHistogram.Histogram(
        histogram_config.lowest_ns,
        histogram_config.highest_ns,
        histogram_config.significant_figures)
    for value in (0, 1, 7, 1_000, 75_000)
        HdrHistogram.record_value!(histogram, value)
    end
    encoded = HistogramArtifact.verified_sparse_histogram(
        histogram,
        histogram_config.lowest_ns,
        histogram_config.highest_ns,
        histogram_config.significant_figures,
        5)
    decoded = HistogramArtifact.decode_sparse_histogram(
        encoded["histogram_base64"],
        histogram_config.lowest_ns,
        histogram_config.highest_ns,
        histogram_config.significant_figures)
    @test HdrHistogram.total_count(decoded) == 5
    @test min(decoded) == min(histogram)
    @test max(decoded) == max(histogram)

    stalled_config = Harness.BoundaryRunConfig(
        samples=128,
        checkpoint_stride=16,
        stall_start_sequence=48,
        stall_frames=8)
    first_result = cached_boundary_run(stalled_config)
    second_result = cached_boundary_run(stalled_config)
    first_counters = first_result.counters
    @test first_counters.stall_end_offered -
        first_counters.stall_start_offered == 8
    @test first_counters.stall_end_observed ==
        first_counters.stall_start_observed
    @test first_counters.maximum_primary_occupancy >= 8
    @test first_counters.published_feedback ==
        first_counters.observed_feedback
    @test counter_signature(first_counters) ==
        counter_signature(second_result.counters)
    @test first_result.checkpoints[
        1:first_result.checkpoint_count] ==
        second_result.checkpoints[
            1:second_result.checkpoint_count]
    @test deterministic_histogram_signature(first_result) ==
        deterministic_histogram_signature(second_result)

    unpaced_config = Harness.BoundaryRunConfig(
        samples=128, checkpoint_stride=128)
    unpaced_result = cached_boundary_run(unpaced_config)
    @test unpaced_result.counters.commands_enqueued == 128
    @test unpaced_result.counters.commands_applied == 128
    @test unpaced_result.counters.command_responses == 128
    @test AdaptiveOpticsHIL.Serial.serial_run_is_quiescent(
        unpaced_result.accounting)

    @test Harness.measure_instrumentation_allocations(
        Harness.Gate4AWorkloadConfig(),
        histogram_config,
        1_000) == 0
end
