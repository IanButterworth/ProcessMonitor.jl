# An htop-like interactive terminal view built on Snapshot differencing.

import REPL
using Printf: @sprintf

const SPARK = ('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')
const HIST_LEN = 120

mutable struct TopState
    sortkey::Symbol        # :cpu, :mem, :pid, :time, :threads, :name
    rev::Bool              # true = descending (the default for usage columns)
    tree::Bool
    aggregate::Bool        # tree mode: roll subtree usage up into each row
    mine::Bool             # only this uid's processes
    juliaonly::Bool        # only Julia processes
    showcmd::Bool          # show full command lines instead of names
    filter::String
    filtering::Bool        # currently typing into the filter
    sel::Int               # selected row (1-based, into visible rows)
    scroll::Int
    paused::Bool
    interval::Float64
    running::Bool
    cpuhist::Vector{Float64}
    memhist::Vector{Float64}
    message::String        # transient status line (e.g. after a kill)
end
TopState(; interval = 2.0, tree = false) = TopState(:cpu, true, tree, false, false, false,
    false, "", false, 1, 0, false, interval, true, Float64[], Float64[], "")

struct Frame
    snap::Snapshot
    cpupct::Dict{Int,Float64}   # per-pid CPU% over the interval
    percore::Vector{Float64}    # per-core busy fraction 0..1
    loadavg::NTuple{3,Float64}
    uptime::Float64
    memtotal::Int
    memused::Int
    nprocs::Int
    nthreads::Int
end

_cpu_busy_idle(c) = (
    getfield(c, Symbol("cpu_times!user")) + getfield(c, Symbol("cpu_times!nice")) +
    getfield(c, Symbol("cpu_times!sys")) + getfield(c, Symbol("cpu_times!irq")),
    getfield(c, Symbol("cpu_times!idle")))

function _frame(prev::Snapshot, snap::Snapshot, prevcores, cores, dt::Float64)
    cpupct = Dict{Int,Float64}()
    for (pid, t) in snap.cputime
        d = t - get(prev.cputime, pid, t)  # unseen pid: no baseline, report 0 not a spike
        cpupct[pid] = 100 * max(d, 0.0) / dt
    end
    percore = Float64[]
    for i in 1:min(length(cores), length(prevcores))
        b1, i1 = _cpu_busy_idle(prevcores[i])
        b2, i2 = _cpu_busy_idle(cores[i])
        db, di = b2 - b1, i2 - i1
        push!(percore, db + di > 0 ? db / (db + di) : 0.0)
    end
    la = Sys.loadavg()
    memtotal = Int(Sys.total_memory())
    return Frame(snap, cpupct, percore, (la[1], la[2], la[3]), Sys.uptime(),
        memtotal, _mem_used(memtotal), length(snap.cputime), sum(values(snap.threads); init = 0))
end

# Memory actually in use. `total - free` badly overstates this on macOS (free excludes
# inactive/cache pages) and Linux (excludes buffers/cache), so use each platform's real
# accounting: active+wired+compressed from host_statistics64 on macOS (what Activity
# Monitor calls "memory used"), total-MemAvailable on Linux.
function _mem_used(memtotal::Int)
    if Sys.isapple()
        # vm_statistics64: free/active/inactive/wire counts lead; compressor_page_count
        # is at byte offset 128. HOST_VM_INFO64 = 4, HOST_VM_INFO64_COUNT = 38.
        buf = zeros(UInt32, 38)
        cnt = Ref{UInt32}(38)
        host = ccall(:mach_host_self, UInt32, ())
        if ccall(:host_statistics64, Cint, (UInt32, Cint, Ptr{Cvoid}, Ptr{UInt32}),
                 host, 4, buf, cnt) == 0
            pagesize = Int(ccall(:getpagesize, Cint, ()))
            active, wire = Int(buf[2]), Int(buf[4])
            compressor = Int(buf[33])  # compressor_page_count
            return min((active + wire + compressor) * pagesize, memtotal)
        end
    elseif Sys.islinux()
        avail = try
            m = match(r"MemAvailable:\s+(\d+) kB", read("/proc/meminfo", String))
            m === nothing ? nothing : parse(Int, m[1]) * 1024
        catch
            nothing
        end
        avail === nothing || return clamp(memtotal - avail, 0, memtotal)
    end
    return clamp(memtotal - Int(Sys.free_memory()), 0, memtotal)
end

# ---- formatting helpers ----

function _fmtbytes(b::Real)
    b < 0 && return "?"
    for (u, s) in ((1 << 30, "G"), (1 << 20, "M"), (1 << 10, "K"))
        if b >= u
            v = b / u
            return v >= 10 ? @sprintf("%.0f%s", v, s) : @sprintf("%.1f%s", v, s)
        end
    end
    return string(round(Int, b))
end

function _fmttime(secs::Real)
    s = round(Int, secs)
    h, rem = divrem(s, 3600)
    m, ss = divrem(rem, 60)
    return h > 0 ? @sprintf("%d:%02d:%02d", h, m, ss) : @sprintf("%d:%02d", m, ss)
end

function _fmtuptime(secs::Real)
    d, rem = divrem(round(Int, secs), 86400)
    h, rem2 = divrem(rem, 3600)
    m = rem2 ÷ 60
    return d > 0 ? @sprintf("%dd %d:%02d", d, h, m) : @sprintf("%d:%02d", h, m)
end

_pctcolor(f) = f < 0.60 ? "\e[32m" : f < 0.85 ? "\e[33m" : "\e[31m"

function _bar(frac::Float64, width::Int; color::Bool = true)
    frac = clamp(frac, 0.0, 1.0)
    cells = frac * width
    full = floor(Int, cells)
    part = cells - full
    partial = part > 0.125 ? SPARK[clamp(round(Int, part * 8), 1, 8)] : ' '
    body = repeat('█', full) * (full < width ? string(partial) : "") *
           repeat(' ', max(width - full - (full < width ? 1 : 0), 0))
    return color ? string(_pctcolor(frac), body, "\e[0m") : body
end

function _spark(vals::Vector{Float64}, width::Int; color::Bool = true)
    isempty(vals) && return repeat(' ', width)
    v = vals[max(end - width + 1, 1):end]
    io = IOBuffer()
    for x in v
        f = clamp(x, 0.0, 1.0)
        color && print(io, _pctcolor(f))
        print(io, SPARK[clamp(ceil(Int, f * 8), 1, 8)])
    end
    color && print(io, "\e[0m")
    print(io, repeat(' ', width - length(v)))
    return String(take!(io))
end

const _USERNAMES = Dict{Int,String}()
function _username(uid::Int)
    get!(_USERNAMES, uid) do
        pw = ccall(:getpwuid, Ptr{Ptr{UInt8}}, (Cuint,), uid % Cuint)
        pw == C_NULL ? string(uid) : unsafe_string(unsafe_load(pw))
    end
end

_ellipsize(s::AbstractString, w::Int) =
    textwidth(s) <= w ? rpad(s, w) : first(s, max(w - 1, 0)) * "…"

# ---- Julia awareness ----

_isjulia(snap::Snapshot, pid::Integer) =
    get(snap.name, Int(pid), "") == "julia" ||
    startswith(basename(get(snap.exe, Int(pid), "")), "julia")

# Best-effort Julia version from the executable path: juliaup installs embed the full
# version (julia-1.12.6+0.arch...), mac app bundles the minor (Julia-1.12.app), and an
# in-tree build (usr/bin/julia) is labeled "dev". Empty when unknown.
function _julia_version_from_path(exe::AbstractString)
    isempty(exe) && return ""
    m = match(r"julia-(\d+\.\d+\.\d+)", exe)
    m === nothing || return m[1]
    m = match(r"[Jj]ulia-(\d+\.\d+)", exe)
    m === nothing || return m[1]
    occursin(r"usr/bin/julia$", exe) && return "dev"
    return ""
end

# ---- row assembly ----

struct Row
    pid::Int
    depth::Int          # tree indentation level
    lastchild::Bool
    name::String
    uid::Int
    threads::Int
    rss::Int
    cpu::Float64        # percent
    time::Float64       # cumulative seconds
    isjulia::Bool
    ver::String         # Julia version label ("" when unknown / not Julia)
    cmd::String         # full command line ("" when unavailable)
end

function _match(st::TopState, snap::Snapshot, pid::Int)
    st.juliaonly && !_isjulia(snap, pid) && return false
    if st.mine
        uid = get(snap.uid, pid, -1)
        uid == -1 || uid == Int(ccall(:getuid, Cuint, ())) || return false
    end
    if !isempty(st.filter)
        name = get(snap.name, pid, "")
        occursin(lowercase(st.filter), lowercase(name)) ||
            occursin(lowercase(st.filter), lowercase(get(snap.cmd, pid, ""))) ||
            occursin(st.filter, string(pid)) || return false
    end
    return true
end

_sortval(st::TopState, r::Row) =
    st.sortkey === :cpu ? r.cpu :
    st.sortkey === :mem ? Float64(r.rss) :
    st.sortkey === :pid ? Float64(r.pid) :
    st.sortkey === :time ? r.time :
    st.sortkey === :threads ? Float64(r.threads) : 0.0

function _mkrow(fr::Frame, pid::Int, depth::Int, lastchild::Bool, agg::Bool)
    snap = fr.snap
    pids = agg ? _tree(snap, pid, true) : (pid,)
    isjulia = _isjulia(snap, pid)
    return Row(pid, depth, lastchild,
        get(snap.name, pid, "?"),
        get(snap.uid, pid, -1),
        sum(p -> get(snap.threads, p, 0), pids),
        sum(p -> get(snap.rss, p, 0), pids),
        sum(p -> get(fr.cpupct, p, 0.0), pids),
        sum(p -> get(snap.cputime, p, 0.0), pids),
        isjulia,
        isjulia ? _julia_version_from_path(get(snap.exe, pid, "")) : "",
        get(snap.cmd, pid, ""))
end

function _rows(st::TopState, fr::Frame)
    snap = fr.snap
    allpids = union(keys(snap.cputime), keys(snap.ppid))
    if !st.tree
        rows = Row[_mkrow(fr, pid, 0, false, false) for pid in allpids if _match(st, snap, pid)]
        by = st.sortkey === :name ? (r -> lowercase(r.name)) : (r -> _sortval(st, r))
        sort!(rows; by, rev = st.rev && st.sortkey !== :name)
        return rows
    end
    # Tree mode: DFS from the roots, sorting siblings by the sort key. A filtered-out
    # process is still shown (dimmed by depth only) if a descendant matches, so trees
    # stay connected.
    rows = Row[]
    keep = Dict{Int,Bool}()
    function matches_below(pid)::Bool
        get!(keep, pid) do
            _match(st, snap, pid) || any(matches_below, get(snap.children, pid, Int[]))
        end
    end
    roots = sort!([pid for pid in allpids
                   if !haskey(snap.ppid, pid) || snap.ppid[pid] == pid ||
                      !(snap.ppid[pid] in allpids)])
    seen = Set{Int}()
    function walk(pid, depth, lastchild)
        pid in seen && return
        push!(seen, pid)
        matches_below(pid) || return
        push!(rows, _mkrow(fr, pid, depth, lastchild, st.aggregate))
        kids = [k for k in get(snap.children, pid, Int[]) if matches_below(k)]
        sort!(kids; by = k -> _sortval(st, _mkrow(fr, k, 0, false, st.aggregate)), rev = st.rev)
        for (i, k) in enumerate(kids)
            walk(k, depth + 1, i == length(kids))
        end
    end
    for r in roots
        walk(r, 0, false)
    end
    return rows
end

# ---- rendering ----

function _render(io::IO, st::TopState, fr::Frame; interactive::Bool = true, color::Bool = true)
    rows_avail, width = displaysize(io)
    height = max(rows_avail, 12)
    width = max(width, 60)
    buf = IOBuffer()
    c(s) = color ? s : ""
    interactive && print(buf, "\e[H")
    eol = interactive ? "\e[K\n" : "\n"

    syscpu = isempty(fr.percore) ? 0.0 : sum(fr.percore) / length(fr.percore)
    memfrac = fr.memtotal > 0 ? fr.memused / fr.memtotal : 0.0

    # header
    print(buf, c("\e[1m"), " ProcessMonitor", c("\e[0m"),
        "  ", gethostname(),
        "  up ", _fmtuptime(fr.uptime),
        @sprintf("  load %.2f %.2f %.2f", fr.loadavg...),
        "  ", length(fr.percore), " cores  ",
        fr.nprocs, " procs  ", fr.nthreads, " thr",
        st.paused ? c("\e[33m") * "  ⏸ paused" * c("\e[0m") : "", eol)

    barw = max(min(width ÷ 4, 30), 10)
    sparkw = max(min(width - barw - 30, HIST_LEN), 10)
    print(buf, " CPU ", c("▕"), _bar(syscpu, barw; color),
        c("▏"), @sprintf("%5.1f%% ", 100syscpu), _spark(st.cpuhist, sparkw; color), eol)
    print(buf, " MEM ", c("▕"), _bar(memfrac, barw; color), c("▏"),
        @sprintf("%5.1f%% ", 100memfrac), _spark(st.memhist, sparkw; color),
        "  ", _fmtbytes(fr.memused), "/", _fmtbytes(fr.memtotal), eol)
    # per-core bars plus a Julia rollup: how much of the machine is Julia right now
    print(buf, " cores ", _spark(fr.percore, length(fr.percore); color))
    jpids = [pid for pid in keys(fr.snap.cputime) if _isjulia(fr.snap, pid)]
    if !isempty(jpids)
        jcpu = sum(p -> get(fr.cpupct, p, 0.0), jpids)
        jrss = sum(p -> get(fr.snap.rss, p, 0), jpids)
        jthr = sum(p -> get(fr.snap.threads, p, 0), jpids)
        print(buf, "   ", c("\e[35m"), "julia: ", length(jpids), " procs  ",
            @sprintf("%.0f%%", jcpu), "  ", _fmtbytes(jrss), "  ", jthr, " thr", c("\e[0m"))
    end
    print(buf, eol)

    # column header
    agg = st.tree && st.aggregate ? "Σ" : ""
    namew = max(width - 48, 8)
    sortmark(k) = st.sortkey === k ? "▾" : " "
    print(buf, c("\e[7m"),
        lpad("PID", 7), " ",
        rpad("USER", 8), " ",
        _ellipsize("NAME" * sortmark(:name), namew), " ",
        lpad("THR" * sortmark(:threads), 5), " ",
        lpad(agg * "RSS" * sortmark(:mem), 7), " ",
        lpad("TIME" * sortmark(:time), 8), " ",
        lpad(agg * "CPU%" * sortmark(:cpu), 7),
        c("\e[0m"), eol)

    rows = _rows(st, fr)
    # Interactive mode fits the terminal; a single-frame dump includes every row.
    nbody = interactive ? height - 7 : length(rows)
    st.sel = clamp(st.sel, 1, max(length(rows), 1))
    st.scroll = clamp(st.scroll, 0, max(length(rows) - nbody, 0))
    if st.sel <= st.scroll
        st.scroll = st.sel - 1
    elseif st.sel > st.scroll + nbody
        st.scroll = st.sel - nbody
    end
    self = getpid()
    for i in (st.scroll + 1):min(st.scroll + nbody, length(rows))
        r = rows[i]
        selected = interactive && i == st.sel
        prefix = r.depth == 0 ? "" : repeat("  ", r.depth - 1) * (r.lastchild ? "└─" : "├─")
        cpufrac = r.cpu / 100 / max(length(fr.percore), 1)
        selected && print(buf, c("\e[7m"))
        # Julia processes: magenta name, version label, and (with `C`) the command line
        label = if st.showcmd && !isempty(r.cmd)
            r.cmd
        elseif r.isjulia && !isempty(r.ver)
            string(r.name, " ", r.ver)
        else
            r.name
        end
        print(buf, lpad(r.pid, 7), " ",
            c(r.uid == Int(ccall(:getuid, Cuint, ())) ? "\e[36m" : "\e[2m"),
            rpad(_ellipsize(r.uid < 0 ? "?" : _username(r.uid), 8), 8), c("\e[0m"),
            selected ? c("\e[7m") : "", " ",
            r.pid == self ? c("\e[1m") : r.isjulia ? c("\e[35m") : "",
            _ellipsize(prefix * label, namew), c(selected ? "" : "\e[0m"), " ",
            lpad(r.threads == 0 ? "?" : string(r.threads), 5), " ",
            lpad(_fmtbytes(r.rss), 7), " ",
            lpad(_fmttime(r.time), 8), " ",
            c(selected ? "" : _pctcolor(cpufrac)),
            lpad(@sprintf("%.1f", r.cpu), 7), c("\e[0m"), eol)
    end
    if interactive
        for _ in (length(rows) - st.scroll):(nbody - 1)
            print(buf, eol)
        end
        # footer
        if st.filtering
            print(buf, c("\e[1m"), " filter: ", st.filter, "▌", c("\e[0m"),
                "  (enter to apply, esc to clear)", "\e[K")
        elseif !isempty(st.message)
            print(buf, c("\e[33m"), " ", st.message, c("\e[0m"), "\e[K")
        else
            print(buf, c("\e[2m"),
                " q quit  c/m/p/t/n sort  T tree  a Σ  j julia  C cmd  / filter  u mine  ↑↓  ",
                "k/K kill  +/- (", round(st.interval, digits = 1), "s)  space pause",
                c("\e[0m"), "\e[K")
        end
    end
    write(io, take!(buf))
    return length(rows)
end

# ---- interactive loop ----

"""
    top(; interval::Real = 2.0, tree::Bool = false)

An interactive, `htop`-like view of the system's processes, built on the same snapshot
machinery as the rest of the package. Requires an interactive terminal; `top(io)` renders
a single non-interactive frame to any `IO` instead.

Header: system CPU and memory with scrolling history sparklines, one mini-bar per core,
load averages, uptime, and process/thread totals. Below it, the process table.

Keys:
- `q`/`Ctrl-C` — quit; `space` — pause
- `c`/`m`/`t`/`p`/`n` — sort by CPU, memory, CPU time, pid, or name
- `T` — toggle tree view; `a` — in tree view, roll each subtree's CPU/RSS up into its row
- `/` — filter by name or pid substring (`enter` applies, `esc` clears); `u` — only your
  own processes
- `↑`/`↓`/`PgUp`/`PgDn` — select; `k` sends SIGTERM, `K` sends SIGKILL to the selection
- `+`/`-` — change the refresh interval
"""
function top(; interval::Real = 2.0, tree::Bool = false)
    Sys.iswindows() && error("ProcessMonitor: Windows is not yet supported")
    stdout isa Base.TTY || error("top() needs an interactive terminal; use top(io) for one frame")
    st = TopState(; interval = Float64(interval), tree)
    term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", ""), stdin, stdout, stderr)
    keych = Channel{Char}(64)
    reader = @async try
        while isopen(keych)
            put!(keych, Char(read(stdin, UInt8)))
        end
    catch
    end
    REPL.Terminals.raw!(term, true)
    print(stdout, "\e[?1049h\e[?25l\e[2J")  # alternate screen, hide cursor
    prev = _snapshot(full = true)
    prevcores = Sys.cpu_info()
    prevt = time()
    fr = nothing
    lastrefresh = 0.0
    nrows = 0
    try
        while st.running
            if !st.paused && time() - lastrefresh >= st.interval
                snap = _snapshot(full = true)
                cores = Sys.cpu_info()
                t = time()
                fr = _frame(prev, snap, prevcores, cores, max(t - prevt, 0.001))
                prev, prevcores, prevt = snap, cores, t
                lastrefresh = t
                syscpu = isempty(fr.percore) ? 0.0 : sum(fr.percore) / length(fr.percore)
                push!(st.cpuhist, syscpu)
                push!(st.memhist, fr.memtotal > 0 ? fr.memused / fr.memtotal : 0.0)
                length(st.cpuhist) > HIST_LEN && popfirst!(st.cpuhist)
                length(st.memhist) > HIST_LEN && popfirst!(st.memhist)
                st.message = ""
                fr === nothing || (nrows = _render(stdout, st, fr))
            end
            # wait for a key or the next refresh tick
            key = nothing
            deadline = time() + 0.05
            while time() < deadline
                if isready(keych)
                    key = take!(keych)
                    break
                end
                sleep(0.01)
            end
            key === nothing && continue
            _handle_key!(st, key, keych, fr, nrows)
            fr === nothing || (nrows = _render(stdout, st, fr))
        end
    finally
        close(keych)
        print(stdout, "\e[?25h\e[?1049l")  # restore cursor and screen
        REPL.Terminals.raw!(term, false)
    end
    return nothing
end

function _handle_key!(st::TopState, key::Char, keych::Channel{Char}, fr, nrows::Int)
    if st.filtering
        if key == '\r' || key == '\n'
            st.filtering = false
        elseif key == '\e' && !isready(keych)
            st.filtering = false
            st.filter = ""
        elseif key == '\x7f' || key == '\b'
            isempty(st.filter) || (st.filter = st.filter[1:prevind(st.filter, end)])
        elseif isprint(key)
            st.filter *= key
        end
        st.sel = 1
        return
    end
    if key == '\e'  # escape sequence (arrows, page keys) or bare escape
        sleep(0.01)
        if isready(keych) && take!(keych) == '['
            isready(keych) || return
            k2 = take!(keych)
            if k2 == 'A'
                st.sel = max(st.sel - 1, 1)
            elseif k2 == 'B'
                st.sel += 1  # clamped in render
            elseif k2 == '5' || k2 == '6'  # PgUp / PgDn (trailing ~)
                isready(keych) && take!(keych)
                st.sel = k2 == '5' ? max(st.sel - 20, 1) : st.sel + 20
            end
        end
    elseif key == 'q' || key == '\x03'
        st.running = false
    elseif key == ' '
        st.paused = !st.paused
    elseif key == 'c'
        st.sortkey = :cpu; st.rev = true
    elseif key == 'm'
        st.sortkey = :mem; st.rev = true
    elseif key == 't'
        st.sortkey = :time; st.rev = true
    elseif key == 'p'
        st.sortkey = :pid; st.rev = false
    elseif key == 'n'
        st.sortkey = :name; st.rev = false
    elseif key == 'T'
        st.tree = !st.tree
        st.sel = 1
    elseif key == 'a'
        st.aggregate = !st.aggregate
    elseif key == 'u'
        st.mine = !st.mine
        st.sel = 1
    elseif key == 'j'
        st.juliaonly = !st.juliaonly
        st.sel = 1
    elseif key == 'C'
        st.showcmd = !st.showcmd
    elseif key == '/'
        st.filtering = true
        st.filter = ""
    elseif key == '+'
        st.interval = min(st.interval * 2, 60.0)
    elseif key == '-'
        st.interval = max(st.interval / 2, 0.25)
    elseif (key == 'k' || key == 'K') && fr !== nothing
        rows = _rows(st, fr)
        if 1 <= st.sel <= length(rows)
            pid = rows[st.sel].pid
            sig = key == 'K' ? 9 : 15
            ok = ccall(:kill, Cint, (Cint, Cint), pid, sig) == 0
            st.message = ok ? "sent SIG$(sig == 9 ? "KILL" : "TERM") to $pid" :
                              "kill $pid failed: $(Libc.strerror(Libc.errno()))"
        end
    end
    return
end

"""
    top(io::IO; interval::Real = 0.5, tree::Bool = false, color::Bool = false)

Render one frame of the process view to `io` (sampling CPU over `interval` seconds) and
return the number of process rows. Non-interactive; useful for logging and testing.
"""
function top(io::IO; interval::Real = 0.5, tree::Bool = false, color::Bool = false)
    Sys.iswindows() && error("ProcessMonitor: Windows is not yet supported")
    st = TopState(; interval = Float64(interval), tree)
    prev = _snapshot(full = true)
    prevcores = Sys.cpu_info()
    t0 = time()
    sleep(interval)
    snap = _snapshot(full = true)
    fr = _frame(prev, snap, prevcores, Sys.cpu_info(), max(time() - t0, 0.001))
    syscpu = isempty(fr.percore) ? 0.0 : sum(fr.percore) / length(fr.percore)
    push!(st.cpuhist, syscpu)
    push!(st.memhist, fr.memtotal > 0 ? fr.memused / fr.memtotal : 0.0)
    return _render(io, st, fr; interactive = false, color)
end
