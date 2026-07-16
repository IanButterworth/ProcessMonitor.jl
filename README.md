# CPUMonitor.jl

Measure the CPU utilization of a process in Julia, optionally including the subprocesses it
spawns.

Utilization is derived by differencing two samples of a process's cumulative CPU time, so it
always describes an *interval*, never an instant. `100%` means one CPU core was fully used on
average over the interval; a process using several cores can report more than `100%`.

CPU time is read from `/proc` on Linux (no external tools, so it works in minimal
containers) and from `ps` on macOS and the BSDs, where `ps` is always in the base system.
The `%cpu` column that `ps`/`top` report is deliberately avoided: it is a platform-dependent
decaying average (FreeBSD, for instance, often reports ~0), whereas differencing cumulative
CPU time is portable. Windows is not yet supported.

## Installation

```julia
pkg> add CPUMonitor
```

## Usage

### Sampler (non-blocking, reusable)

Best for polling — e.g. a timer that prints utilization periodically. Each call reports the
usage since the previous call:

```julia
using CPUMonitor

s = CPUSampler(getpid(); recursive=true)   # recursive: include subprocesses
# ... some work, or on each tick of a timer:
cpu_percent(s)   # => 96.3   (utilization since the last call)
```

`CPUSampler` also accepts a `Base.Process`:

```julia
p = run(`some_program`, wait=false)
s = CPUSampler(p; recursive=true)
```

### Blocking convenience

Samples, sleeps `interval` seconds, samples again, and returns the utilization over that
interval:

```julia
cpu_percent(getpid(); recursive=true, interval=0.5)   # => 96.3
cpu_percent(p; interval=1.0)                           # a Base.Process
```

## Notes

- `recursive=true` sums CPU time over the whole process subtree.
- On macOS/BSD `ps` reports CPU time with one-second resolution, so very short intervals
  quantize the result there; prefer an `interval` of at least a couple of seconds, or a
  `CPUSampler` over a longer polling period. Linux (`/proc`) has finer resolution.
