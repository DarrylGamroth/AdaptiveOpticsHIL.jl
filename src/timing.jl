"""
    Timing

Mapping between the canonical virtual plant timeline and an injected monotonic
host execution clock. This namespace measures timing; it does not sleep, poll,
advance plant time, or own a scheduler.
"""
module Timing

import Clocks
using AdaptiveOpticsSim.Plant: PlantTimestamp, plant_nanoseconds

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError

export ExecutionClockError, ExecutionClockMapping
export arm_execution_clock
export execution_clock, plant_time_origin, execution_clock_origin_ns
export execution_lateness_ns, execution_time_until_ns

"""Invalid execution-clock provider, reading, or plant-time mapping."""
struct ExecutionClockError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

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
    plant_origin::PlantTimestamp
    execution_origin_ns::Int64
end

_checked_execution_reading(value::Int64) = value

_checked_execution_reading(::Any) = throw(ExecutionClockError(
    :execution_clock,
    :invalid_reading_type,
    "Clocks.time_nanos must return Int64 for an execution clock"))

_read_execution_clock(clock::Clocks.AbstractNanoClock) =
    _checked_execution_reading(Clocks.time_nanos(clock))

"""
    arm_execution_clock(clock, plant_origin=zero(PlantTimestamp))

Capture the current reading of a concrete monotonic nanosecond `clock` and bind
it to `plant_origin`. Epoch-clock providers do not satisfy this method.
"""
function arm_execution_clock(clock::C,
    plant_origin::PlantTimestamp=zero(PlantTimestamp)) where {
    C<:Clocks.AbstractNanoClock}
    execution_origin_ns = _read_execution_clock(clock)
    return ExecutionClockMapping(
        clock, plant_origin, execution_origin_ns)
end

"""Return the concrete monotonic provider owned by `mapping`."""
execution_clock(mapping::ExecutionClockMapping) = mapping.clock

"""Return the canonical plant-time origin bound by `mapping`."""
plant_time_origin(mapping::ExecutionClockMapping) = mapping.plant_origin

"""Return the monotonic nanosecond reading captured when `mapping` was armed."""
execution_clock_origin_ns(mapping::ExecutionClockMapping) =
    mapping.execution_origin_ns

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
    elapsed_bits = reinterpret(UInt64, current_ns) -
                   reinterpret(UInt64, mapping.execution_origin_ns)
    elapsed_ns = reinterpret(Int64, elapsed_bits)
    elapsed_ns >= 0 || throw(ExecutionClockError(
        :execution_clock,
        :regression_or_interval_exceeded,
        "execution clock regressed or elapsed interval is at least 2^63 nanoseconds"))
    return elapsed_ns
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

end
