"""
    AdaptiveOpticsHIL

Transport-neutral hardware-in-the-loop orchestration for adaptive-optics
simulations.
"""
module AdaptiveOpticsHIL

include("errors.jl")
include("timing.jl")
include("ownership.jl")
include("ports.jl")
include("serial.jl")

export AdaptiveOpticsHILError, Ownership, Ports, Serial, Timing

end
