"""Invalid execution-clock provider, reading, owner, or plant-time mapping."""
struct ExecutionClockError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

"""Stable run-facing identity of one execution clock."""
struct ExecutionClockID
    name::Symbol

    function ExecutionClockID(name::Symbol)
        isempty(String(name)) && throw(ExecutionClockError(
            :execution_clock_identity,
            :empty_id,
            "execution-clock identity must not be empty"))
        return new(name)
    end
end

"""Stable logical owner allowed to refresh one cached execution clock."""
struct ExecutionClockUpdateOwnerID
    name::Symbol

    function ExecutionClockUpdateOwnerID(name::Symbol)
        isempty(String(name)) && throw(ExecutionClockError(
            :execution_clock_owner,
            :empty_id,
            "execution-clock update-owner identity must not be empty"))
        return new(name)
    end
end

const _ExecutionClockSymbolID =
    Union{ExecutionClockID,ExecutionClockUpdateOwnerID}

Base.:(==)(left::T, right::T) where {T<:_ExecutionClockSymbolID} =
    left.name == right.name
Base.isequal(left::T, right::T) where {T<:_ExecutionClockSymbolID} =
    isequal(left.name, right.name)
Base.hash(value::T, seed::UInt) where {T<:_ExecutionClockSymbolID} =
    hash(value.name, hash(T, seed))

function Base.show(io::IO, value::_ExecutionClockSymbolID)
    print(io, nameof(typeof(value)), "(", repr(value.name), ")")
end

_checked_execution_reading(value::Int64) = value

_checked_execution_reading(::Any) = throw(ExecutionClockError(
    :execution_clock,
    :invalid_reading_type,
    "Clocks.time_nanos must return Int64 for an execution clock"))

@inline _read_execution_clock(clock::Clocks.AbstractNanoClock) =
    _checked_execution_reading(Clocks.time_nanos(clock))

@inline function _checked_execution_elapsed_ns(
    earlier_ns::Int64,
    later_ns::Int64,
    component::Symbol)
    elapsed_bits =
        reinterpret(UInt64, later_ns) - reinterpret(UInt64, earlier_ns)
    elapsed_ns = reinterpret(Int64, elapsed_bits)
    elapsed_ns >= 0 || throw(ExecutionClockError(
        component,
        :regression_or_interval_exceeded,
        "execution clock regressed or elapsed interval is at least 2^63 nanoseconds"))
    return elapsed_ns
end

@inline function _checked_update_cadence(value::Integer)
    0 < value <= typemax(Int64) || throw(ExecutionClockError(
        :cached_execution_clock,
        :invalid_update_cadence,
        "cached execution-clock update cadence must be a positive " *
        "Int64-compatible nanosecond count"))
    return Int64(value)
end

@inline _checked_update_cadence(::Bool) = throw(ExecutionClockError(
    :cached_execution_clock,
    :invalid_update_cadence,
    "cached execution-clock update cadence must be an integer count, not Bool"))

mutable struct _CachedExecutionClockState
    const cache::Clocks.CachedNanoClock
    @atomic maximum_observed_staleness_ns::Int64
    @atomic refresh_count::UInt64
end

"""
Read-only `Clocks.AbstractNanoClock` view distributed to workers. Refresh
authority and the source provider remain in a
[`CachedExecutionClockController`](@ref).
"""
struct CachedExecutionClock <: Clocks.AbstractNanoClock
    state::_CachedExecutionClockState
    identity::ExecutionClockID
    update_owner::ExecutionClockUpdateOwnerID
    update_cadence_ns::Int64
    source_provider::Symbol
end

"""
Single-owner control capability for one [`CachedExecutionClock`](@ref).
Workers should receive only [`cached_execution_clock`](@ref).
"""
struct CachedExecutionClockController{S<:Clocks.AbstractNanoClock}
    clock::CachedExecutionClock
    source::S
end

@inline Clocks.time_nanos(clock::CachedExecutionClock) =
    Clocks.time_nanos(clock.state.cache)

"""
    prepare_cached_execution_clock(source; identity, update_owner,
        update_cadence_ns)

Capture a concrete monotonic source into a worker-readable cached clock.
Epoch-clock providers do not satisfy this method.
"""
function prepare_cached_execution_clock(
    source::S;
    identity::ExecutionClockID=ExecutionClockID(:cached_execution_clock),
    update_owner::ExecutionClockUpdateOwnerID=
        ExecutionClockUpdateOwnerID(:clock_update_owner),
    update_cadence_ns::Integer) where {S<:Clocks.AbstractNanoClock}
    cadence = _checked_update_cadence(update_cadence_ns)
    initial_ns = _read_execution_clock(source)
    state = _CachedExecutionClockState(
        Clocks.CachedNanoClock(initial_ns), 0, UInt64(0))
    clock = CachedExecutionClock(
        state,
        identity,
        update_owner,
        cadence,
        nameof(S))
    return CachedExecutionClockController(clock, source)
end

"""Return the read-only cached clock view suitable for worker distribution."""
cached_execution_clock(controller::CachedExecutionClockController) =
    controller.clock

"""
    refresh_cached_execution_clock!(controller, caller)

Refresh the cached value from its monotonic source. `caller` must match the
prepared logical update owner. The elapsed source interval immediately before
refresh is accumulated as maximum observed cache staleness.
"""
function refresh_cached_execution_clock!(
    controller::CachedExecutionClockController,
    caller::ExecutionClockUpdateOwnerID)
    clock = controller.clock
    caller == clock.update_owner || throw(ExecutionClockError(
        :cached_execution_clock,
        :wrong_update_owner,
        "only the prepared execution-clock update owner may refresh the cache"))
    previous_ns = _read_execution_clock(clock)
    current_ns = _read_execution_clock(controller.source)
    staleness_ns = _checked_execution_elapsed_ns(
        previous_ns, current_ns, :cached_execution_clock)
    count = @atomic :monotonic clock.state.refresh_count
    count < typemax(UInt64) || throw(ExecutionClockError(
        :cached_execution_clock,
        :refresh_count_overflow,
        "cached execution-clock refresh count is exhausted"))
    previous_max =
        @atomic :monotonic clock.state.maximum_observed_staleness_ns
    if staleness_ns > previous_max
        @atomic :release clock.state.maximum_observed_staleness_ns =
            staleness_ns
    end
    Clocks.update!(clock.state.cache, current_ns)
    @atomic :release clock.state.refresh_count = count + UInt64(1)
    return current_ns
end

cached_clock_update_owner(clock::CachedExecutionClock) =
    clock.update_owner
cached_clock_update_owner(controller::CachedExecutionClockController) =
    cached_clock_update_owner(controller.clock)

cached_clock_update_cadence_ns(clock::CachedExecutionClock) =
    clock.update_cadence_ns
cached_clock_update_cadence_ns(controller::CachedExecutionClockController) =
    cached_clock_update_cadence_ns(controller.clock)

cached_clock_maximum_observed_staleness_ns(clock::CachedExecutionClock) =
    @atomic :acquire clock.state.maximum_observed_staleness_ns
cached_clock_maximum_observed_staleness_ns(
    controller::CachedExecutionClockController) =
    cached_clock_maximum_observed_staleness_ns(controller.clock)

cached_clock_refresh_count(clock::CachedExecutionClock) =
    @atomic :acquire clock.state.refresh_count
cached_clock_refresh_count(controller::CachedExecutionClockController) =
    cached_clock_refresh_count(controller.clock)

"""
    ExecutionClockMapping

Immutable run-local correspondence between one [`PlantTimestamp`](@ref) origin
and the reading captured from one concrete `Clocks.AbstractNanoClock`.

Elapsed execution-clock arithmetic is valid only for intervals strictly less
than `2^63` nanoseconds. That bound makes signed modular subtraction
unambiguous across the `Int64` representation wrap used by Clocks.jl.
"""
struct ExecutionClockMapping{C<:Clocks.AbstractNanoClock}
    clock::C
    identity::ExecutionClockID
    plant_origin::PlantTimestamp
    execution_origin_ns::Int64
end

"""Return the stable run-facing identity selected for an execution clock."""
execution_clock_identity(::Clocks.AbstractNanoClock) =
    ExecutionClockID(:execution_clock)
execution_clock_identity(clock::CachedExecutionClock) =
    clock.identity

_validate_execution_clock_identity(
    ::Clocks.AbstractNanoClock,
    ::ExecutionClockID) = nothing

function _validate_execution_clock_identity(
    clock::CachedExecutionClock,
    identity::ExecutionClockID)
    identity == clock.identity || throw(ExecutionClockError(
        :execution_clock_identity,
        :cached_identity_mismatch,
        "cached execution-clock mapping identity must match its prepared identity"))
    return nothing
end

"""
    arm_execution_clock(clock, plant_origin=zero(PlantTimestamp);
        identity=...)

Capture the current reading of a concrete monotonic nanosecond `clock` and bind
it to `plant_origin`. Epoch-clock providers do not satisfy this method.
"""
function arm_execution_clock(
    clock::C,
    plant_origin::PlantTimestamp=zero(PlantTimestamp);
    identity::ExecutionClockID=
        execution_clock_identity(clock)) where {
    C<:Clocks.AbstractNanoClock}
    _validate_execution_clock_identity(clock, identity)
    execution_origin_ns = _read_execution_clock(clock)
    return ExecutionClockMapping(
        clock, identity, plant_origin, execution_origin_ns)
end

"""Return the concrete monotonic provider owned by `mapping`."""
execution_clock(mapping::ExecutionClockMapping) = mapping.clock

"""Return the stable run-facing identity of `mapping`."""
execution_clock_identity(mapping::ExecutionClockMapping) = mapping.identity

"""Return the canonical plant-time origin bound by `mapping`."""
plant_time_origin(mapping::ExecutionClockMapping) = mapping.plant_origin

"""Return the monotonic nanosecond reading captured when `mapping` was armed."""
execution_clock_origin_ns(mapping::ExecutionClockMapping) =
    mapping.execution_origin_ns

"""
Cold run-facing execution-clock metadata. `nothing` fields distinguish a
direct clock from a prepared cached clock without inventing sentinel values.
"""
struct ExecutionClockMetadata
    identity::ExecutionClockID
    source_provider::Symbol
    update_owner::Union{Nothing,ExecutionClockUpdateOwnerID}
    update_cadence_ns::Union{Nothing,Int64}
    maximum_observed_staleness_ns::Union{Nothing,Int64}
    refresh_count::Union{Nothing,UInt64}
end

function execution_clock_metadata(mapping::ExecutionClockMapping)
    return _execution_clock_metadata(mapping.clock, mapping.identity)
end

function _execution_clock_metadata(
    clock::Clocks.AbstractNanoClock,
    identity::ExecutionClockID)
    return ExecutionClockMetadata(
        identity,
        nameof(typeof(clock)),
        nothing,
        nothing,
        nothing,
        nothing)
end

function _execution_clock_metadata(
    clock::CachedExecutionClock,
    identity::ExecutionClockID)
    return ExecutionClockMetadata(
        identity,
        clock.source_provider,
        clock.update_owner,
        clock.update_cadence_ns,
        cached_clock_maximum_observed_staleness_ns(clock),
        cached_clock_refresh_count(clock))
end

execution_clock_identity(metadata::ExecutionClockMetadata) =
    metadata.identity
execution_clock_source_provider(metadata::ExecutionClockMetadata) =
    metadata.source_provider
execution_clock_update_owner(metadata::ExecutionClockMetadata) =
    metadata.update_owner
execution_clock_update_cadence_ns(metadata::ExecutionClockMetadata) =
    metadata.update_cadence_ns
execution_clock_maximum_observed_staleness_ns(
    metadata::ExecutionClockMetadata) =
    metadata.maximum_observed_staleness_ns
execution_clock_refresh_count(metadata::ExecutionClockMetadata) =
    metadata.refresh_count

function _target_elapsed_ns(mapping::ExecutionClockMapping,
    target::PlantTimestamp)
    target_ns = plant_nanoseconds(target)
    origin_ns = plant_nanoseconds(mapping.plant_origin)
    target_ns >= origin_ns || throw(ExecutionClockError(
        :plant_target,
        :before_mapping_origin,
        "plant target precedes the execution-clock mapping origin"))
    return target_ns - origin_ns
end

function _execution_elapsed_ns(mapping::ExecutionClockMapping)
    current_ns = _read_execution_clock(mapping.clock)
    return _checked_execution_elapsed_ns(
        mapping.execution_origin_ns,
        current_ns,
        :execution_clock)
end

"""
    execution_lateness_ns(mapping, target)

Return signed execution lateness for plant `target`, in nanoseconds. A positive
result is late, zero is exactly due, and a negative result is early.

The execution clock is read exactly once. Normal successful calls are
allocation-free for concrete built-in Clocks.jl providers after compilation.
"""
function execution_lateness_ns(mapping::ExecutionClockMapping,
    target::PlantTimestamp)
    target_elapsed_ns = _target_elapsed_ns(mapping, target)
    elapsed_ns = _execution_elapsed_ns(mapping)
    return elapsed_ns - target_elapsed_ns
end

"""
    execution_lateness_ns(mapping, target, observed_execution_ns)

Return signed lateness at one already captured reading of the mapping's
execution clock. This overload does not read the clock and is suitable when
one publication coordinate must be shared by several bounded decisions.
"""
function execution_lateness_ns(
    mapping::ExecutionClockMapping,
    target::PlantTimestamp,
    observed_execution_ns::Int64)
    target_elapsed_ns = _target_elapsed_ns(mapping, target)
    elapsed_ns = _checked_execution_elapsed_ns(
        mapping.execution_origin_ns,
        observed_execution_ns,
        :execution_clock)
    return elapsed_ns - target_elapsed_ns
end

"""
    execution_time_until_ns(mapping, target)

Return signed execution time until plant `target`, in nanoseconds. A positive
result is early, zero is exactly due, and a negative result is late.

The execution clock is read exactly once. This is the additive inverse of
[`execution_lateness_ns`](@ref) for the same clock reading.
"""
function execution_time_until_ns(mapping::ExecutionClockMapping,
    target::PlantTimestamp)
    target_elapsed_ns = _target_elapsed_ns(mapping, target)
    elapsed_ns = _execution_elapsed_ns(mapping)
    return target_elapsed_ns - elapsed_ns
end
