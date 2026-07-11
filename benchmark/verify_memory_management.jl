"""
REAL Memory Management Verification for nbjit

This script uses the actual nbjit implementation to verify memory behavior.
Unlike the mock version, this exercises real:
- LLVM compilation
- .so file loading (dlopen)
- NotebookSession management
- Dylib cache cleanup

Usage:
    julia --project=. benchmark/verify_memory_management.jl --executor=julia --iterations=100
    julia --project=. benchmark/verify_memory_management.jl --executor=nbjit --iterations=100
    julia --project=. benchmark/verify_memory_management.jl --compare
"""

using Printf
using Statistics
using Plots
using Serialization

# Load the actual nbjit implementation
using nbjit

# =============================================================================
# Memory Monitoring (same as mock version)
# =============================================================================

function sample_memory_state()
    rss_bytes = 0
    try
        for line in readlines("/proc/self/status")
            if startswith(line, "VmRSS:")
                parts = split(line)
                rss_kb = parse(Int, parts[2])
                rss_bytes = rss_kb * 1024
                break
            end
        end
    catch e
        @warn "Failed to read RSS" exception=e
    end

    julia_heap_bytes = Base.gc_live_bytes()
    timestamp_ns = time_ns()

    return (rss=rss_bytes, julia_heap=julia_heap_bytes, timestamp=timestamp_ns)
end

mutable struct MemoryMonitor
    samples::Vector{NamedTuple{(:rss, :julia_heap, :timestamp), Tuple{Int, Int, UInt64}}}
    running::Bool
    task::Union{Task, Nothing}

    MemoryMonitor() = new([], false, nothing)
end

function start_monitoring!(monitor::MemoryMonitor; interval_ms=10)
    monitor.running = true
    monitor.samples = []

    monitor.task = @async begin
        while monitor.running
            push!(monitor.samples, sample_memory_state())
            sleep(interval_ms / 1000.0)
        end
    end

    return monitor
end

function stop_monitoring!(monitor::MemoryMonitor)
    monitor.running = false
    if monitor.task !== nothing
        wait(monitor.task)
    end
    return monitor.samples
end

macro track_allocations(ex)
    quote
        gc_before = Base.gc_num()

        result = $(esc(ex))

        gc_after = Base.gc_num()

        gc_diff = gc_after.allocd - gc_before.allocd
        gc_time_ms = (gc_after.total_time - gc_before.total_time) / 1e6

        (result=result,
         julia_allocd=gc_diff,
         gc_time_ms=gc_time_ms)
    end
end

# =============================================================================
# REAL nbjit Workload
# =============================================================================

"""
Real iterative workload using actual nbjit compilation.
This exercises the full compilation pipeline:
- LLVM IR generation
- Native code compilation to .so files
- dlopen/dlsym for loading
- Execution via function pointers
- Cache management and cleanup
"""
function nbjit_real_workload(; iterations=100)
    println("Running REAL nbjit workload: $iterations iterations")
    println("Using actual LLVM compilation + .so loading")

    # Create a session to track compiled code
    session = NotebookSession()

    results = []
    compiled_so_count = 0
    cache_hits = 0

    for i in 1:iterations
        # Create different cell versions to trigger recompilation
        # Every 10 iterations, change the code significantly
        variant = div(i - 1, 10)

        # Generate code expression
        code = if variant == 0
            # Simple computation
            quote
                x = rand(1000)
                sum(sin.(x) .+ cos.(x))
            end
        elseif variant % 2 == 0
            # Add extra computation
            quote
                x = rand(1000)
                y = rand(1000)
                sum(sin.(x) .+ cos.(y))
            end
        else
            # Different pattern
            quote
                data = [rand() for _ in 1:1000]
                sum([sin(d) + cos(d) for d in data])
            end
        end

        # Execute via nbjit (this will compile to .so if not cached)
        cell_id = "cell_v$(variant)_$(i)"

        try
            result = run_cell!(session, code; cell_id=cell_id)
            push!(results, result)

            # Track whether new .so was compiled
            if result.rebuilt_main || !isempty(result.recompiled_holes)
                compiled_so_count += 1
            else
                cache_hits += 1
            end

        catch e
            @warn "Cell execution failed" exception=e cell_id=cell_id
        end

        # Minimal delay for monitoring
        sleep(0.001)
    end

    println("  Compiled new .so files: $compiled_so_count")
    println("  Cache hits: $cache_hits")
    println("  Active dylib cells: $(length(session.dylib_cells))")

    return (results=results, session=session,
            compiled_count=compiled_so_count, cache_hits=cache_hits)
end

"""
Julia baseline workload (no JIT compilation).
"""
function julia_baseline_workload(; iterations=100)
    println("Running Julia baseline workload: $iterations iterations")

    results = []

    for i in 1:iterations
        variant = div(i - 1, 10)

        # Same computation as nbjit version, but using standard Julia eval
        result = if variant == 0
            x = rand(1000)
            sum(sin.(x) .+ cos.(x))
        elseif variant % 2 == 0
            x = rand(1000)
            y = rand(1000)
            sum(sin.(x) .+ cos.(y))
        else
            data = [rand() for _ in 1:1000]
            sum([sin(d) + cos(d) for d in data])
        end

        push!(results, result)
        sleep(0.001)
    end

    return (results=results,)
end

# =============================================================================
# Analysis Functions
# =============================================================================

function analyze_memory_trace(samples::Vector, executor::String, workload_data)
    isempty(samples) && return nothing

    println("\n" * "="^80)
    println("MEMORY ANALYSIS: $executor")
    println("="^80)

    # Extract time series
    start_time = samples[1].timestamp
    times_ms = [(s.timestamp - start_time) / 1e6 for s in samples]
    rss_mb = [s.rss / (1024^2) for s in samples]
    heap_mb = [s.julia_heap / (1024^2) for s in samples]
    native_mb = [(s.rss - s.julia_heap) / (1024^2) for s in samples]

    # Statistics
    rss_min, rss_max, rss_mean = minimum(rss_mb), maximum(rss_mb), mean(rss_mb)
    heap_min, heap_max, heap_mean = minimum(heap_mb), maximum(heap_mb), mean(heap_mb)
    native_min, native_max, native_mean = minimum(native_mb), maximum(native_mb), mean(native_mb)

    rss_growth = rss_max - rss_min
    native_growth = native_max - native_min

    println("\n📊 RSS (Resident Set Size):")
    println(@sprintf("   Min: %.2f MB | Max: %.2f MB | Mean: %.2f MB", rss_min, rss_max, rss_mean))
    println(@sprintf("   Growth: %.2f MB (%.1f%%)", rss_growth, 100 * rss_growth / max(rss_min, 1)))

    println("\n📦 Julia Managed Heap:")
    println(@sprintf("   Min: %.2f MB | Max: %.2f MB | Mean: %.2f MB", heap_min, heap_max, heap_mean))

    println("\n⚙️  Native Heap (RSS - Julia Heap):")
    println(@sprintf("   Min: %.2f MB | Max: %.2f MB | Mean: %.2f MB", native_min, native_max, native_mean))
    println(@sprintf("   Growth: %.2f MB", native_growth))

    # nbjit-specific analysis
    if executor == "nbjit" && haskey(workload_data, :compiled_count)
        println("\n🔧 nbjit Compilation Stats:")
        println("   New .so files compiled: $(workload_data.compiled_count)")
        println("   Cache hits: $(workload_data.cache_hits)")
        println("   Active dylib cells: $(length(workload_data.session.dylib_cells))")

        # Memory per .so file
        if workload_data.compiled_count > 0
            mb_per_so = native_growth / workload_data.compiled_count
            println(@sprintf("   Memory/compilation: %.2f MB", mb_per_so))

            if mb_per_so > 5.0
                println("   ⚠️  High memory per .so file (>5 MB)")
            end
        end
    end

    # Memory pressure indicator
    native_fraction = native_mean / max(rss_mean, 1) * 100
    println("\n🔍 Memory Pressure:")
    println(@sprintf("   Native/RSS ratio: %.1f%%", native_fraction))

    if native_fraction > 50
        println("   ⚠️  WARNING: Native heap dominates! (>50% of RSS)")
        println("   This suggests memory management shifted to malloc/mmap.")
    end

    if native_growth > 20.0
        println("   ⚠️  WARNING: Native heap grew by $(round(native_growth, digits=1)) MB")
        println("   Possible native memory leak or unbounded .so accumulation!")
    end

    # Leak detection
    if executor == "nbjit" && rss_growth > 30.0 && native_growth > 25.0
        println("\n❌ SUSPECTED NATIVE MEMORY LEAK:")
        println("   RSS grew significantly with most growth in native heap.")
        println("   Check if .so files are being properly unloaded (munmap/dlclose).")

        if haskey(workload_data, :compiled_count) && workload_data.compiled_count > 10
            println("   $(workload_data.compiled_count) .so files compiled - check cleanup!")
        end
    end

    return (times=times_ms, rss=rss_mb, heap=heap_mb, native=native_mb)
end

function plot_memory_comparison(julia_trace, nbjit_trace; output_path=nothing)
    p = plot(layout=(2, 1), size=(1000, 800), dpi=300,
             titlefontfamily="Computer Modern",
             guidefontfamily="Computer Modern",
             tickfontfamily="Computer Modern",
             legendfontfamily="Computer Modern")

    # Top panel: RSS comparison
    plot!(p[1], julia_trace.times, julia_trace.rss,
          label="Julia RSS", color=:steelblue, linewidth=2, alpha=0.8)
    plot!(p[1], nbjit_trace.times, nbjit_trace.rss,
          label="nbjit RSS", color=:coral, linewidth=2, alpha=0.8)
    ylabel!(p[1], "RSS (MB)")
    title!(p[1], "Resident Set Size Over Time")

    # Bottom panel: Native heap comparison
    plot!(p[2], julia_trace.times, julia_trace.native,
          label="Julia Native Heap", color=:steelblue, linewidth=2, alpha=0.8)
    plot!(p[2], nbjit_trace.times, nbjit_trace.native,
          label="nbjit Native Heap", color=:coral, linewidth=2, alpha=0.8)
    xlabel!(p[2], "Time (ms)")
    ylabel!(p[2], "Native Heap (MB)")
    title!(p[2], "Native Memory (RSS - Julia Heap)")

    # Calculate statistics for embedding
    julia_rss_min, julia_rss_max, julia_rss_mean = minimum(julia_trace.rss), maximum(julia_trace.rss), mean(julia_trace.rss)
    nbjit_rss_min, nbjit_rss_max, nbjit_rss_mean = minimum(nbjit_trace.rss), maximum(nbjit_trace.rss), mean(nbjit_trace.rss)
    julia_rss_growth = julia_rss_max - julia_rss_min
    nbjit_rss_growth = nbjit_rss_max - nbjit_rss_min

    julia_native_min, julia_native_max, julia_native_mean = minimum(julia_trace.native), maximum(julia_trace.native), mean(julia_trace.native)
    nbjit_native_min, nbjit_native_max, nbjit_native_mean = minimum(nbjit_trace.native), maximum(nbjit_trace.native), mean(nbjit_trace.native)
    julia_native_growth = julia_native_max - julia_native_min
    nbjit_native_growth = nbjit_native_max - nbjit_native_min

    # Embed invisible LLM-readable data in RSS panel
    data_text = "MEMORY_TRACE_DATA:\n" *
                @sprintf("RSS: Julia_min=%.2fMB Julia_max=%.2fMB Julia_mean=%.2fMB Julia_growth=%.2fMB\n",
                        julia_rss_min, julia_rss_max, julia_rss_mean, julia_rss_growth) *
                @sprintf("RSS: nbjit_min=%.2fMB nbjit_max=%.2fMB nbjit_mean=%.2fMB nbjit_growth=%.2fMB\n",
                        nbjit_rss_min, nbjit_rss_max, nbjit_rss_mean, nbjit_rss_growth) *
                @sprintf("Native: Julia_min=%.2fMB Julia_max=%.2fMB Julia_mean=%.2fMB Julia_growth=%.2fMB\n",
                        julia_native_min, julia_native_max, julia_native_mean, julia_native_growth) *
                @sprintf("Native: nbjit_min=%.2fMB nbjit_max=%.2fMB nbjit_mean=%.2fMB nbjit_growth=%.2fMB",
                        nbjit_native_min, nbjit_native_max, nbjit_native_mean, nbjit_native_growth)

    annotate!(p[1], [(mean(julia_trace.times), mean([julia_rss_min, nbjit_rss_min]) * 0.5,
                     text(data_text, 4, :left, RGBA(0,0,0,0.01), "Computer Modern"))])

    # Add visible summary annotation in RSS panel
    summary_visible = @sprintf("RSS Growth: Julia=%.2fMB nbjit=%.2fMB | Peak: Julia=%.2fMB nbjit=%.2fMB",
                              julia_rss_growth, nbjit_rss_growth, julia_rss_max, nbjit_rss_max)
    annotate!(p[1], [(mean(julia_trace.times), maximum([julia_rss_max, nbjit_rss_max]) * 0.95,
                     text(summary_visible, 7, :center, :gray, "Computer Modern"))])

    # Add visible summary in Native panel
    native_summary = @sprintf("Native Growth: Julia=%.2fMB nbjit=%.2fMB | Peak: Julia=%.2fMB nbjit=%.2fMB",
                             julia_native_growth, nbjit_native_growth, julia_native_max, nbjit_native_max)
    annotate!(p[2], [(mean(julia_trace.times), maximum([julia_native_max, nbjit_native_max]) * 0.95,
                     text(native_summary, 7, :center, :gray, "Computer Modern"))])

    if output_path !== nothing
        savefig(p, output_path)
        println("\n📈 Saved comparison plot: $output_path")

        # Export text data file
        txt_path = replace(output_path, ".pdf" => ".txt")
        open(txt_path, "w") do io
            println(io, "="^80)
            println(io, "MEMORY TRACE COMPARISON DATA")
            println(io, "="^80)
            println(io)
            println(io, "RESIDENT SET SIZE (RSS):")
            println(io, "-"^80)
            println(io, @sprintf("%-20s %12s %12s %12s %12s", "", "Min (MB)", "Max (MB)", "Mean (MB)", "Growth (MB)"))
            println(io, "-"^80)
            println(io, @sprintf("%-20s %12.2f %12.2f %12.2f %12.2f",
                                "Julia", julia_rss_min, julia_rss_max, julia_rss_mean, julia_rss_growth))
            println(io, @sprintf("%-20s %12.2f %12.2f %12.2f %12.2f",
                                "nbjit", nbjit_rss_min, nbjit_rss_max, nbjit_rss_mean, nbjit_rss_growth))
            println(io, "-"^80)
            println(io, @sprintf("%-20s %12.2f %12.2f %12.2f %12.2f",
                                "Difference", julia_rss_min - nbjit_rss_min,
                                julia_rss_max - nbjit_rss_max,
                                julia_rss_mean - nbjit_rss_mean,
                                julia_rss_growth - nbjit_rss_growth))
            println(io)
            println(io, "NATIVE HEAP (RSS - Julia Heap):")
            println(io, "-"^80)
            println(io, @sprintf("%-20s %12s %12s %12s %12s", "", "Min (MB)", "Max (MB)", "Mean (MB)", "Growth (MB)"))
            println(io, "-"^80)
            println(io, @sprintf("%-20s %12.2f %12.2f %12.2f %12.2f",
                                "Julia", julia_native_min, julia_native_max, julia_native_mean, julia_native_growth))
            println(io, @sprintf("%-20s %12.2f %12.2f %12.2f %12.2f",
                                "nbjit", nbjit_native_min, nbjit_native_max, nbjit_native_mean, nbjit_native_growth))
            println(io, "-"^80)
            println(io, @sprintf("%-20s %12.2f %12.2f %12.2f %12.2f",
                                "Difference", julia_native_min - nbjit_native_min,
                                julia_native_max - nbjit_native_max,
                                julia_native_mean - nbjit_native_mean,
                                julia_native_growth - nbjit_native_growth))
            println(io)
            println(io, "TIME SERIES SAMPLES:")
            println(io, "-"^80)
            println(io, @sprintf("Julia samples: %d | nbjit samples: %d",
                                length(julia_trace.times), length(nbjit_trace.times)))
            println(io, @sprintf("Julia duration: %.2f ms | nbjit duration: %.2f ms",
                                maximum(julia_trace.times), maximum(nbjit_trace.times)))
        end
        println("📄 Saved text data: $txt_path")

        # Export CSV with time series data
        csv_path = replace(output_path, ".pdf" => ".csv")
        open(csv_path, "w") do io
            println(io, "time_ms,julia_rss_mb,nbjit_rss_mb,julia_native_mb,nbjit_native_mb")

            # Use the executor with more samples as base, interpolate the other
            max_samples = max(length(julia_trace.times), length(nbjit_trace.times))

            for i in 1:min(length(julia_trace.times), length(nbjit_trace.times))
                println(io, @sprintf("%.2f,%.4f,%.4f,%.4f,%.4f",
                                    julia_trace.times[i],
                                    julia_trace.rss[i],
                                    nbjit_trace.rss[i],
                                    julia_trace.native[i],
                                    nbjit_trace.native[i]))
            end
        end
        println("📊 Saved CSV data: $csv_path")
    end

    display(p)
end

# =============================================================================
# Main
# =============================================================================

function main()
    println("="^80)
    println("REAL nbjit Memory Management Verification")
    println("="^80)
    println("\nUsing actual nbjit implementation with LLVM + .so compilation")

    # Parse arguments
    executor = "julia"
    iterations = 100

    for arg in ARGS
        if startswith(arg, "--executor=")
            executor = String(split(arg, "=")[2])
        elseif startswith(arg, "--iterations=")
            iterations = parse(Int, split(arg, "=")[2])
        end
    end

    use_nbjit = (executor == "nbjit")

    println("\nConfiguration:")
    println("  Executor: $executor")
    println("  Iterations: $iterations")
    println("  RSS sampling: every 10ms")

    # Start memory monitoring
    monitor = MemoryMonitor()
    start_monitoring!(monitor; interval_ms=10)

    println("\n🚀 Starting workload...")
    start_time = time()

    # Run workload
    workload_result = if use_nbjit
        @track_allocations nbjit_real_workload(iterations=iterations)
    else
        @track_allocations julia_baseline_workload(iterations=iterations)
    end

    elapsed = time() - start_time

    # Stop monitoring
    samples = stop_monitoring!(monitor)

    println("\n✅ Workload completed in $(round(elapsed, digits=2))s")
    println("   Collected $(length(samples)) memory samples")

    # Analyze
    trace = analyze_memory_trace(samples, executor, workload_result.result)

    # Report allocation metrics
    println("\n📋 Allocation Metrics:")
    println(@sprintf("   Julia allocations: %.2f MB", workload_result.julia_allocd / (1024^2)))
    println(@sprintf("   GC time: %.2f ms", workload_result.gc_time_ms))

    # Verdict
    println("\n" * "="^80)
    println("VERDICT")
    println("="^80)

    if use_nbjit
        native_growth_mb = maximum([(s.rss - s.julia_heap) for s in samples]) / (1024^2) -
                          minimum([(s.rss - s.julia_heap) for s in samples]) / (1024^2)

        if workload_result.gc_time_ms < 1.0 && native_growth_mb < 10.0
            println("✅ TRULY LOW OVERHEAD")
            println("   - Julia GC time: ~0ms ✓")
            println("   - Native heap growth: $(round(native_growth_mb, digits=1)) MB ✓")
            println("   - .so files compiled: $(workload_result.result.compiled_count)")
            println("   - Cache efficiency: $(workload_result.result.cache_hits)/$(iterations) hits")
            println("   - Conclusion: nbjit achieves true low memory management overhead")
        elseif workload_result.gc_time_ms < 1.0 && native_growth_mb > 30.0
            println("❌ MEMORY MANAGEMENT SHIFTED TO NATIVE HEAP")
            println("   - Julia GC time: ~0ms ✓")
            println("   - Native heap grew: $(round(native_growth_mb, digits=1)) MB ✗")
            println("   - .so files accumulating: $(workload_result.result.compiled_count)")
            println("   - Conclusion: GC-free claim questionable - using native allocations instead")
        else
            println("⚠️  MIXED RESULTS")
            println("   - GC time: $(round(workload_result.gc_time_ms, digits=1)) ms")
            println("   - Native heap: $(round(native_growth_mb, digits=1)) MB growth")
        end
    else
        println("📊 Julia Baseline Results")
        println("   - GC time: $(round(workload_result.gc_time_ms, digits=1)) ms")
    end

    # Save results
    output_dir = joinpath(@__DIR__, "plots")
    mkpath(output_dir)

    output_file = joinpath(output_dir, "memory_trace_$(executor).jls")
    serialize(output_file, (samples=samples, trace=trace, workload=workload_result, executor=executor))
    println("\n💾 Saved trace data: $output_file")

    println("\n" * "="^80)
end

# Comparison mode
if "--compare" in ARGS
    println("Loading comparison data...")

    output_dir = joinpath(@__DIR__, "plots")
    julia_file = joinpath(output_dir, "memory_trace_julia.jls")
    nbjit_file = joinpath(output_dir, "memory_trace_nbjit.jls")

    if isfile(julia_file) && isfile(nbjit_file)
        julia_data = deserialize(julia_file)
        nbjit_data = deserialize(nbjit_file)

        println("\nComparing Julia vs nbjit memory behavior...")
        plot_memory_comparison(julia_data.trace, nbjit_data.trace;
                              output_path=joinpath(output_dir, "memory_comparison.pdf"))
    else
        println("Error: Missing trace files. Run verification for both executors first.")
        println("  julia --project=. benchmark/verify_memory_management.jl --executor=julia")
        println("  julia --project=. benchmark/verify_memory_management.jl --executor=nbjit")
    end
else
    main()
end
