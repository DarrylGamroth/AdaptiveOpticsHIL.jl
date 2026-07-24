"""
    AdaptiveOpticsHIL

Transport-neutral hardware-in-the-loop orchestration for adaptive-optics
simulations.
"""
module AdaptiveOpticsHIL

include("errors.jl")
include("timing.jl")

export AdaptiveOpticsHILError, Timing

end
