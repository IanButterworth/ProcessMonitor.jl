# ProcessMonitor.jl

Measure resource use of a process in Julia — CPU utilization, memory (RSS), and thread
count — optionally including the subprocesses it spawns. Includes `top()`, an interactive
`htop`-like terminal view built on the same machinery.

Process information is read without spawning a subprocess: from `/proc` on Linux (so it
works in minimal containers) and via libproc syscalls on macOS (so it works under sandboxes
that forbid executing `ps`). The BSDs use `ps`, which is always in the base system.
Windows is not yet supported.

## Installation

```julia
pkg> add ProcessMonitor
```

## CPU utilization

CPU% is derived by differencing two samples of a process's cumulative CPU time, so it
always describes an *interval*, never an instant. `100%` means one CPU core was fully used
on average over the interval; a process using several cores can report more than `100%`.
(The `%cpu` column that `ps`/`top` report is deliberately avoided: it is a
platform-dependent decaying average — FreeBSD, for instance, often reports ~0.)

### Sampler (non-blocking, reusable)

Best for polling — e.g. a timer that prints utilization periodically. Each call reports the
usage since the previous call:

```julia
using ProcessMonitor

s = CPUSampler(getpid(); recursive=true)   # recursive: include subprocesses
# ... some work, or on each tick of a timer:
cpu_percent(s)   # => 96.3   (utilization since the last call)
```

### Blocking convenience

Samples, sleeps `interval` seconds, samples again, and returns the utilization over that
interval:

```julia
cpu_percent(getpid(); recursive=true, interval=0.5)   # => 96.3
```

## Point-in-time reads

```julia
rss()                                # resident memory of this process, bytes
rss(pid; recursive=true)             # ... plus its live subprocesses
thread_count(pid)                    # OS threads in the process
cpu_time(pid)                        # cumulative CPU seconds so far
ProcessMonitor.info(pid; recursive=true)  # (; cpu_time, rss, threads, processes)
```

All functions also accept a `Base.Process`:

```julia
p = run(`some_program`, wait=false)
cpu_percent(p; interval=1.0)
rss(p; recursive=true)
```

## Interactive system view

```julia
julia> top()
```

```
 ProcessMonitor  mymac.local  up 3d 22:58  load 4.34 3.77 3.54  10 cores  458 procs  3304 thr
 CPU ▕█████▅              ▏ 28.4% ▃▄▆█▅▃▂▂▃▄▅▆▅▄▃▂
 MEM ▕█████████████▆      ▏ 68.5% ▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆   11G/16G
 cores ▃▃▃▃▂▂▁▅▃▂   julia: 3 procs  196%  1.4G  36 thr
    PID USER      NAME                             THR     RSS     TIME    CPU%▾
  82676 ian       julia 1.12.6                      27    830M     0:10    96.4
  82707 ian       └─julia 1.10.11                   18    451M     0:06    95.6
  ...
```

An `htop`-like view with some things `htop` doesn't have:

- **Tree view sorted by subtree** (`T`): trees are ordered by their whole subtree's usage,
  so "sort by CPU" surfaces the busiest tree even when its root is an idle shell; `a`
  additionally rolls each subtree's CPU/RSS/threads up into its parent's row — the "who is
  really using the CPU" question flat per-process views can't answer.
- **Julia-aware**: Julia processes are highlighted and labeled with their version (from
  the juliaup/app install path; in-tree builds show `dev`), role (`worker`,
  `precompile`) and `--project`; a header rollup totals Julia's CPU, memory and threads
  across the machine; `j` filters to Julia processes only; and `P` asks a Julia process
  to print a one-shot profile to its stderr (`SIGUSR1`/`SIGINFO`). Handy for watching a
  test suite, `Distributed` workers, or precompilation fan-out.
- **Braille history graphs** for system CPU and memory, per-process CPU sparklines on wide
  terminals, a per-core mini-bar row, and user/sys split CPU bars.
- **Process age and state columns** — sort by newest (`s`) to catch spawn storms; zombies
  and uninterruptible-sleep processes are color-coded.
- **Detail pane** (`enter`): full command line, executable, start time, parent, fd count.
- **Honest memory accounting**: active+wired+compressed on macOS (what Activity Monitor
  reports), `MemAvailable`-based on Linux — not the misleading `total - free`.
- **Interval-accurate CPU%** from cumulative CPU-time differencing (the same portable
  method as the API), not a decaying average.

Keys (`?` shows this in-app): `c`/`m`/`t`/`p`/`n`/`s` sort · `T` tree · `a` Σ rollup ·
`j` julia-only · `C` command lines · `/` filter · `u` mine-only · `↑`/`↓` select ·
`enter` detail · `k`/`K` SIGTERM/SIGKILL (with confirmation) · `P` profile · `+`/`-`
interval · `space` pause · `q` quit.

`top(io)` renders a single non-interactive frame to any `IO` (for logging or CI
diagnostics); `top(io; tree=true)` for the tree form.

## Notes

- `recursive=true` walks the process tree at call time, so it covers subprocesses that are
  still alive; resources of already-exited children are not included.
- Recursive `rss` counts pages shared between the processes once per process, so it can
  overstate the combined footprint.
- On the BSDs `ps` reports CPU time with one-second resolution, so very short `cpu_percent`
  intervals quantize the result; prefer a couple of seconds or a longer polling period.
  Linux and macOS have finer resolution. Thread counts on the BSDs need a `ps` with `nlwp`.
