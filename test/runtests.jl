using AdaptiveOpticsHIL
using Aqua
using Test

include("timing.jl")
include("lifecycle.jl")
include("ownership.jl")
include("ports.jl")
include("serial.jl")
include("execution.jl")

@testset "AdaptiveOpticsHIL.jl" begin
    Aqua.test_all(AdaptiveOpticsHIL)
end
