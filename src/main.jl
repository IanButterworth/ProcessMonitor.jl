# Entry point for the standalone `jtop` app/executable. Can be built with `juliac --trim`, so
# everything reachable from `main` has to be statically inferrable — see juliac/build.jl.

const USAGE = """
jtop — an htop-like process view (ProcessMonitor.jl)

Usage: jtop [options]
  -i, --interval SECS   refresh interval (default 2.0)
  -t, --tree            start in tree view
  -g, --graphs          start in the expanded CPU/memory signal view
  -h, --help            show this message
"""

function main(args::Vector{String})
    interval = 2.0
    tree = false
    graphs = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "-h" || a == "--help"
            Core.println(Core.stdout, USAGE)
            return 0
        elseif a == "-t" || a == "--tree"
            tree = true
        elseif a == "-g" || a == "--graphs"
            graphs = true
        elseif a == "-i" || a == "--interval"
            i += 1
            i <= length(args) || (Core.println(Core.stdout, "jtop: $a needs a value"); return 2)
            v = tryparse(Float64, args[i])
            v === nothing && (Core.println(Core.stdout, "jtop: bad interval"); return 2)
            interval = v
        else
            Core.println(Core.stdout, "jtop: unknown argument")
            Core.println(Core.stdout, USAGE)
            return 2
        end
        i += 1
    end
    top(; interval, tree, graphs)
    return 0
end

@static if VERSION >= v"1.11"
    @main
end
