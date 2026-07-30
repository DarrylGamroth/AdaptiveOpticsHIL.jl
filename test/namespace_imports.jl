const CANONICAL_ADAPTIVE_OPTICS_SIM_NAMESPACES = Set((
    "Backends",
    "Optics",
    "Atmospheres",
    "Detectors",
    "WavefrontSensors",
    "Calibration",
    "Control",
    "Tomography",
    "Ensembles",
    "Plant",
))

function adaptive_optics_sim_surface_files()
    root = normpath(joinpath(@__DIR__, ".."))
    files = [joinpath(root, "README.md")]
    for relative in ("src", "test", "benchmarks")
        for (directory, _, names) in walkdir(joinpath(root, relative))
            for name in names
                any(extension -> endswith(name, extension),
                    (".jl", ".md")) || continue
                path = joinpath(directory, name)
                abspath(path) == abspath(@__FILE__) && continue
                push!(files, path)
            end
        end
    end
    return files
end

@testset "Canonical AdaptiveOpticsSim imports" begin
    bare_using = r"(?m)^\s*using\s+AdaptiveOpticsSim\s*(?:#.*)?$"
    qualified_access =
        r"\bAdaptiveOpticsSim\.(?!jl\b)([A-Za-z_][A-Za-z_0-9]*)"

    for path in adaptive_optics_sim_surface_files()
        source = read(path, String)
        @test !occursin(bare_using, source)
        for matched in eachmatch(qualified_access, source)
            @test matched.captures[1] in
                CANONICAL_ADAPTIVE_OPTICS_SIM_NAMESPACES
        end
    end
end
