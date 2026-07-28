"""
Maximum execution-clock intervals for owner acknowledgement and ownership
drain after one run stop epoch is published.

Both deadlines are inclusive and relative to the same shutdown observation.
The first later execution-clock reading violates the corresponding interval.
"""
struct RunShutdownPolicy
    acknowledgement_timeout_ns::Int64
    drain_timeout_ns::Int64

    function RunShutdownPolicy(;
        acknowledgement_timeout_ns::Integer,
        drain_timeout_ns::Integer)
        acknowledgement = _checked_shutdown_timeout(
            acknowledgement_timeout_ns,
            :acknowledgement_timeout_ns)
        drain = _checked_shutdown_timeout(
            drain_timeout_ns,
            :drain_timeout_ns)
        return new(acknowledgement, drain)
    end
end

@inline function _checked_shutdown_timeout(
    value::Integer,
    label::Symbol)
    0 < value <= typemax(Int64) || throw(RunLifecycleError(
        :run_shutdown_policy,
        :invalid_timeout,
        "$label must be a positive Int64-compatible nanosecond count"))
    return Int64(value)
end

@inline _checked_shutdown_timeout(::Bool, label::Symbol) =
    throw(RunLifecycleError(
        :run_shutdown_policy,
        :invalid_timeout,
        "$label must be an integer nanosecond count, not Bool"))

acknowledgement_timeout_ns(policy::RunShutdownPolicy) =
    policy.acknowledgement_timeout_ns
drain_timeout_ns(policy::RunShutdownPolicy) =
    policy.drain_timeout_ns

"""Stable identity of one single-writer owner in a prepared run."""
struct RunOwnerID
    component::Symbol
    ordinal::UInt32

    function RunOwnerID(component::Symbol, ordinal::Integer)
        isempty(String(component)) && throw(RunLifecycleError(
            :run_owner,
            :empty_component,
            "run-owner component must not be empty"))
        ordinal > 0 || throw(RunLifecycleError(
            :run_owner,
            :invalid_ordinal,
            "run-owner ordinal must be positive"))
        ordinal <= typemax(UInt32) || throw(RunLifecycleError(
            :run_owner,
            :invalid_ordinal,
            "run-owner ordinal exceeds UInt32 range"))
        return new(component, UInt32(ordinal))
    end
end

RunOwnerID(::Symbol, ::Bool) = throw(RunLifecycleError(
    :run_owner,
    :invalid_ordinal,
    "run-owner ordinal must be an integer count, not Bool"))

Base.:(==)(left::RunOwnerID, right::RunOwnerID) =
    left.component == right.component && left.ordinal == right.ordinal
Base.isequal(left::RunOwnerID, right::RunOwnerID) =
    isequal(left.component, right.component) &&
    isequal(left.ordinal, right.ordinal)
Base.hash(value::RunOwnerID, seed::UInt) =
    hash(value.ordinal, hash(value.component, hash(RunOwnerID, seed)))

function Base.show(io::IO, value::RunOwnerID)
    print(
        io,
        nameof(typeof(value)),
        "(",
        repr(value.component),
        ", ",
        value.ordinal,
        ")")
end

run_owner_component(owner::RunOwnerID) = owner.component
run_owner_ordinal(owner::RunOwnerID) = Int(owner.ordinal)

"""Bounded stage retained in an owner-published failure record."""
@enum RunFailureStage::UInt8 begin
    CoordinatorFailureBoundary = 0x01
    OwnerBeforeDequeue = 0x02
    OwnerAfterDequeue = 0x03
    OwnerMaterialization = 0x04
    OwnerExecution = 0x05
    OwnerDeviceCompletion = 0x06
    OwnerCompletionPublication = 0x07
    ShutdownAcknowledgement = 0x08
    ShutdownDrain = 0x09
end

"""Compact immutable data release-published by one prepared run owner."""
struct RunFailureRecord
    kind::RunTerminationKind
    session::RunSessionID
    owner::RunOwnerID
    stage::RunFailureStage
    observed_execution_ns::Union{Nothing,Int64}
    component::Symbol
    reason::Symbol
    work_sequence::UInt64
end

function RunFailureRecord(
    kind::RunTerminationKind,
    session::RunSessionID,
    owner::RunOwnerID,
    stage::RunFailureStage,
    observed_execution_ns::Union{Nothing,Integer},
    component::Symbol,
    reason::Symbol;
    work_sequence::Integer=0)
    kind in (
        IngressWatchdogRunFailure,
        ResourcePolicyRunFailure,
        OwnerExceptionRunFailure,
        DeviceRunFailure,
        AcknowledgementTimeoutRunFailure,
        DrainTimeoutRunFailure,
    ) || throw(RunLifecycleError(
        :run_failure_record,
        :invalid_failure_kind,
        "run failure record requires a failure termination kind"))
    observed = observed_execution_ns === nothing ? nothing :
        _checked_int64_timestamp(
            observed_execution_ns,
            :run_failure_record,
            "failure execution timestamp")
    sequence = _checked_failure_work_sequence(work_sequence)
    return RunFailureRecord(
        kind,
        session,
        owner,
        stage,
        observed,
        _checked_reason(
            component,
            :run_failure_record,
            "failure component"),
        _checked_reason(
            reason,
            :run_failure_record,
            "failure reason"),
        sequence)
end

@inline function _checked_failure_work_sequence(
    work_sequence::Integer)
    work_sequence >= 0 || throw(RunLifecycleError(
        :run_failure_record,
        :invalid_work_sequence,
        "failure work sequence must be nonnegative"))
    work_sequence <= typemax(UInt64) || throw(RunLifecycleError(
        :run_failure_record,
        :invalid_work_sequence,
        "failure work sequence exceeds UInt64 range"))
    return UInt64(work_sequence)
end

@inline _checked_failure_work_sequence(::Bool) =
    throw(RunLifecycleError(
        :run_failure_record,
        :invalid_work_sequence,
        "failure work sequence must be an integer count, not Bool"))

run_failure_kind(record::RunFailureRecord) = record.kind
run_session(record::RunFailureRecord) = record.session
run_failure_owner(record::RunFailureRecord) = record.owner
run_failure_stage(record::RunFailureRecord) = record.stage
run_failure_execution_ns(record::RunFailureRecord) =
    record.observed_execution_ns
run_failure_component(record::RunFailureRecord) = record.component
run_failure_reason(record::RunFailureRecord) = record.reason
run_failure_work_sequence(record::RunFailureRecord) =
    record.work_sequence

mutable struct _RunOwnerFailureSignal
    record::RunFailureRecord
    @atomic published_stop_epoch::UInt64
    @atomic acknowledged_stop_epoch::UInt64
end

function _RunOwnerFailureSignal(
    session::RunSessionID,
    owner::RunOwnerID)
    sentinel = RunFailureRecord(
        OwnerExceptionRunFailure,
        session,
        owner,
        CoordinatorFailureBoundary,
        nothing,
        :unpublished,
        :unpublished)
    return _RunOwnerFailureSignal(
        sentinel,
        UInt64(0),
        UInt64(0))
end

@enum _RunShutdownCoordinationPhase::UInt8 begin
    _RunShutdownInactive = 0x01
    _RunShutdownDraining = 0x02
    _RunShutdownFinalized = 0x03
end

mutable struct _RunFailureCoordinatorState
    phase::_RunShutdownCoordinationPhase
    @atomic stop_epoch::UInt64
    started_execution_ns::Union{Nothing,Int64}
    acknowledgement_deadline_execution_ns::Union{Nothing,Int64}
    drain_deadline_execution_ns::Union{Nothing,Int64}
    first_failure_slot::UInt32
    acknowledgement_observed::Memory{Bool}
    acknowledgement_timed_out::Memory{Bool}
    drain_timed_out::Bool
end

"""
Prepared owner-local failure slots plus one single-writer lifecycle
coordinator. Slot 1 belongs to the serial coordinator; remaining slots map
one-to-one to prepared execution owners.
"""
struct PreparedRunFailureCoordinator
    session::RunSessionID
    policy::RunShutdownPolicy
    owners::Memory{RunOwnerID}
    signals::Memory{_RunOwnerFailureSignal}
    state::_RunFailureCoordinatorState
end

function _prepare_run_failure_coordinator(
    session::RunSessionID,
    policy::RunShutdownPolicy,
    owners::Memory{RunOwnerID})
    isempty(owners) && throw(RunLifecycleError(
        :run_failure_coordinator,
        :empty_owner_set,
        "a run failure coordinator requires at least its coordinator owner"))
    @inbounds for right in 2:length(owners)
        for left in 1:(right - 1)
            owners[left] == owners[right] && throw(RunLifecycleError(
                :run_failure_coordinator,
                :duplicate_owner,
                "prepared run-owner identities must be unique"))
        end
    end
    signals = Memory{_RunOwnerFailureSignal}(undef, length(owners))
    @inbounds for index in eachindex(signals)
        signals[index] = _RunOwnerFailureSignal(session, owners[index])
    end
    acknowledgement_timed_out = Memory{Bool}(undef, length(owners))
    acknowledgement_observed = Memory{Bool}(undef, length(owners))
    fill!(acknowledgement_observed, false)
    fill!(acknowledgement_timed_out, false)
    return PreparedRunFailureCoordinator(
        session,
        policy,
        owners,
        signals,
        _RunFailureCoordinatorState(
            _RunShutdownInactive,
            UInt64(0),
            nothing,
            nothing,
            nothing,
            UInt32(0),
            acknowledgement_observed,
            acknowledgement_timed_out,
            false))
end

@inline _run_failure_owner_count(
    coordinator::PreparedRunFailureCoordinator) =
    length(coordinator.owners)

@inline function _run_failure_owner(
    coordinator::PreparedRunFailureCoordinator,
    slot::Int)
    return @inbounds coordinator.owners[slot]
end

@inline function _run_shutdown_stop_epoch(
    coordinator::PreparedRunFailureCoordinator)
    return @atomic :acquire coordinator.state.stop_epoch
end

@inline _run_shutdown_requested(
    coordinator::PreparedRunFailureCoordinator) =
    !iszero(_run_shutdown_stop_epoch(coordinator))

@inline function _shutdown_deadline(
    started_execution_ns::Int64,
    timeout_ns::Int64)
    return reinterpret(
        Int64,
        reinterpret(UInt64, started_execution_ns) + UInt64(timeout_ns))
end

function _begin_run_shutdown!(
    coordinator::PreparedRunFailureCoordinator,
    observed_execution_ns::Int64)
    state = coordinator.state
    state.phase == _RunShutdownInactive || return _run_shutdown_stop_epoch(
        coordinator)
    state.started_execution_ns = observed_execution_ns
    state.acknowledgement_deadline_execution_ns = _shutdown_deadline(
        observed_execution_ns,
        coordinator.policy.acknowledgement_timeout_ns)
    state.drain_deadline_execution_ns = _shutdown_deadline(
        observed_execution_ns,
        coordinator.policy.drain_timeout_ns)
    state.phase = _RunShutdownDraining
    @atomic :release state.stop_epoch = UInt64(1)
    return UInt64(1)
end

@inline function _publish_run_failure!(
    coordinator::PreparedRunFailureCoordinator,
    slot::Int,
    record::RunFailureRecord)
    signal = @inbounds coordinator.signals[slot]
    iszero(@atomic :monotonic signal.published_stop_epoch) ||
        return false
    signal.record = record
    epoch = _run_shutdown_stop_epoch(coordinator)
    published_epoch = iszero(epoch) ? UInt64(1) : epoch
    @atomic :release signal.published_stop_epoch = published_epoch
    return true
end

@inline function _publish_run_failure!(
    coordinator::PreparedRunFailureCoordinator,
    slot::Int,
    kind::RunTerminationKind,
    stage::RunFailureStage,
    observed_execution_ns::Union{Nothing,Int64},
    component::Symbol,
    reason::Symbol;
    work_sequence::UInt64=UInt64(0))
    record = RunFailureRecord(
        kind,
        coordinator.session,
        _run_failure_owner(coordinator, slot),
        stage,
        observed_execution_ns,
        component,
        reason;
        work_sequence)
    return _publish_run_failure!(
        coordinator, slot, record)
end

function _observe_run_failures!(
    coordinator::PreparedRunFailureCoordinator)
    state = coordinator.state
    iszero(state.first_failure_slot) || return Int(
        state.first_failure_slot)
    @inbounds for slot in eachindex(coordinator.signals)
        signal = coordinator.signals[slot]
        iszero(@atomic :acquire signal.published_stop_epoch) &&
            continue
        state.first_failure_slot = UInt32(slot)
        return slot
    end
    return 0
end

function first_run_failure(
    coordinator::PreparedRunFailureCoordinator)
    slot = _observe_run_failures!(coordinator)
    iszero(slot) && return nothing
    return @inbounds coordinator.signals[slot].record
end

@inline function _acknowledge_run_stop!(
    coordinator::PreparedRunFailureCoordinator,
    slot::Int)
    epoch = _run_shutdown_stop_epoch(coordinator)
    iszero(epoch) && return false
    return _acknowledge_run_stop!(coordinator, slot, epoch)
end

@inline function _acknowledge_run_stop!(
    coordinator::PreparedRunFailureCoordinator,
    slot::Int,
    epoch::UInt64)
    iszero(epoch) && return false
    signal = @inbounds coordinator.signals[slot]
    acknowledged =
        @atomic :monotonic signal.acknowledged_stop_epoch
    acknowledged == epoch && return true
    iszero(acknowledged) || return false
    @atomic :release signal.acknowledged_stop_epoch = epoch
    return true
end

@inline function _run_owner_stop_acknowledged(
    coordinator::PreparedRunFailureCoordinator,
    slot::Int)
    epoch = _run_shutdown_stop_epoch(coordinator)
    iszero(epoch) && return false
    signal = @inbounds coordinator.signals[slot]
    return (@atomic :acquire signal.acknowledged_stop_epoch) ==
        epoch
end

function _run_shutdown_acknowledged(
    coordinator::PreparedRunFailureCoordinator)
    @inbounds for slot in eachindex(coordinator.signals)
        _run_owner_stop_acknowledged(coordinator, slot) ||
            return false
    end
    return true
end

@inline function _shutdown_interval_expired(
    started_execution_ns::Int64,
    current_execution_ns::Int64,
    timeout_ns::Int64)
    elapsed = reinterpret(
        Int64,
        reinterpret(UInt64, current_execution_ns) -
            reinterpret(UInt64, started_execution_ns))
    return elapsed < 0 || elapsed > timeout_ns
end

function _record_acknowledgement_timeouts!(
    coordinator::PreparedRunFailureCoordinator,
    current_execution_ns::Int64)
    state = coordinator.state
    started = state.started_execution_ns
    started === nothing && return 0
    expired = _shutdown_interval_expired(
        started,
        current_execution_ns,
        coordinator.policy.acknowledgement_timeout_ns)
    count = 0
    @inbounds for slot in eachindex(coordinator.signals)
        acknowledged =
            _run_owner_stop_acknowledged(coordinator, slot)
        if acknowledged && !expired
            state.acknowledgement_observed[slot] = true
            continue
        end
        acknowledged &&
            state.acknowledgement_observed[slot] &&
            continue
        if expired && !state.acknowledgement_timed_out[slot]
            state.acknowledgement_timed_out[slot] = true
            count += 1
        end
    end
    return count
end

function _run_shutdown_drain_expired!(
    coordinator::PreparedRunFailureCoordinator,
    current_execution_ns::Int64)
    state = coordinator.state
    started = state.started_execution_ns
    started === nothing && return false
    expired = _shutdown_interval_expired(
        started,
        current_execution_ns,
        coordinator.policy.drain_timeout_ns)
    expired && (state.drain_timed_out = true)
    return expired
end

function _finalize_run_shutdown!(
    coordinator::PreparedRunFailureCoordinator)
    coordinator.state.phase = _RunShutdownFinalized
    return coordinator
end

"""Cold record for one prepared owner's failure and stop acknowledgement."""
struct RunOwnerFailureAccounting
    owner::RunOwnerID
    failure::Union{Nothing,RunFailureRecord}
    acknowledged::Bool
    acknowledgement_timed_out::Bool
end

"""Cold bounded snapshot of one run's failure and shutdown coordination."""
struct RunFailureAccounting
    stop_epoch::UInt64
    started_execution_ns::Union{Nothing,Int64}
    acknowledgement_deadline_execution_ns::Union{Nothing,Int64}
    drain_deadline_execution_ns::Union{Nothing,Int64}
    first_failure::Union{Nothing,RunFailureRecord}
    owners::Memory{RunOwnerFailureAccounting}
    drain_timed_out::Bool
end

function run_failure_accounting(
    coordinator::PreparedRunFailureCoordinator)
    first = first_run_failure(coordinator)
    epoch = _run_shutdown_stop_epoch(coordinator)
    owners = Memory{RunOwnerFailureAccounting}(
        undef, length(coordinator.signals))
    @inbounds for slot in eachindex(owners)
        signal = coordinator.signals[slot]
        published =
            !iszero(@atomic :acquire signal.published_stop_epoch)
        owners[slot] = RunOwnerFailureAccounting(
            coordinator.owners[slot],
            published ? signal.record : nothing,
            !iszero(epoch) &&
                (@atomic :acquire signal.acknowledged_stop_epoch) ==
                    epoch,
            coordinator.state.acknowledgement_timed_out[slot])
    end
    state = coordinator.state
    return RunFailureAccounting(
        epoch,
        state.started_execution_ns,
        state.acknowledgement_deadline_execution_ns,
        state.drain_deadline_execution_ns,
        first,
        owners,
        state.drain_timed_out)
end
