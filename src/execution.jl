"""
    Execution

Prepared, transport-neutral execution ownership for optical path groups.
Core retains the deterministic plant, path-local products, numerical plans,
and device contexts. This namespace adds fixed owner identity, bounded SPSC
due/completion handoffs, explicit CPU admission, and optional long-lived
Agent.jl duty-cycle tasks. Scheduling remains explicit; optional CPU IDs are
forwarded to Agent.jl's ThreadPinning.jl extension. This namespace does not
move products between memory domains or create one task per event.
"""
module Execution

import AdaptiveOpticsSim.Plant
import Agent

using AdaptiveOpticsSim.Backends: AbstractArrayBackend
using AdaptiveOpticsSim.Backends: AbstractComputeDevice, CPUBackend
using AdaptiveOpticsSim.Plant: AbstractOpticalPathBatchExecutor
using AdaptiveOpticsSim.Plant: CPUExecutionBudget, CPUExecutionEnvironment
using AdaptiveOpticsSim.Plant: OpticalPathBatchClaim
using AdaptiveOpticsSim.Plant: PlantEventLoopState, PlantEventLoopWorkspace
using AdaptiveOpticsSim.Plant: PlantTimestamp, PreparedPlantEventLoop
using AdaptiveOpticsSim.Plant: SerialOpticalPathBatchExecutor
using AdaptiveOpticsSim.Plant: abandon_optical_path_batch!
using AdaptiveOpticsSim.Plant: begin_optical_path_batch!
using AdaptiveOpticsSim.Plant: complete_optical_path_batch!
using AdaptiveOpticsSim.Plant: device_path_batch_backend
using AdaptiveOpticsSim.Plant: device_path_batch_compute_device
using AdaptiveOpticsSim.Plant: device_path_batch_group_count
using AdaptiveOpticsSim.Plant: device_path_batch_group_ordinal
using AdaptiveOpticsSim.Plant: device_path_batch_owner
using AdaptiveOpticsSim.Plant: execute_device_path_batch!
using AdaptiveOpticsSim.Plant: execute_path_execution_group!
using AdaptiveOpticsSim.Plant: materialize_device_path_batch!
using AdaptiveOpticsSim.Plant: materialize_path_execution_group!
using AdaptiveOpticsSim.Plant: optical_path_batch_due_group_count
using AdaptiveOpticsSim.Plant: optical_path_batch_due_group_ordinal
using AdaptiveOpticsSim.Plant: path_execution_backend
using AdaptiveOpticsSim.Plant: path_execution_compute_device
using AdaptiveOpticsSim.Plant: path_execution_group
using AdaptiveOpticsSim.Plant: path_execution_group_count
using AdaptiveOpticsSim.Plant: path_execution_group_device_batch_owner_ordinal
using AdaptiveOpticsSim.Plant: path_execution_group_requirements
using AdaptiveOpticsSim.Plant: seal_optical_path_batch_materialization!
using AdaptiveOpticsSim.Plant: validate_cpu_execution_budget

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError
using ..Lifecycle: DeviceRunFailure, OwnerExceptionRunFailure
using ..Lifecycle: OwnerAfterDequeue, OwnerBeforeDequeue
using ..Lifecycle: OwnerCompletionPublication, OwnerDeviceCompletion
using ..Lifecycle: OwnerExecution, OwnerMaterialization
using ..Lifecycle: PreparedRunFailureCoordinator
using ..Lifecycle: RunFailureStage
using ..Lifecycle: RunOwnerID, RunSessionID, RunShutdownPolicy
using ..Lifecycle: _acknowledge_run_stop!
using ..Lifecycle: _begin_run_shutdown!
using ..Lifecycle: _prepare_run_failure_coordinator
using ..Lifecycle: _publish_run_failure!, _run_shutdown_requested
using ..Lifecycle: _run_owner_stop_acknowledged
using ..Ownership: RingAccounting, RingClosed, RingEmpty, RingFull
using ..Ownership: RingTransferSucceeded, SPSCDescriptorRing
using ..Ownership: close_ring!, ring_accounting
using ..Ownership: try_submit!, try_take!
using ..Ports: AbstractResourceCriticality
using ..Ports: OptionalResource, RequiredResource
import ..Ports: maximum_resource_lateness_ns
import ..Ports: overload_recovery_occupancy, resource_criticality
import ..Ports: resource_is_required
using ..Timing: ExecutionClockMapping
using ..Timing: _read_execution_clock, execution_clock
using ..Timing: execution_lateness_ns

export ExecutionOwnerError
export AbstractOpticalExecutionConfiguration, SerialOpticalExecution
export AbstractExecutionOwnerMode
export DeterministicExecutionOwners, AgentExecutionOwners
export AbstractExecutionOwnerScheduling
export SchedulerManagedExecutionOwnerScheduling
export ThreadAssignedExecutionOwnerScheduling
export ExecutionOwnerConfiguration
export ExecutionOwnerID, execution_owner_id_value
export ExecutionOwnerKind, PathGroupExecutionOwner, DeviceBatchExecutionOwner
export ExecutionOwnersPhase, ExecutionOwnersPrepared, ExecutionOwnersArmed
export ExecutionOwnersRunning, ExecutionOwnersStopped, ExecutionOwnersFailed
export PreparedExecutionOwner, PreparedExecutionOwnerExecutor
export execution_owner_count, execution_owner
export execution_owner_id, execution_owner_kind
export execution_owner_backend, execution_owner_compute_device
export execution_owner_group_count, execution_owner_group_ordinal
export AbstractExecutionOwnerOverloadAction
export FailRunOnOwnerOverload, ExecutionOwnerOverloadPolicy
export ExecutionOwnerPolicyOverride
export execution_owner_overload_policy, execution_owner_overload_action
export resource_criticality, maximum_resource_lateness_ns
export overload_recovery_occupancy, resource_is_required
export execution_owner_mode, execution_owner_idle_strategy_factory
export execution_owner_scheduling
export execution_cpu_budget, execution_cpu_environment
export execution_owner_ring_capacity, execution_owners_phase
export execution_batches_completed
export ExecutionOwnerOverloadDecision
export ExecutionOwnerNoOverloadDecision
export ExecutionOwnerFailedForCapacity, ExecutionOwnerFailedForDeadline
export ExecutionOwnerAccounting, execution_owner_accounting
export execution_owners_are_quiescent

"""Invalid execution-owner configuration, ownership, or lifecycle operation."""
struct ExecutionOwnerError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

@noinline function _execution_owner_error(
    reason::Symbol,
    message::AbstractString,
)
    throw(ExecutionOwnerError(
        :execution_owners,
        reason,
        String(message),
    ))
end

"""
Configuration policy resolved while preparing one serial run.

`SerialOpticalExecution` preserves the canonical core serial oracle.
`ExecutionOwnerConfiguration` prepares bounded execution owners.
"""
abstract type AbstractOpticalExecutionConfiguration end

"""Use the core's canonical deterministic serial path-batch executor."""
struct SerialOpticalExecution <: AbstractOpticalExecutionConfiguration end

"""Prepared owner-service policy."""
abstract type AbstractExecutionOwnerMode end

"""
Service prepared owner rings synchronously from the coordinator.

Every group retains a distinct logical writer and bounded due/completion path,
but no Julia worker task is created. `alternate_order=true` reverses successive
materialization and execution service orders to exercise order independence
while retaining deterministic replay.
"""
struct DeterministicExecutionOwners <: AbstractExecutionOwnerMode
    alternate_order::Bool
end

DeterministicExecutionOwners(; alternate_order::Bool=true) =
    DeterministicExecutionOwners(alternate_order)

"""Scheduling policy for long-lived Agent.jl execution owners."""
abstract type AbstractExecutionOwnerScheduling end

"""
Allow Agent.jl to launch migratable, scheduler-cooperative owner tasks.

This portable policy is appropriate for deterministic correctness tests and
resource-constrained development. AgentRunner yields after every duty cycle in
this mode, so it is not the production low-tail scheduling policy.
"""
struct SchedulerManagedExecutionOwnerScheduling <:
    AbstractExecutionOwnerScheduling end

"""
Assign each execution owner to one unique Julia default-pool thread.

`thread_ids` is ordered by prepared owner ordinal. Optional zero-based
`cpu_ids` are forwarded to Agent.jl's ThreadPinning extension. CPU affinity
requires the caller to load ThreadPinning.jl and does not reserve a physical
core, establish real-time priority, or prove that SMT siblings and interrupts
are isolated. Arm, start, and run this mode from one sticky coordinator task
on an unassigned Julia managed thread.
"""
struct ThreadAssignedExecutionOwnerScheduling{
    T<:Tuple,
    C<:Union{Nothing,Tuple},
} <: AbstractExecutionOwnerScheduling
    thread_ids::T
    cpu_ids::C

    function ThreadAssignedExecutionOwnerScheduling(
        thread_ids,
        cpu_ids,
    )
        threads = _checked_execution_owner_ids(
            thread_ids,
            _checked_execution_owner_thread_id,
            :invalid_owner_thread,
            "assigned Julia thread IDs",
        )
        cpus = if cpu_ids === nothing
            nothing
        else
            checked_cpu_ids = _checked_execution_owner_ids(
                cpu_ids,
                _checked_execution_owner_cpu_id,
                :invalid_owner_cpu,
                "assigned OS CPU IDs",
            )
            length(checked_cpu_ids) == length(threads) ||
                _execution_owner_error(
                    :invalid_owner_cpu,
                    "assigned OS CPU IDs must match the Julia thread-ID count",
                )
            checked_cpu_ids
        end
        return new{typeof(threads),typeof(cpus)}(threads, cpus)
    end
end

@inline function _checked_execution_owner_thread_id(
    value::Integer,
)
    value > 0 || _execution_owner_error(
        :invalid_owner_thread,
        "assigned Julia thread IDs must be positive",
    )
    value <= typemax(Int) || _execution_owner_error(
        :invalid_owner_thread,
        "assigned Julia thread ID exceeds the supported Int range",
    )
    return Int(value)
end

@inline _checked_execution_owner_thread_id(
    ::Bool,
) = _execution_owner_error(
    :invalid_owner_thread,
    "assigned Julia thread IDs must be integer identifiers, not Bool",
)

@inline _checked_execution_owner_thread_id(
    ::Any,
) = _execution_owner_error(
    :invalid_owner_thread,
    "assigned Julia thread IDs must be integer identifiers",
)

@inline function _checked_execution_owner_cpu_id(
    value::Integer,
)
    value >= 0 || _execution_owner_error(
        :invalid_owner_cpu,
        "assigned OS CPU IDs must be nonnegative",
    )
    value <= typemax(Int) || _execution_owner_error(
        :invalid_owner_cpu,
        "assigned OS CPU ID exceeds the supported Int range",
    )
    return Int(value)
end

@inline _checked_execution_owner_cpu_id(
    ::Bool,
) = _execution_owner_error(
    :invalid_owner_cpu,
    "assigned OS CPU IDs must be integer identifiers, not Bool",
)

@inline _checked_execution_owner_cpu_id(
    ::Any,
) = _execution_owner_error(
    :invalid_owner_cpu,
    "assigned OS CPU IDs must be integer identifiers",
)

function _checked_execution_owner_ids(
    values::Tuple,
    checker,
    reason::Symbol,
    label::AbstractString,
)
    isempty(values) && _execution_owner_error(
        reason,
        "$label cannot be empty",
    )
    checked = ntuple(index -> checker(values[index]), length(values))
    length(unique(checked)) == length(checked) ||
        _execution_owner_error(
            reason,
            "$label must be unique",
        )
    return checked
end

function _checked_execution_owner_ids(
    ::Any,
    ::Any,
    reason::Symbol,
    label::AbstractString,
)
    return _execution_owner_error(
        reason,
        "$label must be supplied as a tuple",
    )
end

function ThreadAssignedExecutionOwnerScheduling(
    thread_ids;
    cpu_ids=nothing,
)
    return ThreadAssignedExecutionOwnerScheduling(
        thread_ids, cpu_ids)
end

"""
Run every prepared execution owner as one long-lived Agrona-style Agent.jl
duty-cycle agent.

`idle_strategy_factory()` is checked once when this configuration is built,
then called once for the coordinator wait path and once for every owner runner
during preparation. It must be side-effect-free apart from constructing the
strategy, return the same concrete `Agent.IdleStrategy` type each time, and
return distinct instances when that type is mutable. Rings, overload decisions,
stop epochs, and drain accounting remain owned by AdaptiveOpticsHIL.
"""
struct AgentExecutionOwners{
    I<:Agent.IdleStrategy,
    F,
    P<:AbstractExecutionOwnerScheduling,
} <: AbstractExecutionOwnerMode
    idle_strategy_factory::F
    scheduling::P
end

function AgentExecutionOwners(
    idle_strategy_type::Type{I};
    scheduling::AbstractExecutionOwnerScheduling=
        SchedulerManagedExecutionOwnerScheduling(),
) where {I<:Agent.IdleStrategy}
    applicable(idle_strategy_type) || _execution_owner_error(
        :invalid_idle_strategy_factory,
        "Agent idle-strategy factory must be callable without arguments",
    )
    _checked_agent_idle_strategy(idle_strategy_type)
    return AgentExecutionOwners{
        I,
        typeof(idle_strategy_type),
        typeof(scheduling),
    }(idle_strategy_type, scheduling)
end

function AgentExecutionOwners(
    idle_strategy_factory;
    scheduling::AbstractExecutionOwnerScheduling=
        SchedulerManagedExecutionOwnerScheduling(),
)
    applicable(idle_strategy_factory) || _execution_owner_error(
        :invalid_idle_strategy_factory,
        "Agent idle-strategy factory must be callable without arguments",
    )
    strategy = _checked_agent_idle_strategy(
        idle_strategy_factory)
    return AgentExecutionOwners{
        typeof(strategy),
        typeof(idle_strategy_factory),
        typeof(scheduling),
    }(idle_strategy_factory, scheduling)
end

AgentExecutionOwners(;
    scheduling::AbstractExecutionOwnerScheduling=
        SchedulerManagedExecutionOwnerScheduling(),
) = AgentExecutionOwners(
    Agent.YieldingIdleStrategy; scheduling)

_validate_execution_owner_scheduling(
    ::SchedulerManagedExecutionOwnerScheduling,
) = nothing
_validate_execution_owner_scheduling(
    ::ThreadAssignedExecutionOwnerScheduling,
) = nothing

function _validate_execution_owner_scheduling(
    ::AbstractExecutionOwnerScheduling,
)
    return _execution_owner_error(
        :unsupported_owner_scheduling,
        "execution-owner scheduling policy is not supported",
    )
end

_validate_execution_owner_mode(
    ::DeterministicExecutionOwners,
) = nothing

function _validate_execution_owner_mode(
    mode::AgentExecutionOwners,
)
    return _validate_execution_owner_scheduling(mode.scheduling)
end

function _validate_execution_owner_mode(
    ::AbstractExecutionOwnerMode,
)
    return _execution_owner_error(
        :unsupported_owner_mode,
        "execution-owner mode is not supported",
    )
end

"""Prepared action when an execution-owner capacity or deadline proof fails."""
abstract type AbstractExecutionOwnerOverloadAction end

"""
Fail the run when an owner cannot preserve its prepared capacity or deadline.

This action is valid for required and optional owners. Work is never silently
revoked after dispatch.
"""
struct FailRunOnOwnerOverload <:
    AbstractExecutionOwnerOverloadAction end

@inline _checked_execution_owner_maximum_lateness(::Nothing) = nothing

@inline function _checked_execution_owner_maximum_lateness(
    value::Integer,
)
    0 <= value <= typemax(Int64) || _execution_owner_error(
        :invalid_maximum_lateness,
        "maximum execution-owner lateness must be a nonnegative Int64-compatible nanosecond count",
    )
    return Int64(value)
end

@inline _checked_execution_owner_maximum_lateness(
    ::Bool,
) = _execution_owner_error(
    :invalid_maximum_lateness,
    "maximum execution-owner lateness must be an integer nanosecond count, not Bool",
)

@inline function _checked_execution_owner_recovery_occupancy(
    value::Integer,
)
    0 <= value <= typemax(Int) || _execution_owner_error(
        :invalid_recovery_occupancy,
        "execution-owner recovery occupancy must be a nonnegative addressable count",
    )
    return Int(value)
end

@inline _checked_execution_owner_recovery_occupancy(
    ::Bool,
) = _execution_owner_error(
    :invalid_recovery_occupancy,
    "execution-owner recovery occupancy must be an integer count, not Bool",
)

"""
Immutable capacity/deadline contract applied to one or more prepared owners.

`maximum_lateness_ns === nothing` selects no execution-clock owner deadline.
`recovery_occupancy` applies independently to the equally sized due and
completion descriptor paths and is validated when the topology is prepared.
"""
struct ExecutionOwnerOverloadPolicy{
    C<:AbstractResourceCriticality,
    A<:AbstractExecutionOwnerOverloadAction,
}
    criticality::C
    action::A
    maximum_lateness_ns::Union{Nothing,Int64}
    recovery_occupancy::Int

    function ExecutionOwnerOverloadPolicy(
        criticality::C,
        action::A;
        maximum_lateness_ns::Union{Nothing,Integer},
        recovery_occupancy::Integer,
    ) where {
        C<:AbstractResourceCriticality,
        A<:AbstractExecutionOwnerOverloadAction,
    }
        return new{C,A}(
            criticality,
            action,
            _checked_execution_owner_maximum_lateness(
                maximum_lateness_ns),
            _checked_execution_owner_recovery_occupancy(
                recovery_occupancy),
        )
    end
end

resource_criticality(policy::ExecutionOwnerOverloadPolicy) =
    policy.criticality
execution_owner_overload_action(
    policy::ExecutionOwnerOverloadPolicy) = policy.action
maximum_resource_lateness_ns(
    policy::ExecutionOwnerOverloadPolicy) =
    policy.maximum_lateness_ns
overload_recovery_occupancy(
    policy::ExecutionOwnerOverloadPolicy) =
    policy.recovery_occupancy
@inline resource_is_required(
    policy::ExecutionOwnerOverloadPolicy) =
    resource_is_required(resource_criticality(policy))

_validate_execution_owner_overload_action(
    ::FailRunOnOwnerOverload,
) = nothing

function _validate_execution_owner_overload_action(
    ::AbstractExecutionOwnerOverloadAction,
)
    return _execution_owner_error(
        :unsupported_overload_action,
        "execution-owner overload action is not supported",
    )
end

struct _ExecutionOwnerPolicyOverrideRecord
    owner::UInt32
    policy::ExecutionOwnerOverloadPolicy
end

struct _ExecutionOwnerConfigurationToken end
const _EXECUTION_OWNER_CONFIGURATION_TOKEN =
    _ExecutionOwnerConfigurationToken()

"""
Immutable owner-execution admission contract.

The CPU budget and observed environment come from AdaptiveOpticsSim's
HIL-neutral admission surface. Construction validates them without changing
Julia, FFT-provider, or BLAS thread settings. `ring_capacity` bounds each
owner's one-producer/one-consumer due and completion path. `owner_policy` is a
mandatory declaration for every prepared owner; exact stable owner IDs may
replace it through `owner_policy_overrides`.
"""
struct ExecutionOwnerConfiguration{
    M<:AbstractExecutionOwnerMode,
    B<:CPUExecutionBudget,
    P<:ExecutionOwnerOverloadPolicy,
} <: AbstractOpticalExecutionConfiguration
    mode::M
    cpu_budget::B
    cpu_environment::CPUExecutionEnvironment
    ring_capacity::Int
    owner_policy::P
    owner_policy_overrides::Memory{
        _ExecutionOwnerPolicyOverrideRecord}

    function ExecutionOwnerConfiguration(
        mode::M,
        cpu_budget::B,
        cpu_environment::CPUExecutionEnvironment,
        ring_capacity::Int,
        owner_policy::P,
        owner_policy_overrides::Memory{
            _ExecutionOwnerPolicyOverrideRecord},
        ::_ExecutionOwnerConfigurationToken,
    ) where {
        M<:AbstractExecutionOwnerMode,
        B<:CPUExecutionBudget,
        P<:ExecutionOwnerOverloadPolicy,
    }
        return new{M,B,P}(
            mode,
            cpu_budget,
            cpu_environment,
            ring_capacity,
            owner_policy,
            owner_policy_overrides,
        )
    end
end

function _checked_execution_ring_capacity(capacity::Integer)
    capacity > 0 || _execution_owner_error(
        :invalid_ring_capacity,
        "execution-owner ring capacity must be positive",
    )
    capacity <= typemax(Int) || _execution_owner_error(
        :invalid_ring_capacity,
        "execution-owner ring capacity exceeds the supported Int range",
    )
    return Int(capacity)
end

_checked_execution_ring_capacity(::Bool) = _execution_owner_error(
    :invalid_ring_capacity,
    "execution-owner ring capacity must be an integer count, not Bool",
)

function ExecutionOwnerConfiguration(
    mode::M,
    cpu_budget::B,
    cpu_environment::CPUExecutionEnvironment;
    ring_capacity::Integer=1,
    owner_policy::ExecutionOwnerOverloadPolicy,
    owner_policy_overrides::Tuple=(),
) where {
    M<:AbstractExecutionOwnerMode,
    B<:CPUExecutionBudget,
}
    _validate_execution_owner_mode(mode)
    _validate_execution_owner_overload_action(owner_policy.action)
    overrides = _checked_execution_owner_policy_overrides(
        owner_policy_overrides)
    validate_cpu_execution_budget(cpu_budget, cpu_environment)
    return ExecutionOwnerConfiguration(
        mode,
        cpu_budget,
        cpu_environment,
        _checked_execution_ring_capacity(ring_capacity),
        owner_policy,
        overrides,
        _EXECUTION_OWNER_CONFIGURATION_TOKEN,
    )
end

struct _ExecutionOwnerIDToken end
const _EXECUTION_OWNER_ID_TOKEN = _ExecutionOwnerIDToken()

"""Stable positive ordinal of one prepared execution owner."""
struct ExecutionOwnerID
    value::UInt32

    ExecutionOwnerID(value::UInt32, ::_ExecutionOwnerIDToken) = new(value)
end

function ExecutionOwnerID(value::Integer)
    value > 0 || _execution_owner_error(
        :invalid_owner_identity,
        "execution-owner identity must be positive",
    )
    value <= typemax(UInt32) || _execution_owner_error(
        :invalid_owner_identity,
        "execution-owner identity exceeds UInt32 range",
    )
    return ExecutionOwnerID(UInt32(value), _EXECUTION_OWNER_ID_TOKEN)
end

ExecutionOwnerID(::Bool) = _execution_owner_error(
    :invalid_owner_identity,
    "execution-owner identity must be an integer count, not Bool",
)

Base.:(==)(left::ExecutionOwnerID, right::ExecutionOwnerID) =
    left.value == right.value
Base.isequal(left::ExecutionOwnerID, right::ExecutionOwnerID) =
    isequal(left.value, right.value)
Base.hash(value::ExecutionOwnerID, seed::UInt) =
    hash(value.value, hash(ExecutionOwnerID, seed))

function Base.show(io::IO, value::ExecutionOwnerID)
    print(io, nameof(typeof(value)), "(", value.value, ")")
end

execution_owner_id_value(value::ExecutionOwnerID) = value.value

"""Replace the configured owner policy for one stable prepared owner ID."""
struct ExecutionOwnerPolicyOverride{
    P<:ExecutionOwnerOverloadPolicy,
}
    owner::ExecutionOwnerID
    policy::P

    function ExecutionOwnerPolicyOverride(
        owner::ExecutionOwnerID,
        policy::P,
    ) where {P<:ExecutionOwnerOverloadPolicy}
        _validate_execution_owner_overload_action(policy.action)
        return new{P}(owner, policy)
    end
end

@inline function _store_execution_owner_policy_override!(
    destination::Memory{_ExecutionOwnerPolicyOverrideRecord},
    index::Int,
    override::ExecutionOwnerPolicyOverride,
)
    destination[index] = _ExecutionOwnerPolicyOverrideRecord(
        execution_owner_id_value(override.owner),
        override.policy,
    )
    return nothing
end

function _store_execution_owner_policy_override!(
    ::Memory{_ExecutionOwnerPolicyOverrideRecord},
    ::Int,
    ::Any,
)
    return _execution_owner_error(
        :invalid_owner_policy_override,
        "execution-owner policy overrides must be ExecutionOwnerPolicyOverride values",
    )
end

function _checked_execution_owner_policy_overrides(
    values::Tuple,
)
    Base.@nospecialize values
    overrides = Memory{_ExecutionOwnerPolicyOverrideRecord}(
        undef, length(values))
    @inbounds for index in eachindex(values)
        _store_execution_owner_policy_override!(
            overrides, index, values[index])
    end
    @inbounds for right in 2:length(overrides)
        owner = overrides[right].owner
        for left in 1:(right - 1)
            overrides[left].owner == owner &&
                _execution_owner_error(
                    :duplicate_owner_policy,
                    "an execution owner cannot have more than one overload-policy override",
                )
        end
    end
    return overrides
end

@inline function _resolve_execution_owner_policy(
    default::ExecutionOwnerOverloadPolicy,
    owner::ExecutionOwnerID,
    overrides::Memory{_ExecutionOwnerPolicyOverrideRecord},
)
    owner_value = execution_owner_id_value(owner)
    @inbounds for override in overrides
        override.owner == owner_value && return override.policy
    end
    return default
end

@inline function _execution_owner_policy(
    configuration::ExecutionOwnerConfiguration,
    owner::ExecutionOwnerID,
)
    return _resolve_execution_owner_policy(
        configuration.owner_policy,
        owner,
        configuration.owner_policy_overrides,
    )
end

function _validate_prepared_owner_policy_overrides(
    overrides::Memory{_ExecutionOwnerPolicyOverrideRecord},
    owner_count::Int,
)
    @inbounds for override in overrides
        Int(override.owner) <= owner_count ||
            _execution_owner_error(
                :unknown_owner_policy,
                "an execution-owner policy override refers to an owner absent from the prepared topology",
            )
    end
    return nothing
end

"""Fixed core target owned by one HIL execution owner."""
@enum ExecutionOwnerKind::UInt8 begin
    PathGroupExecutionOwner = 0x01
    DeviceBatchExecutionOwner = 0x02
end

@enum _ExecutionOwnerWorkPhase::UInt8 begin
    _ExecutionOwnerStartup = 0x01
    _ExecutionOwnerMaterialization = 0x02
    _ExecutionOwnerExecution = 0x03
    _ExecutionOwnerStop = 0x04
end

@enum _ExecutionOwnerCompletionStatus::UInt8 begin
    _ExecutionOwnerWorkCompleted = 0x01
    _ExecutionOwnerWorkFailed = 0x02
end

struct _ExecutionOwnerWorkDescriptor
    session::RunSessionID
    owner::ExecutionOwnerID
    batch_sequence::UInt64
    phase::_ExecutionOwnerWorkPhase
    claim::OpticalPathBatchClaim
end

struct _ExecutionOwnerCompletion
    session::RunSessionID
    owner::ExecutionOwnerID
    batch_sequence::UInt64
    phase::_ExecutionOwnerWorkPhase
    status::_ExecutionOwnerCompletionStatus
end

struct _PreparedExecutionOwnerDeadline
    enabled::Bool
    maximum_lateness_ns::Int64
end

"""
Run-immutable execution owner.

The target is either one independent path group or one exact prepared core
device-batch owner. `group_ordinals` identifies the fixed path-local product
slots; the descriptor rings never carry those products.
"""
struct PreparedExecutionOwner
    id::ExecutionOwnerID
    kind::ExecutionOwnerKind
    target_ordinal::UInt32
    group_ordinals::Memory{UInt32}
    backend::AbstractArrayBackend
    compute_device::AbstractComputeDevice
    overload_policy::ExecutionOwnerOverloadPolicy
    deadline::_PreparedExecutionOwnerDeadline
    due::SPSCDescriptorRing{_ExecutionOwnerWorkDescriptor}
    completion::SPSCDescriptorRing{_ExecutionOwnerCompletion}
end

execution_owner_id(owner::PreparedExecutionOwner) = owner.id
execution_owner_kind(owner::PreparedExecutionOwner) = owner.kind
execution_owner_backend(owner::PreparedExecutionOwner) = owner.backend
execution_owner_compute_device(owner::PreparedExecutionOwner) =
    owner.compute_device
execution_owner_overload_policy(owner::PreparedExecutionOwner) =
    owner.overload_policy
execution_owner_overload_action(owner::PreparedExecutionOwner) =
    execution_owner_overload_action(owner.overload_policy)
resource_criticality(owner::PreparedExecutionOwner) =
    resource_criticality(owner.overload_policy)
maximum_resource_lateness_ns(owner::PreparedExecutionOwner) =
    maximum_resource_lateness_ns(owner.overload_policy)
overload_recovery_occupancy(owner::PreparedExecutionOwner) =
    overload_recovery_occupancy(owner.overload_policy)
@inline resource_is_required(owner::PreparedExecutionOwner) =
    resource_is_required(owner.overload_policy)
execution_owner_group_count(owner::PreparedExecutionOwner) =
    length(owner.group_ordinals)

function execution_owner_group_ordinal(
    owner::PreparedExecutionOwner,
    index::Integer,
)
    checkbounds(owner.group_ordinals, index)
    return Int(@inbounds owner.group_ordinals[Int(index)])
end

@enum _ExecutionOwnerActivity::UInt8 begin
    _ExecutionOwnerIdle = 0x01
    _ExecutionOwnerWorking = 0x02
    _ExecutionOwnerStoppedActivity = 0x03
    _ExecutionOwnerFailedActivity = 0x04
end

"""Last bounded overload decision for one execution owner."""
@enum ExecutionOwnerOverloadDecision::UInt8 begin
    ExecutionOwnerNoOverloadDecision = 0x01
    ExecutionOwnerFailedForCapacity = 0x02
    ExecutionOwnerFailedForDeadline = 0x03
end

"""Coordinator-owned mutable overload evidence for one owner."""
mutable struct _ExecutionOwnerOverloadState
    overload_episodes::UInt64
    recovery_count::UInt64
    current_due_occupancy::Int
    maximum_due_occupancy::Int
    current_completion_occupancy::Int
    maximum_completion_occupancy::Int
    latest_lateness_ns::Int64
    maximum_lateness_ns::Int64
    overloaded::Bool
    recovered_to_threshold::Bool
    decision::ExecutionOwnerOverloadDecision
end

mutable struct _ExecutionOwnerState
    activity::_ExecutionOwnerActivity
    active_batch_sequence::UInt64
    work_taken::UInt64
    work_completed::UInt64
    work_failed::UInt64
    work_cancelled::UInt64
    task_id::UInt
    last_thread_id::Int
    failure::Any
end

struct _ExecutionOwnerWorkspace
    work::Base.RefValue{_ExecutionOwnerWorkDescriptor}
end

"""Operational phase of a prepared owner executor."""
@enum ExecutionOwnersPhase::UInt8 begin
    ExecutionOwnersPrepared = 0x01
    ExecutionOwnersArmed = 0x02
    ExecutionOwnersRunning = 0x03
    ExecutionOwnersStopped = 0x04
    ExecutionOwnersFailed = 0x05
end

mutable struct _ExecutionCoordinatorState
    phase::ExecutionOwnersPhase
    batch_sequence::UInt64
    batch_count::UInt64
    active_claim::Union{Nothing,OpticalPathBatchClaim}
    submitted::Memory{UInt64}
    completions::Memory{UInt64}
    startup_acknowledged::Memory{Bool}
    stop_acknowledged::Memory{Bool}
end

struct _ExecutionCoordinatorWorkspace
    due_owner_ordinals::Memory{UInt32}
    owner_due::Memory{Bool}
    completion_seen::Memory{Bool}
    completions::Memory{Base.RefValue{_ExecutionOwnerCompletion}}
end

"""
Prepared bounded owner executor accepted by the core path-batch policy seam.

The object retains exact state/workspace identity, so it cannot be mixed with
another prepared serial run. Worker tasks are created only while arming an
Agent mode and remain stable until nominal stop.
"""
struct PreparedExecutionOwnerExecutor{
    M<:AbstractExecutionOwnerMode,
    B<:CPUExecutionBudget,
    P<:PreparedPlantEventLoop,
    S<:PlantEventLoopState,
    W<:PlantEventLoopWorkspace,
    I,
} <: AbstractOpticalPathBatchExecutor
    session::RunSessionID
    prepared::P
    state::S
    workspace::W
    owners::Memory{PreparedExecutionOwner}
    group_owner_ordinals::Memory{UInt32}
    owner_states::Memory{_ExecutionOwnerState}
    owner_overload_states::Memory{_ExecutionOwnerOverloadState}
    owner_workspaces::Memory{_ExecutionOwnerWorkspace}
    coordinator::_ExecutionCoordinatorState
    coordinator_workspace::_ExecutionCoordinatorWorkspace
    failures::PreparedRunFailureCoordinator
    # Cold lifecycle registry: each start call crosses a function barrier and
    # the spawned Agent loop retains its concrete runner/strategy/agent type.
    runners::Memory{Agent.AgentRunner}
    coordinator_idle_strategy::I
    mode::M
    cpu_budget::B
    cpu_environment::CPUExecutionEnvironment
    ring_capacity::Int
end

"""
Run-local execution-clock binding used only by the armed serial hot path.

The prepared executor continues to own all mutable state and descriptor
rings; this immutable wrapper supplies the exact run timing map for owner
deadline observations.
"""
struct _ExecutionClockBoundOwnerExecutor{
    E<:PreparedExecutionOwnerExecutor,
    M<:ExecutionClockMapping,
} <: AbstractOpticalPathBatchExecutor
    executor::E
    timing::M
end

@inline _bind_optical_execution_timing(
    executor::PreparedExecutionOwnerExecutor,
    timing::ExecutionClockMapping,
) = _ExecutionClockBoundOwnerExecutor(executor, timing)

@inline _bind_optical_execution_timing(
    executor::AbstractOpticalPathBatchExecutor,
    ::ExecutionClockMapping,
) = executor

execution_owner_count(executor::PreparedExecutionOwnerExecutor) =
    length(executor.owners)

function execution_owner(
    executor::PreparedExecutionOwnerExecutor,
    ordinal::Integer,
)
    checkbounds(executor.owners, ordinal)
    return @inbounds executor.owners[Int(ordinal)]
end

execution_owner_mode(executor::PreparedExecutionOwnerExecutor) =
    executor.mode
execution_owner_idle_strategy_factory(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
) = executor.mode.idle_strategy_factory
execution_owner_idle_strategy_factory(
    ::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
) = nothing
execution_owner_scheduling(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
) = executor.mode.scheduling
execution_owner_scheduling(
    ::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
) = nothing
execution_cpu_budget(executor::PreparedExecutionOwnerExecutor) =
    executor.cpu_budget
execution_cpu_environment(executor::PreparedExecutionOwnerExecutor) =
    executor.cpu_environment
execution_owner_ring_capacity(executor::PreparedExecutionOwnerExecutor) =
    executor.ring_capacity
execution_owners_phase(executor::PreparedExecutionOwnerExecutor) =
    executor.coordinator.phase
execution_batches_completed(executor::PreparedExecutionOwnerExecutor) =
    executor.coordinator.batch_count

# Julia emits no coverage counters for these exercised constant dispatch leaves.
_is_cpu_execution_owner(::CPUBackend) = true # COV_EXCL_LINE
_is_cpu_execution_owner(::AbstractArrayBackend) = false # COV_EXCL_LINE

function _copy_uint32_memory(values)
    destination = Memory{UInt32}(undef, length(values))
    @inbounds for index in eachindex(values)
        destination[index] = UInt32(values[index])
    end
    return destination
end

function _copy_owner_memory(values::Vector{PreparedExecutionOwner})
    destination =
        Memory{PreparedExecutionOwner}(undef, length(values))
    copyto!(destination, values)
    return destination
end

function _prepared_owner(
    configuration::ExecutionOwnerConfiguration,
    id::ExecutionOwnerID,
    kind::ExecutionOwnerKind,
    target_ordinal::Int,
    group_ordinals,
    backend::AbstractArrayBackend,
    compute_device::AbstractComputeDevice,
)
    overload_policy = _execution_owner_policy(configuration, id)
    maximum_lateness_ns = overload_policy.maximum_lateness_ns
    return PreparedExecutionOwner(
        id,
        kind,
        UInt32(target_ordinal),
        _copy_uint32_memory(group_ordinals),
        backend,
        compute_device,
        overload_policy,
        _PreparedExecutionOwnerDeadline(
            maximum_lateness_ns !== nothing,
            something(maximum_lateness_ns, Int64(0)),
        ),
        SPSCDescriptorRing{_ExecutionOwnerWorkDescriptor}(
            configuration.ring_capacity),
        SPSCDescriptorRing{_ExecutionOwnerCompletion}(
            configuration.ring_capacity),
    )
end

function _prepare_execution_owner_topology(
    configuration::ExecutionOwnerConfiguration,
    prepared::PreparedPlantEventLoop,
)
    group_count = path_execution_group_count(prepared)
    group_owner_ordinals = Memory{UInt32}(undef, group_count)
    fill!(group_owner_ordinals, zero(UInt32))
    owners = PreparedExecutionOwner[]

    @inbounds for group_ordinal in 1:group_count
        iszero(group_owner_ordinals[group_ordinal]) || continue
        device_owner_ordinal =
            path_execution_group_device_batch_owner_ordinal(
                prepared, group_ordinal)
        owner_id = ExecutionOwnerID(length(owners) + 1)
        if device_owner_ordinal === nothing
            group = path_execution_group(prepared, group_ordinal)
            requirements = path_execution_group_requirements(group)
            owner = _prepared_owner(
                configuration,
                owner_id,
                PathGroupExecutionOwner,
                group_ordinal,
                (group_ordinal,),
                path_execution_backend(requirements),
                path_execution_compute_device(requirements),
            )
            push!(owners, owner)
            group_owner_ordinals[group_ordinal] =
                execution_owner_id_value(owner_id)
            continue
        end

        core_owner =
            device_path_batch_owner(prepared, device_owner_ordinal)
        member_count = device_path_batch_group_count(core_owner)
        members = Vector{Int}(undef, member_count)
        @inbounds for member_index in 1:member_count
            member = device_path_batch_group_ordinal(
                core_owner, member_index)
            iszero(group_owner_ordinals[member]) ||
                _execution_owner_error(
                    :duplicate_group_owner,
                    "path execution group $member belongs to more than " *
                    "one HIL execution owner",
                )
            members[member_index] = member
        end
        owner = _prepared_owner(
            configuration,
            owner_id,
            DeviceBatchExecutionOwner,
            device_owner_ordinal,
            members,
            device_path_batch_backend(core_owner),
            device_path_batch_compute_device(core_owner),
        )
        push!(owners, owner)
        for member in members
            group_owner_ordinals[member] =
                execution_owner_id_value(owner_id)
        end
    end

    all(!iszero, group_owner_ordinals) || _execution_owner_error(
        :unassigned_path_group,
        "every prepared path execution group must have one HIL owner",
    )
    _validate_prepared_owner_policy_overrides(
        configuration.owner_policy_overrides,
        length(owners),
    )
    for owner in owners
        policy = owner.overload_policy
        policy.recovery_occupancy < configuration.ring_capacity ||
            _execution_owner_error(
                :invalid_recovery_occupancy,
                "execution-owner recovery occupancy must be lower than each prepared descriptor-path capacity",
            )
    end
    return _copy_owner_memory(owners), group_owner_ordinals
end

function _simultaneous_cpu_owner_count(
    ::DeterministicExecutionOwners,
    count::Int,
)
    return min(count, 1)
end

function _simultaneous_cpu_owner_count(
    ::AgentExecutionOwners,
    count::Int,
)
    return count
end

function _validate_execution_owner_budget(
    configuration::ExecutionOwnerConfiguration,
    owners::Memory{PreparedExecutionOwner},
)
    cpu_owner_count = count(
        owner -> _is_cpu_execution_owner(owner.backend),
        owners,
    )
    simultaneous = _simultaneous_cpu_owner_count(
        configuration.mode, cpu_owner_count)
    simultaneous <= configuration.cpu_budget.outer_owner_count ||
        _execution_owner_error(
            :cpu_owner_capacity,
            "prepared CPU execution owners exceed the declared simultaneous owner budget",
        )
    return nothing
end

function _owner_states(count::Int)
    values = Memory{_ExecutionOwnerState}(undef, count)
    @inbounds for index in eachindex(values)
        values[index] = _ExecutionOwnerState(
            _ExecutionOwnerIdle,
            UInt64(0),
            UInt64(0),
            UInt64(0),
            UInt64(0),
            UInt64(0),
            UInt(0),
            0,
            nothing,
        )
    end
    return values
end

function _owner_overload_states(count::Int)
    values = Memory{_ExecutionOwnerOverloadState}(
        undef, count)
    @inbounds for index in eachindex(values)
        values[index] = _ExecutionOwnerOverloadState(
            UInt64(0),
            UInt64(0),
            0,
            0,
            0,
            0,
            Int64(0),
            Int64(0),
            false,
            false,
            ExecutionOwnerNoOverloadDecision,
        )
    end
    return values
end

function _owner_workspaces(count::Int)
    values = Memory{_ExecutionOwnerWorkspace}(undef, count)
    @inbounds for index in eachindex(values)
        values[index] = _ExecutionOwnerWorkspace(
            Ref{_ExecutionOwnerWorkDescriptor}())
    end
    return values
end

function _completion_scratch(count::Int)
    values = Memory{
        Base.RefValue{_ExecutionOwnerCompletion}}(undef, count)
    @inbounds for index in eachindex(values)
        values[index] = Ref{_ExecutionOwnerCompletion}()
    end
    return values
end

_runner_storage(::DeterministicExecutionOwners, ::Int) =
    Memory{Agent.AgentRunner}(undef, 0)
_runner_storage(::AgentExecutionOwners, count::Int) =
    Memory{Agent.AgentRunner}(undef, count)

@noinline function _agent_idle_strategy_factory_error(error)
    return _execution_owner_error(
        :idle_strategy_factory_failed,
        "Agent idle-strategy factory failed: $(sprint(showerror, error))",
    )
end

_checked_agent_idle_strategy_result(
    strategy::Agent.IdleStrategy,
) = strategy

function _checked_agent_idle_strategy_result(::Any)
    return _execution_owner_error(
        :invalid_idle_strategy,
        "Agent idle-strategy factory must return an Agent.IdleStrategy",
    )
end

function _checked_agent_idle_strategy(factory)
    strategy = try
        factory()
    catch error
        _agent_idle_strategy_factory_error(error)
    end
    return _checked_agent_idle_strategy_result(strategy)
end

function _new_agent_idle_strategy(
    mode::AgentExecutionOwners{I},
) where {I<:Agent.IdleStrategy}
    strategy = _checked_agent_idle_strategy(
        mode.idle_strategy_factory)
    typeof(strategy) === I || _execution_owner_error(
        :inconsistent_idle_strategy,
        "Agent idle-strategy factory changed its concrete return type after configuration",
    )
    return strategy::I
end

function _prepare_agent_idle_strategies(
    ::DeterministicExecutionOwners,
    ::Int,
)
    return nothing, Memory{Agent.IdleStrategy}(undef, 0)
end

function _prepare_agent_idle_strategies(
    mode::AgentExecutionOwners{I},
    owner_count::Int,
) where {I<:Agent.IdleStrategy}
    coordinator = _new_agent_idle_strategy(mode)
    owners = Memory{I}(undef, owner_count)
    @inbounds for owner_ordinal in eachindex(owners)
        strategy = _new_agent_idle_strategy(mode)
        if ismutabletype(I)
            strategy === coordinator && _execution_owner_error(
                :shared_idle_strategy,
                "mutable Agent idle strategies cannot be shared by " *
                "the coordinator and an owner runner",
            )
            for earlier_ordinal in 1:(owner_ordinal - 1)
                strategy === owners[earlier_ordinal] &&
                    _execution_owner_error(
                        :shared_idle_strategy,
                        "mutable Agent idle strategies cannot be shared by owner runners",
                    )
            end
        end
        owners[owner_ordinal] = strategy
    end
    return coordinator, owners
end

function _validate_prepared_owner_scheduling(
    ::SchedulerManagedExecutionOwnerScheduling,
    ::Int,
)
    return nothing
end

function _validate_prepared_owner_scheduling(
    scheduling::ThreadAssignedExecutionOwnerScheduling,
    owner_count::Int,
)
    length(scheduling.thread_ids) == owner_count ||
        _execution_owner_error(
            :owner_scheduling_cardinality,
            "assigned Julia thread-ID count must equal the prepared execution-owner count",
        )
    default_thread_count = Threads.nthreads(:default)
    owner_count <= default_thread_count ||
        _execution_owner_error(
            :coordinator_context_capacity,
            "thread-assigned execution-owner count exceeds the Julia default-pool size",
        )
    @inbounds for thread_id in scheduling.thread_ids
        1 <= thread_id <= Threads.maxthreadid() ||
            _execution_owner_error(
                :invalid_owner_thread,
                "assigned Julia thread ID is not present in this process",
            )
        Threads.threadpool(thread_id) === :default ||
            _execution_owner_error(
                :invalid_owner_thread_pool,
                "execution owners may be assigned only to Julia default-pool threads",
            )
    end
    return nothing
end

function _validate_prepared_owner_scheduling(
    mode::AgentExecutionOwners,
    owner_count::Int,
)
    return _validate_prepared_owner_scheduling(
        mode.scheduling, owner_count)
end

_validate_prepared_owner_scheduling(
    ::DeterministicExecutionOwners,
    ::Int,
) = nothing

_validate_execution_owner_coordinator_context(
    ::SchedulerManagedExecutionOwnerScheduling,
) = nothing

function _validate_execution_owner_coordinator_context(
    scheduling::ThreadAssignedExecutionOwnerScheduling,
)
    current_task().sticky || _execution_owner_error(
        :unstable_coordinator_task,
        "thread-assigned execution owners require a sticky coordinator task",
    )
    coordinator_thread_id = Threads.threadid()
    coordinator_pool = Threads.threadpool(coordinator_thread_id)
    coordinator_pool in (:default, :interactive) ||
        _execution_owner_error(
            :invalid_coordinator_thread_pool,
            "thread-assigned execution owners require the coordinator " *
            "on a Julia managed thread",
        )
    @inbounds for owner_thread_id in scheduling.thread_ids
        owner_thread_id == coordinator_thread_id &&
            _execution_owner_error(
                :coordinator_owner_thread_collision,
                "the coordinator Julia thread cannot also host an assigned execution owner",
            )
    end
    return nothing
end

mutable struct _ExecutionOwnerAgent{E}
    executor::E
    owner_ordinal::Int
    stage::RunFailureStage
    batch_sequence::UInt64
    agent_name::String
end

Agent.name(agent::_ExecutionOwnerAgent) = agent.agent_name

function _prepare_execution_owner_runners!(
    ::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
    ::Memory{Agent.IdleStrategy},
)
    return nothing
end

function _prepare_execution_owner_runners!(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
    strategies::Memory{I},
) where {I<:Agent.IdleStrategy}
    length(strategies) == length(executor.runners) ||
        _execution_owner_error(
            :idle_strategy_cardinality,
            "prepared Agent idle-strategy count does not match the execution-owner count",
        )
    @inbounds for owner_ordinal in eachindex(executor.runners)
        owner = executor.owners[owner_ordinal]
        agent = _ExecutionOwnerAgent(
            executor,
            owner_ordinal,
            OwnerCompletionPublication,
            UInt64(0),
            "execution-owner-$(execution_owner_id_value(owner.id))",
        )
        executor.runners[owner_ordinal] =
            Agent.AgentRunner(strategies[owner_ordinal], agent)
    end
    return nothing
end

function _execution_failure_owner_ids(
    owners::Memory{PreparedExecutionOwner})
    values = Memory{RunOwnerID}(undef, length(owners) + 1)
    values[1] = RunOwnerID(:serial_coordinator, 1)
    @inbounds for owner_ordinal in eachindex(owners)
        owner = owners[owner_ordinal]
        component = owner.kind == DeviceBatchExecutionOwner ?
            :device_submission_owner : :path_execution_owner
        values[owner_ordinal + 1] = RunOwnerID(
            component, execution_owner_id_value(owner.id))
    end
    return values
end

function _coordinator_only_failure_owner_ids()
    values = Memory{RunOwnerID}(undef, 1)
    values[1] = RunOwnerID(:serial_coordinator, 1)
    return values
end

function _prepare_optical_execution(
    ::SerialOpticalExecution,
    ::PreparedPlantEventLoop,
    ::PlantEventLoopState,
    ::PlantEventLoopWorkspace,
    ::RunSessionID,
    ::RunShutdownPolicy,
)
    return SerialOpticalPathBatchExecutor()
end

function _prepare_optical_execution(
    ::AbstractOpticalExecutionConfiguration,
    ::PreparedPlantEventLoop,
    ::PlantEventLoopState,
    ::PlantEventLoopWorkspace,
    ::RunSessionID,
    ::RunShutdownPolicy,
)
    return _execution_owner_error(
        :unsupported_execution_configuration,
        "optical execution configuration is not supported",
    )
end

function _prepare_optical_execution(
    configuration::ExecutionOwnerConfiguration,
    prepared::PreparedPlantEventLoop,
    state::PlantEventLoopState,
    workspace::PlantEventLoopWorkspace,
    session::RunSessionID,
    shutdown_policy::RunShutdownPolicy,
)
    owners, group_owner_ordinals =
        _prepare_execution_owner_topology(configuration, prepared)
    isempty(owners) && _execution_owner_error(
        :empty_owner_topology,
        "an owner executor requires at least one prepared path group",
    )
    _validate_execution_owner_budget(configuration, owners)
    owner_count = length(owners)
    _validate_prepared_owner_scheduling(
        configuration.mode, owner_count)
    coordinator_idle_strategy, owner_idle_strategies =
        _prepare_agent_idle_strategies(
            configuration.mode, owner_count)
    submitted = Memory{UInt64}(undef, owner_count)
    completions = Memory{UInt64}(undef, owner_count)
    startup = Memory{Bool}(undef, owner_count)
    stopped = Memory{Bool}(undef, owner_count)
    fill!(submitted, UInt64(0))
    fill!(completions, UInt64(0))
    fill!(startup, false)
    fill!(stopped, false)
    due_owner_ordinals = Memory{UInt32}(undef, owner_count)
    owner_due = Memory{Bool}(undef, owner_count)
    completion_seen = Memory{Bool}(undef, owner_count)
    fill!(owner_due, false)
    fill!(completion_seen, false)
    failures = _prepare_run_failure_coordinator(
        session,
        shutdown_policy,
        _execution_failure_owner_ids(owners))
    executor = PreparedExecutionOwnerExecutor(
        session,
        prepared,
        state,
        workspace,
        owners,
        group_owner_ordinals,
        _owner_states(owner_count),
        _owner_overload_states(owner_count),
        _owner_workspaces(owner_count),
        _ExecutionCoordinatorState(
            ExecutionOwnersPrepared,
            UInt64(0),
            UInt64(0),
            nothing,
            submitted,
            completions,
            startup,
            stopped,
        ),
        _ExecutionCoordinatorWorkspace(
            due_owner_ordinals,
            owner_due,
            completion_seen,
            _completion_scratch(owner_count),
        ),
        failures,
        _runner_storage(configuration.mode, owner_count),
        coordinator_idle_strategy,
        configuration.mode,
        configuration.cpu_budget,
        configuration.cpu_environment,
        configuration.ring_capacity,
    )
    _prepare_execution_owner_runners!(
        executor, owner_idle_strategies)
    return executor
end

function _execution_failure_coordinator(
    ::SerialOpticalPathBatchExecutor,
    session::RunSessionID,
    policy::RunShutdownPolicy)
    return _prepare_run_failure_coordinator(
        session, policy, _coordinator_only_failure_owner_ids())
end

function _execution_failure_coordinator(
    executor::PreparedExecutionOwnerExecutor,
    ::RunSessionID,
    ::RunShutdownPolicy)
    return executor.failures
end

function _execution_failure_coordinator(
    ::AbstractOpticalPathBatchExecutor,
    session::RunSessionID,
    policy::RunShutdownPolicy)
    return _prepare_run_failure_coordinator(
        session, policy, _coordinator_only_failure_owner_ids())
end

# Julia emits no coverage counters for these exercised constant dispatch leaves.
_execution_is_armed(::SerialOpticalPathBatchExecutor) = true # COV_EXCL_LINE
_execution_is_quiescent(::SerialOpticalPathBatchExecutor) = true # COV_EXCL_LINE
_execution_ownership_is_drained( # COV_EXCL_LINE
    ::SerialOpticalPathBatchExecutor) = true
_arm_optical_execution!(executor::SerialOpticalPathBatchExecutor) = executor
_start_optical_execution!(executor::SerialOpticalPathBatchExecutor) = executor
_stop_optical_execution!(executor::SerialOpticalPathBatchExecutor) = executor
_begin_optical_execution_shutdown!(
    executor::SerialOpticalPathBatchExecutor) = executor
_progress_optical_execution_shutdown!( # COV_EXCL_LINE
    ::SerialOpticalPathBatchExecutor) = true
_finalize_optical_execution_shutdown!(
    executor::SerialOpticalPathBatchExecutor) = executor
_mark_optical_execution_failed!(
    executor::SerialOpticalPathBatchExecutor) = executor

_begin_optical_execution_shutdown!(
    executor::AbstractOpticalPathBatchExecutor) = executor
_progress_optical_execution_shutdown!( # COV_EXCL_LINE
    ::AbstractOpticalPathBatchExecutor) = true
_finalize_optical_execution_shutdown!(
    executor::AbstractOpticalPathBatchExecutor) =
    _stop_optical_execution!(executor)
_execution_ownership_is_drained(
    executor::AbstractOpticalPathBatchExecutor) =
    _execution_is_quiescent(executor)

@noinline function _wait_for_owner_progress(
    ::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
    ::UInt32,
    reason::Symbol,
    message::AbstractString,
)
    return _execution_owner_error(reason, message)
end

@inline function _wait_for_owner_progress(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
    poll_count::UInt32,
    ::Symbol,
    ::AbstractString,
)
    Agent.idle(executor.coordinator_idle_strategy, 0)
    GC.safepoint()
    return zero(poll_count)
end

@inline function _reset_coordinator_idle!(
    ::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
)
    return nothing
end

@inline function _reset_coordinator_idle!(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
)
    Agent.idle(executor.coordinator_idle_strategy, 1)
    return nothing
end

function _submit_completion!(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
    owner::PreparedExecutionOwner,
    completion::_ExecutionOwnerCompletion,
)
    while true
        status = try_submit!(owner.completion, completion)
        status == RingTransferSucceeded && return nothing
        status == RingFull || _execution_owner_error(
            :completion_publication,
            "execution owner could not publish a completion acknowledgement",
        )
        GC.safepoint()
        yield()
    end
end

function _submit_completion!(
    ::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
    owner::PreparedExecutionOwner,
    completion::_ExecutionOwnerCompletion,
)
    try_submit!(owner.completion, completion) ==
        RingTransferSucceeded || _execution_owner_error(
            :completion_publication,
            "deterministic execution owner could not publish a completion acknowledgement",
        )
    return nothing
end

function _execute_owner_target!(
    executor::PreparedExecutionOwnerExecutor,
    owner::PreparedExecutionOwner,
    descriptor::_ExecutionOwnerWorkDescriptor,
)
    descriptor.session == executor.session || _execution_owner_error(
        :stale_session,
        "execution-owner work belongs to another run/session",
    )
    descriptor.owner == owner.id || _execution_owner_error(
        :wrong_owner,
        "execution-owner work was delivered to another owner",
    )
    if owner.kind == PathGroupExecutionOwner
        ordinal = Int(owner.target_ordinal)
        if descriptor.phase == _ExecutionOwnerMaterialization
            materialize_path_execution_group!(
                executor.prepared,
                executor.state,
                executor.workspace,
                descriptor.claim,
                ordinal,
            )
        else
            descriptor.phase == _ExecutionOwnerExecution ||
                _execution_owner_error(
                    :invalid_work_phase,
                    "path-group owner received a non-execution work phase",
                )
            execute_path_execution_group!(
                executor.prepared,
                executor.state,
                executor.workspace,
                descriptor.claim,
                ordinal,
            )
        end
        return nothing
    end

    owner.kind == DeviceBatchExecutionOwner ||
        _execution_owner_error(
            :invalid_owner_kind,
            "execution owner has an unknown target kind",
        )
    core_owner = device_path_batch_owner(
        executor.prepared, Int(owner.target_ordinal))
    if descriptor.phase == _ExecutionOwnerMaterialization
        materialize_device_path_batch!(
            core_owner,
            executor.prepared,
            executor.state,
            executor.workspace,
            descriptor.claim,
        )
    else
        descriptor.phase == _ExecutionOwnerExecution ||
            _execution_owner_error(
                :invalid_work_phase,
                "device-batch owner received a non-execution work phase",
            )
        execute_device_path_batch!(
            core_owner,
            executor.prepared,
            executor.state,
            executor.workspace,
            descriptor.claim,
        )
    end
    return nothing
end

@inline function _execution_owner_failure_kind(
    owner::PreparedExecutionOwner)
    return _is_cpu_execution_owner(owner.backend) ?
        OwnerExceptionRunFailure : DeviceRunFailure
end

@inline function _execution_owner_failure_stage(
    owner::PreparedExecutionOwner,
    descriptor::_ExecutionOwnerWorkDescriptor)
    descriptor.phase == _ExecutionOwnerMaterialization &&
        return OwnerMaterialization
    return owner.kind == DeviceBatchExecutionOwner ?
        OwnerDeviceCompletion : OwnerExecution
end

@inline _execution_owner_failure_reason(error) =
    nameof(typeof(error))
@inline _execution_owner_failure_reason(error::ExecutionOwnerError) =
    error.reason

@inline function _publish_execution_owner_failure!(
    executor::PreparedExecutionOwnerExecutor,
    owner_ordinal::Int,
    stage,
    error,
    work_sequence::UInt64)
    owner = @inbounds executor.owners[owner_ordinal]
    return _publish_run_failure!(
        executor.failures,
        owner_ordinal + 1,
        _execution_owner_failure_kind(owner),
        stage,
        nothing,
        :execution_owner,
        _execution_owner_failure_reason(error);
        work_sequence)
end

function _service_owner_work!(
    executor::PreparedExecutionOwnerExecutor,
    owner_ordinal::Int,
    descriptor::_ExecutionOwnerWorkDescriptor,
)
    owner = @inbounds executor.owners[owner_ordinal]
    state = @inbounds executor.owner_states[owner_ordinal]
    state.activity == _ExecutionOwnerIdle ||
        _execution_owner_error(
            :owner_not_idle,
            "execution owner received work while it was not idle",
        )
    state.activity = _ExecutionOwnerWorking
    state.active_batch_sequence = descriptor.batch_sequence
    state.work_taken += UInt64(1)
    state.last_thread_id = Threads.threadid()
    failed = false
    failure = try
        _execute_owner_target!(executor, owner, descriptor)
        nothing
    catch caught
        failed = true
        caught
    end
    if !failed
        state.work_completed += UInt64(1)
        state.active_batch_sequence = UInt64(0)
        state.activity = _ExecutionOwnerIdle
        status = _ExecutionOwnerWorkCompleted
    else
        state.failure = failure
        _publish_execution_owner_failure!(
            executor,
            owner_ordinal,
            _execution_owner_failure_stage(owner, descriptor),
            failure,
            descriptor.batch_sequence)
        state.work_failed += UInt64(1)
        state.active_batch_sequence = UInt64(0)
        state.activity = _ExecutionOwnerFailedActivity
        status = _ExecutionOwnerWorkFailed
    end
    try
        _submit_completion!(
            executor,
            owner,
            _ExecutionOwnerCompletion(
                executor.session,
                owner.id,
                descriptor.batch_sequence,
                descriptor.phase,
                status,
            ),
        )
    catch error
        state.failure = error
        state.activity = _ExecutionOwnerFailedActivity
        _publish_execution_owner_failure!(
            executor,
            owner_ordinal,
            OwnerCompletionPublication,
            error,
            descriptor.batch_sequence)
        rethrow()
    end
    return nothing
end

function _drain_cancelled_owner_work!(
    executor::PreparedExecutionOwnerExecutor,
    owner_ordinal::Int)
    owner = @inbounds executor.owners[owner_ordinal]
    state = @inbounds executor.owner_states[owner_ordinal]
    workspace = @inbounds executor.owner_workspaces[owner_ordinal]
    while true
        status = try_take!(workspace.work, owner.due)
        status == RingTransferSucceeded || begin
            status in (RingEmpty, RingClosed) ||
                _execution_owner_error(
                    :due_work_consumption,
                    "execution owner observed an invalid due-work ring result while stopping",
                )
            return nothing
        end
        state.work_cancelled += UInt64(1)
    end
end

function _finish_execution_owner!(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
    owner_ordinal::Int)
    owner = @inbounds executor.owners[owner_ordinal]
    state = @inbounds executor.owner_states[owner_ordinal]
    failed = state.activity == _ExecutionOwnerFailedActivity
    if !failed
        state.activity = _ExecutionOwnerStoppedActivity
        state.active_batch_sequence = UInt64(0)
    end
    try
        _submit_completion!(
            executor,
            owner,
            _ExecutionOwnerCompletion(
                executor.session,
                owner.id,
                UInt64(0),
                _ExecutionOwnerStop,
                failed ? _ExecutionOwnerWorkFailed :
                    _ExecutionOwnerWorkCompleted,
            ),
        )
        close_ring!(owner.completion) == RingTransferSucceeded ||
            _execution_owner_error(
                :completion_closure,
                "execution owner could not close its completion path",
            )
    catch error
        state.failure = error
        state.activity = _ExecutionOwnerFailedActivity
        _publish_execution_owner_failure!(
            executor,
            owner_ordinal,
            OwnerCompletionPublication,
            error,
            UInt64(0))
        close_ring!(owner.completion)
    end
    if failed || state.activity == _ExecutionOwnerFailedActivity
        _acknowledge_run_stop!(
            executor.failures, owner_ordinal + 1, UInt64(1))
    else
        _acknowledge_run_stop!(
            executor.failures, owner_ordinal + 1)
    end
    return nothing
end

function Agent.on_start(agent::_ExecutionOwnerAgent)
    executor = agent.executor
    owner_ordinal = agent.owner_ordinal
    owner = @inbounds executor.owners[owner_ordinal]
    state = @inbounds executor.owner_states[owner_ordinal]
    state.task_id = objectid(current_task())
    state.last_thread_id = Threads.threadid()
    agent.stage = OwnerCompletionPublication
    agent.batch_sequence = UInt64(0)
    _submit_completion!(
        executor,
        owner,
        _ExecutionOwnerCompletion(
            executor.session,
            owner.id,
            UInt64(0),
            _ExecutionOwnerStartup,
            _ExecutionOwnerWorkCompleted,
        ),
    )
    agent.stage = OwnerBeforeDequeue
    return nothing
end

function Agent.do_work(agent::_ExecutionOwnerAgent)
    executor = agent.executor
    owner_ordinal = agent.owner_ordinal
    owner = @inbounds executor.owners[owner_ordinal]
    state = @inbounds executor.owner_states[owner_ordinal]
    workspace = @inbounds executor.owner_workspaces[owner_ordinal]
    if _run_shutdown_requested(executor.failures)
        _drain_cancelled_owner_work!(executor, owner_ordinal)
        throw(Agent.AgentTerminationException())
    end
    agent.stage = OwnerBeforeDequeue
    status = try_take!(workspace.work, owner.due)
    if status == RingTransferSucceeded
        descriptor = workspace.work[]
        agent.batch_sequence = descriptor.batch_sequence
        agent.stage = OwnerAfterDequeue
        if _run_shutdown_requested(executor.failures)
            # COV_EXCL_START
            # The cancellation operation is directly tested. Entering this
            # branch requires the stop epoch to publish in the unforceable
            # interval between one SPSC take and this immediately following
            # acquire observation.
            state.work_cancelled += UInt64(1)
            _drain_cancelled_owner_work!(executor, owner_ordinal)
            throw(Agent.AgentTerminationException())
            # COV_EXCL_STOP
        end
        _service_owner_work!(
            executor, owner_ordinal, descriptor)
        state.activity == _ExecutionOwnerFailedActivity &&
            throw(Agent.AgentTerminationException())
        agent.stage = OwnerBeforeDequeue
        agent.batch_sequence = UInt64(0)
        return 1
    end
    status == RingClosed &&
        throw(Agent.AgentTerminationException())
    status == RingEmpty || _execution_owner_error(
        :due_work_consumption,
        "execution owner observed an invalid due-work ring result",
    )
    return 0
end

Agent.on_error(
    ::_ExecutionOwnerAgent,
    error::Agent.AgentTerminationException,
) = throw(error)

function Agent.on_error(agent::_ExecutionOwnerAgent, error)
    executor = agent.executor
    owner_ordinal = agent.owner_ordinal
    state = @inbounds executor.owner_states[owner_ordinal]
    if state.activity != _ExecutionOwnerFailedActivity
        state.failure = error
        state.active_batch_sequence = UInt64(0)
        state.activity = _ExecutionOwnerFailedActivity
        _publish_execution_owner_failure!(
            executor,
            owner_ordinal,
            agent.stage,
            error,
            agent.batch_sequence)
    end
    throw(Agent.AgentTerminationException(
        "AdaptiveOpticsHIL execution owner failed"))
end

function Agent.on_close(agent::_ExecutionOwnerAgent)
    _finish_execution_owner!(
        agent.executor, agent.owner_ordinal)
    return nothing
end

function _start_execution_owner_runner(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
    owner_ordinal::Int,
)
    runner = @inbounds executor.runners[owner_ordinal]
    return _start_execution_owner_runner(
        runner, executor.mode.scheduling, owner_ordinal)
end

function _start_execution_owner_runner(
    runner::Agent.AgentRunner,
    ::SchedulerManagedExecutionOwnerScheduling,
    ::Int,
)
    Agent.start(runner)
    return runner
end

function _start_execution_owner_runner(
    runner::Agent.AgentRunner,
    scheduling::ThreadAssignedExecutionOwnerScheduling,
    owner_ordinal::Int,
)
    thread_id = @inbounds scheduling.thread_ids[owner_ordinal]
    if scheduling.cpu_ids === nothing
        Agent.start_on_thread(runner, thread_id)
    else
        cpu_id = @inbounds scheduling.cpu_ids[owner_ordinal]
        Agent.start_on_thread(runner, thread_id; cpuid=cpu_id)
    end
    return runner
end

function _take_expected_completion!(
    executor::PreparedExecutionOwnerExecutor,
    owner_ordinal::Int,
    batch_sequence::UInt64,
    phase::_ExecutionOwnerWorkPhase,
)
    owner = @inbounds executor.owners[owner_ordinal]
    scratch = @inbounds executor.coordinator_workspace.completions[
        owner_ordinal]
    poll_count = zero(UInt32)
    while true
        status = try_take!(scratch, owner.completion)
        if status == RingTransferSucceeded
            _reset_coordinator_idle!(executor)
            completion = scratch[]
            completion.session == executor.session ||
                _execution_owner_error(
                    :stale_completion_session,
                    "execution-owner completion belongs to another run/session",
                )
            completion.owner == owner.id ||
                _execution_owner_error(
                    :wrong_completion_owner,
                    "execution-owner completion came from another owner",
                )
            completion.batch_sequence == batch_sequence ||
                _execution_owner_error(
                    :stale_completion_batch,
                    "execution-owner completion belongs to another batch",
                )
            completion.phase == phase ||
                _execution_owner_error(
                    :wrong_completion_phase,
                    "execution-owner completion reports another phase",
                )
            return completion
        end
        status == RingClosed && _execution_owner_error(
            :completion_closed,
            "execution-owner completion path closed before its expected acknowledgement",
        )
        status == RingEmpty ||
            _execution_owner_error(
                :completion_consumption,
                "coordinator observed an invalid completion-ring result",
            )
        poll_count = _wait_for_owner_progress(
            executor,
            poll_count,
            :missing_deterministic_completion,
            "deterministic owner did not publish its completion",
        )
    end
end

function _collect_lifecycle_acknowledgements!(
    executor::PreparedExecutionOwnerExecutor,
    phase::_ExecutionOwnerWorkPhase,
    destination::Memory{Bool},
)
    @inbounds for owner_ordinal in eachindex(executor.owners)
        completion = _take_expected_completion!(
            executor, owner_ordinal, UInt64(0), phase)
        completion.status == _ExecutionOwnerWorkCompleted ||
            _execution_owner_error(
                :owner_lifecycle_failure,
                "execution owner failed during lifecycle acknowledgement",
            )
        destination[owner_ordinal] = true
    end
    return nothing
end

function _arm_optical_execution!(
    executor::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
)
    executor.coordinator.phase == ExecutionOwnersPrepared ||
        _execution_owner_error(
            :invalid_phase,
            "deterministic execution owners can arm only from prepared",
        )
    executor.coordinator.phase = ExecutionOwnersArmed
    return executor
end

function _arm_optical_execution!(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
)
    executor.coordinator.phase == ExecutionOwnersPrepared ||
        _execution_owner_error(
            :invalid_phase,
            "Agent execution owners can arm only from prepared",
        )
    _validate_execution_owner_coordinator_context(
        executor.mode.scheduling)
    @inbounds for owner_ordinal in eachindex(executor.owners)
        _start_execution_owner_runner(
            executor, owner_ordinal)
    end
    _collect_lifecycle_acknowledgements!(
        executor,
        _ExecutionOwnerStartup,
        executor.coordinator.startup_acknowledged,
    )
    executor.coordinator.phase = ExecutionOwnersArmed
    return executor
end

_execution_is_armed(executor::PreparedExecutionOwnerExecutor) =
    executor.coordinator.phase == ExecutionOwnersArmed

function _start_optical_execution!(
    executor::PreparedExecutionOwnerExecutor,
)
    executor.coordinator.phase == ExecutionOwnersArmed ||
        _execution_owner_error(
            :invalid_phase,
            "execution owners can start only from armed",
        )
    executor.coordinator.phase = ExecutionOwnersRunning
    return executor
end

function _mark_optical_execution_failed!(
    executor::PreparedExecutionOwnerExecutor,
)
    executor.coordinator.phase in (
        ExecutionOwnersPrepared,
        ExecutionOwnersArmed,
        ExecutionOwnersRunning,
    ) || return executor
    executor.coordinator.phase = ExecutionOwnersFailed
    return executor
end

function _close_execution_owner_inputs!(
    executor::PreparedExecutionOwnerExecutor)
    @inbounds for owner in executor.owners
        status = close_ring!(owner.due)
        status in (RingTransferSucceeded, RingClosed) ||
            _execution_owner_error(
                :due_work_closure,
                "execution owner could not close its due-work path",
            )
    end
    return executor
end

function _begin_deterministic_execution_shutdown!(
    executor::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
)
    @inbounds for owner_ordinal in eachindex(executor.owners)
        owner = executor.owners[owner_ordinal]
        state = executor.owner_states[owner_ordinal]
        _drain_cancelled_owner_work!(executor, owner_ordinal)
        failed = state.activity == _ExecutionOwnerFailedActivity
        if !failed
            state.activity = _ExecutionOwnerStoppedActivity
            state.active_batch_sequence = UInt64(0)
        end
        _submit_completion!(
            executor,
            owner,
            _ExecutionOwnerCompletion(
                executor.session,
                owner.id,
                UInt64(0),
                _ExecutionOwnerStop,
                failed ? _ExecutionOwnerWorkFailed :
                    _ExecutionOwnerWorkCompleted,
            ),
        )
        close_ring!(owner.completion) == RingTransferSucceeded ||
            _execution_owner_error(
                :completion_closure,
                "deterministic owner could not close its completion path",
            )
        _acknowledge_run_stop!(
            executor.failures, owner_ordinal + 1)
    end
    return executor
end

_begin_execution_owner_mode_shutdown!(
    executor::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
) = _begin_deterministic_execution_shutdown!(executor)

_begin_execution_owner_mode_shutdown!(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
) = begin
    @inbounds for runner in executor.runners
        Agent.is_started(runner) || close(runner)
    end
    executor
end

function _begin_optical_execution_shutdown!(
    executor::PreparedExecutionOwnerExecutor,
)
    executor.coordinator.phase in (
        ExecutionOwnersPrepared,
        ExecutionOwnersArmed,
        ExecutionOwnersRunning,
        ExecutionOwnersFailed,
    ) || _execution_owner_error(
        :invalid_phase,
        "execution owners can begin shutdown only from prepared, armed, running, or failed",
    )
    _close_execution_owner_inputs!(executor)
    _begin_execution_owner_mode_shutdown!(executor)
    return executor
end

function _drain_execution_owner_completions!(
    executor::PreparedExecutionOwnerExecutor,
    owner_ordinal::Int)
    owner = @inbounds executor.owners[owner_ordinal]
    scratch = @inbounds executor.coordinator_workspace.completions[
        owner_ordinal]
    while true
        status = try_take!(scratch, owner.completion)
        status == RingTransferSucceeded || begin
            status in (RingEmpty, RingClosed) ||
                _execution_owner_error(
                    :completion_consumption,
                    "shutdown observed an invalid owner-completion result",
                )
            return nothing
        end
        completion = scratch[]
        completion.session == executor.session ||
            _execution_owner_error(
                :stale_completion_session,
                "shutdown observed an owner completion from another run/session",
            )
        completion.owner == owner.id ||
            _execution_owner_error(
                :wrong_completion_owner,
                "shutdown observed a completion from another owner",
            )
        if completion.phase == _ExecutionOwnerStop
            executor.coordinator.stop_acknowledged[owner_ordinal] = true
        else
            executor.coordinator.completions[owner_ordinal] += UInt64(1)
        end
    end
end

@inline _execution_owner_task_done( # COV_EXCL_LINE
    ::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
    ::Int) = true

@inline function _execution_owner_task_done(
    executor::PreparedExecutionOwnerExecutor{
        <:AgentExecutionOwners,
    },
    owner_ordinal::Int)
    isassigned(executor.runners, owner_ordinal) || return false
    return Agent.is_closed(@inbounds executor.runners[owner_ordinal])
end

function _progress_optical_execution_shutdown!(
    executor::PreparedExecutionOwnerExecutor)
    complete = true
    @inbounds for owner_ordinal in eachindex(executor.owners)
        _drain_execution_owner_completions!(
            executor, owner_ordinal)
        owner = executor.owners[owner_ordinal]
        due = ring_accounting(owner.due)
        completion = ring_accounting(owner.completion)
        complete &= iszero(due.occupancy)
        complete &= iszero(completion.occupancy)
        complete &= _run_owner_stop_acknowledged(
            executor.failures, owner_ordinal + 1)
        complete &= _execution_owner_task_done(
            executor, owner_ordinal)
    end
    return complete
end

function _finalize_optical_execution_shutdown!(
    executor::PreparedExecutionOwnerExecutor)
    _progress_optical_execution_shutdown!(executor) ||
        _execution_owner_error(
            :shutdown_not_drained,
            "execution-owner shutdown cannot finalize before every acknowledgement and handoff drains",
        )
    failed = false
    @inbounds for state in executor.owner_states
        failed |= state.activity == _ExecutionOwnerFailedActivity
    end
    executor.coordinator.phase = failed ||
        executor.coordinator.phase == ExecutionOwnersFailed ?
        ExecutionOwnersFailed : ExecutionOwnersStopped
    return executor
end

function _stop_optical_execution!(
    executor::PreparedExecutionOwnerExecutor)
    _begin_run_shutdown!(executor.failures, Int64(0))
    _begin_optical_execution_shutdown!(executor)
    while !_progress_optical_execution_shutdown!(executor)
        yield()
    end
    return _finalize_optical_execution_shutdown!(executor)
end

function _execution_is_quiescent(
    executor::PreparedExecutionOwnerExecutor,
)
    return execution_owners_are_quiescent(executor)
end

"""Cold, externally synchronized accounting for one execution owner."""
struct ExecutionOwnerAccounting
    id::ExecutionOwnerID
    overload_policy::ExecutionOwnerOverloadPolicy
    due::RingAccounting
    completion::RingAccounting
    work_submitted::UInt64
    work_taken::UInt64
    active_batch_sequence::UInt64
    work_completed::UInt64
    work_failed::UInt64
    work_cancelled::UInt64
    completions_taken::UInt64
    startup_acknowledged::Bool
    stop_acknowledged::Bool
    task_id::UInt
    last_thread_id::Int
    failed::Bool
    overload_episodes::UInt64
    recovery_count::UInt64
    current_due_occupancy::Int
    maximum_due_occupancy::Int
    current_completion_occupancy::Int
    maximum_completion_occupancy::Int
    latest_lateness_ns::Int64
    maximum_lateness_ns::Int64
    overloaded::Bool
    recovered_to_threshold::Bool
    overload_decision::ExecutionOwnerOverloadDecision
end

function execution_owner_accounting(
    executor::PreparedExecutionOwnerExecutor,
    ordinal::Integer,
)
    checkbounds(executor.owners, ordinal)
    index = Int(ordinal)
    owner = @inbounds executor.owners[index]
    state = @inbounds executor.owner_states[index]
    overload = @inbounds executor.owner_overload_states[index]
    coordinator = executor.coordinator
    due = ring_accounting(owner.due)
    completion = ring_accounting(owner.completion)
    return ExecutionOwnerAccounting(
        owner.id,
        owner.overload_policy,
        due,
        completion,
        @inbounds(coordinator.submitted[index]),
        state.work_taken,
        state.active_batch_sequence,
        state.work_completed,
        state.work_failed,
        state.work_cancelled,
        @inbounds(coordinator.completions[index]),
        @inbounds(coordinator.startup_acknowledged[index]),
        @inbounds(coordinator.stop_acknowledged[index]),
        state.task_id,
        state.last_thread_id,
        state.activity == _ExecutionOwnerFailedActivity,
        overload.overload_episodes,
        overload.recovery_count,
        due.occupancy,
        overload.maximum_due_occupancy,
        completion.occupancy,
        overload.maximum_completion_occupancy,
        overload.latest_lateness_ns,
        overload.maximum_lateness_ns,
        overload.overloaded,
        overload.recovered_to_threshold,
        overload.decision,
    )
end

_execution_accounting(::SerialOpticalPathBatchExecutor) = nothing

function _execution_accounting(
    executor::PreparedExecutionOwnerExecutor,
)
    values = Memory{ExecutionOwnerAccounting}(
        undef, execution_owner_count(executor))
    @inbounds for ordinal in eachindex(values)
        values[ordinal] =
            execution_owner_accounting(executor, ordinal)
    end
    return values
end

# Julia emits no coverage counter for this exercised constant dispatch leaf.
_execution_accounting_is_quiescent(::Nothing) = true # COV_EXCL_LINE

function _execution_accounting_is_quiescent(
    values::Memory{ExecutionOwnerAccounting},
)
    @inbounds for value in values
        iszero(value.due.occupancy) || return false
        iszero(value.completion.occupancy) || return false
        value.work_submitted == value.work_taken ==
            value.work_completed == value.completions_taken ||
            return false
        value.failed && return false
    end
    return true
end

function execution_owners_are_quiescent(
    executor::PreparedExecutionOwnerExecutor,
)
    @inbounds for index in eachindex(executor.owners)
        owner = executor.owners[index]
        due = ring_accounting(owner.due)
        completion = ring_accounting(owner.completion)
        iszero(due.occupancy) || return false
        iszero(completion.occupancy) || return false
        state = executor.owner_states[index]
        state.activity in (
            _ExecutionOwnerIdle,
            _ExecutionOwnerStoppedActivity,
        ) || return false
        iszero(state.active_batch_sequence) || return false
        state.work_taken == state.work_completed || return false
        executor.coordinator.submitted[index] ==
            executor.coordinator.completions[index] || return false
    end
    return true
end

function _execution_ownership_is_drained(
    executor::PreparedExecutionOwnerExecutor)
    @inbounds for index in eachindex(executor.owners)
        owner = executor.owners[index]
        due = ring_accounting(owner.due)
        completion = ring_accounting(owner.completion)
        iszero(due.occupancy) || return false
        iszero(completion.occupancy) || return false
        state = executor.owner_states[index]
        iszero(state.active_batch_sequence) || return false
        state.work_taken ==
            state.work_completed + state.work_failed ||
            return false
        executor.coordinator.submitted[index] ==
            state.work_taken + state.work_cancelled ||
            return false
        executor.coordinator.completions[index] ==
            state.work_completed + state.work_failed ||
            return false
    end
    return true
end

function _execution_completions_are_observed(
    executor::PreparedExecutionOwnerExecutor)
    @inbounds for index in eachindex(executor.owners)
        executor.coordinator.submitted[index] ==
            executor.coordinator.completions[index] ||
            return false
    end
    return true
end

function _execution_owner_stops_are_acknowledged(
    executor::PreparedExecutionOwnerExecutor)
    @inbounds for owner_ordinal in eachindex(executor.owners)
        _run_owner_stop_acknowledged(
            executor.failures, owner_ordinal + 1) ||
            return false
    end
    return true
end

@inline _execution_batch_active( # COV_EXCL_LINE
    ::AbstractOpticalPathBatchExecutor) = false
@inline _execution_batch_active(
    executor::PreparedExecutionOwnerExecutor) =
    executor.coordinator.active_claim !== nothing

@inline _abandon_failed_optical_path_batch!( # COV_EXCL_LINE
    ::AbstractOpticalPathBatchExecutor) = true

function _abandon_failed_optical_path_batch!(
    executor::PreparedExecutionOwnerExecutor)
    claim = executor.coordinator.active_claim
    claim === nothing && return true
    (
        _execution_completions_are_observed(executor) ||
        _execution_owner_stops_are_acknowledged(executor)
    ) || return false
    _execution_ownership_is_drained(executor) || return false
    abandon_optical_path_batch!(
        executor.prepared,
        executor.state,
        executor.workspace,
        claim,
    )
    executor.coordinator.active_claim = nothing
    return true
end

function _require_executor_binding(
    executor::PreparedExecutionOwnerExecutor,
    prepared::PreparedPlantEventLoop,
    state::PlantEventLoopState,
    workspace::PlantEventLoopWorkspace,
)
    prepared === executor.prepared || _execution_owner_error(
        :foreign_prepared_plant,
        "execution-owner executor received another prepared event loop",
    )
    state === executor.state || _execution_owner_error(
        :foreign_state_owner,
        "execution-owner executor received another event-loop state",
    )
    workspace === executor.workspace || _execution_owner_error(
        :foreign_workspace_owner,
        "execution-owner executor received another event-loop workspace",
    )
    executor.coordinator.phase == ExecutionOwnersRunning ||
        _execution_owner_error(
            :invalid_phase,
            "execution-owner batch work requires a running owner runtime",
        )
    return nothing
end

function _next_batch_sequence!(executor::PreparedExecutionOwnerExecutor)
    current = executor.coordinator.batch_sequence
    current == typemax(UInt64) && _execution_owner_error(
        :batch_sequence_overflow,
        "execution-owner batch sequence exhausted UInt64",
    )
    next = current + UInt64(1)
    executor.coordinator.batch_sequence = next
    return next
end

function _collect_due_execution_owners!(
    executor::PreparedExecutionOwnerExecutor,
    claim::OpticalPathBatchClaim,
)
    scratch = executor.coordinator_workspace
    fill!(scratch.owner_due, false)
    due_count = optical_path_batch_due_group_count(
        executor.prepared,
        executor.state,
        executor.workspace,
        claim,
    )
    owner_count = 0
    @inbounds for index in 1:due_count
        group_ordinal = optical_path_batch_due_group_ordinal(
            executor.prepared,
            executor.state,
            executor.workspace,
            claim,
            index,
        )
        owner_ordinal = Int(
            executor.group_owner_ordinals[group_ordinal])
        scratch.owner_due[owner_ordinal] && continue
        scratch.owner_due[owner_ordinal] = true
        owner_count += 1
        scratch.due_owner_ordinals[owner_count] =
            UInt32(owner_ordinal)
    end
    return owner_count
end

@inline function _record_owner_due_submission!(
    overload::_ExecutionOwnerOverloadState,
)
    overload.current_due_occupancy += 1
    overload.maximum_due_occupancy = max(
        overload.maximum_due_occupancy,
        overload.current_due_occupancy,
    )
    return nothing
end

@inline function _record_owner_completion_consumption!(
    overload::_ExecutionOwnerOverloadState,
    owner::PreparedExecutionOwner,
)
    overload.maximum_completion_occupancy = max(
        overload.maximum_completion_occupancy,
        overload.current_completion_occupancy + 1,
    )
    overload.current_due_occupancy =
        ring_accounting(owner.due).occupancy
    overload.current_completion_occupancy =
        ring_accounting(owner.completion).occupancy
    return nothing
end

@inline function _mark_execution_owner_overload!(
    overload::_ExecutionOwnerOverloadState,
    decision::ExecutionOwnerOverloadDecision,
)
    if !overload.overloaded
        overload.overload_episodes += UInt64(1)
    end
    overload.overloaded = true
    overload.recovered_to_threshold = false
    overload.decision = decision
    return nothing
end

@noinline function _fail_execution_owner_overload!(
    ::FailRunOnOwnerOverload,
    owner::PreparedExecutionOwner,
    reason::Symbol,
    message::AbstractString,
)
    _execution_owner_error(
        reason,
        "execution owner $(execution_owner_id_value(owner.id)) $message",
    )
end

@inline function _record_execution_owner_lateness!(
    overload::_ExecutionOwnerOverloadState,
    lateness_ns::Int64,
)
    nonnegative = max(Int64(0), lateness_ns)
    overload.latest_lateness_ns = nonnegative
    overload.maximum_lateness_ns = max(
        overload.maximum_lateness_ns, nonnegative)
    return nonnegative
end

@inline function _observe_execution_owner_deadline!(
    executor::PreparedExecutionOwnerExecutor,
    owner_ordinal::Int,
    timing::ExecutionClockMapping,
    timestamp::PlantTimestamp,
)
    deadline =
        @inbounds executor.owners[owner_ordinal].deadline
    deadline.enabled || return false
    overload =
        @inbounds executor.owner_overload_states[owner_ordinal]
    maximum_lateness_ns =
        deadline.maximum_lateness_ns
    observed_execution_ns =
        _read_execution_clock(execution_clock(timing))
    lateness_ns = _record_execution_owner_lateness!(
        overload,
        execution_lateness_ns(
            timing, timestamp, observed_execution_ns),
    )
    lateness_ns <= maximum_lateness_ns && return false
    _mark_execution_owner_overload!(
        overload, ExecutionOwnerFailedForDeadline)
    return true
end

@inline _observe_execution_owner_deadline!(
    ::PreparedExecutionOwnerExecutor,
    ::Int,
    ::Nothing,
    ::PlantTimestamp,
) = false

@noinline function _fail_execution_owner_deadline!(
    executor::PreparedExecutionOwnerExecutor,
    owner_ordinal::Int,
)
    owner = @inbounds executor.owners[owner_ordinal]
    return _fail_execution_owner_overload!(
        owner.overload_policy.action,
        owner,
        :owner_deadline_exceeded,
        "exceeded its prepared execution-clock deadline",
    )
end

function _submit_owner_phase!(
    executor::PreparedExecutionOwnerExecutor,
    claim::OpticalPathBatchClaim,
    batch_sequence::UInt64,
    owner_count::Int,
    phase::_ExecutionOwnerWorkPhase,
)
    due_ordinals =
        executor.coordinator_workspace.due_owner_ordinals
    @inbounds for index in 1:owner_count
        owner_ordinal = Int(due_ordinals[index])
        owner = executor.owners[owner_ordinal]
        descriptor = _ExecutionOwnerWorkDescriptor(
            executor.session,
            owner.id,
            batch_sequence,
            phase,
            claim,
        )
        status = try_submit!(owner.due, descriptor)
        if status != RingTransferSucceeded
            overload =
                executor.owner_overload_states[owner_ordinal]
            accounting = ring_accounting(owner.due)
            overload.current_due_occupancy = accounting.occupancy
            overload.maximum_due_occupancy = max(
                overload.maximum_due_occupancy,
                accounting.occupancy,
            )
            _mark_execution_owner_overload!(
                overload, ExecutionOwnerFailedForCapacity)
            _fail_execution_owner_overload!(
                owner.overload_policy.action,
                owner,
                :due_work_publication,
                "could not publish into its bounded due-work path",
            )
        end
        _record_owner_due_submission!(
            executor.owner_overload_states[owner_ordinal])
        executor.coordinator.submitted[owner_ordinal] += UInt64(1)
    end
    return nothing
end

function _deterministic_service_reversed(
    mode::DeterministicExecutionOwners,
    batch_sequence::UInt64,
    phase::_ExecutionOwnerWorkPhase,
)
    mode.alternate_order || return false
    phase_offset = phase == _ExecutionOwnerExecution
    return isodd(batch_sequence) ⊻ phase_offset
end

function _service_deterministic_phase!(
    executor::PreparedExecutionOwnerExecutor{
        <:DeterministicExecutionOwners,
    },
    batch_sequence::UInt64,
    owner_count::Int,
    phase::_ExecutionOwnerWorkPhase,
)
    ordinals =
        executor.coordinator_workspace.due_owner_ordinals
    reversed = _deterministic_service_reversed(
        executor.mode, batch_sequence, phase)
    @inbounds for service_index in 1:owner_count
        index = reversed ? owner_count - service_index + 1 :
            service_index
        owner_ordinal = Int(ordinals[index])
        owner = executor.owners[owner_ordinal]
        workspace = executor.owner_workspaces[owner_ordinal]
        try_take!(workspace.work, owner.due) ==
            RingTransferSucceeded || _execution_owner_error(
                :deterministic_due_work,
                "deterministic owner could not consume its due descriptor",
            )
        _service_owner_work!(
            executor, owner_ordinal, workspace.work[])
    end
    return nothing
end

_service_deterministic_phase!(
    ::PreparedExecutionOwnerExecutor{<:AgentExecutionOwners},
    ::UInt64,
    ::Int,
    ::_ExecutionOwnerWorkPhase,
) = nothing

function _collect_owner_phase!(
    executor::PreparedExecutionOwnerExecutor,
    batch_sequence::UInt64,
    owner_count::Int,
    phase::_ExecutionOwnerWorkPhase,
    timing,
    timestamp::PlantTimestamp,
)
    workspace = executor.coordinator_workspace
    fill!(workspace.completion_seen, false)
    _service_deterministic_phase!(
        executor, batch_sequence, owner_count, phase)
    remaining = owner_count
    failure_seen = false
    first_failure = nothing
    deadline_failure_owner = 0
    poll_count = zero(UInt32)
    while remaining > 0
        made_progress = false
        @inbounds for due_index in 1:owner_count
            owner_ordinal =
                Int(workspace.due_owner_ordinals[due_index])
            workspace.completion_seen[owner_ordinal] && continue
            owner = executor.owners[owner_ordinal]
            scratch = workspace.completions[owner_ordinal]
            status = try_take!(scratch, owner.completion)
            status == RingEmpty && continue
            status == RingTransferSucceeded ||
                _execution_owner_error(
                    :completion_consumption,
                    "owner completion path closed before the expected work acknowledgement",
                )
            completion = scratch[]
            completion.session == executor.session ||
                _execution_owner_error(
                    :stale_completion_session,
                    "owner completion belongs to another run/session",
                )
            completion.owner == owner.id ||
                _execution_owner_error(
                    :wrong_completion_owner,
                    "owner completion came from another completion path",
                )
            completion.batch_sequence == batch_sequence ||
                _execution_owner_error(
                    :stale_completion_batch,
                    "owner completion belongs to another batch",
                )
            completion.phase == phase ||
                _execution_owner_error(
                    :wrong_completion_phase,
                    "owner completion reports another work phase",
                )
            workspace.completion_seen[owner_ordinal] = true
            executor.coordinator.completions[owner_ordinal] += UInt64(1)
            _record_owner_completion_consumption!(
                executor.owner_overload_states[owner_ordinal],
                owner,
            )
            remaining -= 1
            made_progress = true
            if completion.status == _ExecutionOwnerWorkFailed
                if !failure_seen
                    first_failure =
                        executor.owner_states[owner_ordinal].failure
                    failure_seen = true
                end
            else
                if _observe_execution_owner_deadline!(
                    executor, owner_ordinal, timing, timestamp)
                    iszero(deadline_failure_owner) &&
                        (deadline_failure_owner = owner_ordinal)
                end
            end
        end
        if made_progress
            _reset_coordinator_idle!(executor)
            poll_count = zero(UInt32)
            continue
        end
        @inbounds for due_index in 1:owner_count
            owner_ordinal =
                Int(workspace.due_owner_ordinals[due_index])
            workspace.completion_seen[owner_ordinal] && continue
            _observe_execution_owner_deadline!(
                executor, owner_ordinal, timing, timestamp) &&
                _fail_execution_owner_deadline!(
                    executor, owner_ordinal)
        end
        poll_count = _wait_for_owner_progress(
            executor,
            poll_count,
            :missing_deterministic_completion,
            "deterministic owner phase did not complete",
        )
    end
    failure_seen && throw(first_failure)
    iszero(deadline_failure_owner) ||
        _fail_execution_owner_deadline!(
            executor, deadline_failure_owner)
    return nothing
end

function _execute_owned_optical_path_batch!(
    executor::PreparedExecutionOwnerExecutor,
    prepared::PreparedPlantEventLoop,
    state::PlantEventLoopState,
    workspace::PlantEventLoopWorkspace,
    timestamp::PlantTimestamp,
    timing,
)
    _require_executor_binding(executor, prepared, state, workspace)
    claim = begin_optical_path_batch!(
        prepared, state, workspace, timestamp)
    executor.coordinator.active_claim = claim
    try
        owner_count = _collect_due_execution_owners!(executor, claim)
        batch_sequence = _next_batch_sequence!(executor)
        _submit_owner_phase!(
            executor,
            claim,
            batch_sequence,
            owner_count,
            _ExecutionOwnerMaterialization,
        )
        _collect_owner_phase!(
            executor,
            batch_sequence,
            owner_count,
            _ExecutionOwnerMaterialization,
            timing,
            timestamp,
        )
        seal_optical_path_batch_materialization!(
            prepared, state, workspace, claim)
        _submit_owner_phase!(
            executor,
            claim,
            batch_sequence,
            owner_count,
            _ExecutionOwnerExecution,
        )
        _collect_owner_phase!(
            executor,
            batch_sequence,
            owner_count,
            _ExecutionOwnerExecution,
            timing,
            timestamp,
        )
    catch
        _abandon_failed_optical_path_batch!(executor)
        rethrow()
    end
    completed = complete_optical_path_batch!(
        prepared, state, workspace, claim)
    executor.coordinator.active_claim = nothing
    executor.coordinator.batch_count += UInt64(1)
    return completed
end

function Plant.execute_optical_path_batch!(
    executor::PreparedExecutionOwnerExecutor,
    prepared::PreparedPlantEventLoop,
    state::PlantEventLoopState,
    workspace::PlantEventLoopWorkspace,
    timestamp::PlantTimestamp,
)
    return _execute_owned_optical_path_batch!(
        executor,
        prepared,
        state,
        workspace,
        timestamp,
        nothing,
    )
end

function Plant.execute_optical_path_batch!(
    runtime::_ExecutionClockBoundOwnerExecutor,
    prepared::PreparedPlantEventLoop,
    state::PlantEventLoopState,
    workspace::PlantEventLoopWorkspace,
    timestamp::PlantTimestamp,
)
    return _execute_owned_optical_path_batch!(
        runtime.executor,
        prepared,
        state,
        workspace,
        timestamp,
        runtime.timing,
    )
end

end
