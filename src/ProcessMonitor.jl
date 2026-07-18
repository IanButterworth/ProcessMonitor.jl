module ProcessMonitor

# `info` is intentionally unexported (too generic a name to claim): use ProcessMonitor.info
export CPUSampler, cpu_percent, cpu_time, rss, thread_count, top

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
    ppid::Dict{Int,Int}             # pid -> parent pid
    name::Dict{Int,String}          # pid -> short command name
    uid::Dict{Int,Int}              # pid -> owning user id
    exe::Dict{Int,String}           # pid -> executable path (full snapshots only)
    cmd::Dict{Int,String}           # pid -> full command line (full snapshots only)
    start::Dict{Int,Float64}        # pid -> start time, unix epoch seconds
    state::Dict{Int,Char}           # pid -> scheduler state (R/S/D/T/Z/I)
end
Snapshot() = Snapshot(Dict{Int,Float64}(), Dict{Int,Int}(), Dict{Int,Int}(),
    Dict{Int,Vector{Int}}(), Dict{Int,Int}(), Dict{Int,String}(), Dict{Int,Int}(),
    Dict{Int,String}(), Dict{Int,String}(), Dict{Int,Float64}(), Dict{Int,Char}())

_monotime() = time_ns() / 1e9

# Linux and macOS expose stable process start times. BSD `ps` only exposes elapsed time
# to one-second precision, so snapshots of the same process can differ slightly.
_same_start(a::Real, b::Real) =
    a > 0 && b > 0 && abs(a - b) <= ((Sys.islinux() || Sys.isapple()) ? 0.01 : 2.0)

# `full` additionally gathers executable paths and command lines (used by `top`); the
# plain API skips them so samplers stay cheap.
function _snapshot(; full::Bool = false)
    Sys.iswindows() && error("ProcessMonitor: Windows is not yet supported")
    Sys.islinux() && return _snapshot_proc(full)
    Sys.isapple() && return _snapshot_libproc(full)
    return _snapshot_ps(full)
end

# Boot time (unix epoch), needed to convert /proc starttime ticks; constant per boot.
const _BTIME = Ref(-1.0)
function _btime()
    if _BTIME[] < 0
        raw = try
            read("/proc/stat", String)
        catch
            ""
        end
        m = match(r"btime (\d+)", raw)
        _BTIME[] = m === nothing ? 0.0 : parse(Float64, m[1])
    end
    return _BTIME[]
end

# Linux: read everything straight from /proc/<pid>/stat.
function _snapshot_proc(full::Bool = false)
    s = Snapshot()
    hz = ccall(:sysconf, Clong, (Cint,), 2)  # _SC_CLK_TCK
    hz <= 0 && (hz = 100)
    btime = _btime()
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
        lp = findfirst('(', stat)
        rp = findlast(')', stat)
        (lp === nothing || rp === nothing || rp <= lp) && continue
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
        isempty(f[1]) || (s.state[pid] = f[1][1])
        startticks = tryparse(Int, f[20])
        (startticks === nothing || btime <= 0) || (s.start[pid] = btime + startticks / hz)
        s.name[pid] = String(SubString(stat, nextind(stat, lp), prevind(stat, rp)))
        st = try
            Base.stat("/proc/$name")
        catch
            nothing
        end
        st === nothing || (s.uid[pid] = Int(st.uid))
        s.ppid[pid] = ppid
        push!(get!(s.children, ppid, Int[]), pid)
        if full
            cmdline = try
                read("/proc/$name/cmdline", String)
            catch
                ""
            end
            isempty(cmdline) || (s.cmd[pid] = strip(replace(cmdline, '\0' => ' ')))
            exe = try
                readlink("/proc/$name/exe")
            catch
                ""  # EACCES for other users' processes
            end
            isempty(exe) || (s.exe[pid] = exe)
        end
    end
    return s
end

# macOS: gather everything via libproc syscalls, without spawning a subprocess (some
# sandboxes forbid executing `ps`). proc_pid_rusage reports user+system time in mach ticks
# (converted with mach_timebase); proc_pidinfo(PROC_PIDTASKINFO) yields resident size and
# thread count, and proc_pidinfo(PROC_PIDTBSDINFO) the parent pid. These only succeed for
# own-uid processes, which is all we need.
function _snapshot_libproc(full::Bool = false)
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
    bi = Ref(ntuple(_ -> UInt32(0), 40))  # proc_bsdinfo: pbi_pid, pbi_ppid, pbi_uid are the 4th-6th uint32s
    nb = zeros(UInt8, 64)
    pb = zeros(UInt8, 4096)
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
            b = bi[]
            s.ppid[pid] = Int(b[5])
            s.uid[pid] = Int(b[6])
            push!(get!(s.children, Int(b[5]), Int[]), pid)
            # pbi_status: 1=idle 2=run 3=sleep 4=stopped 5=zombie
            s.state[pid] = get(('I', 'R', 'S', 'T', 'Z'), Int(b[2]), '?')
            # pbi_start_tvsec: uint64 at byte offset 120
            s.start[pid] = Float64(UInt64(b[31]) | (UInt64(b[32]) << 32))
        end
        n = ccall(:proc_name, Cint, (Cint, Ptr{UInt8}, UInt32), pid, nb, length(nb))
        n > 0 && (s.name[pid] = String(nb[1:n]))
        if full
            n = ccall(:proc_pidpath, Cint, (Cint, Ptr{UInt8}, UInt32), pid, pb, length(pb))
            n > 0 && (s.exe[pid] = String(pb[1:n]))
            args = _procargs_apple(pid)
            isempty(args) || (s.cmd[pid] = join(args, ' '))
        end
    end
    return s
end

# macOS: recover a process's argv via sysctl KERN_PROCARGS2 (own-uid processes only).
# The buffer holds an int32 argc, the exec path, NUL padding, then argc NUL-separated args.
function _procargs_apple(pid::Int)
    mib = Cint[1, 49, pid]  # CTL_KERN, KERN_PROCARGS2, pid
    sz = Ref{Csize_t}(0)
    ccall(:sysctl, Cint, (Ptr{Cint}, Cuint, Ptr{Cvoid}, Ptr{Csize_t}, Ptr{Cvoid}, Csize_t),
        mib, 3, C_NULL, sz, C_NULL, 0) == 0 || return String[]
    buf = zeros(UInt8, sz[])
    ccall(:sysctl, Cint, (Ptr{Cint}, Cuint, Ptr{Cvoid}, Ptr{Csize_t}, Ptr{Cvoid}, Csize_t),
        mib, 3, buf, sz, C_NULL, 0) == 0 || return String[]
    length(buf) >= 4 || return String[]
    argc = reinterpret(Int32, buf[1:4])[1]
    i = 5
    while i <= length(buf) && buf[i] != 0x00; i += 1; end  # exec path
    while i <= length(buf) && buf[i] == 0x00; i += 1; end  # padding
    args = String[]
    for _ in 1:argc
        j = i
        while j <= length(buf) && buf[j] != 0x00; j += 1; end
        j > i && push!(args, String(buf[i:j-1]))
        i = j + 1
        i > length(buf) && break
    end
    return args
end

# BSD: one `ps` snapshot of the full process table. `nlwp` (thread count) is not
# universally supported, so fall back to a query without it. `comm` is requested last so
# names containing spaces can be reassembled from the remaining fields.
function _snapshot_ps(full::Bool = false)
    s = Snapshot()
    # Separate `-o` flags (not `-o pid=,ppid=,...`): some BSD `ps` treat the text after
    # the first `=` as a header, collapsing the output to one column. Every snapshot
    # requests elapsed time so samplers can distinguish PID reuse. Full snapshots also
    # request state and `args` (the whole command line) instead of `comm`.
    specs = if full
        ((8, true, `-o pid= -o ppid= -o time= -o rss= -o uid= -o nlwp= -o etime= -o state= -o args=`),
         (7, false, `-o pid= -o ppid= -o time= -o rss= -o uid= -o etime= -o state= -o args=`))
    else
        ((7, true, `-o pid= -o ppid= -o time= -o rss= -o uid= -o nlwp= -o etime= -o comm=`),
         (6, false, `-o pid= -o ppid= -o time= -o rss= -o uid= -o etime= -o comm=`))
    end
    nowt = time()
    for (nnum, hasthreads, cols) in specs
        raw = try
            read(`ps -A $cols`, String)
        catch
            continue
        end
        for line in eachline(IOBuffer(raw))
            f = split(line)
            length(f) >= nnum || continue
            pid = tryparse(Int, f[1])
            ppid = tryparse(Int, f[2])
            secs = _parse_cpu_time(f[3])
            rsskb = tryparse(Int, f[4])
            uid = tryparse(Int, f[5])
            (pid === nothing || ppid === nothing || secs === nothing) && continue
            pid > 0 || continue  # e.g. the FreeBSD kernel is pid 0, its own parent
            s.cputime[pid] = secs
            rsskb === nothing || (s.rss[pid] = rsskb * 1024)
            uid === nothing || (s.uid[pid] = uid)
            if hasthreads
                nthr = tryparse(Int, f[6])
                nthr === nothing || (s.threads[pid] = nthr)
            end
            elapsed = _parse_cpu_time(f[full ? nnum - 1 : nnum])
            elapsed === nothing || (s.start[pid] = nowt - elapsed)
            if full
                isempty(f[nnum]) || (s.state[pid] = f[nnum][1])
            end
            if length(f) > nnum
                rest = join(f[nnum+1:end], ' ')
                if full
                    s.cmd[pid] = rest
                    exe = first(split(rest, ' '))
                    s.exe[pid] = exe
                    s.name[pid] = basename(exe)
                else
                    s.name[pid] = basename(rest)
                end
            end
            s.ppid[pid] = ppid
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

function _require_metric(pids, values, metric::AbstractString;
        allow_globally_unavailable::Bool = false)
    allow_globally_unavailable && isempty(values) && return pids
    missing_index = findfirst(p -> !haskey(values, p), pids)
    missing_index === nothing ||
        throw(ArgumentError("$metric unavailable for process $(pids[missing_index])"))
    return pids
end

function _checked_metric_tree(snap::Snapshot, pid::Integer, recursive::Bool, values,
        metric::AbstractString; allow_globally_unavailable::Bool = false)
    pids = _checked_tree(snap, pid, recursive)
    return _require_metric(pids, values, metric; allow_globally_unavailable)
end

"""
    CPUSampler(pid::Integer = getpid(); recursive::Bool = false)
    CPUSampler(p::Base.Process; recursive::Bool = false)

Create a sampler that tracks the CPU utilization of process `pid`. Construction records a
baseline; each subsequent [`cpu_percent`](@ref) call reports the utilization since the
previous call (or since construction for the first call).

If `recursive` is `true`, CPU time spent in the process's subprocesses (recursively) is
included, which is usually what accounts for utilization above 100%.

Throws `ArgumentError` if the process is not found, cannot be inspected, or its identity
cannot be established.
"""
mutable struct CPUSampler
    pid::Int
    recursive::Bool
    start::Float64
    prev::Dict{Int,Float64}
    prev_start::Dict{Int,Float64}
    prev_t::Float64
end

function CPUSampler(pid::Integer = getpid(); recursive::Bool = false)
    root = Int(pid)
    snap = _snapshot()
    haskey(snap.cputime, root) ||
        throw(ArgumentError("process $pid not found or not accessible"))
    start = get(snap.start, root, -1.0)
    start > 0 || throw(ArgumentError("start time unavailable for process $pid"))
    return CPUSampler(root, recursive, start, snap.cputime, snap.start, _monotime())
end
CPUSampler(p::Base.Process; recursive::Bool = false) = CPUSampler(getpid(p); recursive)

"""
    cpu_percent(s::CPUSampler) -> Float64

Return the CPU utilization of `s`'s process since the previous `cpu_percent(s)` call (or
since the sampler was constructed), and re-arm the sampler. `100.0` means one CPU core was
fully used on average over the interval; a process using several cores can exceed `100.0`.
Throws `ArgumentError` if the original process exited or its PID changed identity.
"""
function cpu_percent(s::CPUSampler)
    snap = _snapshot()
    now = _monotime()
    haskey(snap.cputime, s.pid) && _same_start(s.start, get(snap.start, s.pid, -1.0)) ||
        throw(ArgumentError("process $(s.pid) exited or changed identity"))
    dt = max(now - s.prev_t, eps())
    total = 0.0
    for p in _tree(snap, s.pid, s.recursive)
        haskey(snap.cputime, p) || continue
        # A new descendant, or a reused descendant PID, has no valid baseline yet.
        previous = haskey(s.prev, p) &&
                   _same_start(get(s.prev_start, p, -1.0), get(snap.start, p, -1.0)) ?
                   s.prev[p] : snap.cputime[p]
        d = snap.cputime[p] - previous
        d > 0 && (total += d)
    end
    s.prev = snap.cputime
    s.prev_start = snap.start
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
    pids = _checked_metric_tree(snap, pid, recursive, snap.cputime, "CPU time")
    return sum(p -> snap.cputime[p], pids)
end

"""
    rss(pid::Integer = getpid(); recursive::Bool = false) -> Int

Resident set size (physical memory in use) of the process, in bytes. With `recursive`, the
RSS of live subprocesses is added (note that pages shared between them are then counted
once per process). Throws `ArgumentError` if the process is not found or not accessible.
"""
function rss(pid::Integer = getpid(); recursive::Bool = false)
    snap = _snapshot()
    pids = _checked_metric_tree(snap, pid, recursive, snap.rss, "RSS")
    return sum(p -> snap.rss[p], pids)
end

"""
    thread_count(pid::Integer = getpid(); recursive::Bool = false) -> Int

Number of OS threads in the process, summed over live subprocesses with `recursive`.
Throws `ArgumentError` if the process is not found or not accessible. May be 0 on
platforms where the thread count is unavailable (e.g. a BSD `ps` without `nlwp`).
"""
function thread_count(pid::Integer = getpid(); recursive::Bool = false)
    snap = _snapshot()
    pids = _checked_metric_tree(snap, pid, recursive, snap.threads, "thread count";
        allow_globally_unavailable = true)
    return sum(p -> get(snap.threads, p, 0), pids)
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
    _require_metric(pids, snap.cputime, "CPU time")
    _require_metric(pids, snap.rss, "RSS")
    _require_metric(pids, snap.threads, "thread count"; allow_globally_unavailable = true)
    return (;
        cpu_time = sum(p -> snap.cputime[p], pids),
        rss = sum(p -> snap.rss[p], pids),
        threads = sum(p -> get(snap.threads, p, 0), pids),
        processes = length(pids),
    )
end

for f in (:cpu_time, :rss, :thread_count, :info)
    @eval $f(p::Base.Process; recursive::Bool = false) = $f(getpid(p); recursive)
end

include("top.jl")

end # module
