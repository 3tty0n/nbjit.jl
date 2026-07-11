"""
Unified visualization script for benchmark simulation results.

Supports two types of simulations:
1. notebook-simulation - Parameter sweeps, structure evolution, mixed workflows
2. realistic-simulation - Realistic notebook development patterns

Data sources:
- TSV format (benchmark.data from rebench)
- CSV format (legacy notebook_simulation_results.csv)

Usage:
    # Standard usage
    julia visualize_simulation.jl                                    # Auto-detect and run both
    julia visualize_simulation.jl --suite=notebook                   # Notebook simulation only
    julia visualize_simulation.jl --suite=realistic                  # Realistic simulation only
    julia visualize_simulation.jl path/to/data.tsv                   # Use specific file
    julia visualize_simulation.jl path/to/data.tsv --suite=notebook  # Specific file + suite

    # Rebench integration
    julia visualize_simulation.jl notebook                           # Called from rebench
    julia visualize_simulation.jl realistic                          # Called from rebench
    julia visualize_simulation.jl resources                          # Generate resource plots

    # Run via rebench
    rebench rebench.conf visualize                                   # Run all visualizations
"""

using Plots
using Statistics
using Printf

gr()

# =============================================================================
# Publication-Quality Color Schemes
# =============================================================================

"""
Colorblind-friendly palette based on Paul Tol's scheme.
Designed for scientific publications.
"""
const COLOR_PALETTE = (
    blue = "#4477AA",      # Primary blue
    red = "#EE6677",       # Primary red/coral
    green = "#228833",     # Primary green
    yellow = "#CCBB44",    # Primary yellow
    cyan = "#66CCEE",      # Secondary cyan
    purple = "#AA3377",    # Secondary purple
    grey = "#BBBBBB",      # Neutral grey

    # For Julia vs nbjit comparison
    julia_color = "#4477AA",      # Trustworthy blue
    nbjit_color = "#EE6677",      # Warm red/coral
    breakeven_color = "#228833",  # Success green

    # For multi-scenario plots
    scenario_colors = ["#EE6677", "#4477AA", "#228833", "#CCBB44", "#AA3377", "#66CCEE"]
)

# =============================================================================
# Data Structures
# =============================================================================

"""
Benchmark result for a single scenario.
"""
struct BenchmarkResult
    name::String
    julia_times::Vector{Float64}
    julia_stds::Vector{Float64}
    nbjit_times::Vector{Float64}
    nbjit_stds::Vector{Float64}
    julia_vars::Vector{Float64}  # Variance per iteration
    nbjit_vars::Vector{Float64}  # Variance per iteration
    julia_n_runs::Vector{Int}    # Number of runs per iteration
    nbjit_n_runs::Vector{Int}    # Number of runs per iteration
end

# =============================================================================
# Data Loading
# =============================================================================

"""
Parse TSV benchmark results file (benchmark.data format from rebench).

Columns: invocation, iteration, value, unit, criterion, benchmark, executor, suite, ...

Args:
    filepath: Path to TSV file
    suite_filter: Filter by suite name (e.g., "notebook-simulation", "realistic-simulation")
                  Pass `nothing` to load all suites.
"""
function load_tsv_data(filepath; suite_filter=nothing)
    raw_data = Dict{String, Dict{String, Dict{Int, Vector{Float64}}}}()

    lines = readlines(filepath)
    isempty(lines) && error("Empty data file: $filepath")

    # Skip shebang and comment lines, find header
    header_idx = 1
    for (i, line) in enumerate(lines)
        if !startswith(line, "#") && !isempty(strip(line))
            header_idx = i
            break
        end
    end

    # Parse header to get column indices
    header = split(lines[header_idx], '\t')
    col_idx = Dict(String(col) => i for (i, col) in enumerate(header))

    required_cols = ["benchmark", "executor", "iteration", "value"]
    for col in required_cols
        haskey(col_idx, col) || error("Missing required column: $col")
    end

    has_suite = haskey(col_idx, "suite")

    # Parse data rows
    for line in lines[header_idx+1:end]
        startswith(line, "#") && continue
        isempty(strip(line)) && continue

        parts = split(line, '\t')
        length(parts) < length(header) && continue

        # Filter by suite if specified
        if has_suite && suite_filter !== nothing
            suite = String(parts[col_idx["suite"]])
            suite != suite_filter && continue
        end

        benchmark = String(parts[col_idx["benchmark"]])
        executor = String(parts[col_idx["executor"]])
        iteration = parse(Int, parts[col_idx["iteration"]])
        value = parse(Float64, parts[col_idx["value"]])

        # Initialize nested dicts
        if !haskey(raw_data, benchmark)
            raw_data[benchmark] = Dict{String, Dict{Int, Vector{Float64}}}()
        end
        if !haskey(raw_data[benchmark], executor)
            raw_data[benchmark][executor] = Dict{Int, Vector{Float64}}()
        end
        if !haskey(raw_data[benchmark][executor], iteration)
            raw_data[benchmark][executor][iteration] = Float64[]
        end

        push!(raw_data[benchmark][executor][iteration], value)
    end

    # Aggregate: compute mean and std for each benchmark/executor/iteration
    aggregate_raw_data(raw_data)
end

"""
Load CSV data (legacy format for notebook simulation).

Expected columns: scenario, iteration, julia_time, julia_std, nbjit_time, nbjit_std
"""
function load_csv_data(filepath)
    data = Dict{String, NamedTuple{(:julia_times, :julia_stds, :nbjit_times, :nbjit_stds),
                                    Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}, Vector{Float64}}}}()

    for line in readlines(filepath)
        startswith(line, "scenario") && continue
        isempty(strip(line)) && continue

        parts = split(line, ',')
        length(parts) < 6 && continue

        scenario = String(parts[1])
        iteration = parse(Int, parts[2])
        julia_time = parse(Float64, parts[3])
        julia_std = parse(Float64, parts[4])
        nbjit_time = parse(Float64, parts[5])
        nbjit_std = parse(Float64, parts[6])

        if !haskey(data, scenario)
            data[scenario] = (julia_times=Float64[], julia_stds=Float64[],
                              nbjit_times=Float64[], nbjit_stds=Float64[])
        end

        while length(data[scenario].julia_times) < iteration
            push!(data[scenario].julia_times, 0.0)
            push!(data[scenario].julia_stds, 0.0)
            push!(data[scenario].nbjit_times, 0.0)
            push!(data[scenario].nbjit_stds, 0.0)
        end

        data[scenario].julia_times[iteration] = julia_time
        data[scenario].julia_stds[iteration] = julia_std
        data[scenario].nbjit_times[iteration] = nbjit_time
        data[scenario].nbjit_stds[iteration] = nbjit_std
    end

    data
end

"""
Load detailed CSV data from benchmark_realistic_simulation.jl output.

Expected columns: scenario,executor,iteration,cell_id,version,change_type,time_ms,...
Groups by scenario and executor, collects all times per version for median/variance.
"""
function load_detailed_csv_data(filepath)
    # Raw data: scenario -> executor -> version -> Vector of times
    raw_data = Dict{String, Dict{String, Dict{Int, Vector{Float64}}}}()

    for line in readlines(filepath)
        startswith(line, "scenario") && continue
        isempty(strip(line)) && continue

        parts = split(line, ',')
        length(parts) < 7 && continue

        scenario = String(parts[1])
        executor = String(parts[2])
        # iteration = parse(Int, parts[3])  # invocation number
        # cell_id = String(parts[4])
        version = parse(Int, parts[5])
        # change_type = String(parts[6])
        time_ms = parse(Float64, parts[7])

        # Initialize nested dicts
        if !haskey(raw_data, scenario)
            raw_data[scenario] = Dict{String, Dict{Int, Vector{Float64}}}()
        end
        if !haskey(raw_data[scenario], executor)
            raw_data[scenario][executor] = Dict{Int, Vector{Float64}}()
        end
        if !haskey(raw_data[scenario][executor], version)
            raw_data[scenario][executor][version] = Float64[]
        end

        # Collect all times for this version
        push!(raw_data[scenario][executor][version], time_ms)
    end

    # Convert to the standard format using median and variance/stddev
    data = Dict{String, NamedTuple{(:julia_times, :julia_stds, :nbjit_times, :nbjit_stds,
                                     :julia_vars, :nbjit_vars, :julia_n_runs, :nbjit_n_runs),
                                    Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}, Vector{Float64},
                                          Vector{Float64}, Vector{Float64}, Vector{Int}, Vector{Int}}}}()

    for (scenario, executors) in raw_data
        # Find max version across both executors
        max_version = 0
        for (executor, versions) in executors
            for v in keys(versions)
                max_version = max(max_version, v)
            end
        end

        julia_times = zeros(max_version)
        julia_stds = zeros(max_version)
        julia_vars = zeros(max_version)
        julia_n_runs = zeros(Int, max_version)
        nbjit_times = zeros(max_version)
        nbjit_stds = zeros(max_version)
        nbjit_vars = zeros(max_version)
        nbjit_n_runs = zeros(Int, max_version)

        for (executor, versions) in executors
            is_nbjit = executor == "nbjit"

            for (version, times) in versions
                n = length(times)

                # Use median for central tendency
                med = median(times)

                # Compute sample variance (corrected, ddof=1) and standard deviation
                if n > 1
                    variance = var(times)  # Julia's var() uses corrected sample variance by default
                    stddev = sqrt(variance)
                else
                    variance = 0.0
                    stddev = 0.0
                end

                if is_nbjit
                    nbjit_times[version] = med
                    nbjit_stds[version] = stddev
                    nbjit_vars[version] = variance
                    nbjit_n_runs[version] = n
                else
                    julia_times[version] = med
                    julia_stds[version] = stddev
                    julia_vars[version] = variance
                    julia_n_runs[version] = n
                end
            end
        end

        data[scenario] = (julia_times=julia_times, julia_stds=julia_stds,
                          nbjit_times=nbjit_times, nbjit_stds=nbjit_stds,
                          julia_vars=julia_vars, nbjit_vars=nbjit_vars,
                          julia_n_runs=julia_n_runs, nbjit_n_runs=nbjit_n_runs)
    end

    data
end

"""
Detect CSV format: legacy (6 columns) or detailed (17+ columns).
"""
function detect_csv_format(filepath)
    first_data_line = nothing
    for line in readlines(filepath)
        startswith(line, "scenario") && continue
        isempty(strip(line)) && continue
        first_data_line = line
        break
    end

    first_data_line === nothing && return :unknown

    parts = split(first_data_line, ',')
    if length(parts) >= 7 && occursin("julia", parts[2]) || occursin("nbjit", parts[2])
        return :detailed
    else
        return :legacy
    end
end

"""
Aggregate raw data from TSV parsing into median/variance/std format.
"""
function aggregate_raw_data(raw_data)
    data = Dict{String, NamedTuple{(:julia_times, :julia_stds, :nbjit_times, :nbjit_stds,
                                     :julia_vars, :nbjit_vars, :julia_n_runs, :nbjit_n_runs),
                                    Tuple{Vector{Float64}, Vector{Float64}, Vector{Float64}, Vector{Float64},
                                          Vector{Float64}, Vector{Float64}, Vector{Int}, Vector{Int}}}}()

    for (benchmark, executors) in raw_data
        max_iter = 0
        for (executor, iterations) in executors
            for iter in keys(iterations)
                max_iter = max(max_iter, iter)
            end
        end

        julia_times = zeros(max_iter)
        julia_stds = zeros(max_iter)
        julia_vars = zeros(max_iter)
        julia_n_runs = zeros(Int, max_iter)
        nbjit_times = zeros(max_iter)
        nbjit_stds = zeros(max_iter)
        nbjit_vars = zeros(max_iter)
        nbjit_n_runs = zeros(Int, max_iter)

        for (executor, iterations) in executors
            is_nbjit = occursin("nbjit", lowercase(executor))

            for (iter, values) in iterations
                n = length(values)
                med_val = median(values)

                if n > 1
                    variance = var(values)
                    std_val = sqrt(variance)
                else
                    variance = 0.0
                    std_val = 0.0
                end

                if is_nbjit
                    nbjit_times[iter] = med_val
                    nbjit_stds[iter] = std_val
                    nbjit_vars[iter] = variance
                    nbjit_n_runs[iter] = n
                else
                    julia_times[iter] = med_val
                    julia_stds[iter] = std_val
                    julia_vars[iter] = variance
                    julia_n_runs[iter] = n
                end
            end
        end

        data[benchmark] = (julia_times=julia_times, julia_stds=julia_stds,
                           nbjit_times=nbjit_times, nbjit_stds=nbjit_stds,
                           julia_vars=julia_vars, nbjit_vars=nbjit_vars,
                           julia_n_runs=julia_n_runs, nbjit_n_runs=nbjit_n_runs)
    end

    data
end

"""
Convert loaded data to BenchmarkResult vector for plotting.
"""
function process_results(data)::Vector{BenchmarkResult}
    results = BenchmarkResult[]
    benchmarks = sort(collect(keys(data)))

    for benchmark in benchmarks
        d = data[benchmark]
        (isempty(d.julia_times) && isempty(d.nbjit_times)) && continue

        # Handle both old format (without vars/n_runs) and new format
        julia_vars = haskey(d, :julia_vars) ? d.julia_vars : zeros(length(d.julia_times))
        nbjit_vars = haskey(d, :nbjit_vars) ? d.nbjit_vars : zeros(length(d.nbjit_times))
        julia_n_runs = haskey(d, :julia_n_runs) ? d.julia_n_runs : ones(Int, length(d.julia_times))
        nbjit_n_runs = haskey(d, :nbjit_n_runs) ? d.nbjit_n_runs : ones(Int, length(d.nbjit_times))

        push!(results, BenchmarkResult(
            benchmark,
            d.julia_times,
            d.julia_stds,
            d.nbjit_times,
            d.nbjit_stds,
            julia_vars,
            nbjit_vars,
            julia_n_runs,
            nbjit_n_runs
        ))
    end

    results
end

# =============================================================================
# Analysis Functions
# =============================================================================

"""
Find break-even point where cumulative nbjit time becomes lower than Julia.

Returns (iteration, time) tuple or nothing if no break-even found.
"""
function find_break_even(julia_cumsum::Vector{Float64}, nbjit_cumsum::Vector{Float64})
    n = length(julia_cumsum)
    n == 0 && return nothing

    diff = nbjit_cumsum .- julia_cumsum

    # Already faster at iteration 1
    if diff[1] <= 0
        return (1.0, julia_cumsum[1])
    end

    # Find crossing point
    for i in 1:(n-1)
        if diff[i] > 0 && diff[i+1] <= 0
            t = diff[i] / (diff[i] - diff[i+1])
            break_iter = i + t
            break_time = julia_cumsum[i] + t * (julia_cumsum[i+1] - julia_cumsum[i])
            return (break_iter, break_time)
        end
    end

    nothing
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

# =============================================================================
# Plotting Functions
# =============================================================================

"""
Plot cumulative time comparison for all scenarios.

Shows Julia vs nbjit cumulative time with break-even points.
Uses median times with optional ±1 std (standard deviation) ribbons.
Paper-quality version with high DPI and improved styling.
"""
function plot_cumulative_time(results::Vector{BenchmarkResult};
                               output_path=nothing, title_prefix="", show_ribbons=true)
    n_scenarios = length(results)
    n_scenarios == 0 && return nothing

    # Determine layout
    if n_scenarios <= 4
        n_cols = 2
        n_rows = ceil(Int, n_scenarios / n_cols)
    elseif n_scenarios == 5
        n_cols = 3
        n_rows = 2
    else
        n_cols = ceil(Int, sqrt(n_scenarios))
        n_rows = ceil(Int, n_scenarios / n_cols)
    end

    p = plot(
        size=(500 * n_cols, 380 * n_rows + 80),
        dpi=300,
        layout=@layout([grid(n_rows, n_cols); a{0.08h}]),
        left_margin=10Plots.mm,
        right_margin=8Plots.mm,
        top_margin=8Plots.mm,
        bottom_margin=10Plots.mm,
        titlefontsize=13,
        titlefontfamily="Computer Modern",
        guidefontsize=11,
        guidefontfamily="Computer Modern",
        tickfontsize=9,
        tickfontfamily="Computer Modern",
        legendfontsize=9,
        framestyle=:box,
        grid=:y,
        gridalpha=0.25,
        gridlinewidth=0.5,
        minorgrid=true,
        minorgridalpha=0.1,
        background_color_inside=:white
    )

    for (idx, r) in enumerate(results)
        n = length(r.julia_times)

        # Convert to seconds for readability
        julia_cumsum = cumsum(r.julia_times) ./ 1000
        nbjit_cumsum = cumsum(r.nbjit_times) ./ 1000
        break_even = find_break_even(cumsum(r.julia_times), cumsum(r.nbjit_times))

        # Propagated standard deviation for cumulative sum (in seconds)
        # For cumulative metrics: sqrt(sum of variances) for independent measurements
        julia_cum_std = sqrt.(cumsum(r.julia_stds .^ 2)) ./ 1000
        nbjit_cum_std = sqrt.(cumsum(r.nbjit_stds .^ 2)) ./ 1000

        # Check if we have variance data
        has_variance = any(r.julia_stds .> 0) || any(r.nbjit_stds .> 0)

        # Plot Julia (dashed line + markers) with optional ±1 std ribbon
        if show_ribbons && has_variance && any(julia_cum_std .> 0)
            plot!(p[idx], 1:n, julia_cumsum,
                  ribbon=julia_cum_std, fillalpha=0.2, fillcolor=COLOR_PALETTE.julia_color,
                  label="", linestyle=:dash,
                  color=COLOR_PALETTE.julia_color, linewidth=2.5, alpha=0.9,
                  marker=:circle, markersize=5, markercolor=COLOR_PALETTE.julia_color,
                  markerstrokewidth=0.5, markerstrokecolor=:white, markeralpha=0.9,
                  subplot=idx)
        else
            plot!(p[idx], 1:n, julia_cumsum,
                  label="", linestyle=:dash,
                  color=COLOR_PALETTE.julia_color, linewidth=2.5, alpha=0.9,
                  marker=:circle, markersize=5, markercolor=COLOR_PALETTE.julia_color,
                  markerstrokewidth=0.5, markerstrokecolor=:white, markeralpha=0.9,
                  subplot=idx)
        end

        # Plot nbjit (solid line + markers) with optional ±1 std ribbon
        if show_ribbons && has_variance && any(nbjit_cum_std .> 0)
            plot!(p[idx], 1:n, nbjit_cumsum,
                  ribbon=nbjit_cum_std, fillalpha=0.2, fillcolor=COLOR_PALETTE.nbjit_color,
                  label="",
                  color=COLOR_PALETTE.nbjit_color, linewidth=3, alpha=0.95,
                  marker=:circle, markersize=5, markercolor=COLOR_PALETTE.nbjit_color,
                  markerstrokewidth=0.5, markerstrokecolor=:white, markeralpha=0.95,
                  subplot=idx)
        else
            plot!(p[idx], 1:n, nbjit_cumsum,
                  label="",
                  color=COLOR_PALETTE.nbjit_color, linewidth=3, alpha=0.95,
                  marker=:circle, markersize=5, markercolor=COLOR_PALETTE.nbjit_color,
                  markerstrokewidth=0.5, markerstrokecolor=:white, markeralpha=0.95,
                  subplot=idx)
        end

        # Mark break-even point with annotation
        if break_even !== nothing
            break_iter, break_time_ms = break_even
            break_time_s = break_time_ms / 1000
            scatter!(p[idx], [break_iter], [break_time_s],
                    label="", marker=:diamond, markersize=9,
                    color=COLOR_PALETTE.breakeven_color,
                    markerstrokewidth=1, markerstrokecolor=:black, markeralpha=0.9,
                    subplot=idx)
            vline!(p[idx], [break_iter], label="", linestyle=:dot,
                  color=COLOR_PALETTE.breakeven_color, linewidth=1.5, alpha=0.4, subplot=idx)

            # Add annotation for break-even iteration
            max_y = maximum(max.(julia_cumsum, nbjit_cumsum))
            annotate!(p[idx], [(break_iter + 0.5, break_time_s + max_y * 0.06,
                               text(@sprintf("n=%d", round(Int, break_iter)), 9, :left,
                                    COLOR_PALETTE.breakeven_color, "Computer Modern", :bold))])
        end

        # Calculate and show final speedup with detailed stats
        final_speedup = julia_cumsum[end] / max(nbjit_cumsum[end], 0.001)
        max_y = maximum(max.(julia_cumsum, nbjit_cumsum))

        # Main speedup annotation
        speedup_text = @sprintf("%.1f×", final_speedup)
        annotate!(p[idx], [(n * 0.95, max_y * 0.12,
                           text(speedup_text, 11, :right, :black, "Computer Modern", :bold))])

        stats_text = @sprintf("Data: Julia=%.1fs nbjit=%.1fs Speedup=%.2fx",
                             julia_cumsum[end], nbjit_cumsum[end], final_speedup)
        annotate!(p[idx], [(n * 0.02, max_y * 0.02,
                           text(stats_text, 6, :left, :gray, "Computer Modern"))])

        title!(p[idx], r.name)
        xlabel!(p[idx], "Iteration")
        ylabel!(p[idx], "Cumulative Time (s)")
    end

    # Hide empty grid subplots (when n_scenarios < n_rows * n_cols)
    for idx in (n_scenarios + 1):(n_rows * n_cols)
        plot!(p[idx], framestyle=:none, axis=false, grid=false, subplot=idx)
    end

    # Shared legend (placed after all grid cells)
    legend_idx = n_rows * n_cols + 1
    plot!(p[legend_idx], [], [], label="Julia (median)",
          color=COLOR_PALETTE.julia_color, linewidth=2.5, linestyle=:dash,
          marker=:circle, markersize=5, markercolor=COLOR_PALETTE.julia_color,
          markerstrokewidth=0.5, markerstrokecolor=:white,
          framestyle=:none, legend=:top, legendcolumns=3,
          foreground_color_legend=nothing, background_color_legend=nothing,
          legendfontsize=10, legendfontfamily="Computer Modern")
    plot!(p[legend_idx], [], [], label="nbjit (median)",
          color=COLOR_PALETTE.nbjit_color, linewidth=3,
          marker=:circle, markersize=5, markercolor=COLOR_PALETTE.nbjit_color,
          markerstrokewidth=0.5, markerstrokecolor=:white)
    scatter!(p[legend_idx], [], [], label="Break-even",
            color=COLOR_PALETTE.breakeven_color, marker=:diamond, markersize=8,
            markerstrokewidth=1, markerstrokecolor=:black)

    if output_path !== nothing
        mkpath(dirname(output_path))
        savefig(p, output_path)
        println("Saved: $output_path")
    end

    p
end

"""
Plot a single combined cumulative time figure for all scenarios overlaid.
Uses median times with optional variance ribbons.
"""
function plot_cumulative_time_combined(results::Vector{BenchmarkResult};
                                        output_path=nothing, show_julia=true, show_ribbons=true)
    n_scenarios = length(results)
    n_scenarios == 0 && return nothing

    p = plot(
        size=(1100, 650),
        dpi=300,
        left_margin=10Plots.mm,
        right_margin=10Plots.mm,
        bottom_margin=10Plots.mm,
        top_margin=10Plots.mm,
        titlefontsize=16,
        titlefontfamily="Computer Modern",
        guidefontsize=13,
        guidefontfamily="Computer Modern",
        tickfontsize=11,
        tickfontfamily="Computer Modern",
        legendfontsize=10,
        legendfontfamily="Computer Modern",
        legend=:topleft,
        framestyle=:box,
        grid=:y,
        gridalpha=0.25,
        gridlinewidth=0.5,
        minorgrid=true,
        minorgridalpha=0.1,
        background_color_inside=:white
    )

    # Use the colorblind-friendly palette
    colors = COLOR_PALETTE.scenario_colors

    for (idx, r) in enumerate(results)
        n = length(r.julia_times)
        color = colors[mod1(idx, length(colors))]

        julia_cumsum = cumsum(r.julia_times) ./ 1000  # Convert to seconds
        nbjit_cumsum = cumsum(r.nbjit_times) ./ 1000

        # Propagated variance for cumulative sum
        julia_cum_var = sqrt.(cumsum(r.julia_stds .^ 2)) ./ 1000
        nbjit_cum_var = sqrt.(cumsum(r.nbjit_stds .^ 2)) ./ 1000
        has_variance = any(r.nbjit_stds .> 0)

        # Plot Julia (optional, dashed, lighter)
        if show_julia && idx == 1
            if show_ribbons && has_variance && any(julia_cum_var .> 0)
                plot!(p, 1:n, julia_cumsum,
                      ribbon=julia_cum_var, fillalpha=0.15, fillcolor=COLOR_PALETTE.julia_color,
                      label="Julia (median)",
                      linestyle=:dash, linewidth=2.5, alpha=0.7,
                      color=COLOR_PALETTE.julia_color,
                      marker=:circle, markersize=4, markercolor=COLOR_PALETTE.julia_color,
                      markerstrokewidth=0.5, markerstrokecolor=:white, markeralpha=0.7)
            else
                plot!(p, 1:n, julia_cumsum,
                      label="Julia (median)",
                      linestyle=:dash, linewidth=2.5, alpha=0.7,
                      color=COLOR_PALETTE.julia_color,
                      marker=:circle, markersize=4, markercolor=COLOR_PALETTE.julia_color,
                      markerstrokewidth=0.5, markerstrokecolor=:white, markeralpha=0.7)
            end
        end

        # Plot nbjit (solid, prominent) with optional variance ribbon
        if show_ribbons && has_variance && any(nbjit_cum_var .> 0)
            plot!(p, 1:n, nbjit_cumsum,
                  ribbon=nbjit_cum_var, fillalpha=0.2, fillcolor=color,
                  label=r.name,
                  linewidth=3, alpha=0.95,
                  color=color,
                  marker=:circle, markersize=5, markercolor=color,
                  markerstrokewidth=0.5, markerstrokecolor=:white, markeralpha=0.95)
        else
            plot!(p, 1:n, nbjit_cumsum,
                  label=r.name,
                  linewidth=3, alpha=0.95,
                  color=color,
                  marker=:circle, markersize=5, markercolor=color,
                  markerstrokewidth=0.5, markerstrokecolor=:white, markeralpha=0.95)
        end

        # Mark break-even point
        break_even = find_break_even(cumsum(r.julia_times), cumsum(r.nbjit_times))
        if break_even !== nothing
            break_iter, break_time_ms = break_even
            scatter!(p, [break_iter], [break_time_ms / 1000],
                    label="", marker=:diamond, markersize=8, color=color,
                    markerstrokecolor=:black, markerstrokewidth=1, markeralpha=0.9)
        end
    end

    title!(p, "Cumulative Execution Time (Median)")
    xlabel!(p, "Iteration")
    ylabel!(p, "Cumulative Time (s)")

    if output_path !== nothing
        mkpath(dirname(output_path))
        savefig(p, output_path)
        println("Saved: $output_path")
    end

    p
end

# =============================================================================
# Resource Metrics Visualization
# =============================================================================

"""
Plot peak RSS memory comparison between Julia and nbjit.
Shows memory usage in MB with ratio annotations.
"""
function plot_memory_comparison(scenarios::Vector{String}, julia_rss::Vector{Float64},
                                nbjit_rss::Vector{Float64}; output_path=nothing)
    n = length(scenarios)
    n == 0 && return nothing

    # Calculate ratios
    ratios = julia_rss ./ max.(nbjit_rss, 0.1)  # Avoid division by zero

    p = plot(
        size=(900, 500),
        dpi=300,
        left_margin=12Plots.mm,
        right_margin=8Plots.mm,
        bottom_margin=18Plots.mm,
        top_margin=8Plots.mm,
        titlefontsize=14,
        titlefontfamily="Computer Modern",
        guidefontsize=12,
        guidefontfamily="Computer Modern",
        tickfontsize=10,
        tickfontfamily="Computer Modern",
        legendfontsize=10,
        legendfontfamily="Computer Modern",
        framestyle=:box,
        grid=:y,
        gridalpha=0.25,
        gridlinewidth=0.5,
        background_color_inside=:white,
        legend=:topright
    )

    x = 1:n
    width = 0.35

    # Julia bars
    bar!(p, x .- width/2, julia_rss,
         bar_width=width,
         color=COLOR_PALETTE.julia_color, alpha=0.85,
         label="Julia",
         linewidth=0)

    # nbjit bars
    bar!(p, x .+ width/2, nbjit_rss,
         bar_width=width,
         color=COLOR_PALETTE.nbjit_color, alpha=0.85,
         label="nbjit",
         linewidth=0)

    # Add ratio annotations above bars
    for i in 1:n
        max_height = max(julia_rss[i], nbjit_rss[i])
        if !isnan(ratios[i]) && !isinf(ratios[i]) && ratios[i] > 0
            annotate!(p, [(i, max_height * 1.1,
                          text(@sprintf("%.1f×", ratios[i]), 9, :center,
                               COLOR_PALETTE.breakeven_color, "Computer Modern"))])
        end
    end

    xticks!(p, 1:n, scenarios, rotation=20, xrotation=20)
    xlabel!(p, "Scenario")
    ylabel!(p, "Peak RSS Memory (MB)")
    title!(p, "Memory Usage Comparison")

    data_text = "RSS_MEMORY_DATA:\n"
    for i in 1:n
        data_text *= @sprintf("%s: Julia=%.1fMB nbjit=%.1fMB Ratio=%.2fx\n",
                             scenarios[i], julia_rss[i], nbjit_rss[i], ratios[i])
    end
    annotate!(p, [(n/2, minimum(min.(julia_rss, nbjit_rss)) * 0.1,
                  text(data_text, 4, :center, RGBA(0,0,0,0.01), "Computer Modern"))])

    # Also embed as visible small text at bottom
    summary_visible = @sprintf("Total: Julia_avg=%.1fMB nbjit_avg=%.1fMB Overall_ratio=%.2fx",
                              mean(julia_rss), mean(nbjit_rss), mean(ratios))
    annotate!(p, [(n/2, maximum(max.(julia_rss, nbjit_rss)) * 0.05,
                  text(summary_visible, 7, :center, :gray, "Computer Modern"))])

    if output_path !== nothing
        mkpath(dirname(output_path))
        savefig(p, output_path)
        println("Saved: $output_path")

        # Export text data file
        txt_path = replace(output_path, ".pdf" => ".txt")
        open(txt_path, "w") do io
            println(io, "="^80)
            println(io, "PEAK RSS MEMORY COMPARISON DATA")
            println(io, "="^80)
            println(io)
            println(io, @sprintf("%-35s %12s %12s %10s", "Scenario", "Julia (MB)", "nbjit (MB)", "Ratio"))
            println(io, "-"^80)
            for i in 1:n
                println(io, @sprintf("%-35s %12.2f %12.2f %10.2fx",
                                    scenarios[i], julia_rss[i], nbjit_rss[i], ratios[i]))
            end
            println(io, "-"^80)
            println(io, @sprintf("%-35s %12.2f %12.2f %10.2fx",
                                "AVERAGE", mean(julia_rss), mean(nbjit_rss), mean(ratios)))
            println(io, @sprintf("%-35s %12.2f %12.2f",
                                "TOTAL", sum(julia_rss), sum(nbjit_rss)))
            println(io)
            println(io, "Memory Reduction: $(round(100 * (1 - mean(nbjit_rss)/mean(julia_rss)), digits=1))%")
        end
        println("Saved: $txt_path")

        # Export CSV
        csv_path = replace(output_path, ".pdf" => ".csv")
        open(csv_path, "w") do io
            println(io, "scenario,julia_rss_mb,nbjit_rss_mb,ratio")
            for i in 1:n
                println(io, "$(scenarios[i]),$(julia_rss[i]),$(nbjit_rss[i]),$(ratios[i])")
            end
        end
        println("Saved: $csv_path")
    end

    p
end

"""
Plot GC statistics comparison (time and pause counts).
"""
function plot_gc_statistics(scenarios::Vector{String},
                           julia_gc_time::Vector{Float64}, nbjit_gc_time::Vector{Float64},
                           julia_pauses::Vector{Int}, nbjit_pauses::Vector{Int};
                           output_path=nothing)
    n = length(scenarios)
    n == 0 && return nothing

    # Create 2-panel plot
    p = plot(
        layout=(2, 1),
        size=(900, 700),
        dpi=300,
        left_margin=12Plots.mm,
        right_margin=8Plots.mm,
        bottom_margin=18Plots.mm,
        top_margin=8Plots.mm,
        titlefontsize=13,
        titlefontfamily="Computer Modern",
        guidefontsize=11,
        guidefontfamily="Computer Modern",
        tickfontsize=9,
        tickfontfamily="Computer Modern",
        legendfontsize=10,
        legendfontfamily="Computer Modern",
        framestyle=:box,
        grid=:y,
        gridalpha=0.25,
        gridlinewidth=0.5,
        background_color_inside=:white
    )

    x = 1:n
    width = 0.35

    # Top panel: GC Time
    bar!(p[1], x .- width/2, julia_gc_time,
         bar_width=width,
         color=COLOR_PALETTE.julia_color, alpha=0.85,
         label="Julia",
         linewidth=0,
         subplot=1)

    bar!(p[1], x .+ width/2, nbjit_gc_time,
         bar_width=width,
         color=COLOR_PALETTE.nbjit_color, alpha=0.85,
         label="nbjit",
         linewidth=0,
         subplot=1)

    xticks!(p[1], 1:n, scenarios, rotation=20, xrotation=20, subplot=1)
    ylabel!(p[1], "GC Time (ms)", subplot=1)
    title!(p[1], "Garbage Collection Time", subplot=1)

    # Bottom panel: GC Pause Counts
    bar!(p[2], x .- width/2, julia_pauses,
         bar_width=width,
         color=COLOR_PALETTE.julia_color, alpha=0.85,
         label="Julia",
         linewidth=0,
         subplot=2)

    bar!(p[2], x .+ width/2, nbjit_pauses,
         bar_width=width,
         color=COLOR_PALETTE.nbjit_color, alpha=0.85,
         label="nbjit",
         linewidth=0,
         subplot=2)

    xticks!(p[2], 1:n, scenarios, rotation=20, xrotation=20, subplot=2)
    xlabel!(p[2], "Scenario", subplot=2)
    ylabel!(p[2], "GC Pause Count", subplot=2)
    title!(p[2], "Garbage Collection Pauses", subplot=2)

    gc_data_text = "GC_STATISTICS_DATA:\n"
    for i in 1:n
        gc_data_text *= @sprintf("%s: Julia_GC=%.1fms Julia_Pauses=%d nbjit_GC=%.1fms nbjit_Pauses=%d\n",
                                scenarios[i], julia_gc_time[i], julia_pauses[i],
                                nbjit_gc_time[i], nbjit_pauses[i])
    end
    annotate!(p[2], [(n/2, maximum(max.(julia_pauses, nbjit_pauses)) * 0.5,
                     text(gc_data_text, 4, :center, RGBA(0,0,0,0.01), "Computer Modern", subplot=2))])

    if output_path !== nothing
        mkpath(dirname(output_path))
        savefig(p, output_path)
        println("Saved: $output_path")
    end

    p
end

"""
Plot disk footprint (compiled .so file sizes).
"""
function plot_disk_footprint(scenarios::Vector{String}, total_kb::Vector{Float64},
                            avg_per_iter::Vector{Float64}, iterations::Vector{Int};
                            output_path=nothing)
    n = length(scenarios)
    n == 0 && return nothing

    p = plot(
        size=(900, 500),
        dpi=300,
        left_margin=12Plots.mm,
        right_margin=12Plots.mm,
        bottom_margin=18Plots.mm,
        top_margin=8Plots.mm,
        titlefontsize=14,
        titlefontfamily="Computer Modern",
        guidefontsize=12,
        guidefontfamily="Computer Modern",
        tickfontsize=10,
        tickfontfamily="Computer Modern",
        legendfontsize=10,
        legendfontfamily="Computer Modern",
        framestyle=:box,
        grid=:y,
        gridalpha=0.25,
        gridlinewidth=0.5,
        background_color_inside=:white
    )

    x = 1:n

    # Bar chart for total size
    bar!(p, x, total_kb ./ 1024,  # Convert to MB
         color=COLOR_PALETTE.nbjit_color, alpha=0.85,
         label="Total Size",
         linewidth=0)

    # Add iteration count annotations
    for i in 1:n
        annotate!(p, [(i, (total_kb[i] / 1024) * 1.05,
                      text(@sprintf("%d iter", iterations[i]), 9, :center,
                           :black, "Computer Modern"))])
    end

    xticks!(p, 1:n, scenarios, rotation=20, xrotation=20)
    xlabel!(p, "Scenario")
    ylabel!(p, "Compiled Code Size (MB)")
    title!(p, "Disk Footprint (Compiled .so Files)")

    disk_data_text = "DISK_FOOTPRINT_DATA:\n"
    for i in 1:n
        disk_data_text *= @sprintf("%s: Total=%.1fMB Avg_per_iter=%.2fKB Iterations=%d\n",
                                  scenarios[i], total_kb[i]/1024, avg_per_iter[i], iterations[i])
    end
    annotate!(p, [(n/2, maximum(total_kb ./ 1024) * 0.3,
                  text(disk_data_text, 4, :center, RGBA(0,0,0,0.01), "Computer Modern"))])

    if output_path !== nothing
        mkpath(dirname(output_path))
        savefig(p, output_path)
        println("Saved: $output_path")
    end

    p
end

"""
Create a comprehensive resource usage overview (3-panel figure).
Combines memory, GC, and disk metrics.
"""
function plot_resource_overview(scenarios::Vector{String},
                                julia_rss::Vector{Float64}, nbjit_rss::Vector{Float64},
                                julia_gc::Vector{Float64}, nbjit_gc::Vector{Float64},
                                disk_size_mb::Vector{Float64};
                                output_path=nothing)
    n = length(scenarios)
    n == 0 && return nothing

    p = plot(
        layout=(1, 3),
        size=(1400, 450),
        dpi=300,
        left_margin=10Plots.mm,
        right_margin=8Plots.mm,
        bottom_margin=18Plots.mm,
        top_margin=8Plots.mm,
        titlefontsize=13,
        titlefontfamily="Computer Modern",
        guidefontsize=11,
        guidefontfamily="Computer Modern",
        tickfontsize=9,
        tickfontfamily="Computer Modern",
        legendfontsize=10,
        legendfontfamily="Computer Modern",
        framestyle=:box,
        grid=:y,
        gridalpha=0.25,
        gridlinewidth=0.5,
        background_color_inside=:white
    )

    x = 1:n
    width = 0.35

    # Panel 1: Memory Usage
    bar!(p[1], x .- width/2, julia_rss,
         bar_width=width, color=COLOR_PALETTE.julia_color, alpha=0.85,
         label="Julia", linewidth=0, subplot=1)
    bar!(p[1], x .+ width/2, nbjit_rss,
         bar_width=width, color=COLOR_PALETTE.nbjit_color, alpha=0.85,
         label="nbjit", linewidth=0, subplot=1)
    xticks!(p[1], 1:n, scenarios, rotation=20, xrotation=20, subplot=1)
    xlabel!(p[1], "Scenario", subplot=1)
    ylabel!(p[1], "Peak RSS (MB)", subplot=1)
    title!(p[1], "Memory Usage", subplot=1)

    # Panel 2: GC Time
    bar!(p[2], x .- width/2, julia_gc,
         bar_width=width, color=COLOR_PALETTE.julia_color, alpha=0.85,
         label="Julia", linewidth=0, subplot=2)
    bar!(p[2], x .+ width/2, nbjit_gc,
         bar_width=width, color=COLOR_PALETTE.nbjit_color, alpha=0.85,
         label="nbjit", linewidth=0, subplot=2)
    xticks!(p[2], 1:n, scenarios, rotation=20, xrotation=20, subplot=2)
    xlabel!(p[2], "Scenario", subplot=2)
    ylabel!(p[2], "GC Time (ms)", subplot=2)
    title!(p[2], "Garbage Collection", subplot=2)

    # Panel 3: Disk Footprint
    bar!(p[3], x, disk_size_mb,
         color=COLOR_PALETTE.nbjit_color, alpha=0.85,
         label="nbjit", linewidth=0, subplot=3)
    xticks!(p[3], 1:n, scenarios, rotation=20, xrotation=20, subplot=3)
    xlabel!(p[3], "Scenario", subplot=3)
    ylabel!(p[3], "Disk Size (MB)", subplot=3)
    title!(p[3], "Compiled Code Size", subplot=3)

    summary_text = "NUMERICAL_DATA:\n"
    for i in 1:n
        summary_text *= @sprintf("%s: Julia_RSS=%.1fMB nbjit_RSS=%.1fMB Julia_GC=%.1fms nbjit_GC=%.1fms Disk=%.1fMB\n",
                                scenarios[i], julia_rss[i], nbjit_rss[i],
                                julia_gc[i], nbjit_gc[i], disk_size_mb[i])
    end
    # Place in a text box (invisible but readable by text extraction)
    annotate!(p[3], [(n/2, maximum(disk_size_mb) * 0.5,
                     text(summary_text, 4, :center, RGBA(0,0,0,0.01), "Computer Modern"))])

    if output_path !== nothing
        mkpath(dirname(output_path))
        savefig(p, output_path)
        println("Saved: $output_path")
    end

    p
end

"""
Plot speedup comparison across scenarios.
"""
function plot_speedup_comparison(results::Vector{BenchmarkResult}; output_path=nothing)
    n = length(results)
    n == 0 && return nothing

    names = [r.name for r in results]
    speedups = [sum(r.julia_times) / sum(r.nbjit_times) for r in results]

    # Create color gradient based on speedup values
    bar_colors = [s >= 1.0 ? COLOR_PALETTE.nbjit_color : COLOR_PALETTE.julia_color for s in speedups]

    p = plot(
        size=(900, 500),
        dpi=300,
        left_margin=12Plots.mm,
        right_margin=8Plots.mm,
        bottom_margin=18Plots.mm,
        top_margin=8Plots.mm,
        titlefontsize=14,
        titlefontfamily="Computer Modern",
        guidefontsize=12,
        guidefontfamily="Computer Modern",
        tickfontsize=10,
        tickfontfamily="Computer Modern",
        legendfontsize=10,
        legendfontfamily="Computer Modern",
        framestyle=:box,
        grid=:y,
        gridalpha=0.25,
        gridlinewidth=0.5,
        background_color_inside=:white
    )

    bar!(p, 1:n, speedups,
         color=bar_colors, alpha=0.85,
         label="Speedup (Julia/nbjit)",
         linewidth=0)

    hline!(p, [1.0], linestyle=:dash, color=:black, linewidth=2, alpha=0.6, label="Baseline (1×)")

    xticks!(p, 1:n, names, rotation=20, xrotation=20)
    xlabel!(p, "Scenario")
    ylabel!(p, "Speedup Factor")
    title!(p, "Total Session Speedup by Scenario")

    if output_path !== nothing
        mkpath(dirname(output_path))
        savefig(p, output_path)
        println("Saved: $output_path")
    end

    p
end

function create_data_summary_page(scenarios::Vector{String},
                                 julia_rss::Vector{Float64}, nbjit_rss::Vector{Float64},
                                 julia_gc::Vector{Float64}, nbjit_gc::Vector{Float64},
                                 julia_pauses::Vector{Int}, nbjit_pauses::Vector{Int},
                                 disk_kb::Vector{Float64}, iterations::Vector{Int};
                                 output_path=nothing)

    p = plot(framestyle=:none, size=(800, 1000), dpi=300,
            xlims=(0, 1), ylims=(0, 1), legend=false, grid=false)

    summary = "COMPLETE NUMERICAL DATA SUMMARY\n"
    summary *= "="^60 * "\n\n"

    summary *= "MEMORY USAGE (Peak RSS in MB):\n"
    summary *= "-"^60 * "\n"
    for i in 1:length(scenarios)
        ratio = julia_rss[i] / max(nbjit_rss[i], 0.1)
        summary *= @sprintf("%-30s: Julia=%7.1f MB  nbjit=%7.1f MB  Ratio=%.2fx\n",
                           scenarios[i], julia_rss[i], nbjit_rss[i], ratio)
    end

    summary *= "\n\nGARBAGE COLLECTION STATISTICS:\n"
    summary *= "-"^60 * "\n"
    for i in 1:length(scenarios)
        summary *= @sprintf("%-30s: Julia_GC=%8.1f ms (%5d pauses)  nbjit_GC=%8.1f ms (%5d pauses)\n",
                           scenarios[i], julia_gc[i], julia_pauses[i],
                           nbjit_gc[i], nbjit_pauses[i])
    end

    summary *= "\n\nDISK FOOTPRINT (Compiled .so files):\n"
    summary *= "-"^60 * "\n"
    for i in 1:length(scenarios)
        avg_kb = disk_kb[i] / max(iterations[i], 1)
        summary *= @sprintf("%-30s: Total=%7.1f MB  Avg/iter=%6.2f KB  Iterations=%4d\n",
                           scenarios[i], disk_kb[i]/1024, avg_kb, iterations[i])
    end

    # Totals
    total_julia_rss = sum(julia_rss)
    total_nbjit_rss = sum(nbjit_rss)
    total_julia_gc = sum(julia_gc)
    total_nbjit_gc = sum(nbjit_gc)
    total_julia_pauses = sum(julia_pauses)
    total_nbjit_pauses = sum(nbjit_pauses)
    total_disk = sum(disk_kb)

    summary *= "\n\nTOTALS ACROSS ALL SCENARIOS:\n"
    summary *= "="^60 * "\n"
    summary *= @sprintf("Memory (Peak RSS):     Julia=%7.1f MB   nbjit=%7.1f MB\n",
                       total_julia_rss, total_nbjit_rss)
    summary *= @sprintf("GC Time:               Julia=%8.1f ms  nbjit=%8.1f ms\n",
                       total_julia_gc, total_nbjit_gc)
    summary *= @sprintf("GC Pauses:             Julia=%8d     nbjit=%8d\n",
                       total_julia_pauses, total_nbjit_pauses)
    summary *= @sprintf("Disk Footprint:                         nbjit=%7.1f MB\n",
                       total_disk/1024)

    # Add text to plot
    annotate!(p, [(0.5, 0.5, text(summary, 8, :center, :black, "Courier"))])

    if output_path !== nothing
        mkpath(dirname(output_path))
        savefig(p, output_path)
        println("Saved data summary: $output_path")
    end

    return p
end

"""
Example: Generate all resource usage plots from benchmark data.

Usage:
    # Define your data from tables.md or benchmark results
    scenarios = ["Algorithm Refinement", "Hyperparameter Sweep", "Simplified Data Workflow",
                 "Simplified Debugging", "Visualization Tweaks"]

    # Memory data (MB)
    julia_rss = [11.6, 0.0, 0.2, 15.6, 22.6]
    nbjit_rss = [1.2, 3.4, 1.5, 1.4, 2.4]

    # GC data
    julia_gc_time = [2172.0, 0.0, 2852.1, 0.0, 86.7]
    nbjit_gc_time = [0.0, 0.0, 0.0, 0.0, 0.0]
    julia_pauses = [1442, 0, 2344, 0, 14]
    nbjit_pauses = [0, 0, 0, 0, 0]

    # Disk footprint data (KB)
    disk_total_kb = [4111.7, 20064.1, 7523.2, 3410.4, 6019.2]
    disk_avg_kb = [39.2, 57.3, 56.6, 48.7, 57.3]
    iterations = [105, 350, 133, 70, 105]

    # Execution time (ms)
    julia_time = [743240.3, 3599.2, 787280.2, 68123.5, 41661.3]
    nbjit_time = [3679.2, 10365.9, 9824.1, 3436.9, 1993.1]

    # Generate plots
    output_dir = joinpath(@__DIR__, "plots")

    plot_memory_comparison(scenarios, julia_rss, nbjit_rss;
        output_path=joinpath(output_dir, "memory_comparison.pdf"))

    plot_gc_statistics(scenarios, julia_gc_time, nbjit_gc_time, julia_pauses, nbjit_pauses;
        output_path=joinpath(output_dir, "gc_statistics.pdf"))

    plot_disk_footprint(scenarios, disk_total_kb, disk_avg_kb, iterations;
        output_path=joinpath(output_dir, "disk_footprint.pdf"))

    plot_resource_overview(scenarios, julia_rss, nbjit_rss, julia_gc_time, nbjit_gc_time,
                          disk_total_kb ./ 1024;
        output_path=joinpath(output_dir, "resource_overview.pdf"))
"""
function generate_resource_plots_example()
    # This is a documentation function showing example usage
    nothing
end

# =============================================================================
# Summary Output
# =============================================================================

"""
Print summary table with median-based metrics.
"""
function print_summary(results::Vector{BenchmarkResult}; title="BENCHMARK SUMMARY")
    println("\n", "="^100)
    println(title)
    println("(Using median times, uncertainty shown as ±1 std)")
    println("="^100)
    println()

    println(@sprintf("%-22s │ %14s │ %14s │ %10s │ %10s │ %10s",
                    "Scenario", "Julia (ms)", "nbjit (ms)", "Speedup", "Med Spdup", "Break-even"))
    println("-"^100)

    total_julia = 0.0
    total_nbjit = 0.0

    for r in results
        # Use sum of medians for total time
        julia_total = sum(r.julia_times)
        nbjit_total = sum(r.nbjit_times)
        speedup = julia_total / max(nbjit_total, 0.001)

        total_julia += julia_total
        total_nbjit += nbjit_total

        # Median speedup (median of per-iteration speedups)
        valid_speedups = Float64[]
        for i in 1:min(length(r.julia_times), length(r.nbjit_times))
            if r.nbjit_times[i] > 0
                push!(valid_speedups, r.julia_times[i] / r.nbjit_times[i])
            end
        end
        med_speedup = isempty(valid_speedups) ? 0.0 : median(valid_speedups)

        # Break-even
        julia_cumsum = cumsum(r.julia_times)
        nbjit_cumsum = cumsum(r.nbjit_times)
        break_even = find_break_even(julia_cumsum, nbjit_cumsum)
        break_even_str = break_even !== nothing ? @sprintf("%.1f", break_even[1]) : "N/A"

        # Show variance if available
        julia_var = sum(r.julia_stds)
        nbjit_var = sum(r.nbjit_stds)
        julia_str = julia_var > 0 ? @sprintf("%.1f±%.1f", julia_total, julia_var) : @sprintf("%.1f", julia_total)
        nbjit_str = nbjit_var > 0 ? @sprintf("%.1f±%.1f", nbjit_total, nbjit_var) : @sprintf("%.1f", nbjit_total)

        println(@sprintf("%-22s │ %14s │ %14s │ %9.2f× │ %9.2f× │ %10s",
                        r.name, julia_str, nbjit_str, speedup, med_speedup, break_even_str))
    end

    println("-"^100)
    overall_speedup = total_julia / max(total_nbjit, 0.001)
    println(@sprintf("%-22s │ %14.1f │ %14.1f │ %9.2f× │ %10s │ %10s",
                    "TOTAL", total_julia, total_nbjit, overall_speedup, "", ""))
    println()
end

# =============================================================================
# Main Entry Points
# =============================================================================

"""
Run visualization for notebook simulation suite.
"""
function run_notebook_simulation(data_path::String)
    println("\n" * "="^60)
    println("NOTEBOOK SIMULATION")
    println("="^60)

    data = if endswith(data_path, ".csv")
        load_csv_data(data_path)
    else
        load_tsv_data(data_path; suite_filter="notebook-simulation")
    end

    results = process_results(data)

    if isempty(results)
        println("No notebook-simulation data found.")
        return nothing
    end

    println("Found $(length(results)) scenarios")

    print_summary(results; title="NOTEBOOK SIMULATION SUMMARY")

    println("Generating plots...")
    output_dir = joinpath(@__DIR__, "plots")

    plot_cumulative_time(results;
        output_path=joinpath(output_dir, "notebook_simulation_cumulative.pdf"))


    results
end

"""
Run visualization for realistic simulation suite.
"""
function run_realistic_simulation(data_path::String)
    println("\n" * "="^60)
    println("REALISTIC SIMULATION")
    println("="^60)

    # Support both TSV (rebench) and detailed CSV formats
    data = if endswith(data_path, ".csv")
        csv_format = detect_csv_format(data_path)
        println("Detected CSV format: $csv_format")
        if csv_format == :detailed
            load_detailed_csv_data(data_path)
        else
            load_csv_data(data_path)
        end
    else
        load_tsv_data(data_path; suite_filter="realistic-simulation")
    end

    results = process_results(data)

    if isempty(results)
        println("No realistic-simulation data found.")
        return nothing
    end

    println("Found $(length(results)) scenarios")

    print_summary(results; title="REALISTIC SIMULATION SUMMARY")

    println("Generating plots...")
    output_dir = joinpath(@__DIR__, "plots")

    plot_cumulative_time(results;
        output_path=joinpath(output_dir, "realistic_simulation_cumulative.pdf"))

    results
end

"""
Parse command line arguments.
"""
function parse_args()
    data_path = nothing
    suite = nothing  # nil means run all
    rebench_mode = false

    for arg in ARGS
        if startswith(arg, "--suite=")
            suite = split(arg, "=")[2]
        elseif arg == "--rebench"
            rebench_mode = true
        elseif !startswith(arg, "--")
            # Could be either a benchmark name (from rebench) or a data path
            if arg in ["notebook", "realistic", "resources"]
                suite = arg
                rebench_mode = true
            else
                data_path = arg
            end
        end
    end

    (data_path=data_path, suite=suite, rebench_mode=rebench_mode)
end

"""
Find data file automatically.
"""
function find_data_file()
    # Look in common locations (prefer detailed CSV for realistic simulation)
    candidates = [
        joinpath(@__DIR__, "results.csv"),  # Detailed CSV from benchmark_realistic_simulation.jl
        joinpath(@__DIR__, "..", "benchmark.data"),
        joinpath(@__DIR__, "benchmark.data"),
        joinpath(@__DIR__, "notebook_simulation_results.csv"),
    ]

    for path in candidates
        if isfile(path)
            return path
        end
    end

    error("No data file found. Looked for:\n" * join(["  - $p" for p in candidates], "\n"))
end

function main()
    start_time = time()
    args = parse_args()

    # Handle resource visualization separately
    if args.suite == "resources"
        # Call the resource visualization script
        include("visualize_resources.jl")
        elapsed = time() - start_time

        if args.rebench_mode
            # Output in rebench format
            println("RESULT-total: $(elapsed * 1000.0) ms")
        end
        return nothing
    end

    # Find data file
    data_path = args.data_path !== nothing ? args.data_path : find_data_file()
    !isfile(data_path) && error("Data file not found: $data_path")

    println("Loading results from: $data_path")

    # Auto-detect suite based on file format
    is_detailed_csv = endswith(data_path, ".csv") && detect_csv_format(data_path) == :detailed

    # Determine which suites to run
    # For detailed CSV, default to realistic only (it doesn't have notebook simulation data)
    if is_detailed_csv && args.suite === nothing
        run_notebook = false
        run_realistic = true
    else
        run_notebook = args.suite === nothing || args.suite == "notebook"
        run_realistic = args.suite === nothing || args.suite == "realistic"
    end

    notebook_results = nothing
    realistic_results = nothing

    if run_notebook
        notebook_results = run_notebook_simulation(data_path)
    end

    if run_realistic
        realistic_results = run_realistic_simulation(data_path)
    end

    println("\nDone!")

    elapsed = time() - start_time

    # Output timing in rebench format if in rebench mode
    if args.rebench_mode
        println("RESULT-total: $(elapsed * 1000.0) ms")
    end

    (notebook=notebook_results, realistic=realistic_results)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
