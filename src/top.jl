# An htop-like interactive terminal view built on Snapshot differencing.

import REPL
using Printf: @sprintf

const SPARK = ('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')
const HIST_LEN = 240

Base.@kwdef mutable struct TopState
    sortkey::Symbol = :cpu   # :cpu, :mem, :pid, :time, :threads, :name, :age
    rev::Bool = true         # true = descending (the default for usage columns)
    tree::Bool = false
    aggregate::Bool = true   # tree mode: roll subtree usage up into each row, so the
                             # displayed values match the busiest-subtree-first ordering
    mine::Bool = false       # only this uid's processes
    juliaonly::Bool = false  # only Julia processes
    showcmd::Bool = false    # show full command lines instead of names
    filter::String = ""
    filtering::Bool = false  # currently typing into the filter
    sel::Int = 1             # selected row (1-based, into visible rows)
    scroll::Int = 0
    paused::Bool = false
    detail::Bool = false     # show the detail pane for the selection
    help::Bool = false       # show the help overlay
    pendpid::Int = 0         # pending kill confirmation target (0 = none)
    pendsig::Int = 0
    pendstart::Float64 = -1.0
    escpending::Float64 = 0.0 # monotonic time when an incomplete escape sequence arrived
    interval::Float64 = 2.0
    running::Bool = true
    cpuhist::Vector{Float64} = Float64[]
    memhist::Vector{Float64} = Float64[]
    pidhist::Dict{Int,Vector{Float64}} = Dict{Int,Vector{Float64}}()
    message::String = ""     # transient status line (e.g. after a kill)
end

struct Frame
    snap::Snapshot
    cpupct::Dict{Int,Float64}   # per-pid CPU% over the interval
    percore::Vector{Float64}    # per-core busy fraction 0..1
    fuser::Float64              # system-wide user-time fraction 0..1
    fsys::Float64               # system-wide sys-time fraction 0..1
    loadavg::NTuple{3,Float64}
    uptime::Float64
    memtotal::Int
    memused::Int
    nprocs::Int
    nthreads::Int
end

# (user-ish, sys-ish, idle) tick totals for one core
_cpu_uis(c) = (
    getfield(c, Symbol("cpu_times!user")) + getfield(c, Symbol("cpu_times!nice")),
    getfield(c, Symbol("cpu_times!sys")) + getfield(c, Symbol("cpu_times!irq")),
    getfield(c, Symbol("cpu_times!idle")))

function _frame(prev::Snapshot, snap::Snapshot, prevcores, cores, dt::Float64)
    cpupct = Dict{Int,Float64}()
    for (pid, t) in snap.cputime
        d = t - get(prev.cputime, pid, t)  # unseen pid: no baseline, report 0 not a spike
        cpupct[pid] = 100 * max(d, 0.0) / dt
    end
    percore = Float64[]
    du = ds = di = 0
    for i in 1:min(length(cores), length(prevcores))
        u1, s1, i1 = _cpu_uis(prevcores[i])
        u2, s2, i2 = _cpu_uis(cores[i])
        cu, cs, ci = u2 - u1, s2 - s1, i2 - i1
        du += cu; ds += cs; di += ci
        tot = cu + cs + ci
        push!(percore, tot > 0 ? (cu + cs) / tot : 0.0)
    end
    tot = du + ds + di
    la = Sys.loadavg()
    memtotal = Int(Sys.total_memory())
    return Frame(snap, cpupct, percore,
        tot > 0 ? du / tot : 0.0, tot > 0 ? ds / tot : 0.0,
        (la[1], la[2], la[3]), Sys.uptime(),
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

function _fmtage(secs::Real)
    secs < 0 && return "?"
    secs < 100 && return @sprintf("%ds", secs)
    secs < 6000 && return @sprintf("%dm", secs ÷ 60)
    secs < 172800 && return @sprintf("%.1fh", secs / 3600)
    return @sprintf("%.1fd", secs / 86400)
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

# Two-tone bar: user time (green) stacked with sys time (red).
function _bar2(fu::Float64, fs::Float64, width::Int; color::Bool = true)
    ucells = floor(Int, clamp(fu, 0, 1) * width)
    scells = floor(Int, clamp(fu + fs, 0, 1) * width) - ucells
    pad = max(width - ucells - scells, 0)
    color || return repeat('█', ucells) * repeat('▓', scells) * repeat(' ', pad)
    return string("\e[32m", repeat('█', ucells), "\e[31m", repeat('█', scells), "\e[0m",
        repeat(' ', pad))
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

# Braille history graph: `rows` text rows tall, two samples per character column, so a
# 2-row graph has 8 vertical levels at twice the horizontal density of block sparklines.
# Right-aligned (newest sample at the right edge). Returns one String per row, top first.
function _braille(vals::Vector{Float64}, width::Int, rows::Int; color::Bool = true)
    # dot bits per char: left column top→bottom, then right column top→bottom
    LEFT = (0x01, 0x02, 0x04, 0x40)
    RIGHT = (0x08, 0x10, 0x20, 0x80)
    n = 2 * width
    v = length(vals) >= n ? vals[end-n+1:end] : vals
    pad = width - cld(length(v), 2)
    lines = [IOBuffer() for _ in 1:rows]
    for l in lines
        print(l, repeat(' ', pad))
    end
    total = 4 * rows
    filled(x) = clamp(round(Int, clamp(x, 0, 1) * total), 0, total)
    for i in 1:2:length(v)
        fl = filled(v[i])
        fr = i + 1 <= length(v) ? filled(v[i+1]) : 0
        peak = max(v[i], i + 1 <= length(v) ? v[i+1] : 0.0)
        for r in 1:rows
            bits = 0x00
            for d in 1:4  # dot rows top→bottom within this char row
                b = (rows - r) * 4 + (5 - d)  # height index from the bottom
                b <= fl && (bits |= LEFT[d])
                b <= fr && (bits |= RIGHT[d])
            end
            color && print(lines[r], _pctcolor(peak))
            print(lines[r], Char(0x2800 + bits))
        end
    end
    return [String(take!(l)) * (color ? "\e[0m" : "") for l in lines]
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

# What a Julia process is doing, from its command line. Precompilation workers name the
# package in their --output-ji cache path (…/compiled/v1.12/StaticArrays/jl_…), so surface
# it: "precompile StaticArrays".
function _julia_role(cmd::AbstractString)
    occursin("--worker", cmd) && return "worker"
    if occursin("--output-ji", cmd) || occursin(r"Precompilation|precompilepkgs", cmd)
        m = match(r"compiled/v[\d.]+/([^/]+)", cmd)
        return m === nothing ? "precompile" : "precompile " * m[1]
    end
    return ""
end

# The active project from --project, shortened to its basename.
function _julia_project(cmd::AbstractString)
    m = match(r"--project(?:=(\S+))?", cmd)
    m === nothing && return ""
    v = m[1]
    (v === nothing || v == "@.") && return "@."
    return basename(rstrip(v, ('/', '\\')))
end

# ---- row assembly ----

struct Row
    pid::Int
    prefix::String      # rendered tree glyphs ("│ ├─" etc.), empty in flat mode
    name::String
    uid::Int
    threads::Int
    rss::Int
    cpu::Float64        # percent
    time::Float64       # cumulative seconds
    age::Float64        # seconds since the process started (-1 unknown)
    state::Char
    isjulia::Bool
    ver::String         # Julia version label ("" when unknown / not Julia)
    role::String        # "worker"/"precompile"/"" for Julia processes
    project::String     # active --project for Julia processes
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
    st.sortkey === :age ? -r.age :
    st.sortkey === :threads ? Float64(r.threads) : 0.0

function _mkrow(fr::Frame, pid::Int, prefix::String, agg::Bool)
    snap = fr.snap
    pids = agg ? _tree(snap, pid, true) : (pid,)
    isjulia = _isjulia(snap, pid)
    cmd = get(snap.cmd, pid, "")
    start = get(snap.start, pid, -1.0)
    return Row(pid, prefix,
        get(snap.name, pid, "?"),
        get(snap.uid, pid, -1),
        sum(p -> get(snap.threads, p, 0), pids),
        sum(p -> get(snap.rss, p, 0), pids),
        sum(p -> get(fr.cpupct, p, 0.0), pids),
        sum(p -> get(snap.cputime, p, 0.0), pids),
        start > 0 ? max(time() - start, 0.0) : -1.0,
        get(snap.state, pid, ' '),
        isjulia,
        isjulia ? _julia_version_from_path(get(snap.exe, pid, "")) : "",
        isjulia ? _julia_role(cmd) : "",
        isjulia ? _julia_project(cmd) : "",
        cmd)
end

function _rows(st::TopState, fr::Frame)
    snap = fr.snap
    allpids = union(keys(snap.cputime), keys(snap.ppid))
    if !st.tree
        rows = Row[_mkrow(fr, pid, "", false) for pid in allpids if _match(st, snap, pid)]
        by = st.sortkey === :name ? (r -> lowercase(r.name)) : (r -> _sortval(st, r))
        sort!(rows; by, rev = st.rev && st.sortkey !== :name)
        return rows
    end
    # Tree mode: DFS from the roots, sorting siblings by the sort key. A filtered-out
    # process is still shown if a descendant matches, so trees stay connected.
    rows = Row[]
    keep = Dict{Int,Bool}()
    function matches_below(pid)::Bool
        get!(keep, pid) do
            _match(st, snap, pid) || any(matches_below, get(snap.children, pid, Int[]))
        end
    end
    # Order roots and siblings by their whole subtree's totals (independent of the Σ
    # display toggle), so "sort by CPU" surfaces the busiest tree even when its root is
    # an idle shell. Precompute the keys: `sort!(by=...)` re-evaluates per comparison.
    treekey = if st.sortkey === :name
        pid -> lowercase(get(snap.name, pid, ""))
    else
        subkey = Dict{Int,Float64}()
        pid -> get!(() -> _sortval(st, _mkrow(fr, pid, "", true)), subkey, pid)
    end
    roots = [pid for pid in allpids
             if !haskey(snap.ppid, pid) || snap.ppid[pid] == pid ||
                !(snap.ppid[pid] in allpids)]
    sort!(roots; by = treekey, rev = st.rev)
    seen = Set{Int}()
    # `stem` accumulates one glyph pair per ancestor: "│ " below an ancestor with later
    # siblings, "  " below a last child — so vertical lines run continuously.
    function walk(pid, stem, lastchild, isroot)
        pid in seen && return
        push!(seen, pid)
        matches_below(pid) || return
        push!(rows, _mkrow(fr, pid, isroot ? "" : stem * (lastchild ? "└─" : "├─"),
            st.aggregate))
        kids = [k for k in get(snap.children, pid, Int[]) if matches_below(k)]
        sort!(kids; by = treekey, rev = st.rev)
        childstem = isroot ? "" : stem * (lastchild ? "  " : "│ ")
        for (i, k) in enumerate(kids)
            walk(k, childstem, i == length(kids), false)
        end
    end
    for r in roots
        walk(r, "", false, true)
    end
    return rows
end

# ---- detail pane ----

function _fdcount(pid::Int)
    if Sys.isapple()
        bi = Ref(ntuple(_ -> UInt32(0), 40))
        r = ccall(:proc_pidinfo, Cint, (Cint, Cint, UInt64, Ptr{Cvoid}, Cint), pid, 3, 0, bi, 160)
        return r > 0 ? Int(bi[][25]) : -1  # pbi_nfiles
    elseif Sys.islinux()
        try
            return length(readdir("/proc/$pid/fd"))
        catch
            return -1
        end
    end
    return -1
end

# A displayed PID may have exited and been reused before the user confirms an action.
# Full BSD snapshots estimate start time from second-resolution elapsed time, hence the
# small tolerance; Linux and macOS start times are stable within it.
function _same_process(pid::Integer, expected_start::Float64)
    expected_start > 0 || return false
    pid = Int(pid)
    snap = try
        _snapshot(full = true)
    catch
        return false
    end
    current_start = get(snap.start, pid, -1.0)
    return current_start > 0 && abs(current_start - expected_start) <= 2.0
end

function _send_signal(pid::Integer, sig::Integer, expected_start::Float64)
    pid, sig = Int(pid), Int(sig)
    _same_process(pid, expected_start) ||
        return false, "process $pid exited or changed; no signal sent"
    ok = ccall(:kill, Cint, (Cint, Cint), pid, sig) == 0
    return ok, ok ? "" : "signal failed: $(Libc.strerror(Libc.errno()))"
end

# Wrap `label * text` to `width` columns, indenting continuation lines under the label so
# a long value stays fully readable across several rows.
function _wrap(label::AbstractString, text::AbstractString, width::Int)
    width = max(width, 16)
    indent = repeat(' ', min(length(label), width - 8))
    chars = collect(label * text)
    out = String[]
    i, firstline = 1, true
    while i <= length(chars)
        cap = max(firstline ? width : width - length(indent), 1)
        j = min(i + cap - 1, length(chars))
        push!(out, (firstline ? "" : indent) * String(chars[i:j]))
        i, firstline = j + 1, false
    end
    isempty(out) && push!(out, String(label))
    return out
end

# Drop argv[0] (the executable, shown on its own line) from a command line.
function _strip_argv0(cmd::AbstractString)
    sp = findfirst(' ', cmd)
    return sp === nothing ? "" : lstrip(cmd[nextind(cmd, sp):end])
end

function _detail_lines(fr::Frame, r::Row, width::Int, maxlines::Int)
    snap = fr.snap
    started = r.age >= 0 ?
        string(Libc.strftime("%b %d %H:%M:%S", time() - r.age), " (", _fmtage(r.age), " ago)") : "?"
    pp = get(snap.ppid, r.pid, 0)
    parent = pp > 0 ? string(pp, " ", get(snap.name, pp, "?")) : "?"
    fds = _fdcount(r.pid)
    cwd = Sys.islinux() ? (try readlink("/proc/$(r.pid)/cwd") catch; "" end) : ""
    jl = r.isjulia ? string("  julia ", r.ver,
        isempty(r.role) ? "" : "  role $(r.role)",
        isempty(r.project) ? "" : "  project $(r.project)") : ""
    exe = get(snap.exe, r.pid, "")
    args = _strip_argv0(r.cmd)
    lines = String[]
    # exe first, then cmd (with the exe stripped) — both wrapped so they are fully visible
    append!(lines, _wrap(" exe  ", isempty(exe) ? "?" : exe, width))
    append!(lines, _wrap(" cmd  ", isempty(args) ? "(no arguments)" : args, width))
    push!(lines, _ellipsize(string(" pid ", r.pid, "  ", r.name, "  state ", r.state,
        "  user ", r.uid < 0 ? "?" : _username(r.uid), jl), width))
    push!(lines, _ellipsize(string(" started ", started, "  parent ", parent,
        isempty(cwd) ? "" : "  cwd $cwd"), width))
    push!(lines, _ellipsize(string(" threads ", r.threads, "  rss ", _fmtbytes(r.rss),
        "  cpu ", @sprintf("%.1f%%", r.cpu), "  cputime ", _fmttime(r.time),
        fds >= 0 ? "  fds $fds" : ""), width))
    if length(lines) > maxlines
        lines = lines[1:max(maxlines - 1, 1)]
        push!(lines, _ellipsize(" …", width))
    end
    return lines
end

const _HELP = """
  q / Ctrl-C   quit                     space        pause
  c m t p n s  sort: cpu, memory, cpu-time, pid, name, newest
  T            tree view                a            Σ roll subtrees up (tree)
  j            only Julia processes     C            show full command lines
  /            filter (enter apply, esc clear)       u  only my processes
  ↑ ↓ PgUp PgDn  select                 enter        detail pane
  k / K        SIGTERM / SIGKILL selection (asks to confirm)
  P            ask a Julia process to print a profile to its stderr
  + / -        change refresh interval
"""

# ---- rendering ----

function _render(io::IO, st::TopState, fr::Frame; interactive::Bool = true, color::Bool = true)
    rows_avail, width = displaysize(io)
    height = max(rows_avail, 14)
    width = max(width, 60)
    buf = IOBuffer()
    c(s) = color ? s : ""
    interactive && print(buf, "\e[H")
    eol = interactive ? "\e[K\n" : "\n"

    syscpu = isempty(fr.percore) ? 0.0 : sum(fr.percore) / length(fr.percore)
    memfrac = fr.memtotal > 0 ? fr.memused / fr.memtotal : 0.0

    # header: title, bar line, 2 braille history rows, cores line
    print(buf, c("\e[1m"), " ProcessMonitor", c("\e[0m"),
        "  ", gethostname(),
        "  up ", _fmtuptime(fr.uptime),
        @sprintf("  load %.2f %.2f %.2f", fr.loadavg...),
        "  ", length(fr.percore), " cores  ",
        fr.nprocs, " procs  ", fr.nthreads, " thr",
        st.paused ? c("\e[33m") * "  ⏸ paused" * c("\e[0m") : "")
    # active mode badges, so toggles are visible at a glance
    modes = String[]
    st.tree && push!(modes, st.aggregate ? "tree Σ" : "tree")
    st.juliaonly && push!(modes, "julia")
    st.mine && push!(modes, "mine")
    st.showcmd && push!(modes, "cmd")
    isempty(st.filter) || push!(modes, "/" * st.filter)
    isempty(modes) || print(buf, c("\e[46;30m"), " ", join(modes, " · "), " ", c("\e[0m"))
    print(buf, eol)

    barw = max(min(width ÷ 5, 24), 10)
    print(buf, " CPU ", c("▕"), _bar2(fr.fuser, fr.fsys, barw; color), c("▏"),
        @sprintf("%5.1f%%", 100syscpu),
        "   MEM ", c("▕"), _bar(memfrac, barw; color), c("▏"),
        @sprintf("%5.1f%%  ", 100memfrac),
        _fmtbytes(fr.memused), "/", _fmtbytes(fr.memtotal), eol)
    graphw = max((width - 7) ÷ 2 - 1, 10)
    cpug = _braille(st.cpuhist, graphw, 2; color)
    memg = _braille(st.memhist, graphw, 2; color)
    for r in 1:2
        print(buf, "     ", cpug[r], "  ", memg[r], eol)
    end

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

    showspark = interactive && width >= 100
    showage = width >= 88
    namew = width - 51 - (showspark ? 9 : 0) - (showage ? 7 : 0)
    agg = st.tree && st.aggregate ? "Σ" : ""
    sortmark(k) = st.sortkey === k ? "▾" : " "
    print(buf, c("\e[7m"),
        lpad("PID", 7), " ",
        rpad("USER", 8), " ",
        "S", " ",
        _ellipsize("NAME" * sortmark(:name), namew), " ",
        showspark ? rpad("HIST", 8) * " " : "",
        lpad("THR" * sortmark(:threads), 5), " ",
        lpad(agg * "RSS" * sortmark(:mem), 7), " ",
        showage ? lpad("AGE" * sortmark(:age), 6) * " " : "",
        lpad("TIME" * sortmark(:time), 8), " ",
        lpad(agg * "CPU%" * sortmark(:cpu), 7),
        c("\e[0m"), eol)

    rows = _rows(st, fr)
    st.sel = clamp(st.sel, 1, max(length(rows), 1))
    # The detail pane wraps exe/cmd, so its height is dynamic; compute it before the body
    # so the process list gets the remaining rows. Cap it at half the screen.
    detaillines = String[]
    if interactive && st.detail && 1 <= st.sel <= length(rows)
        detaillines = _detail_lines(fr, rows[st.sel], width, max(height ÷ 2, 6))
    end
    detailh = isempty(detaillines) ? 0 : length(detaillines) + 1  # +1 separator
    # Interactive mode fits the terminal; a single-frame dump includes every row.
    nbody = interactive ? max(height - 7 - detailh, 1) : length(rows)
    st.scroll = clamp(st.scroll, 0, max(length(rows) - nbody, 0))
    if st.sel <= st.scroll
        st.scroll = st.sel - 1
    elseif st.sel > st.scroll + nbody
        st.scroll = st.sel - nbody
    end
    self = getpid()

    if st.help && interactive
        for l in split(_HELP, '\n')
            print(buf, l, eol)
        end
        for _ in (length(split(_HELP, '\n'))):(nbody - 1)
            print(buf, eol)
        end
    else
        for i in (st.scroll + 1):min(st.scroll + nbody, length(rows))
            r = rows[i]
            selected = interactive && i == st.sel
            prefix = r.prefix
            cpufrac = r.cpu / 100 / max(length(fr.percore), 1)
            selected && print(buf, c("\e[7m"))
            # Julia rows: magenta, labeled with version/role/project; C swaps in the cmdline
            label = if st.showcmd && !isempty(r.cmd)
                r.cmd
            elseif r.isjulia
                join(filter(!isempty, [isempty(r.ver) ? r.name : "$(r.name) $(r.ver)",
                    r.role, r.project]), " · ")
            else
                r.name
            end
            statecol = r.state == 'Z' ? "\e[31m" : r.state == 'D' ? "\e[33m" : "\e[2m"
            print(buf, lpad(r.pid, 7), " ",
                c(r.uid == Int(ccall(:getuid, Cuint, ())) ? "\e[36m" : "\e[2m"),
                rpad(_ellipsize(r.uid < 0 ? "?" : _username(r.uid), 8), 8), c("\e[0m"),
                selected ? c("\e[7m") : "", " ",
                c(selected ? "" : statecol), r.state, c(selected ? "" : "\e[0m"),
                selected ? "" : "", " ",
                r.pid == self ? c("\e[1m") : r.isjulia ? c("\e[35m") : "",
                _ellipsize(prefix * label, namew), c(selected ? "" : "\e[0m"), " ",
                showspark ? _spark(get(st.pidhist, r.pid, Float64[]), 8;
                    color = color && !selected) * " " : "",
                lpad(r.threads == 0 ? "?" : string(r.threads), 5), " ",
                lpad(_fmtbytes(r.rss), 7), " ",
                showage ? lpad(_fmtage(r.age), 6) * " " : "",
                lpad(_fmttime(r.time), 8), " ",
                c(selected ? "" : _pctcolor(cpufrac)),
                lpad(@sprintf("%.1f", r.cpu), 7), c("\e[0m"), eol)
        end
        if interactive
            for _ in (length(rows) - st.scroll):(nbody - 1)
                print(buf, eol)
            end
        end
    end

    if interactive
        if !isempty(detaillines)
            print(buf, c("\e[2m"), repeat('─', width), c("\e[0m"), eol)
            for l in detaillines
                print(buf, c("\e[2m"), l, c("\e[0m"), eol)
            end
        end
        # footer
        if st.filtering
            print(buf, c("\e[1m"), " filter: ", st.filter, "▌", c("\e[0m"),
                "  (enter to apply, esc to clear)", "\e[K")
        elseif st.pendpid != 0
            print(buf, c("\e[33;1m"), " send SIG", st.pendsig == 9 ? "KILL" : "TERM",
                " to ", st.pendpid, "?  y to confirm, any other key cancels", c("\e[0m"), "\e[K")
        elseif !isempty(st.message)
            print(buf, c("\e[33m"), " ", st.message, c("\e[0m"), "\e[K")
        else
            print(buf, c("\e[2m"),
                " q quit  ? help  c/m/t/p/n/s sort  T tree  a Σ  j julia  C cmd  / filter  ",
                "enter detail  k/K kill  P profile  (", round(st.interval, digits = 1), "s)",
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

The header shows system CPU (user green / sys red) and memory with braille history
graphs, one mini-bar per core, load averages, uptime, process/thread totals, and a rollup
of all Julia processes (count, CPU, memory, threads). Julia rows are highlighted and
labeled with version (from the install path), role (`worker`, `precompile`) and
`--project`. Press `?` for the key reference.
"""
function top(; interval::Real = 2.0, tree::Bool = false)
    Sys.iswindows() && error("ProcessMonitor: Windows is not yet supported")
    stdout isa Base.TTY || error("top() needs an interactive terminal; use top(io) for one frame")
    st = TopState(; interval, tree)
    term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", ""), stdin, stdout, stderr)
    raw = reading = screen = false
    try
        raw = true
        REPL.Terminals.raw!(term, true)
        # Poll stdin on this task rather than blocking-read in a helper task: an orphaned
        # blocked read would survive top() and swallow the first byte of every escape
        # sequence the REPL receives afterwards.
        reading = true
        Base.start_reading(stdin)
        queue = UInt8[]
        screen = true
        print(stdout, "\e[?1049h\e[?25l\e[2J")  # alternate screen, hide cursor
        flush(stdout)
        prev = _snapshot(full = true)
        prevcores = Sys.cpu_info()
        prevt = _monotime()
        fr = nothing
        lastrefresh = 0.0
        sleep(0.15)  # short priming sample: the first frame appears immediately with real data
        while st.running
            if !st.paused && _monotime() - lastrefresh >= st.interval
                snap = _snapshot(full = true)
                cores = Sys.cpu_info()
                t = _monotime()
                fr = _frame(prev, snap, prevcores, cores, max(t - prevt, 0.001))
                prev, prevcores, prevt = snap, cores, t
                lastrefresh = t
                _push_hist!(st, fr)
                st.message = ""
                _render(stdout, st, fr)
            end
            # wait for input or the next refresh tick
            deadline = _monotime() + 0.05
            while _monotime() < deadline && bytesavailable(stdin) == 0
                sleep(0.01)
            end
            bytesavailable(stdin) > 0 && append!(queue, readavailable(stdin))
            if _drain_keys!(st, queue, fr) && fr !== nothing
                _render(stdout, st, fr)
            end
        end
    finally
        if reading
            try
                Base.stop_reading(stdin)
            catch
            end
        end
        if screen
            try
                print(stdout, "\e[?25h\e[?1049l")  # restore cursor and screen
                flush(stdout)
            catch
            end
        end
        if raw
            try
                REPL.Terminals.raw!(term, false)
            catch
            end
        end
    end
    return nothing
end

# Return true once an incomplete escape sequence has waited long enough to be interpreted
# as a bare Escape key.
function _escape_timed_out!(st::TopState)
    now = _monotime()
    if st.escpending == 0.0
        st.escpending = now
        return false
    end
    return now - st.escpending >= 0.1
end

function _handle_bare_escape!(st::TopState)
    if st.filtering
        st.filtering = false
        st.filter = ""
    elseif st.help
        st.help = false
    end
    return
end

# Consume complete buffered input sequences. Incomplete escape sequences remain in `queue`
# because readavailable() may split one terminal keypress across multiple reads.
function _drain_keys!(st::TopState, queue::Vector{UInt8}, fr)
    changed = false
    while !isempty(queue) && st.running
        if queue[1] == 0x1b
            if length(queue) == 1
                _escape_timed_out!(st) || break
                popfirst!(queue)
                st.escpending = 0.0
                changed = true
                _handle_bare_escape!(st)
                continue
            elseif queue[2] == UInt8('[')
                finalindex = 3
                while finalindex <= length(queue) &&
                      !(0x40 <= queue[finalindex] <= 0x7e)
                    finalindex += 1
                end
                if finalindex > length(queue)
                    _escape_timed_out!(st) || break
                    popfirst!(queue)
                    st.escpending = 0.0
                    changed = true
                    _handle_bare_escape!(st)
                    continue
                end
                seq = splice!(queue, 1:finalindex)
                st.escpending = 0.0
                changed = true
                params = seq[3:end-1]
                final = Char(seq[end])
                ps = split(String(params), ';')
                if st.help
                    st.help = false
                elseif final == 'A'
                    st.sel = max(st.sel - 1, 1)
                elseif final == 'B'
                    st.sel += 1  # clamped in render
                elseif final == '~' && !isempty(ps) && (ps[1] == "5" || ps[1] == "6")
                    st.sel = ps[1] == "5" ? max(st.sel - 20, 1) : st.sel + 20
                elseif final == 'u'  # CSI-u (modifyOtherKeys): "code;modifiers u"
                    code = isempty(ps) ? nothing : tryparse(Int, ps[1])
                    mods = length(ps) >= 2 ? something(tryparse(Int, ps[2]), 1) : 1
                    if code !== nothing && 0 < code <= 0x10ffff
                        ch = Char(code)
                        # the code is the unshifted key; modifier bit 1 is shift
                        ((mods - 1) & 1) != 0 && (ch = uppercase(ch))
                        _handle_key!(st, ch, fr)
                    end
                end
            elseif queue[2] == UInt8('O')  # SS3 arrows (\eOA/\eOB)
                if length(queue) < 3
                    _escape_timed_out!(st) || break
                    popfirst!(queue)
                    st.escpending = 0.0
                    changed = true
                    _handle_bare_escape!(st)
                    continue
                end
                seq = splice!(queue, 1:3)
                st.escpending = 0.0
                changed = true
                k2 = Char(seq[3])
                k2 == 'A' && (st.sel = max(st.sel - 1, 1))
                k2 == 'B' && (st.sel += 1)
            else
                popfirst!(queue)
                st.escpending = 0.0
                changed = true
                _handle_bare_escape!(st)
            end
        else
            st.escpending = 0.0
            b = popfirst!(queue)
            changed = true
            _handle_key!(st, Char(b), fr)
        end
    end
    return changed
end

function _push_hist!(st::TopState, fr::Frame)
    syscpu = isempty(fr.percore) ? 0.0 : sum(fr.percore) / length(fr.percore)
    push!(st.cpuhist, syscpu)
    push!(st.memhist, fr.memtotal > 0 ? fr.memused / fr.memtotal : 0.0)
    length(st.cpuhist) > HIST_LEN && popfirst!(st.cpuhist)
    length(st.memhist) > HIST_LEN && popfirst!(st.memhist)
    for (pid, pct) in fr.cpupct
        h = get!(() -> Float64[], st.pidhist, pid)
        push!(h, pct / 100)  # scaled so 1.0 == one full core
        length(h) > 16 && popfirst!(h)
    end
    for pid in collect(keys(st.pidhist))
        haskey(fr.cpupct, pid) || delete!(st.pidhist, pid)
    end
    return
end

function _handle_key!(st::TopState, key::Char, fr)
    if st.help
        st.help = false
        return
    end
    if st.pendpid != 0  # kill confirmation
        if key == 'y'
            ok, err = _send_signal(st.pendpid, st.pendsig, st.pendstart)
            st.message = ok ?
                "sent SIG$(st.pendsig == 9 ? "KILL" : "TERM") to $(st.pendpid)" : err
        else
            st.message = ""
        end
        st.pendpid = 0
        st.pendstart = -1.0
        return
    end
    if st.filtering
        if key == '\r' || key == '\n'
            st.filtering = false
        elseif key == '\x7f' || key == '\b'
            isempty(st.filter) || (st.filter = st.filter[1:prevind(st.filter, end)])
        elseif isprint(key)
            st.filter *= key
        end
        st.sel = 1
        return
    end
    if key == 'q' || key == '\x03'
        st.running = false
    elseif key == '?'
        st.help = true
    elseif key == ' '
        st.paused = !st.paused
    elseif key == '\r' || key == '\n'
        st.detail = !st.detail
    elseif key == 'c'
        st.sortkey = :cpu; st.rev = true
    elseif key == 'm'
        st.sortkey = :mem; st.rev = true
    elseif key == 't'
        st.sortkey = :time; st.rev = true
    elseif key == 's'
        st.sortkey = :age; st.rev = true  # sorts by -age: newest first
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
    elseif key == 'P' && fr !== nothing
        rows = _rows(st, fr)
        if 1 <= st.sel <= length(rows)
            r = rows[st.sel]
            if r.isjulia
                sig = Sys.islinux() ? 10 : 29  # SIGUSR1 / SIGINFO: one-shot profile print
                ok, err = _send_signal(r.pid, sig, get(fr.snap.start, r.pid, -1.0))
                st.message = ok ? "asked $(r.pid) to print a profile to its stderr" :
                                  err
            else
                st.message = "$(r.pid) is not a Julia process"
            end
        end
    elseif (key == 'k' || key == 'K') && fr !== nothing
        rows = _rows(st, fr)
        if 1 <= st.sel <= length(rows)
            row = rows[st.sel]
            st.pendpid = row.pid
            st.pendsig = key == 'K' ? 9 : 15
            st.pendstart = get(fr.snap.start, row.pid, -1.0)
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
    st = TopState(; interval, tree)
    prev = _snapshot(full = true)
    prevcores = Sys.cpu_info()
    t0 = _monotime()
    sleep(interval)
    snap = _snapshot(full = true)
    fr = _frame(prev, snap, prevcores, Sys.cpu_info(), max(_monotime() - t0, 0.001))
    _push_hist!(st, fr)
    return _render(io, st, fr; interactive = false, color)
end

# Compile the frame/render path into the package image so the first interactive frame
# does not pay JIT latency.
if ccall(:jl_generating_output, Cint, ()) == 1 && !Sys.iswindows()
    let io = IOBuffer()
        try
            top(io; interval = 0.01)
            top(io; interval = 0.01, tree = true, color = true)
        catch
        end
    end
end
