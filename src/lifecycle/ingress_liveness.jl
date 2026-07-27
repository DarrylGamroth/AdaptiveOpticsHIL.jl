"""
Prepared policy for one execution-clock RTC-ingress-liveness watchdog.

The watchdog is scoped to exactly one command endpoint. Its inclusive timeout
is shorter than `2^63` nanoseconds by construction, and expiry is terminal for
the prepared state.
"""
abstract type AbstractRTCIngressLivenessPolicy end

"""Internal concrete policy used when a run selects no ingress watchdog."""
struct NoRTCIngressLiveness <: AbstractRTCIngressLivenessPolicy end

@inline function _checked_rtc_ingress_liveness_timeout(
    timeout_ns::Integer)
    0 < timeout_ns <= typemax(Int64) ||
        throw(RunLifecycleError(
            :rtc_ingress_liveness,
            :invalid_timeout,
            "RTC-ingress-liveness timeout must be positive and shorter than 2^63 nanoseconds"))
    return Int64(timeout_ns)
end

@inline _checked_rtc_ingress_liveness_timeout(::Bool) =
    throw(RunLifecycleError(
        :rtc_ingress_liveness,
        :invalid_timeout,
        "RTC-ingress-liveness timeout must be an integer nanosecond count, not Bool"))

struct RTCIngressLivenessPolicy <: AbstractRTCIngressLivenessPolicy
    endpoint::CommandEndpointID
    execution_clock::ExecutionClockID
    timeout_ns::Int64

    function RTCIngressLivenessPolicy(
        endpoint::CommandEndpointID,
        execution_clock::ExecutionClockID;
        timeout_ns::Integer)
        return new(
            endpoint,
            execution_clock,
            _checked_rtc_ingress_liveness_timeout(timeout_ns))
    end
end

rtc_ingress_liveness_endpoint(policy::RTCIngressLivenessPolicy) =
    policy.endpoint
rtc_ingress_liveness_clock(policy::RTCIngressLivenessPolicy) =
    policy.execution_clock
rtc_ingress_liveness_timeout_ns(policy::RTCIngressLivenessPolicy) =
    policy.timeout_ns

@enum RTCIngressLivenessStatus::UInt8 begin
    RTCIngressLivenessDisabled = 0x01
    RTCIngressLivenessDisarmed = 0x02
    RTCIngressLivenessActive = 0x03
    RTCIngressLivenessExpired = 0x04
end

"""
Preallocated single-writer watchdog state.

Coordinates are valid only when implied by `status`; explicit flags avoid
nullable mutable fields on the warmed path.
"""
mutable struct RTCIngressLivenessState{
    P<:AbstractRTCIngressLivenessPolicy,
}
    const policy::P
    status::RTCIngressLivenessStatus
    origin_execution_ns::Int64
    deadline_execution_ns::Int64
    observation_execution_ns::Int64
    last_admission_execution_ns::Int64
    has_last_admission::Bool
    reset_count::UInt64
    expiry_count::UInt64
end

RTCIngressLivenessState(policy::NoRTCIngressLiveness) =
    RTCIngressLivenessState(
        policy,
        RTCIngressLivenessDisabled,
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        false,
        UInt64(0),
        UInt64(0))

RTCIngressLivenessState(policy::RTCIngressLivenessPolicy) =
    RTCIngressLivenessState(
        policy,
        RTCIngressLivenessDisarmed,
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        false,
        UInt64(0),
        UInt64(0))

rtc_ingress_liveness_status(state::RTCIngressLivenessState) =
    state.status

@inline _rtc_ingress_liveness_has_origin(
    status::RTCIngressLivenessStatus) =
    status == RTCIngressLivenessActive ||
    status == RTCIngressLivenessExpired

rtc_ingress_liveness_origin_ns(state::RTCIngressLivenessState) =
    _rtc_ingress_liveness_has_origin(state.status) ?
        state.origin_execution_ns : nothing
rtc_ingress_liveness_deadline_ns(state::RTCIngressLivenessState) =
    _rtc_ingress_liveness_has_origin(state.status) ?
        state.deadline_execution_ns : nothing
rtc_ingress_liveness_observation_ns(state::RTCIngressLivenessState) =
    _rtc_ingress_liveness_has_origin(state.status) ?
        state.observation_execution_ns : nothing
rtc_ingress_liveness_last_admission_ns(state::RTCIngressLivenessState) =
    state.has_last_admission ?
        state.last_admission_execution_ns : nothing
rtc_ingress_liveness_reset_count(state::RTCIngressLivenessState) =
    state.reset_count
rtc_ingress_liveness_expiry_count(state::RTCIngressLivenessState) =
    state.expiry_count

@inline function _rtc_ingress_liveness_deadline(
    origin_execution_ns::Int64,
    timeout_ns::Int64)
    return reinterpret(
        Int64,
        reinterpret(UInt64, origin_execution_ns) + UInt64(timeout_ns))
end

@inline function _require_rtc_ingress_liveness_clock(
    policy::RTCIngressLivenessPolicy,
    execution_clock::ExecutionClockID)
    policy.execution_clock == execution_clock ||
        throw(RunLifecycleError(
            :rtc_ingress_liveness,
            :clock_identity_mismatch,
            "RTC-ingress-liveness observation uses another execution-clock identity"))
    return nothing
end

@inline function _require_rtc_ingress_liveness_active(
    state::RTCIngressLivenessState)
    state.status == RTCIngressLivenessActive ||
        throw(RunLifecycleError(
            :rtc_ingress_liveness,
            :invalid_status,
            "RTC-ingress-liveness watchdog is not active"))
    return nothing
end

@inline function _rtc_ingress_liveness_elapsed_ns(
    state::RTCIngressLivenessState,
    observed_execution_ns::Int64)
    return _checked_lifecycle_elapsed_ns(
        state.origin_execution_ns,
        observed_execution_ns,
        :rtc_ingress_liveness,
        :execution_clock_regressed,
        "execution clock regressed during RTC-ingress-liveness observation or the interval reached 2^63 nanoseconds")
end

@inline function _start_rtc_ingress_liveness!(
    state::RTCIngressLivenessState{NoRTCIngressLiveness},
    ::ExecutionClockID,
    ::Int64)
    return state.status
end

function _start_rtc_ingress_liveness!(
    state::RTCIngressLivenessState{RTCIngressLivenessPolicy},
    execution_clock::ExecutionClockID,
    origin_execution_ns::Int64)
    state.status == RTCIngressLivenessDisarmed ||
        throw(RunLifecycleError(
            :rtc_ingress_liveness,
            :invalid_status,
            "RTC-ingress-liveness watchdog can start exactly once per prepared run"))
    _require_rtc_ingress_liveness_clock(
        state.policy, execution_clock)
    state.origin_execution_ns = origin_execution_ns
    state.deadline_execution_ns = _rtc_ingress_liveness_deadline(
        origin_execution_ns, state.policy.timeout_ns)
    state.observation_execution_ns = origin_execution_ns
    state.status = RTCIngressLivenessActive
    return state.status
end

@inline function _expire_rtc_ingress_liveness!(
    state::RTCIngressLivenessState,
    observed_execution_ns::Int64)
    state.observation_execution_ns = observed_execution_ns
    state.status = RTCIngressLivenessExpired
    state.expiry_count += UInt64(1)
    return state.status
end

@inline function _observe_rtc_ingress_liveness!(
    state::RTCIngressLivenessState{NoRTCIngressLiveness},
    ::ExecutionClockID,
    ::Int64)
    return state.status
end

@inline function _observe_rtc_ingress_liveness!(
    state::RTCIngressLivenessState{RTCIngressLivenessPolicy},
    execution_clock::ExecutionClockID,
    observed_execution_ns::Int64)
    _require_rtc_ingress_liveness_clock(
        state.policy, execution_clock)
    state.status == RTCIngressLivenessExpired &&
        return state.status
    _require_rtc_ingress_liveness_active(state)
    elapsed_ns = _rtc_ingress_liveness_elapsed_ns(
        state, observed_execution_ns)
    elapsed_ns > state.policy.timeout_ns &&
        return _expire_rtc_ingress_liveness!(
            state, observed_execution_ns)
    state.observation_execution_ns = observed_execution_ns
    return state.status
end

@inline function _admit_rtc_ingress_liveness!(
    state::RTCIngressLivenessState{NoRTCIngressLiveness},
    ::CommandEndpointID,
    ::ExecutionClockID,
    ::Int64)
    return state.status
end

@inline function _admit_rtc_ingress_liveness!(
    state::RTCIngressLivenessState{RTCIngressLivenessPolicy},
    endpoint::CommandEndpointID,
    execution_clock::ExecutionClockID,
    observed_execution_ns::Int64)
    state.policy.endpoint == endpoint ||
        throw(RunLifecycleError(
            :rtc_ingress_liveness,
            :endpoint_mismatch,
            "semantic command admission belongs to another RTC-ingress-liveness scope"))
    _require_rtc_ingress_liveness_clock(
        state.policy, execution_clock)
    state.status == RTCIngressLivenessExpired &&
        return state.status
    _require_rtc_ingress_liveness_active(state)
    elapsed_ns = _rtc_ingress_liveness_elapsed_ns(
        state, observed_execution_ns)
    state.last_admission_execution_ns = observed_execution_ns
    state.has_last_admission = true
    elapsed_ns > state.policy.timeout_ns &&
        return _expire_rtc_ingress_liveness!(
            state, observed_execution_ns)
    state.origin_execution_ns = observed_execution_ns
    state.deadline_execution_ns = _rtc_ingress_liveness_deadline(
        observed_execution_ns, state.policy.timeout_ns)
    state.observation_execution_ns = observed_execution_ns
    state.reset_count += UInt64(1)
    return state.status
end

"""Cold immutable accounting snapshot for one prepared watchdog."""
struct RTCIngressLivenessAccounting
    status::RTCIngressLivenessStatus
    endpoint::Union{Nothing,CommandEndpointID}
    execution_clock::Union{Nothing,ExecutionClockID}
    timeout_ns::Union{Nothing,Int64}
    origin_execution_ns::Union{Nothing,Int64}
    deadline_execution_ns::Union{Nothing,Int64}
    observation_execution_ns::Union{Nothing,Int64}
    last_admission_execution_ns::Union{Nothing,Int64}
    reset_count::UInt64
    expiry_count::UInt64
end

function rtc_ingress_liveness_accounting(
    state::RTCIngressLivenessState{NoRTCIngressLiveness})
    return RTCIngressLivenessAccounting(
        state.status,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        state.reset_count,
        state.expiry_count)
end

function rtc_ingress_liveness_accounting(
    state::RTCIngressLivenessState{RTCIngressLivenessPolicy})
    return RTCIngressLivenessAccounting(
        state.status,
        state.policy.endpoint,
        state.policy.execution_clock,
        state.policy.timeout_ns,
        rtc_ingress_liveness_origin_ns(state),
        rtc_ingress_liveness_deadline_ns(state),
        rtc_ingress_liveness_observation_ns(state),
        rtc_ingress_liveness_last_admission_ns(state),
        state.reset_count,
        state.expiry_count)
end
