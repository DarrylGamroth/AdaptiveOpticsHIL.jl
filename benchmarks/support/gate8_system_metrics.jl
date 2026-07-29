struct ProcessCounters
    voluntary_context_switches::Union{Missing,Int64}
    involuntary_context_switches::Union{Missing,Int64}
    migrations::Union{Missing,Int64}
    minor_page_faults::Union{Missing,Int64}
    major_page_faults::Union{Missing,Int64}
    user_cpu_ns::Union{Missing,Int64}
    system_cpu_ns::Union{Missing,Int64}
end

mutable struct ProductTraceObserver <:
    Boundary.AbstractBoundaryObserver
    primary::Vector{NTuple{10,UInt64}}
    feedback::Vector{NTuple{6,UInt64}}
    science::Vector{NTuple{6,UInt64}}
    events::Vector{NTuple{5,UInt64}}
    primary_count::Int
    feedback_count::Int
    science_count::Int
    event_count::Int
end

ProductTraceObserver(samples::Integer) = samples > 0 ?
    ProductTraceObserver(
        Vector{NTuple{10,UInt64}}(undef, Int(samples)),
        Vector{NTuple{6,UInt64}}(undef, Int(samples)),
        Vector{NTuple{6,UInt64}}(undef, Int(samples)),
        Vector{NTuple{5,UInt64}}(
            undef, 48 * Int(samples) + 64),
        0,
        0,
        0,
        0) :
    error("product trace sample count must be positive")

@inline _trace_bits(value::Int64) =
    reinterpret(UInt64, value)

function Boundary.observe_boundary_step!(
    observer::ProductTraceObserver,
    ::Any,
    result,
    execution_elapsed_ns::Int64)
    observer.event_count < length(observer.events) || error(
        "Gate 8 event-trace capacity was exhausted")
    observer.event_count += 1
    timestamp = serial_step_timestamp(result)
    timestamp_present = timestamp === nothing ?
        UInt64(0) : UInt64(1)
    timestamp_bits = timestamp === nothing ?
        UInt64(0) :
        _trace_bits(Plant.plant_nanoseconds(timestamp))
    observer.events[observer.event_count] = (
        UInt64(UInt8(serial_step_status(result))),
        timestamp_present,
        timestamp_bits,
        _trace_bits(serial_step_time_until_ns(result)),
        _trace_bits(execution_elapsed_ns))
    return nothing
end

function Boundary.observe_primary_product!(
    observer::ProductTraceObserver,
    sequence::UInt64,
    completion_timestamp_ns::Int64,
    publication_execution_ns::Int64,
    observation_execution_ns::Int64,
    measurement)
    index = Int(sequence)
    checkbounds(observer.primary, index)
    length(measurement) == 2 || error(
        "Gate 8 product trace requires the declared two-mode product")
    observer.primary[index] = (
        sequence,
        _trace_bits(completion_timestamp_ns),
        _trace_bits(publication_execution_ns),
        _trace_bits(observation_execution_ns),
        reinterpret(UInt64, Float64(measurement[1])),
        reinterpret(UInt64, Float64(measurement[2])),
        UInt64(0),
        UInt64(0),
        UInt64(0),
        UInt64(0))
    observer.primary_count = max(
        observer.primary_count, index)
    return nothing
end

function Boundary.observe_feedback_product!(
    observer::ProductTraceObserver,
    sequence::UInt64,
    completion_timestamp_ns::Int64,
    publication_execution_ns::Int64,
    observation_execution_ns::Int64,
    measurement)
    index = Int(sequence)
    checkbounds(observer.feedback, index)
    length(measurement) == 2 || error(
        "Gate 8 feedback trace requires the declared two-mode product")
    observer.feedback[index] = (
        sequence,
        _trace_bits(completion_timestamp_ns),
        _trace_bits(publication_execution_ns),
        _trace_bits(observation_execution_ns),
        reinterpret(UInt64, Float64(measurement[1])),
        reinterpret(UInt64, Float64(measurement[2])))
    observer.feedback_count = max(
        observer.feedback_count, index)
    return nothing
end

function Boundary.observe_science_product!(
    observer::ProductTraceObserver,
    sequence::UInt64,
    completion_timestamp_ns::Int64,
    publication_execution_ns::Int64,
    observation_execution_ns::Int64,
    measurement)
    index = Int(sequence)
    checkbounds(observer.science, index)
    length(measurement) == 2 || error(
        "Gate 8 science trace requires the declared two-mode product")
    observer.science[index] = (
        sequence,
        _trace_bits(completion_timestamp_ns),
        _trace_bits(publication_execution_ns),
        _trace_bits(observation_execution_ns),
        reinterpret(UInt64, Float64(measurement[1])),
        reinterpret(UInt64, Float64(measurement[2])))
    observer.science_count = max(
        observer.science_count, index)
    return nothing
end

function Boundary.observe_command_outcome!(
    observer::ProductTraceObserver,
    sequence::UInt64,
    terminal_timestamp_ns::Int64,
    publication_execution_ns::Int64)
    index = Int(sequence)
    checkbounds(observer.primary, index)
    record = observer.primary[index]
    record[1] == sequence || error(
        "Gate 8 outcome preceded its primary product trace")
    observer.primary[index] = (
        record[1],
        record[2],
        record[3],
        record[4],
        record[5],
        record[6],
        _trace_bits(terminal_timestamp_ns),
        _trace_bits(publication_execution_ns),
        record[9],
        record[10])
    return nothing
end

function Boundary.observe_command_response!(
    observer::ProductTraceObserver,
    sequence::UInt64,
    sample_timestamp_ns::Int64,
    observation_execution_ns::Int64)
    index = Int(sequence)
    checkbounds(observer.primary, index)
    record = observer.primary[index]
    record[1] == sequence || error(
        "Gate 8 response preceded its primary product trace")
    observer.primary[index] = (
        record[1],
        record[2],
        record[3],
        record[4],
        record[5],
        record[6],
        record[7],
        record[8],
        _trace_bits(sample_timestamp_ns),
        _trace_bits(observation_execution_ns))
    return nothing
end

function reset_operational_observer!(
    observer::ProductTraceObserver)
    observer.primary_count = 0
    observer.feedback_count = 0
    observer.science_count = 0
    observer.event_count = 0
    return nothing
end

function finish_operational_observer!(
    observer::ProductTraceObserver,
    driver)
    observer.primary_count == driver.run_config.samples || error(
        "Gate 8 primary trace did not retain every product")
    observer.feedback_count > 0 || error(
        "Gate 8 feedback trace is empty")
    driver.fixture.science_port === nothing ||
        observer.science_count > 0 || error(
            "Gate 8 science trace is empty")
    observer.event_count > 0 || error(
        "Gate 8 event trace is empty")
    @inbounds for index in 1:observer.primary_count
        record = observer.primary[index]
        record[1] == UInt64(index) || error(
            "Gate 8 primary trace sequence is incomplete")
        !iszero(record[7]) && !iszero(record[8]) || error(
            "Gate 8 primary trace lacks a terminal command outcome")
        !iszero(record[9]) && !iszero(record[10]) || error(
            "Gate 8 primary trace lacks a responsive optical sample")
    end
    return nothing
end

product_trace(observer::ProductTraceObserver) =
    @view observer.primary[1:observer.primary_count]
feedback_trace(observer::ProductTraceObserver) =
    @view observer.feedback[1:observer.feedback_count]
science_trace(observer::ProductTraceObserver) =
    @view observer.science[1:observer.science_count]
event_trace(observer::ProductTraceObserver) =
    @view observer.events[1:observer.event_count]

struct OperationalInterval
    wall_elapsed_ns::Int64
    execution_elapsed_ns::Int64
    offered_primary::UInt64
    completed_primary::UInt64
    achieved_offered_rate_hz::Float64
    achieved_completed_rate_hz::Float64
    shed_science::UInt64
    rejected_commands::UInt64
    primary_occupancy::Int
    primary_headroom::Int
    feedback_occupancy::Int
    feedback_headroom::Int
    science_occupancy::Int
    science_headroom::Int
    command_submission_occupancy::Int
    command_submission_headroom::Int
    command_completion_occupancy::Int
    command_completion_headroom::Int
    publication_lateness_p99_ns::Int64
    command_application_delay_p99_ns::Int64
    closed_loop_response_p99_ns::Int64
    maximum_product_lease_hold_ns::Int64
    gc_allocated_bytes::Int64
    gc_time_ns::Int64
    gc_collections::Int64
    gc_full_sweeps::Int64
    process_user_cpu_ns::Union{Missing,Int64}
    process_system_cpu_ns::Union{Missing,Int64}
    process_cpu_utilization::Union{Missing,Float64}
    voluntary_context_switches::Union{Missing,Int64}
    involuntary_context_switches::Union{Missing,Int64}
    migrations::Union{Missing,Int64}
    minor_page_faults::Union{Missing,Int64}
    major_page_faults::Union{Missing,Int64}
    ingress_liveness_status::UInt8
    ingress_liveness_reset_count::UInt64
    ingress_liveness_expiry_count::UInt64
    execution_batches_completed::UInt64
    owner_one_task_id::UInt
    owner_two_task_id::UInt
    owner_one_thread_id::Int
    owner_two_thread_id::Int
    owner_one_work_completed::UInt64
    owner_two_work_completed::UInt64
    owner_one_due_occupancy::Int
    owner_one_due_headroom::Int
    owner_two_due_occupancy::Int
    owner_two_due_headroom::Int
    owner_one_completion_occupancy::Int
    owner_one_completion_headroom::Int
    owner_two_completion_occupancy::Int
    owner_two_completion_headroom::Int
end

mutable struct OperationalIntervalObserver <:
    Boundary.AbstractBoundaryObserver
    records::Vector{OperationalInterval}
    count::Int
    interval_ns::Int64
    next_interval_ns::Int64
    wall_start_ns::UInt64
    gc_start::Base.GC_Num
    process_start::ProcessCounters
    last_probed_completion::UInt64
    probe_stride::UInt64
end

function _parse_int_after_colon(path::AbstractString, key::AbstractString)
    isfile(path) || return missing
    for line in eachline(path)
        fields = split(line, ':'; limit=2)
        length(fields) == 2 || continue
        strip(fields[1]) == key || continue
        value = tryparse(Int64, strip(fields[2]))
        return value === nothing ? missing : value
    end
    return missing
end

function _linux_process_stat_counters()
    path = "/proc/self/stat"
    isfile(path) ||
        return (missing, missing, missing, missing)
    line = read(path, String)
    close_index = findlast(==(')'), line)
    close_index === nothing &&
        return (missing, missing, missing, missing)
    fields = split(SubString(line, close_index + 2))
    length(fields) >= 13 ||
        return (missing, missing, missing, missing)
    minor = tryparse(Int64, fields[8])
    major = tryparse(Int64, fields[10])
    user_ticks = tryparse(Int64, fields[12])
    system_ticks = tryparse(Int64, fields[13])
    ticks_to_ns(value) = value === nothing ?
        missing :
        Int64(
            div(
                Int128(value) * Int128(1_000_000_000),
                Int128(Sys.SC_CLK_TCK)))
    return (
        minor === nothing ? missing : minor,
        major === nothing ? missing : major,
        ticks_to_ns(user_ticks),
        ticks_to_ns(system_ticks))
end

function process_counters()
    voluntary = _parse_int_after_colon(
        "/proc/self/status", "voluntary_ctxt_switches")
    involuntary = _parse_int_after_colon(
        "/proc/self/status", "nonvoluntary_ctxt_switches")
    migrations = _parse_int_after_colon(
        "/proc/self/sched", "se.nr_migrations")
    minor, major, user_cpu_ns, system_cpu_ns =
        _linux_process_stat_counters()
    return ProcessCounters(
        voluntary,
        involuntary,
        migrations,
        minor,
        major,
        user_cpu_ns,
        system_cpu_ns)
end

@inline _counter_delta(
    current::Missing,
    ::Union{Missing,Int64}) = missing
@inline _counter_delta(
    ::Int64,
    baseline::Missing) = missing
@inline _counter_delta(current::Int64, baseline::Int64) =
    current - baseline

function OperationalIntervalObserver(
    capacity::Integer,
    interval_ns::Integer;
    probe_stride::Integer=100)
    capacity > 0 || error(
        "operational interval capacity must be positive")
    interval_ns > 0 || error(
        "operational interval must be positive")
    probe_stride > 0 || error(
        "operational interval probe stride must be positive")
    return OperationalIntervalObserver(
        Vector{OperationalInterval}(undef, Int(capacity)),
        0,
        Int64(interval_ns),
        Int64(interval_ns),
        time_ns(),
        Base.gc_num(),
        process_counters(),
        UInt64(0),
        UInt64(probe_stride))
end

function reset_operational_observer!(
    observer::OperationalIntervalObserver)
    observer.count = 0
    observer.next_interval_ns = observer.interval_ns
    observer.wall_start_ns = time_ns()
    observer.gc_start = Base.gc_num()
    observer.process_start = process_counters()
    observer.last_probed_completion = UInt64(0)
    return nothing
end

struct ExecutionIntervalObservation
    batches_completed::UInt64
    owner_one_task_id::UInt
    owner_two_task_id::UInt
    owner_one_thread_id::Int
    owner_two_thread_id::Int
    owner_one_work_completed::UInt64
    owner_two_work_completed::UInt64
    owner_one_due_occupancy::Int
    owner_one_due_headroom::Int
    owner_two_due_occupancy::Int
    owner_two_due_headroom::Int
    owner_one_completion_occupancy::Int
    owner_one_completion_headroom::Int
    owner_two_completion_occupancy::Int
    owner_two_completion_headroom::Int
end

_execution_interval_observation(
    ::Plant.AbstractOpticalPathBatchExecutor) =
    ExecutionIntervalObservation(
        UInt64(0),
        UInt(0),
        UInt(0),
        0,
        0,
        UInt64(0),
        UInt64(0),
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0)

function _execution_interval_observation(
    executor::PreparedExecutionOwnerExecutor)
    execution_owner_count(executor) == 2 || error(
        "Gate 8 interval evidence requires exactly two execution owners")
    first = execution_owner_accounting(executor, 1)
    second = execution_owner_accounting(executor, 2)
    return ExecutionIntervalObservation(
        execution_batches_completed(executor),
        first.task_id,
        second.task_id,
        first.last_thread_id,
        second.last_thread_id,
        first.work_completed,
        second.work_completed,
        first.due.occupancy,
        first.due.capacity - first.due.occupancy,
        second.due.occupancy,
        second.due.capacity - second.due.occupancy,
        first.completion.occupancy,
        first.completion.capacity - first.completion.occupancy,
        second.completion.occupancy,
        second.completion.capacity - second.completion.occupancy)
end

_owner_interval_observation(driver) =
    _execution_interval_observation(
    serial_optical_execution(driver.fixture.run))

@inline function _histogram_p99_ns(histogram)
    iszero(HdrHistogram.total_count(histogram)) &&
        return Int64(0)
    return Int64(HdrHistogram.value_at_percentile(
        histogram, 99.0))
end

@inline _ring_headroom(accounting) =
    accounting.capacity - accounting.occupancy

@inline function _cpu_utilization(
    user_cpu_ns::Union{Missing,Int64},
    system_cpu_ns::Union{Missing,Int64},
    wall_elapsed_ns::Int64)
    ismissing(user_cpu_ns) && return missing
    ismissing(system_cpu_ns) && return missing
    return (user_cpu_ns + system_cpu_ns) /
        max(1, wall_elapsed_ns)
end

function _record_operational_interval!(
    observer::OperationalIntervalObserver,
    driver,
    execution_elapsed_ns::Int64,
    wall_elapsed_ns::Int64)
    observer.count < length(observer.records) || error(
        "operational interval record capacity was exhausted")
    gc = Base.GC_Diff(Base.gc_num(), observer.gc_start)
    process = process_counters()
    counters = driver.counters
    fixture = driver.fixture
    primary = descriptor_accounting(fixture.wfs_port)
    feedback = descriptor_accounting(fixture.feedback_port)
    science = fixture.science_port === nothing ?
        nothing : descriptor_accounting(fixture.science_port)
    command_submission = descriptor_accounting(
        command_submission_port(fixture.command_ports))
    command_completion = descriptor_accounting(
        command_completion_port(fixture.command_ports))
    science_occupancy = science === nothing ?
        0 : science.occupancy
    science_headroom = science === nothing ?
        0 : _ring_headroom(science)
    execution = _owner_interval_observation(driver)
    user_cpu_ns = _counter_delta(
        process.user_cpu_ns,
        observer.process_start.user_cpu_ns)
    system_cpu_ns = _counter_delta(
        process.system_cpu_ns,
        observer.process_start.system_cpu_ns)
    liveness = serial_rtc_ingress_liveness_accounting(
        fixture.run)
    wall_seconds = wall_elapsed_ns / 1.0e9
    observer.count += 1
    observer.records[observer.count] = OperationalInterval(
        wall_elapsed_ns,
        execution_elapsed_ns,
        counters.offered_primary,
        counters.command_responses,
        Float64(counters.offered_primary) / wall_seconds,
        Float64(counters.command_responses) / wall_seconds,
        counters.shed_science,
        counters.commands_rejected,
        primary.occupancy,
        _ring_headroom(primary),
        feedback.occupancy,
        _ring_headroom(feedback),
        science_occupancy,
        science_headroom,
        command_submission.occupancy,
        _ring_headroom(command_submission),
        command_completion.occupancy,
        _ring_headroom(command_completion),
        _histogram_p99_ns(
            driver.histograms.publication_lateness),
        _histogram_p99_ns(
            driver.histograms.command_application_delay),
        _histogram_p99_ns(
            driver.histograms.closed_loop_response),
        counters.maximum_product_lease_hold_ns,
        gc.allocd,
        gc.total_time,
        gc.pause,
        gc.full_sweep,
        user_cpu_ns,
        system_cpu_ns,
        _cpu_utilization(
            user_cpu_ns, system_cpu_ns, wall_elapsed_ns),
        _counter_delta(
            process.voluntary_context_switches,
            observer.process_start.voluntary_context_switches),
        _counter_delta(
            process.involuntary_context_switches,
            observer.process_start.involuntary_context_switches),
        _counter_delta(
            process.migrations,
            observer.process_start.migrations),
        _counter_delta(
            process.minor_page_faults,
            observer.process_start.minor_page_faults),
        _counter_delta(
            process.major_page_faults,
            observer.process_start.major_page_faults),
        UInt8(liveness.status),
        liveness.reset_count,
        liveness.expiry_count,
        execution.batches_completed,
        execution.owner_one_task_id,
        execution.owner_two_task_id,
        execution.owner_one_thread_id,
        execution.owner_two_thread_id,
        execution.owner_one_work_completed,
        execution.owner_two_work_completed,
        execution.owner_one_due_occupancy,
        execution.owner_one_due_headroom,
        execution.owner_two_due_occupancy,
        execution.owner_two_due_headroom,
        execution.owner_one_completion_occupancy,
        execution.owner_one_completion_headroom,
        execution.owner_two_completion_occupancy,
        execution.owner_two_completion_headroom)
    return nothing
end

function Boundary.observe_boundary_step!(
    observer::OperationalIntervalObserver,
    driver,
    ::Any,
    execution_elapsed_ns::Int64)
    completed = driver.counters.command_responses
    completed < observer.last_probed_completion +
        observer.probe_stride && return nothing
    observer.last_probed_completion = completed
    wall_elapsed_ns = Int64(time_ns() - observer.wall_start_ns)
    wall_elapsed_ns < observer.next_interval_ns && return nothing
    _record_operational_interval!(
        observer,
        driver,
        execution_elapsed_ns,
        wall_elapsed_ns)
    while observer.next_interval_ns <= wall_elapsed_ns
        observer.next_interval_ns += observer.interval_ns
    end
    return nothing
end

function finish_operational_observer!(
    observer::OperationalIntervalObserver,
    driver)
    wall_elapsed_ns = Int64(time_ns() - observer.wall_start_ns)
    if observer.count == 0 ||
            observer.records[observer.count].wall_elapsed_ns <
            wall_elapsed_ns
        _record_operational_interval!(
            observer,
            driver,
            Boundary._execution_elapsed_ns(driver),
            wall_elapsed_ns)
    end
    return nothing
end

function interval_records(observer::OperationalIntervalObserver)
    return @view observer.records[1:observer.count]
end
