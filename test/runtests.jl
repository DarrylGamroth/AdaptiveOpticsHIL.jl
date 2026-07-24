using AdaptiveOpticsHIL
using Aqua
using Test

include("timing.jl")
include("ownership.jl")
include("ports.jl")
include("serial.jl")

@testset "AdaptiveOpticsHIL.jl" begin
    Aqua.test_all(AdaptiveOpticsHIL)
end
