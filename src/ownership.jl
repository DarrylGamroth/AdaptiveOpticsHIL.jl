"""
    Ownership

Fixed-capacity, transport-neutral ownership primitives for warmed HIL
boundaries. Compact isbits descriptors cross a bounded single-producer,
single-consumer ring; large mutable payloads remain in a separately prepared,
generation-checked pool.

Ring operations never wait, yield, retry, invoke callbacks, or allocate after
preparation. An idle or retry policy belongs to the caller.
"""
module Ownership

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError

export OwnershipError
export CONSERVATIVE_CACHE_LINE_BYTES
export RingStatus, RingTransferSucceeded, RingFull, RingEmpty, RingClosed
export RingBatchResult, RingAccounting, SPSCDescriptorRing
export close_ring!, ring_accounting, ring_capacity, ring_cursor_separation_bytes
export ring_is_closed, try_submit!, try_take!, try_take_batch!
export PayloadStatus
export PayloadTransitionSucceeded, PayloadPoolExhausted
export WrongPayloadPool, WrongPayloadSession, InvalidPayloadSlot
export StalePayloadLease, WrongPayloadOwner, DuplicatePayloadRelease
export PayloadGenerationExhausted
export PayloadLeaseRef, PayloadPool, PayloadPoolAccounting
export abort_payload!, consumer_payload, lease_payload!, payload_generation
export payload_pool_accounting, payload_pool_capacity, payload_pool_id
export payload_session_id, payload_slot, producer_payload, queue_payload!
export release_payload!, try_claim_payload!, validate_quiescent_pool

"""Invalid ownership configuration, access, state, or accounting."""
struct OwnershipError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

"""
Conservative separation, in bytes, maintained between independently written
ring publication fields.

This Gate 4A constant intentionally does not claim target-specific cache
topology or generated-code validation; those remain later promotion evidence.
"""
const CONSERVATIVE_CACHE_LINE_BYTES = 128

const _WORD_BYTES = sizeof(UInt64)
const _PREFIX_WORDS = CONSERVATIVE_CACHE_LINE_BYTES ÷ _WORD_BYTES
const _BETWEEN_FIELD_WORDS = _PREFIX_WORDS - 2

@inline _zero_words(::Val{N}) where {N} =
    ntuple(_ -> zero(UInt64), Val(N))

"""
Result of one nonblocking descriptor-ring operation.

`RingTransferSucceeded` is the only ownership-transferring result. `RingFull`,
`RingEmpty`, and `RingClosed` leave caller ownership unchanged.
"""
@enum RingStatus::UInt8 begin
    RingTransferSucceeded = 0x01
    RingFull = 0x02
    RingEmpty = 0x03
    RingClosed = 0x04
end

"""
Result of a bounded natural-batch take.

When `status == RingTransferSucceeded`, exactly `count` descriptors were
transferred. An empty or closed result has `count == 0`.
"""
struct RingBatchResult
    status::RingStatus
    count::Int
end

"""
Quiescent snapshot of descriptor-ring accounting.

`producer_sequence - consumer_sequence` is interpreted modulo `UInt64`.
Callers must externally quiesce the two owners before treating the snapshot as
a simultaneous invariant check.
"""
struct RingAccounting
    capacity::Int
    occupancy::Int
    producer_sequence::UInt64
    consumer_sequence::UInt64
    closed::Bool
end

# The prefix and suffix keep every independently accessed atomic field at least
# one conservative line from the allocation boundary. The two owner-local cache
# fields share only their respective owner's publication line. Lifecycle state
# occupies a third line.
mutable struct _SPSCCursors
    prefix::NTuple{_PREFIX_WORDS,UInt64}
    @atomic producer_sequence::UInt64
    producer_cached_consumer_sequence::UInt64
    producer_consumer_gap::NTuple{_BETWEEN_FIELD_WORDS,UInt64}
    @atomic consumer_sequence::UInt64
    consumer_cached_producer_sequence::UInt64
    consumer_closed_gap::NTuple{_BETWEEN_FIELD_WORDS,UInt64}
    @atomic closed::UInt64
    suffix::NTuple{_PREFIX_WORDS,UInt64}
end

function _SPSCCursors()
    prefix_padding = _zero_words(Val(_PREFIX_WORDS))
    between_field_padding = _zero_words(Val(_BETWEEN_FIELD_WORDS))
    return _SPSCCursors(
        prefix_padding,
        zero(UInt64),
        zero(UInt64),
        between_field_padding,
        zero(UInt64),
        zero(UInt64),
        between_field_padding,
        zero(UInt64),
        prefix_padding)
end

"""
    SPSCDescriptorRing{T}(capacity)

Prepare fixed storage for `capacity` compact descriptors of isbits type `T`.
Exactly one logical producer may call `try_submit!` and `close_ring!`; exactly
one logical consumer may call `try_take!` or `try_take_batch!`.

The owner restriction is stronger than task or thread identity: callers must
not concurrently invoke one side from several tasks even if those tasks happen
to execute on one thread.
"""
struct SPSCDescriptorRing{T}
    slots::Memory{T}
    capacity::UInt64
    cursors::_SPSCCursors
end

function SPSCDescriptorRing{T}(capacity::Integer) where {T}
    isbitstype(T) || throw(OwnershipError(
        :descriptor_ring,
        :descriptor_not_isbits,
        "SPSC descriptor type must be an isbits type"))
    capacity > 0 || throw(OwnershipError(
        :descriptor_ring,
        :invalid_capacity,
        "SPSC descriptor-ring capacity must be positive"))
    capacity <= typemax(Int) || throw(OwnershipError(
        :descriptor_ring,
        :capacity_exceeds_address_space,
        "SPSC descriptor-ring capacity exceeds the addressable or signed sequence bound"))

    capacity_int = Int(capacity)
    return SPSCDescriptorRing{T}(
        Memory{T}(undef, capacity_int),
        UInt64(capacity_int),
        _SPSCCursors())
end

"""Return the prepared descriptor capacity."""
ring_capacity(ring::SPSCDescriptorRing) = Int(ring.capacity)

@inline _ring_slot(sequence::UInt64, capacity::UInt64) =
    Int(rem(sequence, capacity)) + 1

@inline function _ring_closed(cursors::_SPSCCursors)
    return (@atomic :acquire cursors.closed) != zero(UInt64)
end

"""Return whether the producer has closed the ring to new submissions."""
ring_is_closed(ring::SPSCDescriptorRing) = _ring_closed(ring.cursors)

"""
    close_ring!(ring)

Release-publish producer closure. Already published descriptors remain
drainable. The first call returns `RingTransferSucceeded`; later calls return
`RingClosed`.
"""
function close_ring!(ring::SPSCDescriptorRing)
    cursors = ring.cursors
    (@atomic :monotonic cursors.closed) == zero(UInt64) ||
        return RingClosed
    @atomic :release cursors.closed = one(UInt64)
    return RingTransferSucceeded
end

"""
    try_submit!(ring, descriptor)

Attempt one bounded producer-side ownership transfer. A successful ordinary
descriptor write happens-before a consumer read through release/acquire
publication of the producer sequence.
"""
function try_submit!(ring::SPSCDescriptorRing{T}, descriptor::T) where {T}
    cursors = ring.cursors
    (@atomic :monotonic cursors.closed) == zero(UInt64) ||
        return RingClosed

    producer_sequence = @atomic :monotonic cursors.producer_sequence
    consumer_sequence = cursors.producer_cached_consumer_sequence
    occupancy = producer_sequence - consumer_sequence

    if occupancy >= ring.capacity
        consumer_sequence = @atomic :acquire cursors.consumer_sequence
        cursors.producer_cached_consumer_sequence = consumer_sequence
        occupancy = producer_sequence - consumer_sequence
        occupancy >= ring.capacity && return RingFull
    end

    slot = _ring_slot(producer_sequence, ring.capacity)
    @inbounds ring.slots[slot] = descriptor
    @atomic :release cursors.producer_sequence =
        producer_sequence + one(UInt64)
    return RingTransferSucceeded
end

@inline function _consumer_availability(
    cursors::_SPSCCursors,
    consumer_sequence::UInt64)
    producer_sequence = cursors.consumer_cached_producer_sequence
    if producer_sequence == consumer_sequence
        producer_sequence = @atomic :acquire cursors.producer_sequence
        cursors.consumer_cached_producer_sequence = producer_sequence
        if producer_sequence == consumer_sequence && _ring_closed(cursors)
            # Closure is release-published after the producer's final sequence
            # publication. Reloading after the acquire-observed close prevents
            # reporting closed while a final descriptor remains unread.
            producer_sequence =
                @atomic :acquire cursors.producer_sequence
            cursors.consumer_cached_producer_sequence = producer_sequence
            producer_sequence == consumer_sequence &&
                return producer_sequence, RingClosed
        end
    end
    producer_sequence == consumer_sequence &&
        return producer_sequence, RingEmpty
    return producer_sequence, RingTransferSucceeded
end

"""
    try_take!(output, ring)

Attempt one bounded consumer-side ownership transfer into caller-owned
`output`. Empty and closed results do not mutate `output`. A successful
descriptor read happens-before producer slot reuse through release/acquire
publication of the consumer sequence.
"""
function try_take!(
    output::Base.RefValue{T},
    ring::SPSCDescriptorRing{T}) where {T}
    cursors = ring.cursors
    consumer_sequence = @atomic :monotonic cursors.consumer_sequence
    _, status = _consumer_availability(cursors, consumer_sequence)
    status == RingTransferSucceeded || return status

    slot = _ring_slot(consumer_sequence, ring.capacity)
    @inbounds output[] = ring.slots[slot]
    @atomic :release cursors.consumer_sequence =
        consumer_sequence + one(UInt64)
    return RingTransferSucceeded
end

"""
    try_take_batch!(destination, ring, max_items=length(destination))

Transfer the currently available natural batch, capped by `max_items`, into
caller-owned `destination`. The consumer acquires the producer publication once
and release-publishes one reclaimed sequence after copying the batch.
"""
function try_take_batch!(
    destination::AbstractVector{T},
    ring::SPSCDescriptorRing{T},
    max_items::Integer=length(destination)) where {T}
    max_items > 0 || throw(ArgumentError("max_items must be positive"))
    max_items <= length(destination) ||
        throw(ArgumentError("max_items exceeds destination length"))

    cursors = ring.cursors
    consumer_sequence = @atomic :monotonic cursors.consumer_sequence
    producer_sequence, status =
        _consumer_availability(cursors, consumer_sequence)
    status == RingTransferSucceeded || return RingBatchResult(status, 0)

    available = producer_sequence - consumer_sequence
    count = Int(min(available, UInt64(max_items)))
    destination_index = firstindex(destination)
    @inbounds for offset in 0:(count - 1)
        sequence = consumer_sequence + UInt64(offset)
        slot = _ring_slot(sequence, ring.capacity)
        destination[destination_index + offset] = ring.slots[slot]
    end
    @atomic :release cursors.consumer_sequence =
        consumer_sequence + UInt64(count)
    return RingBatchResult(RingTransferSucceeded, count)
end

"""
    ring_accounting(ring)

Return a cold, quiescent accounting snapshot and reject an impossible
occupancy. This is not a linearizable telemetry operation while owners run.
"""
function ring_accounting(ring::SPSCDescriptorRing)
    cursors = ring.cursors
    producer_sequence = @atomic :acquire cursors.producer_sequence
    consumer_sequence = @atomic :acquire cursors.consumer_sequence
    occupancy = producer_sequence - consumer_sequence
    occupancy <= ring.capacity || throw(OwnershipError(
        :descriptor_ring,
        :invalid_accounting,
        "descriptor-ring occupancy exceeds its prepared capacity"))
    return RingAccounting(
        ring_capacity(ring),
        Int(occupancy),
        producer_sequence,
        consumer_sequence,
        _ring_closed(cursors))
end

"""
    ring_cursor_separation_bytes()

Return the byte distance between the producer-published and consumer-released
sequence fields. Gate 4A verifies this structural lower bound; allocation
alignment, target cache topology, and generated atomics remain Gate 8 evidence.
"""
function ring_cursor_separation_bytes()
    producer_field =
        Base.fieldindex(_SPSCCursors, :producer_sequence)
    consumer_field =
        Base.fieldindex(_SPSCCursors, :consumer_sequence)
    return Int(
        fieldoffset(_SPSCCursors, consumer_field) -
        fieldoffset(_SPSCCursors, producer_field))
end

"""
Result of one payload-pool ownership transition.

Only `PayloadTransitionSucceeded` changes ownership. Every failure preserves
both the payload state and any caller-owned output reference.
"""
@enum PayloadStatus::UInt8 begin
    PayloadTransitionSucceeded = 0x01
    PayloadPoolExhausted = 0x02
    WrongPayloadPool = 0x03
    WrongPayloadSession = 0x04
    InvalidPayloadSlot = 0x05
    StalePayloadLease = 0x06
    WrongPayloadOwner = 0x07
    DuplicatePayloadRelease = 0x08
    PayloadGenerationExhausted = 0x09
end

const _PAYLOAD_FREE = UInt8(0)
const _PAYLOAD_PRODUCER_OWNED = UInt8(1)
const _PAYLOAD_QUEUED = UInt8(2)
const _PAYLOAD_CONSUMER_LEASED = UInt8(3)

"""
Immutable reference to one payload-pool slot in one run session.

Pool and session identities are caller-declared stable values. Slot generation
changes on every successful claim, making a reference from an earlier use
stale even when the same slot has been reclaimed.
"""
struct PayloadLeaseRef
    pool_id::UInt64
    session_id::UInt64
    slot::UInt32
    generation::UInt64
end

"""Return the declared pool identity carried by `lease`."""
payload_pool_id(lease::PayloadLeaseRef) = lease.pool_id

"""Return the declared run/session identity carried by `lease`."""
payload_session_id(lease::PayloadLeaseRef) = lease.session_id

"""Return the one-based prepared payload slot carried by `lease`."""
payload_slot(lease::PayloadLeaseRef) = lease.slot

"""Return the slot generation carried by `lease`."""
payload_generation(lease::PayloadLeaseRef) = lease.generation

"""
    PayloadPool(payloads, pool_id, session_id)

Prepare a bounded pool over caller-supplied payload buffers. The container of
payload references is copied, not the payload buffers themselves. The caller
must relinquish mutation through retained aliases while a buffer is owned by
the pool.
"""
struct PayloadPool{P}
    payloads::Memory{P}
    generations::Memory{UInt64}
    states::AtomicMemory{UInt8}
    pool_id::UInt64
    session_id::UInt64
end

function PayloadPool(
    payloads::AbstractVector{P},
    pool_id::UInt64,
    session_id::UInt64) where {P}
    isempty(payloads) && throw(OwnershipError(
        :payload_pool,
        :invalid_capacity,
        "payload-pool capacity must be positive"))
    length(payloads) <= typemax(UInt32) || throw(OwnershipError(
        :payload_pool,
        :capacity_exceeds_slot_identity,
        "payload-pool capacity exceeds the UInt32 slot identity"))
    pool_id != zero(UInt64) || throw(OwnershipError(
        :payload_pool,
        :invalid_pool_id,
        "payload-pool identity must be nonzero"))
    session_id != zero(UInt64) || throw(OwnershipError(
        :payload_pool,
        :invalid_session_id,
        "payload-pool session identity must be nonzero"))

    capacity = length(payloads)
    payload_storage = Memory{P}(undef, capacity)
    copyto!(payload_storage, payloads)
    generations = Memory{UInt64}(undef, capacity)
    fill!(generations, zero(UInt64))
    states = AtomicMemory{UInt8}(undef, capacity)
    for slot in eachindex(states)
        @atomic :monotonic states[slot] = _PAYLOAD_FREE
    end
    return PayloadPool{P}(
        payload_storage, generations, states, pool_id, session_id)
end

"""Return the number of prepared payload slots."""
payload_pool_capacity(pool::PayloadPool) = length(pool.payloads)

"""Return the stable declared identity of `pool`."""
payload_pool_id(pool::PayloadPool) = pool.pool_id

"""Return the stable run/session identity of `pool`."""
payload_session_id(pool::PayloadPool) = pool.session_id

@inline function _lease_identity_status(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    lease.pool_id == pool.pool_id || return WrongPayloadPool
    lease.session_id == pool.session_id || return WrongPayloadSession
    (lease.slot != zero(UInt32) &&
     UInt64(lease.slot) <= UInt64(length(pool.payloads))) ||
        return InvalidPayloadSlot
    lease.generation != zero(UInt64) || return StalePayloadLease
    return PayloadTransitionSucceeded
end

@inline function _lease_state_status(
    pool::PayloadPool,
    lease::PayloadLeaseRef,
    expected_state::UInt8)
    identity_status = _lease_identity_status(pool, lease)
    identity_status == PayloadTransitionSucceeded || return identity_status

    slot = Int(lease.slot)
    state = @atomic :acquire pool.states[slot]
    @inbounds generation = pool.generations[slot]
    generation == lease.generation || return StalePayloadLease
    state == expected_state || return WrongPayloadOwner
    return PayloadTransitionSucceeded
end

"""
    try_claim_payload!(output, pool)

Claim one free payload for the single producer and write its immutable reference
to caller-owned `output`. The scan is bounded by prepared capacity and performs
no compare-and-swap retry: only the producer claims free slots.
"""
function try_claim_payload!(
    output::Base.RefValue{PayloadLeaseRef},
    pool::PayloadPool)
    for slot in eachindex(pool.payloads)
        state = @atomic :acquire pool.states[slot]
        state == _PAYLOAD_FREE || continue

        @inbounds generation = pool.generations[slot]
        generation != typemax(UInt64) ||
            return PayloadGenerationExhausted
        next_generation = generation + one(UInt64)
        @inbounds pool.generations[slot] = next_generation
        @atomic :release pool.states[slot] = _PAYLOAD_PRODUCER_OWNED
        output[] = PayloadLeaseRef(
            pool.pool_id,
            pool.session_id,
            UInt32(slot),
            next_generation)
        return PayloadTransitionSucceeded
    end
    return PayloadPoolExhausted
end

function _payload_access_error(
    operation::Symbol,
    status::PayloadStatus)
    return OwnershipError(
        :payload_pool,
        Symbol(operation, :_, Symbol(lowercase(string(status)))),
        "payload lease does not have the required identity, generation, or owner")
end

"""
    producer_payload(pool, lease)

Return the exact caller-supplied payload while `lease` is producer-owned.
"""
function producer_payload(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    status =
        _lease_state_status(pool, lease, _PAYLOAD_PRODUCER_OWNED)
    status == PayloadTransitionSucceeded ||
        throw(_payload_access_error(:producer_access, status))
    @inbounds return pool.payloads[Int(lease.slot)]
end

"""
    queue_payload!(pool, lease)

Release-publish a completed producer-owned payload before its descriptor is
published to a ring.
"""
function queue_payload!(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    status =
        _lease_state_status(pool, lease, _PAYLOAD_PRODUCER_OWNED)
    status == PayloadTransitionSucceeded || return status
    @atomic :release pool.states[Int(lease.slot)] = _PAYLOAD_QUEUED
    return PayloadTransitionSucceeded
end

"""
    abort_payload!(pool, lease)

Return a producer-owned payload directly to the free state before publication.
"""
function abort_payload!(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    status =
        _lease_state_status(pool, lease, _PAYLOAD_PRODUCER_OWNED)
    status == PayloadTransitionSucceeded || return status
    @atomic :release pool.states[Int(lease.slot)] = _PAYLOAD_FREE
    return PayloadTransitionSucceeded
end

"""
    lease_payload!(pool, lease)

Acquire a queued payload for the single consumer.
"""
function lease_payload!(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    status = _lease_state_status(pool, lease, _PAYLOAD_QUEUED)
    status == PayloadTransitionSucceeded || return status
    @atomic :release pool.states[Int(lease.slot)] =
        _PAYLOAD_CONSUMER_LEASED
    return PayloadTransitionSucceeded
end

"""
    consumer_payload(pool, lease)

Return the exact caller-supplied payload while `lease` is consumer-leased.
"""
function consumer_payload(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    status =
        _lease_state_status(pool, lease, _PAYLOAD_CONSUMER_LEASED)
    status == PayloadTransitionSucceeded ||
        throw(_payload_access_error(:consumer_access, status))
    @inbounds return pool.payloads[Int(lease.slot)]
end

"""
    release_payload!(pool, lease)

Release one consumer lease back to the pool. Wrong pool, wrong session, invalid
slot, stale generation, duplicate release, and wrong ownership all return
distinct non-mutating statuses.
"""
function release_payload!(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    identity_status = _lease_identity_status(pool, lease)
    identity_status == PayloadTransitionSucceeded || return identity_status

    slot = Int(lease.slot)
    state = @atomic :acquire pool.states[slot]
    @inbounds generation = pool.generations[slot]
    generation == lease.generation || return StalePayloadLease
    state == _PAYLOAD_FREE && return DuplicatePayloadRelease
    state == _PAYLOAD_CONSUMER_LEASED || return WrongPayloadOwner

    @atomic :release pool.states[slot] = _PAYLOAD_FREE
    return PayloadTransitionSucceeded
end

"""
Cold snapshot of the four payload ownership states.
"""
struct PayloadPoolAccounting
    capacity::Int
    free::Int
    producer_owned::Int
    queued::Int
    consumer_leased::Int
end

"""
    payload_pool_accounting(pool)

Inspect every slot atomically and return a cold accounting snapshot. The sum of
the four state counts always equals capacity unless internal state is corrupt.
"""
function payload_pool_accounting(pool::PayloadPool)
    free = 0
    producer_owned = 0
    queued = 0
    consumer_leased = 0
    for slot in eachindex(pool.states)
        state = @atomic :acquire pool.states[slot]
        if state == _PAYLOAD_FREE
            free += 1
        elseif state == _PAYLOAD_PRODUCER_OWNED
            producer_owned += 1
        elseif state == _PAYLOAD_QUEUED
            queued += 1
        elseif state == _PAYLOAD_CONSUMER_LEASED
            consumer_leased += 1
        else
            throw(OwnershipError(
                :payload_pool,
                :invalid_ownership_state,
                "payload pool contains an invalid ownership state"))
        end
    end
    return PayloadPoolAccounting(
        length(pool.payloads),
        free,
        producer_owned,
        queued,
        consumer_leased)
end

"""
    validate_quiescent_pool(pool)

Return the accounting snapshot when every slot is free; otherwise throw a
structured ownership error. External orchestration establishes quiescence.
"""
function validate_quiescent_pool(pool::PayloadPool)
    accounting = payload_pool_accounting(pool)
    accounting.free == accounting.capacity || throw(OwnershipError(
        :payload_pool,
        :not_quiescent,
        "payload pool still owns or leases one or more payloads"))
    return accounting
end

end
