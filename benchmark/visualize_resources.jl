"""
Generate resource usage visualizations from benchmark data.

This script creates publication-quality plots for:
- Peak RSS memory comparison
- GC statistics (time and pause counts)
- Disk footprint (compiled .so sizes)
- Comprehensive resource overview

Usage:
    julia visualize_resources.jl [path/to/results.csv]

If no path is provided, defaults to benchmark/results.csv
"""

# Load the visualization functions from visualize_simulation.jl
include("visualize_simulation.jl")

"""
Parse results.csv and aggregate resource metrics by scenario.
Returns a dictionary with scenario-level aggregated metrics.
"""
function parse_results_csv(filepath::String)
    !isfile(filepath) && error("Results file not found: $filepath")

    # Data structures to aggregate results
    scenarios = Set{String}()
    data = Dict{String, Dict{String, Any}}()

    lines = readlines(filepath)
    isempty(lines) && error("Empty results file")

    # Parse header
    header = split(lines[1], ',')
    col_idx = Dict(String(strip(col)) => i for (i, col) in enumerate(header))

    # Parse data rows
    for line in lines[2:end]
        isempty(strip(line)) && continue

        parts = split(line, ',')
        length(parts) < length(header) && continue

        scenario = String(strip(parts[col_idx["scenario"]]))
        executor = String(strip(parts[col_idx["executor"]]))
        version = parse(Int, parts[col_idx["version"]])

        # Parse metrics
        rss_after = parse(Float64, parts[col_idx["rss_after"]])
        gc_time_ns = parse(Float64, parts[col_idx["gc_time_ns"]])
        gc_pause_count = parse(Int, parts[col_idx["gc_pause_count"]])
        compiled_code_bytes = parse(Float64, parts[col_idx["compiled_code_bytes"]])

        # Initialize scenario data structure
        push!(scenarios, scenario)
        if !haskey(data, scenario)
            data[scenario] = Dict(
                "julia_peak_rss" => 0.0,
                "nbjit_peak_rss" => 0.0,
                "julia_gc_time_ms" => 0.0,
                "nbjit_gc_time_ms" => 0.0,
                "julia_gc_pauses" => 0,
                "nbjit_gc_pauses" => 0,
                "nbjit_code_bytes" => 0.0,
                "max_version" => 0
            )
        end

        # Update aggregated metrics
        is_julia = executor == "julia"

        # Peak RSS (convert bytes to MB)
        rss_mb = rss_after / (1024 * 1024)
        if is_julia
            data[scenario]["julia_peak_rss"] = max(data[scenario]["julia_peak_rss"], rss_mb)
        else
            data[scenario]["nbjit_peak_rss"] = max(data[scenario]["nbjit_peak_rss"], rss_mb)
        end

        # GC time (convert nanoseconds to milliseconds)
        gc_time_ms = gc_time_ns / 1_000_000
        if is_julia
            data[scenario]["julia_gc_time_ms"] += gc_time_ms
        else
            data[scenario]["nbjit_gc_time_ms"] += gc_time_ms
        end

        # GC pause count
        if is_julia
            data[scenario]["julia_gc_pauses"] += gc_pause_count
        else
            data[scenario]["nbjit_gc_pauses"] += gc_pause_count
        end

        # Compiled code size (nbjit only)
        if !is_julia
            data[scenario]["nbjit_code_bytes"] += compiled_code_bytes
        end

        # Track max version for iteration count
        data[scenario]["max_version"] = max(data[scenario]["max_version"], version)
    end

    # Convert to sorted arrays
    scenario_list = sort(collect(scenarios))

    julia_rss = [data[s]["julia_peak_rss"] for s in scenario_list]
    nbjit_rss = [data[s]["nbjit_peak_rss"] for s in scenario_list]

    julia_gc_time = [data[s]["julia_gc_time_ms"] for s in scenario_list]
    nbjit_gc_time = [data[s]["nbjit_gc_time_ms"] for s in scenario_list]

    julia_pauses = [data[s]["julia_gc_pauses"] for s in scenario_list]
    nbjit_pauses = [data[s]["nbjit_gc_pauses"] for s in scenario_list]

    disk_total_kb = [data[s]["nbjit_code_bytes"] / 1024 for s in scenario_list]
    iterations = [data[s]["max_version"] for s in scenario_list]
    disk_avg_kb = [total / max(iter, 1) for (total, iter) in zip(disk_total_kb, iterations)]

    return (
        scenarios = scenario_list,
        julia_rss = julia_rss,
        nbjit_rss = nbjit_rss,
        julia_gc_time = julia_gc_time,
        nbjit_gc_time = nbjit_gc_time,
        julia_pauses = julia_pauses,
        nbjit_pauses = nbjit_pauses,
        disk_total_kb = disk_total_kb,
        disk_avg_kb = disk_avg_kb,
        iterations = iterations
    )
end

"""
Generate all resource plots using data from results.csv.
"""
function main()
    println("Generating resource usage visualizations from results.csv...")
    println()

    # Determine input file path
    csv_path = if length(ARGS) > 0
        ARGS[1]
    else
        joinpath(@__DIR__, "results.csv")
    end

    println("Reading data from: $csv_path")

    # Parse CSV data
    metrics = parse_results_csv(csv_path)

    println("Found $(length(metrics.scenarios)) scenarios:")
    for scenario in metrics.scenarios
        println("  - $scenario")
    end
    println()

    # Output directory
    output_dir = joinpath(@__DIR__, "plots")
    mkpath(output_dir)

    # Generate individual plots
    plot_memory_comparison(metrics.scenarios, metrics.julia_rss, metrics.nbjit_rss;
        output_path=joinpath(output_dir, "resource_memory_comparison.pdf"))

    plot_gc_statistics(metrics.scenarios,
                      metrics.julia_gc_time, metrics.nbjit_gc_time,
                      metrics.julia_pauses, metrics.nbjit_pauses;
        output_path=joinpath(output_dir, "resource_gc_statistics.pdf"))

    plot_disk_footprint(metrics.scenarios,
                       metrics.disk_total_kb, metrics.disk_avg_kb, metrics.iterations;
        output_path=joinpath(output_dir, "resource_disk_footprint.pdf"))

    plot_resource_overview(metrics.scenarios,
                          metrics.julia_rss, metrics.nbjit_rss,
                          metrics.julia_gc_time, metrics.nbjit_gc_time,
                          metrics.disk_total_kb ./ 1024;  # Convert to MB
        output_path=joinpath(output_dir, "resource_overview.pdf"))

    create_data_summary_page(metrics.scenarios,
                            metrics.julia_rss, metrics.nbjit_rss,
                            metrics.julia_gc_time, metrics.nbjit_gc_time,
                            metrics.julia_pauses, metrics.nbjit_pauses,
                            metrics.disk_total_kb, metrics.iterations;
        output_path=joinpath(output_dir, "resource_data_summary.pdf"))

    println()
    println("✓ All resource visualizations generated successfully!")
    println("  Output directory: $output_dir")
    println()
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
