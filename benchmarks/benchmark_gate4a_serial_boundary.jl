using AdaptiveOpticsHIL
using Clocks
using Dates
using HdrHistogram
using LinearAlgebra
using Pkg
using SHA
using Statistics
using TOML

const BENCHMARK_ROOT = @__DIR__
const REPOSITORY_ROOT = normpath(joinpath(BENCHMARK_ROOT, ".."))
const DEFAULT_CONTRACT = joinpath(
    BENCHMARK_ROOT, "contracts", "gate4a_serial_boundary.toml")

include(joinpath(
    BENCHMARK_ROOT, "support", "gate4a_boundary_harness.jl"))
include(joinpath(
    BENCHMARK_ROOT, "support", "hdr_histogram_artifact.jl"))

const Harness = Gate4ABoundaryHarness
const HistogramArtifact = HILHdrHistogramArtifact

function parse_arguments(arguments)
    contract_path = DEFAULT_CONTRACT
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
            error("unknown benchmark argument: $argument")
        end
        index += 1
    end
    output_path === nothing && error(
        "durable evidence requires an explicit --output path")
    return (; contract_path, output_path)
end

function require_clean_repository()
    status = readchomp(
        `git -C $REPOSITORY_ROOT status --porcelain=v1 --untracked-files=all`)
    isempty(status) || error(
        "durable evidence requires a clean repository; commit or remove " *
        "every tracked and untracked change before measurement")
    return status
end

function contract_workload(contract)
    workload = contract["workload"]
    return Harness.Gate4AWorkloadConfig(
        primary_period_ns=workload["primary_period_ns"],
        primary_exposure_ns=workload["primary_exposure_ns"],
        optical_sample_period_ns=workload[
            "optical_sample_period_ns"],
        feedback_period_ns=workload["feedback_period_ns"],
        feedback_phase_ns=workload["feedback_phase_ns"],
        feedback_exposure_ns=workload["feedback_exposure_ns"],
        command_capacity=workload["command_payload_pool_capacity"],
        primary_product_capacity=workload[
            "primary_product_capacity"],
        feedback_product_capacity=workload[
            "feedback_product_capacity"],
        complete_product_lead_time_ns=workload[
            "complete_product_lead_time_ns"],
        maximum_lease_hold_time_ns=workload[
            "maximum_lease_hold_time_ns"],
        controller_gain=workload["controller_gain"],
        run_seed=workload["run_seed"])
end

function contract_histograms(contract)
    return Harness.HistogramConfig(
        contract["histogram_lowest_ns"],
        contract["histogram_highest_ns"],
        contract["histogram_significant_figures"])
end

function validate_contract(contract)
    contract["schema_version"] == 1 || error(
        "unsupported Gate 4A contract schema")
    contract["fixed_samples_per_run"] >=
        contract["minimum_samples_for_p99_9"] || error(
        "fixed run is too short for its declared p99.9 evidence")
    contract["saturation_samples_per_run"] >=
        contract["minimum_samples_for_p99_9"] || error(
        "saturation run is too short for its declared p99.9 evidence")
    contract["fixed_runs"] >= 3 || error(
        "durable fixed-arrival evidence requires at least three runs")
    contract["saturation_runs"] >= 3 || error(
        "durable saturation evidence requires at least three runs")
    contract["stall_frames"] > 0 || error(
        "fixed-arrival evidence requires a nonempty injected stall")
    workload = contract["workload"]
    workload["command_payload_pool_capacity"] ==
        workload["command_submission_capacity"] ==
        workload["command_completion_capacity"] || error(
        "the Gate 4A command payload, submission, and completion " *
        "capacities must match")
    workload["primary_product_capacity"] ==
        workload["primary_completion_capacity"] || error(
        "the Gate 4A primary product and completion capacities must match")
    workload["feedback_product_capacity"] ==
        workload["feedback_completion_capacity"] || error(
        "the Gate 4A feedback product and completion capacities must match")
    workload["command_payload_bytes"] ==
        workload["command_payload_elements"] * sizeof(Float64) || error(
        "the Gate 4A command payload byte count is inconsistent")
    return true
end

_artifact_value(value::Unsigned) = Int(value)
_artifact_value(value) = value

function counter_snapshot(counters::Harness.BoundaryCounters)
    values = Dict{String,Any}()
    for field in fieldnames(typeof(counters))
        value = getfield(counters, field)
        values[string(field)] = _artifact_value(value)
    end
    return values
end

function ring_snapshot(accounting)
    return Dict{String,Any}(
        "capacity" => accounting.capacity,
        "occupancy" => accounting.occupancy,
        "producer_sequence" => Int(accounting.producer_sequence),
        "consumer_sequence" => Int(accounting.consumer_sequence),
        "closed" => accounting.closed,
    )
end

function pool_snapshot(::Nothing)
    return Dict{String,Any}(
        "present" => false)
end

function pool_snapshot(accounting)
    return Dict{String,Any}(
        "present" => true,
        "capacity" => accounting.capacity,
        "free" => accounting.free,
        "producer_owned" => accounting.producer_owned,
        "queued" => accounting.queued,
        "consumer_leased" => accounting.consumer_leased,
    )
end

function accounting_snapshot(accounting)
    acquisitions = Vector{Dict{String,Any}}()
    for (index, acquisition) in enumerate(accounting.acquisitions)
        push!(acquisitions, Dict{String,Any}(
            "index" => index,
            "descriptors" => ring_snapshot(acquisition.descriptors),
            "products" => pool_snapshot(acquisition.products),
        ))
    end
    return Dict{String,Any}(
        "quiescent" =>
            AdaptiveOpticsHIL.Serial.serial_run_is_quiescent(accounting),
        "command_submissions" =>
            ring_snapshot(accounting.command_submissions),
        "command_completions" =>
            ring_snapshot(accounting.command_completions),
        "command_credits" =>
            pool_snapshot(accounting.command_credits),
        "command_payloads" =>
            pool_snapshot(accounting.command_payloads),
        "command_dispositions" => accounting.command_dispositions,
        "active_command_correlations" =>
            accounting.active_command_correlations,
        "acquisitions" => acquisitions,
    )
end

function checkpoint_snapshot(
    result::Harness.BoundaryRunResult)
    checkpoints = Vector{Dict{String,Any}}(
        undef, result.checkpoint_count)
    @inbounds for index in 1:result.checkpoint_count
        checkpoint = result.checkpoints[index]
        checkpoints[index] = Dict{String,Any}(
            "kind" => string(checkpoint.kind),
            "scheduled_sequence" =>
                Int(checkpoint.scheduled_sequence),
            "scheduled_deadline_ns" =>
                checkpoint.scheduled_deadline_ns,
            "observed_elapsed_ns" =>
                checkpoint.observed_elapsed_ns,
            "offered" => Int(checkpoint.offered),
            "published" => Int(checkpoint.published),
            "observed" => Int(checkpoint.observed),
            "primary_occupancy" =>
                checkpoint.primary_occupancy,
            "feedback_occupancy" =>
                checkpoint.feedback_occupancy,
        )
    end
    return checkpoints
end

function histogram_fields(histograms::Harness.BoundaryHistograms)
    return (
        publication_lateness_ns=histograms.publication_lateness,
        adapter_observation_delay_ns=
            histograms.adapter_observation_delay,
        rtc_processing_ns=histograms.rtc_processing,
        command_admission_delay_ns=
            histograms.command_admission_delay,
        command_application_delay_ns=
            histograms.command_application_delay,
        closed_loop_response_ns=histograms.closed_loop_response,
        controller_service_ns=histograms.controller_service,
    )
end

function histogram_summary(
    histogram,
    histogram_config::Harness.HistogramConfig,
    contract;
    include_raw::Bool)
    samples = Int(HdrHistogram.total_count(histogram))
    samples >= contract["minimum_samples_for_p99"] || error(
        "histogram does not support the declared p99")
    summary = Dict{String,Any}(
        "samples" => samples,
        "minimum_ns" => Int(min(histogram)),
        "p50_ns" => Int(
            HdrHistogram.value_at_percentile(histogram, 50.0)),
        "p90_ns" => Int(
            HdrHistogram.value_at_percentile(histogram, 90.0)),
        "p99_ns" => Int(
            HdrHistogram.value_at_percentile(histogram, 99.0)),
        "maximum_ns" => Int(max(histogram)),
    )
    if samples >= contract["minimum_samples_for_p99_9"]
        summary["p99_9_ns"] = Int(
            HdrHistogram.value_at_percentile(histogram, 99.9))
    end
    if include_raw
        merge!(summary,
            HistogramArtifact.verified_sparse_histogram(
                histogram,
                histogram_config.lowest_ns,
                histogram_config.highest_ns,
                histogram_config.significant_figures,
                samples))
    end
    return summary
end

function histogram_report(
    result::Harness.BoundaryRunResult,
    histogram_config::Harness.HistogramConfig,
    contract;
    only_controller_service::Bool=false)
    report = Dict{String,Any}()
    for (name, histogram) in pairs(
        histogram_fields(result.histograms))
        only_controller_service &&
            name != :controller_service_ns && continue
        report[string(name)] = histogram_summary(
            histogram, histogram_config, contract; include_raw=true)
    end
    return report
end

function deterministic_histogram_signature(result)
    signature = String[]
    fields = histogram_fields(result.histograms)
    for name in (
        :publication_lateness_ns,
        :adapter_observation_delay_ns,
        :rtc_processing_ns,
        :command_admission_delay_ns,
        :command_application_delay_ns,
        :closed_loop_response_ns,
    )
        encoded = HistogramArtifact.encode_sparse_histogram(
            getproperty(fields, name))
        push!(signature, encoded["histogram_base64"])
    end
    return signature
end

function execute_cached_run(
    workload,
    run_config,
    histogram_config)
    driver = Harness.prepare_boundary_driver(
        Clocks.CachedNanoClock(0),
        workload,
        run_config,
        histogram_config)
    result = Harness.execute_boundary_run!(driver)
    Harness.validate_boundary_result(result, run_config)
    return result
end

function check_exact_replay(
    workload,
    histogram_config,
    frames::Int)
    frames >= 32 || error(
        "exact replay requires at least 32 frames")
    stall_frames = min(8, frames ÷ 8)
    stall_start = frames ÷ 2
    config = Harness.BoundaryRunConfig(
        samples=frames,
        checkpoint_stride=max(1, frames ÷ 8),
        stall_start_sequence=stall_start,
        stall_frames=stall_frames)
    first_result = execute_cached_run(
        workload, config, histogram_config)
    second_result = execute_cached_run(
        workload, config, histogram_config)
    counter_snapshot(first_result.counters) ==
        counter_snapshot(second_result.counters) || error(
        "cached-clock replay changed exact counters")
    checkpoint_snapshot(first_result) ==
        checkpoint_snapshot(second_result) || error(
        "cached-clock replay changed arrival checkpoints")
    deterministic_histogram_signature(first_result) ==
        deterministic_histogram_signature(second_result) || error(
        "cached-clock replay changed execution-clock histograms")
    return Dict{String,Any}(
        "passed" => true,
        "frames" => frames,
        "stall_start_sequence" => stall_start,
        "stall_frames" => stall_frames,
        "counters" => counter_snapshot(first_result.counters),
    )
end

function warm_system_specialization!(
    workload,
    histogram_config)
    # Recursive JIT work must not consume the measured run's bounded product
    # capacity after its clock mapping has been armed. Values do not affect the
    # concrete driver type, so compile that exact type using a slow sacrificial
    # schedule, then construct a fresh 2 kHz driver below.
    compilation_workload = Harness.Gate4AWorkloadConfig(
        primary_period_ns=1_000_000_000,
        primary_exposure_ns=100_000_000,
        optical_sample_period_ns=100_000_000,
        feedback_period_ns=1_500_000_000,
        feedback_phase_ns=250_000_000,
        feedback_exposure_ns=100_000_000,
        command_capacity=workload.command_capacity,
        primary_product_capacity=
            workload.primary_product_capacity,
        feedback_product_capacity=
            workload.feedback_product_capacity,
        complete_product_lead_time_ns=
            workload.complete_product_lead_time_ns,
        maximum_lease_hold_time_ns=
            workload.maximum_lease_hold_time_ns,
        controller_gain=workload.controller_gain,
        run_seed=workload.run_seed)
    config = Harness.BoundaryRunConfig(
        samples=1, checkpoint_stride=1)
    driver = Harness.prepare_boundary_driver(
        Clocks.SystemNanoClock(),
        compilation_workload,
        config,
        histogram_config)
    result = Harness.execute_boundary_run!(driver)
    Harness.validate_boundary_result(result, config)
    return nothing
end

function execute_fixed_run(
    workload,
    run_config,
    histogram_config)
    driver = Harness.prepare_boundary_driver(
        Clocks.SystemNanoClock(),
        workload,
        run_config,
        histogram_config)
    result = Harness.execute_boundary_run!(driver)
    Harness.validate_boundary_result(result, run_config)
    return result
end

function measured_allocations(
    workload,
    histogram_config,
    frames::Int)
    config = Harness.BoundaryRunConfig(
        samples=frames, checkpoint_stride=frames)
    driver = Harness.prepare_boundary_driver(
        Clocks.CachedNanoClock(0),
        workload,
        config,
        histogram_config)
    result = nothing
    GC.gc()
    bytes = @allocated result =
        Harness.execute_boundary_run!(driver)
    Harness.validate_boundary_result(result, config)
    return Dict{String,Any}(
        "frames" => frames,
        "inclusive_bytes" => bytes,
        "inclusive_bytes_per_frame" => bytes / frames,
    )
end

function fixed_run_report(
    result,
    run_index,
    histogram_config,
    contract)
    elapsed_ns = Int(result.wall_end_ns - result.wall_start_ns)
    seconds = elapsed_ns / 1.0e9
    counters = result.counters
    return Dict{String,Any}(
        "run" => run_index,
        "wall_elapsed_ns" => elapsed_ns,
        "configured_offered_rate_hz" =>
            1.0e9 / contract["workload"]["primary_period_ns"],
        "published_rate_hz" =>
            Int(counters.published_primary) / seconds,
        "command_enqueued_rate_hz" =>
            Int(counters.commands_enqueued) / seconds,
        "command_admitted_rate_hz" =>
            Int(counters.commands_admitted) / seconds,
        "command_applied_rate_hz" =>
            Int(counters.commands_applied) / seconds,
        "completed_rate_hz" =>
            Int(counters.command_responses) / seconds,
        "counters" => counter_snapshot(counters),
        "accounting" => accounting_snapshot(result.accounting),
        "arrival_checkpoints" => checkpoint_snapshot(result),
        "histograms" => histogram_report(
            result, histogram_config, contract),
    )
end

function saturation_run_report(
    result,
    run_index,
    histogram_config,
    contract)
    elapsed_ns = Int(result.wall_end_ns - result.wall_start_ns)
    seconds = elapsed_ns / 1.0e9
    counters = result.counters
    return Dict{String,Any}(
        "run" => run_index,
        "classification" =>
            "unpaced maximum-useful-throughput diagnostic",
        "wall_elapsed_ns" => elapsed_ns,
        "offered_rate_hz" =>
            Int(counters.commands_offered) / seconds,
        "enqueued_rate_hz" =>
            Int(counters.commands_enqueued) / seconds,
        "admitted_rate_hz" =>
            Int(counters.commands_admitted) / seconds,
        "applied_rate_hz" =>
            Int(counters.commands_applied) / seconds,
        "useful_completed_rate_hz" =>
            Int(counters.command_responses) / seconds,
        "counters" => counter_snapshot(counters),
        "accounting" => accounting_snapshot(result.accounting),
        "controller_service_histogram" => histogram_report(
            result,
            histogram_config,
            contract;
            only_controller_service=true)[
                "controller_service_ns"],
        "execution_clock_histograms_qualified_for_latency" => false,
    )
end

function timer_calibration(histogram_config; samples=100_000)
    clock = Clocks.SystemNanoClock()
    warm_timer_histogram = HdrHistogram.Histogram(
        histogram_config.lowest_ns,
        histogram_config.highest_ns,
        histogram_config.significant_figures)
    warm_record_histogram = HdrHistogram.Histogram(
        histogram_config.lowest_ns,
        histogram_config.highest_ns,
        histogram_config.significant_figures)
    for _ in 1:1_000
        first = Clocks.time_nanos(clock)
        second = Clocks.time_nanos(clock)
        HdrHistogram.record_value!(
            warm_timer_histogram, max(0, second - first))
        HdrHistogram.record_value!(warm_record_histogram, 1)
    end
    timer_histogram = HdrHistogram.Histogram(
        histogram_config.lowest_ns,
        histogram_config.highest_ns,
        histogram_config.significant_figures)
    record_histogram = HdrHistogram.Histogram(
        histogram_config.lowest_ns,
        histogram_config.highest_ns,
        histogram_config.significant_figures)
    timer_wall_start = time_ns()
    for _ in 1:samples
        first = Clocks.time_nanos(clock)
        second = Clocks.time_nanos(clock)
        HdrHistogram.record_value!(
            timer_histogram, max(0, second - first))
    end
    timer_wall_elapsed = Int(time_ns() - timer_wall_start)
    record_wall_start = time_ns()
    for _ in 1:samples
        HdrHistogram.record_value!(record_histogram, 1)
    end
    record_wall_elapsed = Int(time_ns() - record_wall_start)
    HdrHistogram.total_count(timer_histogram) == samples || error(
        "timer calibration retained or lost samples")
    HdrHistogram.total_count(record_histogram) == samples || error(
        "histogram recorder calibration retained or lost samples")
    return Dict{String,Any}(
        "samples" => samples,
        "two_timer_queries_plus_record_wall_ns_per_sample" =>
            timer_wall_elapsed / samples,
        "histogram_record_wall_ns_per_sample" =>
            record_wall_elapsed / samples,
        "observed_timer_delta_minimum_ns" =>
            Int(min(timer_histogram)),
        "observed_timer_delta_p50_ns" => Int(
            HdrHistogram.value_at_percentile(
                timer_histogram, 50.0)),
        "observed_timer_delta_p99_ns" => Int(
            HdrHistogram.value_at_percentile(
                timer_histogram, 99.0)),
    )
end

function package_snapshot(names)
    dependencies = Pkg.dependencies()
    report = Dict{String,Any}()
    for name in names
        matches = filter(
            pair -> pair.second.name == name,
            collect(dependencies))
        length(matches) == 1 || error(
            "could not resolve exactly one dependency named $name")
        info = only(matches).second
        package = Dict{String,Any}(
            "version" => string(info.version),
            "tracking_path" => info.is_tracking_path,
            "tracking_repository" => info.is_tracking_repo,
        )
        info.tree_hash === nothing ||
            (package["tree_hash"] = info.tree_hash)
        info.git_revision === nothing ||
            (package["git_revision"] = info.git_revision)
        info.git_source === nothing ||
            (package["git_source"] = info.git_source)
        report[name] = package
    end
    return report
end

function first_matching_line(path, prefix)
    isfile(path) || return ""
    for line in eachline(path)
        startswith(line, prefix) &&
            return strip(split(line, ':'; limit=2)[2])
    end
    return ""
end

function first_key_value(path, key)
    isfile(path) || return ""
    prefix = key * "="
    for line in eachline(path)
        startswith(line, prefix) &&
            return strip(split(line, '='; limit=2)[2], ['"'])
    end
    return ""
end

function os_description()
    description = first_key_value(
        "/etc/os-release", "PRETTY_NAME")
    isempty(description) || return description
    return string(Sys.KERNEL)
end

kernel_release() = Sys.iswindows() ?
    string(Sys.KERNEL) : readchomp(`uname -r`)

function cpu_governors()
    root = "/sys/devices/system/cpu"
    isdir(root) || return String[]
    governors = Set{String}()
    for entry in readdir(root)
        startswith(entry, "cpu") || continue
        all(isdigit, entry[4:end]) || continue
        path = joinpath(
            root, entry, "cpufreq", "scaling_governor")
        isfile(path) && push!(governors, strip(read(path, String)))
    end
    return sort!(collect(governors))
end

function environment_snapshot(
    contract_path,
    repository_status)
    manifest_path = joinpath(BENCHMARK_ROOT, "Manifest.toml")
    project_path = joinpath(BENCHMARK_ROOT, "Project.toml")
    return Dict{String,Any}(
        "captured_at_utc" =>
            Dates.format(Dates.now(Dates.UTC),
                dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"),
        "repository_commit" => readchomp(
            `git -C $REPOSITORY_ROOT rev-parse HEAD`),
        "repository_branch" => readchomp(
            `git -C $REPOSITORY_ROOT branch --show-current`),
        "repository_status_before_measurement" =>
            repository_status,
        "contract_sha256" =>
            bytes2hex(SHA.sha256(read(contract_path))),
        "benchmark_project_sha256" =>
            bytes2hex(SHA.sha256(read(project_path))),
        "resolved_manifest_sha256" =>
            bytes2hex(SHA.sha256(read(manifest_path))),
        "julia_version" => string(VERSION),
        "julia_commit" => string(Base.GIT_VERSION_INFO.commit),
        "julia_threads" => Threads.nthreads(),
        "julia_num_threads" =>
            get(ENV, "JULIA_NUM_THREADS", ""),
        "julia_cpu_target" =>
            get(ENV, "JULIA_CPU_TARGET", ""),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        "openblas_num_threads" =>
            get(ENV, "OPENBLAS_NUM_THREADS", ""),
        "omp_num_threads" => get(ENV, "OMP_NUM_THREADS", ""),
        "mkl_num_threads" => get(ENV, "MKL_NUM_THREADS", ""),
        "kernel" => string(Sys.KERNEL),
        "kernel_release" => kernel_release(),
        "operating_system" => os_description(),
        "machine" => Sys.MACHINE,
        "word_size" => Sys.WORD_SIZE,
        "cpu_name" => Sys.CPU_NAME,
        "cpu_model" => let model =
                first_matching_line("/proc/cpuinfo", "model name")
            isempty(model) ? Sys.CPU_NAME : model
        end,
        "logical_cpu_threads" => Sys.CPU_THREADS,
        "allowed_cpu_list" =>
            first_matching_line(
                "/proc/self/status", "Cpus_allowed_list"),
        "cpu_frequency_governors" => cpu_governors(),
        "affinity_or_isolation_applied_by_benchmark" => false,
        "packages" => package_snapshot((
            "AdaptiveOpticsHIL",
            "AdaptiveOpticsSim",
            "Clocks",
            "HdrHistogram",
        )),
        "invocation" =>
            "julia --startup-file=no --project=benchmarks " *
            "benchmarks/benchmark_gate4a_serial_boundary.jl " *
            "--output <artifact>",
    )
end

function gate_report(
    fixed_reports,
    allocation_report,
    instrumentation_bytes,
    exact_replay,
    contract)
    publication_p99 = [
        run["histograms"]["publication_lateness_ns"]["p99_ns"]
        for run in fixed_reports
    ]
    observation_p99 = [
        run["histograms"]["adapter_observation_delay_ns"]["p99_ns"]
        for run in fixed_reports
    ]
    response_p99 = [
        run["histograms"]["closed_loop_response_ns"]["p99_ns"]
        for run in fixed_reports
    ]
    target = contract["fixed_samples_per_run"]
    accounting_reconciled = all(fixed_reports) do run
        counters = run["counters"]
        run["accounting"]["quiescent"] &&
            counters["offered_primary"] == target &&
            counters["published_primary"] == target &&
            counters["observed_primary"] == target &&
            counters["commands_enqueued"] == target &&
            counters["commands_admitted"] == target &&
            counters["commands_applied"] == target &&
            counters["outcomes_consumed"] == target &&
            counters["command_responses"] == target &&
            counters["commands_rejected"] == 0 &&
            counters["dropped_primary"] == 0 &&
            counters["primary_sequence_gaps"] == 0 &&
            counters["command_sequence_gaps"] == 0 &&
            counters["outcome_sequence_gaps"] == 0
    end
    stall_preserved = all(fixed_reports) do run
        counters = run["counters"]
        counters["stall_end_offered"] -
            counters["stall_start_offered"] ==
            contract["stall_frames"] &&
            counters["stall_end_observed"] ==
            counters["stall_start_observed"] &&
            counters["maximum_primary_occupancy"] >=
            contract["stall_frames"]
    end
    maximum_lease_hold = maximum(
        run["counters"]["maximum_product_lease_hold_ns"]
        for run in fixed_reports)
    gates = Dict{String,Any}(
        "exact_cached_clock_replay" => Dict(
            "passed" => exact_replay["passed"]),
        "fixed_accounting_reconciled" => Dict(
            "passed" => accounting_reconciled),
        "fixed_arrivals_preserved_through_stall" => Dict(
            "passed" => stall_preserved,
            "stall_frames" => contract["stall_frames"]),
        "product_lease_hold" => Dict(
            "worst_observed_ns" => maximum_lease_hold,
            "maximum_ns" => contract["workload"][
                "maximum_lease_hold_time_ns"],
            "passed" => maximum_lease_hold <=
                contract["workload"][
                    "maximum_lease_hold_time_ns"]),
        "instrumentation_allocation" => Dict(
            "observed_bytes" => instrumentation_bytes,
            "maximum_bytes" =>
                contract["max_instrumentation_alloc_bytes"],
            "passed" => instrumentation_bytes <=
                contract["max_instrumentation_alloc_bytes"]),
        "inclusive_allocation" => Dict(
            "observed_bytes_per_frame" =>
                allocation_report["inclusive_bytes_per_frame"],
            "maximum_bytes_per_frame" =>
                contract["max_inclusive_alloc_bytes_per_frame"],
            "passed" =>
                allocation_report["inclusive_bytes_per_frame"] <=
                contract["max_inclusive_alloc_bytes_per_frame"]),
        "fixed_p99_publication_lateness" => Dict(
            "worst_observed_ns" => maximum(publication_p99),
            "maximum_ns" =>
                contract["max_fixed_p99_publication_lateness_ns"],
            "passed" => maximum(publication_p99) <=
                contract[
                    "max_fixed_p99_publication_lateness_ns"]),
        "fixed_p99_adapter_observation_delay" => Dict(
            "worst_observed_ns" => maximum(observation_p99),
            "maximum_ns" =>
                contract["max_fixed_p99_observation_delay_ns"],
            "passed" => maximum(observation_p99) <=
                contract[
                    "max_fixed_p99_observation_delay_ns"]),
        "fixed_p99_closed_loop_response" => Dict(
            "worst_observed_ns" => maximum(response_p99),
            "maximum_ns" =>
                contract["max_fixed_p99_closed_loop_response_ns"],
            "passed" => maximum(response_p99) <=
                contract[
                    "max_fixed_p99_closed_loop_response_ns"]),
        "relative_latency" => Dict(
            "evaluated" => false,
            "reason" =>
                "first comparable Gate 4A artifact establishes baseline"),
    )
    evaluated_passes = Bool[]
    for gate in values(gates)
        haskey(gate, "passed") &&
            push!(evaluated_passes, gate["passed"])
    end
    gates["all_evaluated_gates_passed"] = all(evaluated_passes)
    return gates
end

function summary_report(fixed_reports, saturation_reports)
    fixed_rates = [
        report["completed_rate_hz"]
        for report in fixed_reports
    ]
    saturation_rates = [
        report["useful_completed_rate_hz"]
        for report in saturation_reports
    ]
    return Dict{String,Any}(
        "fixed_completed_rate_hz_median" =>
            median(fixed_rates),
        "fixed_completed_rate_hz_minimum" =>
            minimum(fixed_rates),
        "unpaced_useful_rate_hz_median" =>
            median(saturation_rates),
        "unpaced_useful_rate_hz_minimum" =>
            minimum(saturation_rates),
        "qualification" =>
            "serial CPU, in-memory, reduced-order boundary only",
    )
end

_gate_failed(::Any) = false
_gate_failed(gate::AbstractDict) =
    get(gate, "passed", true) === false

function report_failed_gates(gates)
    names = sort!([
        name
        for (name, gate) in pairs(gates)
        if _gate_failed(gate)
    ])
    for name in names
        println(stderr,
            "Gate 4A failed gate $name: ",
            repr(gates[name]))
    end
    return names
end

function write_artifact(output_path, artifact)
    mkpath(dirname(output_path))
    open(output_path, "w") do io
        TOML.print(io, artifact; sorted=true)
    end
    artifact_hash = bytes2hex(SHA.sha256(read(output_path)))
    manifest_path = joinpath(
        dirname(output_path), "artifact-manifest.toml")
    manifest = Dict{String,Any}(
        "schema_version" => 1,
        "artifact_file" => basename(output_path),
        "artifact_sha256" => artifact_hash,
        "source_revision" =>
            artifact["environment"]["repository_commit"],
        "contract_sha256" =>
            artifact["environment"]["contract_sha256"],
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    return (; artifact_hash, manifest_path)
end

function main(arguments=ARGS)
    options = parse_arguments(arguments)
    repository_status = require_clean_repository()
    Threads.nthreads() == 1 || error(
        "Gate 4A evidence requires exactly one Julia thread")
    LinearAlgebra.BLAS.set_num_threads(1)
    LinearAlgebra.BLAS.get_num_threads() == 1 || error(
        "Gate 4A evidence requires exactly one BLAS thread")

    contract = TOML.parsefile(options.contract_path)
    validate_contract(contract)
    workload = contract_workload(contract)
    histogram_config = contract_histograms(contract)
    environment = environment_snapshot(
        options.contract_path, repository_status)

    println("Gate 4A: warming cached-clock serial boundary")
    flush(stdout)
    warm_config = Harness.BoundaryRunConfig(
        samples=contract["warmup_frames"],
        checkpoint_stride=contract["warmup_frames"])
    execute_cached_run(workload, warm_config, histogram_config)

    println("Gate 4A: checking exact cached-clock replay")
    flush(stdout)
    exact_replay = check_exact_replay(
        workload,
        histogram_config,
        contract["correctness_frames"])

    instrumentation_bytes =
        Harness.measure_instrumentation_allocations(
            workload,
            histogram_config,
            contract["allocation_frames"])
    allocation_report = measured_allocations(
        workload,
        histogram_config,
        contract["allocation_frames"])
    calibration = timer_calibration(histogram_config)

    println("Gate 4A: warming SystemNanoClock specialization")
    flush(stdout)
    warm_system_specialization!(workload, histogram_config)
    execute_fixed_run(
        workload, warm_config, histogram_config)

    fixed_config = Harness.BoundaryRunConfig(
        samples=contract["fixed_samples_per_run"],
        checkpoint_stride=contract["checkpoint_stride"],
        stall_start_sequence=contract["stall_start_sequence"],
        stall_frames=contract["stall_frames"])
    fixed_reports = Vector{Dict{String,Any}}()
    for run_index in 1:contract["fixed_runs"]
        println(
            "Gate 4A: fixed-arrival run $run_index/" *
            string(contract["fixed_runs"]))
        flush(stdout)
        result = execute_fixed_run(
            workload, fixed_config, histogram_config)
        push!(fixed_reports, fixed_run_report(
            result,
            run_index,
            histogram_config,
            contract))
    end

    saturation_config = Harness.BoundaryRunConfig(
        samples=contract["saturation_samples_per_run"],
        checkpoint_stride=contract["saturation_samples_per_run"])
    saturation_reports = Vector{Dict{String,Any}}()
    for run_index in 1:contract["saturation_runs"]
        println(
            "Gate 4A: unpaced saturation run $run_index/" *
            string(contract["saturation_runs"]))
        flush(stdout)
        result = execute_cached_run(
            workload, saturation_config, histogram_config)
        push!(saturation_reports, saturation_run_report(
            result,
            run_index,
            histogram_config,
            contract))
    end

    gates = gate_report(
        fixed_reports,
        allocation_report,
        instrumentation_bytes,
        exact_replay,
        contract)
    if !gates["all_evaluated_gates_passed"]
        failed = report_failed_gates(gates)
        error(
            "predeclared Gate 4A evidence gates failed: " *
            join(failed, ", "))
    end

    artifact = Dict{String,Any}(
        "schema_version" => 1,
        "name" => contract["name"],
        "evidence_class" => contract["evidence_class"],
        "contract" => contract,
        "environment" => environment,
        "calibration" => calibration,
        "correctness" => exact_replay,
        "allocation" => merge(
            allocation_report,
            Dict(
                "instrumentation_bytes" =>
                    instrumentation_bytes)),
        "fixed_arrival_runs" => fixed_reports,
        "unpaced_saturation_runs" => saturation_reports,
        "gates" => gates,
        "summary" =>
            summary_report(fixed_reports, saturation_reports),
    )
    written = write_artifact(options.output_path, artifact)
    println(
        "Gate 4A artifact: $(options.output_path) " *
        "sha256=$(written.artifact_hash)")
    println("Gate 4A manifest: $(written.manifest_path)")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
