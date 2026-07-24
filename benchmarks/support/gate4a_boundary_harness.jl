module Gate4ABoundaryHarness

using AdaptiveOpticsHIL.Ownership
using AdaptiveOpticsHIL.Ports
using AdaptiveOpticsHIL.Serial
using AdaptiveOpticsHIL.Timing
using AdaptiveOpticsSim
using AdaptiveOpticsSim.Plant
using AdaptiveOpticsSim.Plant: AppliedCommand
using Clocks
using HdrHistogram

include("gate4a_serial_workload.jl")
using .Gate4ASerialWorkload:
    Gate4AWorkloadConfig,
    feedback_product_sequence,
    latest_optical_sample_timestamp,
    prepare_gate4a_fixture,
    primary_product_sequence

const Plant = AdaptiveOpticsSim.Plant

struct HistogramConfig
    lowest_ns::Int64
    highest_ns::Int64
    significant_figures::Int
end

function HistogramConfig(
    lowest_ns::Integer=1,
    highest_ns::Integer=60_000_000_000,
    significant_figures::Integer=3)
    lowest_ns >= 1 || error(
        "histogram lowest discernible value must be positive")
    highest_ns >= 2 * lowest_ns || error(
        "histogram highest trackable value is too small")
    1 <= significant_figures <= 5 || error(
        "histogram significant figures must lie in 1:5")
    return HistogramConfig(
        Int64(lowest_ns),
        Int64(highest_ns),
        Int(significant_figures))
end

struct BoundaryRunConfig
    samples::Int
    checkpoint_stride::Int
    stall_start_sequence::Int
    stall_frames::Int
end

function BoundaryRunConfig(;
    samples::Integer,
    checkpoint_stride::Integer=max(1, samples),
    stall_start_sequence::Integer=0,
    stall_frames::Integer=0)
    samples > 0 || error("run sample count must be positive")
    checkpoint_stride > 0 || error(
        "arrival checkpoint stride must be positive")
    stall_frames >= 0 || error(
        "stall frame count must be nonnegative")
    if stall_frames > 0
        1 <= stall_start_sequence <= samples || error(
            "stall start sequence must lie inside the finite arrival run")
        stall_start_sequence + stall_frames <= samples || error(
            "stall interval must end inside the finite arrival run")
    else
        stall_start_sequence == 0 || error(
            "zero-length stall requires a zero start sequence")
    end
    return BoundaryRunConfig(
        Int(samples),
        Int(checkpoint_stride),
        Int(stall_start_sequence),
        Int(stall_frames))
end

struct BoundaryHistograms
    publication_lateness::HdrHistogram.Histogram
    adapter_observation_delay::HdrHistogram.Histogram
    rtc_processing::HdrHistogram.Histogram
    command_admission_delay::HdrHistogram.Histogram
    command_application_delay::HdrHistogram.Histogram
    closed_loop_response::HdrHistogram.Histogram
    controller_service::HdrHistogram.Histogram
end

function BoundaryHistograms(config::HistogramConfig)
    histogram() = HdrHistogram.Histogram(
        config.lowest_ns,
        config.highest_ns,
        config.significant_figures)
    return BoundaryHistograms(
        histogram(),
        histogram(),
        histogram(),
        histogram(),
        histogram(),
        histogram(),
        histogram())
end

mutable struct BoundaryCounters
    offered_primary::UInt64
    published_primary::UInt64
    published_primary_cooldown::UInt64
    observed_primary::UInt64
    dropped_primary::UInt64
    primary_sequence_gaps::UInt64
    published_feedback::UInt64
    observed_feedback::UInt64
    feedback_sequence_gaps::UInt64
    commands_offered::UInt64
    commands_enqueued::UInt64
    commands_admitted::UInt64
    commands_applied::UInt64
    commands_rejected::UInt64
    outcomes_consumed::UInt64
    command_responses::UInt64
    command_sequence_gaps::UInt64
    outcome_sequence_gaps::UInt64
    adapter_lead_misses::UInt64
    maximum_primary_occupancy::Int
    maximum_feedback_occupancy::Int
    maximum_command_submission_occupancy::Int
    maximum_command_completion_occupancy::Int
    maximum_feedback_observation_delay_ns::Int64
    maximum_product_lease_hold_ns::Int64
    stall_start_offered::UInt64
    stall_end_offered::UInt64
    stall_start_published::UInt64
    stall_end_published::UInt64
    stall_start_observed::UInt64
    stall_end_observed::UInt64
    initial_residual_metric::Float64
    final_residual_metric::Float64
end

function BoundaryCounters()
    return BoundaryCounters(
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        0,
        0,
        0,
        0,
        Int64(0),
        Int64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        NaN,
        NaN)
end

@enum CheckpointKind::UInt8 begin
    PeriodicArrivalCheckpoint = 0x01
    RTCStallStartCheckpoint = 0x02
    RTCStallEndCheckpoint = 0x03
end

struct ArrivalCheckpoint
    kind::CheckpointKind
    scheduled_sequence::UInt64
    scheduled_deadline_ns::Int64
    observed_elapsed_ns::Int64
    offered::UInt64
    published::UInt64
    observed::UInt64
    primary_occupancy::Int
    feedback_occupancy::Int
end

@enum ControllerPhase::UInt8 begin
    ControllerIdle = 0x01
    ControllerCommandPrepared = 0x02
    ControllerCommandSubmitted = 0x03
    ControllerAwaitingResponse = 0x04
end

mutable struct BoundaryDriver{
    F,
    H<:BoundaryHistograms,
    C<:BoundaryCounters,
}
    fixture::F
    histograms::H
    counters::C
    run_config::BoundaryRunConfig
    histogram_config::HistogramConfig
    command::Vector{Float64}
    command_lease::Base.RefValue{PayloadLeaseRef}
    primary_completion::Base.RefValue{AcquisitionCompletion}
    feedback_completion::Base.RefValue{AcquisitionCompletion}
    command_outcome::Base.RefValue{
        CommandOutcome{LeasedCommandPayload}}
    checkpoints::Vector{ArrivalCheckpoint}
    checkpoint_count::Int
    next_periodic_checkpoint::Int
    phase::ControllerPhase
    prepared_sequence::UInt64
    prepared_completion_timestamp_ns::Int64
    prepared_observation_execution_ns::Int64
    command_ingress_execution_ns::Int64
    command_receive_timestamp_ns::Int64
    command_application_timestamp_ns::Int64
    controller_service_start_ns::UInt64
    last_optical_sample_timestamp_ns::Int64
    has_optical_sample::Bool
    last_published_primary::UInt64
    last_published_feedback::UInt64
    last_observed_primary::UInt64
    last_observed_feedback::UInt64
    last_command_sequence::UInt64
    last_outcome_sequence::UInt64
    stall_started::Bool
    stall_ended::Bool
end

function prepare_boundary_driver(
    clock::Clocks.AbstractNanoClock,
    workload::Gate4AWorkloadConfig,
    run_config::BoundaryRunConfig,
    histogram_config::HistogramConfig=HistogramConfig())
    histograms = BoundaryHistograms(histogram_config)
    counters = BoundaryCounters()
    checkpoint_capacity =
        cld(run_config.samples, run_config.checkpoint_stride) + 4
    checkpoints = Vector{ArrivalCheckpoint}(undef, checkpoint_capacity)
    command = zeros(Float64, 2)
    command_lease = Ref(PayloadLeaseRef(0, 0, 0, 0))
    primary_completion = Ref{AcquisitionCompletion}()
    feedback_completion = Ref{AcquisitionCompletion}()
    command_outcome =
        Ref{CommandOutcome{LeasedCommandPayload}}()
    fixture = prepare_gate4a_fixture(clock, workload)
    return BoundaryDriver(
        fixture,
        histograms,
        counters,
        run_config,
        histogram_config,
        command,
        command_lease,
        primary_completion,
        feedback_completion,
        command_outcome,
        checkpoints,
        0,
        run_config.checkpoint_stride,
        ControllerIdle,
        UInt64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        UInt64(0),
        Int64(0),
        false,
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        false,
        run_config.stall_frames == 0)
end

@inline function _elapsed_ns(start_ns::Int64, end_ns::Int64)
    elapsed_bits =
        reinterpret(UInt64, end_ns) - reinterpret(UInt64, start_ns)
    elapsed = reinterpret(Int64, elapsed_bits)
    elapsed >= 0 || error(
        "execution clock regressed or elapsed interval exceeded 2^63 ns")
    return elapsed
end

@inline function _signed_execution_delta_ns(
    start_ns::Int64,
    end_ns::Int64)
    delta_bits =
        reinterpret(UInt64, end_ns) - reinterpret(UInt64, start_ns)
    return reinterpret(Int64, delta_bits)
end

@inline function _execution_elapsed_ns(driver::BoundaryDriver)
    mapping = driver.fixture.armed.timing
    return _elapsed_ns(
        execution_clock_origin_ns(mapping),
        Clocks.time_nanos(execution_clock(mapping)))
end

@inline function _target_execution_ns(
    driver::BoundaryDriver,
    timestamp::PlantTimestamp)
    mapping = driver.fixture.armed.timing
    target_elapsed =
        plant_nanoseconds(timestamp) -
        plant_nanoseconds(plant_time_origin(mapping))
    target_elapsed >= 0 || error(
        "plant target precedes the execution mapping origin")
    target_bits =
        reinterpret(UInt64, execution_clock_origin_ns(mapping)) +
        UInt64(target_elapsed)
    return reinterpret(Int64, target_bits)
end

@inline function _plant_timestamp_at_execution(
    driver::BoundaryDriver,
    execution_ns::Int64)
    mapping = driver.fixture.armed.timing
    elapsed = _elapsed_ns(
        execution_clock_origin_ns(mapping), execution_ns)
    plant_ns =
        plant_nanoseconds(plant_time_origin(mapping)) + elapsed
    return PlantTimestamp(plant_ns)
end

@inline function _record_nonnegative!(
    histogram::HdrHistogram.Histogram,
    value::Int64,
    label::AbstractString)
    value >= 0 || error("$label was negative")
    HdrHistogram.record_value!(histogram, value)
    return value
end

@inline function record_instrumentation_sample!(
    histograms::BoundaryHistograms,
    publication_lateness::Int64,
    observation_delay::Int64,
    rtc_processing::Int64,
    admission_delay::Int64,
    application_delay::Int64,
    closed_loop_response::Int64)
    HdrHistogram.record_value!(
        histograms.publication_lateness, publication_lateness)
    HdrHistogram.record_value!(
        histograms.adapter_observation_delay, observation_delay)
    HdrHistogram.record_value!(
        histograms.rtc_processing, rtc_processing)
    HdrHistogram.record_value!(
        histograms.command_admission_delay, admission_delay)
    HdrHistogram.record_value!(
        histograms.command_application_delay, application_delay)
    HdrHistogram.record_value!(
        histograms.closed_loop_response, closed_loop_response)
    return nothing
end

@inline function _offered_primary(
    driver::BoundaryDriver,
    execution_elapsed_ns::Int64)
    config = driver.fixture.config
    execution_elapsed_ns < config.primary_exposure_ns &&
        return UInt64(0)
    offered = fld(
        execution_elapsed_ns - config.primary_exposure_ns,
        config.primary_period_ns) + 1
    return UInt64(min(offered, driver.run_config.samples))
end

@inline function _primary_deadline_ns(
    driver::BoundaryDriver,
    sequence::Integer)
    return driver.fixture.config.primary_exposure_ns +
        (Int64(sequence) - 1) *
        driver.fixture.config.primary_period_ns
end

function _update_maximum_occupancy!(driver::BoundaryDriver)
    counters = driver.counters
    fixture = driver.fixture
    counters.maximum_primary_occupancy = max(
        counters.maximum_primary_occupancy,
        descriptor_accounting(fixture.wfs_port).occupancy)
    counters.maximum_feedback_occupancy = max(
        counters.maximum_feedback_occupancy,
        descriptor_accounting(fixture.feedback_port).occupancy)
    counters.maximum_command_submission_occupancy = max(
        counters.maximum_command_submission_occupancy,
        descriptor_accounting(
            command_submission_port(fixture.command_ports)).occupancy)
    counters.maximum_command_completion_occupancy = max(
        counters.maximum_command_completion_occupancy,
        descriptor_accounting(
            command_completion_port(fixture.command_ports)).occupancy)
    return nothing
end

function _record_checkpoint!(
    driver::BoundaryDriver,
    kind::CheckpointKind,
    sequence::UInt64,
    observed_elapsed_ns::Int64)
    driver.checkpoint_count < length(driver.checkpoints) || error(
        "arrival checkpoint capacity was exhausted")
    driver.checkpoint_count += 1
    driver.checkpoints[driver.checkpoint_count] = ArrivalCheckpoint(
        kind,
        sequence,
        _primary_deadline_ns(driver, sequence),
        observed_elapsed_ns,
        driver.counters.offered_primary,
        driver.counters.published_primary,
        driver.counters.observed_primary,
        descriptor_accounting(driver.fixture.wfs_port).occupancy,
        descriptor_accounting(driver.fixture.feedback_port).occupancy)
    return nothing
end

function _update_offered_arrivals!(
    driver::BoundaryDriver,
    execution_elapsed_ns::Int64)
    offered = _offered_primary(driver, execution_elapsed_ns)
    offered >= driver.counters.offered_primary || error(
        "absolute offered-arrival count regressed")
    driver.counters.offered_primary = offered
    while driver.next_periodic_checkpoint <= Int(offered)
        sequence = UInt64(driver.next_periodic_checkpoint)
        _record_checkpoint!(
            driver,
            PeriodicArrivalCheckpoint,
            sequence,
            execution_elapsed_ns)
        driver.next_periodic_checkpoint +=
            driver.run_config.checkpoint_stride
    end
    return nothing
end

function _update_stall_state!(
    driver::BoundaryDriver,
    execution_elapsed_ns::Int64)
    config = driver.run_config
    config.stall_frames == 0 && return nothing
    published = driver.counters.published_primary
    if !driver.stall_started &&
            published >= UInt64(config.stall_start_sequence)
        driver.phase == ControllerIdle || error(
            "RTC stall began with a command already in flight")
        driver.stall_started = true
        driver.counters.stall_start_offered =
            driver.counters.offered_primary
        driver.counters.stall_start_published = published
        driver.counters.stall_start_observed =
            driver.counters.observed_primary
        _record_checkpoint!(
            driver,
            RTCStallStartCheckpoint,
            UInt64(config.stall_start_sequence),
            execution_elapsed_ns)
    end
    if driver.stall_started && !driver.stall_ended &&
            published >= UInt64(
                config.stall_start_sequence + config.stall_frames)
        driver.stall_ended = true
        driver.counters.stall_end_offered =
            driver.counters.offered_primary
        driver.counters.stall_end_published = published
        driver.counters.stall_end_observed =
            driver.counters.observed_primary
        _record_checkpoint!(
            driver,
            RTCStallEndCheckpoint,
            UInt64(
                config.stall_start_sequence + config.stall_frames),
            execution_elapsed_ns)
    end
    return nothing
end

@inline _rtc_is_stalled(driver::BoundaryDriver) =
    driver.stall_started && !driver.stall_ended

function _update_published_sequences!(driver::BoundaryDriver)
    primary = primary_product_sequence(driver.fixture)
    primary >= driver.last_published_primary || error(
        "primary product sequence regressed")
    if primary > driver.last_published_primary
        driver.counters.primary_sequence_gaps +=
            primary - driver.last_published_primary - UInt64(1)
        driver.last_published_primary = primary
        target = UInt64(driver.run_config.samples)
        driver.counters.published_primary = min(primary, target)
        driver.counters.published_primary_cooldown =
            primary > target ? primary - target : UInt64(0)
    end

    feedback = feedback_product_sequence(driver.fixture)
    feedback >= driver.last_published_feedback || error(
        "feedback product sequence regressed")
    if feedback > driver.last_published_feedback
        driver.counters.feedback_sequence_gaps +=
            feedback - driver.last_published_feedback - UInt64(1)
        driver.last_published_feedback = feedback
        driver.counters.published_feedback = feedback
    end
    return nothing
end

@inline function _residual_metric(measurement)
    total = 0.0
    @inbounds for value in measurement
        total += abs2(value)
    end
    return total
end

function _observe_primary_product!(driver::BoundaryDriver)
    driver.phase == ControllerIdle || return false
    port = driver.fixture.wfs_port
    result = try_take!(driver.primary_completion, port)
    port_status(result) == PortEmpty && return false
    port_status(result) == PortTransferSucceeded || error(
        "primary completion port returned an invalid status")
    completion = driver.primary_completion[]
    sequence = stream_sequence_value(
        acquisition_completion_sequence(completion))
    sequence > driver.last_observed_primary || error(
        "primary completion sequence did not increase")
    driver.counters.primary_sequence_gaps +=
        sequence - driver.last_observed_primary - UInt64(1)
    driver.last_observed_primary = sequence

    observation_execution_ns =
        Clocks.time_nanos(driver.fixture.clock)
    publication_execution_ns =
        acquisition_completion_publication_ns(completion)
    completion_timestamp =
        acquisition_completion_timestamp(completion)
    completion_execution_ns =
        _target_execution_ns(driver, completion_timestamp)
    publication_lateness = _elapsed_ns(
        completion_execution_ns, publication_execution_ns)
    observation_delay = _elapsed_ns(
        publication_execution_ns, observation_execution_ns)
    lease_start_ns = observation_execution_ns

    target_sequence = sequence <= UInt64(driver.run_config.samples)
    if target_sequence
        driver.controller_service_start_ns = time_ns()
        _record_nonnegative!(
            driver.histograms.publication_lateness,
            publication_lateness,
            "primary publication lateness")
        _record_nonnegative!(
            driver.histograms.adapter_observation_delay,
            observation_delay,
            "adapter observation delay")
        observation_delay >
            driver.fixture.config.complete_product_lead_time_ns &&
            (driver.counters.adapter_lead_misses += UInt64(1))
        product = completed_product(port, completion)
        measurement = measurement_storage(product.measurement)
        @inbounds for index in eachindex(driver.command, measurement)
            driver.command[index] -=
                driver.fixture.config.controller_gain *
                Float64(measurement[index])
        end
        metric = _residual_metric(measurement)
        isnan(driver.counters.initial_residual_metric) &&
            (driver.counters.initial_residual_metric = metric)
        driver.counters.final_residual_metric = metric
        driver.prepared_sequence = sequence
        driver.prepared_completion_timestamp_ns =
            plant_nanoseconds(completion_timestamp)
        driver.prepared_observation_execution_ns =
            observation_execution_ns
        driver.phase = ControllerCommandPrepared
        driver.counters.observed_primary += UInt64(1)
        driver.counters.commands_offered += UInt64(1)
    else
        driver.counters.published_primary_cooldown =
            max(driver.counters.published_primary_cooldown,
                sequence - UInt64(driver.run_config.samples))
    end

    release_result = release_product!(port, completion)
    port_status(release_result) == PortTransferSucceeded || error(
        "primary product lease could not be released")
    release_execution_ns =
        Clocks.time_nanos(driver.fixture.clock)
    lease_hold = _elapsed_ns(lease_start_ns, release_execution_ns)
    driver.counters.maximum_product_lease_hold_ns = max(
        driver.counters.maximum_product_lease_hold_ns,
        lease_hold)
    return true
end

function _observe_feedback_products!(driver::BoundaryDriver)
    port = driver.fixture.feedback_port
    while true
        result = try_take!(driver.feedback_completion, port)
        port_status(result) == PortEmpty && return nothing
        port_status(result) == PortTransferSucceeded || error(
            "feedback completion port returned an invalid status")
        completion = driver.feedback_completion[]
        sequence = stream_sequence_value(
            acquisition_completion_sequence(completion))
        sequence > driver.last_observed_feedback || error(
            "feedback completion sequence did not increase")
        driver.counters.feedback_sequence_gaps +=
            sequence - driver.last_observed_feedback - UInt64(1)
        driver.last_observed_feedback = sequence
        observation_execution_ns =
            Clocks.time_nanos(driver.fixture.clock)
        delay = _elapsed_ns(
            acquisition_completion_publication_ns(completion),
            observation_execution_ns)
        driver.counters.maximum_feedback_observation_delay_ns = max(
            driver.counters.maximum_feedback_observation_delay_ns,
            delay)
        release_result = release_product!(port, completion)
        port_status(release_result) == PortTransferSucceeded || error(
            "feedback product lease could not be released")
        driver.counters.observed_feedback += UInt64(1)
    end
end

@inline _advance_deterministic_controller_clock!(
    ::Clocks.SystemNanoClock) = nothing

@inline function _advance_deterministic_controller_clock!(
    clock::Clocks.CachedNanoClock)
    Clocks.advance!(clock, 1)
    return nothing
end

function _submit_prepared_command!(
    driver::BoundaryDriver,
    next_event_timestamp::PlantTimestamp)
    driver.phase == ControllerCommandPrepared || return false
    # A receive-time command must be strictly newer than the most recently
    # processed plant event. A real monotonic clock advances while the fake RTC
    # computes; deterministic replay represents that interval by one nanosecond.
    _advance_deterministic_controller_clock!(driver.fixture.clock)
    now = Clocks.time_nanos(driver.fixture.clock)
    next_execution_ns =
        _target_execution_ns(driver, next_event_timestamp)
    _signed_execution_delta_ns(now, next_execution_ns) > 0 ||
        return false
    receive = _plant_timestamp_at_execution(driver, now)
    submission_port =
        command_submission_port(driver.fixture.command_ports)
    claim_status =
        try_claim_command_payload!(driver.command_lease, submission_port)
    claim_status == PayloadTransitionSucceeded || error(
        "no prepared command payload was available")
    copyto!(
        producer_command_payload(
            submission_port, driver.command_lease[]),
        driver.command)
    sequence = driver.prepared_sequence
    submission = matching_command_submission(
        submission_port,
        StreamSequence(sequence),
        PlantCommandSequence(sequence),
        receive_time_command_timing(
            receive; requested_effective_timestamp=receive),
        LeasedCommandPayload(driver.command_lease[]))
    result = try_submit!(submission_port, submission, now)
    if port_status(result) != PortTransferSucceeded
        abort_command_payload!(
            submission_port, driver.command_lease[])
        driver.counters.commands_rejected += UInt64(1)
        error("prepared command submission was not transferred")
    end
    sequence > driver.last_command_sequence || error(
        "command submission sequence did not increase")
    driver.counters.command_sequence_gaps +=
        sequence - driver.last_command_sequence - UInt64(1)
    driver.last_command_sequence = sequence
    driver.command_ingress_execution_ns = now
    driver.command_receive_timestamp_ns = plant_nanoseconds(receive)
    rtc_processing = _elapsed_ns(
        driver.prepared_observation_execution_ns, now)
    _record_nonnegative!(
        driver.histograms.rtc_processing,
        rtc_processing,
        "RTC processing time")
    driver.phase = ControllerCommandSubmitted
    driver.counters.commands_enqueued += UInt64(1)
    return true
end

function _record_command_admission!(
    driver::BoundaryDriver,
    result::SerialStepResult)
    driver.phase == ControllerCommandSubmitted || error(
        "serial runtime processed a command without prepared correlation")
    plant_nanoseconds(serial_step_timestamp(result)) ==
        driver.command_receive_timestamp_ns || error(
        "serial command admission timestamp changed at the HIL boundary")
    now = Clocks.time_nanos(driver.fixture.clock)
    admission_delay = _elapsed_ns(
        driver.command_ingress_execution_ns, now)
    _record_nonnegative!(
        driver.histograms.command_admission_delay,
        admission_delay,
        "command admission delay")
    driver.counters.commands_admitted += UInt64(1)
    return nothing
end

function _observe_command_outcomes!(driver::BoundaryDriver)
    port = command_completion_port(driver.fixture.command_ports)
    while true
        result = try_take!(driver.command_outcome, port)
        port_status(result) == PortEmpty && return nothing
        port_status(result) == PortTransferSucceeded || error(
            "command completion port returned an invalid status")
        outcome = driver.command_outcome[]
        outcome_stage(outcome) == CoreCommandOutcome || error(
            "benchmark command ended at the HIL boundary")
        outcome_terminal_kind(outcome) == AppliedCommand || error(
            "benchmark command did not reach physical application")
        sequence = stream_sequence_value(
            outcome_stream_sequence(outcome))
        sequence > driver.last_outcome_sequence || error(
            "command outcome sequence did not increase")
        driver.counters.outcome_sequence_gaps +=
            sequence - driver.last_outcome_sequence - UInt64(1)
        driver.last_outcome_sequence = sequence
        sequence == driver.prepared_sequence || error(
            "terminal outcome did not match the active fake-RTC command")
        publication_ns =
            outcome_publication_execution_ns(outcome)
        application_delay = _elapsed_ns(
            driver.command_ingress_execution_ns, publication_ns)
        _record_nonnegative!(
            driver.histograms.command_application_delay,
            application_delay,
            "command application delay")
        driver.command_application_timestamp_ns =
            plant_nanoseconds(outcome_terminal_timestamp(outcome))
        driver.counters.commands_applied += UInt64(1)
        driver.counters.outcomes_consumed += UInt64(1)
        release_result = release_outcome!(port, outcome)
        port_status(release_result) == PortTransferSucceeded || error(
            "command outcome credit could not be released")
        driver.phase = ControllerAwaitingResponse
    end
end

function _observe_optical_sample!(driver::BoundaryDriver)
    timestamp = latest_optical_sample_timestamp(driver.fixture)
    timestamp === nothing && return nothing
    sample_ns = plant_nanoseconds(timestamp)
    if driver.has_optical_sample &&
            sample_ns == driver.last_optical_sample_timestamp_ns
        return nothing
    end
    driver.last_optical_sample_timestamp_ns = sample_ns
    driver.has_optical_sample = true
    driver.phase == ControllerAwaitingResponse || return nothing
    sample_ns >= driver.command_application_timestamp_ns || return nothing
    now = Clocks.time_nanos(driver.fixture.clock)
    product_completion_execution_ns = _target_execution_ns(
        driver,
        PlantTimestamp(driver.prepared_completion_timestamp_ns))
    response = _elapsed_ns(
        product_completion_execution_ns, now)
    _record_nonnegative!(
        driver.histograms.closed_loop_response,
        response,
        "closed-loop response")
    service =
        Int64(time_ns() - driver.controller_service_start_ns)
    _record_nonnegative!(
        driver.histograms.controller_service,
        service,
        "controller service time")
    driver.counters.command_responses += UInt64(1)
    driver.phase = ControllerIdle
    return nothing
end

function _wait_for_deadline!(
    driver::BoundaryDriver,
    result::SerialStepResult)
    serial_step_status(result) == SerialDeadlinePending ||
        return nothing
    clock = driver.fixture.clock
    _wait_for_deadline!(
        clock, serial_step_time_until_ns(result))
    return nothing
end

@inline _wait_for_deadline!(
    ::Clocks.SystemNanoClock,
    ::Int64) = nothing

@inline function _wait_for_deadline!(
    clock::Clocks.CachedNanoClock,
    time_until_ns::Int64)
    time_until_ns > 0 &&
        Clocks.advance!(clock, time_until_ns)
    return nothing
end

function _run_is_complete(driver::BoundaryDriver)
    target = UInt64(driver.run_config.samples)
    counters = driver.counters
    return counters.offered_primary == target &&
        counters.published_primary == target &&
        counters.observed_primary == target &&
        counters.commands_enqueued == target &&
        counters.commands_admitted == target &&
        counters.commands_applied == target &&
        counters.outcomes_consumed == target &&
        counters.command_responses == target &&
        counters.published_feedback ==
            counters.observed_feedback &&
        driver.phase == ControllerIdle &&
        descriptor_accounting(driver.fixture.wfs_port).occupancy == 0 &&
        descriptor_accounting(
            driver.fixture.feedback_port).occupancy == 0 &&
        descriptor_accounting(
            command_submission_port(
                driver.fixture.command_ports)).occupancy == 0 &&
        descriptor_accounting(
            command_completion_port(
                driver.fixture.command_ports)).occupancy == 0 &&
        active_command_correlations(driver.fixture.state.bridge) == 0
end

struct BoundaryRunResult{
    H<:BoundaryHistograms,
    C<:BoundaryCounters,
    A<:SerialRunAccounting,
}
    histograms::H
    counters::C
    accounting::A
    checkpoints::Vector{ArrivalCheckpoint}
    checkpoint_count::Int
    wall_start_ns::UInt64
    wall_end_ns::UInt64
end

function execute_boundary_run!(driver::BoundaryDriver)
    wall_start = time_ns()
    while true
        result = step_serial_run!(
            driver.fixture.armed,
            driver.fixture.state,
            driver.fixture.workspace)
        elapsed = _execution_elapsed_ns(driver)
        _update_offered_arrivals!(driver, elapsed)

        status = serial_step_status(result)
        if status == SerialCommandProcessed
            _record_command_admission!(driver, result)
        elseif status == SerialPlantEventProcessed
            _update_published_sequences!(driver)
            _update_maximum_occupancy!(driver)
        elseif status == SerialEventLoopComplete
            error("periodic Gate 4A event loop ended unexpectedly")
        end

        _update_stall_state!(driver, elapsed)
        if !_rtc_is_stalled(driver)
            _observe_command_outcomes!(driver)
            status == SerialPlantEventProcessed &&
                _observe_optical_sample!(driver)
            _observe_feedback_products!(driver)
            if status == SerialDeadlinePending
                if driver.phase == ControllerIdle
                    _observe_primary_product!(driver)
                end
                driver.phase == ControllerCommandPrepared &&
                    _submit_prepared_command!(
                        driver, serial_step_timestamp(result))
            end
        end
        _update_maximum_occupancy!(driver)
        _run_is_complete(driver) && break
        _wait_for_deadline!(driver, result)
    end
    _observe_feedback_products!(driver)
    wall_end = time_ns()
    accounting = stop_serial_run!(
        driver.fixture.armed,
        driver.fixture.state,
        driver.fixture.workspace)
    return BoundaryRunResult(
        driver.histograms,
        driver.counters,
        accounting,
        driver.checkpoints,
        driver.checkpoint_count,
        wall_start,
        wall_end)
end

function validate_boundary_result(
    result::BoundaryRunResult,
    run_config::BoundaryRunConfig)
    counters = result.counters
    target = UInt64(run_config.samples)
    counters.offered_primary == target || error(
        "fixed arrival generator did not offer every deadline")
    counters.published_primary == target || error(
        "serial runtime did not publish every primary product")
    counters.observed_primary == target || error(
        "fake RTC did not observe every primary product")
    counters.dropped_primary == 0 || error(
        "primary products were dropped")
    counters.primary_sequence_gaps == 0 || error(
        "primary product sequence contains a gap")
    counters.feedback_sequence_gaps == 0 || error(
        "feedback product sequence contains a gap")
    counters.published_feedback == counters.observed_feedback || error(
        "sampled feedback was not fully consumed")
    counters.commands_offered == target ||
        error("fake RTC did not derive one command per primary product")
    counters.commands_enqueued == target ||
        error("not every derived command transferred ownership")
    counters.commands_admitted == target ||
        error("not every transferred command reached semantic admission")
    counters.commands_applied == target ||
        error("not every admitted command was physically applied")
    counters.commands_rejected == 0 ||
        error("benchmark commands were rejected")
    counters.outcomes_consumed == target ||
        error("not every transferred command returned an outcome")
    counters.command_responses == target ||
        error("not every command reached a responsive optical sample")
    counters.command_sequence_gaps == 0 ||
        error("command sequence contains a gap")
    counters.outcome_sequence_gaps == 0 ||
        error("command outcome sequence contains a gap")
    serial_run_is_quiescent(result.accounting) || error(
        "serial run stopped with outstanding ownership")
    for histogram in (
        result.histograms.publication_lateness,
        result.histograms.adapter_observation_delay,
        result.histograms.rtc_processing,
        result.histograms.command_admission_delay,
        result.histograms.command_application_delay,
        result.histograms.closed_loop_response,
        result.histograms.controller_service,
    )
        HdrHistogram.total_count(histogram) == run_config.samples ||
            error("boundary histogram sample count is incomplete")
    end
    if run_config.stall_frames > 0
        counters.stall_end_offered - counters.stall_start_offered ==
            UInt64(run_config.stall_frames) || error(
            "offered deadlines did not continue through the RTC stall")
        counters.stall_end_observed ==
            counters.stall_start_observed || error(
            "fake RTC consumed a primary product during its stall")
        counters.maximum_primary_occupancy >=
            run_config.stall_frames || error(
            "primary completion occupancy did not retain the stall backlog")
    end
    return true
end

function _exercise_instrumentation!(
    driver::BoundaryDriver,
    samples::Int)
    config = driver.fixture.config
    @inbounds for index in 1:samples
        elapsed = config.primary_exposure_ns +
            (index - 1) * config.primary_period_ns
        _update_offered_arrivals!(driver, elapsed)
        _update_maximum_occupancy!(driver)
        record_instrumentation_sample!(
            driver.histograms, 1, 2, 3, 4, 5, 6)
    end
    return nothing
end

function _stop_instrumentation_driver!(driver::BoundaryDriver)
    stop_serial_run!(
        driver.fixture.armed,
        driver.fixture.state,
        driver.fixture.workspace)
    return nothing
end

function measure_instrumentation_allocations(
    workload::Gate4AWorkloadConfig,
    histogram_config::HistogramConfig,
    samples::Int)
    samples > 0 || error(
        "instrumentation allocation sample count must be positive")
    run_config = BoundaryRunConfig(
        samples=samples,
        checkpoint_stride=max(1, samples ÷ 100))
    warm_driver = prepare_boundary_driver(
        Clocks.CachedNanoClock(0),
        workload,
        run_config,
        histogram_config)
    _exercise_instrumentation!(warm_driver, samples)
    _stop_instrumentation_driver!(warm_driver)
    measured_driver = prepare_boundary_driver(
        Clocks.CachedNanoClock(0),
        workload,
        run_config,
        histogram_config)
    bytes = @allocated _exercise_instrumentation!(
        measured_driver, samples)
    _stop_instrumentation_driver!(measured_driver)
    return bytes
end

end
