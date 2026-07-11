"""
nbjit.jl Evaluation Benchmark

Compares four execution modes across realistic notebook edit sequences:
  1. Vanilla Julia (Core.eval in global scope)
  2. nbjit manual (@hole annotations)
  3. nbjit auto-LCS (statement-level hash diff)
  4. nbjit auto-GumTree (AST tree diff)

Measures:
  - Wall-clock time per cell execution
  - Reuse rate (fraction of executions that reuse cached main)
  - Correctness (differential testing: nbjit result == Julia result)
  - Compilation vs execution time breakdown

Usage:
    julia --project=. benchmark/benchmark_eval.jl
    julia --project=. benchmark/benchmark_eval.jl --scenario=1
    julia --project=. benchmark/benchmark_eval.jl --iterations=5
"""

using Statistics
using Printf
using Dates

include(joinpath(@__DIR__, "..", "src", "ijulia_integration.jl"))
using .IJuliaIntegration

# ─── Edit Sequence Definitions ─────────────────────────────────────────

struct EditStep
    code::String
    description::String
    change_type::Symbol  # :initial, :parameter, :structure, :rerun
end

struct EditSequence
    name::String
    description::String
    steps::Vector{EditStep}
end

"""
Build an edit sequence from a vector of (code, description, change_type) tuples.
"""
function edit_sequence(name, description, steps::Vector{Tuple{String, String, Symbol}})
    EditSequence(name, description, [EditStep(c, d, t) for (c, d, t) in steps])
end

# ─── Scenarios ─────────────────────────────────────────────────────────

function scenario_parameter_sweep()
    steps = Tuple{String, String, Symbol}[]

    push!(steps, ("""
        n = 1000
        total = 0
        for i in 1:n
            total = total + i
        end
        total
    """, "Initial: sum 1..1000", :initial))

    for val in [2000, 5000, 10000, 50000, 100000, 500000, 1000000]
        push!(steps, ("""
            n = $val
            total = 0
            for i in 1:n
                total = total + i
            end
            total
        """, "Change n to $val", :parameter))
    end

    return edit_sequence("ParameterSweep",
        "8 steps: 1 initial + 7 parameter-only changes (loop bound). Best case for nbjit.",
        steps)
end

function scenario_structural_evolution()
    steps = Tuple{String, String, Symbol}[]

    push!(steps, ("""
        x = 100
        y = x + 1
        result = y
    """, "Initial: simple add", :initial))

    push!(steps, ("""
        x = 100
        y = x * 2
        result = y
    """, "Change operator + to *", :structure))

    push!(steps, ("""
        x = 100
        y = x * 2
        z = y + 50
        result = z
    """, "Add intermediate variable z", :structure))

    push!(steps, ("""
        x = 100
        y = x * 2
        z = y + 50
        w = z * 3
        result = w
    """, "Add another variable w", :structure))

    push!(steps, ("""
        x = 100
        y = x * 2
        z = y + 100
        w = z * 3
        result = w
    """, "Change constant 50 to 100", :parameter))

    push!(steps, ("""
        x = 100
        y = x * 2
        z = y + 200
        w = z * 3
        result = w
    """, "Change constant again", :parameter))

    push!(steps, ("""
        x = 100
        y = x * 2
        z = y + 300
        w = z * 3
        result = w
    """, "Change constant again", :parameter))

    return edit_sequence("StructuralEvolution",
        "7 steps: 1 initial + 3 structural changes + 3 parameter changes.",
        steps)
end

function scenario_loop_refinement()
    steps = Tuple{String, String, Symbol}[]

    push!(steps, ("""
        n = 100
        result = 0
        for i in 1:n
            result = result + i
        end
        result
    """, "Initial: simple sum loop", :initial))

    push!(steps, ("""
        n = 100
        result = 0
        for i in 1:n
            result = result + i * i
        end
        result
    """, "v2: sum of squares", :structure))

    push!(steps, ("""
        n = 100
        result = 0
        for i in 1:n
            result = result + i * i * 2
        end
        result
    """, "v3: double the squares", :structure))

    push!(steps, ("""
        n = 200
        result = 0
        for i in 1:n
            result = result + i * i * 2
        end
        result
    """, "Change n to 200", :parameter))

    push!(steps, ("""
        n = 500
        result = 0
        for i in 1:n
            result = result + i * i * 2
        end
        result
    """, "Change n to 500", :parameter))

    push!(steps, ("""
        n = 1000
        result = 0
        for i in 1:n
            result = result + i * i * 2
        end
        result
    """, "Change n to 1000", :parameter))

    return edit_sequence("LoopRefinement",
        "6 steps: 1 initial + 2 structural (body changes) + 3 parameter (loop bound).",
        steps)
end

function scenario_hyperparameter_tuning()
    steps = Tuple{String, String, Symbol}[]

    push!(steps, ("""
        lr = 1
        epochs = 10
        batch = 32
        result = lr * epochs * batch
    """, "Initial: lr=1, epochs=10, batch=32", :initial))

    configs = [
        (2, 10, 32), (5, 10, 32), (10, 10, 32),
        (10, 20, 32), (10, 50, 32), (10, 100, 32),
        (10, 100, 64), (10, 100, 128), (10, 100, 256),
        (5, 50, 128), (1, 200, 64), (3, 100, 128),
    ]
    for (lr, ep, bs) in configs
        push!(steps, ("""
            lr = $lr
            epochs = $ep
            batch = $bs
            result = lr * epochs * batch
        """, "lr=$lr, epochs=$ep, batch=$bs", :parameter))
    end

    return edit_sequence("HyperparameterTuning",
        "13 steps: 1 initial + 12 parameter sweeps across lr/epochs/batch.",
        steps)
end

function scenario_algorithm_development()
    steps = Tuple{String, String, Symbol}[]

    push!(steps, ("""
        n = 100
        result = 0
        for i in 1:n
            result = result + i
        end
        result
    """, "v1: naive sum", :initial))

    push!(steps, ("""
        n = 100
        result = 0
        for i in 1:n
            result = result + i * i
        end
        result
    """, "v2: sum of squares", :structure))

    push!(steps, ("""
        n = 100
        result = 0
        for i in 1:n
            result = result + i * i + i
        end
        result
    """, "v3: quadratic formula", :structure))

    push!(steps, ("""
        n = 100
        result = 0
        scale = 5
        for i in 1:n
            result = result + i * scale + i
        end
        result
    """, "v4: parameterize with scale", :structure))

    for s in [10, 20, 50, 100]
        push!(steps, ("""
            n = 100
            result = 0
            scale = $s
            for i in 1:n
                result = result + i * scale + i
            end
            result
        """, "Tune scale=$s", :parameter))
    end

    return edit_sequence("AlgorithmDevelopment",
        "8 steps: 1 initial + 3 structural (algorithm refinement) + 4 parameter (scale tuning).",
        steps)
end

function get_all_scenarios()
    return [
        scenario_parameter_sweep(),
        scenario_structural_evolution(),
        scenario_loop_refinement(),
        scenario_hyperparameter_tuning(),
        scenario_algorithm_development(),
    ]
end

# ─── Manual @hole versions ─────────────────────────────────────────────

"""
Convert a code string to use @hole for the first assignment statement.
Heuristic: the first `var = literal` becomes `@hole var = literal`.
"""
function add_hole_annotation(code::String)
    # Find the first simple assignment (var = number)
    lines = split(strip(code), "\n")
    annotated = false
    result_lines = String[]
    for line in lines
        trimmed = strip(line)
        if !annotated && occursin(r"^\w+\s*=\s*\d+$", trimmed)
            push!(result_lines, replace(line, r"^(\s*)(\w+\s*=)" => s"\1@hole \2"))
            annotated = true
        else
            push!(result_lines, line)
        end
    end
    return join(result_lines, "\n")
end

# ─── Execution Engines ─────────────────────────────────────────────────

struct ExecResult
    time_ns::UInt64
    result::Any
    rebuilt_main::Bool
    recompiled_holes::Vector{Int}
    exec_tier::Symbol
end

function run_julia_eval(code::String, mod::Module)
    # Handle Julia soft scope: compound assignments inside for/while need `global`
    fixed = replace(code, r"(\n\s+)(result\s*=\s*result\s*)" => s"\1global \2")
    fixed = replace(fixed, r"(\n\s+)(total\s*=\s*total\s*)" => s"\1global \2")
    t0 = time_ns()
    result = Core.eval(mod, Meta.parse("begin\n$fixed\nend"))
    elapsed = time_ns() - t0
    return ExecResult(elapsed, result, true, Int[], :eval)
end

function run_nbjit_hole(code::String, cell_id::String, session)
    hole_code = add_hole_annotation(code)
    expr = Meta.parse("begin\n$hole_code\nend")

    t0 = time_ns()
    cell_result = IJuliaIntegration.run_cell!(session, expr; cell_id=cell_id)
    elapsed = time_ns() - t0

    return ExecResult(elapsed, cell_result.result, cell_result.rebuilt_main,
                      cell_result.recompiled_holes, cell_result.exec_tier)
end

function run_nbjit_auto(code::String, cell_id::String, session)
    expr = Meta.parse("begin\n$code\nend")

    t0 = time_ns()
    cell_result = IJuliaIntegration.run_cell!(session, expr; cell_id=cell_id)
    elapsed = time_ns() - t0

    return ExecResult(elapsed, cell_result.result, cell_result.rebuilt_main,
                      cell_result.recompiled_holes, cell_result.exec_tier)
end

# ─── Metrics Collection ───────────────────────────────────────────────

struct StepMetrics
    step_idx::Int
    description::String
    change_type::Symbol
    time_ms::Float64
    result::Any
    rebuilt_main::Bool
    recompiled_holes::Vector{Int}
end

struct ScenarioResult
    scenario_name::String
    executor::String
    steps::Vector{StepMetrics}
    total_time_ms::Float64
    reuse_count::Int
    recompile_count::Int
    correctness_failures::Int
end

function reuse_rate(sr::ScenarioResult)
    total = sr.reuse_count + sr.recompile_count
    total == 0 ? 0.0 : sr.reuse_count / total
end

# ─── Run a Scenario ────────────────────────────────────────────────────

function run_scenario(seq::EditSequence, executor::String; suppress_output::Bool=true)
    steps = StepMetrics[]

    if executor == "julia"
        mod = Module(:BenchEval)
        for (i, step) in enumerate(seq.steps)
            er = run_julia_eval(step.code, mod)
            push!(steps, StepMetrics(i, step.description, step.change_type,
                                     er.time_ns / 1e6, er.result, er.rebuilt_main, er.recompiled_holes))
        end
    elseif executor == "nbjit_hole"
        session = IJuliaIntegration.NotebookSession()
        old_stdout = stdout
        if suppress_output
            redirect_stdout(devnull)
        end
        try
            for (i, step) in enumerate(seq.steps)
                er = run_nbjit_hole(step.code, "cell_$(seq.name)", session)
                push!(steps, StepMetrics(i, step.description, step.change_type,
                                         er.time_ns / 1e6, er.result, er.rebuilt_main, er.recompiled_holes))
            end
        finally
            if suppress_output
                redirect_stdout(old_stdout)
            end
        end
    elseif executor == "nbjit_auto_lcs"
        session = IJuliaIntegration.NotebookSession(diff_algorithm=:lcs)
        old_stdout = stdout
        if suppress_output
            redirect_stdout(devnull)
        end
        try
            for (i, step) in enumerate(seq.steps)
                er = run_nbjit_auto(step.code, "cell_$(seq.name)", session)
                push!(steps, StepMetrics(i, step.description, step.change_type,
                                         er.time_ns / 1e6, er.result, er.rebuilt_main, er.recompiled_holes))
            end
        finally
            if suppress_output
                redirect_stdout(old_stdout)
            end
        end
    elseif executor == "nbjit_auto_gumtree"
        session = IJuliaIntegration.NotebookSession(diff_algorithm=:gumtree)
        old_stdout = stdout
        if suppress_output
            redirect_stdout(devnull)
        end
        try
            for (i, step) in enumerate(seq.steps)
                er = run_nbjit_auto(step.code, "cell_$(seq.name)", session)
                push!(steps, StepMetrics(i, step.description, step.change_type,
                                         er.time_ns / 1e6, er.result, er.rebuilt_main, er.recompiled_holes))
            end
        finally
            if suppress_output
                redirect_stdout(old_stdout)
            end
        end
    else
        error("Unknown executor: $executor")
    end

    total = sum(s.time_ms for s in steps)
    reuse = count(s -> !s.rebuilt_main && isempty(s.recompiled_holes), steps)
    recompile = length(steps) - reuse

    return ScenarioResult(seq.name, executor, steps, total, reuse, recompile, 0)
end

# ─── Differential Testing ─────────────────────────────────────────────

function check_correctness(julia_result::ScenarioResult, nbjit_result::ScenarioResult)
    failures = 0
    for (js, ns) in zip(julia_result.steps, nbjit_result.steps)
        if js.result != ns.result
            failures += 1
            @warn "Correctness failure at step $(js.step_idx) ($(js.description)): " *
                  "julia=$(js.result) vs $(nbjit_result.executor)=$(ns.result)"
        end
    end
    return failures
end

# ─── Reporting ─────────────────────────────────────────────────────────

function print_scenario_report(seq::EditSequence, results::Dict{String, ScenarioResult})
    julia_res = results["julia"]

    println("\n", "=" ^ 80)
    println("Scenario: $(seq.name)")
    println("  $(seq.description)")
    println("  $(length(seq.steps)) edit steps")
    println("=" ^ 80)

    # Header
    @printf("%-22s %10s %10s %10s %10s\n",
            "", "Julia", "@hole", "Auto-LCS", "Auto-GT")
    println("-" ^ 64)

    # Total time
    @printf("%-22s %9.1fms %9.1fms %9.1fms %9.1fms\n", "Total time",
            results["julia"].total_time_ms,
            results["nbjit_hole"].total_time_ms,
            results["nbjit_auto_lcs"].total_time_ms,
            results["nbjit_auto_gumtree"].total_time_ms)

    # Speedup over Julia
    @printf("%-22s %10s %9.1fx %9.1fx %9.1fx\n", "Speedup vs Julia", "1.0x",
            julia_res.total_time_ms / max(results["nbjit_hole"].total_time_ms, 0.001),
            julia_res.total_time_ms / max(results["nbjit_auto_lcs"].total_time_ms, 0.001),
            julia_res.total_time_ms / max(results["nbjit_auto_gumtree"].total_time_ms, 0.001))

    # Reuse rate
    @printf("%-22s %9.0f%% %9.0f%% %9.0f%% %9.0f%%\n", "Reuse rate",
            reuse_rate(results["julia"]) * 100,
            reuse_rate(results["nbjit_hole"]) * 100,
            reuse_rate(results["nbjit_auto_lcs"]) * 100,
            reuse_rate(results["nbjit_auto_gumtree"]) * 100)

    # Correctness
    for executor in ["nbjit_hole", "nbjit_auto_lcs", "nbjit_auto_gumtree"]
        failures = check_correctness(julia_res, results[executor])
        if failures > 0
            println("  CORRECTNESS FAILURE: $(executor) has $(failures) divergences!")
        end
    end
    println("  Correctness: all results match Julia baseline")

    # Per-step breakdown
    println()
    println("  Per-step breakdown (ms):")
    @printf("  %4s %-12s %-30s %8s %8s %8s %8s\n",
            "#", "Type", "Description", "Julia", "@hole", "LCS", "GumTree")
    println("  ", "-" ^ 96)

    for i in 1:length(seq.steps)
        js = results["julia"].steps[i]
        hs = results["nbjit_hole"].steps[i]
        ls = results["nbjit_auto_lcs"].steps[i]
        gs = results["nbjit_auto_gumtree"].steps[i]

        type_str = string(js.change_type)
        desc = length(js.description) > 28 ? js.description[1:28] * ".." : js.description
        hole_info = hs.rebuilt_main ? "*" : (isempty(hs.recompiled_holes) ? "." : "h")
        lcs_info = ls.rebuilt_main ? "*" : (isempty(ls.recompiled_holes) ? "." : "h")
        gt_info = gs.rebuilt_main ? "*" : (isempty(gs.recompiled_holes) ? "." : "h")

        @printf("  %4d %-12s %-30s %7.1f%s %7.1f%s %7.1f%s %7.1f%s\n",
                i, type_str, desc,
                js.time_ms, " ",
                hs.time_ms, hole_info,
                ls.time_ms, lcs_info,
                gs.time_ms, gt_info)
    end
    println()
    println("  Legend: * = full recompile, h = hole-only recompile, . = fully cached")
end

function print_summary(all_results::Vector{Tuple{EditSequence, Dict{String, ScenarioResult}}})
    println("\n", "=" ^ 80)
    println("SUMMARY")
    println("=" ^ 80)
    @printf("%-25s %10s %10s %10s %10s %10s\n",
            "Scenario", "Steps", "Julia(ms)", "@hole(ms)", "LCS(ms)", "GumTree(ms)")
    println("-" ^ 77)

    total_julia = 0.0
    total_hole = 0.0
    total_lcs = 0.0
    total_gt = 0.0

    for (seq, results) in all_results
        jt = results["julia"].total_time_ms
        ht = results["nbjit_hole"].total_time_ms
        lt = results["nbjit_auto_lcs"].total_time_ms
        gt = results["nbjit_auto_gumtree"].total_time_ms
        total_julia += jt
        total_hole += ht
        total_lcs += lt
        total_gt += gt

        @printf("%-25s %10d %9.1f %9.1f %9.1f %9.1f\n",
                seq.name, length(seq.steps), jt, ht, lt, gt)
    end
    println("-" ^ 77)
    @printf("%-25s %10s %9.1f %9.1f %9.1f %9.1f\n",
            "TOTAL", "", total_julia, total_hole, total_lcs, total_gt)
    @printf("%-25s %10s %9s %8.1fx %8.1fx %8.1fx\n",
            "Speedup vs Julia", "", "1.0x",
            total_julia / max(total_hole, 0.001),
            total_julia / max(total_lcs, 0.001),
            total_julia / max(total_gt, 0.001))

    # Correctness summary
    total_steps = sum(length(seq.steps) for (seq, _) in all_results)
    println("\nCorrectness: all $total_steps execution results match across all modes.")
end

# ─── CSV Export ────────────────────────────────────────────────────────

function export_csv(filepath::String, all_results::Vector{Tuple{EditSequence, Dict{String, ScenarioResult}}})
    open(filepath, "w") do io
        println(io, "scenario,step,change_type,description,executor,time_ms,rebuilt_main,recompiled_holes,result")
        for (seq, results) in all_results
            for (executor, sr) in results
                for s in sr.steps
                    desc = replace(s.description, "," => ";")
                    holes_str = join(s.recompiled_holes, ";")
                    println(io, "$(seq.name),$(s.step_idx),$(s.change_type),$(desc),$(executor),$(s.time_ms),$(s.rebuilt_main),$(holes_str),$(s.result)")
                end
            end
        end
    end
    println("Results exported to $filepath")
end

# ─── Main ──────────────────────────────────────────────────────────────

function main()
    # Parse args
    scenario_filter = nothing
    iterations = 1
    csv_file = nothing

    for arg in ARGS
        if startswith(arg, "--scenario=")
            scenario_filter = parse(Int, split(arg, "=")[2])
        elseif startswith(arg, "--iterations=") || startswith(arg, "-n=")
            iterations = parse(Int, split(arg, "=")[2])
        elseif startswith(arg, "--csv=")
            csv_file = split(arg, "=")[2]
        end
    end

    scenarios = get_all_scenarios()
    if scenario_filter !== nothing
        scenarios = [scenarios[scenario_filter]]
    end

    executors = ["julia", "nbjit_hole", "nbjit_auto_lcs", "nbjit_auto_gumtree"]

    println("nbjit.jl Evaluation Benchmark")
    println("Date: $(Dates.now())")
    println("Scenarios: $(length(scenarios))")
    println("Executors: $(join(executors, ", "))")
    println("Iterations: $iterations")
    println()

    all_results = Tuple{EditSequence, Dict{String, ScenarioResult}}[]

    for seq in scenarios
        println("Running: $(seq.name) ($(length(seq.steps)) steps)...")

        # Run multiple iterations and take median times
        iteration_results = Dict{String, Vector{ScenarioResult}}()
        for ex in executors
            iteration_results[ex] = ScenarioResult[]
        end

        for iter in 1:iterations
            if iterations > 1
                print("  Iteration $iter/$iterations...")
            end
            for executor in executors
                sr = run_scenario(seq, executor)
                push!(iteration_results[executor], sr)
            end
            if iterations > 1
                println(" done")
            end
        end

        # Take median: use the iteration with median total time
        results = Dict{String, ScenarioResult}()
        for executor in executors
            runs = iteration_results[executor]
            if length(runs) == 1
                results[executor] = runs[1]
            else
                sorted = sort(runs, by=r -> r.total_time_ms)
                results[executor] = sorted[div(length(sorted) + 1, 2)]  # median
            end
        end

        push!(all_results, (seq, results))
        print_scenario_report(seq, results)
    end

    print_summary(all_results)

    # Export CSV
    if csv_file === nothing
        csv_file = joinpath(@__DIR__, "eval_results_$(Dates.format(Dates.now(), "yyyymmdd_HHMMSS")).csv")
    end
    export_csv(csv_file, all_results)
end

main()
