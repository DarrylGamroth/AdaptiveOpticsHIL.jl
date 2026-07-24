using AdaptiveOpticsHIL.Ownership

const OWNERSHIP_TESTS_WITH_COVERAGE =
    Base.JLOptions().code_coverage != 0

struct HugePayloadVector <: AbstractVector{UInt8} end

Base.size(::HugePayloadVector) = (Int(typemax(UInt32)) + 1,)
Base.getindex(::HugePayloadVector, ::Int) = UInt8(0)

abstract type AbstractTestDescriptor end

mutable struct MutableTestDescriptor
    value::UInt64
end

struct SymbolicTestDescriptor
    endpoint::Symbol
    sequence::UInt64
end

function ring_allocation_bytes(
    ring::SPSCDescriptorRing{UInt64},
    output::Base.RefValue{UInt64})
    try_submit!(ring, UInt64(11))
    try_take!(output, ring)
    submit_bytes = @allocated try_submit!(ring, UInt64(12))
    take_bytes = @allocated try_take!(output, ring)
    return submit_bytes, take_bytes
end

function payload_allocation_bytes(
    pool::PayloadPool,
    output::Base.RefValue{PayloadLeaseRef})
    try_claim_payload!(output, pool)
    lease = output[]
    producer_payload(pool, lease)[] = UInt64(1)
    queue_payload!(pool, lease)
    lease_payload!(pool, lease)
    consumer_payload(pool, lease)[]
    release_payload!(pool, lease)

    claim_bytes = @allocated try_claim_payload!(output, pool)
    lease = output[]
    producer_access_bytes = @allocated producer_payload(pool, lease)
    producer_payload(pool, lease)[] = UInt64(2)
    queue_bytes = @allocated queue_payload!(pool, lease)
    lease_bytes = @allocated lease_payload!(pool, lease)
    consumer_access_bytes = @allocated consumer_payload(pool, lease)
    release_bytes = @allocated release_payload!(pool, lease)
    return (
        claim_bytes,
        producer_access_bytes,
        queue_bytes,
        lease_bytes,
        consumer_access_bytes,
        release_bytes)
end

@testset "Bounded SPSC descriptor ring" begin
    @testset "Preparation and layout" begin
        @test_throws OwnershipError SPSCDescriptorRing{UInt64}(0)
        @test_throws OwnershipError SPSCDescriptorRing{
            AbstractTestDescriptor}(2)
        @test_throws OwnershipError SPSCDescriptorRing{
            MutableTestDescriptor}(2)
        @test_throws OwnershipError SPSCDescriptorRing{Vector{Int}}(2)
        @test_throws OwnershipError SPSCDescriptorRing{UInt64}(
            UInt128(typemax(Int)) + 1)

        ring = SPSCDescriptorRing{UInt64}(3)
        @test ring_capacity(ring) == 3
        @test ring_cursor_separation_bytes() >=
              CONSERVATIVE_CACHE_LINE_BYTES
        @test !ring_is_closed(ring)
        accounting = ring_accounting(ring)
        @test accounting ==
              RingAccounting(3, 0, UInt64(0), UInt64(0), false)
    end

    @testset "Inline symbolic descriptors" begin
        @test !isbitstype(SymbolicTestDescriptor)
        @test Base.allocatedinline(SymbolicTestDescriptor)
        ring = SPSCDescriptorRing{SymbolicTestDescriptor}(2)
        descriptor = SymbolicTestDescriptor(:dm_command, UInt64(17))
        output = Ref(descriptor)
        @test try_submit!(ring, descriptor) == RingTransferSucceeded
        @test try_take!(output, ring) == RingTransferSucceeded
        @test output[] == descriptor

        try_submit!(ring, descriptor)
        try_take!(output, ring)
        if OWNERSHIP_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test @allocated(try_submit!(ring, descriptor)) == 0
            @test @allocated(try_take!(output, ring)) == 0
        end
    end

    @testset "Empty, full, wraparound, and slot reuse" begin
        ring = SPSCDescriptorRing{UInt64}(3)
        output = Ref(UInt64(999))
        @test @inferred(try_take!(output, ring)) == RingEmpty
        @test output[] == 999

        for value in UInt64(1):UInt64(3)
            @test @inferred(try_submit!(ring, value)) == RingTransferSucceeded
        end
        @test try_submit!(ring, UInt64(4)) == RingFull
        @test ring_accounting(ring).occupancy == 3

        @test try_take!(output, ring) == RingTransferSucceeded
        @test output[] == 1
        @test try_submit!(ring, UInt64(4)) == RingTransferSucceeded
        @test try_submit!(ring, UInt64(5)) == RingFull

        for expected in UInt64(2):UInt64(4)
            @test try_take!(output, ring) == RingTransferSucceeded
            @test output[] == expected
        end
        @test try_take!(output, ring) == RingEmpty

        for cycle in UInt64(1):UInt64(20)
            @test try_submit!(ring, cycle) == RingTransferSucceeded
            @test try_take!(output, ring) == RingTransferSucceeded
            @test output[] == cycle
        end
        @test ring_accounting(ring).occupancy == 0
    end

    @testset "Natural batches" begin
        ring = SPSCDescriptorRing{UInt32}(5)
        for value in UInt32(10):UInt32(13)
            @test try_submit!(ring, value) == RingTransferSucceeded
        end
        destination = fill(UInt32(0), 3)
        first_batch =
            @inferred try_take_batch!(destination, ring, 3)
        @test first_batch == RingBatchResult(RingTransferSucceeded, 3)
        @test destination == UInt32[10, 11, 12]

        second_batch =
            @inferred try_take_batch!(destination, ring)
        @test second_batch == RingBatchResult(RingTransferSucceeded, 1)
        @test destination[1] == 13
        @test try_take_batch!(destination, ring) ==
              RingBatchResult(RingEmpty, 0)
        @test_throws ArgumentError try_take_batch!(
            destination, ring, 0)
        @test_throws ArgumentError try_take_batch!(
            destination, ring, 4)
    end

    @testset "Close and drain" begin
        ring = SPSCDescriptorRing{UInt64}(2)
        output = Ref(UInt64(88))
        @test try_take!(output, ring) == RingEmpty
        @test try_submit!(ring, UInt64(1)) == RingTransferSucceeded
        @test try_submit!(ring, UInt64(2)) == RingTransferSucceeded
        @test close_ring!(ring) == RingTransferSucceeded
        @test ring_is_closed(ring)
        @test close_ring!(ring) == RingClosed
        @test try_submit!(ring, UInt64(3)) == RingClosed

        @test try_take!(output, ring) == RingTransferSucceeded
        @test output[] == 1
        @test try_take!(output, ring) == RingTransferSucceeded
        @test output[] == 2
        @test try_take!(output, ring) == RingClosed
        @test output[] == 2

        destination = fill(UInt64(0), 2)
        @test try_take_batch!(destination, ring) ==
              RingBatchResult(RingClosed, 0)
        accounting = ring_accounting(ring)
        @test accounting.occupancy == 0
        @test accounting.closed
    end

    @testset "Accounting corruption detection" begin
        ring = SPSCDescriptorRing{UInt64}(2)
        @atomic :release ring.cursors.producer_sequence = UInt64(3)
        @test_throws OwnershipError ring_accounting(ring)
        @atomic :release ring.cursors.producer_sequence = UInt64(0)
        @test ring_accounting(ring).occupancy == 0
    end

    @testset "Inference and warmed allocations" begin
        ring = SPSCDescriptorRing{UInt64}(2)
        output = Ref(UInt64(0))
        @test @inferred(try_submit!(ring, UInt64(1))) ==
              RingTransferSucceeded
        @test @inferred(try_take!(output, ring)) == RingTransferSucceeded
        if OWNERSHIP_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test ring_allocation_bytes(ring, output) == (0, 0)
        end
    end
end

@testset "Generation-checked payload pool" begin
    @testset "Preparation and identities" begin
        @test_throws OwnershipError PayloadPool(
            Ref{UInt64}[], UInt64(1), UInt64(1))
        @test_throws OwnershipError PayloadPool(
            HugePayloadVector(), UInt64(1), UInt64(1))
        @test_throws OwnershipError PayloadPool(
            [Ref(UInt64(0))], UInt64(0), UInt64(1))
        @test_throws OwnershipError PayloadPool(
            [Ref(UInt64(0))], UInt64(1), UInt64(0))

        payloads = [Ref(UInt64(0)), Ref(UInt64(0))]
        pool = PayloadPool(payloads, UInt64(17), UInt64(23))
        @test payload_pool_capacity(pool) == 2
        @test payload_pool_id(pool) == 17
        @test payload_session_id(pool) == 23
        @test isbitstype(PayloadLeaseRef)
        accounting = validate_quiescent_pool(pool)
        @test accounting ==
              PayloadPoolAccounting(2, 2, 0, 0, 0)
    end

    @testset "Legal ownership lifecycle" begin
        payloads = [Ref(UInt64(0)), Ref(UInt64(0))]
        pool = PayloadPool(payloads, UInt64(7), UInt64(9))
        output = Ref(PayloadLeaseRef(99, 99, 99, 99))

        @test @inferred(try_claim_payload!(output, pool)) ==
              PayloadTransitionSucceeded
        lease = output[]
        @test payload_pool_id(lease) == 7
        @test payload_session_id(lease) == 9
        @test payload_slot(lease) == 1
        @test payload_generation(lease) == 1
        @test @inferred(producer_payload(pool, lease)) === payloads[1]
        producer_payload(pool, lease)[] = UInt64(42)
        @test payload_pool_accounting(pool) ==
              PayloadPoolAccounting(2, 1, 1, 0, 0)

        @test @inferred(queue_payload!(pool, lease)) ==
              PayloadTransitionSucceeded
        @test payload_pool_accounting(pool) ==
              PayloadPoolAccounting(2, 1, 0, 1, 0)
        @test_throws OwnershipError producer_payload(pool, lease)

        @test @inferred(lease_payload!(pool, lease)) ==
              PayloadTransitionSucceeded
        @test @inferred(consumer_payload(pool, lease))[] == 42
        @test payload_pool_accounting(pool) ==
              PayloadPoolAccounting(2, 1, 0, 0, 1)

        @test @inferred(release_payload!(pool, lease)) ==
              PayloadTransitionSucceeded
        @test release_payload!(pool, lease) ==
              DuplicatePayloadRelease
        @test_throws OwnershipError consumer_payload(pool, lease)
        @test validate_quiescent_pool(pool).free == 2
    end

    @testset "Abort, exhaustion, and generation reuse" begin
        pool =
            PayloadPool([Ref(UInt64(0))], UInt64(11), UInt64(13))
        output = Ref(PayloadLeaseRef(99, 99, 99, 99))
        @test try_claim_payload!(output, pool) == PayloadTransitionSucceeded
        first_lease = output[]
        @test try_claim_payload!(output, pool) ==
              PayloadPoolExhausted
        @test output[] == first_lease
        @test_throws OwnershipError validate_quiescent_pool(pool)
        @test abort_payload!(pool, first_lease) == PayloadTransitionSucceeded
        @test abort_payload!(pool, first_lease) ==
              WrongPayloadOwner

        @test try_claim_payload!(output, pool) == PayloadTransitionSucceeded
        second_lease = output[]
        @test second_lease.slot == first_lease.slot
        @test second_lease.generation == first_lease.generation + 1
        @test release_payload!(pool, first_lease) == StalePayloadLease
        @test abort_payload!(pool, second_lease) == PayloadTransitionSucceeded

        generation_pool =
            PayloadPool([Ref(UInt64(0))], UInt64(2), UInt64(3))
        generation_pool.generations[1] = typemax(UInt64)
        sentinel = PayloadLeaseRef(8, 8, 8, 8)
        generation_output = Ref(sentinel)
        @test try_claim_payload!(generation_output, generation_pool) ==
              PayloadGenerationExhausted
        @test generation_output[] == sentinel
    end

    @testset "Rejected transitions preserve ownership" begin
        pool =
            PayloadPool([Ref(UInt64(0))], UInt64(31), UInt64(37))
        output = Ref{PayloadLeaseRef}()
        @test try_claim_payload!(output, pool) == PayloadTransitionSucceeded
        lease = output[]
        before = payload_pool_accounting(pool)

        wrong_pool = PayloadLeaseRef(
            lease.pool_id + 1,
            lease.session_id,
            lease.slot,
            lease.generation)
        wrong_session = PayloadLeaseRef(
            lease.pool_id,
            lease.session_id + 1,
            lease.slot,
            lease.generation)
        zero_slot = PayloadLeaseRef(
            lease.pool_id,
            lease.session_id,
            UInt32(0),
            lease.generation)
        high_slot = PayloadLeaseRef(
            lease.pool_id,
            lease.session_id,
            UInt32(2),
            lease.generation)
        zero_generation = PayloadLeaseRef(
            lease.pool_id,
            lease.session_id,
            lease.slot,
            UInt64(0))

        @test release_payload!(pool, wrong_pool) ==
              WrongPayloadPool
        @test release_payload!(pool, wrong_session) ==
              WrongPayloadSession
        @test release_payload!(pool, zero_slot) ==
              InvalidPayloadSlot
        @test release_payload!(pool, high_slot) ==
              InvalidPayloadSlot
        @test release_payload!(pool, zero_generation) ==
              StalePayloadLease
        @test release_payload!(pool, lease) ==
              WrongPayloadOwner
        @test payload_pool_accounting(pool) == before

        @test queue_payload!(pool, wrong_pool) == WrongPayloadPool
        @test queue_payload!(pool, wrong_session) ==
              WrongPayloadSession
        @test queue_payload!(pool, high_slot) ==
              InvalidPayloadSlot
        @test queue_payload!(pool, lease) == PayloadTransitionSucceeded
        @test queue_payload!(pool, lease) == WrongPayloadOwner
        @test lease_payload!(pool, lease) == PayloadTransitionSucceeded
        @test lease_payload!(pool, lease) == WrongPayloadOwner
        @test abort_payload!(pool, lease) == WrongPayloadOwner
        @test release_payload!(pool, lease) == PayloadTransitionSucceeded
        @test validate_quiescent_pool(pool).free == 1
    end

    @testset "Accounting corruption detection" begin
        pool =
            PayloadPool([Ref(UInt64(0))], UInt64(41), UInt64(43))
        @atomic :release pool.states[1] = UInt8(0xff)
        @test_throws OwnershipError payload_pool_accounting(pool)
        @atomic :release pool.states[1] = UInt8(0)
        @test validate_quiescent_pool(pool).free == 1
    end

    @testset "Inference and warmed allocations" begin
        pool =
            PayloadPool([Ref(UInt64(0))], UInt64(47), UInt64(53))
        output = Ref{PayloadLeaseRef}()
        @test @inferred(try_claim_payload!(output, pool)) ==
              PayloadTransitionSucceeded
        lease = output[]
        @test @inferred(producer_payload(pool, lease)) isa
              Base.RefValue{UInt64}
        @test @inferred(queue_payload!(pool, lease)) ==
              PayloadTransitionSucceeded
        @test @inferred(lease_payload!(pool, lease)) ==
              PayloadTransitionSucceeded
        @test @inferred(consumer_payload(pool, lease)) isa
              Base.RefValue{UInt64}
        @test @inferred(release_payload!(pool, lease)) ==
              PayloadTransitionSucceeded

        if OWNERSHIP_TESTS_WITH_COVERAGE
            @test_skip "allocation assertions are disabled under coverage"
        else
            @test payload_allocation_bytes(pool, output) ==
                  (0, 0, 0, 0, 0, 0)
        end
    end
end
