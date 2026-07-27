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
include("execution.jl")
include("serial.jl")

export AdaptiveOpticsHILError, Execution, Lifecycle, Ownership, Ports, Serial
export Timing

end
