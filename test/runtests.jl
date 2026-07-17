using ProcessMonitor
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

# Kill the process and any subprocesses it spawned (killing only the parent would orphan
# e.g. IDLE_PARENT's spinning child), using the package's own process-tree snapshot.
function stop(p, out)
    pids = try
        ProcessMonitor._tree(ProcessMonitor._snapshot(), getpid(p), true)
    catch
        Int[]
    end
    kill(p); wait(p)
    for pid in pids
        pid == getpid(p) && continue
        ccall(:kill, Cint, (Cint, Cint), pid, 9)  # SIGKILL any orphaned descendants
    end
    close(out)
end

# Spins on the CPU forever; signals readiness once spinning.
const SPIN = "println(\"READY\"); flush(stdout); while true; end"

# Stays idle itself but spawns a spinning child; signals readiness once the child is spawned.
const IDLE_PARENT = raw"""run(`$(Base.julia_cmd()) --startup-file=no -e "while true; end"`, wait=false); println("READY"); flush(stdout); sleep(60)"""

@testset "ProcessMonitor" begin
    @testset "_parse_cpu_time" begin
        f = ProcessMonitor._parse_cpu_time
        @test f("0:00.01") ≈ 0.01
        @test f("18:29.85") ≈ 1109.85
        @test f("1:02:03") ≈ 3723.0
        @test f("2-03:00:00") ≈ 183600.0
        @test f("garbage") === nothing
    end

    if Sys.iswindows()
        @testset "windows unsupported" begin
            @test_throws ErrorException CPUSampler()
            @test_throws ErrorException top(IOBuffer())
        end
    else
        # CPU assertions are relational rather than absolute: a contended (e.g. CI) host
        # may deny a spinner a full core, but a spinner always out-uses a sleeper and a
        # subtree with a busy child always out-uses the idle parent alone.
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

        @testset "cpu_time" begin
            bare = cpu_time()
            @test bare > 0                             # this process has done real work
            # measured after `bare`, so it includes at least self's still-growing CPU time
            @test cpu_time(; recursive=true) >= bare
        end

        @testset "rss" begin
            self = rss()
            @test self > 10_000_000                    # a Julia process is >10 MB resident
            p, out = start_ready(IDLE_PARENT)
            try
                @test rss(p) > 10_000_000
                @test rss(p; recursive=true) > rss(p)  # child's memory is added
            finally
                stop(p, out)
            end
        end

        @testset "thread_count" begin
            # BSD `ps` may lack nlwp, in which case the count is 0; require it only where
            # the platform is known to provide it.
            if Sys.islinux() || Sys.isapple()
                @test thread_count() >= 1
                p, out = start_ready(IDLE_PARENT)
                try
                    @test thread_count(p; recursive=true) > thread_count(p)
                finally
                    stop(p, out)
                end
            else
                @test thread_count() >= 0
            end
        end

        @testset "info" begin
            i = ProcessMonitor.info(; recursive=true)
            @test i.cpu_time > 0
            @test i.rss > 10_000_000
            @test i.processes >= 1
            p, out = start_ready(IDLE_PARENT)
            try
                ip = ProcessMonitor.info(p; recursive=true)
                @test ip.processes >= 2                # parent + spinning child
                @test ip.rss > ProcessMonitor.info(p).rss
            finally
                stop(p, out)
            end
        end

        @testset "top single frame" begin
            io = IOBuffer()
            n = top(io; interval=0.5)
            s = String(take!(io))
            @test n > 1
            @test occursin("ProcessMonitor", s)
            @test occursin("PID", s)
            @test occursin(string(getpid()), s)   # our own row is present
            @test occursin("CPU", s) && occursin("MEM", s)
            @test !occursin('\e', s)              # color=false → no escape codes

            # tree mode nests our spawned child under its parent
            p, out = start_ready(IDLE_PARENT)
            try
                iot = IOBuffer()
                top(iot; interval=0.5, tree=true)
                st = String(take!(iot))
                @test occursin("└─", st) || occursin("├─", st)
            finally
                stop(p, out)
            end
        end

        @testset "julia awareness" begin
            # the test process is itself Julia, so full snapshots must know about it
            snap = ProcessMonitor._snapshot(full=true)
            self = getpid()
            @test ProcessMonitor._isjulia(snap, self)
            @test occursin("julia", lowercase(get(snap.exe, self, "")))
            @test occursin("--startup-file=no", get(snap.cmd, self, ""))

            # the header rollup and version-labeled row appear in a frame
            io = IOBuffer()
            top(io; interval=0.5)
            s = String(take!(io))
            @test occursin("julia:", s)   # "julia: N procs ..." rollup

            f = ProcessMonitor._julia_version_from_path
            @test f("/x/.julia/juliaup/julia-1.12.6+0.aarch64/bin/julia") == "1.12.6"
            @test f("/Applications/Julia-1.11.app/Contents/julia") == "1.11"
            @test f("/home/x/julia/usr/bin/julia") == "dev"
            @test f("/usr/bin/vim") == ""

            # a cheap plain snapshot skips exe/cmd
            lean = ProcessMonitor._snapshot()
            @test isempty(lean.exe) && isempty(lean.cmd)
        end

        @testset "formatting helpers" begin
            @test ProcessMonitor._fmtbytes(1 << 30) == "1.0G"
            @test ProcessMonitor._fmtbytes(15 * (1 << 20)) == "15M"
            @test ProcessMonitor._fmtbytes(512) == "512"
            @test ProcessMonitor._fmttime(65) == "1:05"
            @test ProcessMonitor._fmttime(3665) == "1:01:05"
            @test ProcessMonitor._fmtuptime(90061) == "1d 1:01"
            @test length(ProcessMonitor._spark([0.5, 1.0], 4)) >= 4
        end

        @testset "missing process throws" begin
            # Find a pid that does not exist: kill(pid, 0) failing with ESRCH specifically
            # (EPERM would mean the pid is alive but owned by another user).
            deadpid = 0
            for cand in 60_000:-1:50_000
                if ccall(:kill, Cint, (Cint, Cint), cand, 0) != 0 && Libc.errno() == Libc.ESRCH
                    deadpid = cand
                    break
                end
            end
            @test deadpid != 0
            @test_throws ArgumentError rss(deadpid)
            @test_throws ArgumentError ProcessMonitor.info(deadpid)
        end
    end
end
