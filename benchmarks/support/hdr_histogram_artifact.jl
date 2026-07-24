module HILHdrHistogramArtifact

using Base64
using HdrHistogram

const SPARSE_ENCODING =
    "AOHIL HdrHistogram sparse Int64 value/count pairs big-endian base64 v1"
const _PAIR_BYTES = 16

@inline function append_int64_be!(bytes::Vector{UInt8}, value::Int64)
    bits = reinterpret(UInt64, value)
    @inbounds for shift in 56:-8:0
        push!(bytes, UInt8((bits >> shift) & UInt64(0xff)))
    end
    return bytes
end

@inline function read_int64_be(bytes::AbstractVector{UInt8}, offset::Int)
    bits = zero(UInt64)
    @inbounds for index in offset:(offset + 7)
        bits = (bits << 8) | UInt64(bytes[index])
    end
    return reinterpret(Int64, bits)
end

function encode_sparse_histogram(histogram::HdrHistogram.Histogram)
    bytes = UInt8[]
    sizehint!(bytes, 16 * 128)
    recorded_bins = 0
    for entry in HdrHistogram.RecordedValuesIterator(histogram)
        value = Int64(HdrHistogram.value_iterated_to(entry))
        count = Int64(HdrHistogram.count_at_value_iterated_to(entry))
        count > 0 || error("recorded HdrHistogram bin has no samples")
        append_int64_be!(bytes, value)
        append_int64_be!(bytes, count)
        recorded_bins += 1
    end
    return Dict{String,Any}(
        "histogram_encoding" => SPARSE_ENCODING,
        "histogram_recorded_bins" => recorded_bins,
        "histogram_base64" => base64encode(bytes),
    )
end

function decode_sparse_histogram(
    payload::AbstractString,
    lowest_ns::Int64,
    highest_ns::Int64,
    significant_figures::Int)
    bytes = base64decode(payload)
    length(bytes) % _PAIR_BYTES == 0 || error(
        "sparse HdrHistogram payload has a partial value/count pair")
    histogram = HdrHistogram.Histogram(
        lowest_ns, highest_ns, significant_figures)
    for offset in 1:_PAIR_BYTES:length(bytes)
        value = read_int64_be(bytes, offset)
        count = read_int64_be(bytes, offset + 8)
        value >= 0 || error("sparse HdrHistogram value is negative")
        count > 0 || error(
            "sparse HdrHistogram count is not positive")
        HdrHistogram.record_value!(histogram, value, count)
    end
    return histogram
end

function verified_sparse_histogram(
    histogram::HdrHistogram.Histogram,
    lowest_ns::Int64,
    highest_ns::Int64,
    significant_figures::Int,
    expected_samples::Int)
    encoded = encode_sparse_histogram(histogram)
    decoded = decode_sparse_histogram(
        encoded["histogram_base64"],
        lowest_ns,
        highest_ns,
        significant_figures)
    reencoded = encode_sparse_histogram(decoded)
    HdrHistogram.total_count(decoded) == expected_samples || error(
        "sparse HdrHistogram round trip lost samples")
    reencoded["histogram_recorded_bins"] ==
        encoded["histogram_recorded_bins"] || error(
        "sparse HdrHistogram round trip changed the recorded-bin count")
    reencoded["histogram_base64"] ==
        encoded["histogram_base64"] || error(
        "sparse HdrHistogram round trip changed recorded values or counts")
    min(decoded) == min(histogram) || error(
        "sparse HdrHistogram round trip changed the minimum")
    max(decoded) == max(histogram) || error(
        "sparse HdrHistogram round trip changed the maximum")
    return encoded
end

end
