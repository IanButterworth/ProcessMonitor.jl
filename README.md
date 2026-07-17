# ProcessMonitor.jl

Measure resource use of a process in Julia — CPU utilization, memory (RSS), and thread
count — optionally including the subprocesses it spawns.

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

## Notes

- `recursive=true` walks the process tree at call time, so it covers subprocesses that are
  still alive; resources of already-exited children are not included.
- Recursive `rss` counts pages shared between the processes once per process, so it can
  overstate the combined footprint.
- On the BSDs `ps` reports CPU time with one-second resolution, so very short `cpu_percent`
  intervals quantize the result; prefer a couple of seconds or a longer polling period.
  Linux and macOS have finer resolution. Thread counts on the BSDs need a `ps` with `nlwp`.
