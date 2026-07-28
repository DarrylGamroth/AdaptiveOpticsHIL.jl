using AdaptiveOpticsHIL
using Clocks
using Test
using TOML

include(joinpath(
    normpath(joinpath(@__DIR__, "..")),
    "benchmark_gate8_operational_runtime.jl"))

Threads.nthreads(:default) >= 4 || error(
    "Gate 8 runtime smoke tests require at least four Julia threads")
Threads.nthreads(:interactive) == 0 || error(
    "Gate 8 runtime smoke tests require a disabled interactive pool")

const GATE8_TEST_CONTRACT =
    TOML.parsefile(DEFAULT_GATE8_CONTRACT)
const GATE8_TEST_HISTOGRAM =
    Operational.histogram_config_from_contract(
        GATE8_TEST_CONTRACT)
const GATE8_TEST_WORKLOAD =
    Operational.workload_from_contract(GATE8_TEST_CONTRACT)

@testset "Gate 8 secondary product numerical traces" begin
    observer = Operational.ProductTraceObserver(1)
    feedback = [1.25, -0.5]
    science = [-2.0, 3.5]
    Harness.observe_feedback_product!(
        observer, UInt64(1), Int64(2), Int64(3), Int64(4), feedback)
    Harness.observe_science_product!(
        observer, UInt64(1), Int64(5), Int64(6), Int64(7), science)
    feedback_record = only(Operational.feedback_trace(observer))
    science_record = only(Operational.science_trace(observer))
    @test feedback_record[5:6] == (
        reinterpret(UInt64, feedback[1]),
        reinterpret(UInt64, feedback[2]),
    )
    @test science_record[5:6] == (
        reinterpret(UInt64, science[1]),
        reinterpret(UInt64, science[2]),
    )
end

@testset "Gate 8 execution topology correctness" begin
    contract = deepcopy(GATE8_TEST_CONTRACT)
    contract["correctness_frames"] = 64
    report = exact_correctness_report(
        GATE8_TEST_WORKLOAD,
        GATE8_TEST_HISTOGRAM,
        contract)
    @test report["passed"]
    @test report["frames"] == 64
end

@testset "Gate 8 operational interval evidence" begin
    contract = deepcopy(GATE8_TEST_CONTRACT)
    contract["warmup_frames"] = 64
    contract["interval_ns"] = 10_000_000
    contract["minimum_samples_for_p99"] = 128
    execute_gate8_warmup!(
        GATE8_TEST_WORKLOAD,
        GATE8_TEST_HISTOGRAM,
        contract)
    run_config = Harness.BoundaryRunConfig(
        samples=256,
        checkpoint_stride=64)
    report = execute_recorded_run(
        GATE8_TEST_WORKLOAD,
        run_config,
        GATE8_TEST_HISTOGRAM,
        contract,
        Operational.agent_execution_configuration(
            contract);
        phase="ci_operational_smoke",
        run_index=1,
        agent_owned=true)
    @test length(report["intervals"]) >= 2
    @test report["intervals"][1][
        "achieved_offered_rate_hz"] > 0
    @test report["intervals"][1][
        "primary_headroom"] >= 0
    @test report["intervals"][1][
        "process_cpu_utilization"] != "unavailable"
    @test owner_tasks_are_stable(report)
    @test clean_lifecycle_accounting(report)
    lifecycle_timing = report["lifecycle"]["timing"]
    @test lifecycle_timing[
        "total_prepare_arm_start_ns"] ==
        lifecycle_timing["configuration_ns"] +
        lifecycle_timing["preparation_ns"] +
        lifecycle_timing["arm_ns"] +
        lifecycle_timing["start_ns"]
    @test lifecycle_timing["clean_stop_ns"] >= 0
    @test lifecycle_timing[
        "operational_wall_excludes_stop"]
    @test length(report["histograms"][
        "publication_lateness_ns"][
            "histogram_sha256"]) == 64
    unpaced = execute_unpaced_run(
        GATE8_TEST_WORKLOAD,
        run_config,
        GATE8_TEST_HISTOGRAM,
        contract,
        1)
    @test unpaced["useful_completed_rate_hz"] > 0
    @test !isempty(unpaced["intervals"])
    allocation_contract = deepcopy(contract)
    allocation_contract["allocation_frames"] = 256
    allocation = gate8_allocation_report(
        GATE8_TEST_WORKLOAD,
        GATE8_TEST_HISTOGRAM,
        allocation_contract)
    @test allocation["inclusive_bytes_per_frame"] <=
        allocation_contract[
            "max_inclusive_alloc_bytes_per_frame"]
    calibration_contract = deepcopy(contract)
    calibration_contract["calibration_iterations"] = 1_000
    calibration = gate8_calibration_report(
        GATE8_TEST_HISTOGRAM,
        calibration_contract,
        GATE8_TEST_WORKLOAD)
    @test calibration["samples"] == 1_000
end

@testset "Gate 8 required consumer interruption" begin
    run_config = Harness.BoundaryRunConfig(
        samples=256,
        checkpoint_stride=64,
        stall_start_sequence=128,
        stall_frames=16)
    result = Operational.execute_run(
        CachedNanoClock(0),
        GATE8_TEST_WORKLOAD,
        run_config,
        GATE8_TEST_HISTOGRAM,
        Operational.agent_execution_configuration(
            GATE8_TEST_CONTRACT))
    @test result.counters.stall_end_offered -
        result.counters.stall_start_offered == 16
    @test result.counters.stall_end_observed ==
        result.counters.stall_start_observed
    @test result.counters.dropped_primary == 0
    @test serial_ownership_is_drained(result.accounting)
end

@testset "Gate 8 optional science shedding and recovery" begin
    run_config = Harness.BoundaryRunConfig(
        samples=256,
        checkpoint_stride=64,
        science_stall_start_sequence=32,
        science_stall_frames=64)
    result = Operational.execute_run(
        CachedNanoClock(0),
        GATE8_TEST_WORKLOAD,
        run_config,
        GATE8_TEST_HISTOGRAM,
        Operational.agent_execution_configuration(
            GATE8_TEST_CONTRACT))
    @test Operational.validate_agent_owner_result(
        result,
        GATE8_TEST_CONTRACT["execution_owner_count"])
    @test result.counters.shed_science >= 8
    @test result.counters.science_sequence_gaps ==
        result.counters.shed_science
    @test result.counters.science_recovery_count >= 1
    @test serial_ownership_is_drained(result.accounting)
end

@testset "Gate 8 bounded required overload" begin
    contract = deepcopy(GATE8_TEST_CONTRACT)
    contract["overload_maximum_offered"] = 4_096
    contract["execution_owner_maximum_lateness_ns"] = 1_000_000
    contract["interval_ns"] = 1_000_000
    overload_workload = workload_at_rate(
        GATE8_TEST_WORKLOAD,
        100_000;
        preserve_capacity_time_headroom=true)
    result = Operational.execute_required_overload(
        contract,
        overload_workload,
        GATE8_TEST_HISTOGRAM)
    report = overload_report(result, 100_000, overload_workload)
    @test !isempty(report["intervals"])
    @test report["first_failure"]["kind"] ==
        "ResourcePolicyRunFailure"
    @test report["ingress_closed"]
    @test report["accounting"]["ownership_drained"]
end

@testset "Gate 8 injected execution-owner failure" begin
    contract = deepcopy(GATE8_TEST_CONTRACT)
    contract["injected_failure_batch_sequence"] = 16
    contract["correctness_frames"] = 32
    result = Operational.execute_injected_owner_failure(
        contract,
        GATE8_TEST_HISTOGRAM;
        clock=CachedNanoClock(0))
    @test result.trigger_batch_sequence == 16
    @test AdaptiveOpticsHIL.Lifecycle.run_failure_stage(
        result.failure) ==
        AdaptiveOpticsHIL.Lifecycle.OwnerBeforeDequeue
    @test AdaptiveOpticsHIL.Lifecycle.run_failure_reason(
        result.failure) == :Gate8InjectedOwnerFailure
    @test serial_ownership_is_drained(result.accounting)
    @test !AdaptiveOpticsHIL.Serial.serial_run_is_quiescent(
        result.accounting)
end

@testset "Gate 8 named drain deficit" begin
    result = Operational.execute_named_drain_deficit(
        GATE8_TEST_CONTRACT)
    @test result.failure.drain_timed_out
    wfs = only(
        acquisition
        for acquisition in result.accounting.acquisitions
        if acquisition.acquisition.name == :hil_wfs)
    @test wfs.products.consumer_leased == 1
    @test serial_ownership_is_drained(
        result.cleanup_accounting)
end
