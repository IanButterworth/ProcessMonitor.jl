# Entry point for the standalone `jtop` executable. Built with `juliac --trim`, so
# everything reachable from `main` has to be statically inferrable — see juliac/build.jl.

using ProcessMonitor: main
