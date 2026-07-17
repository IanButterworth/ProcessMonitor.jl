module CPUMonitor

export CPUSampler, cpu_percent

"""
    CPUMonitor

Measure the CPU utilization of a process, optionally including the processes it spawns.

Utilization is derived by differencing two samples of a process's cumulative CPU time, so
it always describes an interval, never an instant. The core primitive is [`CPUSampler`](@ref)
(non-blocking, reusable for polling); [`cpu_percent`](@ref) also has a blocking convenience
method that samples over a fixed interval for you.

CPU time is read without spawning any subprocess: from `/proc` on Linux (so it works in
minimal containers) and via libproc syscalls on macOS (so it works under sandboxes that
forbid executing `ps`). The BSDs use `ps`, which is always in the base system. The `%cpu`
column that `ps` and `top` report is deliberately avoided because it is a platform-dependent
decaying average (e.g. FreeBSD reports ~0); differencing cumulative CPU time is portable.

Windows is not yet supported.
"""
CPUMonitor

# Cumulative CPU time (seconds, user+sys) and parent pid for every process, from one
# snapshot. Throws on Windows.
function _snapshot()
    Sys.iswindows() && error("CPUMonitor: Windows is not yet supported")
    Sys.islinux() && return _snapshot_proc()
    Sys.isapple() && return _snapshot_libproc()
    return _snapshot_ps()
end

# macOS: gather CPU time and parent links via libproc syscalls, without spawning a
# subprocess (some sandboxes forbid executing `ps`). proc_pid_rusage reports user+system
# time in mach ticks (converted with mach_timebase); proc_pidinfo(PROC_PIDTBSDINFO) gives
# the parent pid. Both only succeed for own-uid processes, which is all we need.
function _snapshot_libproc()
    cputime = Dict{Int,Float64}()
    children = Dict{Int,Vector{Int}}()
    tb = Ref((UInt32(0), UInt32(0)))
    ccall(:mach_timebase_info, Cint, (Ptr{Cvoid},), tb) == 0 || return cputime, children
    numer, denom = tb[]
    (numer == 0 || denom == 0) && return cputime, children
    scale = numer / denom / 1e9  # mach ticks -> seconds (numer/denom is 1/1 on Intel)
    npids = ccall(:proc_listallpids, Cint, (Ptr{Cvoid}, Cint), C_NULL, 0)
    npids > 0 || return cputime, children
    pids = Vector{Cint}(undef, npids + 128)  # headroom for pids spawned since the count
    got = ccall(:proc_listallpids, Cint, (Ptr{Cint}, Cint), pids, sizeof(Cint) * length(pids))
    rb = Ref(ntuple(_ -> UInt64(0), 16))  # rusage_info_v0: uuid[16B], ri_user_time, ri_system_time, ...
    bi = Ref(ntuple(_ -> UInt32(0), 40))  # proc_bsdinfo: pbi_ppid is the 5th uint32
    for i in 1:min(got, length(pids))
        pid = Int(pids[i])
        pid > 0 || continue
        if ccall(:proc_pid_rusage, Cint, (Cint, Cint, Ptr{Cvoid}), pid, 0, rb) == 0
            t = rb[]
            cputime[pid] = (t[3] + t[4]) * scale
        end
        if ccall(:proc_pidinfo, Cint, (Cint, Cint, UInt64, Ptr{Cvoid}, Cint), pid, 3, 0, bi, 160) > 0
            push!(get!(children, Int(bi[][5]), Int[]), pid)
        end
    end
    return cputime, children
end

# Linux: read utime+stime and ppid straight from /proc/<pid>/stat.
function _snapshot_proc()
    cputime = Dict{Int,Float64}()
    children = Dict{Int,Vector{Int}}()
    hz = ccall(:sysconf, Clong, (Cint,), 2)  # _SC_CLK_TCK
    hz <= 0 && (hz = 100)
    for name in readdir("/proc")
        pid = tryparse(Int, name)
        pid === nothing && continue
        stat = try
            read("/proc/$name/stat", String)
        catch
            continue  # process vanished between readdir and read
        end
        # The comm field is parenthesised and may contain spaces or ')', so index the
        # numeric fields (state, ppid, ..., utime, stime) from after the last ')'.
        rp = findlast(')', stat)
        rp === nothing && continue
        f = split(SubString(stat, nextind(stat, rp)))
        length(f) >= 13 || continue
        ppid = tryparse(Int, f[2])
        utime = tryparse(Int, f[12])
        stime = tryparse(Int, f[13])
        (ppid === nothing || utime === nothing || stime === nothing) && continue
        cputime[pid] = (utime + stime) / hz
        push!(get!(children, ppid, Int[]), pid)
    end
    return cputime, children
end

# BSD: one `ps` snapshot of the full process table.
function _snapshot_ps()
    cputime = Dict{Int,Float64}()
    children = Dict{Int,Vector{Int}}()
    # Separate `-o` flags (not `-o pid=,ppid=,time=`): some BSD `ps` treat the text after
    # the first `=` as a header, collapsing the output to one column.
    raw = read(`ps -A -o pid= -o ppid= -o time=`, String)
    for line in eachline(IOBuffer(raw))
        f = split(line)
        length(f) == 3 || continue
        pid = tryparse(Int, f[1])
        ppid = tryparse(Int, f[2])
        secs = _parse_cpu_time(f[3])
        (pid === nothing || ppid === nothing || secs === nothing) && continue
        cputime[pid] = secs
        push!(get!(children, ppid, Int[]), pid)
    end
    return cputime, children
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

# CPU seconds accrued by `root` (and, if `recursive`, its whole subtree) between the
# `prev` snapshot and the current `cputime`/`children` tables.
function _delta_seconds(root, prev, cputime, children, recursive)
    total = 0.0
    stack = [root]
    while !isempty(stack)
        p = pop!(stack)
        if haskey(cputime, p)
            d = cputime[p] - get(prev, p, 0.0)
            d > 0 && (total += d)
        end
        recursive && append!(stack, get(children, p, Int[]))
    end
    return total
end

"""
    CPUSampler(pid::Integer = getpid(); recursive::Bool = false)
    CPUSampler(p::Base.Process; recursive::Bool = false)

Create a sampler that tracks the CPU utilization of process `pid`. Construction records a
baseline; each subsequent [`cpu_percent`](@ref) call reports the utilization since the
previous call (or since construction for the first call).

If `recursive` is `true`, CPU time spent in the process's subprocesses (recursively) is
included.
"""
mutable struct CPUSampler
    pid::Int
    recursive::Bool
    prev::Dict{Int,Float64}
    prev_t::Float64
end

function CPUSampler(pid::Integer = getpid(); recursive::Bool = false)
    cputime, _ = _snapshot()
    return CPUSampler(Int(pid), recursive, cputime, time())
end
CPUSampler(p::Base.Process; recursive::Bool = false) = CPUSampler(getpid(p); recursive)

"""
    cpu_percent(s::CPUSampler) -> Float64

Return the CPU utilization of `s`'s process since the previous `cpu_percent(s)` call (or
since the sampler was constructed), and re-arm the sampler. `100.0` means one CPU core was
fully used on average over the interval; a process using several cores can exceed `100.0`.
"""
function cpu_percent(s::CPUSampler)
    cputime, children = _snapshot()
    now = time()
    dt = max(now - s.prev_t, eps())
    secs = _delta_seconds(s.pid, s.prev, cputime, children, s.recursive)
    s.prev = cputime
    s.prev_t = now
    return 100 * secs / dt
end

"""
    cpu_percent(pid::Integer = getpid(); recursive::Bool = false, interval::Real = 0.5) -> Float64
    cpu_percent(p::Base.Process; recursive::Bool = false, interval::Real = 0.5) -> Float64

Blocking convenience: sample process `pid`, sleep `interval` seconds, sample again, and
return the CPU utilization over that interval. See [`CPUSampler`](@ref) for the non-blocking
form and for the meaning of `recursive`.

Note: on macOS/BSD `ps` reports CPU time with one-second resolution, so very short intervals
quantize the result there; prefer an `interval` of at least a couple of seconds, or use a
[`CPUSampler`](@ref) over a longer polling period. Linux (`/proc`) has finer resolution.
"""
function cpu_percent(pid::Integer = getpid(); recursive::Bool = false, interval::Real = 0.5)
    s = CPUSampler(pid; recursive)
    sleep(interval)
    return cpu_percent(s)
end
cpu_percent(p::Base.Process; recursive::Bool = false, interval::Real = 0.5) =
    cpu_percent(getpid(p); recursive, interval)

end # module
