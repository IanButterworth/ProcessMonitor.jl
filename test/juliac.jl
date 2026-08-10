# Build the standalone `jtop` executable and exercise it.
#
# This is the regression test for `juliac --trim`: the trim verifier rejects any call it
# cannot resolve statically, so a stray dynamic dispatch introduced anywhere reachable from
# `top()` fails the build rather than silently un-trimming it. Running the result then
# proves the binary actually links and reaches `top()`.
#
# The build takes a minute or so. Prerequisites are Julia 1.12 or newer (which is when
# juliac started shipping in `share/julia/juliac`) and a C compiler for the final link; the
# test reports and skips when either is missing. Set PROCESSMONITOR_TEST_JULIAC=false to
# skip it even where it could run.

const JULIAC = normpath(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl"))

_find_cc() = something(Sys.which("cc"), Sys.which("gcc"), Sys.which("clang"), Some(nothing))

@testset "juliac --trim" begin
    root = dirname(@__DIR__)
    skip = if get(ENV, "PROCESSMONITOR_TEST_JULIAC", "true") == "false"
        "PROCESSMONITOR_TEST_JULIAC=false"
    elseif Sys.iswindows()
        "Windows is not supported"
    elseif !isfile(JULIAC)
        "no juliac.jl at $JULIAC (needs Julia 1.12 or newer; this is $VERSION)"
    elseif _find_cc() === nothing
        "no C compiler found to link the executable"
    else
        nothing
    end
    if skip !== nothing
        @info "skipping the juliac --trim build: $skip"
    else
        mktempdir() do dir
            exe = joinpath(dir, "jtop")
            outlog, errlog = joinpath(dir, "build.out"), joinpath(dir, "build.err")
            # Plain `JULIA` rather than `Base.julia_cmd()`: juliac forwards its own
            # process's flags to the compile, and `Pkg.test` runs us with `--check-bounds`
            # and possibly coverage on. `Pkg.test` also narrows JULIA_LOAD_PATH to the
            # active project, which hides the stdlibs juliac.jl itself loads.
            build = addenv(`$JULIA --startup-file=no --project=$root $JULIAC
                            --output-exe $exe --experimental --trim=safe
                            $(joinpath(root, "juliac", "main.jl"))`,
                "JULIA_LOAD_PATH" => "@:@stdlib")
            built = success(pipeline(ignorestatus(build); stdout = outlog, stderr = errlog))
            if !built
                # The verifier names every unresolved call; that output is the whole point
                # of a failure here, so surface it instead of just a red `false`.
                print(read(outlog, String))
                print(stderr, read(errlog, String))
            end
            @test built
            @test isfile(exe)

            if built && isfile(exe)
                @test occursin("Usage: jtop", read(`$exe --help`, String))

                # Redirecting stdout away from a terminal takes the binary through the real
                # entry point: `top()` must refuse rather than draw into a pipe.
                runerr = joinpath(dir, "run.err")
                notty = run(pipeline(ignorestatus(`$exe`); stdout = devnull, stderr = runerr))
                @test !success(notty)
                @test occursin("interactive terminal", read(runerr, String))
            end
        end
    end
end
