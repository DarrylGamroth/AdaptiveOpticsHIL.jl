using AdaptiveOpticsHIL.Ownership
using Test

struct LeasedStressDescriptor
    sequence::UInt64
    lease::PayloadLeaseRef
    guard::UInt64
end

const STRESS_GUARD = UInt64(0xd1ce_cafe_a05c_5a5a)

function run_two_owner_stress(
    iterations::Int=200_000,
    capacity::Int=64)
    payloads = [fill(UInt64(0), 2) for _ in 1:capacity]
    pool = PayloadPool(payloads, UInt64(101), UInt64(103))
    ring = SPSCDescriptorRing{LeasedStressDescriptor}(capacity)

    consumer = Threads.@spawn begin
        output = Ref{LeasedStressDescriptor}()
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
        return valid && expected == UInt64(iterations) + one(UInt64)
    end

    producer = Threads.@spawn begin
        lease_output = Ref{PayloadLeaseRef}()
        valid = true
        for sequence in UInt64(1):UInt64(iterations)
            while true
                claim_status = try_claim_payload!(lease_output, pool)
                claim_status == PayloadTransitionSucceeded && break
                if claim_status != PayloadPoolExhausted
                    valid = false
                    break
                end
                yield()
            end
            valid || break

            lease = lease_output[]
            payload = producer_payload(pool, lease)
            payload[1] = sequence
            payload[2] = xor(STRESS_GUARD, sequence)
            valid &= queue_payload!(pool, lease) == PayloadTransitionSucceeded
            valid || break

            descriptor = LeasedStressDescriptor(
                sequence, lease, xor(STRESS_GUARD, sequence))
            while true
                submit_status = try_submit!(ring, descriptor)
                submit_status == RingTransferSucceeded && break
                if submit_status != RingFull
                    valid = false
                    break
                end
                yield()
            end
            valid || break
        end
        valid &= close_ring!(ring) == RingTransferSucceeded
        return valid
    end

    return (
        fetch(producer),
        fetch(consumer),
        ring_accounting(ring),
        validate_quiescent_pool(pool))
end

@testset "Two-owner ring and payload stress" begin
    @test Threads.nthreads() >= 2
    producer_valid, consumer_valid, ring_state, pool_state =
        run_two_owner_stress()
    @test producer_valid
    @test consumer_valid
    @test ring_state.occupancy == 0
    @test ring_state.closed
    @test pool_state.free == pool_state.capacity
end
