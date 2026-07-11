"""
Metrics Module

Measurement utilities and result structures for benchmark analysis.
"""
module MetricsLib

export ExecutionResult, ScenarioMetrics, BenchmarkReport, GCStats, CompilationTimings
export compute_metrics, create_report, print_metrics, print_comparison
export print_summary_table, save_to_csv, measure_ms, measure_with_memory
export measure_with_detailed_metrics, get_peak_rss_bytes, get_current_rss_bytes
export percentile, bytes_to_mb, bytes_to_kb

using Printf
using Dates
using Statistics
using ..CellEvolutionLib: CellExecution, ChangeType, INITIAL, PARAMETER, STRUCTURE, DEPENDENCY, BUGFIX, REFACTOR

# =============================================================================
# System-level Memory Metrics (Linux-focused with macOS fallback)
# =============================================================================

"""
Get current RSS (Resident Set Size) in bytes.
Linux: reads from /proc/self/status (VmRSS)
macOS: uses getrusage (less accurate)
"""
function get_current_rss_bytes()::Int64
    if Sys.islinux()
        try
            for line in eachline("/proc/self/status")
                if startswith(line, "VmRSS:")
                    parts = split(line)
                    return parse(Int64, parts[2]) * 1024  # kB → bytes
                end
            end
        catch
        end
    elseif Sys.isapple()
        # macOS: use getrusage
        try
            rusage = Vector{UInt8}(undef, 144)  # sizeof(struct rusage)
            ccall(:getrusage, Cint, (Cint, Ptr{UInt8}), 0, rusage)
            # ru_maxrss is at offset 0 on macOS, in bytes
            return reinterpret(Int64, rusage[1:8])[1]
        catch
        end
    end
    return Int64(0)
end

"""
Get peak RSS (High Water Mark) in bytes.
Linux: reads from /proc/self/status (VmHWM)
macOS: uses getrusage ru_maxrss
"""
function get_peak_rss_bytes()::Int64
    if Sys.islinux()
        try
            for line in eachline("/proc/self/status")
                if startswith(line, "VmHWM:")
                    parts = split(line)
                    return parse(Int64, parts[2]) * 1024  # kB → bytes
                end
            end
        catch
        end
    elseif Sys.isapple()
        # macOS: getrusage ru_maxrss (already peak)
        return get_current_rss_bytes()
    end
    return Int64(0)
end

# =============================================================================
# GC Statistics
# =============================================================================

"""
Detailed GC statistics for a single measurement period.
"""
struct GCStats
    gc_time_ns::Int64       # Total GC time in nanoseconds
    gc_pause_count::Int64   # Number of GC pauses
    gc_full_sweep::Int64    # Number of full sweeps
    alloc_bytes::Int64      # Total bytes allocated
end

function Base.show(io::IO, gc::GCStats)
    print(io, "GCStats(time=$(gc.gc_time_ns/1e6)ms, pauses=$(gc.gc_pause_count), sweeps=$(gc.gc_full_sweep), alloc=$(bytes_to_mb(gc.alloc_bytes))MB)")
end

# =============================================================================
# Compilation Timing Breakdown (for nbjit internal phases)
# =============================================================================

"""
Timing breakdown for nbjit compilation phases.
"""
mutable struct CompilationTimings
    parse_ms::Float64       # prepare_split + compute_hash
    codegen_ms::Float64     # partial_evaluate + generate_IR
    optimize_ms::Float64    # LLVM optimize!
    link_ms::Float64        # gcc/clang (compile_module_to_dylib)
    load_ms::Float64        # dlopen + dlsym
    total_ms::Float64       # Sum of all phases
end

CompilationTimings() = CompilationTimings(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

function Base.show(io::IO, t::CompilationTimings)
    print(io, @sprintf("CompilationTimings(parse=%.2f, codegen=%.2f, opt=%.2f, link=%.2f, load=%.2f, total=%.2f ms)",
                       t.parse_ms, t.codegen_ms, t.optimize_ms, t.link_ms, t.load_ms, t.total_ms))
end

"""
Compute percentile of a vector (0-100 scale).
"""
function percentile(v::Vector{Float64}, p::Real)
    isempty(v) && return 0.0
    sorted = sort(v)
    n = length(sorted)
    k = (p / 100) * (n - 1) + 1
    f = floor(Int, k)
    c = ceil(Int, k)
    if f == c
        return sorted[f]
    else
        return sorted[f] * (c - k) + sorted[c] * (k - f)
    end
end

# Prevent compiler optimization
global _benchmark_sink::Any = nothing

"""
Convert bytes to megabytes.
"""
bytes_to_mb(bytes::Int64) = bytes / (1024 * 1024)
bytes_to_mb(bytes::Real) = Float64(bytes) / (1024 * 1024)

"""
Convert bytes to kilobytes.
"""
bytes_to_kb(bytes::Int64) = bytes / 1024
bytes_to_kb(bytes::Real) = Float64(bytes) / 1024

"""
Measure execution time in milliseconds.
"""
function measure_ms(f)
    t = @elapsed (global _benchmark_sink = f())
    t * 1000
end

"""
Measure execution time and memory allocation.

Returns (time_ms, alloc_bytes, result).
"""
function measure_with_memory(f)
    GC.gc()  # Clean up before measurement

    alloc_before = Base.gc_live_bytes()
    stats_before = Base.gc_num()

    t = @elapsed (global _benchmark_sink = f())

    stats_after = Base.gc_num()
    alloc_after = Base.gc_live_bytes()

    # Total allocations during execution
    total_alloc = stats_after.malloc - stats_before.malloc +
                  stats_after.realloc - stats_before.realloc +
                  stats_after.poolalloc - stats_before.poolalloc

    # Net memory change (can be negative due to GC)
    net_memory = alloc_after - alloc_before

    return (
        time_ms = t * 1000,
        alloc_bytes = max(0, total_alloc),
        net_memory_bytes = net_memory,
        result = _benchmark_sink
    )
end

"""
Measure execution with detailed metrics including GC stats and RSS.

Returns a NamedTuple with:
- time_ms: Execution time in milliseconds
- alloc_bytes: Total bytes allocated
- gc_stats: GCStats struct with GC timing and counts
- rss_before: RSS before execution (bytes)
- rss_after: RSS after execution (bytes)
- rss_delta: RSS growth during execution (bytes) - can be negative if GC freed memory
- result: The result of the function
"""
function measure_with_detailed_metrics(f)
    # Force GC before measurement for consistent baseline
    GC.gc()
    GC.gc()  # Double GC to ensure finalizers run

    # Capture baseline metrics
    rss_before = get_current_rss_bytes()
    stats_before = Base.gc_num()

    # Execute the function
    t = @elapsed (global _benchmark_sink = f())

    # Capture post-execution metrics
    stats_after = Base.gc_num()
    rss_after = get_current_rss_bytes()
    rss_delta = rss_after - rss_before

    # Calculate GC statistics
    gc_time_ns = stats_after.total_time - stats_before.total_time
    gc_pause_count = stats_after.pause - stats_before.pause
    gc_full_sweep = stats_after.full_sweep - stats_before.full_sweep

    # Total allocations during execution
    total_alloc = stats_after.malloc - stats_before.malloc +
                  stats_after.realloc - stats_before.realloc +
                  stats_after.poolalloc - stats_before.poolalloc

    gc_stats = GCStats(gc_time_ns, gc_pause_count, gc_full_sweep, max(0, total_alloc))

    return (
        time_ms = t * 1000,
        alloc_bytes = max(0, total_alloc),
        gc_stats = gc_stats,
        rss_before = rss_before,
        rss_after = rss_after,
        rss_delta = rss_delta,
        result = _benchmark_sink
    )
end

"""
Result of a single cell execution with detailed metrics.
"""
struct ExecutionResult
    cell_id::String
    version::Int
    change_type::ChangeType
    time_ms::Float64
    triggered_by::Union{Nothing, String}

    # Memory metrics (0 if not measured)
    alloc_bytes::Int64          # Total bytes allocated during execution

    # Compilation breakdown (0 if not measured)
    compilation_ms::Float64     # Time spent in compilation
    execution_ms::Float64       # Time spent in actual execution
    cache_hit::Bool             # Whether this was a cache hit (nbjit only)

    # Compiled code size (nbjit only, 0 for Julia)
    compiled_code_bytes::Int64  # Total size of compiled dylib files

    # NEW: Extended metrics for paper-quality benchmarks
    gc_time_ns::Int64           # GC time in nanoseconds
    gc_pause_count::Int64       # Number of GC pauses
    rss_before::Int64           # RSS before execution (bytes)
    rss_after::Int64            # RSS after execution (bytes)
    rss_delta::Int64            # RSS growth during execution (bytes)

    # Full constructor with all fields including extended metrics
    function ExecutionResult(
        cell_id::String,
        version::Int,
        change_type::ChangeType,
        time_ms::Float64,
        triggered_by::Union{Nothing, String},
        alloc_bytes::Int64,
        compilation_ms::Float64,
        execution_ms::Float64,
        cache_hit::Bool,
        compiled_code_bytes::Int64,
        gc_time_ns::Int64,
        gc_pause_count::Int64,
        rss_before::Int64,
        rss_after::Int64,
        rss_delta::Int64
    )
        new(cell_id, version, change_type, time_ms, triggered_by,
            alloc_bytes, compilation_ms, execution_ms, cache_hit, compiled_code_bytes,
            gc_time_ns, gc_pause_count, rss_before, rss_after, rss_delta)
    end

    # Default constructor with all original fields (extended metrics default to 0)
    function ExecutionResult(
        cell_id::String,
        version::Int,
        change_type::ChangeType,
        time_ms::Float64,
        triggered_by::Union{Nothing, String},
        alloc_bytes::Int64,
        compilation_ms::Float64,
        execution_ms::Float64,
        cache_hit::Bool,
        compiled_code_bytes::Int64
    )
        new(cell_id, version, change_type, time_ms, triggered_by,
            alloc_bytes, compilation_ms, execution_ms, cache_hit, compiled_code_bytes,
            Int64(0), Int64(0), Int64(0), Int64(0), Int64(0))
    end

    # Constructor without compiled code size (defaults to 0)
    function ExecutionResult(
        cell_id::String,
        version::Int,
        change_type::ChangeType,
        time_ms::Float64,
        triggered_by::Union{Nothing, String},
        alloc_bytes::Int64,
        compilation_ms::Float64,
        execution_ms::Float64,
        cache_hit::Bool
    )
        new(cell_id, version, change_type, time_ms, triggered_by,
            alloc_bytes, compilation_ms, execution_ms, cache_hit, Int64(0),
            Int64(0), Int64(0), Int64(0), Int64(0), Int64(0))
    end

    # Backward-compatible constructor (without memory/compilation metrics)
    function ExecutionResult(
        cell_id::String,
        version::Int,
        change_type::ChangeType,
        time_ms::Float64,
        triggered_by::Union{Nothing, String}
    )
        new(cell_id, version, change_type, time_ms, triggered_by,
            Int64(0), 0.0, time_ms, false, Int64(0),
            Int64(0), Int64(0), Int64(0), Int64(0), Int64(0))
    end
end

"""
Aggregated metrics for a scenario.
"""
struct ScenarioMetrics
    scenario_name::String
    total_executions::Int

    # Timing breakdown by change type
    initial_times::Vector{Float64}
    parameter_times::Vector{Float64}
    structure_times::Vector{Float64}
    dependency_times::Vector{Float64}

    # Computed summary metrics (mean)
    total_time::Float64
    first_run_time::Float64
    avg_parameter_time::Float64
    avg_structure_time::Float64
    avg_dependency_time::Float64

    # Median metrics
    median_initial_time::Float64
    median_parameter_time::Float64
    median_structure_time::Float64

    # Percentile metrics (p95)
    p95_initial_time::Float64
    p95_parameter_time::Float64
    p95_structure_time::Float64
    p95_all_time::Float64  # p95 across all executions

    # Cumulative metrics
    cumulative_time::Float64  # Same as total_time, but explicit

    # Memory metrics
    total_alloc_bytes::Int64        # Total bytes allocated across all executions
    avg_alloc_bytes::Float64        # Average allocation per execution
    peak_alloc_bytes::Int64         # Maximum allocation in single execution

    # Compilation vs Execution breakdown
    total_compilation_ms::Float64   # Total time spent compiling
    total_execution_ms::Float64     # Total time spent executing
    compilation_ratio::Float64      # compilation_time / total_time
    cache_hit_count::Int            # Number of cache hits
    cache_hit_ratio::Float64        # cache_hits / total_executions

    # Compiled code size (nbjit only)
    total_compiled_code_bytes::Int64  # Total compiled dylib size
    avg_compiled_code_bytes::Float64  # Average compiled code per execution
    peak_compiled_code_bytes::Int64   # Maximum compiled code size

    # Scenario-level RSS metrics (measured per-executor, not process-wide)
    scenario_rss_start::Int64         # RSS at scenario start (bytes)
    scenario_rss_end::Int64           # RSS at scenario end (bytes)
    scenario_rss_growth::Int64        # Net RSS growth during scenario (bytes)
    max_rss_observed::Int64           # Maximum RSS observed during scenario (bytes)
    total_rss_delta::Int64            # Sum of all RSS deltas (can differ from growth due to GC)
end

"""
Full benchmark report comparing Julia vs nbjit.
"""
struct BenchmarkReport
    scenario_name::String
    julia_metrics::ScenarioMetrics
    nbjit_metrics::ScenarioMetrics

    # Speedup calculations (based on sum)
    total_speedup::Float64
    parameter_speedup::Float64
    structure_speedup::Float64
    dependency_speedup::Float64

    # Median-based speedup calculations
    median_initial_speedup::Float64
    median_parameter_speedup::Float64
    median_structure_speedup::Float64

    # Cumulative time saved
    cumulative_time_saved::Float64

    # Memory comparison
    memory_ratio::Float64           # julia_alloc / nbjit_alloc
    memory_saved_bytes::Int64       # julia_alloc - nbjit_alloc

    # Compilation comparison
    compilation_speedup::Float64    # julia_compilation / nbjit_compilation

    # Compiled code size (nbjit only, Julia will be 0)
    nbjit_compiled_code_bytes::Int64  # Total compiled code size for nbjit

    # RSS growth comparison
    julia_rss_growth::Int64         # Julia RSS growth during scenario (bytes)
    nbjit_rss_growth::Int64         # nbjit RSS growth during scenario (bytes)
    rss_growth_ratio::Float64       # julia_rss_growth / nbjit_rss_growth
end

"""
Compute metrics from execution results.
Optionally accepts scenario-level RSS measurements (rss_start, rss_end).
"""
function compute_metrics(
    scenario_name::String,
    results::Vector{ExecutionResult};
    rss_start::Int64=Int64(0),
    rss_end::Int64=Int64(0)
)::ScenarioMetrics
    initial_times = Float64[]
    parameter_times = Float64[]
    structure_times = Float64[]
    dependency_times = Float64[]

    for r in results
        if r.change_type == INITIAL
            push!(initial_times, r.time_ms)
        elseif r.change_type == PARAMETER
            push!(parameter_times, r.time_ms)
        elseif r.change_type == STRUCTURE || r.change_type == BUGFIX || r.change_type == REFACTOR
            push!(structure_times, r.time_ms)
        elseif r.change_type == DEPENDENCY
            push!(dependency_times, r.time_ms)
        end
    end

    all_times = [r.time_ms for r in results]
    total_time = sum(all_times)
    first_run_time = isempty(initial_times) ? 0.0 : sum(initial_times)

    # Mean metrics
    avg_parameter = isempty(parameter_times) ? 0.0 : sum(parameter_times) / length(parameter_times)
    avg_structure = isempty(structure_times) ? 0.0 : sum(structure_times) / length(structure_times)
    avg_dependency = isempty(dependency_times) ? 0.0 : sum(dependency_times) / length(dependency_times)

    # Median metrics
    median_initial = isempty(initial_times) ? 0.0 : median(initial_times)
    median_parameter = isempty(parameter_times) ? 0.0 : median(parameter_times)
    median_structure = isempty(structure_times) ? 0.0 : median(structure_times)

    # Percentile metrics (p95)
    p95_initial = percentile(initial_times, 95)
    p95_parameter = percentile(parameter_times, 95)
    p95_structure = percentile(structure_times, 95)
    p95_all = percentile(all_times, 95)

    # Cumulative time (same as total, but semantically distinct)
    cumulative_time = total_time

    # Memory metrics
    all_allocs = [r.alloc_bytes for r in results]
    total_alloc = sum(all_allocs)
    avg_alloc = isempty(results) ? 0.0 : total_alloc / length(results)
    peak_alloc = isempty(all_allocs) ? Int64(0) : maximum(all_allocs)

    # Compilation vs Execution breakdown
    total_compilation = sum(r.compilation_ms for r in results)
    total_execution = sum(r.execution_ms for r in results)
    compilation_ratio = total_time > 0 ? total_compilation / total_time : 0.0
    cache_hits = count(r -> r.cache_hit, results)
    cache_hit_ratio = isempty(results) ? 0.0 : cache_hits / length(results)

    # Compiled code size (nbjit only, 0 for Julia)
    all_code_sizes = [r.compiled_code_bytes for r in results]
    total_code_size = sum(all_code_sizes)
    avg_code_size = isempty(results) ? 0.0 : total_code_size / length(results)
    peak_code_size = isempty(all_code_sizes) ? Int64(0) : maximum(all_code_sizes)

    # Scenario-level RSS metrics
    scenario_rss_growth = rss_end - rss_start
    all_rss_afters = [r.rss_after for r in results]
    max_rss = isempty(all_rss_afters) ? rss_end : maximum(all_rss_afters)
    total_rss_delta = sum(r.rss_delta for r in results)

    return ScenarioMetrics(
        scenario_name,
        length(results),
        initial_times,
        parameter_times,
        structure_times,
        dependency_times,
        total_time,
        first_run_time,
        avg_parameter,
        avg_structure,
        avg_dependency,
        median_initial,
        median_parameter,
        median_structure,
        p95_initial,
        p95_parameter,
        p95_structure,
        p95_all,
        cumulative_time,
        total_alloc,
        avg_alloc,
        peak_alloc,
        total_compilation,
        total_execution,
        compilation_ratio,
        cache_hits,
        cache_hit_ratio,
        total_code_size,
        avg_code_size,
        peak_code_size,
        rss_start,
        rss_end,
        scenario_rss_growth,
        max_rss,
        total_rss_delta
    )
end

"""
Create a benchmark report comparing Julia and nbjit metrics.
"""
function create_report(
    scenario_name::String,
    julia_metrics::ScenarioMetrics,
    nbjit_metrics::ScenarioMetrics
)::BenchmarkReport
    total_speedup = julia_metrics.total_time / max(nbjit_metrics.total_time, 0.001)

    parameter_speedup = if isempty(julia_metrics.parameter_times) || isempty(nbjit_metrics.parameter_times)
        1.0
    else
        sum(julia_metrics.parameter_times) / max(sum(nbjit_metrics.parameter_times), 0.001)
    end

    structure_speedup = if isempty(julia_metrics.structure_times) || isempty(nbjit_metrics.structure_times)
        1.0
    else
        sum(julia_metrics.structure_times) / max(sum(nbjit_metrics.structure_times), 0.001)
    end

    dependency_speedup = if isempty(julia_metrics.dependency_times) || isempty(nbjit_metrics.dependency_times)
        1.0
    else
        sum(julia_metrics.dependency_times) / max(sum(nbjit_metrics.dependency_times), 0.001)
    end

    # Median-based speedups
    median_initial_speedup = julia_metrics.median_initial_time / max(nbjit_metrics.median_initial_time, 0.001)
    median_parameter_speedup = julia_metrics.median_parameter_time / max(nbjit_metrics.median_parameter_time, 0.001)
    median_structure_speedup = julia_metrics.median_structure_time / max(nbjit_metrics.median_structure_time, 0.001)

    # Cumulative time saved
    cumulative_time_saved = julia_metrics.cumulative_time - nbjit_metrics.cumulative_time

    # Memory comparison
    memory_ratio = julia_metrics.total_alloc_bytes / max(nbjit_metrics.total_alloc_bytes, 1)
    memory_saved = julia_metrics.total_alloc_bytes - nbjit_metrics.total_alloc_bytes

    # Compilation comparison
    compilation_speedup = julia_metrics.total_compilation_ms / max(nbjit_metrics.total_compilation_ms, 0.001)

    # Compiled code size (nbjit only)
    nbjit_code_size = nbjit_metrics.total_compiled_code_bytes

    # RSS growth comparison
    julia_rss_growth = julia_metrics.scenario_rss_growth
    nbjit_rss_growth = nbjit_metrics.scenario_rss_growth
    rss_growth_ratio = if nbjit_rss_growth != 0
        Float64(julia_rss_growth) / Float64(abs(nbjit_rss_growth))
    else
        1.0
    end

    return BenchmarkReport(
        scenario_name,
        julia_metrics,
        nbjit_metrics,
        total_speedup,
        parameter_speedup,
        structure_speedup,
        dependency_speedup,
        median_initial_speedup,
        median_parameter_speedup,
        median_structure_speedup,
        cumulative_time_saved,
        memory_ratio,
        memory_saved,
        compilation_speedup,
        nbjit_code_size,
        julia_rss_growth,
        nbjit_rss_growth,
        rss_growth_ratio
    )
end

"""
Print metrics for a single executor.
"""
function print_metrics(metrics::ScenarioMetrics)
    println("="^70)
    println("Scenario: $(metrics.scenario_name)")
    println("="^70)
    println()

    println(@sprintf("Total executions: %d", metrics.total_executions))
    println(@sprintf("Total time: %.2f ms", metrics.total_time))
    println(@sprintf("p95 latency: %.2f ms", metrics.p95_all_time))
    println()

    println("Breakdown by change type (count × median [p95]):")
    println("-"^55)

    if !isempty(metrics.initial_times)
        println(@sprintf("  Initial:    %3d × median %.2f ms [p95: %.2f ms]",
            length(metrics.initial_times), metrics.median_initial_time, metrics.p95_initial_time))
    end

    if !isempty(metrics.parameter_times)
        println(@sprintf("  Parameter:  %3d × median %.2f ms [p95: %.2f ms]",
            length(metrics.parameter_times), metrics.median_parameter_time, metrics.p95_parameter_time))
    end

    if !isempty(metrics.structure_times)
        println(@sprintf("  Structure:  %3d × median %.2f ms [p95: %.2f ms]",
            length(metrics.structure_times), metrics.median_structure_time, metrics.p95_structure_time))
    end

    if !isempty(metrics.dependency_times)
        println(@sprintf("  Dependency: %3d × avg %.2f ms",
            length(metrics.dependency_times), metrics.avg_dependency_time))
    end

    # Memory metrics
    if metrics.total_alloc_bytes > 0
        println()
        println("Memory:")
        println("-"^55)
        println(@sprintf("  Total allocated: %.2f MB", bytes_to_mb(metrics.total_alloc_bytes)))
        println(@sprintf("  Avg per execution: %.2f MB", bytes_to_mb(metrics.avg_alloc_bytes)))
        println(@sprintf("  Peak allocation: %.2f MB", bytes_to_mb(metrics.peak_alloc_bytes)))
    end

    # Compilation breakdown
    if metrics.total_compilation_ms > 0 || metrics.cache_hit_count > 0
        println()
        println("Compilation vs Execution:")
        println("-"^55)
        println(@sprintf("  Compilation time: %.2f ms (%.1f%%)",
            metrics.total_compilation_ms, metrics.compilation_ratio * 100))
        println(@sprintf("  Execution time: %.2f ms (%.1f%%)",
            metrics.total_execution_ms, (1 - metrics.compilation_ratio) * 100))
        println(@sprintf("  Cache hits: %d / %d (%.1f%%)",
            metrics.cache_hit_count, metrics.total_executions, metrics.cache_hit_ratio * 100))
    end

    # Compiled code size (nbjit only)
    if metrics.total_compiled_code_bytes > 0
        println()
        println("Compiled Code Size:")
        println("-"^55)
        println(@sprintf("  Total compiled: %.2f KB", bytes_to_kb(metrics.total_compiled_code_bytes)))
        println(@sprintf("  Avg per execution: %.2f KB", bytes_to_kb(metrics.avg_compiled_code_bytes)))
        println(@sprintf("  Peak size: %.2f KB", bytes_to_kb(metrics.peak_compiled_code_bytes)))
    end

    # RSS growth (if data available)
    if metrics.scenario_rss_start != 0 || metrics.scenario_rss_end != 0
        println()
        println("RSS Growth:")
        println("-"^55)
        println(@sprintf("  RSS start: %.2f MB", bytes_to_mb(metrics.scenario_rss_start)))
        println(@sprintf("  RSS end: %.2f MB", bytes_to_mb(metrics.scenario_rss_end)))
        println(@sprintf("  RSS growth: %.2f MB", bytes_to_mb(metrics.scenario_rss_growth)))
        println(@sprintf("  Max RSS observed: %.2f MB", bytes_to_mb(metrics.max_rss_observed)))
    end

    println()
end

"""
Print comparison between Julia and nbjit.
"""
function print_comparison(report::BenchmarkReport)
    julia = report.julia_metrics
    nbjit = report.nbjit_metrics

    println("="^95)
    println("SCENARIO: $(report.scenario_name)")
    println("="^95)
    println()

    # Main comparison table
    println(@sprintf("%-28s │ %12s │ %12s │ %10s",
        "Metric", "Julia (ms)", "nbjit (ms)", "Speedup"))
    println("-"^70)

    # First run (median)
    if !isempty(julia.initial_times)
        println(@sprintf("%-28s │ %12.2f │ %12.2f │ %9.2f×",
            "INITIAL (median)",
            julia.median_initial_time,
            nbjit.median_initial_time,
            report.median_initial_speedup))
    end

    # Parameter changes (median)
    if !isempty(julia.parameter_times)
        println(@sprintf("%-28s │ %12.2f │ %12.2f │ %9.2f×",
            "PARAMETER (median)",
            julia.median_parameter_time,
            nbjit.median_parameter_time,
            report.median_parameter_speedup))
    end

    # Structure changes (median)
    if !isempty(julia.structure_times)
        println(@sprintf("%-28s │ %12.2f │ %12.2f │ %9.2f×",
            "STRUCTURE (median)",
            julia.median_structure_time,
            nbjit.median_structure_time,
            report.median_structure_speedup))
    end

    println("-"^70)

    # p95 latency
    println(@sprintf("%-28s │ %12.2f │ %12.2f │ %9.2f×",
        "p95 latency",
        julia.p95_all_time,
        nbjit.p95_all_time,
        julia.p95_all_time / max(nbjit.p95_all_time, 0.001)))

    # Cumulative session time
    println(@sprintf("%-28s │ %12.2f │ %12.2f │ %9.2f×",
        "Cumulative session time",
        julia.cumulative_time,
        nbjit.cumulative_time,
        report.total_speedup))

    println("-"^70)
    println(@sprintf("%-28s │ %12s │ %12.2f ms saved",
        "Time saved", "", report.cumulative_time_saved))

    # Memory comparison (if data available)
    if julia.total_alloc_bytes > 0 || nbjit.total_alloc_bytes > 0
        println()
        println("Memory Comparison:")
        println("-"^70)
        println(@sprintf("%-28s │ %12.2f │ %12.2f │ %9.2f×",
            "Total allocated (MB)",
            bytes_to_mb(julia.total_alloc_bytes),
            bytes_to_mb(nbjit.total_alloc_bytes),
            report.memory_ratio))
        println(@sprintf("%-28s │ %12.2f │ %12.2f │",
            "Peak allocation (MB)",
            bytes_to_mb(julia.peak_alloc_bytes),
            bytes_to_mb(nbjit.peak_alloc_bytes)))
        if report.memory_saved_bytes != 0
            saved_mb = bytes_to_mb(report.memory_saved_bytes)
            sign = saved_mb > 0 ? "" : ""
            println(@sprintf("%-28s │ %12s │ %11.2f MB %s",
                "Memory difference", "", abs(saved_mb),
                saved_mb > 0 ? "saved" : "extra"))
        end
    end

    # RSS growth comparison (if data available)
    if julia.scenario_rss_start != 0 || nbjit.scenario_rss_start != 0
        println()
        println("RSS Growth Comparison:")
        println("-"^70)
        println(@sprintf("%-28s │ %12.2f │ %12.2f │",
            "RSS start (MB)",
            bytes_to_mb(julia.scenario_rss_start),
            bytes_to_mb(nbjit.scenario_rss_start)))
        println(@sprintf("%-28s │ %12.2f │ %12.2f │",
            "RSS end (MB)",
            bytes_to_mb(julia.scenario_rss_end),
            bytes_to_mb(nbjit.scenario_rss_end)))
        println(@sprintf("%-28s │ %12.2f │ %12.2f │ %9.2f×",
            "RSS growth (MB)",
            bytes_to_mb(julia.scenario_rss_growth),
            bytes_to_mb(nbjit.scenario_rss_growth),
            report.rss_growth_ratio))
        println(@sprintf("%-28s │ %12.2f │ %12.2f │",
            "Max RSS observed (MB)",
            bytes_to_mb(julia.max_rss_observed),
            bytes_to_mb(nbjit.max_rss_observed)))
    end

    # Compilation breakdown (if data available)
    if julia.total_compilation_ms > 0 || nbjit.cache_hit_count > 0
        println()
        println("Compilation Breakdown:")
        println("-"^70)
        println(@sprintf("%-28s │ %12.2f │ %12.2f │ %9.2f×",
            "Compilation time (ms)",
            julia.total_compilation_ms,
            nbjit.total_compilation_ms,
            report.compilation_speedup))
        println(@sprintf("%-28s │ %11.1f%% │ %11.1f%% │",
            "Compilation ratio",
            julia.compilation_ratio * 100,
            nbjit.compilation_ratio * 100))
        println(@sprintf("%-28s │ %12s │ %11.1f%% │",
            "Cache hit ratio",
            "N/A",
            nbjit.cache_hit_ratio * 100))
    end

    # Compiled code size (nbjit only)
    if nbjit.total_compiled_code_bytes > 0
        println()
        println("Compiled Code Size (nbjit):")
        println("-"^70)
        println(@sprintf("%-28s │ %12s │ %10.2f KB │",
            "Total compiled code", "N/A", bytes_to_kb(nbjit.total_compiled_code_bytes)))
        println(@sprintf("%-28s │ %12s │ %10.2f KB │",
            "Avg per execution", "N/A", bytes_to_kb(nbjit.avg_compiled_code_bytes)))
        println(@sprintf("%-28s │ %12s │ %10.2f KB │",
            "Peak compiled size", "N/A", bytes_to_kb(nbjit.peak_compiled_code_bytes)))
    end

    println()
end

"""
Save detailed results to CSV.
"""
function save_to_csv(
    filepath::String,
    scenario_name::String,
    julia_results::Vector{ExecutionResult},
    nbjit_results::Vector{ExecutionResult}
)
    open(filepath, "w") do io
        println(io, "scenario,executor,cell_id,version,change_type,time_ms,triggered_by,alloc_bytes,compilation_ms,execution_ms,cache_hit,compiled_code_bytes")

        for r in julia_results
            triggered = r.triggered_by === nothing ? "" : r.triggered_by
            println(io, "$(scenario_name),julia,$(r.cell_id),$(r.version),$(r.change_type),$(r.time_ms),$(triggered),$(r.alloc_bytes),$(r.compilation_ms),$(r.execution_ms),$(r.cache_hit),$(r.compiled_code_bytes)")
        end

        for r in nbjit_results
            triggered = r.triggered_by === nothing ? "" : r.triggered_by
            println(io, "$(scenario_name),nbjit,$(r.cell_id),$(r.version),$(r.change_type),$(r.time_ms),$(triggered),$(r.alloc_bytes),$(r.compilation_ms),$(r.execution_ms),$(r.cache_hit),$(r.compiled_code_bytes)")
        end
    end
    println("Results saved to: $filepath")
end

"""
Print a summary table for multiple reports.
"""
function print_summary_table(reports::Vector{BenchmarkReport})
    println("\n", "="^120)
    println("OVERALL SUMMARY (Median-based metrics)")
    println("="^120)
    println()

    # Time metrics table
    println("Time Metrics:")
    println(@sprintf("%-25s │ %10s │ %10s │ %8s │ %10s │ %10s │ %12s",
        "Scenario", "Julia", "nbjit", "Speedup", "Param Spd", "p95 Spd", "Time Saved"))
    println("-"^110)

    total_julia = 0.0
    total_nbjit = 0.0
    total_saved = 0.0

    for r in reports
        total_julia += r.julia_metrics.cumulative_time
        total_nbjit += r.nbjit_metrics.cumulative_time
        total_saved += r.cumulative_time_saved

        p95_speedup = r.julia_metrics.p95_all_time / max(r.nbjit_metrics.p95_all_time, 0.001)

        println(@sprintf("%-25s │ %10.1f │ %10.1f │ %7.1f× │ %9.1f× │ %9.1f× │ %10.1f ms",
            r.scenario_name,
            r.julia_metrics.cumulative_time,
            r.nbjit_metrics.cumulative_time,
            r.total_speedup,
            r.median_parameter_speedup,
            p95_speedup,
            r.cumulative_time_saved))
    end

    println("-"^110)
    overall_speedup = total_julia / max(total_nbjit, 0.001)
    println(@sprintf("%-25s │ %10.1f │ %10.1f │ %7.1f× │ %9s │ %9s │ %10.1f ms",
        "TOTAL", total_julia, total_nbjit, overall_speedup, "", "", total_saved))
    println()

    # Memory metrics table (if data available)
    has_memory_data = any(r -> r.julia_metrics.total_alloc_bytes > 0 || r.nbjit_metrics.total_alloc_bytes > 0, reports)
    if has_memory_data
        println("Memory Metrics:")
        println(@sprintf("%-25s │ %12s │ %12s │ %10s │ %10s",
            "Scenario", "Julia (MB)", "nbjit (MB)", "Ratio", "Cache Hit%"))
        println("-"^85)

        total_julia_mem = Int64(0)
        total_nbjit_mem = Int64(0)

        for r in reports
            total_julia_mem += r.julia_metrics.total_alloc_bytes
            total_nbjit_mem += r.nbjit_metrics.total_alloc_bytes

            println(@sprintf("%-25s │ %12.2f │ %12.2f │ %9.2f× │ %9.1f%%",
                r.scenario_name,
                bytes_to_mb(r.julia_metrics.total_alloc_bytes),
                bytes_to_mb(r.nbjit_metrics.total_alloc_bytes),
                r.memory_ratio,
                r.nbjit_metrics.cache_hit_ratio * 100))
        end

        println("-"^85)
        overall_mem_ratio = total_julia_mem / max(total_nbjit_mem, 1)
        println(@sprintf("%-25s │ %12.2f │ %12.2f │ %9.2f× │",
            "TOTAL", bytes_to_mb(total_julia_mem), bytes_to_mb(total_nbjit_mem), overall_mem_ratio))
        println()
    end

    # Compilation breakdown table (if data available)
    has_compilation_data = any(r -> r.julia_metrics.total_compilation_ms > 0 || r.nbjit_metrics.cache_hit_count > 0, reports)
    if has_compilation_data
        println("Compilation Breakdown:")
        println(@sprintf("%-25s │ %12s │ %12s │ %10s │ %12s │ %12s",
            "Scenario", "Julia Comp", "nbjit Comp", "Comp Spd", "Julia Exec", "nbjit Exec"))
        println("-"^100)

        for r in reports
            println(@sprintf("%-25s │ %10.1f ms │ %10.1f ms │ %9.1f× │ %10.1f ms │ %10.1f ms",
                r.scenario_name,
                r.julia_metrics.total_compilation_ms,
                r.nbjit_metrics.total_compilation_ms,
                r.compilation_speedup,
                r.julia_metrics.total_execution_ms,
                r.nbjit_metrics.total_execution_ms))
        end
        println()
    end

    # Compiled code size table (nbjit only, if data available)
    has_code_size_data = any(r -> r.nbjit_metrics.total_compiled_code_bytes > 0, reports)
    if has_code_size_data
        println("Compiled Code Size (nbjit):")
        println(@sprintf("%-25s │ %12s │ %12s │ %12s",
            "Scenario", "Total (KB)", "Avg (KB)", "Peak (KB)"))
        println("-"^75)

        total_code_size = Int64(0)

        for r in reports
            total_code_size += r.nbjit_metrics.total_compiled_code_bytes

            println(@sprintf("%-25s │ %12.2f │ %12.2f │ %12.2f",
                r.scenario_name,
                bytes_to_kb(r.nbjit_metrics.total_compiled_code_bytes),
                bytes_to_kb(r.nbjit_metrics.avg_compiled_code_bytes),
                bytes_to_kb(r.nbjit_metrics.peak_compiled_code_bytes)))
        end

        println("-"^75)
        println(@sprintf("%-25s │ %12.2f │ %12s │ %12s",
            "TOTAL", bytes_to_kb(total_code_size), "", ""))
        println()
    end
end

end # module
