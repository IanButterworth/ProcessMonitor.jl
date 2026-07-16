using CPUMonitor
using Test

const JULIA = Base.julia_cmd()[1]

# Start a Julia subprocess running `script` and return (process, io) only once the process
# has printed "READY", i.e. once it is past startup. This keeps the subprocess's startup
# CPU out of the measurement window so the tests aren't timing-dependent.
function start_ready(script)
    out = Pipe()
    p = run(pipeline(`$JULIA --startup-file=no -e $script`, stdout=out), wait=false)
    close(out.in)
    readuntil(out, "READY")
    return p, out
end

stop(p, out) = (kill(p); wait(p); close(out))

# Spins on the CPU forever; signals readiness once spinning.
const SPIN = "println(\"READY\"); flush(stdout); while true; end"

# Stays idle itself but spawns a spinning child; signals readiness once the child is spawned.
const IDLE_PARENT = raw"""run(`$(Base.julia_cmd()) --startup-file=no -e "while true; end"`, wait=false); println("READY"); flush(stdout); sleep(60)"""

@testset "CPUMonitor" begin
    @testset "_parse_cpu_time" begin
        f = CPUMonitor._parse_cpu_time
        @test f("0:00.01") ≈ 0.01
        @test f("18:29.85") ≈ 1109.85
        @test f("1:02:03") ≈ 3723.0
        @test f("2-03:00:00") ≈ 183600.0
        @test f("garbage") === nothing
    end

    if Sys.iswindows()
        @testset "windows unsupported" begin
            @test_throws ErrorException CPUSampler()
        end
    else
        # Assertions are relational rather than absolute: a contended (e.g. CI) host may
        # deny a spinner a full core, but a spinner always out-uses a sleeper and a subtree
        # with a busy child always out-uses the idle parent alone.
        @testset "busy out-uses idle" begin
            p, out = start_ready(SPIN)
            try
                busy = CPUSampler(p)
                idle = CPUSampler()   # this test process, mostly sleeping
                sleep(2.5)
                b, i = cpu_percent(busy), cpu_percent(idle)
                @test b > i
                @test b > 10          # actively spinning, so clearly nonzero
            finally
                stop(p, out)
            end
        end

        @testset "recursive captures subprocess CPU" begin
            p, out = start_ready(IDLE_PARENT)
            try
                bare = CPUSampler(p; recursive=false)
                rec = CPUSampler(p; recursive=true)
                sleep(2.5)
                b, r = cpu_percent(bare), cpu_percent(rec)
                @test r > b           # the busy child shows up only in the subtree
                @test r > 10          # and contributes real CPU
                @test b < r / 2       # the parent itself is comparatively idle
            finally
                stop(p, out)
            end
        end

        @testset "blocking convenience" begin
            p, out = start_ready(SPIN)
            try
                @test cpu_percent(p; interval=2.5) > 10
            finally
                stop(p, out)
            end
        end
    end
end
