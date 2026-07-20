# An htop-like interactive terminal view built on Snapshot differencing.

import REPL
using Printf: @sprintf
using Unicode

const SPARK = ('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')
const HIST_LEN = 480

Base.@kwdef mutable struct TopState
    sortkey::Symbol = :cpu   # :cpu, :mem, :pid, :time, :threads, :name, :age
    rev::Bool = true         # true = descending (the default for usage columns)
    tree::Bool = false
    aggregate::Bool = true   # tree mode: roll subtree usage up into each row, so the
                             # displayed values match the busiest-subtree-first ordering
    mine::Bool = false       # only this uid's processes
    juliaonly::Bool = false  # only Julia processes
    showcmd::Bool = false    # show full command lines instead of names
    graphs::Bool = false     # expanded CPU/memory signal view
    filter::String = ""
    filtering::Bool = false  # currently typing into the filter
    sel::Int = 0             # selected row (1-based), or 0 for no selection above row 1
    selpid::Int = 0          # selected process identity (0 until the first render)
    scroll::Int = 0
    paused::Bool = false
    detail::Bool = false     # show the detail pane for the selection
    help::Bool = false       # show the help overlay
    pendpid::Int = 0         # pending kill confirmation target (0 = none)
    pendsig::Int = 0
    pendstart::Float64 = -1.0
    escpending::Float64 = 0.0 # monotonic time when an incomplete escape sequence arrived
    lastclickpid::Int = 0     # process row used to recognize a double click
    lastclicktime::Float64 = 0.0
    interval::Float64 = 2.0
    running::Bool = true
    cpuhist::Vector{Float64} = Float64[]
    memhist::Vector{Float64} = Float64[]
    corehist::Vector{Vector{Float64}} = Vector{Float64}[]
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
        # New and reused PIDs have no valid baseline, so report zero for their first frame.
        previous = haskey(prev.cputime, pid) &&
                   _same_start(get(prev.start, pid, -1.0), get(snap.start, pid, -1.0)) ?
                   prev.cputime[pid] : t
        d = t - previous
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
_memcolor(f) = f < 0.65 ? "\e[36m" : f < 0.85 ? "\e[35m" : "\e[31m"

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
function _braille(vals::Vector{Float64}, width::Int, rows::Int;
        color::Bool = true, palette = _pctcolor)
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
            color && print(lines[r], palette(peak))
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

_pad_display(s::AbstractString, w::Int) =
    String(s) * repeat(' ', max(w - textwidth(s), 0))

function _ellipsize(s::AbstractString, w::Int)
    w = max(w, 0)
    textwidth(s) <= w && return _pad_display(s, w)
    w == 0 && return ""
    marker = "…"
    available = max(w - textwidth(marker), 0)
    io = IOBuffer()
    used = 0
    for grapheme in Unicode.graphemes(s)
        gw = textwidth(grapheme)
        used + gw <= available || break
        print(io, grapheme)
        used += gw
    end
    return _pad_display(String(take!(io)) * marker, w)
end

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

struct _Usage
    threads::Int
    rss::Int
    cpu::Float64
    time::Float64
end

_own_usage(fr::Frame, pid::Int) = _Usage(
    get(fr.snap.threads, pid, 0),
    get(fr.snap.rss, pid, 0),
    get(fr.cpupct, pid, 0.0),
    get(fr.snap.cputime, pid, 0.0),
)

function _mkrow(fr::Frame, pid::Int, prefix::String, usage::Union{Nothing,_Usage} = nothing)
    snap = fr.snap
    usage === nothing && (usage = _own_usage(fr, pid))
    isjulia = _isjulia(snap, pid)
    cmd = get(snap.cmd, pid, "")
    start = get(snap.start, pid, -1.0)
    return Row(pid, prefix,
        get(snap.name, pid, "?"),
        get(snap.uid, pid, -1),
        usage.threads,
        usage.rss,
        usage.cpu,
        usage.time,
        start > 0 ? max(time() - start, 0.0) : -1.0,
        get(snap.state, pid, ' '),
        isjulia,
        isjulia ? _julia_version_from_path(get(snap.exe, pid, "")) : "",
        isjulia ? _julia_role(cmd) : "",
        isjulia ? _julia_project(cmd) : "",
        cmd)
end

function _forest_order(snap::Snapshot, allpids::Set{Int})
    roots = [pid for pid in allpids
             if !haskey(snap.ppid, pid) || snap.ppid[pid] == pid ||
                !(snap.ppid[pid] in allpids)]
    order = Int[]
    seen = Set{Int}()
    function visit!(root)
        stack = [root]
        while !isempty(stack)
            pid = pop!(stack)
            pid in seen && continue
            push!(seen, pid)
            push!(order, pid)
            for child in Iterators.reverse(get(snap.children, pid, Int[]))
                child in allpids && !(child in seen) && push!(stack, child)
            end
        end
    end
    for root in roots
        visit!(root)
    end
    # A malformed or racing snapshot can contain a parent cycle with no natural root.
    # Include each remaining component once instead of dropping it or recursing forever.
    for pid in allpids
        if !(pid in seen)
            push!(roots, pid)
            visit!(pid)
        end
    end
    return roots, order
end

function _subtree_usage(fr::Frame, order::Vector{Int})
    snap = fr.snap
    totals = Dict{Int,_Usage}()
    for pid in Iterators.reverse(order)
        total = _own_usage(fr, pid)
        for child in get(snap.children, pid, Int[])
            child == pid && continue
            childtotal = get(totals, child, nothing)
            childtotal === nothing && continue
            total = _Usage(
                total.threads + childtotal.threads,
                total.rss + childtotal.rss,
                total.cpu + childtotal.cpu,
                total.time + childtotal.time,
            )
        end
        totals[pid] = total
    end
    return totals
end

function _rows(st::TopState, fr::Frame)
    snap = fr.snap
    allpids = Set{Int}(union(keys(snap.cputime), keys(snap.ppid)))
    if !st.tree
        rows = Row[_mkrow(fr, pid, "") for pid in allpids if _match(st, snap, pid)]
        by = st.sortkey === :name ? (r -> lowercase(r.name)) : (r -> _sortval(st, r))
        sort!(rows; by, rev = st.rev && st.sortkey !== :name)
        return rows
    end

    roots, order = _forest_order(snap, allpids)
    totals = _subtree_usage(fr, order)

    # Compute filter retention in postorder. A filtered-out process remains visible when
    # a descendant matches, so tree relationships stay understandable.
    keep = Dict{Int,Bool}()
    for pid in Iterators.reverse(order)
        keep[pid] = _match(st, snap, pid) ||
                    any(child -> get(keep, child, false), get(snap.children, pid, Int[]))
    end

    # Order roots and siblings by their whole subtree's totals (independent of the Σ
    # display toggle), so "sort by CPU" surfaces the busiest tree even when its root is an
    # idle shell. Cache the rows used as sort keys: `sort!(by=...)` calls `by` repeatedly.
    treekey = if st.sortkey === :name
        pid -> lowercase(get(snap.name, pid, ""))
    else
        sortrows = Dict{Int,Row}()
        pid -> _sortval(st,
            get!(() -> _mkrow(fr, pid, "", totals[pid]), sortrows, pid))
    end
    filter!(pid -> get(keep, pid, false), roots)
    sort!(roots; by = treekey, rev = st.rev)

    # Iterative DFS avoids stack overflow for deep process trees.
    rows = Row[]
    seen = Set{Int}()
    stack = Tuple{Int,String,Bool,Bool}[]
    for i in Iterators.reverse(eachindex(roots))
        push!(stack, (roots[i], "", false, true))
    end
    while !isempty(stack)
        pid, stem, lastchild, isroot = pop!(stack)
        pid in seen && continue
        push!(seen, pid)
        get(keep, pid, false) || continue
        push!(rows, _mkrow(fr, pid, isroot ? "" : stem * (lastchild ? "└─" : "├─"),
            st.aggregate ? totals[pid] : nothing))
        kids = [k for k in get(snap.children, pid, Int[])
                if k in allpids && get(keep, k, false) && !(k in seen)]
        sort!(kids; by = treekey, rev = st.rev)
        childstem = isroot ? "" : stem * (lastchild ? "  " : "│ ")
        for i in Iterators.reverse(eachindex(kids))
            push!(stack, (kids[i], childstem, i == length(kids), false))
        end
    end
    return rows
end

function _sync_selection!(st::TopState, rows::Vector{Row})
    if isempty(rows)
        st.sel = 0
        st.selpid = 0
        return
    end
    if st.sel == 0 && st.selpid == 0
        return
    end
    if st.selpid != 0
        index = findfirst(r -> r.pid == st.selpid, rows)
        index === nothing || (st.sel = index)
    end
    st.sel = clamp(st.sel, 1, length(rows))
    st.selpid = rows[st.sel].pid
    return
end

function _select_row!(st::TopState, index::Integer)
    st.sel = max(Int(index), 0)
    st.selpid = 0
    return
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
# BSD snapshots estimate start time from second-resolution elapsed time; `_same_start`
# accounts for that limited precision.
function _same_process(pid::Integer, expected_start::Float64)
    expected_start > 0 || return false
    pid = Int(pid)
    snap = try
        _snapshot(full = true)
    catch
        return false
    end
    current_start = get(snap.start, pid, -1.0)
    return _same_start(current_start, expected_start)
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
    indent = repeat(' ', min(textwidth(label), width - 8))
    graphemes = collect(Unicode.graphemes(label * text))
    out = String[]
    i, firstline = 1, true
    while i <= length(graphemes)
        prefix = firstline ? "" : indent
        cap = max(width - textwidth(prefix), 1)
        io = IOBuffer()
        used = 0
        j = i
        while j <= length(graphemes)
            gw = textwidth(graphemes[j])
            used + gw <= cap || break
            print(io, graphemes[j])
            used += gw
            j += 1
        end
        # `width` is at least 16, so this is only relevant to unusually wide graphemes.
        if j == i
            print(io, graphemes[j])
            j += 1
        end
        push!(out, prefix * String(take!(io)))
        i, firstline = j, false
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
  g            expanded CPU/memory graphs
  j            only Julia processes     C            show full command lines
  /            filter (enter apply, esc clear)       u  only my processes
  ↑ ↓ PgUp PgDn  select                 enter        detail pane
  k / K        SIGTERM / SIGKILL selection (asks to confirm)
  P            ask a Julia process to print a profile to its stderr
  + / -        change refresh interval
"""

# ---- rendering ----

# Footer entries double as mouse hit targets. Keeping their labels and actions together
# prevents the clickable regions from drifting away from what the user sees.
function _footer_items(; graphs::Bool = false, interval::Float64 = 2.0)
    slower = "+ slower ($(round(interval, digits = 1))s)"
    if graphs
        return [
            (label = "q quit", key = 'q'),
            (label = "g processes", key = 'g'),
            (label = "? help", key = '?'),
            (label = "␠ pause", key = ' '),
            (label = "− faster", key = '-'),
            (label = slower, key = '+'),
        ]
    end
    return [
        (label = "q quit", key = 'q'),
        (label = "? help", key = '?'),
        (label = "g graphs", key = 'g'),
        (label = "/ filter", key = '/'),
        (label = "T tree", key = 'T'),
        (label = "a Σ", key = 'a'),
        (label = "j julia", key = 'j'),
        (label = "C cmd", key = 'C'),
        (label = "↵ detail", key = '\r'),
        (label = "k kill", key = 'k'),
        (label = "P profile", key = 'P'),
        (label = "− faster", key = '-'),
        (label = slower, key = '+'),
    ]
end

function _footer_targets(width::Int; graphs::Bool = false, interval::Float64 = 2.0)
    targets = NamedTuple{(:first, :last, :key),Tuple{Int,Int,Char}}[]
    x = 2
    for item in _footer_items(; graphs, interval)
        x > width && break
        last = min(x + textwidth(item.label) - 1, width)
        push!(targets, (first = x, last, key = item.key))
        x += textwidth(item.label) + 2
    end
    return targets
end

# Underline only the key token, rather than the whole footer, as a quiet indication that
# the surrounding label is clickable.
function _print_footer!(io::IO, width::Int; graphs::Bool = false,
        color::Bool = true, interval::Float64 = 2.0)
    x = 1
    print(io, " ")
    x += 1
    for item in _footer_items(; graphs, interval)
        x > width && break
        available = width - x + 1
        label = textwidth(item.label) <= available ?
            item.label : _ellipsize(item.label, available)
        splitat = findfirst(' ', label)
        keyend = splitat === nothing ? lastindex(label) : prevind(label, splitat)
        key = label[firstindex(label):keyend]
        rest = splitat === nothing ? "" : label[splitat:end]
        color && print(io, "\e[4m")
        print(io, key)
        color && print(io, "\e[24m")
        print(io, rest)
        used = textwidth(label)
        x += used
        x > width && break
        gap = min(2, width - x + 1)
        print(io, repeat(' ', gap))
        x += gap
    end
    return
end

function _heading(label::AbstractString, width::Int;
        left::Bool = false, color::Bool = true, clickable::Bool = true)
    shown = textwidth(label) <= width ? String(label) :
            rstrip(_ellipsize(label, width))
    pad = max(width - textwidth(shown), 0)
    before, after = left ? (0, pad) : (pad, 0)
    return string(repeat(' ', before),
        color && clickable ? "\e[4m" : "", shown,
        color && clickable ? "\e[24m" : "", repeat(' ', after))
end

function _table_header_targets(width::Int)
    width = max(width, 60)
    showspark = width >= 100
    showage = width >= 88
    namew = width - 51 - (showspark ? 9 : 0) - (showage ? 7 : 0)
    targets = NamedTuple{(:first, :last, :sortkey),Tuple{Int,Int,Symbol}}[]
    x = 1
    push!(targets, (first = x, last = x + 6, sortkey = :pid)); x += 8
    x += 8 + 1  # USER and following space
    x += 1 + 1  # state and following space
    push!(targets, (first = x, last = x + namew - 1, sortkey = :name)); x += namew + 1
    showspark && (x += 8 + 1)
    push!(targets, (first = x, last = x + 4, sortkey = :threads)); x += 6
    push!(targets, (first = x, last = x + 6, sortkey = :mem)); x += 8
    if showage
        push!(targets, (first = x, last = x + 5, sortkey = :age)); x += 7
    end
    push!(targets, (first = x, last = x + 7, sortkey = :time)); x += 9
    push!(targets, (first = x, last = x + 6, sortkey = :cpu))
    return targets
end

function _history_stats(values::Vector{Float64})
    isempty(values) && return (0.0, 0.0)
    return sum(values) / length(values), maximum(values)
end

function _history_trend(values::Vector{Float64})
    length(values) < 2 && return "·"
    delta = values[end] - values[max(end - 3, 1)]
    return delta > 0.02 ? "↑" : delta < -0.02 ? "↓" : "→"
end

function _axis_label(row::Int, rows::Int)
    row == 1 && return "100%"
    row == rows && return "  0%"
    row == cld(rows, 2) && rows >= 5 && return " 50%"
    return "    "
end

function _render_graph_view(io::IO, st::TopState, fr::Frame;
        interactive::Bool = true, color::Bool = true)
    rows_avail, width = displaysize(io)
    height = max(rows_avail, 14)
    width = max(width, 60)
    buf = IOBuffer()
    c(s) = color ? s : ""
    interactive && print(buf, "\e[H")
    eol = interactive ? "\e[K\n" : "\n"

    syscpu = isempty(fr.percore) ? 0.0 : sum(fr.percore) / length(fr.percore)
    memfrac = fr.memtotal > 0 ? fr.memused / fr.memtotal : 0.0
    cpuavg, cpupeak = _history_stats(st.cpuhist)
    memavg, mempeak = _history_stats(st.memhist)
    ncores = length(fr.percore)

    corecols = width >= 68 ? 2 : 1
    maxcorerows = max(min(height ÷ 3, 8), 1)
    corerows = ncores == 0 ? 1 : min(cld(ncores, corecols), maxcorerows)
    graphspace = max(height - 5 - corerows, 4)
    cpurows = graphspace ÷ 2
    memrows = graphspace - cpurows
    graphwidth = max(width - 6, 1)

    header = string(" ProcessMonitor  ·  SIGNAL VIEW  ·  ", gethostname(),
        "  ·  up ", _fmtuptime(fr.uptime),
        @sprintf("  ·  load %.2f %.2f %.2f", fr.loadavg...),
        st.paused ? "  ·  PAUSED" : "")
    print(buf, c("\e[1;36m"), _ellipsize(header, width), c("\e[0m"), eol)

    cpuheading = if width >= 88
        @sprintf(" CPU TOTAL %s %5.1f%%   avg %5.1f%%   peak %5.1f%%   user %5.1f%%   sys %5.1f%%",
            _history_trend(st.cpuhist), 100syscpu, 100cpuavg, 100cpupeak,
            100fr.fuser, 100fr.fsys)
    else
        @sprintf(" CPU TOTAL %s %5.1f%%   user %5.1f%%   sys %5.1f%%",
            _history_trend(st.cpuhist), 100syscpu, 100fr.fuser, 100fr.fsys)
    end
    print(buf, c("\e[1m"), c(_pctcolor(syscpu)), _ellipsize(cpuheading, width),
        c("\e[0m"), eol)
    cpugraph = _braille(st.cpuhist, graphwidth, cpurows; color)
    for row in 1:cpurows
        print(buf, c("\e[2m"), _axis_label(row, cpurows), " │", c("\e[0m"),
            cpugraph[row], eol)
    end

    memheading = if width >= 88
        @sprintf(" MEMORY    %s %5.1f%%   avg %5.1f%%   peak %5.1f%%   %s / %s",
            _history_trend(st.memhist), 100memfrac, 100memavg, 100mempeak,
            _fmtbytes(fr.memused), _fmtbytes(fr.memtotal))
    else
        @sprintf(" MEMORY    %s %5.1f%%   %s / %s",
            _history_trend(st.memhist), 100memfrac,
            _fmtbytes(fr.memused), _fmtbytes(fr.memtotal))
    end
    print(buf, c("\e[1m"), c(_memcolor(memfrac)), _ellipsize(memheading, width),
        c("\e[0m"), eol)
    memgraph = _braille(st.memhist, graphwidth, memrows; color, palette = _memcolor)
    for row in 1:memrows
        print(buf, c("\e[2m"), _axis_label(row, memrows), " │", c("\e[0m"),
            memgraph[row], eol)
    end

    capacity = corecols * corerows
    coreindices = if ncores <= capacity
        collect(1:ncores)
    else
        sortperm(fr.percore; rev = true)[1:capacity]
    end
    coreheading = if ncores == 0
        " CORE TRAILS   unavailable"
    elseif ncores <= capacity
        @sprintf(" CORE TRAILS   all %d cores   hottest %5.1f%%", ncores,
            100maximum(fr.percore))
    else
        @sprintf(" CORE TRAILS   busiest %d / %d   hottest %5.1f%%", capacity, ncores,
            100maximum(fr.percore))
    end
    print(buf, c("\e[1m"), _ellipsize(coreheading, width), c("\e[0m"), eol)

    cellwidth = width ÷ corecols
    for row in 1:corerows
        for column in 1:corecols
            position = (row - 1) * corecols + column
            if position > length(coreindices)
                print(buf, repeat(' ', cellwidth))
                continue
            end
            index = coreindices[position]
            usage = fr.percore[index]
            label = @sprintf(" C%02d", index - 1)
            percent = @sprintf("%5.1f%%", 100usage)
            trailwidth = max(cellwidth - textwidth(label) - textwidth(percent) - 2, 1)
            history = index <= length(st.corehist) ? st.corehist[index] : Float64[]
            trail = _braille(history, trailwidth, 1; color)[1]
            print(buf, label, " ", c(_pctcolor(usage)), percent, c("\e[0m"), " ", trail)
            visible = textwidth(label) + textwidth(percent) + trailwidth + 2
            print(buf, repeat(' ', max(cellwidth - visible, 0)))
        end
        print(buf, repeat(' ', width - cellwidth * corecols), eol)
    end

    if interactive
        print(buf, c("\e[2m"))
        _print_footer!(buf, width; graphs = true, color, interval = st.interval)
        print(buf, c("\e[0m"), "\e[K")
    else
        print(buf, c("\e[2m"), _ellipsize(" newest samples →", width), c("\e[0m"), eol)
    end
    write(io, take!(buf))
    return length(_rows(st, fr))
end

function _render(io::IO, st::TopState, fr::Frame; interactive::Bool = true, color::Bool = true)
    st.graphs && !st.help &&
        return _render_graph_view(io, st, fr; interactive, color)
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
    st.graphs && push!(modes, "signals")
    isempty(st.filter) || push!(modes, "/" * st.filter)
    isempty(modes) || print(buf, c("\e[46;30m"), " ", join(modes, " · "), " ", c("\e[0m"))
    print(buf, eol)

    barw = max(min(width ÷ 5, 24), 10)
    print(buf, " ", _heading("CPU", 3; left = true, color), " ", c("▕"),
        _bar2(fr.fuser, fr.fsys, barw; color), c("▏"),
        @sprintf("%5.1f%%", 100syscpu),
        "   ", _heading("MEM", 3; left = true, color), " ", c("▕"),
        _bar(memfrac, barw; color), c("▏"),
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
    sortmark(k) = st.sortkey === k ? "▾" : ""
    print(buf, c("\e[7m"),
        _heading("PID" * sortmark(:pid), 7; color), " ",
        rpad("USER", 8), " ",
        "S", " ",
        _heading("NAME" * sortmark(:name), namew; left = true, color), " ",
        showspark ? rpad("HIST", 8) * " " : "",
        _heading("THR" * sortmark(:threads), 5; color), " ",
        _heading(agg * "RSS" * sortmark(:mem), 7; color), " ",
        showage ? _heading("AGE" * sortmark(:age), 6; color) * " " : "",
        _heading("TIME" * sortmark(:time), 8; color), " ",
        _heading(agg * "CPU%" * sortmark(:cpu), 7; color),
        c("\e[0m"), eol)

    rows = _rows(st, fr)
    _sync_selection!(st, rows)
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
    if st.sel == 0
        st.scroll = 0
    elseif st.sel <= st.scroll
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
                _ellipsize(r.uid < 0 ? "?" : _username(r.uid), 8), c("\e[0m"),
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
            print(buf, c("\e[2m"))
            _print_footer!(buf, width; color, interval = st.interval)
            print(buf, c("\e[0m"), "\e[K")
        end
    end
    write(io, take!(buf))
    return length(rows)
end

# ---- interactive loop ----

"""
    top(; interval::Real = 2.0, tree::Bool = false, graphs::Bool = false)

An interactive, `htop`-like view of the system's processes, built on the same snapshot
machinery as the rest of the package. Requires an interactive terminal; `top(io)` renders
a single non-interactive frame to any `IO` instead. `interval` must be finite and greater
than zero.

The header shows system CPU (user green / sys red) and memory with braille history
graphs, one mini-bar per core, load averages, uptime, process/thread totals, and a rollup
of all Julia processes (count, CPU, memory, threads). Julia rows are highlighted and
labeled with version (from the install path), role (`worker`, `precompile`) and
`--project`. Press `g` for the expanded CPU/memory signal view and `?` for the key
reference. In a mouse-capable terminal, click the underlined headings and footer controls;
click a process to select it and double-click it for details.
"""
function top(; interval::Real = 2.0, tree::Bool = false, graphs::Bool = false)
    Sys.iswindows() && error("ProcessMonitor: Windows is not yet supported")
    stdout isa Base.TTY || error("top() needs an interactive terminal; use top(io) for one frame")
    interval = _validated_interval(interval)
    st = TopState(; interval, tree, graphs)
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
        # Alternate screen, hidden cursor, and button-event tracking with SGR coordinates.
        # 1000 reports presses/releases without the noisy hover stream from 1003.
        print(stdout, "\e[?1049h\e[?25l\e[?1000h\e[?1006h\e[2J")
        flush(stdout)
        prev = _snapshot(full = true)
        prevcores = Sys.cpu_info()
        prevt = _monotime()
        fr = nothing
        lastrefresh_start = _monotime()
        priming = true
        while st.running
            now = _monotime()
            refresh_after = priming ? 0.15 : st.interval
            if !st.paused && now - lastrefresh_start >= refresh_after
                refresh_start = now
                snap = _snapshot(full = true)
                cores = Sys.cpu_info()
                t = _monotime()
                fr = _frame(prev, snap, prevcores, cores, max(t - prevt, 0.001))
                prev, prevcores, prevt = snap, cores, t
                lastrefresh_start = refresh_start
                priming = false
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
                # Disable mouse reporting before returning control to the REPL.
                print(stdout, "\e[?1006l\e[?1000l\e[?25h\e[?1049l")
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

function _pop_utf8_char!(queue::Vector{UInt8})
    b = queue[1]
    nbytes = b <= 0x7f ? 1 :
             0xc2 <= b <= 0xdf ? 2 :
             0xe0 <= b <= 0xef ? 3 :
             0xf0 <= b <= 0xf4 ? 4 : 0
    if nbytes == 0
        popfirst!(queue)
        return true, nothing
    end
    length(queue) >= nbytes || return false, nothing
    encoded = String(copy(queue[1:nbytes]))
    if !isvalid(encoded) || length(encoded) != 1
        popfirst!(queue)
        return true, nothing
    end
    splice!(queue, 1:nbytes)
    return true, first(encoded)
end

function _drop_last_grapheme(s::AbstractString)
    graphemes = collect(Unicode.graphemes(s))
    isempty(graphemes) || pop!(graphemes)
    return join(graphemes)
end

_default_sort_reverse(key::Symbol) = !(key in (:pid, :name))

function _set_sort!(st::TopState, key::Symbol; toggle::Bool = false)
    if toggle && st.sortkey === key
        st.rev = !st.rev
    else
        st.sortkey = key
        st.rev = _default_sort_reverse(key)
    end
    return
end

function _footer_key_at(x::Int, width::Int;
        graphs::Bool = false, interval::Float64 = 2.0)
    targets = _footer_targets(width; graphs, interval)
    target = findfirst(t -> t.first <= x <= t.last, targets)
    return target === nothing ? nothing : targets[target].key
end

# Handle a press reported by xterm's SGR mouse protocol. Coordinates are 1-based terminal
# cells. A single row click selects; a second click on the same live PID opens its detail
# pane. Column headings and the underlined footer keys invoke their keyboard equivalents.
function _handle_mouse!(st::TopState, button::Int, x::Int, y::Int, fr;
        rows_avail::Int = displaysize(stdout)[1],
        width::Int = displaysize(stdout)[2])
    x > 0 && y > 0 || return
    (button & 32) == 0 || return  # ignore pointer motion if a terminal sends it
    (button & 64) == 0 || return  # wheel events are not clicks
    (button & 3) == 0 || return   # left button only
    height = max(rows_avail, 14)
    width = max(width, 60)

    if st.help
        st.help = false
        return
    end
    # While text entry or a signal confirmation owns the footer, do not let a stray click
    # trigger an unrelated action underneath it.
    (st.filtering || st.pendpid != 0) && return

    if st.graphs
        if y == height
            key = _footer_key_at(x, width; graphs = true, interval = st.interval)
            key === nothing || _handle_key!(st, key, fr)
        end
        return
    end

    # The compact CPU/MEM summary is itself a doorway into the signal view.
    if 2 <= y <= 4
        st.graphs = true
        return
    end

    if y == 6
        target = findfirst(t -> t.first <= x <= t.last, _table_header_targets(width))
        if target !== nothing
            _set_sort!(st, _table_header_targets(width)[target].sortkey; toggle = true)
            st.lastclickpid = 0
        end
        return
    end

    if y == height && isempty(st.message)
        key = _footer_key_at(x, width; interval = st.interval)
        key === nothing || _handle_key!(st, key, fr)
        return
    end

    fr === nothing && return
    rows = _rows(st, fr)
    _sync_selection!(st, rows)
    detaillines = String[]
    if st.detail && 1 <= st.sel <= length(rows)
        detaillines = _detail_lines(fr, rows[st.sel], width, max(height ÷ 2, 6))
    end
    detailh = isempty(detaillines) ? 0 : length(detaillines) + 1
    nbody = max(height - 7 - detailh, 1)
    if 7 <= y <= 6 + nbody
        index = st.scroll + y - 6
        if 1 <= index <= length(rows)
            pid = rows[index].pid
            now = _monotime()
            doubleclick = st.lastclickpid == pid &&
                          0.0 <= now - st.lastclicktime <= 0.45
            st.sel = index
            st.selpid = pid
            st.lastclickpid = pid
            st.lastclicktime = now
            doubleclick && (st.detail = !st.detail)
        end
        return
    end

    return
end

function _decode_sgr_mouse(params::AbstractString)
    startswith(params, '<') || return nothing
    fields = split(params[2:end], ';')
    length(fields) == 3 || return nothing
    values = tryparse.(Int, fields)
    any(isnothing, values) && return nothing
    return (something(values[1]), something(values[2]), something(values[3]))
end

# Consume complete buffered input sequences. Incomplete escape sequences remain in `queue`
# because readavailable() may split one terminal keypress or UTF-8 character across reads.
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
                # `String(::Vector{UInt8})` may take ownership of and empty its input, so
                # materialize the parameter text once and share that immutable value.
                paramtext = String(params)
                ps = split(paramtext, ';')
                mouse = (final == 'M' || final == 'm') ?
                    _decode_sgr_mouse(paramtext) : nothing
                if mouse !== nothing
                    # SGR uses uppercase M for a button press and lowercase m for release.
                    if final == 'M'
                        button, x, y = mouse
                        _handle_mouse!(st, button, x, y, fr)
                    end
                elseif st.help
                    st.help = false
                elseif final == 'A'
                    _select_row!(st, st.sel - 1)
                elseif final == 'B'
                    _select_row!(st, st.sel + 1)  # clamped in render
                elseif final == '~' && !isempty(ps) && (ps[1] == "5" || ps[1] == "6")
                    _select_row!(st, ps[1] == "5" ? st.sel - 20 : st.sel + 20)
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
                k2 == 'A' && _select_row!(st, st.sel - 1)
                k2 == 'B' && _select_row!(st, st.sel + 1)
            else
                popfirst!(queue)
                st.escpending = 0.0
                changed = true
                _handle_bare_escape!(st)
            end
        else
            st.escpending = 0.0
            complete, key = _pop_utf8_char!(queue)
            complete || break
            changed = true
            key === nothing || _handle_key!(st, key, fr)
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
    while length(st.corehist) < length(fr.percore)
        push!(st.corehist, Float64[])
    end
    resize!(st.corehist, length(fr.percore))
    for (i, usage) in enumerate(fr.percore)
        push!(st.corehist[i], usage)
        length(st.corehist[i]) > HIST_LEN && popfirst!(st.corehist[i])
    end
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
            st.filter = _drop_last_grapheme(st.filter)
        elseif isprint(key)
            st.filter *= key
        end
        _select_row!(st, 0)
        return
    end
    if key == 'q' || key == '\x03'
        st.running = false
    elseif key == '?'
        st.help = true
    elseif key == ' '
        st.paused = !st.paused
    elseif key == 'g'
        st.graphs = !st.graphs
    elseif (key == '\r' || key == '\n') && st.sel > 0
        st.detail = !st.detail
    elseif key == 'c'
        _set_sort!(st, :cpu)
    elseif key == 'm'
        _set_sort!(st, :mem)
    elseif key == 't'
        _set_sort!(st, :time)
    elseif key == 's'
        _set_sort!(st, :age)  # sorts by -age: newest first
    elseif key == 'p'
        _set_sort!(st, :pid)
    elseif key == 'n'
        _set_sort!(st, :name)
    elseif key == 'T'
        st.tree = !st.tree
        _select_row!(st, 0)
    elseif key == 'a'
        st.aggregate = !st.aggregate
    elseif key == 'u'
        st.mine = !st.mine
        _select_row!(st, 0)
    elseif key == 'j'
        st.juliaonly = !st.juliaonly
        _select_row!(st, 0)
    elseif key == 'C'
        st.showcmd = !st.showcmd
    elseif key == '/'
        st.filtering = true
        st.filter = ""
        _select_row!(st, 0)
    elseif key == '+'
        st.interval = min(st.interval * 2, 60.0)
    elseif key == '-'
        st.interval = max(st.interval / 2, 0.25)
    elseif key == 'P' && fr !== nothing
        rows = _rows(st, fr)
        _sync_selection!(st, rows)
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
        _sync_selection!(st, rows)
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
    top(io::IO; interval::Real = 0.5, tree::Bool = false, graphs::Bool = false,
        color::Bool = false)

Render one frame of the process view to `io` (sampling CPU over `interval` seconds) and
return the number of process rows. Non-interactive; useful for logging and testing.
`interval` must be finite and greater than zero.
"""
function top(io::IO; interval::Real = 0.5, tree::Bool = false, graphs::Bool = false,
        color::Bool = false)
    Sys.iswindows() && error("ProcessMonitor: Windows is not yet supported")
    interval = _validated_interval(interval)
    st = TopState(; interval, tree, graphs)
    timer = Timer(interval)
    try
        prev = _snapshot(full = true)
        prevcores = Sys.cpu_info()
        t0 = _monotime()
        wait(timer)
        snap = _snapshot(full = true)
        fr = _frame(prev, snap, prevcores, Sys.cpu_info(), max(_monotime() - t0, 0.001))
        _push_hist!(st, fr)
        return _render(io, st, fr; interactive = false, color)
    finally
        close(timer)
    end
end

# Compile the frame/render path into the package image so the first interactive frame
# does not pay JIT latency.
if ccall(:jl_generating_output, Cint, ()) == 1 && !Sys.iswindows()
    let io = IOBuffer()
        try
            top(io; interval = 0.01)
            top(io; interval = 0.01, tree = true, color = true)
            top(io; interval = 0.01, graphs = true, color = true)
        catch
        end
    end
end
