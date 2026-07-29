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

const BENCHMARK_TEST_GROUPS = (
    "gate4a",
    "gate4a-allocation",
    "gate8",
)

function selected_benchmark_test_groups(arguments)
    isempty(arguments) && return Set(BENCHMARK_TEST_GROUPS)
    requested = Set(String(argument) for argument in arguments)
    unsupported = sort!(collect(
        setdiff(requested, Set(BENCHMARK_TEST_GROUPS))))
    isempty(unsupported) || error(
        "unknown benchmark test group(s): " *
        "$(join(unsupported, ", ")); choose from " *
        join(BENCHMARK_TEST_GROUPS, ", "),
    )
    return requested
end

const SELECTED_BENCHMARK_TEST_GROUPS =
    selected_benchmark_test_groups(ARGS)

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

mutable struct DeadlineCrossingObserver{
    C<:Clocks.CachedNanoClock,
} <: Harness.AbstractBoundaryObserver
    clock::C
    delay_ns::Int64
    crossed::Bool
    phase_after_crossing::Union{
        Nothing,
        Harness.ControllerPhase,
    }
end

DeadlineCrossingObserver(
    clock::Clocks.CachedNanoClock,
    delay_ns::Integer,
) = DeadlineCrossingObserver(
    clock,
    Int64(delay_ns),
    false,
    nothing,
)

function Harness.observe_primary_product!(
    observer::DeadlineCrossingObserver,
    ::UInt64,
    ::Int64,
    ::Int64,
    ::Int64,
    ::Any,
)
    observer.crossed && return nothing
    Clocks.advance!(observer.clock, observer.delay_ns)
    observer.crossed = true
    return nothing
end

function Harness.observe_boundary_step!(
    observer::DeadlineCrossingObserver,
    driver,
    ::Any,
    ::Int64,
)
    observer.crossed || return nothing
    observer.phase_after_crossing === nothing || return nothing
    observer.phase_after_crossing = driver.phase
    return nothing
end

mutable struct CatchupProgressObserver <:
        Harness.AbstractBoundaryObserver
    serviced_during_plant_event::Bool
    idle_with_pending_primary::Bool
end

CatchupProgressObserver() =
    CatchupProgressObserver(false, false)

function Harness.observe_boundary_step!(
    observer::CatchupProgressObserver,
    driver,
    result,
    ::Int64,
)
    AdaptiveOpticsHIL.Serial.serial_step_status(result) ==
        AdaptiveOpticsHIL.Serial.SerialPlantEventProcessed ||
        return nothing
    primary_occupancy =
        AdaptiveOpticsHIL.Ports.descriptor_accounting(
            driver.fixture.wfs_port).occupancy
    if driver.phase == Harness.ControllerIdle &&
            primary_occupancy > 0
        observer.idle_with_pending_primary = true
    end
    if driver.phase == Harness.ControllerCommandSubmitted &&
            driver.counters.commands_enqueued > 0
        observer.serviced_during_plant_event = true
    end
    return nothing
end

if "gate4a" in SELECTED_BENCHMARK_TEST_GROUPS
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

    crossing_clock = CachedNanoClock(0)
    crossing_workload = Harness.Gate4AWorkloadConfig()
    crossing_observer = DeadlineCrossingObserver(
        crossing_clock,
        2 * crossing_workload.primary_period_ns,
    )
    crossing_config = Harness.BoundaryRunConfig(
        samples=32,
        checkpoint_stride=32,
    )
    crossing_driver = Harness.prepare_boundary_driver(
        crossing_clock,
        crossing_workload,
        crossing_config;
        observer=crossing_observer,
    )
    crossing_result =
        Harness.execute_boundary_run!(crossing_driver)
    @test Harness.validate_boundary_result(
        crossing_result, crossing_config)
    @test crossing_observer.phase_after_crossing ==
        Harness.ControllerCommandSubmitted

    catchup_clock = CachedNanoClock(0)
    catchup_workload = Harness.Gate4AWorkloadConfig(
        primary_product_capacity=4,
        feedback_product_capacity=4,
    )
    catchup_config = Harness.BoundaryRunConfig(
        samples=32,
        checkpoint_stride=32,
    )
    catchup_observer = CatchupProgressObserver()
    catchup_driver = Harness.prepare_boundary_driver(
        catchup_clock,
        catchup_workload,
        catchup_config;
        observer=catchup_observer,
    )
    Clocks.advance!(
        catchup_clock,
        catchup_workload.primary_product_capacity *
            catchup_workload.primary_period_ns,
    )
    catchup_result =
        Harness.execute_boundary_run!(catchup_driver)
    @test Harness.validate_boundary_result(
        catchup_result, catchup_config)
    @test catchup_result.counters.command_responses ==
        catchup_config.samples
    @test catchup_observer.serviced_during_plant_event
    @test !catchup_observer.idle_with_pending_primary

end
end

if "gate4a-allocation" in SELECTED_BENCHMARK_TEST_GROUPS
@testset "Gate 4A optimized allocation contract" begin
    @test Harness.measure_instrumentation_allocations(
        Harness.Gate4AWorkloadConfig(),
        Harness.HistogramConfig(),
        1_000) == 0
end
end

if "gate8" in SELECTED_BENCHMARK_TEST_GROUPS
@testset "Gate 8 operational benchmark contract" begin
    contract = TOML.parsefile(DEFAULT_GATE8_CONTRACT)
    @test validate_gate8_contract(contract)

    semantic_fields = semantic_counter_field_names()
    @test semantic_fields isa Vector{String}
    @test length(semantic_fields) ==
        length(GATE8_SEMANTIC_COUNTER_FIELDS)
    semantic_buffer = IOBuffer()
    TOML.print(
        semantic_buffer,
        Dict("semantic_counter_fields" => semantic_fields);
        sorted=true)
    @test TOML.parse(String(take!(semantic_buffer)))[
        "semantic_counter_fields"] == semantic_fields

    mktempdir() do directory
        invalid_path = joinpath(directory, "invalid.toml")
        @test_throws ErrorException _write_toml_atomically(
            invalid_path,
            Dict("unsupported_tuple" => ("one", "two")))
        @test !isfile(invalid_path)

        valid_path = joinpath(directory, "valid.toml")
        _write_toml_atomically(
            valid_path,
            Dict("values" => ["one", "two"]))
        @test TOML.parsefile(valid_path)["values"] ==
            ["one", "two"]
    end

    invalid_owner_count = deepcopy(contract)
    invalid_owner_count["execution_owner_count"] = 3
    @test_throws ErrorException validate_gate8_contract(
        invalid_owner_count)

    invalid_scheduler_priority = deepcopy(contract)
    invalid_scheduler_priority[
        "execution_scheduler_priority"] = 19
    @test_throws ErrorException validate_gate8_contract(
        invalid_scheduler_priority)

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

    insufficient_overload_drive = deepcopy(contract)
    insufficient_overload_drive["overload_rate_hz"] = 8_000
    @test_throws ErrorException validate_gate8_contract(
        insufficient_overload_drive)

    short_target = deepcopy(contract)
    short_target["target_samples_per_run"] =
        contract["minimum_samples_for_p99_9"] - 1
    @test_throws ErrorException validate_gate8_contract(
        short_target)

    workload = Operational.workload_from_contract(contract)
    @test contract["minimum_calibrated_rate_hz"] == 4_500
    @test contract["minimum_calibrated_rate_hz"] >=
        2 * contract["target_rate_hz"]
    @test contract["near_saturation_rate_hz"] == 3_000
    @test contract["saturation_rate_hz"] == 4_000
    @test contract["overload_rate_hz"] == 12_000
    @test contract["target_rate_hz"] <
        contract["near_saturation_rate_hz"] <
        contract["saturation_rate_hz"] <=
        contract["minimum_calibrated_rate_hz"]
    @test workload.science_enabled
    @test workload.primary_period_ns ==
        contract["workload"]["primary_period_ns"]
    @test workload.science_period_ns ==
        contract["workload"]["science_period_ns"]
    @test workload.science_product_capacity ==
        contract["workload"]["science_product_capacity"]
    required_horizon_ns =
        contract["required_product_capacity_horizon_ns"]
    @test workload.primary_product_capacity == 128
    @test contract["workload"]["primary_completion_capacity"] == 128
    @test workload.feedback_product_capacity == 86
    @test contract["workload"]["feedback_completion_capacity"] == 86
    @test workload.primary_product_capacity *
        workload.primary_period_ns >= required_horizon_ns
    @test (workload.primary_product_capacity - 1) *
        workload.primary_period_ns < required_horizon_ns
    @test workload.feedback_product_capacity *
        workload.feedback_period_ns >= required_horizon_ns
    @test (workload.feedback_product_capacity - 1) *
        workload.feedback_period_ns < required_horizon_ns

    science_stall_config = Harness.BoundaryRunConfig(
        samples=128,
        checkpoint_stride=128,
        science_stall_start_sequence=32,
        science_stall_frames=64,
    )
    science_stall_driver = Operational.prepare_driver(
        CachedNanoClock(0),
        workload,
        science_stall_config,
        Operational.histogram_config_from_contract(contract),
        AdaptiveOpticsHIL.Execution.SerialOpticalExecution(),
    )
    science_stall_driver.counters.offered_primary = UInt64(128)
    science_stall_driver.counters.published_primary = UInt64(31)
    Harness._update_science_stall_state!(science_stall_driver)
    @test !science_stall_driver.science_stall_started
    science_stall_driver.counters.published_primary = UInt64(32)
    Harness._update_science_stall_state!(science_stall_driver)
    @test science_stall_driver.science_stall_started
    @test !science_stall_driver.science_stall_ended
    science_stall_driver.counters.published_primary = UInt64(96)
    Harness._update_science_stall_state!(science_stall_driver)
    @test science_stall_driver.science_stall_ended
    @test science_stall_driver.counters.
        science_stall_start_offered == UInt64(128)
    @test science_stall_driver.counters.
        science_stall_end_offered == UInt64(128)
    Harness._stop_instrumentation_driver!(science_stall_driver)

    soak_samples = minimum_soak_sample_count(
        contract, workload)
    soak_horizon_ns =
        workload.primary_exposure_ns +
        (soak_samples - 1) * workload.primary_period_ns
    @test contract["soak_schedule_guard_ns"] == 10_000_000
    @test soak_samples == 600_021
    @test soak_horizon_ns >=
        contract["soak_duration_ns"] +
        contract["soak_schedule_guard_ns"]
    @test soak_horizon_ns -
        workload.primary_period_ns <
        contract["soak_duration_ns"] +
        contract["soak_schedule_guard_ns"]

    latency_report(run, p99_ns, p99_9_ns) = Dict{String,Any}(
        "run" => run,
        "histograms" => Dict{String,Any}(
            metric => Dict{String,Any}(
                "p99_ns" => p99_ns,
                "p99_9_ns" => p99_9_ns)
            for metric in (
                "publication_lateness_ns",
                "adapter_observation_delay_ns",
                "closed_loop_response_ns",
            )))
    latency = target_latency_gate(
        [
            latency_report(1, 10, 100),
            latency_report(2, 20, 200),
            latency_report(3, 30, 300),
        ],
        contract)
    publication =
        latency["publication_lateness_ns"]
    @test publication["worst_p99_ns"] == 30
    @test publication["worst_p99_9_ns"] == 300
    @test [run["run"] for run in publication["runs"]] ==
        [1, 2, 3]

    overload = Dict{String,Any}(
        "first_failure" => Dict{String,Any}(
            "kind" => "ResourcePolicyRunFailure"),
        "start_to_failure_ns" => 3_000_000_000,
        "violation_to_failure_ns" => 0,
        "violation_observation_is_failure_boundary" => true,
        "ingress_closed" => true,
        "failure_to_acknowledgement_ns" => 100,
        "failure_to_shutdown_ns" => 200,
        "failure_accounting" => Dict{String,Any}(
            "owners" => [
                Dict{String,Any}(
                    "acknowledged" => true,
                    "acknowledgement_timed_out" => false)
                for _ in 1:2
            ]),
        "accounting" => Dict{String,Any}(
            "ownership_drained" => true))
    overload_gate = required_overload_gate(
        overload, contract)
    @test overload_gate["passed"]
    @test overload_gate["start_to_failure_is_diagnostic"]
    @test overload_gate[
        "maximum_violation_to_failure_ns"] ==
        contract["overload_failure_bound_ns"]
    overload["accounting"]["ownership_drained"] = false
    @test !required_overload_gate(
        overload, contract)["passed"]

    doubled_rate = workload_at_rate(
        workload, 2 * contract["target_rate_hz"])
    @test doubled_rate.primary_period_ns ==
        workload.primary_period_ns ÷ 2
    @test doubled_rate.science_enabled
    @test doubled_rate.science_period_ns ==
        workload.science_period_ns ÷ 2
    @test doubled_rate.primary_product_capacity ==
        workload.primary_product_capacity

    doubled_rate_with_time_headroom = workload_at_rate(
        workload,
        2 * contract["target_rate_hz"];
        preserve_capacity_time_headroom=true)
    @test doubled_rate_with_time_headroom.command_capacity ==
        2 * workload.command_capacity
    @test doubled_rate_with_time_headroom.primary_product_capacity ==
        2 * workload.primary_product_capacity
    @test doubled_rate_with_time_headroom.feedback_product_capacity ==
        2 * workload.feedback_product_capacity
    @test doubled_rate_with_time_headroom.science_product_capacity ==
        2 * workload.science_product_capacity

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
end
