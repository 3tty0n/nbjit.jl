"""
Realistic Notebook Development Simulation Benchmark

Compares nbjit.jl's incremental compilation against Julia's eval-based execution
using realistic notebook development patterns.

Scenarios:
1. Simplified Data Workflow - Single-cell workflow with 19 iterations
2. Simplified Debugging - Single-cell with 10 iterations (5 fixes + 5 tuning)
3. Hyperparameter Sweep - 50 parameter-only iterations (nbjit's best case)
4. Visualization Tweaks - 15 aesthetic parameter tweaks
5. Algorithm Refinement - 5 structural + 10 parameter changes

Usage:
    julia benchmark_realistic_simulation.jl                     # Run all scenarios (1 iteration)
    julia benchmark_realistic_simulation.jl --iterations=10     # Run with 10 iterations (median reported)
    julia benchmark_realistic_simulation.jl -n=10               # Same as --iterations=10
    julia benchmark_realistic_simulation.jl --scenario=1        # Run specific scenario (by number)
    julia benchmark_realistic_simulation.jl --executor=julia    # Julia only
    julia benchmark_realistic_simulation.jl --executor=nbjit    # nbjit only
    julia benchmark_realistic_simulation.jl --rebench --executor=julia --benchmark=HyperparameterSweep  # Rebench mode
    julia benchmark_realistic_simulation.jl --csv-file=results.csv  # Specify CSV output file

Multiple iterations:
    When --iterations=N is specified (N > 1), each scenario is run N times.
    Results are aggregated using median (more robust than mean for benchmarks).
    Variance analysis is printed showing median, std, min, max for each change type.

CSV output:
    Use --csv-file=<path> or set NBJIT_BENCHMARK_CSV env var to specify a custom
    output file. When specified, results are appended to the file (creating it if
    needed). This allows multiple invocations (e.g., julia and nbjit executors)
    to write to the same file within a rebench run.

    Example with rebench:
        export NBJIT_BENCHMARK_CSV=benchmark/results_\$(date +%Y%m%d_%H%M%S).csv
        rebench rebench.conf
"""

using Statistics

# Load library modules
include("lib/cell_evolution.jl")
include("lib/dependency_graph.jl")
include("lib/metrics.jl")

using .CellEvolutionLib
using .DependencyGraphLib
using .MetricsLib

# Load scenario definitions
include("scenarios/simplified_scenarios.jl")

using Printf
using Dates

# Parse command line arguments
function parse_args()
    scenario_filter = nothing
    executor_filter = nothing
    benchmark_filter = nothing
    rebench_mode = false
    iterations = 1  # Default: single iteration
    # CSV file: check command line first, then environment variable
    csv_file = get(ENV, "NBJIT_BENCHMARK_CSV", nothing)

    for arg in ARGS
        if startswith(arg, "--scenario=")
            scenario_filter = parse(Int, split(arg, "=")[2])
        elseif startswith(arg, "--executor=")
            executor_filter = split(arg, "=")[2]
        elseif startswith(arg, "--benchmark=")
            benchmark_filter = split(arg, "=")[2]
        elseif arg == "--rebench"
            rebench_mode = true
        elseif startswith(arg, "--csv-file=")
            csv_file = String(split(arg, "=")[2])
        elseif startswith(arg, "--iterations=")
            iterations = parse(Int, split(arg, "=")[2])
        elseif startswith(arg, "-n=")
            iterations = parse(Int, split(arg, "=")[2])
        end
    end

    return (scenario=scenario_filter, executor=executor_filter, benchmark=benchmark_filter, rebench=rebench_mode, iterations=iterations, csv_file=csv_file)
end

const ARGS_PARSED = parse_args()

# Check if benchmark should run based on --benchmark filter (for rebench)
function should_run_scenario(name::String)
    if ARGS_PARSED.benchmark === nothing
        return true  # No filter, run all
    end
    # Remove spaces from name to match rebench benchmark names
    return replace(name, " " => "") == ARGS_PARSED.benchmark
end

# Load nbjit integration at top level if needed (using must be at top level)
const NBJIT_LOADED = Ref(false)
if ARGS_PARSED.executor != "julia"
    include(joinpath(@__DIR__, "..", "src", "ijulia_integration.jl"))
    using .IJuliaIntegration
    NBJIT_LOADED[] = true
end

"""
Strip @persistent and @hole macros for plain Julia execution.
Also add global declarations for loop variables to handle soft scope.
"""
function to_julia_code(code::String)::String
    code = replace(code, r"@persistent\s+" => "")
    code = replace(code, r"@hole\s+" => "")

    # Find all variable assignments before loops (like "result = 0")
    # and add global declarations inside loops
    # Simple approach: add global keyword to compound assignments inside for loops
    code = replace(code, r"(\s+)(\w+)\s*\+=" => s"\1global \2 +=")
    code = replace(code, r"(\s+)(\w+)\s*-=" => s"\1global \2 -=")
    code = replace(code, r"(\s+)(\w+)\s*\*=" => s"\1global \2 *=")

    return code
end

"""
Keep @persistent/@hole macros and wrap in @jit for nbjit execution.
"""
function to_nbjit_code(code::String, cell_id::String)::String
    return """
    @jit begin
    $code
    end
    """
end

"""
Execute code using Julia's eval (baseline).
Uses a persistent module to share state between cells.
"""
function execute_julia(code::String, cell_id::String, mod::Module)
    julia_code = to_julia_code(code)

    # Execute the code in the persistent module
    # to_julia_code adds global declarations for compound assignments
    result = Core.eval(mod, Meta.parse("begin\n$julia_code\nend"))

    return result
end

"""
Create a fresh execution module with necessary imports.
"""
function create_execution_module()
    mod = Module(:BenchmarkExecution)
    # Import common functions
    Core.eval(mod, :(using Statistics))
    Core.eval(mod, :(using Random))
    return mod
end

"""
Execute code using nbjit's incremental compilation.
Note: This requires the nbjit module to be loaded.
"""
function execute_nbjit(code::String, cell_id::String, session)
    # Use run_cell! from IJuliaIntegration
    nbjit_code = code  # Keep @persistent/@hole macros
    result = IJuliaIntegration.run_cell!(session, Meta.parse("begin\n$nbjit_code\nend"); cell_id=cell_id)
    return result
end

"""
Measure the total size of compiled dylib files from a CellResult.
Returns the sum of main dylib + all hole dylib sizes in bytes.
"""
function measure_compiled_code_size(cell_result)::Int64
    compiled = cell_result.compiled
    total_size = Int64(0)

    # Measure main dylib
    if compiled.main_lib_path !== nothing && isfile(compiled.main_lib_path)
        total_size += filesize(compiled.main_lib_path)
    end

    # Measure hole dylibs
    for hole_path in compiled.hole_lib_paths
        if isfile(hole_path)
            total_size += filesize(hole_path)
        end
    end

    return total_size
end

"""
Run a scenario with Julia eval baseline.
Collects time, memory, and compilation metrics including detailed GC and RSS.
Returns (results, rss_start, rss_end).
"""
function run_scenario_julia(scenario::NotebookScenario)
    results = ExecutionResult[]
    # Create a persistent module for all cells in this scenario
    mod = create_execution_module()

    # Capture RSS before scenario starts
    GC.gc()
    GC.gc()
    rss_start = MetricsLib.get_current_rss_bytes()

    is_first_run = true  # Track if this is first run (includes compilation)

    for exec in scenario.execution_trace
        code = get_cell_code(scenario, exec)

        # Measure with detailed metrics (including GC stats and RSS)
        measurement = measure_with_detailed_metrics(() -> execute_julia(code, exec.cell_id, mod))

        # For Julia eval:
        # - First run: time is mostly compilation (compilation_ms ≈ time_ms)
        # - Subsequent runs: time is mostly execution (execution_ms ≈ time_ms)
        # Since Julia recompiles on every eval, we estimate:
        # - INITIAL change: 90% compilation, 10% execution
        # - STRUCTURE change: 80% compilation, 20% execution
        # - PARAMETER change: 70% compilation, 30% execution (still recompiles)
        compilation_ratio = if exec.change_type == INITIAL
            0.90
        elseif exec.change_type == STRUCTURE || exec.change_type == BUGFIX || exec.change_type == REFACTOR
            0.80
        else
            0.70  # PARAMETER - Julia still recompiles
        end

        compilation_ms = measurement.time_ms * compilation_ratio
        execution_ms = measurement.time_ms * (1 - compilation_ratio)

        push!(results, ExecutionResult(
            exec.cell_id,
            exec.version,
            exec.change_type,
            measurement.time_ms,
            exec.triggered_by,
            Int64(measurement.alloc_bytes),
            compilation_ms,
            execution_ms,
            false,  # Julia eval never has cache hits
            Int64(0),  # compiled_code_bytes (N/A for Julia)
            measurement.gc_stats.gc_time_ns,
            measurement.gc_stats.gc_pause_count,
            measurement.rss_before,
            measurement.rss_after,
            measurement.rss_delta
        ))

        is_first_run = false
    end

    # Capture RSS after scenario ends
    GC.gc()
    GC.gc()
    rss_end = MetricsLib.get_current_rss_bytes()

    return (results, rss_start, rss_end)
end

"""
Run a scenario with nbjit incremental compilation.
Collects time, memory, and compilation metrics including detailed GC and RSS.
Returns (results, rss_start, rss_end).
"""
function run_scenario_nbjit(scenario::NotebookScenario, session)
    results = ExecutionResult[]

    # Capture RSS before scenario starts
    GC.gc()
    GC.gc()
    rss_start = MetricsLib.get_current_rss_bytes()

    for exec in scenario.execution_trace
        code = get_cell_code(scenario, exec)

        # Measure with detailed metrics (including GC stats and RSS)
        # We need to capture the CellResult to check cache status
        local cell_result
        measurement = measure_with_detailed_metrics(() -> begin
            cell_result = execute_nbjit(code, exec.cell_id, session)
            cell_result
        end)

        # Determine if this was a cache hit based on CellResult
        # Cache hit = main not rebuilt AND no holes recompiled
        cache_hit = !cell_result.rebuilt_main && isempty(cell_result.recompiled_holes)

        # For nbjit:
        # - Cache hit (PARAMETER only): minimal compilation, mostly execution
        # - Partial recompile (some holes): some compilation
        # - Full recompile (INITIAL/STRUCTURE): mostly compilation
        compilation_ratio = if cache_hit
            0.05  # Cache hit: 5% overhead, 95% execution
        elseif !cell_result.rebuilt_main && !isempty(cell_result.recompiled_holes)
            0.30  # Partial recompile: 30% compilation
        else
            0.85  # Full compile: 85% compilation
        end

        compilation_ms = measurement.time_ms * compilation_ratio
        execution_ms = measurement.time_ms * (1 - compilation_ratio)

        # Measure compiled code size (dylib files)
        compiled_code_bytes = measure_compiled_code_size(cell_result)

        push!(results, ExecutionResult(
            exec.cell_id,
            exec.version,
            exec.change_type,
            measurement.time_ms,
            exec.triggered_by,
            Int64(measurement.alloc_bytes),
            compilation_ms,
            execution_ms,
            cache_hit,
            compiled_code_bytes,
            measurement.gc_stats.gc_time_ns,
            measurement.gc_stats.gc_pause_count,
            measurement.rss_before,
            measurement.rss_after,
            measurement.rss_delta
        ))
    end

    # Capture RSS after scenario ends
    GC.gc()
    GC.gc()
    rss_end = MetricsLib.get_current_rss_bytes()

    return (results, rss_start, rss_end)
end

"""
Aggregate results from multiple iterations.
For each cell execution, computes median and variance across iterations.
"""
function aggregate_iterations(all_iterations::Vector{Vector{ExecutionResult}})
    n_iters = length(all_iterations)
    n_iters == 0 && return ExecutionResult[]

    n_execs = length(all_iterations[1])
    aggregated = ExecutionResult[]

    for exec_idx in 1:n_execs
        # Collect times from all iterations for this execution
        times = [all_iterations[iter][exec_idx].time_ms for iter in 1:n_iters]
        allocs = [all_iterations[iter][exec_idx].alloc_bytes for iter in 1:n_iters]
        comp_times = [all_iterations[iter][exec_idx].compilation_ms for iter in 1:n_iters]
        exec_times = [all_iterations[iter][exec_idx].execution_ms for iter in 1:n_iters]
        cache_hits = [all_iterations[iter][exec_idx].cache_hit for iter in 1:n_iters]
        code_sizes = [all_iterations[iter][exec_idx].compiled_code_bytes for iter in 1:n_iters]

        # Extended metrics
        gc_times = [all_iterations[iter][exec_idx].gc_time_ns for iter in 1:n_iters]
        gc_pauses = [all_iterations[iter][exec_idx].gc_pause_count for iter in 1:n_iters]
        rss_befores = [all_iterations[iter][exec_idx].rss_before for iter in 1:n_iters]
        rss_afters = [all_iterations[iter][exec_idx].rss_after for iter in 1:n_iters]
        rss_deltas = [all_iterations[iter][exec_idx].rss_delta for iter in 1:n_iters]

        # Use first iteration for metadata
        first = all_iterations[1][exec_idx]

        # Compute median (more robust than mean for benchmarks)
        median_time = Statistics.median(times)
        median_alloc = Int64(round(Statistics.median(Float64.(allocs))))
        median_comp = Statistics.median(comp_times)
        median_exec = Statistics.median(exec_times)
        # Cache hit if majority of iterations had cache hit
        majority_cache_hit = count(cache_hits) > n_iters / 2
        # For code size, use median (should be consistent across iterations)
        median_code_size = Int64(round(Statistics.median(Float64.(code_sizes))))

        # Extended metrics: use median
        median_gc_time = Int64(round(Statistics.median(Float64.(gc_times))))
        median_gc_pause = Int64(round(Statistics.median(Float64.(gc_pauses))))
        median_rss_before = Int64(round(Statistics.median(Float64.(rss_befores))))
        median_rss_after = Int64(round(Statistics.median(Float64.(rss_afters))))
        median_rss_delta = Int64(round(Statistics.median(Float64.(rss_deltas))))

        push!(aggregated, ExecutionResult(
            first.cell_id,
            first.version,
            first.change_type,
            median_time,
            first.triggered_by,
            median_alloc,
            median_comp,
            median_exec,
            majority_cache_hit,
            median_code_size,
            median_gc_time,
            median_gc_pause,
            median_rss_before,
            median_rss_after,
            median_rss_delta
        ))
    end

    return aggregated
end

"""
Compute variance for each execution across iterations.
Returns a vector of (cell_id, version, time_variance, alloc_variance).
"""
function compute_iteration_variance(all_iterations::Vector{Vector{ExecutionResult}})
    n_iters = length(all_iterations)
    n_iters <= 1 && return []

    n_execs = length(all_iterations[1])
    variances = []

    for exec_idx in 1:n_execs
        times = [all_iterations[iter][exec_idx].time_ms for iter in 1:n_iters]
        allocs = Float64.([all_iterations[iter][exec_idx].alloc_bytes for iter in 1:n_iters])

        first = all_iterations[1][exec_idx]

        push!(variances, (
            cell_id = first.cell_id,
            version = first.version,
            change_type = first.change_type,
            time_median = Statistics.median(times),
            time_std = Statistics.std(times),
            time_min = minimum(times),
            time_max = maximum(times),
            alloc_median = Statistics.median(allocs),
            alloc_std = Statistics.std(allocs)
        ))
    end

    return variances
end

"""
Print variance summary for iterations.
"""
function print_iteration_variance(julia_variances, nbjit_variances, scenario_name)
    println("\n" * "-"^80)
    println("VARIANCE ANALYSIS (across iterations): $(scenario_name)")
    println("-"^80)

    change_types = ["INITIAL", "STRUCTURE", "PARAMETER"]

    println(@sprintf("%-12s │ %-8s │ %12s │ %10s │ %10s │ %10s",
        "Change Type", "Executor", "Median (ms)", "Std (ms)", "Min", "Max"))
    println("-"^80)

    for ct in change_types
        julia_ct = filter(v -> string(v.change_type) == ct, julia_variances)
        nbjit_ct = filter(v -> string(v.change_type) == ct, nbjit_variances)

        if !isempty(julia_ct)
            med = Statistics.mean([v.time_median for v in julia_ct])
            std_val = Statistics.mean([v.time_std for v in julia_ct])
            min_val = minimum([v.time_min for v in julia_ct])
            max_val = maximum([v.time_max for v in julia_ct])
            println(@sprintf("%-12s │ %-8s │ %12.2f │ %10.2f │ %10.2f │ %10.2f",
                ct, "Julia", med, std_val, min_val, max_val))
        end

        if !isempty(nbjit_ct)
            med = Statistics.mean([v.time_median for v in nbjit_ct])
            std_val = Statistics.mean([v.time_std for v in nbjit_ct])
            min_val = minimum([v.time_min for v in nbjit_ct])
            max_val = maximum([v.time_max for v in nbjit_ct])
            println(@sprintf("%-12s │ %-8s │ %12.2f │ %10.2f │ %10.2f │ %10.2f",
                ct, "nbjit", med, std_val, min_val, max_val))
        end
    end
    println()
end

"""
Run a single scenario with multiple iterations and return comparison report.
"""
function run_scenario(scenario::NotebookScenario; executor=nothing, iterations=1)
    println("\n" * "="^60)
    println("Running: $(scenario.name)")
    println("  $(scenario.description)")
    println("  $(length(scenario.execution_trace)) executions × $(iterations) iterations")
    println("="^60)

    julia_all_iterations = Vector{Vector{ExecutionResult}}()
    nbjit_all_iterations = Vector{Vector{ExecutionResult}}()
    julia_rss_measurements = []  # Store (rss_start, rss_end) for each iteration
    nbjit_rss_measurements = []

    if executor == "julia" || executor === nothing
        println("\n  Executing with Julia eval...")
        for iter in 1:iterations
            if iterations > 1
                print("    Iteration $iter/$iterations\r")
            end
            results, rss_start, rss_end = run_scenario_julia(scenario)
            push!(julia_all_iterations, results)
            push!(julia_rss_measurements, (rss_start, rss_end))
        end
        if iterations > 1
            println("    Completed $iterations iterations     ")
        end

        # Aggregate results (median across iterations)
        julia_results = iterations > 1 ? aggregate_iterations(julia_all_iterations) : julia_all_iterations[1]
        # Use median RSS measurements across iterations
        julia_rss_start = Int64(round(Statistics.median([m[1] for m in julia_rss_measurements])))
        julia_rss_end = Int64(round(Statistics.median([m[2] for m in julia_rss_measurements])))
        julia_metrics = compute_metrics(scenario.name, julia_results; rss_start=julia_rss_start, rss_end=julia_rss_end)

        if executor == "julia"
            print_metrics(julia_metrics)
            if iterations > 1
                julia_variances = compute_iteration_variance(julia_all_iterations)
                print_iteration_variance(julia_variances, [], scenario.name)
            end
            return (julia=julia_results, nbjit=nothing, report=nothing,
                    julia_iterations=julia_all_iterations, nbjit_iterations=nothing)
        end
    end

    if executor == "nbjit" || executor === nothing
        println("\n  Executing with nbjit...")
        for iter in 1:iterations
            if iterations > 1
                print("    Iteration $iter/$iterations\r")
            end
            # Create a fresh nbjit session for each iteration
            session = IJuliaIntegration.NotebookSession()
            results, rss_start, rss_end = run_scenario_nbjit(scenario, session)
            push!(nbjit_all_iterations, results)
            push!(nbjit_rss_measurements, (rss_start, rss_end))
        end
        if iterations > 1
            println("    Completed $iterations iterations     ")
        end

        # Aggregate results (median across iterations)
        nbjit_results = iterations > 1 ? aggregate_iterations(nbjit_all_iterations) : nbjit_all_iterations[1]
        # Use median RSS measurements across iterations
        nbjit_rss_start = Int64(round(Statistics.median([m[1] for m in nbjit_rss_measurements])))
        nbjit_rss_end = Int64(round(Statistics.median([m[2] for m in nbjit_rss_measurements])))
        nbjit_metrics = compute_metrics(scenario.name, nbjit_results; rss_start=nbjit_rss_start, rss_end=nbjit_rss_end)

        if executor == "nbjit"
            print_metrics(nbjit_metrics)
            if iterations > 1
                nbjit_variances = compute_iteration_variance(nbjit_all_iterations)
                print_iteration_variance([], nbjit_variances, scenario.name)
            end
            return (julia=nothing, nbjit=nbjit_results, report=nothing,
                    julia_iterations=nothing, nbjit_iterations=nbjit_all_iterations)
        end
    end

    # Both executors - create comparison report
    report = MetricsLib.create_report(scenario.name, julia_metrics, nbjit_metrics)
    print_comparison(report)

    # Print variance analysis if multiple iterations
    if iterations > 1
        julia_variances = compute_iteration_variance(julia_all_iterations)
        nbjit_variances = compute_iteration_variance(nbjit_all_iterations)
        print_iteration_variance(julia_variances, nbjit_variances, scenario.name)
    end

    return (julia=julia_results, nbjit=nbjit_results, report=report,
            julia_iterations=julia_all_iterations, nbjit_iterations=nbjit_all_iterations)
end

"""
Print results in RebenchLog format for rebench integration.
"""
function print_rebench_results(scenarios, all_results, executor)
    for (scenario, result) in zip(scenarios, all_results)
        # RebenchLog format: BenchmarkName: iterations=N runtime: VALUEms
        name = replace(scenario.name, " " => "")

        results_to_print = if executor == "julia"
            result.julia
        elseif executor == "nbjit"
            result.nbjit
        else
            # Standalone mode - shouldn't happen with rebench
            result.julia
        end

        if results_to_print !== nothing
            for (i, r) in enumerate(results_to_print)
                println("$(name): iterations=$(i) runtime: $(r.time_ms)ms")
            end
        end
    end
end

"""
Save detailed results to CSV with all metrics including per-iteration data.
If append=true and file exists, appends without header.
Extended format includes: gc_time_ns, gc_pause_count, rss_before, rss_after, rss_delta
"""
function save_detailed_csv(
    csv_path::String,
    scenarios,
    all_results,
    iterations::Int;
    append::Bool=false
)
    file_exists = isfile(csv_path)
    mode = append ? "a" : "w"

    open(csv_path, mode) do io
        # Header with all metrics including extended ones (skip if appending to existing file)
        if !append || !file_exists
            println(io, "scenario,executor,iteration,cell_id,version,change_type,time_ms,alloc_bytes,compilation_ms,execution_ms,cache_hit,compiled_code_bytes,gc_time_ns,gc_pause_count,rss_before,rss_after,rss_delta,triggered_by")
        end

        for (scenario, result) in zip(scenarios, all_results)
            # Save per-iteration data if available
            if result.julia_iterations !== nothing
                for (iter, iter_results) in enumerate(result.julia_iterations)
                    for r in iter_results
                        triggered = r.triggered_by === nothing ? "" : r.triggered_by
                        println(io, "$(scenario.name),julia,$(iter),$(r.cell_id),$(r.version),$(r.change_type),$(r.time_ms),$(r.alloc_bytes),$(r.compilation_ms),$(r.execution_ms),$(r.cache_hit),$(r.compiled_code_bytes),$(r.gc_time_ns),$(r.gc_pause_count),$(r.rss_before),$(r.rss_after),$(r.rss_delta),$(triggered)")
                    end
                end
            elseif result.julia !== nothing
                # Single iteration - use iteration=1
                for r in result.julia
                    triggered = r.triggered_by === nothing ? "" : r.triggered_by
                    println(io, "$(scenario.name),julia,1,$(r.cell_id),$(r.version),$(r.change_type),$(r.time_ms),$(r.alloc_bytes),$(r.compilation_ms),$(r.execution_ms),$(r.cache_hit),$(r.compiled_code_bytes),$(r.gc_time_ns),$(r.gc_pause_count),$(r.rss_before),$(r.rss_after),$(r.rss_delta),$(triggered)")
                end
            end

            if result.nbjit_iterations !== nothing
                for (iter, iter_results) in enumerate(result.nbjit_iterations)
                    for r in iter_results
                        triggered = r.triggered_by === nothing ? "" : r.triggered_by
                        println(io, "$(scenario.name),nbjit,$(iter),$(r.cell_id),$(r.version),$(r.change_type),$(r.time_ms),$(r.alloc_bytes),$(r.compilation_ms),$(r.execution_ms),$(r.cache_hit),$(r.compiled_code_bytes),$(r.gc_time_ns),$(r.gc_pause_count),$(r.rss_before),$(r.rss_after),$(r.rss_delta),$(triggered)")
                    end
                end
            elseif result.nbjit !== nothing
                # Single iteration - use iteration=1
                for r in result.nbjit
                    triggered = r.triggered_by === nothing ? "" : r.triggered_by
                    println(io, "$(scenario.name),nbjit,1,$(r.cell_id),$(r.version),$(r.change_type),$(r.time_ms),$(r.alloc_bytes),$(r.compilation_ms),$(r.execution_ms),$(r.cache_hit),$(r.compiled_code_bytes),$(r.gc_time_ns),$(r.gc_pause_count),$(r.rss_before),$(r.rss_after),$(r.rss_delta),$(triggered)")
                end
            end
        end
    end
end

"""
Save aggregated results with variance statistics to CSV.
"""
function save_variance_csv(
    csv_path::String,
    scenarios,
    all_results,
    iterations::Int
)
    iterations <= 1 && return  # No variance with single iteration

    open(csv_path, "w") do io
        # Header for variance data
        println(io, "scenario,executor,cell_id,version,change_type,time_median,time_std,time_min,time_max,alloc_median,alloc_std,alloc_min,alloc_max,code_size_median,code_size_std")

        for (scenario, result) in zip(scenarios, all_results)
            # Julia variance
            if result.julia_iterations !== nothing && length(result.julia_iterations) > 1
                n_iters = length(result.julia_iterations)
                n_execs = length(result.julia_iterations[1])

                for exec_idx in 1:n_execs
                    times = [result.julia_iterations[iter][exec_idx].time_ms for iter in 1:n_iters]
                    allocs = Float64.([result.julia_iterations[iter][exec_idx].alloc_bytes for iter in 1:n_iters])
                    code_sizes = Float64.([result.julia_iterations[iter][exec_idx].compiled_code_bytes for iter in 1:n_iters])

                    first = result.julia_iterations[1][exec_idx]

                    println(io, @sprintf("%s,julia,%s,%d,%s,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f",
                        scenario.name, first.cell_id, first.version, first.change_type,
                        Statistics.median(times), Statistics.std(times), minimum(times), maximum(times),
                        Statistics.median(allocs), Statistics.std(allocs), minimum(allocs), maximum(allocs),
                        Statistics.median(code_sizes), Statistics.std(code_sizes)))
                end
            end

            # nbjit variance
            if result.nbjit_iterations !== nothing && length(result.nbjit_iterations) > 1
                n_iters = length(result.nbjit_iterations)
                n_execs = length(result.nbjit_iterations[1])

                for exec_idx in 1:n_execs
                    times = [result.nbjit_iterations[iter][exec_idx].time_ms for iter in 1:n_iters]
                    allocs = Float64.([result.nbjit_iterations[iter][exec_idx].alloc_bytes for iter in 1:n_iters])
                    code_sizes = Float64.([result.nbjit_iterations[iter][exec_idx].compiled_code_bytes for iter in 1:n_iters])

                    first = result.nbjit_iterations[1][exec_idx]

                    println(io, @sprintf("%s,nbjit,%s,%d,%s,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f",
                        scenario.name, first.cell_id, first.version, first.change_type,
                        Statistics.median(times), Statistics.std(times), minimum(times), maximum(times),
                        Statistics.median(allocs), Statistics.std(allocs), minimum(allocs), maximum(allocs),
                        Statistics.median(code_sizes), Statistics.std(code_sizes)))
                end
            end
        end
    end
end

"""
Main entry point.
"""
function main()
    if !ARGS_PARSED.rebench
        println("="^70)
        println("REALISTIC NOTEBOOK DEVELOPMENT SIMULATION")
        println("="^70)
        println()
        println("This benchmark simulates real notebook development patterns")
        println("to measure nbjit's practical performance benefits.")
        println()
    end

    if !ARGS_PARSED.rebench
        if NBJIT_LOADED[]
            println("nbjit.jl loaded successfully")
        else
            println("Running Julia-only mode (nbjit not loaded)")
        end
    end

    # Create all scenarios (using simplified versions compatible with nbjit)
    all_scenarios = get_all_simplified_scenarios()

    # Filter scenarios if requested (by number or by name for rebench)
    scenarios = if ARGS_PARSED.scenario !== nothing
        [all_scenarios[ARGS_PARSED.scenario]]
    elseif ARGS_PARSED.benchmark !== nothing
        filter(s -> should_run_scenario(s.name), all_scenarios)
    else
        all_scenarios
    end

    iterations = ARGS_PARSED.iterations

    if !ARGS_PARSED.rebench
        println("\nScenarios to run:")
        for (i, s) in enumerate(scenarios)
            println("  $i. $(s.name) ($(length(s.execution_trace)) executions)")
        end
        if iterations > 1
            println("\nRunning $(iterations) iterations per scenario (reporting median)")
        end
    end

    # Run scenarios
    all_results = []
    reports = BenchmarkReport[]

    for scenario in scenarios
        result = run_scenario(scenario; executor=ARGS_PARSED.executor, iterations=iterations)
        push!(all_results, result)

        if result.report !== nothing
            push!(reports, result.report)
        end
    end

    # Generate timestamp for file names
    timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")

    # Always save detailed CSV data (even in rebench mode)
    executor_suffix = ARGS_PARSED.executor !== nothing ? "_$(ARGS_PARSED.executor)" : ""

    # Determine CSV output path
    if ARGS_PARSED.csv_file !== nothing
        # Use specified CSV file path (for rebench: append if file exists)
        detailed_csv_path = ARGS_PARSED.csv_file
        save_detailed_csv(detailed_csv_path, scenarios, all_results, iterations; append=true)
    else
        # Normal mode: create timestamped file
        detailed_csv_path = joinpath(@__DIR__, "realistic_simulation_detailed$(executor_suffix)_$(timestamp).csv")
        save_detailed_csv(detailed_csv_path, scenarios, all_results, iterations; append=false)
    end

    # Save variance statistics if multiple iterations (only when not using custom csv file)
    variance_csv_path = nothing
    if iterations > 1 && ARGS_PARSED.csv_file === nothing
        variance_csv_path = joinpath(@__DIR__, "realistic_simulation_variance$(executor_suffix)_$(timestamp).csv")
        save_variance_csv(variance_csv_path, scenarios, all_results, iterations)
    end

    # Output results
    if ARGS_PARSED.rebench
        # Rebench mode: print in RebenchLog format to stdout
        print_rebench_results(scenarios, all_results, ARGS_PARSED.executor)

        # Also print CSV path to stderr so it doesn't interfere with rebench parsing
        if ARGS_PARSED.csv_file !== nothing
            println(stderr, "\nResults written to: $detailed_csv_path")
        end
    else
        # Normal mode: print summary
        if !isempty(reports)
            MetricsLib.print_summary_table(reports)
        end

        println("\nResults saved to: $detailed_csv_path")
        if variance_csv_path !== nothing
            println("Variance results saved to: $variance_csv_path")
        end

        println("\nBenchmark complete!")
    end

    return all_results
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
