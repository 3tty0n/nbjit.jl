#!/usr/bin/env julia
using Pkg

const PROJECT_DIR = @__DIR__

println("Activating project...")
Pkg.activate(PROJECT_DIR)

println("Installing Julia dependencies...")
Pkg.instantiate()

println("Loading CondaPkg...")
@eval using CondaPkg

println("Resolving Python dependencies...")
CondaPkg.resolve()

println("Loading IJulia...")
@eval using IJulia

julia_version = "$(VERSION.major).$(VERSION.minor)"
kernel_name = "julia-$julia_version"
println("Installing IJulia kernel '$kernel_name'...")
IJulia.installkernel("Julia", "--project=$PROJECT_DIR")

println("Verifying installation...")

# Check Julia packages
try
    @eval using LLVM
    println("  LLVM.jl: OK (v$(pkgversion(LLVM)))")
catch
    println("  LLVM.jl: FAILED")
end

try
    @eval using PythonCall
    println("  PythonCall.jl: OK")
catch
    println("  PythonCall.jl: FAILED")
end

# Check Python packages
jupyter_client = false
try
    @eval using PythonCall
    pyimport("jupyter_client")
    println("  jupyter_client (Python): OK")
    jupyter_client = true
catch
    println("  jupyter_client (Python): FAILED")
end

if !jupyter_client
    try
        CondaPkg.add("jupyter_client")
        println("  jupyter_client (Python): OK, installed by CondaPkg")
        jupyter_client = true
    catch
        println("  jupyter_client (Python); FAILED, check your CondaPkg dependency")
    end
end

# Check kernel registration
try
    result = read(`jupyter kernelspec list`, String)
    if occursin("julia-$julia_version", result)
        println("  IJulia kernel: OK")
    else
        println("  IJulia kernel: NOT FOUND")
    end
catch
    println("  IJulia kernel: FAILED to check")
end

println("Setup complete.")
