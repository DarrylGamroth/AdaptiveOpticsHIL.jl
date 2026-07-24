using AdaptiveOpticsHIL
using Aqua
using Test

include("timing.jl")
include("ownership.jl")

@testset "AdaptiveOpticsHIL.jl" begin
    Aqua.test_all(AdaptiveOpticsHIL)
end
