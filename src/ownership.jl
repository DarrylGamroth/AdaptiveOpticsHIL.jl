"""
    Ownership

Fixed-capacity, transport-neutral ownership primitives for warmed HIL
boundaries. Compact, concrete, immutable descriptors cross a bounded
single-producer, single-consumer ring; large mutable payloads remain in a
separately prepared, generation-checked pool.

Ring operations never wait, yield, retry, invoke callbacks, or allocate after
preparation. An idle or retry policy belongs to the caller.
"""
module Ownership

import ..AdaptiveOpticsHIL: AdaptiveOpticsHILError

export OwnershipError
export RingStatus, RingTransferSucceeded, RingFull, RingEmpty, RingClosed
export RingBatchResult, RingAccounting
export SPSCLayoutContract, SPSCDescriptorRing
export close_ring!, ring_accounting, ring_capacity, ring_is_closed
export try_submit!, try_take!, try_take_batch!
export PayloadStatus
export PayloadTransitionSucceeded, PayloadPoolExhausted
export PayloadPoolClosed
export WrongPayloadPool, WrongPayloadSession, InvalidPayloadSlot
export StalePayloadLease, WrongPayloadOwner, DuplicatePayloadRelease
export PayloadGenerationExhausted
export PayloadReturnCreditUnavailable, PayloadReturnPathClosed
export PayloadLeaseRef, PayloadPool, PayloadPoolAccounting
export PayloadPoolCapacityContract, PayloadPoolDeficit
export PayloadPoolCloseStatus
export PayloadPoolCloseSucceeded, PayloadPoolAlreadyClosed
export PayloadPoolLifecycleState
export PayloadPoolAccepting, PayloadPoolDraining, PayloadPoolDrained
export abort_payload!, consumer_payload, lease_payload!, payload_generation
export close_payload_pool!
export payload_pool_accounting, payload_pool_capacity, payload_pool_id
export payload_pool_lifecycle_state
export payload_session_id, payload_slot, producer_payload, queue_payload!
export close_payload_returns!, payload_pool_capacity_contract
export payload_pool_deficit, payload_return_accounting
export reclaim_payload_returns!, release_payload!, try_claim_payload!
export validate_quiescent_pool

public MAX_SUPPORTED_CACHE_LINE_BYTES, SPSCLayoutEvidence
public maximum_cache_line_bytes, ring_layout_contract, validate_ring_layout

"""Invalid ownership configuration, access, state, or accounting."""
struct OwnershipError <: AdaptiveOpticsHILError
    component::Symbol
    reason::Symbol
    msg::String
end

"""
Largest cache-line size, in bytes, supported by the prepared SPSC cursor
layout.

The maintained x86-64 and Apple Silicon targets use 64- or 128-byte cache
lines. A target with a larger line requires a different cursor layout.
"""
const MAX_SUPPORTED_CACHE_LINE_BYTES = 128
const _MIN_SUPPORTED_CACHE_LINE_BYTES = 64

const _WORD_BYTES = sizeof(UInt64)
const _PREFIX_WORDS = MAX_SUPPORTED_CACHE_LINE_BYTES ÷ _WORD_BYTES
const _OWNER_SECTION_WORDS = 2 * _PREFIX_WORDS
const _BETWEEN_OWNER_WORDS = _OWNER_SECTION_WORDS - 3

@inline _zero_words(::Val{N}) where {N} =
    ntuple(_ -> zero(UInt64), Val(N))

"""
    SPSCLayoutContract([maximum_cache_line_bytes])

Prepared target contract for an `SPSCDescriptorRing`. The declared value is an
upper bound on the target's coherent cache-line size, not a runtime discovery
mechanism. Maintained contracts accept power-of-two bounds from 64 through 128
bytes. Proving the layout against 128 bytes also proves isolation for a
64-byte-line target.
"""
struct SPSCLayoutContract
    maximum_cache_line_bytes::Int

    function SPSCLayoutContract(
        maximum_cache_line_bytes::Integer=
            MAX_SUPPORTED_CACHE_LINE_BYTES)
        (
            maximum_cache_line_bytes >=
                _MIN_SUPPORTED_CACHE_LINE_BYTES &&
            maximum_cache_line_bytes <=
                MAX_SUPPORTED_CACHE_LINE_BYTES &&
            ispow2(maximum_cache_line_bytes)
        ) || throw(OwnershipError(
            :descriptor_ring_layout,
            :invalid_cache_line_upper_bound,
            "cache-line upper bound must be a power of two from 64 through 128 bytes"))
        return new(Int(maximum_cache_line_bytes))
    end
end

"""Return the cache-line upper bound declared by `contract`."""
maximum_cache_line_bytes(contract::SPSCLayoutContract) =
    contract.maximum_cache_line_bytes

"""
Cold structural evidence returned by `validate_ring_layout`.

`object_base_modulo` records the actual cursor-object address modulo the
declared cache-line upper bound. The remaining offsets are byte offsets from
that address. Together they permit independent reconstruction of field
alignment, line membership, separation, and boundary padding without exposing
an unstable absolute address.
"""
struct SPSCLayoutEvidence
    maximum_cache_line_bytes::Int
    cursor_storage_bytes::Int
    object_base_modulo::Int
    producer_sequence_offset::Int
    producer_cached_consumer_sequence_offset::Int
    producer_slot_offset::Int
    consumer_sequence_offset::Int
    consumer_cached_producer_sequence_offset::Int
    consumer_slot_offset::Int
    closed_offset::Int
end

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
# one maximum line from the allocation boundary. Each owner section spans two
# maximum lines so its cached remote cursor and local slot cannot spill into the
# next owner's publication line under a merely word-aligned object allocation.
# Lifecycle state occupies a separately written line after both owner sections.
mutable struct _SPSCCursors
    prefix::NTuple{_PREFIX_WORDS,UInt64}
    @atomic producer_sequence::UInt64
    producer_cached_consumer_sequence::UInt64
    producer_slot::UInt64
    producer_consumer_gap::NTuple{_BETWEEN_OWNER_WORDS,UInt64}
    @atomic consumer_sequence::UInt64
    consumer_cached_producer_sequence::UInt64
    consumer_slot::UInt64
    consumer_closed_gap::NTuple{_BETWEEN_OWNER_WORDS,UInt64}
    @atomic closed::UInt64
    suffix::NTuple{_PREFIX_WORDS,UInt64}
end

function _SPSCCursors()
    prefix_padding = _zero_words(Val(_PREFIX_WORDS))
    between_owner_padding = _zero_words(Val(_BETWEEN_OWNER_WORDS))
    return _SPSCCursors(
        prefix_padding,
        zero(UInt64),
        zero(UInt64),
        one(UInt64),
        between_owner_padding,
        zero(UInt64),
        zero(UInt64),
        one(UInt64),
        between_owner_padding,
        zero(UInt64),
        prefix_padding)
end

"""
    SPSCDescriptorRing{T}(capacity[, layout_contract])

Prepare fixed storage for `capacity` compact descriptors of concrete immutable
type `T`. The type must use Julia's inline array representation; it may contain
immutable references such as stable `Symbol`-backed identities. Exactly one
logical producer may call `try_submit!` and `close_ring!`; exactly one logical
consumer may call `try_take!` or `try_take_batch!`.

The owner restriction is stronger than task or thread identity: callers must
not concurrently invoke one side from several tasks even if those tasks happen
to execute on one thread. Preparation validates the actual cursor-object
address against `layout_contract` before returning.
"""
struct SPSCDescriptorRing{T}
    slots::Memory{T}
    capacity::UInt64
    cursors::_SPSCCursors
    layout_contract::SPSCLayoutContract
end

function SPSCDescriptorRing{T}(
    capacity::Integer,
    layout_contract::SPSCLayoutContract=
        SPSCLayoutContract()) where {T}
    isconcretetype(T) || throw(OwnershipError(
        :descriptor_ring,
        :abstract_descriptor,
        "SPSC descriptor type must be concrete"))
    ismutabletype(T) && throw(OwnershipError(
        :descriptor_ring,
        :mutable_descriptor,
        "SPSC descriptor type must be immutable"))
    Base.allocatedinline(T) || throw(OwnershipError(
        :descriptor_ring,
        :boxed_descriptor,
        "SPSC descriptor type must use Julia's inline array representation"))
    capacity > 0 || throw(OwnershipError(
        :descriptor_ring,
        :invalid_capacity,
        "SPSC descriptor-ring capacity must be positive"))
    capacity <= typemax(Int) || throw(OwnershipError(
        :descriptor_ring,
        :capacity_exceeds_address_space,
        "SPSC descriptor-ring capacity exceeds the addressable or signed sequence bound"))

    capacity_int = Int(capacity)
    ring = SPSCDescriptorRing{T}(
        Memory{T}(undef, capacity_int),
        UInt64(capacity_int),
        _SPSCCursors(),
        layout_contract)
    validate_ring_layout(ring)
    return ring
end

"""Return the prepared descriptor capacity."""
ring_capacity(ring::SPSCDescriptorRing) = Int(ring.capacity)

"""Return the prepared cache-line contract for `ring`."""
ring_layout_contract(ring::SPSCDescriptorRing) = ring.layout_contract

# Prepared slot cursors are always in `1:ring.capacity`, and capacity is
# constructor-checked against `typemax(Int)`. Keeping slot traversal separate
# from the wrapping publication sequence makes arbitrary capacities correct at
# the UInt64 sequence boundary and removes division from descriptor transfer.
@inline _ring_slot_index(slot::UInt64) =
    signed(slot)

@inline _next_ring_slot(slot::UInt64, capacity::UInt64) =
    ifelse(slot == capacity, one(UInt64), slot + one(UInt64))

@inline function _ring_closed(cursors::_SPSCCursors)
    return (@atomic :acquire cursors.closed) != zero(UInt64)
end

"""Return whether the producer has closed the ring to new submissions."""
ring_is_closed(ring::SPSCDescriptorRing) = _ring_closed(ring.cursors)

"""
Internal producer-side availability check used to compose a descriptor-ring
publication with other ownership transitions. The single-producer contract
guarantees that capacity cannot decrease between this check and the producer's
immediately following `try_submit!`; the consumer can only reclaim capacity.
"""
@inline function _producer_submission_status(ring::SPSCDescriptorRing)
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
    return RingTransferSucceeded
end

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

    producer_slot = cursors.producer_slot
    slot = _ring_slot_index(producer_slot)
    @inbounds ring.slots[slot] = descriptor
    cursors.producer_slot =
        _next_ring_slot(producer_slot, ring.capacity)
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

    consumer_slot = cursors.consumer_slot
    slot = _ring_slot_index(consumer_slot)
    @inbounds output[] = ring.slots[slot]
    cursors.consumer_slot =
        _next_ring_slot(consumer_slot, ring.capacity)
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
    consumer_slot = cursors.consumer_slot
    @inbounds for offset in 0:(count - 1)
        slot = _ring_slot_index(consumer_slot)
        destination[destination_index + offset] = ring.slots[slot]
        consumer_slot =
            _next_ring_slot(consumer_slot, ring.capacity)
    end
    cursors.consumer_slot = consumer_slot
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

@inline function _cursor_field_offset(field::Symbol)
    index = Base.fieldindex(_SPSCCursors, field)
    return Int(fieldoffset(_SPSCCursors, index))
end

@noinline function _layout_error(reason::Symbol, msg::String)
    throw(OwnershipError(:descriptor_ring_layout, reason, msg))
end

@inline _layout_line(
    evidence::SPSCLayoutEvidence,
    offset::Int) =
    fld(evidence.object_base_modulo + offset,
        evidence.maximum_cache_line_bytes)

function _validate_spsc_layout_evidence(
    contract::SPSCLayoutContract,
    evidence::SPSCLayoutEvidence)
    line_bytes = maximum_cache_line_bytes(contract)
    evidence.maximum_cache_line_bytes == line_bytes ||
        _layout_error(
            :layout_contract_mismatch,
            "layout evidence does not match the prepared cache-line contract")
    0 <= evidence.object_base_modulo < line_bytes ||
        _layout_error(
            :invalid_object_address_modulo,
            "cursor-object address modulo is outside the declared cache line")

    storage_bytes = evidence.cursor_storage_bytes
    storage_bytes >= 6 * line_bytes ||
        _layout_error(
            :insufficient_cursor_storage,
            "cursor storage is too small for isolated owner sections, lifecycle state, and boundary padding")

    producer_sequence = evidence.producer_sequence_offset
    producer_cache =
        evidence.producer_cached_consumer_sequence_offset
    producer_slot = evidence.producer_slot_offset
    consumer_sequence = evidence.consumer_sequence_offset
    consumer_cache =
        evidence.consumer_cached_producer_sequence_offset
    consumer_slot = evidence.consumer_slot_offset
    closed = evidence.closed_offset

    for offset in (
        producer_sequence,
        producer_cache,
        producer_slot,
        consumer_sequence,
        consumer_cache,
        consumer_slot,
        closed)
        (
            offset >= 0 &&
            offset <= storage_bytes - _WORD_BYTES
        ) || _layout_error(
            :atomic_field_outside_storage,
            "cursor field falls outside the cursor object")
        (evidence.object_base_modulo + offset) % _WORD_BYTES == 0 ||
            _layout_error(
                :misaligned_atomic_field,
                "cursor field is not naturally aligned for UInt64 atomic access")
        _layout_line(evidence, offset) ==
            _layout_line(evidence, offset + _WORD_BYTES - 1) ||
            _layout_error(
                :atomic_field_straddles_cache_line,
                "cursor field straddles the declared cache-line boundary")
    end

    (
        producer_sequence + _WORD_BYTES <= producer_cache &&
        producer_cache + _WORD_BYTES <= producer_slot &&
        producer_slot + _WORD_BYTES <= consumer_sequence &&
        consumer_sequence + _WORD_BYTES <= consumer_cache &&
        consumer_cache + _WORD_BYTES <= consumer_slot &&
        consumer_slot + _WORD_BYTES <= closed
    ) || _layout_error(
        :overlapping_cursor_fields,
        "cursor fields overlap or are not in producer/consumer/lifecycle order")

    producer_line = _layout_line(evidence, producer_sequence)
    producer_cache_line = _layout_line(evidence, producer_cache)
    producer_slot_line = _layout_line(evidence, producer_slot)
    consumer_line = _layout_line(evidence, consumer_sequence)
    consumer_cache_line = _layout_line(evidence, consumer_cache)
    consumer_slot_line = _layout_line(evidence, consumer_slot)
    closed_line = _layout_line(evidence, closed)

    (
        consumer_sequence - producer_sequence >= 2 * line_bytes &&
        closed - consumer_sequence >= 2 * line_bytes &&
        producer_line != consumer_line &&
        producer_line != consumer_cache_line &&
        producer_line != consumer_slot_line &&
        producer_cache_line != consumer_line &&
        producer_cache_line != consumer_cache_line &&
        producer_cache_line != consumer_slot_line &&
        producer_slot_line != consumer_line &&
        producer_slot_line != consumer_cache_line &&
        producer_slot_line != consumer_slot_line &&
        producer_line != closed_line &&
        producer_cache_line != closed_line &&
        producer_slot_line != closed_line &&
        consumer_line != closed_line &&
        consumer_cache_line != closed_line &&
        consumer_slot_line != closed_line
    ) || _layout_error(
        :insufficient_publication_separation,
        "producer-owned, consumer-owned, and closure fields do not occupy isolated cache lines")

    (
        producer_sequence >= line_bytes &&
        storage_bytes - (closed + _WORD_BYTES) >= line_bytes
    ) || _layout_error(
        :insufficient_boundary_padding,
        "publication fields are not isolated from both cursor-object boundaries")

    return evidence
end

"""
    validate_ring_layout(ring)

Verify the actual cursor-object address, field offsets, natural atomic
alignment, cache-line membership, publication-field separation, and boundary
padding against the prepared contract. This is a cold preparation/diagnostic
operation; it is not part of descriptor transfer. The evidence remains valid
because maintained Julia runtimes use nonmoving heap storage for the mutable
cursor object.
"""
function validate_ring_layout(ring::SPSCDescriptorRing)
    contract = ring.layout_contract
    line_bytes = maximum_cache_line_bytes(contract)
    cursors = ring.cursors
    object_base_modulo = GC.@preserve cursors begin
        address = UInt(pointer_from_objref(cursors))
        Int(rem(address, UInt(line_bytes)))
    end
    evidence = SPSCLayoutEvidence(
        line_bytes,
        sizeof(_SPSCCursors),
        object_base_modulo,
        _cursor_field_offset(:producer_sequence),
        _cursor_field_offset(:producer_cached_consumer_sequence),
        _cursor_field_offset(:producer_slot),
        _cursor_field_offset(:consumer_sequence),
        _cursor_field_offset(:consumer_cached_producer_sequence),
        _cursor_field_offset(:consumer_slot),
        _cursor_field_offset(:closed))
    return _validate_spsc_layout_evidence(contract, evidence)
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
    PayloadReturnCreditUnavailable = 0x0a
    PayloadReturnPathClosed = 0x0b
    PayloadPoolClosed = 0x0c
end

const _PAYLOAD_FREE = UInt8(0)
const _PAYLOAD_PRODUCER_OWNED = UInt8(1)
const _PAYLOAD_QUEUED = UInt8(2)
const _PAYLOAD_CONSUMER_LEASED = UInt8(3)
const _PAYLOAD_RETURN_QUEUED = UInt8(4)

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
    PayloadPool(payloads, pool_id, session_id;
        return_capacity=length(payloads))

Prepare a bounded pool over caller-supplied payload buffers. The container of
payload references is copied, not the payload buffers themselves. The caller
must relinquish mutation through retained aliases while a buffer is owned by
the pool. `pool_id` must be unique among all pools in the same run/session;
cross-pool uniqueness is a preparation responsibility rather than a global
runtime registry.

The pool prepares one SPSC lease-return descriptor for every payload slot.
The final consumer release-publishes into that ring, and the single pool owner
reclaims returned leases before reusing storage. `return_capacity` may be
larger than the payload capacity but never smaller: every legal simultaneous
consumer lease has reserved return credit.
"""
mutable struct _PayloadPoolOwnerState
    return_scratch::Base.RefValue{PayloadLeaseRef}
    reclaimed::UInt64
    @atomic claims_closed::UInt64
end

struct PayloadPool{P}
    payloads::Memory{P}
    generations::Memory{UInt64}
    states::AtomicMemory{UInt8}
    pool_id::UInt64
    session_id::UInt64
    return_ring::SPSCDescriptorRing{PayloadLeaseRef}
    owner_state::_PayloadPoolOwnerState
end

@inline _payload_capacity_is_bool(::Bool) = true
@inline _payload_capacity_is_bool(::Integer) = false

function PayloadPool(
    payloads::AbstractVector{P},
    pool_id::UInt64,
    session_id::UInt64;
    return_capacity::Integer=length(payloads)) where {P}
    _payload_capacity_is_bool(return_capacity) && throw(OwnershipError(
        :payload_pool,
        :invalid_return_capacity,
        "lease-return capacity must be an integer count, not Bool"))
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
    return_capacity >= capacity || throw(OwnershipError(
        :payload_pool,
        :insufficient_return_capacity,
        "lease-return capacity must cover every payload slot that may be consumer-leased"))
    return_capacity <= typemax(Int) || throw(OwnershipError(
        :payload_pool,
        :return_capacity_exceeds_address_space,
        "lease-return capacity exceeds the addressable range"))
    payload_storage = Memory{P}(undef, capacity)
    copyto!(payload_storage, payloads)
    generations = Memory{UInt64}(undef, capacity)
    fill!(generations, zero(UInt64))
    states = AtomicMemory{UInt8}(undef, capacity)
    for slot in eachindex(states)
        @atomic :monotonic states[slot] = _PAYLOAD_FREE
    end
    return PayloadPool{P}(
        payload_storage,
        generations,
        states,
        pool_id,
        session_id,
        SPSCDescriptorRing{PayloadLeaseRef}(Int(return_capacity)),
        _PayloadPoolOwnerState(
            Ref(PayloadLeaseRef(0, 0, 0, 0)),
            zero(UInt64),
            zero(UInt64)))
end

"""Return the number of prepared payload slots."""
payload_pool_capacity(pool::PayloadPool) = length(pool.payloads)

"""Return the stable declared identity of `pool`."""
payload_pool_id(pool::PayloadPool) = pool.pool_id

"""Return the stable run/session identity of `pool`."""
payload_session_id(pool::PayloadPool) = pool.session_id

"""
Prepared capacity proof for one payload pool and its lease-return path.

`maximum_consumer_leases` equals the pool capacity because every slot may
legally reach the consumer-owned state. `return_capacity` is therefore at
least that large.
"""
struct PayloadPoolCapacityContract
    capacity::Int
    maximum_consumer_leases::Int
    return_capacity::Int
end

"""Return the prepared slot and lease-return capacity proof."""
function payload_pool_capacity_contract(pool::PayloadPool)
    capacity = payload_pool_capacity(pool)
    return PayloadPoolCapacityContract(
        capacity,
        capacity,
        ring_capacity(pool.return_ring))
end

"""Return a cold snapshot of the pool's reserved lease-return ring."""
payload_return_accounting(pool::PayloadPool) =
    ring_accounting(pool.return_ring)

"""
Lifecycle of producer claims for one payload pool.

Closing claims prevents new producer ownership but does not revoke any existing
producer, queued, consumer, or return-queued ownership.
"""
@enum PayloadPoolLifecycleState::UInt8 begin
    PayloadPoolAccepting = 0x01
    PayloadPoolDraining = 0x02
    PayloadPoolDrained = 0x03
end

"""Result of closing a payload pool to new producer claims."""
@enum PayloadPoolCloseStatus::UInt8 begin
    PayloadPoolCloseSucceeded = 0x01
    PayloadPoolAlreadyClosed = 0x02
end

@inline function _payload_claims_are_closed(pool::PayloadPool)
    return (@atomic :acquire pool.owner_state.claims_closed) !=
        zero(UInt64)
end

"""Close a pool to new producer claims without revoking existing ownership."""
function close_payload_pool!(pool::PayloadPool)
    owner_state = pool.owner_state
    (@atomic :monotonic owner_state.claims_closed) == zero(UInt64) ||
        return PayloadPoolAlreadyClosed
    @atomic :release owner_state.claims_closed = one(UInt64)
    return PayloadPoolCloseSucceeded
end

"""Return the cold accepting/draining/drained producer-claim lifecycle."""
function payload_pool_lifecycle_state(pool::PayloadPool)
    _payload_claims_are_closed(pool) || return PayloadPoolAccepting
    accounting = payload_pool_accounting(pool)
    returns = payload_return_accounting(pool)
    (
        accounting.free == accounting.capacity &&
        iszero(returns.occupancy)
    ) && return PayloadPoolDrained
    return PayloadPoolDraining
end

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
    (@atomic :acquire pool.owner_state.claims_closed) ==
        zero(UInt64) || return PayloadPoolClosed
    reclaim_payload_returns!(pool)
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

@inline function _payload_return_status(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    identity_status = _lease_identity_status(pool, lease)
    identity_status == PayloadTransitionSucceeded || return identity_status

    slot = Int(lease.slot)
    state = @atomic :acquire pool.states[slot]
    @inbounds generation = pool.generations[slot]
    generation == lease.generation || return StalePayloadLease
    (state == _PAYLOAD_FREE || state == _PAYLOAD_RETURN_QUEUED) &&
        return DuplicatePayloadRelease
    state == _PAYLOAD_CONSUMER_LEASED || return WrongPayloadOwner

    return_status = _producer_submission_status(pool.return_ring)
    return_status == RingFull && return PayloadReturnCreditUnavailable
    return_status == RingClosed && return PayloadReturnPathClosed
    return PayloadTransitionSucceeded
end

@inline function _publish_payload_return!(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    slot = Int(lease.slot)
    @atomic :release pool.states[slot] = _PAYLOAD_RETURN_QUEUED
    return_status = try_submit!(pool.return_ring, lease)
    return_status == RingTransferSucceeded ||
        _payload_return_publication_error()
    return PayloadTransitionSucceeded
end

@noinline function _payload_return_publication_error()
    throw(OwnershipError(
        :payload_pool,
        :return_publication_invariant,
        "reserved lease-return publication failed after successful preflight"))
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

Release-publish one consumer lease into its reserved return path. The payload
becomes reusable only when the pool owner reclaims it. Wrong pool, wrong
session, invalid slot, stale generation, duplicate release, wrong ownership,
and return-path invariant failures return distinct non-mutating statuses.
"""
function release_payload!(
    pool::PayloadPool,
    lease::PayloadLeaseRef)
    status = _payload_return_status(pool, lease)
    status == PayloadTransitionSucceeded || return status
    return _publish_payload_return!(pool, lease)
end

"""
    reclaim_payload_returns!(pool[, max_items])

Drain at most `max_items` already published lease returns for the single pool
owner. Reclamation is bounded, nonblocking, and allocation-free after
preparation. A successful result reports the number reclaimed; an empty or
closed result reports zero.
"""
function reclaim_payload_returns!(
    pool::PayloadPool,
    max_items::Integer=payload_pool_capacity(pool))
    max_items > 0 || _payload_reclaim_count_error(:not_positive)
    max_items <= typemax(Int) ||
        _payload_reclaim_count_error(:exceeds_address_space)
    maximum = min(Int(max_items), payload_pool_capacity(pool))
    reclaimed = 0
    scratch = pool.owner_state
    while reclaimed < maximum
        status = try_take!(scratch.return_scratch, pool.return_ring)
        if status != RingTransferSucceeded
            return reclaimed == 0 ?
                RingBatchResult(status, 0) :
                RingBatchResult(RingTransferSucceeded, reclaimed)
        end
        lease = scratch.return_scratch[]
        lease_status =
            _lease_state_status(pool, lease, _PAYLOAD_RETURN_QUEUED)
        lease_status == PayloadTransitionSucceeded ||
            _payload_return_reclamation_error()
        @atomic :release pool.states[Int(lease.slot)] = _PAYLOAD_FREE
        scratch.reclaimed += one(UInt64)
        reclaimed += 1
    end
    return RingBatchResult(RingTransferSucceeded, reclaimed)
end

@noinline function _payload_reclaim_count_error(reason::Symbol)
    message = reason == :not_positive ?
        "max_items must be positive" :
        "max_items exceeds the addressable range"
    throw(ArgumentError(message))
end

@noinline function _payload_return_reclamation_error()
    throw(OwnershipError(
        :payload_pool,
        :return_reclamation_invariant,
        "lease-return descriptor does not identify a return-queued payload"))
end

reclaim_payload_returns!(
    ::PayloadPool,
    ::Bool) =
    _payload_reclaim_bool_error()

@noinline _payload_reclaim_bool_error() =
    throw(ArgumentError("max_items must be an integer count, not Bool"))

"""
    close_payload_returns!(pool)

Close the consumer-to-owner return path only after producer claims are closed
and no producer-owned, queued, or consumer-leased slot can create another
return. Already published returns remain drainable by
`reclaim_payload_returns!`.
"""
function close_payload_returns!(pool::PayloadPool)
    _payload_claims_are_closed(pool) || throw(OwnershipError(
        :payload_pool,
        :claims_still_accepting,
        "payload-pool claims must close before its lease-return path"))
    accounting = payload_pool_accounting(pool)
    (
        iszero(accounting.producer_owned) &&
        iszero(accounting.queued) &&
        iszero(accounting.consumer_leased)
    ) || throw(OwnershipError(
        :payload_pool,
        :outstanding_return_obligations,
        "lease-return path cannot close while a payload may still require return"))
    return close_ring!(pool.return_ring)
end

"""
Cold snapshot of the five payload ownership states plus successful owner
reclamation counted modulo `UInt64`.
"""
struct PayloadPoolAccounting
    capacity::Int
    free::Int
    producer_owned::Int
    queued::Int
    consumer_leased::Int
    return_queued::Int
    reclaimed::UInt64
end

"""
    payload_pool_accounting(pool)

Inspect every slot atomically and return a cold accounting snapshot. The sum of
the five state counts always equals capacity unless internal state is corrupt.
External quiescence is required to compare `return_queued` with the return-ring
occupancy.
"""
function payload_pool_accounting(pool::PayloadPool)
    free = 0
    producer_owned = 0
    queued = 0
    consumer_leased = 0
    return_queued = 0
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
        elseif state == _PAYLOAD_RETURN_QUEUED
            return_queued += 1
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
        consumer_leased,
        return_queued,
        pool.owner_state.reclaimed)
end

"""
Bounded cold ownership-deficit report.

`deficit` is the number of slots not yet free. During an active run that
number is ordinary in-flight ownership; it becomes a shutdown deficit only
after orchestration has ended publication and bounded draining. The individual
state counts preserve where each missing slot remains.
"""
struct PayloadPoolDeficit
    capacity::Int
    deficit::Int
    producer_owned::Int
    queued::Int
    consumer_leased::Int
    return_queued::Int
end

"""Return a bounded cold report of every slot not currently free."""
function payload_pool_deficit(pool::PayloadPool)
    accounting = payload_pool_accounting(pool)
    return PayloadPoolDeficit(
        accounting.capacity,
        accounting.capacity - accounting.free,
        accounting.producer_owned,
        accounting.queued,
        accounting.consumer_leased,
        accounting.return_queued)
end

"""
    validate_quiescent_pool(pool)

Return the accounting snapshot when every slot is free; otherwise throw a
structured ownership error. External orchestration establishes quiescence.
"""
function validate_quiescent_pool(pool::PayloadPool)
    accounting = payload_pool_accounting(pool)
    returns = payload_return_accounting(pool)
    (
        accounting.free == accounting.capacity &&
        iszero(returns.occupancy)
    ) || throw(OwnershipError(
        :payload_pool,
        :not_quiescent,
        "payload pool still owns, leases, or queues one or more payloads"))
    return accounting
end

end
