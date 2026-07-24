using AdaptiveOpticsHIL
using Aqua
using Test

include("timing.jl")

@testset "AdaptiveOpticsHIL.jl" begin
    Aqua.test_all(AdaptiveOpticsHIL)
end
