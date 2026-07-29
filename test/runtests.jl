using AdaptiveOpticsHIL
using Test

const TEST_GROUP_FILES = (
    "timing" => "timing.jl",
    "lifecycle" => "lifecycle.jl",
    "ownership" => "ownership.jl",
    "ports" => "ports.jl",
    "serial" => "serial.jl",
    "execution" => "execution.jl",
    "hsm-proof" => "hsm_lifecycle_proof.jl",
)

function selected_test_groups(arguments)
    isempty(arguments) && return TEST_GROUP_FILES
    requested = Set(String(argument) for argument in arguments)
    supported = Set(first.(TEST_GROUP_FILES))
    unsupported = sort!(collect(setdiff(requested, supported)))
    isempty(unsupported) || error(
        "unknown test group(s): $(join(unsupported, ", ")); " *
        "choose from $(join(first.(TEST_GROUP_FILES), ", "))",
    )
    return filter(pair -> first(pair) in requested, TEST_GROUP_FILES)
end

isempty(ARGS) && @eval using Aqua

@testset "AdaptiveOpticsHIL.jl" begin
    for (name, filename) in selected_test_groups(ARGS)
        @testset "$name" begin
            include(filename)
        end
    end
    isempty(ARGS) && @testset "Aqua" begin
        Aqua.test_all(AdaptiveOpticsHIL)
    end
end
