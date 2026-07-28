using AdaptiveOpticsHIL
using Base64
using Clocks
using HdrHistogram
using SHA
using Test
using TOML

include(joinpath(
    normpath(joinpath(@__DIR__, "..")),
    "benchmark_gate4a_serial_boundary.jl"))
include(joinpath(
    normpath(joinpath(@__DIR__, "..")),
    "benchmark_gate8_operational_runtime.jl"))

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
    @test encoded["histogram_sha256"] ==
        bytes2hex(SHA.sha256(
            Base64.base64decode(
                encoded["histogram_base64"])))
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
    observations = observation_report(
        [Dict("counters" => counter_snapshot(first_counters))],
        contract)
    @test !observations["product_lease_hold"][
        "qualified_as_absolute_gate"]
    @test observations["primary_completion_occupancy"][
        "maximum_observed"] ==
        first_counters.maximum_primary_occupancy

    unpaced_config = Harness.BoundaryRunConfig(
        samples=128, checkpoint_stride=128)
    unpaced_result = cached_boundary_run(unpaced_config)
    @test unpaced_result.counters.commands_enqueued == 128
    @test unpaced_result.counters.commands_applied == 128
    @test unpaced_result.counters.command_responses == 128
    @test AdaptiveOpticsHIL.Serial.serial_run_is_quiescent(
        unpaced_result.accounting)
    @test serial_ownership_is_drained(
        unpaced_result.accounting)

    @test Harness.measure_instrumentation_allocations(
        Harness.Gate4AWorkloadConfig(),
        histogram_config,
        1_000) == 0
end

@testset "Gate 8 operational benchmark contract" begin
    contract = TOML.parsefile(DEFAULT_GATE8_CONTRACT)
    @test validate_gate8_contract(contract)

    invalid_owner_count = deepcopy(contract)
    invalid_owner_count["execution_owner_count"] = 3
    @test_throws ErrorException validate_gate8_contract(
        invalid_owner_count)

    relaxed_latency = deepcopy(contract)
    relaxed_latency[
        "max_target_p99_publication_lateness_ns"] += 1
    @test_throws ErrorException validate_gate8_contract(
        relaxed_latency)

    invalid_science_capacity = deepcopy(contract)
    invalid_science_capacity["workload"][
        "science_completion_capacity"] += 1
    @test_throws ErrorException validate_gate8_contract(
        invalid_science_capacity)

    incomplete_compilation_coverage = deepcopy(contract)
    incomplete_compilation_coverage[
        "compilation_coverage_frames"] = 1
    @test_throws ErrorException validate_gate8_contract(
        incomplete_compilation_coverage)

    short_target = deepcopy(contract)
    short_target["target_samples_per_run"] =
        contract["minimum_samples_for_p99_9"] - 1
    @test_throws ErrorException validate_gate8_contract(
        short_target)

    workload = Operational.workload_from_contract(contract)
    @test workload.science_enabled
    @test workload.primary_period_ns ==
        contract["workload"]["primary_period_ns"]
    @test workload.science_period_ns ==
        contract["workload"]["science_period_ns"]
    @test workload.science_product_capacity ==
        contract["workload"]["science_product_capacity"]

    doubled_rate = workload_at_rate(
        workload, 2 * contract["target_rate_hz"])
    @test doubled_rate.primary_period_ns ==
        workload.primary_period_ns ÷ 2
    @test doubled_rate.science_enabled
    @test doubled_rate.science_period_ns ==
        workload.science_period_ns ÷ 2

    @test_throws ErrorException Operational.ProductTraceObserver(0)
    @test_throws ErrorException Operational.OperationalIntervalObserver(
        0, 1)
    @test_throws ErrorException Operational.OperationalIntervalObserver(
        1, 0)

    process = Operational.process_counters()
    for field in fieldnames(typeof(process))
        @test getfield(process, field) isa
            Union{Missing,Int64}
    end
end
