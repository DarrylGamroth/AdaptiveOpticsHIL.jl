"""
    AdaptiveOpticsHIL

Transport-neutral hardware-in-the-loop orchestration for adaptive-optics
simulations.
"""
module AdaptiveOpticsHIL

include("errors.jl")
include("timing.jl")
include("ownership.jl")
include("lifecycle.jl")
include("ports.jl")
include("serial.jl")

export AdaptiveOpticsHILError, Lifecycle, Ownership, Ports, Serial, Timing

end
