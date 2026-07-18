using ProcessMonitor
using Test

const JULIA = Base.julia_cmd()[1]
const TEST_MARKER = "PROCESSMONITOR_TEST_$(getpid())_$(time_ns())"

# Start a Julia subprocess running `script` and return (process, io) only once the process
# has printed "READY", i.e. once it is past startup. This keeps the subprocess's startup
# CPU out of the measurement window so the tests aren't timing-dependent.
function start_ready(script)
    out = Pipe()
    p = run(pipeline(`$JULIA --startup-file=no -e $script $TEST_MARKER`, stdout=out), wait=false)
    close(out.in)
    readuntil(out, "READY")
    return p, out
end

# Kill the process and any subprocesses it spawned (killing only the parent would orphan
# e.g. IDLE_PARENT's spinning child), using the package's own process-tree snapshot.
# The root pid must be captured before wait(): getpid(p) can throw once p has exited.
function stop(p, out)
    rootpid = try
        Int(getpid(p))
    catch
        0
    end
    pids = rootpid == 0 ? Int[] : try
        ProcessMonitor._tree(ProcessMonitor._snapshot(), rootpid, true)
    catch
        Int[]
    end
    kill(p); wait(p)
    for pid in pids
        pid == rootpid && continue
        ccall(:kill, Cint, (Cint, Cint), pid, 9)  # SIGKILL any orphaned descendants
    end
    close(out)
end

# Safety net at exit: descendants orphaned by a mid-test failure reparent to init and
# leave our subtree. Every subprocess receives a unique per-run command-line marker so
# cleanup cannot match an unrelated Julia process or another concurrent test run.
atexit() do
    snap = try
        ProcessMonitor._snapshot(full=true)
    catch
        return
    end
    for (pid, cmd) in snap.cmd
        pid == getpid() && continue
        if occursin(TEST_MARKER, cmd)
            ccall(:kill, Cint, (Cint, Cint), pid, 9)
        end
    end
end

# Spins on the CPU forever; signals readiness once spinning.
const SPIN = "println(\"READY\"); flush(stdout); while true; end"

# Stays idle itself but spawns a spinning child; signals readiness once the child is spawned.
const IDLE_PARENT = raw"""run(`$(Base.julia_cmd()) --startup-file=no -e "while true; end" $(ARGS[1])`, wait=false); println("READY"); flush(stdout); sleep(60)"""

@testset "ProcessMonitor" begin
    @testset "_parse_cpu_time" begin
        f = ProcessMonitor._parse_cpu_time
        @test f("0:00.01") ≈ 0.01
        @test f("18:29.85") ≈ 1109.85
        @test f("1:02:03") ≈ 3723.0
        @test f("2-03:00:00") ≈ 183600.0
        @test f("garbage") === nothing
    end

    @testset "metric availability" begin
        snap = ProcessMonitor.Snapshot()
        snap.cputime[7] = 1.0
        @test_throws ArgumentError ProcessMonitor._checked_metric_tree(
            snap, 7, false, snap.rss, "RSS")
        @test ProcessMonitor._checked_metric_tree(
            snap, 7, false, snap.threads, "thread count";
            allow_globally_unavailable=true) == [7]
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
            busy = CPUSampler(p)
            try
                idle = CPUSampler()   # this test process, mostly sleeping
                sleep(2.5)
                b, i = cpu_percent(busy), cpu_percent(idle)
                @test b > i
                @test b > 10          # actively spinning, so clearly nonzero
            finally
                stop(p, out)
            end
            @test_throws ArgumentError cpu_percent(busy)
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

        @testset "recursive captures a newly spawned child" begin
            bare = CPUSampler()
            rec = CPUSampler(; recursive=true)
            p, out = start_ready(SPIN)  # starts after both samplers recorded their baselines
            try
                sleep(2.5)
                b, r = cpu_percent(bare), cpu_percent(rec)
                @test r > b
                @test r > 10
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

        @testset "interval validation" begin
            for interval in (0.0, -1.0, NaN, Inf)
                @test_throws ArgumentError cpu_percent(; interval)
                @test_throws ArgumentError top(IOBuffer(); interval)
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

            # expanded signal view fills the frame with high-resolution resource history
            iog = IOBuffer()
            ng = top(iog; interval=0.2, graphs=true)
            sg = String(take!(iog))
            graphlines = split(chomp(sg), '\n')
            @test ng > 1
            @test occursin("SIGNAL VIEW", sg)
            @test occursin("CPU TOTAL", sg) && occursin("MEMORY", sg)
            @test occursin("CORE TRAILS", sg) && occursin("C00", sg)
            @test any(line -> any(ch -> '⠀' <= ch <= '⣿', line), graphlines)
            @test length(graphlines) == 24
            @test all(line -> textwidth(line) <= 80, graphlines)
            @test !occursin('\e', sg)

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

            @test ProcessMonitor._julia_role("julia --worker=abc") == "worker"
            @test ProcessMonitor._julia_role("julia --output-ji /x.ji") == "precompile"
            @test ProcessMonitor._julia_role(
                "julia --output-ji /Users/x/.julia/compiled/v1.12/StaticArrays/jl_U1.ji") ==
                "precompile StaticArrays"
            @test ProcessMonitor._julia_role("julia script.jl") == ""
            @test ProcessMonitor._julia_project("julia --project=/x/MyPkg -e 1") == "MyPkg"
            @test ProcessMonitor._julia_project("julia --project -e 1") == "@."
            @test ProcessMonitor._julia_project("julia -e 1") == ""

            # start time and state are captured for ourselves
            @test 0 < get(snap.start, self, 0.0) <= time()
            @test get(snap.state, self, ' ') in ('R', 'S', 'I')
            @test ProcessMonitor._same_process(self, snap.start[self])
            @test !ProcessMonitor._same_process(self, snap.start[self] - 10)
            ok, msg = ProcessMonitor._send_signal(self, 0, snap.start[self])
            @test ok && isempty(msg)

            # a cheap plain snapshot skips exe/cmd
            lean = ProcessMonitor._snapshot()
            @test isempty(lean.exe) && isempty(lean.cmd)
            @test 0 < get(lean.start, self, 0.0) <= time()
        end

        @testset "formatting helpers" begin
            @test ProcessMonitor._fmtbytes(1 << 30) == "1.0G"
            @test ProcessMonitor._fmtbytes(15 * (1 << 20)) == "15M"
            @test ProcessMonitor._fmtbytes(512) == "512"
            @test ProcessMonitor._fmttime(65) == "1:05"
            @test ProcessMonitor._fmttime(3665) == "1:01:05"
            @test ProcessMonitor._fmtuptime(90061) == "1d 1:01"
            @test length(ProcessMonitor._spark([0.5, 1.0], 4)) >= 4
            @test ProcessMonitor._fmtage(45) == "45s"
            @test ProcessMonitor._fmtage(600) == "10m"
            @test ProcessMonitor._fmtage(7200) == "2.0h"
            @test ProcessMonitor._fmtage(200000) == "2.3d"
            g = ProcessMonitor._braille([0.1, 0.5, 0.9, 1.0], 4, 2; color=false)
            @test length(g) == 2 && all(l -> length(l) == 4, g)
            @test any(l -> any(ch -> '⠀' <= ch <= '⣿', l), g)
            b2 = ProcessMonitor._bar2(0.3, 0.2, 10; color=false)
            @test length(b2) == 10

            w = ProcessMonitor._wrap(" cmd  ", repeat("x", 200), 40)
            @test length(w) > 1                       # wrapped across rows
            @test all(l -> textwidth(l) <= 40, w)      # each row fits
            @test startswith(w[2], "      ")          # continuation indented under label
            @test textwidth(ProcessMonitor._ellipsize("界界", 2)) == 2
            combined = ProcessMonitor._ellipsize("e\u0301", 2)
            @test startswith(combined, "e\u0301") && textwidth(combined) == 2
            wide = ProcessMonitor._wrap(" cmd  ", repeat("界", 30), 20)
            @test length(wide) > 1 && all(l -> textwidth(l) <= 20, wide)
            @test ProcessMonitor._strip_argv0("/bin/julia --project=X -e 1") == "--project=X -e 1"
            @test ProcessMonitor._strip_argv0("solo") == ""

            # detail pane: exe line precedes cmd line, cmd has argv0 removed
            snap = ProcessMonitor._snapshot(full=true)
            st = ProcessMonitor.TopState(); st.detail = true
            prev = snap; pc = Sys.cpu_info(); t0 = time(); sleep(0.3)
            fr = ProcessMonitor._frame(prev, ProcessMonitor._snapshot(full=true), pc, Sys.cpu_info(), time()-t0)
            rows = ProcessMonitor._rows(st, fr)
            idx = findfirst(r -> r.pid == getpid(), rows)
            dl = ProcessMonitor._detail_lines(fr, rows[idx], 60, 20)
            iexe = findfirst(l -> occursin("exe ", l), dl)
            icmd = findfirst(l -> occursin("cmd ", l), dl)
            @test iexe !== nothing && icmd !== nothing && iexe < icmd

            # graph histories retain a separate high-resolution trail for every core
            graphstate = ProcessMonitor.TopState(graphs=true)
            ProcessMonitor._push_hist!(graphstate, fr)
            @test length(graphstate.corehist) == length(fr.percore)
            @test all(history -> length(history) == 1, graphstate.corehist)
            graphio = IOBuffer()
            ProcessMonitor._render(
                graphio, graphstate, fr; interactive=false, color=true)
            colored = String(take!(graphio))
            @test occursin("SIGNAL VIEW", colored) && occursin('\e', colored)
            for (height, width) in ((14, 60), (18, 67), (24, 80), (32, 120))
                sizebuf = IOBuffer()
                sizeio = IOContext(sizebuf, :displaysize => (height, width))
                ProcessMonitor._render(
                    sizeio, graphstate, fr; interactive=false, color=false)
                sizelines = split(chomp(String(take!(sizebuf))), '\n')
                @test length(sizelines) == height
                @test all(line -> textwidth(line) <= width, sizelines)
            end
        end

        @testset "key decoding" begin
            # CSI-u (modifyOtherKeys) sends shift+T as "\e[116;2u" — code of the
            # UNSHIFTED key plus a shift modifier. It must decode to 'T' (tree toggle),
            # not 't' (sort by time).
            st = ProcessMonitor.TopState()
            q = collect(codeunits("\e[116;2u"))
            ProcessMonitor._drain_keys!(st, q, nothing)
            @test st.tree
            @test st.sortkey === :cpu       # unchanged
            # plain bytes still work
            ProcessMonitor._drain_keys!(st, collect(codeunits("t")), nothing)
            @test st.sortkey === :time
            ProcessMonitor._drain_keys!(st, collect(codeunits("T")), nothing)
            @test !st.tree
            ProcessMonitor._drain_keys!(st, collect(codeunits("g")), nothing)
            @test st.graphs
            ProcessMonitor._drain_keys!(st, collect(codeunits("g")), nothing)
            @test !st.graphs
            # selection starts above the first row; down enters and up leaves the table
            @test st.sel == 0
            ProcessMonitor._drain_keys!(st, collect(codeunits("\e[B")), nothing)
            @test st.sel == 1
            ProcessMonitor._drain_keys!(st, collect(codeunits("\e[A")), nothing)
            @test st.sel == 0
            ProcessMonitor._drain_keys!(st, collect(codeunits("\r")), nothing)
            @test !st.detail
            # arrows: CSI and SS3 forms move the selection
            st.sel = 5
            ProcessMonitor._drain_keys!(st, collect(codeunits("\e[A")), nothing)
            @test st.sel == 4
            ProcessMonitor._drain_keys!(st, collect(codeunits("\eOB")), nothing)
            @test st.sel == 5
            # Escape sequences may be split across terminal reads.
            splitq = collect(codeunits("\e"))
            @test !ProcessMonitor._drain_keys!(st, splitq, nothing)
            @test splitq == collect(codeunits("\e"))
            append!(splitq, codeunits("[A"))
            @test ProcessMonitor._drain_keys!(st, splitq, nothing)
            @test st.sel == 4 && isempty(splitq)
            # A lone Escape is handled after the disambiguation timeout.
            st.filtering = true
            st.filter = "abc"
            st.escpending = ProcessMonitor._monotime() - 1
            ProcessMonitor._drain_keys!(st, collect(codeunits("\e")), nothing)
            @test !st.filtering && isempty(st.filter)
            # CSI-u enter toggles the detail pane
            ProcessMonitor._drain_keys!(st, collect(codeunits("\e[13;1u")), nothing)
            @test st.detail

            # UTF-8 characters may also be split across terminal reads.
            utf = ProcessMonitor.TopState(filtering=true)
            encoded = collect(codeunits("é"))
            utfq = encoded[1:1]
            @test !ProcessMonitor._drain_keys!(utf, utfq, nothing)
            @test isempty(utf.filter) && utfq == encoded[1:1]
            append!(utfq, encoded[2:end])
            @test ProcessMonitor._drain_keys!(utf, utfq, nothing)
            @test utf.filter == "é" && isempty(utfq)
            ProcessMonitor._drain_keys!(utf, collect(codeunits("e\u0301")), nothing)
            ProcessMonitor._drain_keys!(utf, UInt8[0x7f], nothing)
            @test utf.filter == "é"  # backspace removes the last grapheme, not one codepoint
        end

        @testset "tree name sorting" begin
            snap = ProcessMonitor.Snapshot()
            for (pid, ppid, name) in ((1, 0, "root"), (3, 1, "zeta"), (2, 1, "alpha"))
                snap.cputime[pid] = 0.0
                snap.ppid[pid] = ppid
                snap.name[pid] = name
                push!(get!(snap.children, ppid, Int[]), pid)
            end
            fr = ProcessMonitor.Frame(snap, Dict{Int,Float64}(), Float64[], 0.0, 0.0,
                (0.0, 0.0, 0.0), 0.0, 1, 0, 3, 0)
            st = ProcessMonitor.TopState(tree=true, sortkey=:name, rev=false)
            @test [row.name for row in ProcessMonitor._rows(st, fr)] ==
                  ["root", "alpha", "zeta"]
        end

        @testset "deep tree aggregation" begin
            n = 3_000
            snap = ProcessMonitor.Snapshot()
            for pid in 1:n
                parent = pid == 1 ? 0 : pid - 1
                snap.cputime[pid] = 1.0
                snap.rss[pid] = 2
                snap.threads[pid] = 1
                snap.ppid[pid] = parent
                snap.name[pid] = "process"
                push!(get!(snap.children, parent, Int[]), pid)
            end
            fr = ProcessMonitor.Frame(snap, Dict(pid => 1.0 for pid in 1:n),
                Float64[], 0.0, 0.0, (0.0, 0.0, 0.0), 0.0, 1, 0, n, n)
            st = ProcessMonitor.TopState(tree=true, aggregate=true, sortkey=:pid, rev=false)
            rows = ProcessMonitor._rows(st, fr)
            @test length(rows) == n
            @test (rows[1].threads, rows[1].rss, rows[1].cpu, rows[1].time) ==
                  (n, 2n, Float64(n), Float64(n))
            @test (rows[end].threads, rows[end].rss, rows[end].cpu, rows[end].time) ==
                  (1, 2, 1.0, 1.0)
        end

        @testset "PID identity and stable selection" begin
            previous = ProcessMonitor.Snapshot()
            current = ProcessMonitor.Snapshot()
            previous.cputime[7] = 10.0
            current.cputime[7] = 11.0
            previous.start[7] = 100.0
            current.start[7] = 100.0
            same = ProcessMonitor._frame(previous, current, Any[], Any[], 2.0)
            @test same.cpupct[7] ≈ 50.0
            current.start[7] = 110.0
            reused = ProcessMonitor._frame(previous, current, Any[], Any[], 2.0)
            @test reused.cpupct[7] == 0.0

            sampler = CPUSampler()
            sampler.start -= 10
            @test_throws ArgumentError cpu_percent(sampler)

            snap = ProcessMonitor.Snapshot()
            for (pid, name) in ((11, "one"), (22, "two"))
                snap.cputime[pid] = 1.0
                snap.name[pid] = name
            end
            frame1 = ProcessMonitor.Frame(snap, Dict(11 => 20.0, 22 => 10.0),
                Float64[], 0.0, 0.0, (0.0, 0.0, 0.0), 0.0, 1, 0, 2, 0)
            frame2 = ProcessMonitor.Frame(snap, Dict(11 => 5.0, 22 => 30.0),
                Float64[], 0.0, 0.0, (0.0, 0.0, 0.0), 0.0, 1, 0, 2, 0)
            state = ProcessMonitor.TopState()
            rows1 = ProcessMonitor._rows(state, frame1)
            ProcessMonitor._sync_selection!(state, rows1)
            @test state.sel == 0 && state.selpid == 0
            ProcessMonitor._select_row!(state, 1)
            ProcessMonitor._sync_selection!(state, rows1)
            @test state.sel == 1 && state.selpid == 11
            rows2 = ProcessMonitor._rows(state, frame2)
            ProcessMonitor._sync_selection!(state, rows2)
            @test state.sel == 2 && state.selpid == 11
            ProcessMonitor._select_row!(state, 1)
            ProcessMonitor._sync_selection!(state, rows2)
            @test state.sel == 1 && state.selpid == 22
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
            @test_throws ArgumentError CPUSampler(deadpid)
            @test_throws ArgumentError rss(deadpid)
            @test_throws ArgumentError ProcessMonitor.info(deadpid)
        end
    end
end
