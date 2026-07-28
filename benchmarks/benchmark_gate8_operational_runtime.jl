const GATE8_PACKAGE_LOAD_START_NS = time_ns()

if !isdefined(@__MODULE__, :Gate4ABoundaryHarness)
    include("benchmark_gate4a_serial_boundary.jl")
end
if !isdefined(@__MODULE__, :Gate8OperationalHarness)
    include(joinpath(
        BENCHMARK_ROOT,
        "support",
        "gate8_operational_harness.jl"))
end

const GATE8_PACKAGE_LOAD_NS =
    Int(time_ns() - GATE8_PACKAGE_LOAD_START_NS)
const Operational = Gate8OperationalHarness
const DEFAULT_GATE8_CONTRACT = joinpath(
    BENCHMARK_ROOT,
    "contracts",
    "gate8_operational_runtime.toml")

const GATE8_FROZEN_CONTRACT_VALUES = (
    "julia_threads" => 4,
    "julia_interactive_threads" => 0,
    "blas_threads" => 1,
    "fft_threads" => 1,
    "execution_owner_count" => 2,
    "execution_owner_ring_capacity" => 8,
    "execution_owner_idle_spin_count" => 32,
    "execution_owner_maximum_lateness_ns" => 50_000_000,
    "arm_timeout_ns" => 5_000_000_000,
    "correctness_frames" => 1_024,
    "compilation_coverage_frames" => 2,
    "warmup_frames" => 5_000,
    "baseline_runs" => 3,
    "baseline_samples_per_run" => 20_000,
    "target_rate_hz" => 2_000,
    "target_runs" => 3,
    "target_samples_per_run" => 100_000,
    "burst_samples" => 100_000,
    "burst_start_sequence" => 50_000,
    "burst_frames" => 16,
    "science_shed_samples" => 12_000,
    "science_stall_start_sequence" => 1_000,
    "science_stall_primary_frames" => 64,
    "science_recovery_frames" => 10_000,
    "calibration_runs" => 3,
    "calibration_samples_per_run" => 100_000,
    "minimum_calibrated_rate_hz" => 5_000,
    "derived_rate_preserve_capacity_time_headroom" => true,
    "near_saturation_fraction" => 0.70,
    "saturation_fraction" => 0.85,
    "overload_fraction" => 1.25,
    "rate_rounding_hz" => 100,
    "near_saturation_runs" => 3,
    "near_saturation_samples_per_run" => 100_000,
    "saturation_runs" => 3,
    "saturation_samples_per_run" => 100_000,
    "overload_maximum_offered" => 100_000,
    "overload_failure_bound_ns" => 2_000_000_000,
    "recovery_samples" => 20_000,
    "injected_failure_runs" => 3,
    "injected_failure_batch_sequence" => 64,
    "acknowledgement_timeout_ns" => 1_000_000_000,
    "drain_timeout_ns" => 2_000_000_000,
    "deficit_drain_timeout_ns" => 10_000_000,
    "soak_duration_ns" => 300_000_000_000,
    "soak_minimum_samples" => 500_000,
    "interval_ns" => 1_000_000_000,
    "minimum_samples_for_p99" => 10_000,
    "minimum_samples_for_p99_9" => 100_000,
    "histogram_lowest_ns" => 1,
    "histogram_highest_ns" => 60_000_000_000,
    "histogram_significant_figures" => 3,
    "calibration_iterations" => 1_000_000,
    "checkpoint_stride" => 1_000,
    "allocation_frames" => 10_000,
    "max_instrumentation_alloc_bytes" => 0,
    "max_inclusive_alloc_bytes_per_frame" => 16_384,
    "max_gc_fraction" => 0.05,
    "max_target_rate_error_fraction" => 0.005,
    "max_derived_rate_error_fraction" => 0.01,
    "max_target_p99_publication_lateness_ns" => 500_000,
    "max_target_p99_observation_delay_ns" => 500_000,
    "max_target_p99_closed_loop_response_ns" => 1_000_000,
    "max_target_p99_9_publication_lateness_ns" => 2_000_000,
    "max_target_p99_9_observation_delay_ns" => 2_000_000,
    "max_target_p99_9_closed_loop_response_ns" => 4_000_000,
    "relative_multiplier" => 4.0,
    "relative_publication_floor_ns" => 250_000,
    "relative_observation_floor_ns" => 250_000,
    "relative_response_floor_ns" => 500_000,
    "future_baseline_multiplier" => 1.25,
    "future_baseline_floor_ns" => 50_000,
)

const GATE8_FROZEN_WORKLOAD_VALUES = (
    "provider" => "LinearReducedOrderAcquisitionModel",
    "backend" => "CPUBackend",
    "numeric_type" => "Float64",
    "run_seed" => 31_744,
    "controller" => "two-mode integral controller",
    "controller_gain" => 0.65,
    "primary_acquisition" => "hil_wfs",
    "primary_period_ns" => 500_000,
    "primary_exposure_ns" => 100_000,
    "primary_optical_sample_period_ns" => 100_000,
    "feedback_acquisition" => "hil_dm_feedback",
    "feedback_period_ns" => 750_000,
    "feedback_phase_ns" => 125_000,
    "feedback_exposure_ns" => 100_000,
    "science_acquisition" => "hil_science",
    "science_period_ns" => 2_000_000,
    "science_exposure_ns" => 500_000,
    "science_optical_sample_period_ns" => 1_000_000,
    "command_endpoint" => "hil_dm",
    "command_payload_elements" => 2,
    "command_payload_bytes" => 16,
    "command_payload_pool_capacity" => 8,
    "command_submission_capacity" => 8,
    "command_completion_capacity" => 8,
    "primary_product_capacity" => 64,
    "primary_completion_capacity" => 64,
    "feedback_product_capacity" => 64,
    "feedback_completion_capacity" => 64,
    "science_product_capacity" => 8,
    "science_completion_capacity" => 8,
    "complete_product_lead_time_ns" => 500_000,
    "maximum_lease_hold_time_ns" => 2_000_000,
)

function parse_gate8_arguments(arguments)
    contract_path = DEFAULT_GATE8_CONTRACT
    output_path = nothing
    index = 1
    while index <= length(arguments)
        argument = arguments[index]
        if argument == "--contract"
            index < length(arguments) || error(
                "--contract requires a path")
            index += 1
            contract_path = abspath(arguments[index])
        elseif argument == "--output"
            index < length(arguments) || error(
                "--output requires a path")
            index += 1
            output_path = abspath(arguments[index])
        else
            error("unknown Gate 8 benchmark argument: $argument")
        end
        index += 1
    end
    output_path === nothing && error(
        "durable Gate 8 evidence requires an explicit --output path")
    return (; contract_path, output_path)
end

function validate_gate8_contract(contract)
    contract["schema_version"] == 1 || error(
        "unsupported Gate 8 operational contract schema")
    for (key, expected) in GATE8_FROZEN_CONTRACT_VALUES
        isequal(contract[key], expected) || error(
            "Gate 8 protocol field $key changed from its frozen value")
    end
    workload = contract["workload"]
    for (key, expected) in GATE8_FROZEN_WORKLOAD_VALUES
        isequal(workload[key], expected) || error(
            "Gate 8 workload field $key changed from its frozen value")
    end
    contract["execution_owner_count"] == 2 || error(
        "the predeclared Gate 8 topology requires exactly two owners")
    contract["julia_threads"] == 4 || error(
        "the frozen Gate 8 topology requires exactly four Julia threads")
    contract["julia_interactive_threads"] == 0 || error(
        "the frozen Gate 8 topology disables the interactive thread pool")
    contract["blas_threads"] == 1 || error(
        "the frozen Gate 8 topology requires one BLAS thread")
    contract["fft_threads"] == 1 || error(
        "the frozen Gate 8 topology requires one FFT-provider thread")
    contract["execution_owner_ring_capacity"] == 8 || error(
        "the frozen Gate 8 owner-ring capacity is eight")
    contract["execution_owner_idle_spin_count"] == 32 || error(
        "the frozen Gate 8 hybrid idle policy spins 32 times")
    contract["execution_owner_maximum_lateness_ns"] ==
        50_000_000 || error(
            "the amended Gate 8 owner watchdog is 50 ms")
    contract["target_runs"] >= 3 || error(
        "target evidence requires at least three repetitions")
    contract["baseline_runs"] >= 3 || error(
        "comparable baseline evidence requires at least three repetitions")
    contract["calibration_runs"] >= 3 || error(
        "capacity calibration requires at least three repetitions")
    contract["near_saturation_runs"] >= 3 || error(
        "near-saturation evidence requires at least three repetitions")
    contract["saturation_runs"] >= 3 || error(
        "saturation evidence requires at least three repetitions")
    contract["injected_failure_runs"] >= 3 || error(
        "injected failure evidence requires at least three repetitions")
    contract["target_samples_per_run"] >=
        contract["minimum_samples_for_p99_9"] || error(
        "target runs are too short for p99.9")
    contract["burst_samples"] >=
        contract["minimum_samples_for_p99_9"] || error(
        "burst run is too short for p99.9")
    contract["near_saturation_samples_per_run"] >=
        contract["minimum_samples_for_p99_9"] || error(
        "near-saturation runs are too short for p99.9")
    contract["saturation_samples_per_run"] >=
        contract["minimum_samples_for_p99_9"] || error(
        "saturation runs are too short for p99.9")
    contract["baseline_samples_per_run"] >=
        contract["minimum_samples_for_p99"] || error(
        "deterministic baselines are too short for p99")
    contract["burst_frames"] > 0 || error(
        "the consumer-interruption burst must be nonempty")
    contract["science_stall_primary_frames"] == 64 || error(
        "the frozen optional science stall must span 32 ms at 2 kHz")
    contract["science_shed_samples"] >=
        contract["science_stall_start_sequence"] +
        contract["science_stall_primary_frames"] +
        contract["science_recovery_frames"] || error(
            "the science phase does not retain its declared recovery tail")
    0 < contract["near_saturation_fraction"] <
        contract["saturation_fraction"] < 1 || error(
            "near-saturation and saturation fractions are inconsistent")
    contract["overload_fraction"] > 1 || error(
        "bounded overload must exceed calibrated capacity")
    contract["soak_duration_ns"] >= 300_000_000_000 || error(
        "the Gate 8 soak must last at least 300 seconds")
    contract["soak_minimum_samples"] >=
        contract["minimum_samples_for_p99_9"] || error(
            "the soak is too short for p99.9")
    workload["provider"] ==
        "LinearReducedOrderAcquisitionModel" || error(
            "Gate 8 requires the frozen reduced-order provider")
    workload["backend"] == "CPUBackend" || error(
        "Gate 8 operational evidence is CPU-only")
    workload["numeric_type"] == "Float64" || error(
        "Gate 8 requires the frozen Float64 workload")
    workload["run_seed"] == 31_744 || error(
        "Gate 8 requires the frozen deterministic seed")
    workload["primary_product_capacity"] == 64 || error(
        "the frozen required WFS capacity is 64")
    workload["feedback_product_capacity"] == 64 || error(
        "the frozen required feedback capacity is 64")
    workload["science_product_capacity"] == 8 || error(
        "the frozen optional science capacity is eight")
    workload["command_payload_pool_capacity"] == 8 || error(
        "the frozen command capacity is eight")
    workload["primary_optical_sample_period_ns"] == 100_000 || error(
        "the frozen WFS-path optical sample rate is 10 kHz")
    workload["science_optical_sample_period_ns"] == 1_000_000 || error(
        "the frozen science-path optical sample rate is 1 kHz")
    workload["science_period_ns"] == 2_000_000 || error(
        "the frozen science product rate is 500 Hz")
    compilation_coverage_horizon_ns =
        workload["primary_exposure_ns"] +
        (contract["compilation_coverage_frames"] - 1) *
            workload["primary_period_ns"]
    compilation_coverage_horizon_ns >= max(
        workload["feedback_phase_ns"] +
            workload["feedback_exposure_ns"],
        workload["science_exposure_ns"]) || error(
            "the compilation fixture does not reach every acquisition stream")
    workload["command_payload_pool_capacity"] ==
        workload["command_submission_capacity"] ==
        workload["command_completion_capacity"] || error(
        "command pool and descriptor capacities must match")
    workload["primary_product_capacity"] ==
        workload["primary_completion_capacity"] || error(
        "primary product and descriptor capacities must match")
    workload["feedback_product_capacity"] ==
        workload["feedback_completion_capacity"] || error(
        "feedback product and descriptor capacities must match")
    workload["science_product_capacity"] ==
        workload["science_completion_capacity"] || error(
        "science product and descriptor capacities must match")
    workload["command_payload_bytes"] ==
        workload["command_payload_elements"] * sizeof(Float64) || error(
        "command payload byte count is inconsistent")
    1_000_000_000 ÷ workload["primary_period_ns"] ==
        contract["target_rate_hz"] || error(
            "target rate and primary period are inconsistent")
    burst_duration_ns =
        contract["burst_frames"] *
        workload["primary_period_ns"]
    required_stall_capacity = cld(
        contract["target_rate_hz"] * burst_duration_ns,
        1_000_000_000)
    workload["primary_product_capacity"] >=
        4 * required_stall_capacity || error(
            "required WFS capacity lacks the predeclared 4x stall margin")
    science_stall_duration_ns =
        contract["science_stall_primary_frames"] *
        workload["primary_period_ns"]
    science_products_during_stall = fld(
        science_stall_duration_ns,
        workload["science_period_ns"])
    science_products_during_stall -
        workload["science_product_capacity"] >= 8 || error(
            "optional science stall cannot force eight prepared sheds")
    return true
end

function workload_at_rate(
    base::Harness.Gate4AWorkloadConfig,
    requested_rate_hz::Real;
    preserve_capacity_time_headroom::Bool=false)
    isfinite(requested_rate_hz) && requested_rate_hz > 0 || error(
        "requested fixed-arrival rate must be finite and positive")
    primary_period_ns = max(
        1,
        round(Int, 1.0e9 / requested_rate_hz))
    scale(value) = max(
        1,
        round(Int,
            value * primary_period_ns /
            base.primary_period_ns))
    feedback_period_ns = scale(base.feedback_period_ns)
    feedback_phase_ns = min(
        feedback_period_ns - 1,
        scale(base.feedback_phase_ns))
    scale_capacity(value) =
        preserve_capacity_time_headroom ?
        max(
            value,
            cld(
                value * base.primary_period_ns,
                primary_period_ns)) :
        value
    return Harness.Gate4AWorkloadConfig(
        primary_period_ns=primary_period_ns,
        primary_exposure_ns=scale(base.primary_exposure_ns),
        optical_sample_period_ns=
            scale(base.optical_sample_period_ns),
        feedback_period_ns=feedback_period_ns,
        feedback_phase_ns=feedback_phase_ns,
        feedback_exposure_ns=scale(base.feedback_exposure_ns),
        science_enabled=base.science_enabled,
        science_sample_period_ns=
            scale(base.science_sample_period_ns),
        science_period_ns=scale(base.science_period_ns),
        science_exposure_ns=scale(base.science_exposure_ns),
        command_capacity=scale_capacity(base.command_capacity),
        primary_product_capacity=
            scale_capacity(base.primary_product_capacity),
        feedback_product_capacity=
            scale_capacity(base.feedback_product_capacity),
        science_product_capacity=
            scale_capacity(base.science_product_capacity),
        complete_product_lead_time_ns=
            base.complete_product_lead_time_ns,
        maximum_lease_hold_time_ns=
            base.maximum_lease_hold_time_ns,
        controller_gain=base.controller_gain,
        run_seed=base.run_seed)
end

effective_primary_rate_hz(workload) =
    1.0e9 / workload.primary_period_ns

function workload_capacity_snapshot(workload)
    return Dict{String,Any}(
        "command_payload_pool_capacity" =>
            workload.command_capacity,
        "command_submission_capacity" =>
            workload.command_capacity,
        "command_completion_capacity" =>
            workload.command_capacity,
        "primary_product_capacity" =>
            workload.primary_product_capacity,
        "primary_completion_capacity" =>
            workload.primary_product_capacity,
        "feedback_product_capacity" =>
            workload.feedback_product_capacity,
        "feedback_completion_capacity" =>
            workload.feedback_product_capacity,
        "science_product_capacity" =>
            workload.science_product_capacity,
        "science_completion_capacity" =>
            workload.science_product_capacity)
end

function gate8_counter_snapshot(counters)
    return counter_snapshot(counters)
end

function overload_snapshot(overload)
    return Dict{String,Any}(
        "acquisition" => string(overload.acquisition.name),
        "last_sequence" => Int(overload.last_sequence),
        "products_published" => Int(overload.products_published),
        "products_shed" => Int(overload.products_shed),
        "products_failed" => Int(overload.products_failed),
        "overload_episodes" => Int(overload.overload_episodes),
        "recovery_count" => Int(overload.recovery_count),
        "current_descriptor_occupancy" =>
            overload.current_descriptor_occupancy,
        "maximum_descriptor_occupancy" =>
            overload.maximum_descriptor_occupancy,
        "current_product_occupancy" =>
            overload.current_product_occupancy,
        "maximum_product_occupancy" =>
            overload.maximum_product_occupancy,
        "latest_lateness_ns" => overload.latest_lateness_ns,
        "maximum_lateness_ns" => overload.maximum_lateness_ns,
        "overloaded" => overload.overloaded,
        "recovered_to_threshold" =>
            overload.recovered_to_threshold,
        "decision" => string(overload.decision))
end

artifact_unsigned_identity(value::Unsigned) =
    "0x" * string(value; base=16, pad=2 * sizeof(value))

function execution_owner_snapshot(owner)
    return Dict{String,Any}(
        "id" => artifact_unsigned_identity(
            AdaptiveOpticsHIL.Execution.execution_owner_id_value(
                owner.id)),
        "due_occupancy" => owner.due.occupancy,
        "completion_occupancy" => owner.completion.occupancy,
        "work_submitted" => Int(owner.work_submitted),
        "work_taken" => Int(owner.work_taken),
        "active_batch_sequence" =>
            Int(owner.active_batch_sequence),
        "work_completed" => Int(owner.work_completed),
        "work_failed" => Int(owner.work_failed),
        "work_cancelled" => Int(owner.work_cancelled),
        "completions_taken" => Int(owner.completions_taken),
        "startup_acknowledged" => owner.startup_acknowledged,
        "stop_acknowledged" => owner.stop_acknowledged,
        "task_id" => artifact_unsigned_identity(owner.task_id),
        "last_thread_id" => owner.last_thread_id,
        "failed" => owner.failed,
        "maximum_due_occupancy" => owner.maximum_due_occupancy,
        "maximum_completion_occupancy" =>
            owner.maximum_completion_occupancy,
        "maximum_lateness_ns" => owner.maximum_lateness_ns,
        "overload_episodes" => Int(owner.overload_episodes),
        "recovery_count" => Int(owner.recovery_count),
        "overload_decision" => string(owner.overload_decision))
end

@inline ownership_pool_is_drained(::Nothing) = true

@inline function ownership_pool_is_drained(accounting)
    return accounting.free == accounting.capacity &&
        iszero(accounting.producer_owned) &&
        iszero(accounting.queued) &&
        iszero(accounting.consumer_leased)
end

function execution_owner_ownership_is_drained(owner)
    return iszero(owner.due.occupancy) &&
        iszero(owner.completion.occupancy) &&
        iszero(owner.active_batch_sequence) &&
        owner.work_submitted ==
            owner.work_taken + owner.work_cancelled &&
        owner.completions_taken ==
            owner.work_completed + owner.work_failed &&
        owner.stop_acknowledged
end

function serial_ownership_is_drained(accounting)
    acquisitions_drained = all(
        acquisition -> begin
            iszero(acquisition.descriptors.occupancy) &&
                ownership_pool_is_drained(acquisition.products)
        end,
        accounting.acquisitions)
    owners = accounting.execution_owners
    owners_drained = owners === nothing ||
        all(execution_owner_ownership_is_drained, owners)
    return iszero(accounting.command_submissions.occupancy) &&
        iszero(accounting.command_completions.occupancy) &&
        ownership_pool_is_drained(accounting.command_credits) &&
        ownership_pool_is_drained(accounting.command_payloads) &&
        iszero(accounting.command_dispositions) &&
        iszero(accounting.active_command_correlations) &&
        acquisitions_drained &&
        !accounting.execution_batch_active &&
        owners_drained
end

function interval_snapshot(interval)
    report = Dict{String,Any}()
    for field in fieldnames(typeof(interval))
        value = getfield(interval, field)
        report[string(field)] = if ismissing(value)
            "unavailable"
        elseif field in (
                :owner_one_task_id,
                :owner_two_task_id)
            artifact_unsigned_identity(value)
        else
            _artifact_value(value)
        end
    end
    return report
end

function gate8_accounting_snapshot(accounting)
    report = accounting_snapshot(accounting)
    report["ownership_drained"] =
        serial_ownership_is_drained(accounting)
    for (snapshot, acquisition) in zip(
        report["acquisitions"],
        accounting.acquisitions)
        snapshot["acquisition"] =
            string(acquisition.acquisition.name)
    end
    report["execution_batch_active"] =
        accounting.execution_batch_active
    owners = accounting.execution_owners
    report["execution_owners"] = owners === nothing ?
        Vector{Dict{String,Any}}() :
        [execution_owner_snapshot(owner) for owner in owners]
    return report
end

function failure_snapshot(record)
    record === nothing && return Dict{String,Any}(
        "present" => false)
    lifecycle = AdaptiveOpticsHIL.Lifecycle
    execution_ns = lifecycle.run_failure_execution_ns(record)
    return Dict{String,Any}(
        "present" => true,
        "kind" => string(lifecycle.run_failure_kind(record)),
        "stage" => string(lifecycle.run_failure_stage(record)),
        "component" =>
            string(lifecycle.run_failure_component(record)),
        "reason" => string(lifecycle.run_failure_reason(record)),
        "execution_ns" => execution_ns === nothing ?
            "unavailable" : execution_ns,
        "work_sequence" =>
            Int(lifecycle.run_failure_work_sequence(record)))
end

function failure_accounting_snapshot(accounting)
    lifecycle = AdaptiveOpticsHIL.Lifecycle
    owners = Vector{Dict{String,Any}}()
    for owner in accounting.owners
        push!(owners, Dict{String,Any}(
            "component" =>
                string(lifecycle.run_owner_component(owner.owner)),
            "ordinal" =>
                lifecycle.run_owner_ordinal(owner.owner),
            "acknowledged" => owner.acknowledged,
            "acknowledgement_timed_out" =>
                owner.acknowledgement_timed_out,
            "failure" => failure_snapshot(owner.failure)))
    end
    return Dict{String,Any}(
        "stop_epoch" => Int(accounting.stop_epoch),
        "started_execution_ns" =>
            something(
                accounting.started_execution_ns,
                "unavailable"),
        "acknowledgement_deadline_execution_ns" =>
            something(
                accounting.acknowledgement_deadline_execution_ns,
                "unavailable"),
        "drain_deadline_execution_ns" =>
            something(
                accounting.drain_deadline_execution_ns,
                "unavailable"),
        "first_failure" =>
            failure_snapshot(accounting.first_failure),
        "owners" => owners,
        "drain_timed_out" => accounting.drain_timed_out)
end

function ingress_liveness_snapshot(accounting)
    return Dict{String,Any}(
        "status" => string(accounting.status),
        "endpoint" => accounting.endpoint === nothing ?
            "not configured" : string(accounting.endpoint),
        "execution_clock" =>
            accounting.execution_clock === nothing ?
                "not configured" :
                string(accounting.execution_clock),
        "timeout_ns" => something(
            accounting.timeout_ns, "not configured"),
        "origin_execution_ns" => something(
            accounting.origin_execution_ns, "not configured"),
        "deadline_execution_ns" => something(
            accounting.deadline_execution_ns, "not configured"),
        "observation_execution_ns" => something(
            accounting.observation_execution_ns, "not configured"),
        "last_admission_execution_ns" => something(
            accounting.last_admission_execution_ns,
            "not configured"),
        "reset_count" => Int(accounting.reset_count),
        "expiry_count" => Int(accounting.expiry_count))
end

function successful_lifecycle_snapshot(result)
    timings = result.lifecycle_timings
    return Dict{String,Any}(
        "terminal_phase" => string(result.terminal_phase),
        "timing" => Dict{String,Any}(
            "configuration_ns" => timings.configuration_ns,
            "preparation_ns" => timings.preparation_ns,
            "arm_ns" => timings.arm_ns,
            "start_ns" => timings.start_ns,
            "total_prepare_arm_start_ns" => timings.total_ns,
            "clean_stop_ns" => result.stop_elapsed_ns,
            "operational_wall_excludes_stop" => true),
        "rtc_ingress_liveness" =>
            ingress_liveness_snapshot(result.ingress_liveness),
        "stop_coordination" =>
            failure_accounting_snapshot(
                result.failure_accounting))
end

function recorded_run_report(
    result,
    observer::Operational.OperationalIntervalObserver,
    phase::AbstractString,
    run_index::Integer,
    workload,
    histogram_config,
    contract)
    elapsed_ns = Int(result.wall_end_ns - result.wall_start_ns)
    seconds = elapsed_ns / 1.0e9
    offered_elapsed_ns = Int(
        result.offered_complete_wall_ns - result.wall_start_ns)
    offered_seconds = offered_elapsed_ns / 1.0e9
    counters = result.counters
    intervals = [
        interval_snapshot(interval)
        for interval in Operational.interval_records(observer)
    ]
    isempty(intervals) && error(
        "recorded operational run did not retain an interval record")
    final_interval = last(intervals)
    gc_fraction = final_interval["gc_time_ns"] /
        max(1, final_interval["wall_elapsed_ns"])
    return Dict{String,Any}(
        "phase" => String(phase),
        "run" => Int(run_index),
        "wall_elapsed_ns" => elapsed_ns,
        "offered_elapsed_ns" => offered_elapsed_ns,
        "configured_offered_rate_hz" =>
            effective_primary_rate_hz(workload),
        "achieved_offered_rate_hz" =>
            Int(counters.offered_primary) / offered_seconds,
        "completed_rate_hz" =>
            Int(counters.command_responses) / seconds,
        "prepared_capacities" =>
            workload_capacity_snapshot(workload),
        "gc_fraction" => gc_fraction,
        "lifecycle" => successful_lifecycle_snapshot(result),
        "counters" => gate8_counter_snapshot(counters),
        "accounting" =>
            gate8_accounting_snapshot(result.accounting),
        "acquisition_overload" => [
            overload_snapshot(overload)
            for overload in result.overload_accounting
        ],
        "arrival_checkpoints" => checkpoint_snapshot(result),
        "intervals" => intervals,
        "histograms" => histogram_report(
            result,
            histogram_config,
            contract))
end

function execute_recorded_run(
    workload,
    run_config,
    histogram_config,
    contract,
    optical_execution;
    phase::AbstractString,
    run_index::Integer,
    threaded::Bool)
    estimated_wall_ns =
        run_config.samples * workload.primary_period_ns
    interval_capacity = max(
        4,
        cld(estimated_wall_ns, contract["interval_ns"]) + 8)
    observer = Operational.OperationalIntervalObserver(
        interval_capacity,
        contract["interval_ns"])
    GC.gc()
    result = Operational.execute_run(
        Clocks.SystemNanoClock(),
        workload,
        run_config,
        histogram_config,
        optical_execution;
        observer)
    threaded && Operational.validate_threaded_owner_result(
        result, contract["execution_owner_count"])
    return recorded_run_report(
        result,
        observer,
        phase,
        run_index,
        workload,
        histogram_config,
        contract)
end

function unpaced_run_report(
    result,
    observer::Operational.OperationalIntervalObserver,
    run_index,
    workload,
    histogram_config,
    contract)
    elapsed_ns = Int(result.wall_end_ns - result.wall_start_ns)
    seconds = elapsed_ns / 1.0e9
    counters = result.counters
    intervals = [
        interval_snapshot(interval)
        for interval in Operational.interval_records(observer)
    ]
    isempty(intervals) && error(
        "unpaced capacity run did not retain an interval record")
    return Dict{String,Any}(
        "run" => run_index,
        "classification" =>
            "unpaced maximum-useful-throughput diagnostic",
        "wall_elapsed_ns" => elapsed_ns,
        "simulated_primary_rate_hz" =>
            effective_primary_rate_hz(workload),
        "useful_completed_rate_hz" =>
            Int(counters.command_responses) / seconds,
        "prepared_capacities" =>
            workload_capacity_snapshot(workload),
        "intervals" => intervals,
        "lifecycle" => successful_lifecycle_snapshot(result),
        "counters" => gate8_counter_snapshot(counters),
        "accounting" =>
            gate8_accounting_snapshot(result.accounting),
        "acquisition_overload" => [
            overload_snapshot(overload)
            for overload in result.overload_accounting
        ],
        "controller_service_histogram" => histogram_report(
            result,
            histogram_config,
            contract;
            only_controller_service=true)[
                "controller_service_ns"],
        "execution_clock_histograms_qualified_for_latency" =>
            false)
end

function execute_unpaced_run(
    workload,
    run_config,
    histogram_config,
    contract,
    run_index)
    maximum_wall_ns = cld(
        run_config.samples * 1_000_000_000,
        contract["minimum_calibrated_rate_hz"])
    observer = Operational.OperationalIntervalObserver(
        max(
            4,
            cld(
                maximum_wall_ns,
                contract["interval_ns"]) + 8),
        contract["interval_ns"])
    result = Operational.execute_run(
        Clocks.CachedNanoClock(0),
        workload,
        run_config,
        histogram_config,
        Operational.threaded_execution_configuration(contract);
        observer)
    Operational.validate_threaded_owner_result(
        result, contract["execution_owner_count"])
    return unpaced_run_report(
        result,
        observer,
        run_index,
        workload,
        histogram_config,
        contract)
end

function gate8_allocation_report(
    workload,
    histogram_config,
    contract)
    frames = contract["allocation_frames"]
    run_config = Harness.BoundaryRunConfig(
        samples=frames,
        checkpoint_stride=frames)
    optical_execution =
        Operational.deterministic_execution_configuration(
            contract)
    warm_driver = Operational.prepare_driver(
        Clocks.CachedNanoClock(0),
        workload,
        run_config,
        histogram_config,
        optical_execution)
    warm_result =
        Harness.execute_boundary_run!(warm_driver)
    Harness.validate_boundary_result(
        warm_result, run_config)
    driver = Operational.prepare_driver(
        Clocks.CachedNanoClock(0),
        workload,
        run_config,
        histogram_config,
        optical_execution)
    result = nothing
    GC.gc()
    bytes = @allocated result =
        Harness.execute_boundary_run!(driver)
    Harness.validate_boundary_result(result, run_config)
    return Dict{String,Any}(
        "frames" => frames,
        "inclusive_bytes" => bytes,
        "inclusive_bytes_per_frame" => bytes / frames)
end

@noinline function deadline_accounting_calibration(
    iterations::Int,
    period_ns::Int64)
    checksum = Int64(0)
    start_ns = time_ns()
    @inbounds for index in 1:iterations
        elapsed_ns = Int64(index) * period_ns
        checksum += fld(elapsed_ns, period_ns)
    end
    wall_ns = Int(time_ns() - start_ns)
    return Dict{String,Any}(
        "iterations" => iterations,
        "wall_ns_per_iteration" => wall_ns / iterations,
        "checksum" => checksum)
end

function gate8_calibration_report(
    histogram_config,
    contract,
    workload)
    timer = timer_calibration(
        histogram_config;
        samples=contract["calibration_iterations"])
    timer["deadline_accounting"] =
        deadline_accounting_calibration(
            contract["calibration_iterations"],
            workload.primary_period_ns)
    return timer
end

function optional_file_value(path)
    isfile(path) || return "unavailable"
    value = strip(read(path, String))
    return isempty(value) ? "unavailable" : value
end

function optional_cpu_list(path)
    isfile(path) || return "unavailable"
    value = strip(read(path, String))
    return isempty(value) ? "none" : value
end

function cpu_cache_snapshot()
    root = "/sys/devices/system/cpu/cpu0/cache"
    isdir(root) || return Vector{Dict{String,Any}}()
    report = Vector{Dict{String,Any}}()
    for entry in sort(readdir(root))
        startswith(entry, "index") || continue
        path = joinpath(root, entry)
        push!(report, Dict{String,Any}(
            "index" => entry,
            "level" => optional_file_value(
                joinpath(path, "level")),
            "type" => optional_file_value(
                joinpath(path, "type")),
            "size" => optional_file_value(
                joinpath(path, "size")),
            "line_size_bytes" => optional_file_value(
                joinpath(path, "coherency_line_size")),
            "shared_cpu_list" => optional_file_value(
                joinpath(path, "shared_cpu_list"))))
    end
    return report
end

function source_file_hashes()
    relative_paths = (
        "benchmarks/benchmark_gate8_operational_runtime.jl",
        "benchmarks/contracts/gate8_operational_runtime.toml",
        "benchmarks/support/gate4a_boundary_harness.jl",
        "benchmarks/support/gate4a_serial_workload.jl",
        "benchmarks/support/gate8_operational_harness.jl",
        "benchmarks/support/gate8_system_metrics.jl",
        "benchmarks/support/hdr_histogram_artifact.jl",
    )
    return Dict{String,Any}(
        path => bytes2hex(
            SHA.sha256(read(joinpath(REPOSITORY_ROOT, path))))
        for path in relative_paths)
end

function operational_policy_manifest(contract, workload)
    configured_contexts = max(
        contract["julia_threads"],
        contract["execution_owner_count"] *
            contract["fft_threads"],
        contract["execution_owner_count"] *
            contract["blas_threads"])
    return Dict{String,Any}(
        "clock" => Dict{String,Any}(
            "recorded_fixed_arrival_source" =>
                "Clocks.SystemNanoClock",
            "deterministic_replay_source" =>
                "Clocks.CachedNanoClock",
            "mapping" =>
                "immutable AdaptiveOpticsHIL.Timing.ExecutionClockMapping selected at arm",
            "mapping_revision_identity" =>
                "AdaptiveOpticsHIL repository_commit plus Clocks package tree_hash"),
        "arrival" => Dict{String,Any}(
            "model" =>
                "schedule-preserving absolute execution-clock deadlines",
            "primary_period_ns" => workload.primary_period_ns,
            "completion_paces_arrivals" => false,
            "coordinated_omission_correction" => false),
        "execution_owners" => Dict{String,Any}(
            "count" => contract["execution_owner_count"],
            "mode" => "ThreadedExecutionOwners",
            "idle_policy" => "HybridExecutionOwnerIdle",
            "spin_count" =>
                contract["execution_owner_idle_spin_count"],
            "after_spin_action" => "yield",
            "due_and_completion_ring_capacity" =>
                contract["execution_owner_ring_capacity"],
            "overload_action" => "FailRunOnOwnerOverload",
            "maximum_lateness_ns" =>
                contract[
                    "execution_owner_maximum_lateness_ns"],
            "batch_observation" =>
                "per-interval completed path-batch and owner work counters"),
        "derived_rate_capacity_policy" => Dict{String,Any}(
            "preserve_time_headroom" =>
                contract[
                    "derived_rate_preserve_capacity_time_headroom"],
            "scaling_basis" =>
                "ceil(base capacity * base primary period / derived primary period)",
            "applies_to" =>
                "command, primary, feedback, and science bounded capacities",
            "target_phase_capacities_unchanged" => true),
        "compilation_hygiene" => Dict{String,Any}(
            "uniformly_scaled_primary_rate_hz" => 0.25,
            "coverage_primary_products" =>
                contract["compilation_coverage_frames"],
            "coverage_goal" =>
                "exercise every slower acquisition stream before the production-deadline warmup",
            "maximum_lateness_ns" => 600_000_000_000,
            "production_rate_smoke_primary_products" => 1,
            "production_rate_smoke_uses_compilation_policy" => true,
            "injected_fault_smoke_clock" =>
                "Clocks.SystemNanoClock",
            "injected_fault_smoke_batch_sequence" => 16,
            "injected_fault_smoke_uses_compilation_policy" => true,
            "recorded_injected_fault_owner_maximum_lateness_ns" =>
                600_000_000_000,
            "recorded_injected_fault_performance_claim" => false,
            "explicit_gc_before_production_warmup" => true,
            "recorded_as_evidence" => false),
        "cpu_admission" => Dict{String,Any}(
            "cpu_context_count" => configured_contexts,
            "julia_thread_count" =>
                contract["julia_threads"],
            "julia_interactive_thread_count" =>
                contract["julia_interactive_threads"],
            "outer_owner_count" =>
                contract["execution_owner_count"],
            "group_julia_thread_count" => 1,
            "fft_thread_count" => contract["fft_threads"],
            "blas_thread_count" => contract["blas_threads"],
            "fft_provider_used_by_reduced_order_workload" =>
                false),
        "acquisition_resources" => Dict{String,Any}(
            "hil_wfs" => Dict{String,Any}(
                "criticality" => "required",
                "full_action" => "RetainProducerOnFull",
                "capacity" =>
                    workload.primary_product_capacity),
            "hil_dm_feedback" => Dict{String,Any}(
                "criticality" => "required",
                "full_action" => "RetainProducerOnFull",
                "capacity" =>
                    workload.feedback_product_capacity),
            "hil_science" => Dict{String,Any}(
                "criticality" => "optional",
                "full_action" => "DropNewestOnFull",
                "capacity" =>
                    workload.science_product_capacity)),
        "command_resources" => Dict{String,Any}(
            "payload_pool_capacity" =>
                workload.command_capacity,
            "submission_capacity" =>
                workload.command_capacity,
            "completion_capacity" =>
                workload.command_capacity,
            "terminal_outcome_required" => true),
        "rtc_ingress_liveness" => Dict{String,Any}(
            "configured" => false,
            "reason" =>
                "the deterministic in-memory benchmark adapter owns the command cadence"),
        "shutdown" => Dict{String,Any}(
            "acknowledgement_timeout_ns" =>
                contract["acknowledgement_timeout_ns"],
            "drain_timeout_ns" =>
                contract["drain_timeout_ns"],
            "dependency_ordered_closure" => true),
        "interval_instrumentation" => Dict{String,Any}(
            "period_ns" => contract["interval_ns"],
            "probe_stride_completed_wfs" => 100,
            "latency_percentile" => "cumulative p99",
            "process_cpu_utilization_definition" =>
                "delta process CPU nanoseconds divided by wall nanoseconds (core-equivalents; not normalized by host CPU count)",
            "unsupported_os_counters" => "unavailable"))
end

function gate8_environment_snapshot(
    contract_path,
    repository_status,
    contract,
    workload)
    report = environment_snapshot(
        contract_path,
        repository_status)
    report["invocation"] =
        "JULIA_NUM_THREADS=4,0 OPENBLAS_NUM_THREADS=1 " *
        "OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 " *
        "julia --startup-file=no " *
        "--project=benchmarks " *
        "benchmarks/benchmark_gate8_operational_runtime.jl " *
        "--output <artifact>"
    report["package_load_ns"] = GATE8_PACKAGE_LOAD_NS
    report["thread_pools"] = Dict{String,Any}(
        "default" => Threads.nthreads(:default),
        "interactive" => Threads.nthreads(:interactive))
    report["fft_threads"] = 1
    report["julia_num_gc_threads"] =
        get(ENV, "JULIA_NUM_GC_THREADS", "runtime default")
    report["julia_gc_mark_threads_option"] =
        Base.JLOptions().nmarkthreads
    report["julia_gc_sweep_threads_option"] =
        Base.JLOptions().nsweepthreads
    report["julia_heap_size_hint_bytes"] =
        Int(Base.JLOptions().heap_size_hint)
    report["julia_startup_file_option"] =
        Base.JLOptions().startupfile
    report["julia_optimization_level"] =
        Base.JLOptions().opt_level
    report["julia_bounds_check_option"] =
        Base.JLOptions().check_bounds
    report["julia_coverage_option"] =
        Base.JLOptions().code_coverage
    report["numa_online"] = optional_file_value(
        "/sys/devices/system/node/online")
    report["isolated_cpu_list"] = optional_cpu_list(
        "/sys/devices/system/cpu/isolated")
    report["nohz_full_cpu_list"] = optional_cpu_list(
        "/sys/devices/system/cpu/nohz_full")
    report["smt_active"] = optional_file_value(
        "/sys/devices/system/cpu/smt/active")
    report["transparent_hugepages"] = optional_file_value(
        "/sys/kernel/mm/transparent_hugepage/enabled")
    report["memory_policy_applied_by_benchmark"] = false
    report["cpu_caches"] = cpu_cache_snapshot()
    report["gpu"] = Dict{String,Any}(
        "used" => false,
        "runtime" => "not used",
        "driver" => "not used",
        "device" => "not used",
        "synchronizations" => 0)
    report["source_file_sha256"] = source_file_hashes()
    report["operational_policy_manifest"] =
        operational_policy_manifest(contract, workload)
    report["protocol_issue"] =
        "https://github.com/DarrylGamroth/AdaptiveOpticsHIL.jl/issues/25"
    return report
end

function cold_lifecycle_report(
    workload,
    histogram_config,
    contract)
    cold_rate_hz = 0.25
    cold_workload = workload_at_rate(
        workload, cold_rate_hz)
    cold_contract = deepcopy(contract)
    cold_contract[
        "execution_owner_maximum_lateness_ns"] =
        600_000_000_000
    cold_histogram_config = Harness.HistogramConfig(
        histogram_config.lowest_ns,
        600_000_000_000,
        histogram_config.significant_figures)
    run_config = Harness.BoundaryRunConfig(
        samples=1,
        checkpoint_stride=1)
    driver = nothing
    prepare_allocated_bytes = @allocated driver =
        Operational.prepare_driver(
            Clocks.SystemNanoClock(),
            cold_workload,
            run_config,
            cold_histogram_config,
            Operational.threaded_execution_configuration(
                cold_contract))
    wall_start_ns = time_ns()
    result = nothing
    first_use_allocated_bytes = @allocated result =
        Harness.execute_boundary_run!(driver)
    Harness.validate_boundary_result(result, run_config)
    Operational.validate_threaded_owner_result(
        result, contract["execution_owner_count"])
    first_use_ns = Int(
        result.first_response_wall_ns - wall_start_ns)
    timings = driver.fixture.lifecycle_timings
    return Dict{String,Any}(
        "package_load_ns" => GATE8_PACKAGE_LOAD_NS,
        "configuration_ns" => timings.configuration_ns,
        "preparation_ns" => timings.preparation_ns,
        "arm_ns" => timings.arm_ns,
        "start_ns" => timings.start_ns,
        "total_prepare_arm_start_ns" => timings.total_ns,
        "prepare_arm_start_allocated_bytes" =>
            prepare_allocated_bytes,
        "first_complete_control_cycle_ns" => first_use_ns,
        "first_complete_run_allocated_bytes" =>
            first_use_allocated_bytes,
        "first_use_includes_compilation" => true,
        "classification" =>
            "descriptive cold JIT evidence on a uniformly slowed schedule, not operational latency evidence",
        "cold_only_primary_rate_hz" =>
            effective_primary_rate_hz(cold_workload),
        "recorded_primary_rate_hz" =>
            effective_primary_rate_hz(workload),
        "cold_only_owner_lateness_ns" =>
            cold_contract[
                "execution_owner_maximum_lateness_ns"],
        "cold_only_histogram_highest_ns" =>
            cold_histogram_config.highest_ns,
        "recorded_phase_owner_lateness_ns" =>
            contract[
                "execution_owner_maximum_lateness_ns"],
        "recorded_phase_histogram_highest_ns" =>
            histogram_config.highest_ns,
        "gated_only_by_prepared_lifecycle_timeouts" => true,
        "lifecycle" => successful_lifecycle_snapshot(result),
        "accounting" =>
            gate8_accounting_snapshot(result.accounting))
end

const GATE8_SEMANTIC_COUNTER_FIELDS = (
    :offered_primary,
    :published_primary,
    :observed_primary,
    :dropped_primary,
    :primary_sequence_gaps,
    :published_feedback,
    :observed_feedback,
    :feedback_sequence_gaps,
    :commands_offered,
    :commands_enqueued,
    :commands_admitted,
    :commands_applied,
    :commands_rejected,
    :outcomes_consumed,
    :command_responses,
    :command_sequence_gaps,
    :outcome_sequence_gaps,
    :initial_residual_metric,
    :final_residual_metric,
    :generated_science,
    :published_science,
    :observed_science,
    :shed_science,
    :failed_science,
    :science_sequence_gaps,
)

semantic_counter_signature(counters) = Tuple(
    getfield(counters, field)
    for field in GATE8_SEMANTIC_COUNTER_FIELDS)

function trace_sha256(trace)
    bytes = reinterpret(UInt8, collect(trace))
    return bytes2hex(SHA.sha256(bytes))
end

function trace_hashes(observer)
    return Dict{String,Any}(
        "primary_product_command_response" =>
            trace_sha256(Operational.product_trace(observer)),
        "feedback_products" =>
            trace_sha256(Operational.feedback_trace(observer)),
        "science_products" =>
            trace_sha256(Operational.science_trace(observer)),
        "serial_events" =>
            trace_sha256(Operational.event_trace(observer)))
end

function exact_trace_signature(observer)
    return (
        collect(Operational.product_trace(observer)),
        collect(Operational.feedback_trace(observer)),
        collect(Operational.science_trace(observer)),
        collect(Operational.event_trace(observer)),
    )
end

function execute_correctness_trace(
    workload,
    histogram_config,
    run_config,
    optical_execution)
    observer = Operational.ProductTraceObserver(run_config.samples)
    result = Operational.execute_run(
        Clocks.CachedNanoClock(0),
        workload,
        run_config,
        histogram_config,
        optical_execution;
        observer)
    return (; result, observer)
end

function exact_correctness_report(
    workload,
    histogram_config,
    contract)
    frames = contract["correctness_frames"]
    run_config = Harness.BoundaryRunConfig(
        samples=frames,
        checkpoint_stride=max(1, frames ÷ 8))
    serial = execute_correctness_trace(
        workload,
        histogram_config,
        run_config,
        AdaptiveOpticsHIL.Execution.SerialOpticalExecution())
    deterministic = execute_correctness_trace(
        workload,
        histogram_config,
        run_config,
        Operational.deterministic_execution_configuration(
            contract))
    threaded = execute_correctness_trace(
        workload,
        histogram_config,
        run_config,
        Operational.threaded_execution_configuration(contract))
    Operational.validate_threaded_owner_result(
        threaded.result,
        contract["execution_owner_count"])
    serial_trace = exact_trace_signature(serial.observer)
    deterministic_trace =
        exact_trace_signature(deterministic.observer)
    threaded_trace =
        exact_trace_signature(threaded.observer)
    serial_trace == deterministic_trace == threaded_trace || error(
        "serial, deterministic-owner, and threaded-owner event/product traces differ")
    serial_signature =
        semantic_counter_signature(serial.result.counters)
    serial_signature ==
        semantic_counter_signature(
            deterministic.result.counters) ==
        semantic_counter_signature(
            threaded.result.counters) || error(
                "execution topologies changed semantic counters")
    checkpoint_snapshot(serial.result) ==
        checkpoint_snapshot(deterministic.result) ==
        checkpoint_snapshot(threaded.result) || error(
            "execution topologies changed cached-clock arrival checkpoints")
    deterministic_histogram_signature(serial.result) ==
        deterministic_histogram_signature(
            deterministic.result) ==
        deterministic_histogram_signature(
            threaded.result) || error(
            "execution topologies changed cached-clock boundary timing")
    return Dict{String,Any}(
        "passed" => true,
        "frames" => frames,
        "trace_sha256" => trace_hashes(serial.observer),
        "semantic_counter_fields" =>
            String.(GATE8_SEMANTIC_COUNTER_FIELDS),
        "serial_lifecycle" =>
            successful_lifecycle_snapshot(serial.result),
        "deterministic_owner_lifecycle" =>
            successful_lifecycle_snapshot(
                deterministic.result),
        "threaded_owner_lifecycle" =>
            successful_lifecycle_snapshot(threaded.result),
        "serial_accounting" =>
            gate8_accounting_snapshot(serial.result.accounting),
        "deterministic_owner_accounting" =>
            gate8_accounting_snapshot(
                deterministic.result.accounting),
        "threaded_owner_accounting" =>
            gate8_accounting_snapshot(
                threaded.result.accounting))
end

function execute_gate8_warmup!(
    workload,
    histogram_config,
    contract)
    one_frame_config = Harness.BoundaryRunConfig(
        samples=1,
        checkpoint_stride=1)
    compilation_coverage_frames =
        contract["compilation_coverage_frames"]
    compilation_coverage_config = Harness.BoundaryRunConfig(
        samples=compilation_coverage_frames,
        checkpoint_stride=compilation_coverage_frames)
    threaded_execution =
        Operational.threaded_execution_configuration(contract)
    compilation_contract = deepcopy(contract)
    compilation_contract[
        "execution_owner_maximum_lateness_ns"] =
        600_000_000_000
    compilation_histogram_config = Harness.HistogramConfig(
        histogram_config.lowest_ns,
        600_000_000_000,
        histogram_config.significant_figures)
    compilation_workload = workload_at_rate(
        workload, 0.25)
    for compilation_execution in (
            Operational.deterministic_execution_configuration(
                compilation_contract),
            Operational.threaded_execution_configuration(
                compilation_contract))
        observer = Operational.OperationalIntervalObserver(
            4, 100_000_000; probe_stride=1)
        driver = Operational.prepare_driver(
            Clocks.SystemNanoClock(),
            compilation_workload,
            compilation_coverage_config,
            compilation_histogram_config,
            compilation_execution;
            observer)
        Operational.precompile_and_discard_driver!(driver)
        Operational.execute_run(
            Clocks.SystemNanoClock(),
            compilation_workload,
            compilation_coverage_config,
            compilation_histogram_config,
            compilation_execution;
            observer=Operational.OperationalIntervalObserver(
                4, 100_000_000; probe_stride=1))
        Operational.execute_run(
            Clocks.SystemNanoClock(),
            workload,
            one_frame_config,
            compilation_histogram_config,
            compilation_execution;
            observer=Operational.OperationalIntervalObserver(
                4, contract["interval_ns"]))
    end
    GC.gc()
    run_config = Harness.BoundaryRunConfig(
        samples=contract["warmup_frames"],
        checkpoint_stride=contract["warmup_frames"])
    estimated_wall_ns =
        run_config.samples * workload.primary_period_ns
    observer = Operational.OperationalIntervalObserver(
        max(
            4,
            cld(
                estimated_wall_ns,
                contract["interval_ns"]) + 8),
        contract["interval_ns"])
    driver = Operational.prepare_driver(
        Clocks.SystemNanoClock(),
        workload,
        run_config,
        histogram_config,
        threaded_execution;
        observer)
    Operational.reset_operational_observer!(observer)
    result = try
        Harness.execute_boundary_run!(driver)
    catch error
        executor = AdaptiveOpticsHIL.Serial.
            serial_optical_execution(driver.fixture.run)
        owner_lateness_ns = [
            AdaptiveOpticsHIL.Execution.
                execution_owner_accounting(
                    executor, index).maximum_lateness_ns
            for index in 1:AdaptiveOpticsHIL.Execution.
                execution_owner_count(executor)
        ]
        failure = AdaptiveOpticsHIL.Lifecycle.
            first_run_failure(driver.fixture.run.failures)
        @error(
            "Gate 8 declared warmup failed",
            offered_primary=driver.counters.offered_primary,
            execution_batches_completed=
                AdaptiveOpticsHIL.Execution.
                    execution_batches_completed(executor),
            owner_one_maximum_lateness_ns=
                owner_lateness_ns[1],
            owner_two_maximum_lateness_ns=
                owner_lateness_ns[2],
            first_failure=failure,
            error_type=typeof(error))
        rethrow()
    end
    Operational.finish_operational_observer!(
        observer, driver)
    Harness.validate_boundary_result(result, run_config)
    Operational.validate_threaded_owner_result(
        result, contract["execution_owner_count"])
    Operational.execute_run(
        Clocks.CachedNanoClock(0),
        workload,
        one_frame_config,
        histogram_config,
        threaded_execution;
        observer=Operational.OperationalIntervalObserver(
            4, contract["interval_ns"]))
    GC.gc()
    return nothing
end

function injected_failure_report(result, run_index)
    return Dict{String,Any}(
        "run" => run_index,
        "owner_maximum_lateness_ns" =>
            result.owner_maximum_lateness_ns,
        "error_type" => string(typeof(result.error)),
        "trigger_batch_sequence" =>
            result.trigger_batch_sequence,
        "injection_to_observation_ns" =>
            result.injection_to_observation_ns,
        "observation_to_ingress_closure_ns" =>
            result.observation_to_ingress_closure_ns,
        "observation_to_acknowledgement_ns" =>
            result.observation_to_acknowledgement_ns,
        "observation_to_shutdown_ns" =>
            result.observation_to_shutdown_ns,
        "ingress_closed" => result.ingress_closed,
        "first_failure" => failure_snapshot(result.failure),
        "failure_accounting" =>
            failure_accounting_snapshot(
                result.failure_accounting),
        "accounting" =>
            gate8_accounting_snapshot(result.accounting))
end

function overload_report(result, requested_rate_hz, workload)
    return Dict{String,Any}(
        "requested_rate_hz" => requested_rate_hz,
        "configured_rate_hz" =>
            effective_primary_rate_hz(workload),
        "prepared_capacities" =>
            workload_capacity_snapshot(workload),
        "error_type" => string(typeof(result.error)),
        "start_to_failure_ns" => result.start_to_failure_ns,
        "violation_observation_is_failure_boundary" =>
            result.violation_observation_is_failure_boundary,
        "violation_to_failure_measurement_basis" =>
            "the prepared resource policy throws at the first observed violation; failure selection shares that synchronous boundary",
        "violation_to_failure_ns" =>
            result.violation_to_failure_ns,
        "failure_to_acknowledgement_ns" =>
            result.failure_to_acknowledgement_ns,
        "failure_to_shutdown_ns" =>
            result.failure_to_shutdown_ns,
        "ingress_closed" => result.ingress_closed,
        "offered_primary" => Int(result.offered_primary),
        "completed_primary" => Int(result.completed_primary),
        "first_failure" => failure_snapshot(result.failure),
        "failure_accounting" =>
            failure_accounting_snapshot(
                result.failure_accounting),
        "accounting" =>
            gate8_accounting_snapshot(result.accounting))
end

function named_deficit_report(result)
    return Dict{String,Any}(
        "first_failure" =>
            failure_snapshot(result.failure.first_failure),
        "failure_accounting" =>
            failure_accounting_snapshot(result.failure),
        "accounting_at_deadline" =>
            gate8_accounting_snapshot(result.accounting),
        "accounting_after_evidence_cleanup" =>
            gate8_accounting_snapshot(
                result.cleanup_accounting),
        "retained_resource" => "hil_wfs acquisition product lease",
        "retained_count" => 1)
end

function histogram_metric(run, name, percentile)
    return run["histograms"][name][percentile]
end

function rate_fidelity_passed(
    reports,
    maximum_error_fraction)
    return all(reports) do report
        configured = report["configured_offered_rate_hz"]
        achieved = report["achieved_offered_rate_hz"]
        abs(achieved - configured) / configured <=
            maximum_error_fraction
    end
end

function clean_lifecycle_accounting(report)
    lifecycle = report["lifecycle"]
    liveness = lifecycle["rtc_ingress_liveness"]
    stop = lifecycle["stop_coordination"]
    return lifecycle["terminal_phase"] == "RunStopped" &&
        liveness["expiry_count"] == 0 &&
        !stop["first_failure"]["present"] &&
        !stop["drain_timed_out"] &&
        all(
            owner -> owner["acknowledged"] &&
                !owner["acknowledgement_timed_out"],
            stop["owners"])
end

function exact_success_accounting(report)
    counters = report["counters"]
    accounting = report["accounting"]
    target = counters["offered_primary"]
    return clean_lifecycle_accounting(report) &&
        accounting["quiescent"] &&
        !accounting["execution_batch_active"] &&
        counters["published_primary"] == target &&
        counters["observed_primary"] == target &&
        counters["published_feedback"] ==
            counters["observed_feedback"] &&
        counters["commands_enqueued"] == target &&
        counters["commands_offered"] == target &&
        counters["commands_admitted"] == target &&
        counters["commands_applied"] == target &&
        counters["outcomes_consumed"] == target &&
        counters["command_responses"] == target &&
        counters["commands_rejected"] == 0 &&
        counters["dropped_primary"] == 0 &&
        counters["primary_sequence_gaps"] == 0 &&
        counters["feedback_sequence_gaps"] == 0 &&
        counters["command_sequence_gaps"] == 0 &&
        counters["outcome_sequence_gaps"] == 0 &&
        counters["published_science"] +
            counters["shed_science"] ==
            counters["generated_science"] &&
        counters["observed_science"] ==
            counters["published_science"] &&
        counters["failed_science"] == 0 &&
        counters["science_sequence_gaps"] ==
            counters["shed_science"]
end

function bounded_occupancy_and_required_delivery(
    report,
    contract)
    counters = report["counters"]
    workload = report["prepared_capacities"]
    counters["maximum_primary_occupancy"] <=
        workload["primary_completion_capacity"] || return false
    counters["maximum_feedback_occupancy"] <=
        workload["feedback_completion_capacity"] || return false
    counters["maximum_science_occupancy"] <=
        workload["science_completion_capacity"] || return false
    counters["maximum_command_submission_occupancy"] <=
        workload["command_submission_capacity"] || return false
    counters["maximum_command_completion_occupancy"] <=
        workload["command_completion_capacity"] || return false
    capacities = Dict(
        "hil_wfs" => workload["primary_product_capacity"],
        "hil_dm_feedback" =>
            workload["feedback_product_capacity"],
        "hil_science" => workload["science_product_capacity"])
    for acquisition in report["acquisition_overload"]
        capacity = capacities[acquisition["acquisition"]]
        acquisition["maximum_descriptor_occupancy"] <= capacity ||
            return false
        acquisition["maximum_product_occupancy"] <= capacity ||
            return false
        if acquisition["acquisition"] != "hil_science"
            acquisition["products_shed"] == 0 || return false
            acquisition["products_failed"] == 0 || return false
        end
    end
    for owner in report["accounting"]["execution_owners"]
        owner["maximum_due_occupancy"] <=
            contract["execution_owner_ring_capacity"] || return false
        owner["maximum_completion_occupancy"] <=
            contract["execution_owner_ring_capacity"] || return false
    end
    return true
end

bounded_success_accounting(report, contract) =
    exact_success_accounting(report) &&
    bounded_occupancy_and_required_delivery(report, contract)

function owner_tasks_are_stable(report)
    owners = report["accounting"]["execution_owners"]
    length(owners) == 2 || return false
    expected_one = owners[1]["task_id"]
    expected_two = owners[2]["task_id"]
    zero_identity = artifact_unsigned_identity(UInt(0))
    expected_one != zero_identity || return false
    expected_two != zero_identity || return false
    expected_one != expected_two || return false
    return all(report["intervals"]) do interval
        interval["owner_one_task_id"] == expected_one &&
            interval["owner_two_task_id"] == expected_two
    end
end

function target_latency_gate(
    reports,
    contract)
    metric_contracts = (
        (
            "publication_lateness_ns",
            "max_target_p99_publication_lateness_ns",
            "max_target_p99_9_publication_lateness_ns",
        ),
        (
            "adapter_observation_delay_ns",
            "max_target_p99_observation_delay_ns",
            "max_target_p99_9_observation_delay_ns",
        ),
        (
            "closed_loop_response_ns",
            "max_target_p99_closed_loop_response_ns",
            "max_target_p99_9_closed_loop_response_ns",
        ),
    )
    observations = Dict{String,Any}()
    passed = true
    for (metric, p99_key, p99_9_key) in metric_contracts
        run_observations = [
            Dict{String,Any}(
                "run" => report["run"],
                "p99_ns" =>
                    histogram_metric(report, metric, "p99_ns"),
                "p99_9_ns" =>
                    histogram_metric(report, metric, "p99_9_ns"))
            for report in reports
        ]
        worst_p99 = maximum(
            observation["p99_ns"]
            for observation in run_observations)
        worst_p99_9 = maximum(
            observation["p99_9_ns"]
            for observation in run_observations)
        metric_passed =
            worst_p99 <= contract[p99_key] &&
            worst_p99_9 <= contract[p99_9_key]
        observations[metric] = Dict{String,Any}(
            "runs" => run_observations,
            "worst_p99_ns" => worst_p99,
            "maximum_p99_ns" => contract[p99_key],
            "worst_p99_9_ns" => worst_p99_9,
            "maximum_p99_9_ns" => contract[p99_9_key],
            "passed" => metric_passed)
        passed &= metric_passed
    end
    observations["passed"] = passed
    return observations
end

function relative_latency_gate(
    baseline_reports,
    target_reports,
    contract)
    specifications = (
        (
            "publication_lateness_ns",
            contract["relative_publication_floor_ns"],
        ),
        (
            "adapter_observation_delay_ns",
            contract["relative_observation_floor_ns"],
        ),
        (
            "closed_loop_response_ns",
            contract["relative_response_floor_ns"],
        ),
    )
    report = Dict{String,Any}()
    passed = true
    for (metric, floor_ns) in specifications
        baseline = median([
            histogram_metric(run, metric, "p99_ns")
            for run in baseline_reports
        ])
        observed = median([
            histogram_metric(run, metric, "p99_ns")
            for run in target_reports
        ])
        maximum_ns = max(
            contract["relative_multiplier"] * baseline,
            baseline + floor_ns)
        metric_passed = observed <= maximum_ns
        report[metric] = Dict{String,Any}(
            "deterministic_median_p99_ns" => baseline,
            "threaded_median_p99_ns" => observed,
            "maximum_ns" => maximum_ns,
            "passed" => metric_passed)
        passed &= metric_passed
    end
    report["future_comparable_baseline"] = Dict{String,Any}(
        "evaluated" => false,
        "reason" =>
            "this first Gate 8 artifact establishes the cross-revision baseline",
        "multiplier" =>
            contract["future_baseline_multiplier"],
        "absolute_floor_ns" =>
            contract["future_baseline_floor_ns"])
    report["passed"] = passed
    return report
end

function required_overload_gate(overload, contract)
    owners = overload["failure_accounting"]["owners"]
    owners_acknowledged = all(
        owner -> owner["acknowledged"],
        owners)
    acknowledgement_timed_out = any(
        owner -> owner["acknowledgement_timed_out"],
        owners)
    ownership_drained =
        overload["accounting"]["ownership_drained"]
    failure_kind = overload["first_failure"]["kind"]
    passed =
        failure_kind == "ResourcePolicyRunFailure" &&
        overload[
            "violation_observation_is_failure_boundary"] &&
        overload["violation_to_failure_ns"] <=
            contract["overload_failure_bound_ns"] &&
        overload["ingress_closed"] &&
        overload["failure_to_acknowledgement_ns"] <=
            contract["acknowledgement_timeout_ns"] &&
        overload["failure_to_shutdown_ns"] <=
            contract["drain_timeout_ns"] &&
        owners_acknowledged &&
        !acknowledgement_timed_out &&
        ownership_drained
    return Dict{String,Any}(
        "failure_kind" => failure_kind,
        "start_to_failure_ns" =>
            overload["start_to_failure_ns"],
        "start_to_failure_is_diagnostic" => true,
        "violation_to_failure_ns" =>
            overload["violation_to_failure_ns"],
        "violation_observation_is_failure_boundary" =>
            overload[
                "violation_observation_is_failure_boundary"],
        "maximum_violation_to_failure_ns" =>
            contract["overload_failure_bound_ns"],
        "ingress_closed" => overload["ingress_closed"],
        "failure_to_acknowledgement_ns" =>
            overload["failure_to_acknowledgement_ns"],
        "maximum_acknowledgement_ns" =>
            contract["acknowledgement_timeout_ns"],
        "failure_to_shutdown_ns" =>
            overload["failure_to_shutdown_ns"],
        "maximum_shutdown_ns" =>
            contract["drain_timeout_ns"],
        "owners_acknowledged" => owners_acknowledged,
        "acknowledgement_timed_out" =>
            acknowledgement_timed_out,
        "ownership_drained" => ownership_drained,
        "passed" => passed)
end

function gate8_gate_report(
    correctness,
    baseline_reports,
    target_reports,
    burst_report,
    science_report,
    calibration_reports,
    near_reports,
    saturation_reports,
    overload,
    recovery_report,
    injected_reports,
    deficit,
    soak_report,
    allocation,
    instrumentation_bytes,
    contract)
    calibrated_rate = minimum(
        report["useful_completed_rate_hz"]
        for report in calibration_reports)
    target_latency =
        target_latency_gate(target_reports, contract)
    soak_latency =
        target_latency_gate([soak_report], contract)
    relative_latency = relative_latency_gate(
        baseline_reports, target_reports, contract)
    burst_counters = burst_report["counters"]
    science_counters = science_report["counters"]
    injected_passed = all(injected_reports) do report
        failure = report["first_failure"]
        failure["present"] &&
            report["owner_maximum_lateness_ns"] ==
                600_000_000_000 &&
            failure["stage"] == "OwnerBeforeDequeue" &&
            report["trigger_batch_sequence"] ==
                contract["injected_failure_batch_sequence"] &&
            report["injection_to_observation_ns"] <=
                contract["overload_failure_bound_ns"] &&
            report["ingress_closed"] &&
            report["observation_to_acknowledgement_ns"] <=
                contract["acknowledgement_timeout_ns"] &&
            report["observation_to_shutdown_ns"] <=
                contract["drain_timeout_ns"] &&
            all(
                owner -> owner["acknowledged"] &&
                    !owner["acknowledgement_timed_out"],
                report["failure_accounting"]["owners"]) &&
            report["accounting"]["ownership_drained"]
    end
    deficit_wfs = only(
        acquisition
        for acquisition in
            deficit["accounting_at_deadline"]["acquisitions"]
        if acquisition["acquisition"] == "hil_wfs")
    threaded_success_reports = vcat(
        target_reports,
        [burst_report, science_report],
        calibration_reports,
        near_reports,
        saturation_reports,
        [recovery_report, soak_report])
    gates = Dict{String,Any}(
        "exact_correctness" => Dict(
            "passed" => correctness["passed"]),
        "deterministic_baseline_accounting" => Dict(
            "passed" => all(
                report -> bounded_success_accounting(
                    report, contract),
                baseline_reports)),
        "target_accounting" => Dict(
            "passed" =>
                all(
                    report -> bounded_success_accounting(
                        report, contract),
                    target_reports)),
        "target_rate_fidelity" => Dict(
            "maximum_error_fraction" =>
                contract["max_target_rate_error_fraction"],
            "passed" => rate_fidelity_passed(
                target_reports,
                contract["max_target_rate_error_fraction"])),
        "target_absolute_latency" => target_latency,
        "relative_latency" => relative_latency,
        "consumer_interruption_burst" => Dict(
            "offered_during_stall" =>
                burst_counters["stall_end_offered"] -
                burst_counters["stall_start_offered"],
            "required_frames" => contract["burst_frames"],
            "passed" =>
                burst_counters["stall_end_offered"] -
                    burst_counters["stall_start_offered"] ==
                    contract["burst_frames"] &&
                burst_counters["stall_end_observed"] ==
                    burst_counters["stall_start_observed"] &&
                bounded_success_accounting(
                    burst_report, contract)),
        "optional_science_shedding" => Dict(
            "products_shed" =>
                science_counters["shed_science"],
            "sequence_gaps" =>
                science_counters["science_sequence_gaps"],
            "recovery_count" =>
                science_counters["science_recovery_count"],
            "passed" =>
                science_counters["shed_science"] >= 8 &&
                science_counters["science_sequence_gaps"] ==
                    science_counters["shed_science"] &&
                science_counters["science_recovery_count"] >= 1 &&
                bounded_success_accounting(
                    science_report, contract)),
        "capacity_calibration" => Dict(
            "minimum_useful_rate_hz" => calibrated_rate,
            "required_minimum_rate_hz" =>
                contract["minimum_calibrated_rate_hz"],
            "accounting_passed" => all(
                report -> bounded_success_accounting(
                    report, contract),
                calibration_reports),
            "passed" =>
                calibrated_rate >=
                    contract["minimum_calibrated_rate_hz"] &&
                all(
                    report -> bounded_success_accounting(
                        report, contract),
                    calibration_reports)),
        "threaded_owner_identity" => Dict(
            "recorded_runs" => length(
                threaded_success_reports),
            "passed" => all(
                owner_tasks_are_stable,
                threaded_success_reports)),
        "near_saturation" => Dict(
            "passed" =>
                rate_fidelity_passed(
                    near_reports,
                    contract["max_derived_rate_error_fraction"]) &&
                all(
                    report -> bounded_success_accounting(
                        report, contract),
                    near_reports)),
        "saturation" => Dict(
            "passed" =>
                rate_fidelity_passed(
                    saturation_reports,
                    contract["max_derived_rate_error_fraction"]) &&
                all(
                    report -> bounded_success_accounting(
                        report, contract),
                    saturation_reports)),
        "required_overload" =>
            required_overload_gate(overload, contract),
        "fresh_run_recovery" => Dict(
            "passed" => bounded_success_accounting(
                recovery_report, contract)),
        "injected_owner_failure" => Dict(
            "repetitions" => length(injected_reports),
            "injection_to_observation_ns" => Dict{String,Any}(
                "minimum" => minimum(
                    report["injection_to_observation_ns"]
                    for report in injected_reports),
                "median" => median([
                    report["injection_to_observation_ns"]
                    for report in injected_reports
                ]),
                "maximum" => maximum(
                    report["injection_to_observation_ns"]
                    for report in injected_reports)),
            "observation_to_acknowledgement_ns" =>
                Dict{String,Any}(
                    "minimum" => minimum(
                        report[
                            "observation_to_acknowledgement_ns"]
                        for report in injected_reports),
                    "median" => median([
                        report[
                            "observation_to_acknowledgement_ns"]
                        for report in injected_reports
                    ]),
                    "maximum" => maximum(
                        report[
                            "observation_to_acknowledgement_ns"]
                        for report in injected_reports)),
            "observation_to_shutdown_ns" => Dict{String,Any}(
                "minimum" => minimum(
                    report["observation_to_shutdown_ns"]
                    for report in injected_reports),
                "median" => median([
                    report["observation_to_shutdown_ns"]
                    for report in injected_reports
                ]),
                "maximum" => maximum(
                    report["observation_to_shutdown_ns"]
                    for report in injected_reports)),
            "passed" => injected_passed),
        "named_drain_deficit" => Dict(
            "retained_consumer_leases" =>
                deficit_wfs["products"]["consumer_leased"],
            "drain_timed_out" =>
                deficit["failure_accounting"][
                    "drain_timed_out"],
            "passed" =>
                deficit_wfs["products"][
                    "consumer_leased"] == 1 &&
                deficit["failure_accounting"][
                    "drain_timed_out"] &&
                deficit[
                    "accounting_after_evidence_cleanup"][
                        "ownership_drained"]),
        "instrumentation_allocation" => Dict(
            "observed_bytes" => instrumentation_bytes,
            "maximum_bytes" =>
                contract["max_instrumentation_alloc_bytes"],
            "passed" => instrumentation_bytes <=
                contract["max_instrumentation_alloc_bytes"]),
        "inclusive_allocation" => Dict(
            "observed_bytes_per_frame" =>
                allocation["inclusive_bytes_per_frame"],
            "maximum_bytes_per_frame" =>
                contract["max_inclusive_alloc_bytes_per_frame"],
            "passed" =>
                allocation["inclusive_bytes_per_frame"] <=
                contract[
                    "max_inclusive_alloc_bytes_per_frame"]),
        "gc_budget" => Dict(
            "maximum_fraction" => contract["max_gc_fraction"],
            "worst_target_fraction" => maximum(
                report["gc_fraction"]
                for report in target_reports),
            "soak_fraction" => soak_report["gc_fraction"],
            "passed" =>
                all(
                    report -> report["gc_fraction"] <=
                        contract["max_gc_fraction"],
                    target_reports) &&
                soak_report["gc_fraction"] <=
                    contract["max_gc_fraction"]),
        "soak" => Dict(
            "wall_elapsed_ns" =>
                soak_report["wall_elapsed_ns"],
            "minimum_wall_elapsed_ns" =>
                contract["soak_duration_ns"],
            "completed_samples" =>
                soak_report["counters"][
                    "command_responses"],
            "minimum_samples" =>
                contract["soak_minimum_samples"],
            "accounting_passed" =>
                bounded_success_accounting(
                    soak_report, contract),
            "owner_tasks_stable" =>
                owner_tasks_are_stable(soak_report),
            "latency" => soak_latency,
            "passed" =>
                soak_report["wall_elapsed_ns"] >=
                    contract["soak_duration_ns"] &&
                soak_report["counters"][
                    "command_responses"] >=
                    contract["soak_minimum_samples"] &&
                bounded_success_accounting(
                    soak_report, contract) &&
                owner_tasks_are_stable(soak_report) &&
                soak_latency["passed"]),
    )
    gates["all_evaluated_gates_passed"] = all(
        get(gate, "passed", true)
        for gate in values(gates))
    return gates
end

function derived_rate(
    calibrated_rate_hz,
    fraction,
    rounding_hz)
    rate = floor(
        calibrated_rate_hz * fraction / rounding_hz) *
        rounding_hz
    rate > 0 || error("derived operational rate was not positive")
    return rate
end

function minimum_soak_sample_count(contract, workload)
    scheduled_samples = cld(
        max(
            0,
            contract["soak_duration_ns"] -
                workload.primary_exposure_ns),
        workload.primary_period_ns) + 1
    # The execution-clock origin precedes the benchmark loop's wall start.
    # One additional schedule period keeps that setup skew from shortening
    # the measured wall interval below the unchanged soak-duration gate.
    return max(
        contract["soak_minimum_samples"],
        scheduled_samples + 1)
end

function gate8_summary_report(
    target_reports,
    calibration_reports,
    near_rate_hz,
    saturation_rate_hz,
    overload_rate_hz,
    soak_report)
    return Dict{String,Any}(
        "qualification" =>
            "single-host CPU, in-memory, two-owner reduced-order HIL runtime only",
        "target_completed_rate_hz_median" => median([
            report["completed_rate_hz"]
            for report in target_reports
        ]),
        "target_completed_rate_hz_minimum" => minimum(
            report["completed_rate_hz"]
            for report in target_reports),
        "calibrated_unpaced_rate_hz_minimum" => minimum(
            report["useful_completed_rate_hz"]
            for report in calibration_reports),
        "near_saturation_rate_hz" => near_rate_hz,
        "saturation_rate_hz" => saturation_rate_hz,
        "overload_rate_hz" => overload_rate_hz,
        "soak_completed_samples" =>
            soak_report["counters"]["command_responses"],
        "soak_wall_elapsed_ns" =>
            soak_report["wall_elapsed_ns"])
end

function report_gate8_failed_gates(gates)
    failures = sort!([
        name
        for (name, gate) in pairs(gates)
        if gate isa AbstractDict &&
            get(gate, "passed", true) === false
    ])
    for name in failures
        println(
            stderr,
            "Gate 8 failed gate $name: ",
            repr(gates[name]))
    end
    return failures
end

function gate8_main(arguments=ARGS)
    options = parse_gate8_arguments(arguments)
    repository_status = require_clean_repository()
    contract = TOML.parsefile(options.contract_path)
    validate_gate8_contract(contract)
    Threads.nthreads() == contract["julia_threads"] || error(
        "Gate 8 evidence requires exactly " *
        string(contract["julia_threads"]) *
        " Julia threads")
    Threads.nthreads(:default) ==
        contract["julia_threads"] || error(
            "Gate 8 evidence requires all declared Julia threads in the default pool")
    Threads.nthreads(:interactive) ==
        contract["julia_interactive_threads"] || error(
            "Gate 8 evidence requires the frozen interactive-pool thread count")
    Base.JLOptions().startupfile == 2 || error(
        "Gate 8 evidence requires --startup-file=no")
    Base.JLOptions().code_coverage == 0 || error(
        "Gate 8 allocation evidence cannot run under coverage instrumentation")
    LinearAlgebra.BLAS.set_num_threads(contract["blas_threads"])
    LinearAlgebra.BLAS.get_num_threads() ==
        contract["blas_threads"] || error(
            "Gate 8 evidence requires the predeclared BLAS thread count")

    workload = Operational.workload_from_contract(contract)
    histogram_config =
        Operational.histogram_config_from_contract(contract)
    environment = gate8_environment_snapshot(
        options.contract_path,
        repository_status,
        contract,
        workload)

    println("Gate 8: cold lifecycle and first use")
    flush(stdout)
    cold = cold_lifecycle_report(
        workload, histogram_config, contract)

    println("Gate 8: exact serial/deterministic/threaded replay")
    flush(stdout)
    correctness = exact_correctness_report(
        workload, histogram_config, contract)

    println("Gate 8: warming threaded SystemNanoClock runtime")
    flush(stdout)
    execute_gate8_warmup!(
        workload, histogram_config, contract)

    instrumentation_bytes =
        Harness.measure_instrumentation_allocations(
            workload,
            histogram_config,
            contract["allocation_frames"])
    allocation = gate8_allocation_report(
        workload, histogram_config, contract)
    calibration = gate8_calibration_report(
        histogram_config, contract, workload)

    baseline_config = Harness.BoundaryRunConfig(
        samples=contract["baseline_samples_per_run"],
        checkpoint_stride=contract["checkpoint_stride"])
    baseline_reports = Vector{Dict{String,Any}}()
    for run_index in 1:contract["baseline_runs"]
        println(
            "Gate 8: deterministic baseline $run_index/" *
            string(contract["baseline_runs"]))
        flush(stdout)
        push!(
            baseline_reports,
            execute_recorded_run(
                workload,
                baseline_config,
                histogram_config,
                contract,
                Operational.deterministic_execution_configuration(
                    contract);
                phase="deterministic_baseline",
                run_index,
                threaded=false))
    end

    target_config = Harness.BoundaryRunConfig(
        samples=contract["target_samples_per_run"],
        checkpoint_stride=contract["checkpoint_stride"])
    target_reports = Vector{Dict{String,Any}}()
    for run_index in 1:contract["target_runs"]
        println(
            "Gate 8: target 2 kHz run $run_index/" *
            string(contract["target_runs"]))
        flush(stdout)
        push!(
            target_reports,
            execute_recorded_run(
                workload,
                target_config,
                histogram_config,
                contract,
                Operational.threaded_execution_configuration(
                    contract);
                phase="target",
                run_index,
                threaded=true))
    end

    println("Gate 8: 16-frame consumer-interruption burst")
    flush(stdout)
    burst_config = Harness.BoundaryRunConfig(
        samples=contract["burst_samples"],
        checkpoint_stride=contract["checkpoint_stride"],
        stall_start_sequence=contract[
            "burst_start_sequence"],
        stall_frames=contract["burst_frames"])
    burst_report = execute_recorded_run(
        workload,
        burst_config,
        histogram_config,
        contract,
        Operational.threaded_execution_configuration(contract);
        phase="consumer_interruption_burst",
        run_index=1,
        threaded=true)

    println("Gate 8: optional science shedding and recovery")
    flush(stdout)
    science_config = Harness.BoundaryRunConfig(
        samples=contract["science_shed_samples"],
        checkpoint_stride=contract["checkpoint_stride"],
        science_stall_start_sequence=contract[
            "science_stall_start_sequence"],
        science_stall_frames=contract[
            "science_stall_primary_frames"])
    science_report = execute_recorded_run(
        workload,
        science_config,
        histogram_config,
        contract,
        Operational.threaded_execution_configuration(contract);
        phase="optional_science_shedding",
        run_index=1,
        threaded=true)

    calibration_config = Harness.BoundaryRunConfig(
        samples=contract["calibration_samples_per_run"],
        checkpoint_stride=contract[
            "calibration_samples_per_run"])
    calibration_reports = Vector{Dict{String,Any}}()
    for run_index in 1:contract["calibration_runs"]
        println(
            "Gate 8: unpaced capacity diagnostic $run_index/" *
            string(contract["calibration_runs"]))
        flush(stdout)
        push!(
            calibration_reports,
            execute_unpaced_run(
                workload,
                calibration_config,
                histogram_config,
                contract,
                run_index))
    end
    calibrated_rate_hz = minimum(
        report["useful_completed_rate_hz"]
        for report in calibration_reports)
    calibrated_rate_hz >=
        contract["minimum_calibrated_rate_hz"] || error(
            "calibrated capacity is below the predeclared minimum")
    near_rate_hz = derived_rate(
        calibrated_rate_hz,
        contract["near_saturation_fraction"],
        contract["rate_rounding_hz"])
    saturation_rate_hz = derived_rate(
        calibrated_rate_hz,
        contract["saturation_fraction"],
        contract["rate_rounding_hz"])
    overload_rate_hz = derived_rate(
        calibrated_rate_hz,
        contract["overload_fraction"],
        contract["rate_rounding_hz"])

    near_workload = workload_at_rate(
        workload,
        near_rate_hz;
        preserve_capacity_time_headroom=contract[
            "derived_rate_preserve_capacity_time_headroom"])
    near_config = Harness.BoundaryRunConfig(
        samples=contract["near_saturation_samples_per_run"],
        checkpoint_stride=contract["checkpoint_stride"])
    near_reports = Vector{Dict{String,Any}}()
    for run_index in 1:contract["near_saturation_runs"]
        println(
            "Gate 8: near saturation $run_index/" *
            string(contract["near_saturation_runs"]) *
            " at $(near_rate_hz) Hz")
        flush(stdout)
        push!(
            near_reports,
            execute_recorded_run(
                near_workload,
                near_config,
                histogram_config,
                contract,
                Operational.threaded_execution_configuration(
                    contract);
                phase="near_saturation",
                run_index,
                threaded=true))
    end

    saturation_workload = workload_at_rate(
        workload,
        saturation_rate_hz;
        preserve_capacity_time_headroom=contract[
            "derived_rate_preserve_capacity_time_headroom"])
    saturation_config = Harness.BoundaryRunConfig(
        samples=contract["saturation_samples_per_run"],
        checkpoint_stride=contract["checkpoint_stride"])
    saturation_reports = Vector{Dict{String,Any}}()
    for run_index in 1:contract["saturation_runs"]
        println(
            "Gate 8: saturation $run_index/" *
            string(contract["saturation_runs"]) *
            " at $(saturation_rate_hz) Hz")
        flush(stdout)
        push!(
            saturation_reports,
            execute_recorded_run(
                saturation_workload,
                saturation_config,
                histogram_config,
                contract,
                Operational.threaded_execution_configuration(
                    contract);
                phase="saturation",
                run_index,
                threaded=true))
    end

    println(
        "Gate 8: bounded required overload at " *
        "$(overload_rate_hz) Hz")
    flush(stdout)
    overload_workload = workload_at_rate(
        workload,
        overload_rate_hz;
        preserve_capacity_time_headroom=contract[
            "derived_rate_preserve_capacity_time_headroom"])
    overload_result = Operational.execute_required_overload(
        contract,
        overload_workload,
        histogram_config)
    overload = overload_report(
        overload_result,
        overload_rate_hz,
        overload_workload)

    println("Gate 8: fresh-run recovery")
    flush(stdout)
    recovery_config = Harness.BoundaryRunConfig(
        samples=contract["recovery_samples"],
        checkpoint_stride=contract["checkpoint_stride"])
    recovery_report = execute_recorded_run(
        workload,
        recovery_config,
        histogram_config,
        contract,
        Operational.threaded_execution_configuration(contract);
        phase="fresh_run_recovery",
        run_index=1,
        threaded=true)

    println("Gate 8: warming injected-fault specialization")
    flush(stdout)
    Operational.warm_injected_owner_failure_specialization!(
        contract, histogram_config)

    injected_failure_contract = deepcopy(contract)
    injected_failure_contract[
        "execution_owner_maximum_lateness_ns"] =
        600_000_000_000
    injected_reports = Vector{Dict{String,Any}}()
    for run_index in 1:contract["injected_failure_runs"]
        println(
            "Gate 8: injected owner failure $run_index/" *
            string(contract["injected_failure_runs"]))
        flush(stdout)
        GC.gc()
        result = Operational.execute_injected_owner_failure(
            injected_failure_contract, histogram_config)
        push!(
            injected_reports,
            injected_failure_report(result, run_index))
    end

    println("Gate 8: retained-lease named drain deficit")
    flush(stdout)
    deficit = named_deficit_report(
        Operational.execute_named_drain_deficit(contract))

    soak_samples = minimum_soak_sample_count(
        contract, workload)
    println(
        "Gate 8: 300 s soak ($soak_samples WFS products)")
    flush(stdout)
    soak_config = Harness.BoundaryRunConfig(
        samples=soak_samples,
        checkpoint_stride=contract["checkpoint_stride"])
    soak_report = execute_recorded_run(
        workload,
        soak_config,
        histogram_config,
        contract,
        Operational.threaded_execution_configuration(contract);
        phase="soak",
        run_index=1,
        threaded=true)

    gates = gate8_gate_report(
        correctness,
        baseline_reports,
        target_reports,
        burst_report,
        science_report,
        calibration_reports,
        near_reports,
        saturation_reports,
        overload,
        recovery_report,
        injected_reports,
        deficit,
        soak_report,
        allocation,
        instrumentation_bytes,
        contract)
    if !gates["all_evaluated_gates_passed"]
        failed = report_gate8_failed_gates(gates)
        error(
            "predeclared Gate 8 evidence gates failed: " *
            join(failed, ", "))
    end

    artifact = Dict{String,Any}(
        "schema_version" => 1,
        "name" => contract["name"],
        "evidence_class" => contract["evidence_class"],
        "contract" => contract,
        "environment" => environment,
        "cold_lifecycle" => cold,
        "calibration" => calibration,
        "correctness" => correctness,
        "allocation" => merge(
            allocation,
            Dict(
                "instrumentation_bytes" =>
                    instrumentation_bytes)),
        "deterministic_baseline_runs" => baseline_reports,
        "target_runs" => target_reports,
        "consumer_interruption_burst" => burst_report,
        "optional_science_shedding" => science_report,
        "unpaced_capacity_runs" => calibration_reports,
        "near_saturation_runs" => near_reports,
        "saturation_runs" => saturation_reports,
        "required_overload" => overload,
        "fresh_run_recovery" => recovery_report,
        "injected_owner_failures" => injected_reports,
        "named_drain_deficit" => deficit,
        "soak" => soak_report,
        "gates" => gates,
        "summary" => gate8_summary_report(
            target_reports,
            calibration_reports,
            near_rate_hz,
            saturation_rate_hz,
            overload_rate_hz,
            soak_report))
    written = write_artifact(options.output_path, artifact)
    println(
        "Gate 8 artifact: $(options.output_path) " *
        "sha256=$(written.artifact_hash)")
    println("Gate 8 manifest: $(written.manifest_path)")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    gate8_main()
end
