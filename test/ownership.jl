using AdaptiveOpticsHIL.Ownership
using AdaptiveOpticsHIL.Ownership:
    MAX_SUPPORTED_CACHE_LINE_BYTES,
    SPSCLayoutEvidence,
    maximum_cache_line_bytes,
    ring_layout_contract,
    validate_ring_layout
using InteractiveUtils

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
    batch_output = fill(UInt64(0), 2)
    try_submit!(ring, UInt64(12))
    try_submit!(ring, UInt64(13))
    try_take_batch!(batch_output, ring)
    ring_accounting(ring)
    validate_ring_layout(ring)

    submit_bytes = @allocated try_submit!(ring, UInt64(14))
    take_bytes = @allocated try_take!(output, ring)
    try_submit!(ring, UInt64(15))
    try_submit!(ring, UInt64(16))
    batch_bytes = @allocated try_take_batch!(batch_output, ring)
    accounting_bytes = @allocated ring_accounting(ring)
    layout_validation_bytes = @allocated validate_ring_layout(ring)
    return (;
        submit_bytes,
        take_bytes,
        batch_bytes,
        accounting_bytes,
        layout_validation_bytes)
end

function replace_layout_evidence(
    evidence::SPSCLayoutEvidence;
    maximum_cache_line_bytes::Int=
        evidence.maximum_cache_line_bytes,
    cursor_storage_bytes::Int=evidence.cursor_storage_bytes,
    object_base_modulo::Int=evidence.object_base_modulo,
    producer_sequence_offset::Int=
        evidence.producer_sequence_offset,
    producer_cached_consumer_sequence_offset::Int=
        evidence.producer_cached_consumer_sequence_offset,
    producer_slot_offset::Int=
        evidence.producer_slot_offset,
    consumer_sequence_offset::Int=
        evidence.consumer_sequence_offset,
    consumer_cached_producer_sequence_offset::Int=
        evidence.consumer_cached_producer_sequence_offset,
    consumer_slot_offset::Int=
        evidence.consumer_slot_offset,
    closed_offset::Int=evidence.closed_offset)
    return SPSCLayoutEvidence(
        maximum_cache_line_bytes,
        cursor_storage_bytes,
        object_base_modulo,
        producer_sequence_offset,
        producer_cached_consumer_sequence_offset,
        producer_slot_offset,
        consumer_sequence_offset,
        consumer_cached_producer_sequence_offset,
        consumer_slot_offset,
        closed_offset)
end

function ownership_error_reason(f::F) where {F}
    try
        f()
    catch error
        error isa OwnershipError || rethrow()
        return error.reason
    end
    return nothing
end

function llvm_text(f, types)
    output = IOBuffer()
    code_llvm(
        output,
        f,
        types;
        optimize=true,
        raw=true,
        debuginfo=:none)
    return String(take!(output))
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
        @test_throws OwnershipError SPSCLayoutContract(32)
        @test_throws OwnershipError SPSCLayoutContract(96)
        @test_throws OwnershipError SPSCLayoutContract(256)

        ring = SPSCDescriptorRing{UInt64}(3)
        @test ring_capacity(ring) == 3
        contract = ring_layout_contract(ring)
        @test maximum_cache_line_bytes(contract) ==
              MAX_SUPPORTED_CACHE_LINE_BYTES
        evidence = @inferred validate_ring_layout(ring)
        @test evidence.maximum_cache_line_bytes ==
              MAX_SUPPORTED_CACHE_LINE_BYTES
        @test evidence.cursor_storage_bytes >=
              6 * MAX_SUPPORTED_CACHE_LINE_BYTES
        @test evidence.consumer_sequence_offset -
              evidence.producer_sequence_offset >=
              2 * MAX_SUPPORTED_CACHE_LINE_BYTES
        @test evidence.closed_offset -
              evidence.consumer_sequence_offset >=
              2 * MAX_SUPPORTED_CACHE_LINE_BYTES
        @test 0 <= evidence.object_base_modulo <
              MAX_SUPPORTED_CACHE_LINE_BYTES

        line64_contract = SPSCLayoutContract(64)
        line64_ring =
            SPSCDescriptorRing{UInt64}(3, line64_contract)
        @test ring_layout_contract(line64_ring) === line64_contract
        line64_evidence = validate_ring_layout(line64_ring)
        @test line64_evidence.maximum_cache_line_bytes == 64

        mismatched_contract = replace_layout_evidence(
            evidence;
            maximum_cache_line_bytes=64)
        mismatch_reason = ownership_error_reason() do
            Ownership._validate_spsc_layout_evidence(
                contract, mismatched_contract)
        end
        @test mismatch_reason == :layout_contract_mismatch

        invalid_modulo = replace_layout_evidence(
            evidence;
            object_base_modulo=
                evidence.maximum_cache_line_bytes)
        modulo_reason = ownership_error_reason() do
            Ownership._validate_spsc_layout_evidence(
                contract, invalid_modulo)
        end
        @test modulo_reason == :invalid_object_address_modulo

        insufficient_storage = replace_layout_evidence(
            evidence;
            cursor_storage_bytes=
                6 * evidence.maximum_cache_line_bytes - 1)
        storage_reason = ownership_error_reason() do
            Ownership._validate_spsc_layout_evidence(
                contract, insufficient_storage)
        end
        @test storage_reason == :insufficient_cursor_storage

        outside_storage = replace_layout_evidence(
            evidence;
            closed_offset=evidence.cursor_storage_bytes)
        outside_reason = ownership_error_reason() do
            Ownership._validate_spsc_layout_evidence(
                contract, outside_storage)
        end
        @test outside_reason == :atomic_field_outside_storage

        misaligned = replace_layout_evidence(
            evidence;
            object_base_modulo=mod(
                evidence.object_base_modulo + 1,
                evidence.maximum_cache_line_bytes))
        misaligned_reason = ownership_error_reason() do
            Ownership._validate_spsc_layout_evidence(
                contract, misaligned)
        end
        @test misaligned_reason == :misaligned_atomic_field

        overlapping = replace_layout_evidence(
            evidence;
            consumer_sequence_offset=
                evidence.producer_sequence_offset)
        overlapping_reason = ownership_error_reason() do
            Ownership._validate_spsc_layout_evidence(
                contract, overlapping)
        end
        @test overlapping_reason == :overlapping_cursor_fields

        insufficiently_separated = SPSCLayoutEvidence(
            128, 776, 0, 128, 136, 144, 152, 160, 168, 176)
        separation_reason = ownership_error_reason() do
            Ownership._validate_spsc_layout_evidence(
                contract, insufficiently_separated)
        end
        @test separation_reason ==
              :insufficient_publication_separation

        insufficiently_padded = SPSCLayoutEvidence(
            128, 776, 0, 0, 8, 16, 256, 264, 272, 512)
        padding_reason = ownership_error_reason() do
            Ownership._validate_spsc_layout_evidence(
                contract, insufficiently_padded)
        end
        @test padding_reason == :insufficient_boundary_padding

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

    @testset "UInt64 sequence wrap" begin
        ring = SPSCDescriptorRing{UInt64}(3)
        output = Ref(UInt64(0))
        initial_sequence = typemax(UInt64) - one(UInt64)
        @atomic :release ring.cursors.producer_sequence =
            initial_sequence
        ring.cursors.producer_cached_consumer_sequence =
            initial_sequence
        @atomic :release ring.cursors.consumer_sequence =
            initial_sequence
        ring.cursors.consumer_cached_producer_sequence =
            initial_sequence

        @test try_submit!(ring, UInt64(41)) ==
              RingTransferSucceeded
        @test try_submit!(ring, UInt64(42)) ==
              RingTransferSucceeded
        @test try_submit!(ring, UInt64(43)) ==
              RingTransferSucceeded
        @test ring_accounting(ring).producer_sequence == 1
        @test ring_accounting(ring).occupancy == 3
        @test try_take!(output, ring) == RingTransferSucceeded
        @test output[] == 41
        @test try_take!(output, ring) == RingTransferSucceeded
        @test output[] == 42
        @test try_take!(output, ring) == RingTransferSucceeded
        @test output[] == 43
        accounting = ring_accounting(ring)
        @test accounting.producer_sequence == 1
        @test accounting.consumer_sequence == 1
        @test accounting.occupancy == 0

        @test try_submit!(ring, UInt64(44)) ==
              RingTransferSucceeded
        @test try_take!(output, ring) == RingTransferSucceeded
        @test output[] == 44

        batch_ring = SPSCDescriptorRing{UInt64}(5)
        batch_initial_sequence =
            typemax(UInt64) - UInt64(2)
        @atomic :release batch_ring.cursors.producer_sequence =
            batch_initial_sequence
        batch_ring.cursors.producer_cached_consumer_sequence =
            batch_initial_sequence
        @atomic :release batch_ring.cursors.consumer_sequence =
            batch_initial_sequence
        batch_ring.cursors.consumer_cached_producer_sequence =
            batch_initial_sequence
        for value in UInt64(51):UInt64(55)
            @test try_submit!(batch_ring, value) ==
                  RingTransferSucceeded
        end
        batch_output = fill(UInt64(0), 5)
        @test try_take_batch!(batch_output, batch_ring) ==
              RingBatchResult(RingTransferSucceeded, 5)
        @test batch_output == collect(UInt64(51):UInt64(55))
        batch_accounting = ring_accounting(batch_ring)
        @test batch_accounting.producer_sequence == 2
        @test batch_accounting.consumer_sequence == 2
        @test batch_accounting.occupancy == 0
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
            @test ring_allocation_bytes(ring, output) == (
                submit_bytes=0,
                take_bytes=0,
                batch_bytes=0,
                accounting_bytes=0,
                layout_validation_bytes=0)
        end
    end

    @testset "Generated atomic ordering" begin
        submit_llvm = llvm_text(
            try_submit!,
            Tuple{SPSCDescriptorRing{UInt64},UInt64})
        take_llvm = llvm_text(
            try_take!,
            Tuple{
                Base.RefValue{UInt64},
                SPSCDescriptorRing{UInt64}})
        close_llvm = llvm_text(
            close_ring!,
            Tuple{SPSCDescriptorRing{UInt64}})

        @test occursin(
            r"load atomic i64, ptr .* acquire",
            submit_llvm)
        @test occursin(
            r"store atomic i64 .* release",
            submit_llvm)
        @test occursin(
            r"load atomic i64, ptr .* acquire",
            take_llvm)
        @test occursin(
            r"store atomic i64 .* release",
            take_llvm)
        @test occursin(
            r"store atomic i64 .* release",
            close_llvm)
        for generated_code in (
            submit_llvm,
            take_llvm,
            close_llvm)
            @test !occursin("jl_apply_generic", generated_code)
            @test !occursin("jl_gc_alloc", generated_code)
            @test !occursin(" urem ", generated_code)
        end

        @info(
            "SPSC atomic-ordering inspection target",
            julia_version=VERSION,
            llvm_version=Base.libllvm_version,
            machine=Sys.MACHINE,
            kernel=Sys.KERNEL)
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
