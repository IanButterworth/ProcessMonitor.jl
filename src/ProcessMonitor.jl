module ProcessMonitor

# `info` is intentionally unexported (too generic a name to claim): use ProcessMonitor.info
export CPUSampler, cpu_percent, cpu_time, rss, thread_count

"""
    ProcessMonitor

Measure resource use of a process — CPU utilization, memory (RSS), and thread count —
optionally including the processes it spawns.

CPU utilization is derived by differencing two samples of a process's cumulative CPU time,
so it always describes an interval, never an instant; the core primitive is
[`CPUSampler`](@ref) (non-blocking, reusable for polling) and [`cpu_percent`](@ref) also has
a blocking convenience method. Memory ([`rss`](@ref)), [`thread_count`](@ref),
[`cpu_time`](@ref) and the combined [`info`](@ref) are point-in-time reads.

Process information is read without spawning any subprocess: from `/proc` on Linux (so it
works in minimal containers) and via libproc syscalls on macOS (so it works under sandboxes
that forbid executing `ps`). The BSDs use `ps`, which is always in the base system. The
`%cpu` column that `ps` and `top` report is deliberately avoided because it is a
platform-dependent decaying average (e.g. FreeBSD reports ~0); differencing cumulative CPU
time is portable.

Windows is not yet supported.
"""
ProcessMonitor

# One snapshot of the process table. Any per-pid field may be missing for processes we
# lack permission to inspect; lookups treat absence as "unknown", not zero.
struct Snapshot
    cputime::Dict{Int,Float64}      # cumulative CPU seconds, user+sys
    rss::Dict{Int,Int}              # resident set size, bytes
    threads::Dict{Int,Int}          # thread count
    children::Dict{Int,Vector{Int}} # ppid -> child pids
end
Snapshot() = Snapshot(Dict{Int,Float64}(), Dict{Int,Int}(), Dict{Int,Int}(), Dict{Int,Vector{Int}}())

function _snapshot()
    Sys.iswindows() && error("ProcessMonitor: Windows is not yet supported")
    Sys.islinux() && return _snapshot_proc()
    Sys.isapple() && return _snapshot_libproc()
    return _snapshot_ps()
end

# Linux: read everything straight from /proc/<pid>/stat.
function _snapshot_proc()
    s = Snapshot()
    hz = ccall(:sysconf, Clong, (Cint,), 2)  # _SC_CLK_TCK
    hz <= 0 && (hz = 100)
    pagesize = Int(ccall(:getpagesize, Cint, ()))
    names = try
        readdir("/proc")
    catch
        return s  # procfs not mounted
    end
    for name in names
        pid = tryparse(Int, name)
        pid === nothing && continue
        stat = try
            read("/proc/$name/stat", String)
        catch
            continue  # process vanished between readdir and read
        end
        # The comm field is parenthesised and may contain spaces or ')', so index the
        # numeric fields (state, ppid, ...) from after the last ')'.
        rp = findlast(')', stat)
        rp === nothing && continue
        f = split(SubString(stat, nextind(stat, rp)))
        length(f) >= 22 || continue
        ppid = tryparse(Int, f[2])
        utime = tryparse(Int, f[12])
        stime = tryparse(Int, f[13])
        nthr = tryparse(Int, f[18])
        rsspages = tryparse(Int, f[22])
        (ppid === nothing || utime === nothing || stime === nothing) && continue
        s.cputime[pid] = (utime + stime) / hz
        nthr === nothing || (s.threads[pid] = nthr)
        rsspages === nothing || (s.rss[pid] = rsspages * pagesize)
        push!(get!(s.children, ppid, Int[]), pid)
    end
    return s
end

# macOS: gather everything via libproc syscalls, without spawning a subprocess (some
# sandboxes forbid executing `ps`). proc_pid_rusage reports user+system time in mach ticks
# (converted with mach_timebase); proc_pidinfo(PROC_PIDTASKINFO) yields resident size and
# thread count, and proc_pidinfo(PROC_PIDTBSDINFO) the parent pid. These only succeed for
# own-uid processes, which is all we need.
function _snapshot_libproc()
    s = Snapshot()
    tb = Ref((UInt32(0), UInt32(0)))
    ccall(:mach_timebase_info, Cint, (Ptr{Cvoid},), tb) == 0 || return s
    numer, denom = tb[]
    (numer == 0 || denom == 0) && return s
    scale = numer / denom / 1e9  # mach ticks -> seconds (numer/denom is 1/1 on Intel)
    npids = ccall(:proc_listallpids, Cint, (Ptr{Cvoid}, Cint), C_NULL, 0)
    npids > 0 || return s
    pids = Vector{Cint}(undef, npids + 128)  # headroom for pids spawned since the count
    got = ccall(:proc_listallpids, Cint, (Ptr{Cint}, Cint), pids, sizeof(Cint) * length(pids))
    rb = Ref(ntuple(_ -> UInt64(0), 16))  # rusage_info_v0: uuid[16B], ri_user_time, ri_system_time, ...
    ti = Ref(ntuple(_ -> UInt64(0), 16))  # proc_taskinfo: virtual, resident, 4 more u64s, then int32s
    bi = Ref(ntuple(_ -> UInt32(0), 40))  # proc_bsdinfo: pbi_ppid is the 5th uint32
    for i in 1:min(got, length(pids))
        pid = Int(pids[i])
        pid > 0 || continue
        if ccall(:proc_pid_rusage, Cint, (Cint, Cint, Ptr{Cvoid}), pid, 0, rb) == 0
            t = rb[]
            s.cputime[pid] = (t[3] + t[4]) * scale
        end
        if ccall(:proc_pidinfo, Cint, (Cint, Cint, UInt64, Ptr{Cvoid}, Cint), pid, 4, 0, ti, 128) >= 96
            t = ti[]  # full 96-byte proc_taskinfo was filled
            s.rss[pid] = Int(t[2])              # pti_resident_size
            s.threads[pid] = Int(t[11] >> 32)   # pti_threadnum: 10th int32 after 6 uint64s
        end
        if ccall(:proc_pidinfo, Cint, (Cint, Cint, UInt64, Ptr{Cvoid}, Cint), pid, 3, 0, bi, 160) > 0
            push!(get!(s.children, Int(bi[][5]), Int[]), pid)
        end
    end
    return s
end

# BSD: one `ps` snapshot of the full process table. `nlwp` (thread count) is not
# universally supported, so fall back to a query without it.
function _snapshot_ps()
    s = Snapshot()
    # Separate `-o` flags (not `-o pid=,ppid=,...`): some BSD `ps` treat the text after
    # the first `=` as a header, collapsing the output to one column.
    for cols in (`-o pid= -o ppid= -o time= -o rss= -o nlwp=`, `-o pid= -o ppid= -o time= -o rss=`)
        raw = try
            read(`ps -A $cols`, String)
        catch
            continue
        end
        for line in eachline(IOBuffer(raw))
            f = split(line)
            length(f) >= 4 || continue
            pid = tryparse(Int, f[1])
            ppid = tryparse(Int, f[2])
            secs = _parse_cpu_time(f[3])
            rsskb = tryparse(Int, f[4])
            (pid === nothing || ppid === nothing || secs === nothing) && continue
            pid > 0 || continue  # e.g. the FreeBSD kernel is pid 0, its own parent
            s.cputime[pid] = secs
            rsskb === nothing || (s.rss[pid] = rsskb * 1024)
            if length(f) >= 5
                nthr = tryparse(Int, f[5])
                nthr === nothing || (s.threads[pid] = nthr)
            end
            push!(get!(s.children, ppid, Int[]), pid)
        end
        isempty(s.cputime) || break
    end
    return s
end

# Parse a `ps` TIME field ([[DD-]HH:]MM:SS[.ss]) into seconds.
function _parse_cpu_time(s)
    s = strip(s)
    days = 0
    d = findfirst('-', s)
    if d !== nothing
        dd = tryparse(Int, s[1:prevind(s, d)])
        dd === nothing && return nothing
        days = dd
        s = s[nextind(s, d):end]
    end
    total = 0.0
    mult = 1.0
    for p in Iterators.reverse(split(s, ':'))
        v = tryparse(Float64, p)
        v === nothing && return nothing
        total += v * mult
        mult *= 60
    end
    return total + days * 86400
end

# The pids of `root`'s subtree in `snap` (root first), or just `[root]` if not recursive.
# Guards against ppid cycles (e.g. pid 0 is its own parent on some systems).
function _tree(snap::Snapshot, root::Int, recursive::Bool)
    recursive || return [root]
    pids = Int[]
    seen = Set{Int}()
    stack = [root]
    while !isempty(stack)
        p = pop!(stack)
        p in seen && continue
        push!(seen, p)
        push!(pids, p)
        append!(stack, get(snap.children, p, Int[]))
    end
    return pids
end

_known(snap::Snapshot, pid::Int) =
    haskey(snap.cputime, pid) || haskey(snap.rss, pid) || haskey(snap.threads, pid)

function _checked_tree(snap::Snapshot, pid::Integer, recursive::Bool)
    _known(snap, Int(pid)) ||
        throw(ArgumentError("process $pid not found or not accessible"))
    return _tree(snap, Int(pid), recursive)
end

"""
    CPUSampler(pid::Integer = getpid(); recursive::Bool = false)
    CPUSampler(p::Base.Process; recursive::Bool = false)

Create a sampler that tracks the CPU utilization of process `pid`. Construction records a
baseline; each subsequent [`cpu_percent`](@ref) call reports the utilization since the
previous call (or since construction for the first call).

If `recursive` is `true`, CPU time spent in the process's subprocesses (recursively) is
included, which is usually what accounts for utilization above 100%.
"""
mutable struct CPUSampler
    pid::Int
    recursive::Bool
    prev::Dict{Int,Float64}
    prev_t::Float64
end

function CPUSampler(pid::Integer = getpid(); recursive::Bool = false)
    return CPUSampler(Int(pid), recursive, _snapshot().cputime, time())
end
CPUSampler(p::Base.Process; recursive::Bool = false) = CPUSampler(getpid(p); recursive)

"""
    cpu_percent(s::CPUSampler) -> Float64

Return the CPU utilization of `s`'s process since the previous `cpu_percent(s)` call (or
since the sampler was constructed), and re-arm the sampler. `100.0` means one CPU core was
fully used on average over the interval; a process using several cores can exceed `100.0`.
"""
function cpu_percent(s::CPUSampler)
    snap = _snapshot()
    now = time()
    dt = max(now - s.prev_t, eps())
    total = 0.0
    for p in _tree(snap, s.pid, s.recursive)
        haskey(snap.cputime, p) || continue
        d = snap.cputime[p] - get(s.prev, p, 0.0)
        d > 0 && (total += d)
    end
    s.prev = snap.cputime
    s.prev_t = now
    return 100 * total / dt
end

"""
    cpu_percent(pid::Integer = getpid(); recursive::Bool = false, interval::Real = 0.5) -> Float64
    cpu_percent(p::Base.Process; recursive::Bool = false, interval::Real = 0.5) -> Float64

Blocking convenience: sample process `pid`, sleep `interval` seconds, sample again, and
return the CPU utilization over that interval. See [`CPUSampler`](@ref) for the non-blocking
form and for the meaning of `recursive`.

Note: on the BSDs `ps` reports CPU time with one-second resolution, so very short intervals
quantize the result there; prefer an `interval` of at least a couple of seconds, or use a
[`CPUSampler`](@ref) over a longer polling period. Linux (`/proc`) and macOS (libproc) have
finer resolution.
"""
function cpu_percent(pid::Integer = getpid(); recursive::Bool = false, interval::Real = 0.5)
    s = CPUSampler(pid; recursive)
    sleep(interval)
    return cpu_percent(s)
end
cpu_percent(p::Base.Process; recursive::Bool = false, interval::Real = 0.5) =
    cpu_percent(getpid(p); recursive, interval)

"""
    cpu_time(pid::Integer = getpid(); recursive::Bool = false) -> Float64

Cumulative CPU time (user+system, in seconds) the process has used so far. With
`recursive`, subprocess CPU time is included — but only for subprocesses still alive at
the time of the call. Throws `ArgumentError` if the process is not found or not accessible.
"""
function cpu_time(pid::Integer = getpid(); recursive::Bool = false)
    snap = _snapshot()
    return sum(p -> get(snap.cputime, p, 0.0), _checked_tree(snap, pid, recursive))
end

"""
    rss(pid::Integer = getpid(); recursive::Bool = false) -> Int

Resident set size (physical memory in use) of the process, in bytes. With `recursive`, the
RSS of live subprocesses is added (note that pages shared between them are then counted
once per process). Throws `ArgumentError` if the process is not found or not accessible.
"""
function rss(pid::Integer = getpid(); recursive::Bool = false)
    snap = _snapshot()
    return sum(p -> get(snap.rss, p, 0), _checked_tree(snap, pid, recursive))
end

"""
    thread_count(pid::Integer = getpid(); recursive::Bool = false) -> Int

Number of OS threads in the process, summed over live subprocesses with `recursive`.
Throws `ArgumentError` if the process is not found or not accessible. May be 0 on
platforms where the thread count is unavailable (e.g. a BSD `ps` without `nlwp`).
"""
function thread_count(pid::Integer = getpid(); recursive::Bool = false)
    snap = _snapshot()
    return sum(p -> get(snap.threads, p, 0), _checked_tree(snap, pid, recursive))
end

"""
    info(pid::Integer = getpid(); recursive::Bool = false)
        -> (; cpu_time, rss, threads, processes)

Point-in-time summary of the process from a single snapshot: cumulative CPU seconds,
resident memory in bytes, OS thread count, and the number of processes counted (1, or the
live subtree size with `recursive`). Throws `ArgumentError` if the process is not found or
not accessible.
"""
function info(pid::Integer = getpid(); recursive::Bool = false)
    snap = _snapshot()
    pids = _checked_tree(snap, pid, recursive)
    return (;
        cpu_time = sum(p -> get(snap.cputime, p, 0.0), pids),
        rss = sum(p -> get(snap.rss, p, 0), pids),
        threads = sum(p -> get(snap.threads, p, 0), pids),
        processes = length(pids),
    )
end

for f in (:cpu_time, :rss, :thread_count, :info)
    @eval $f(p::Base.Process; recursive::Bool = false) = $f(getpid(p); recursive)
end

end # module
