"""Base exception type for AdaptiveOpticsHIL.jl."""
abstract type AdaptiveOpticsHILError <: Exception end

Base.showerror(io::IO, error::AdaptiveOpticsHILError) =
    print(io, error.msg)
