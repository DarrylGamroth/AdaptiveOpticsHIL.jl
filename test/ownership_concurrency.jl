using AdaptiveOpticsHIL.Ownership
using Test

struct LeasedStressDescriptor
    sequence::UInt64
    lease::PayloadLeaseRef
    guard::UInt64
end

const STRESS_GUARD = UInt64(0xd1ce_cafe_a05c_5a5a)

function publish_stress_descriptor!(
    ring::SPSCDescriptorRing{LeasedStressDescriptor},
    pool::PayloadPool,
    lease_output::Base.RefValue{PayloadLeaseRef},
    sequence::UInt64)
    while true
        claim_status = try_claim_payload!(lease_output, pool)
        claim_status == PayloadTransitionSucceeded && break
        claim_status == PayloadPoolExhausted || return false
        yield()
    end

    lease = lease_output[]
    payload = producer_payload(pool, lease)
    payload[1] = sequence
    payload[2] = xor(STRESS_GUARD, sequence)
    queue_payload!(pool, lease) == PayloadTransitionSucceeded ||
        return false

    descriptor = LeasedStressDescriptor(
        sequence, lease, xor(STRESS_GUARD, sequence))
    while true
        submit_status = try_submit!(ring, descriptor)
        submit_status == RingTransferSucceeded && return true
        submit_status == RingFull || return false
        yield()
    end
end

function run_two_owner_stress(
    iterations::Int=200_000,
    capacity::Int=64)
    iterations >= capacity ||
        throw(ArgumentError("iterations must be at least capacity"))
    payloads = [fill(UInt64(0), 2) for _ in 1:capacity]
    pool = PayloadPool(payloads, UInt64(101), UInt64(103))
    ring = SPSCDescriptorRing{LeasedStressDescriptor}(capacity)
    startup_gate = Threads.Atomic{UInt8}(0)

    consumer = Threads.@spawn begin
        output = Ref{LeasedStressDescriptor}()
        initial_empty = try_take!(output, ring) == RingEmpty
        startup_gate[] = UInt8(1)
        while startup_gate[] != UInt8(2)
            yield()
        end

        expected = UInt64(1)
        valid = true
        while true
            status = try_take!(output, ring)
            if status == RingTransferSucceeded
                descriptor = output[]
                valid &= descriptor.sequence == expected
                valid &= descriptor.guard ==
                         xor(STRESS_GUARD, descriptor.sequence)
                valid &= lease_payload!(pool, descriptor.lease) ==
                         PayloadTransitionSucceeded
                payload = consumer_payload(pool, descriptor.lease)
                valid &= payload[1] == descriptor.sequence
                valid &= payload[2] ==
                         xor(STRESS_GUARD, descriptor.sequence)
                valid &= release_payload!(pool, descriptor.lease) ==
                         PayloadTransitionSucceeded
                expected += one(UInt64)
            elseif status == RingEmpty
                yield()
            elseif status == RingClosed
                break
            else
                valid = false
                break
            end
        end
        return (
            valid &&
            expected == UInt64(iterations) + one(UInt64),
            initial_empty)
    end

    producer = Threads.@spawn begin
        lease_output = Ref{PayloadLeaseRef}()
        valid = true
        while startup_gate[] != UInt8(1)
            yield()
        end

        for sequence in UInt64(1):UInt64(capacity)
            valid &= publish_stress_descriptor!(
                ring, pool, lease_output, sequence)
            valid || break
        end
        full_observed = false
        if valid
            probe_sequence =
                UInt64(capacity) + one(UInt64)
            full_probe = LeasedStressDescriptor(
                probe_sequence,
                lease_output[],
                xor(STRESS_GUARD, probe_sequence))
            full_observed =
                try_submit!(ring, full_probe) == RingFull
        end
        startup_gate[] = UInt8(2)

        if valid
            for sequence in
                (UInt64(capacity) + one(UInt64)):UInt64(iterations)
                valid &= publish_stress_descriptor!(
                    ring, pool, lease_output, sequence)
                valid || break
            end
        end
        valid &= close_ring!(ring) == RingTransferSucceeded
        return valid, full_observed
    end

    producer_valid, full_observed = fetch(producer)
    consumer_valid, empty_observed = fetch(consumer)
    return (
        producer_valid,
        consumer_valid,
        empty_observed,
        full_observed,
        ring_accounting(ring),
        validate_quiescent_pool(pool))
end

@testset "Two-owner ring and payload stress" begin
    @test Threads.nthreads() >= 2
    for capacity in (2, 3, 7, 64)
        (
            producer_valid,
            consumer_valid,
            empty_observed,
            full_observed,
            ring_state,
            pool_state,
        ) = run_two_owner_stress(50_000, capacity)
        @test producer_valid
        @test consumer_valid
        @test empty_observed
        @test full_observed
        @test ring_state.occupancy == 0
        @test ring_state.closed
        @test pool_state.free == pool_state.capacity
    end
end
