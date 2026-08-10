# Build the standalone `jtop` executable:
#
#     julia --project=. juliac/build.jl [output-path]
#
# `juliac --trim` only emits code it can prove is reachable and statically typed, so the
# interactive view deliberately avoids `stdin`/`stdout`, REPL.Terminals and anything else
# that resolves through untyped globals or libuv's task scheduler. Requires Julia 1.12 or
# newer (juliac ships in `share/julia/juliac`) and a C compiler for the final link.

const ROOT = dirname(@__DIR__)
const OUT = abspath(get(ARGS, 1, joinpath(ROOT, "jtop")))

const JULIAC = joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl")
isfile(JULIAC) || error("""
    juliac.jl not found at $JULIAC.
    Building jtop needs Julia 1.12 or newer; this is Julia $VERSION.""")

cmd = `$(Base.julia_cmd()) --startup-file=no --project=$ROOT $JULIAC
       --output-exe $OUT --experimental --trim=safe $(joinpath(@__DIR__, "main.jl"))`
println("Running: ", cmd)
run(cmd)

println("\nBuilt $OUT ($(round(filesize(OUT) / 1024^2; digits = 1)) MiB)")
println("""
    It links against this Julia's libjulia by absolute path, so it runs wherever that
    installation stays put. Pass --relative-rpath to juliac and ship an adjacent julia/
    directory of shared libraries if you need a relocatable bundle.""")
