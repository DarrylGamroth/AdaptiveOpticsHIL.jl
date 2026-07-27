"""
Producer-owned declaration of one complete acquisition product. Product
storage remains in a generation-checked pool and the stream sequence is
assigned before publication so an explicitly dropped product leaves a gap.
"""
struct AcquisitionCompletion
    session::RunSessionID
    descriptor_schema_id::PortSchemaID
    descriptor_schema_version::PortSchemaVersion
    stream_sequence::StreamSequence
    acquisition::AcquisitionID
    completion_timestamp::PlantTimestamp
    product_lease::PayloadLeaseRef
    publication_execution_ns::Int64
end

acquisition_completion_session(value::AcquisitionCompletion) = value.session
acquisition_completion_sequence(value::AcquisitionCompletion) =
    value.stream_sequence
acquisition_completion_id(value::AcquisitionCompletion) = value.acquisition
acquisition_completion_timestamp(value::AcquisitionCompletion) =
    value.completion_timestamp
acquisition_completion_publication_ns(value::AcquisitionCompletion) =
    value.publication_execution_ns

struct AcquisitionCompletionPort{
    P,
    C<:AcquisitionProductContract,
    F<:AbstractPortFullPolicy}
    session::RunSessionID
    descriptor_schema_id::PortSchemaID
    descriptor_schema_version::PortSchemaVersion
    acquisition::AcquisitionID
    product_contract::C
    delivery_contract::AdapterDeliveryContract
    full_policy::F
    ring::SPSCDescriptorRing{AcquisitionCompletion}
    product_pool::PayloadPool{P}
end

@inline _acquisition_product_storage(product) = product
@inline _acquisition_product_storage(product::IntensityMap) =
    intensity_values(product)
@inline _acquisition_product_storage(product::WFSObservation) =
    observation_storage(product)
@inline _acquisition_product_storage(product::WFSMeasurement) =
    measurement_storage(product)

# Julia emits no coverage counters for these tested constant dispatch leaves.
@inline _product_storage_may_alias(::Nothing, ::Nothing) = false # COV_EXCL_LINE
@inline _product_storage_may_alias(::Nothing, ::Tuple) = false # COV_EXCL_LINE
@inline _product_storage_may_alias(::Tuple, ::Nothing) = false # COV_EXCL_LINE
@inline _product_storage_may_alias(::Nothing, right) = false # COV_EXCL_LINE
@inline _product_storage_may_alias(left, ::Nothing) = false # COV_EXCL_LINE
@inline _product_storage_may_alias(
    left::AbstractArray,
    right::AbstractArray) = Base.mightalias(left, right)
@inline _product_storage_may_alias(
    left::Base.RefValue,
    right::Base.RefValue) = left === right

function _product_storage_may_alias(left::Tuple, right::Tuple)
    for left_product in left
        for right_product in right
            _product_storage_may_alias(
                _acquisition_product_storage(left_product),
                _acquisition_product_storage(right_product)) &&
                return true
        end
    end
    return false
end

function _product_storage_may_alias(left::Tuple, right)
    for left_product in left
        _product_storage_may_alias(
            _acquisition_product_storage(left_product), right) &&
            return true
    end
    return false
end

function _product_storage_may_alias(left, right::Tuple)
    for right_product in right
        _product_storage_may_alias(
            left, _acquisition_product_storage(right_product)) &&
            return true
    end
    return false
end

@inline _product_storage_may_alias(left, right) = false # COV_EXCL_LINE

@inline function _acquisition_products_may_alias(
    left::AcquisitionProducts,
    right::AcquisitionProducts)
    left_storage = (
        _acquisition_product_storage(left.observation),
        _acquisition_product_storage(left.measurement))
    right_storage = (
        _acquisition_product_storage(right.observation),
        _acquisition_product_storage(right.measurement))
    return _product_storage_may_alias(left_storage, right_storage)
end

function _validate_distinct_acquisition_products(
    products::AbstractVector{<:AcquisitionProducts})
    @inbounds for right in 2:length(products)
        for left in 1:(right - 1)
            _acquisition_products_may_alias(
                products[left], products[right]) &&
                throw(PortError(
                    :acquisition_completion,
                    :aliased_product_storage,
                    "prepared acquisition products must not share mutable storage"))
        end
    end
    return products
end

@inline _validate_acquisition_full_policy(
    policy::Union{RetainProducerOnFull,DropNewestOnFull}) = policy

function _validate_acquisition_full_policy(
    ::AbstractPortFullPolicy)
    throw(PortError(
        :acquisition_completion,
        :invalid_full_policy,
        "acquisition completion supports retain-producer or drop-newest full behavior"))
end

"""
    prepare_acquisition_completion_port(acquisition, products; ...)

Prepare one complete-product stream. The first caller-owned
`AcquisitionProducts` value defines the exact type/shape/backend/device/units/
metadata contract and every remaining buffer is checked against it before the
port is armed.
"""
function prepare_acquisition_completion_port(
    acquisition::AcquisitionID,
    products::AbstractVector{P};
    session::RunSessionID,
    product_pool_id::UInt64,
    ring_capacity=length(products),
    product_return_capacity=length(products),
    descriptor_schema_id::PortSchemaID=
        PortSchemaID(:acquisition_completion),
    descriptor_schema_version::PortSchemaVersion=PortSchemaVersion(1),
    delivery_contract::AdapterDeliveryContract,
    full_policy::AbstractPortFullPolicy=
        RetainProducerOnFull()) where {
    P<:AcquisitionProducts}
    isempty(products) && throw(PortError(
        :acquisition_completion, :invalid_product_capacity,
        "acquisition product capacity must be positive"))
    isconcretetype(P) || throw(PortError(
        :acquisition_completion, :abstract_product_storage,
        "acquisition product vector must have one concrete product type"))
    contract = acquisition_product_contract(first(products))
    for product in products
        validate_acquisition_product_contract(product, contract)
    end
    _validate_distinct_acquisition_products(products)
    checked_ring_capacity =
        _checked_port_capacity(ring_capacity, :acquisition_completion)
    _validate_acquisition_full_policy(full_policy)
    pool = PayloadPool(
        products,
        product_pool_id,
        run_session_value(session);
        return_capacity=product_return_capacity)
    return AcquisitionCompletionPort(
        session,
        descriptor_schema_id,
        descriptor_schema_version,
        acquisition,
        contract,
        delivery_contract,
        full_policy,
        SPSCDescriptorRing{AcquisitionCompletion}(checked_ring_capacity),
        pool)
end

acquisition_delivery_contract(port::AcquisitionCompletionPort) =
    port.delivery_contract
acquisition_product_contract(port::AcquisitionCompletionPort) =
    port.product_contract

function port_resource_policy(port::AcquisitionCompletionPort)
    capacity = ring_capacity(port.ring)
    maximum = min(
        capacity,
        payload_pool_capacity(port.product_pool))
    return PortResourcePolicy(capacity, maximum, port.full_policy)
end

"""
Close acquisition publication and product claims. Already published products
remain drainable, and an existing producer-owned product may still be aborted.
"""
function close_acquisition_completion!(port::AcquisitionCompletionPort)
    ring_status = close_ring!(port.ring)
    pool_status = close_payload_pool!(port.product_pool)
    (
        pool_status == PayloadPoolCloseSucceeded ||
        pool_status == PayloadPoolAlreadyClosed
    ) || throw(PortError(
        :acquisition_completion,
        :payload_close_invariant,
        "acquisition completion could not close product claims"))
    return _ring_port_result(ring_status)
end

"""Claim one producer-owned complete-product buffer."""
try_claim_product!(
    output::Base.RefValue{PayloadLeaseRef},
    port::AcquisitionCompletionPort) =
    try_claim_payload!(output, port.product_pool)

"""Access one producer-owned complete-product buffer."""
producer_product(
    port::AcquisitionCompletionPort,
    lease::PayloadLeaseRef) =
    producer_payload(port.product_pool, lease)

"""Return an unpublished complete-product buffer to prepared storage."""
abort_product!(
    port::AcquisitionCompletionPort,
    lease::PayloadLeaseRef) =
    abort_payload!(port.product_pool, lease)

"""Reclaim already released products for the single product-pool owner."""
reclaim_product_returns!(
    port::AcquisitionCompletionPort,
    max_items::Integer=payload_pool_capacity(port.product_pool)) =
    reclaim_payload_returns!(port.product_pool, max_items)

"""
Construct a completion whose session, descriptor schema, and acquisition
identity exactly match `port`.
"""
function matching_acquisition_completion(
    port::AcquisitionCompletionPort,
    stream_sequence::StreamSequence,
    completion_timestamp::PlantTimestamp,
    product_lease::PayloadLeaseRef,
    publication_execution_ns::Int64)
    return AcquisitionCompletion(
        port.session,
        port.descriptor_schema_id,
        port.descriptor_schema_version,
        stream_sequence,
        port.acquisition,
        completion_timestamp,
        product_lease,
        publication_execution_ns)
end

"""
Publish one complete acquisition product. Rejected and closed results preserve
producer ownership. A full result either preserves it or reclaims the newest
product according to the prepared policy. Success queues the lease before
descriptor publication.
"""
function try_publish!(
    port::AcquisitionCompletionPort,
    completion::AcquisitionCompletion)
    completion.session == port.session ||
        return PortResult(PortRejected, SessionMismatch)
    completion.descriptor_schema_id == port.descriptor_schema_id &&
        completion.descriptor_schema_version ==
            port.descriptor_schema_version ||
        return PortResult(PortRejected, DescriptorSchemaMismatch)
    completion.acquisition == port.acquisition ||
        return PortResult(PortRejected, AcquisitionMismatch)

    payload_status = _lease_state_status(
        port.product_pool,
        completion.product_lease,
        _PAYLOAD_PRODUCER_OWNED)
    payload_status == PayloadTransitionSucceeded || return PortResult(
        PortRejected, PayloadLeaseMismatch, payload_status)
    ring_status = _producer_submission_status(port.ring)
    if ring_status != RingTransferSucceeded
        return _acquisition_publication_failure!(
            port.full_policy,
            port,
            completion.product_lease,
            ring_status)
    end

    payload_status =
        queue_payload!(port.product_pool, completion.product_lease)
    payload_status == PayloadTransitionSucceeded || return PortResult(
        PortRejected, PayloadLeaseMismatch, payload_status)
    ring_status = try_submit!(port.ring, completion)
    ring_status == RingTransferSucceeded || throw(PortError(
        :acquisition_completion, :publication_invariant,
        "completion publication failed after successful producer preflight"))
    return PortResult(PortTransferSucceeded)
end

@inline function _acquisition_publication_failure!(
    ::RetainProducerOnFull,
    ::AcquisitionCompletionPort,
    ::PayloadLeaseRef,
    ring_status::RingStatus)
    return _ring_port_result(ring_status)
end

@inline function _acquisition_publication_failure!(
    ::DropNewestOnFull,
    port::AcquisitionCompletionPort,
    lease::PayloadLeaseRef,
    ring_status::RingStatus)
    ring_status == RingFull ||
        return _ring_port_result(ring_status)
    status = abort_payload!(port.product_pool, lease)
    status == PayloadTransitionSucceeded || throw(PortError(
        :acquisition_completion,
        :drop_reclamation_invariant,
        "drop-newest policy could not reclaim the producer-owned product"))
    return PortResult(PortFull)
end

"""Take one complete product and acquire its generation-checked lease."""
function try_take!(
    output::Base.RefValue{AcquisitionCompletion},
    port::AcquisitionCompletionPort)
    ring_status = try_take!(output, port.ring)
    ring_status == RingTransferSucceeded ||
        return _ring_port_result(ring_status)
    payload_status =
        lease_payload!(port.product_pool, output[].product_lease)
    payload_status == PayloadTransitionSucceeded || throw(PortError(
        :acquisition_completion, :product_lease_invariant,
        "published acquisition product could not be leased by the consumer"))
    return PortResult(PortTransferSucceeded)
end

"""Access the complete product while its completion lease is consumer-owned."""
function completed_product(
    port::AcquisitionCompletionPort,
    completion::AcquisitionCompletion)
    completion.session == port.session || throw(PortError(
        :acquisition_completion, :session_mismatch,
        "completion belongs to another run/session"))
    completion.acquisition == port.acquisition || throw(PortError(
        :acquisition_completion, :acquisition_mismatch,
        "completion belongs to another acquisition"))
    return consumer_payload(port.product_pool, completion.product_lease)
end

"""Release-publish one consumed product for its pool owner to reclaim."""
function release_product!(
    port::AcquisitionCompletionPort,
    completion::AcquisitionCompletion)
    completion.session == port.session ||
        return PortResult(PortRejected, SessionMismatch)
    completion.acquisition == port.acquisition ||
        return PortResult(PortRejected, AcquisitionMismatch)
    payload_status =
        release_payload!(port.product_pool, completion.product_lease)
    payload_status == PayloadTransitionSucceeded || return PortResult(
        PortRejected,
        payload_status in (
            PayloadReturnCreditUnavailable,
            PayloadReturnPathClosed,
        ) ? LeaseReturnUnavailable : PayloadLeaseMismatch,
        payload_status)
    return PortResult(PortTransferSucceeded)
end

acquisition_product_accounting(port::AcquisitionCompletionPort) =
    payload_pool_accounting(port.product_pool)

"""
Close a product lease-return path after no product can create another return.
Already released products remain reclaimable after closure.
"""
function close_acquisition_return_path!(
    port::AcquisitionCompletionPort)
    _require_drained_completion(port, :acquisition_return)
    return close_payload_returns!(port.product_pool)
end
