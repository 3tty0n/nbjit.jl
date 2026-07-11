"""
Benchmark: nbjit.jl Speedup vs Normal Julia

Compares nbjit.jl's incremental compilation against Julia's eval-based execution
(as used in notebooks like IJulia).

Scenarios:
1. Parameter Sweep - 30 parameter-only changes (nbjit's best case)
2. Structure Evolution - 10 structural changes in loop body
3. Mixed Workflow - 10 alternating structure/parameter changes (realistic)
4. Nested Loops - 10 structural changes in nested loops
5. Grid Search - 100 hyperparameter combinations (ML training simulation)
6. Monte Carlo - 50 simulation runs with different seeds
7. Physics Sim - 50 physical constant tuning iterations
8. Image Filter - 30 image processing parameter tweaks

This script runs the benchmarks and saves results to a CSV file.
Use visualize_notebook_simulation.jl to generate plots from the results.
"""

include("../src/ijulia_integration.jl")
using .IJuliaIntegration
using Printf
using Dates
using PythonCall

# Import jupyter_client from Python
const jupyter_client = Ref{Py}()

function init_jupyter_client()
    jupyter_client[] = pyimport("jupyter_client")
end

# Global kernel manager and client
mutable struct IJuliaKernel
    km::Py
    kc::Py
    started::Bool
end

const IJULIA_KERNEL = Ref{Union{Nothing, IJuliaKernel}}(nothing)

function start_ijulia_kernel(; init_nbjit::Bool=false)
    if IJULIA_KERNEL[] !== nothing && IJULIA_KERNEL[].started
        return IJULIA_KERNEL[]
    end

    init_jupyter_client()

    # Start IJulia kernel
    km = jupyter_client[].KernelManager(kernel_name="julia-1.12")
    km.start_kernel()

    # Get client for communication
    kc = km.client()
    kc.start_channels()

    # Wait for kernel to be ready
    kc.wait_for_ready(timeout=60)

    kernel = IJuliaKernel(km, kc, true)
    IJULIA_KERNEL[] = kernel

    println("IJulia kernel started successfully")

    # Initialize nbjit inside the kernel if requested
    if init_nbjit
        println("Initializing nbjit inside IJulia kernel...")
        project_root = dirname(@__DIR__)
        init_code = """
        # Load nbjit.jl project
        import Pkg
        Pkg.activate("$project_root")
        include("$project_root/src/ijulia_integration.jl")
        using .IJuliaIntegration
        # Create a global notebook session for benchmarking
        global __nbjit_session__ = IJuliaIntegration.NotebookSession()
        println("nbjit initialized in kernel")
        """
        execute_on_kernel(kernel, init_code)
        println("nbjit initialized inside IJulia kernel")
    end

    return kernel
end

function stop_ijulia_kernel()
    if IJULIA_KERNEL[] !== nothing && IJULIA_KERNEL[].started
        kernel = IJULIA_KERNEL[]
        kernel.kc.stop_channels()
        kernel.km.shutdown_kernel(now=true)
        kernel.started = false
        IJULIA_KERNEL[] = nothing
        println("IJulia kernel stopped")
    end
end

function execute_on_kernel(kernel::IJuliaKernel, code::String)
    # Execute code on the kernel
    msg_id = kernel.kc.execute(code)

    # Wait for execution to complete
    while true
        try
            msg = kernel.kc.get_iopub_msg(timeout=120)
            parent_header = pyconvert(Dict, msg["parent_header"])
            if get(parent_header, "msg_id", nothing) == pyconvert(String, msg_id)
                header = pyconvert(Dict, msg["header"])
                msg_type = header["msg_type"]
                if msg_type == "execute_result" || msg_type == "status"
                    content = pyconvert(Dict, msg["content"])
                    if msg_type == "status" && get(content, "execution_state", "") == "idle"
                        break
                    end
                elseif msg_type == "error"
                    error("Kernel execution error: $(pyconvert(Dict, msg["content"]))")
                end
            end
        catch e
            if isa(e, PythonCall.PyException)
                # Timeout or other error
                break
            end
            rethrow(e)
        end
    end
end

# Parse executor from command line: --executor=julia or --executor=nbjit
function get_executor()
    for arg in ARGS
        if startswith(arg, "--executor=")
            return split(arg, "=")[2]
        end
    end
    return nothing  # No executor specified, run both (for standalone mode)
end

# Parse benchmark name from command line (for rebench)
function get_benchmark()
    for arg in ARGS
        if !startswith(arg, "--")
            return arg
        end
    end
    return nothing  # No benchmark specified, run all
end

const EXECUTOR = get_executor()
const BENCHMARK = get_benchmark()

# Prevent compiler optimization
global _sink::Any = nothing

function measure_ms(f)
    t = @elapsed (global _sink = f())
    t * 1000
end

function expr_to_string(code::Expr)
    # Convert Expr to string, removing @persistent and @hole macros
    code_str = string(code)
    # Remove begin/end wrapper if present
    code_str = replace(code_str, r"^begin\n" => "")
    code_str = replace(code_str, r"\nend$" => "")
    return code_str
end

function run_julia(code::Expr)
    kernel = IJULIA_KERNEL[]
    if kernel === nothing || !kernel.started
        error("IJulia kernel not started. Call start_ijulia_kernel() first.")
    end

    code_str = expr_to_string(code)
    execute_on_kernel(kernel, code_str)
end

function nbjit_expr_to_string(code::Expr)
    # Convert nbjit Expr to string, keeping @persistent and @hole macros
    code_str = string(code)
    # Remove begin/end wrapper if present
    code_str = replace(code_str, r"^begin\n" => "")
    code_str = replace(code_str, r"\nend$" => "")
    return code_str
end

function run_nbjit(code::Expr, cell_id::String)
    kernel = IJULIA_KERNEL[]
    if kernel === nothing || !kernel.started
        error("IJulia kernel not started. Call start_ijulia_kernel() first.")
    end

    code_str = nbjit_expr_to_string(code)
    # Wrap the code in run_cell! call using the global session
    wrapped_code = """
    IJuliaIntegration.run_cell!(__nbjit_session__, quote
    $code_str
    end; cell_id="$cell_id")
    """
    execute_on_kernel(kernel, wrapped_code)
end

function run_julia_inline(code::String)
    """Execute inline Julia code in the kernel (simulates user writing code directly in cell)"""
    kernel = IJULIA_KERNEL[]
    if kernel === nothing || !kernel.started
        error("IJulia kernel not started. Call start_ijulia_kernel() first.")
    end
    execute_on_kernel(kernel, code)
end

function run_nbjit_native(code::String)
    """Execute nbjit code using @jit macro in the kernel (native IJulia integration)"""
    kernel = IJULIA_KERNEL[]
    if kernel === nothing || !kernel.started
        error("IJulia kernel not started. Call start_ijulia_kernel() first.")
    end
    # Wrap code in @jit macro for native IJulia execution
    wrapped_code = """
    @jit begin
    $code
    end
    """
    execute_on_kernel(kernel, wrapped_code)
end

function benchmark_scenario(name, julia_codes::Vector{String}, nbjit_codes::Vector{String}, cell_id; executor=EXECUTOR)
    """
    Fair benchmark using IJulia's native cell execution:
    - Julia: Inline code executed directly by kernel (eval)
    - nbjit: Code wrapped in @jit macro executed by kernel (native nbjit integration)
    """
    times = Float64[]

    if executor == "julia"
        # Execute inline code (simulates user writing code directly in notebook cell)
        for code in julia_codes
            t = measure_ms(() -> run_julia_inline(code))
            push!(times, t)
        end
    elseif executor == "nbjit"
        # Execute code with @jit macro (native nbjit integration in IJulia)
        for code in nbjit_codes
            t = measure_ms(() -> run_nbjit_native(code))
            push!(times, t)
        end
    else
        # Standalone mode: run both through IJulia kernel
        julia_times = Float64[]
        nbjit_times = Float64[]
        for i in eachindex(julia_codes)
            push!(julia_times, measure_ms(() -> run_julia_inline(julia_codes[i])))
            push!(nbjit_times, measure_ms(() -> run_nbjit_native(nbjit_codes[i])))
        end
        return (name=name, julia=julia_times, nbjit=nbjit_times, executor=nothing)
    end

    (name=name, times=times, executor=executor)
end

# Check if benchmark should run based on BENCHMARK filter
function should_run(name::String)
    if BENCHMARK === nothing
        return true  # No filter, run all
    end
    # Remove spaces from name to match rebench benchmark names
    return replace(name, " " => "") == BENCHMARK
end

function run_benchmarks()
    results = []

    # ==========================================================================
    # Scenario 1: Parameter Sweep (30 iterations)
    # Tests nbjit's best case: many parameter-only changes with stable structure
    # Consolidated from: Parameter Tuning, Rapid Changes, Param Change
    # ==========================================================================
    if should_run("Parameter Sweep")
        # Generate 30 different parameter combinations for comprehensive testing
        # Uses varied thresholds and multipliers to test hole value handling
        params = [(t, m) for t in [10, 30, 50, 70, 100] for m in [2, 3, 5, 7, 11, 13]]

        # Julia: inline code (user writes this directly in notebook cell)
        julia_codes = ["""
            n = 10000000
            threshold = $(p[1])
            multiplier = $(p[2])
            result = 0
            for i in 1:n
                val = (i * multiplier) % 100
                result += val < threshold ? val * 2 : val
            end
            result
        """ for p in params]

        # nbjit: inline code with @persistent/@hole
        nbjit_codes = ["""
            @persistent n = 10000000
            @hole threshold = $(p[1])
            @hole multiplier = $(p[2])
            result = 0
            for i in 1:n
                val = (i * multiplier) % 100
                result += val < threshold ? val * 2 : val
            end
            result
        """ for p in params]

        push!(results, benchmark_scenario(
            "Parameter Sweep",
            julia_codes,
            nbjit_codes,
            "param_sweep"
        ))
    end

    # ==========================================================================
    # Scenario 2: Structure Evolution (10 iterations)
    # Tests nbjit's recompilation: structural changes require full recompile
    # Simulates algorithm development from naive to optimized implementation
    # Note: Uses large n (5M) so computation time dominates compilation overhead
    # ==========================================================================
    if should_run("Structure Evolution")
        # Julia: inline code with evolving structure
        struct_codes_julia = [
            # v1: simple sum
            """
            n = 5000000
            result = 0
            for i in 1:n
                result += i
            end
            result
            """,
            # v2: add multiplication
            """
            n = 5000000
            result = 0
            for i in 1:n
                result += i * 2
            end
            result
            """,
            # v3: add modulo
            """
            n = 5000000
            result = 0
            for i in 1:n
                result += (i * 2) % 1000
            end
            result
            """,
            # v4: change multiplier
            """
            n = 5000000
            result = 0
            for i in 1:n
                result += (i * 3) % 1000
            end
            result
            """,
            # v5: add conditional
            """
            n = 5000000
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                result += val < 500 ? val : 0
            end
            result
            """,
            # v6: change threshold
            """
            n = 5000000
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                result += val < 300 ? val : 0
            end
            result
            """,
            # v7: add else branch
            """
            n = 5000000
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                result += val < 300 ? val : 1
            end
            result
            """,
            # v8: nested computation
            """
            n = 5000000
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                val2 = val * 2
                result += val2 < 600 ? val2 : 1
            end
            result
            """,
            # v9: more complex
            """
            n = 5000000
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                val2 = (val * 2) % 500
                result += val2 < 250 ? val2 * 2 : val2
            end
            result
            """,
            # v10: final version
            """
            n = 5000000
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                val2 = (val * 2) % 500
                val3 = val2 + i % 100
                result += val3 < 300 ? val3 * 2 : val3
            end
            result
            """,
        ]

        # nbjit: inline code with @persistent/@hole (structure changes require recompilation)
        struct_codes_nbjit = [
            """
            @persistent n = 5000000
            @hole _v = 1
            result = 0
            for i in 1:n
                result += i
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole _v = 2
            result = 0
            for i in 1:n
                result += i * 2
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole _v = 3
            result = 0
            for i in 1:n
                result += (i * 2) % 1000
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole _v = 4
            result = 0
            for i in 1:n
                result += (i * 3) % 1000
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole _v = 5
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                result += val < 500 ? val : 0
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole _v = 6
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                result += val < 300 ? val : 0
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole _v = 7
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                result += val < 300 ? val : 1
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole _v = 8
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                val2 = val * 2
                result += val2 < 600 ? val2 : 1
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole _v = 9
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                val2 = (val * 2) % 500
                result += val2 < 250 ? val2 * 2 : val2
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole _v = 10
            result = 0
            for i in 1:n
                val = (i * 3) % 1000
                val2 = (val * 2) % 500
                val3 = val2 + i % 100
                result += val3 < 300 ? val3 * 2 : val3
            end
            result
            """,
        ]

        push!(results, benchmark_scenario(
            "Structure Evolution",
            struct_codes_julia,
            struct_codes_nbjit,
            "struct_evolution"
        ))
    end

    # ==========================================================================
    # Scenario 3: Mixed Workflow (10 iterations)
    # Tests realistic development: alternating structure and parameter changes
    # Most representative of actual notebook development patterns
    # Note: Uses large n (5M) so computation time dominates compilation overhead
    # ==========================================================================
    if should_run("Mixed Workflow")
        mixed_codes_julia = [
            """
            n = 5000000
            k = 2
            result = 0
            for i in 1:n
                result += i * k
            end
            result
            """,
            """
            n = 5000000
            k = 3
            result = 0
            for i in 1:n
                result += i * k
            end
            result
            """,
            """
            n = 5000000
            k = 3
            result = 0
            for i in 1:n
                result += (i * k) % 1000
            end
            result
            """,
            """
            n = 5000000
            k = 5
            result = 0
            for i in 1:n
                result += (i * k) % 1000
            end
            result
            """,
            """
            n = 5000000
            k = 5
            threshold = 500
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val : 0
            end
            result
            """,
            """
            n = 5000000
            k = 7
            threshold = 500
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val : 0
            end
            result
            """,
            """
            n = 5000000
            k = 7
            threshold = 300
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val : 0
            end
            result
            """,
            """
            n = 5000000
            k = 7
            threshold = 300
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val * 2 : val
            end
            result
            """,
            """
            n = 5000000
            k = 11
            threshold = 300
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val * 2 : val
            end
            result
            """,
            """
            n = 5000000
            k = 11
            threshold = 400
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val * 2 : val
            end
            result
            """,
        ]

        mixed_codes_nbjit = [
            """
            @persistent n = 5000000
            @hole k = 2
            result = 0
            for i in 1:n
                result += i * k
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole k = 3
            result = 0
            for i in 1:n
                result += i * k
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole k = 3
            result = 0
            for i in 1:n
                result += (i * k) % 1000
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole k = 5
            result = 0
            for i in 1:n
                result += (i * k) % 1000
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole k = 5
            @hole threshold = 500
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val : 0
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole k = 7
            @hole threshold = 500
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val : 0
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole k = 7
            @hole threshold = 300
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val : 0
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole k = 7
            @hole threshold = 300
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val * 2 : val
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole k = 11
            @hole threshold = 300
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val * 2 : val
            end
            result
            """,
            """
            @persistent n = 5000000
            @hole k = 11
            @hole threshold = 400
            result = 0
            for i in 1:n
                val = (i * k) % 1000
                result += val < threshold ? val * 2 : val
            end
            result
            """,
        ]

        push!(results, benchmark_scenario(
            "Mixed Workflow",
            mixed_codes_julia,
            mixed_codes_nbjit,
            "mixed_workflow"
        ))
    end

    # ==========================================================================
    # Scenario 4: Nested Loops (10 iterations)
    # Tests nested loop compilation overhead with structural evolution
    # Important for matrix/array operations common in data science
    # Note: Uses n=2000 (4M operations per iteration) so computation dominates
    # ==========================================================================
    if should_run("Nested Loops")
        nested_codes_julia = [
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    result += i + j
                end
            end
            result
            """,
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    result += i * j
                end
            end
            result
            """,
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    result += (i * j) % 100
                end
            end
            result
            """,
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    result += val < 50 ? val : 0
                end
            end
            result
            """,
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    result += val < 50 ? val * 2 : val
                end
            end
            result
            """,
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = val + i
                    result += val2 < 100 ? val2 : 0
                end
            end
            result
            """,
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = val + i + j
                    result += val2 < 150 ? val2 : 0
                end
            end
            result
            """,
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = (val + i + j) % 200
                    result += val2 < 100 ? val2 * 2 : val2
                end
            end
            result
            """,
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = (val + i + j) % 200
                    val3 = val2 * 3
                    result += val3 < 300 ? val3 : val2
                end
            end
            result
            """,
            """
            n = 2000
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = (val + i + j) % 200
                    val3 = (val2 * 3) % 500
                    result += val3 < 250 ? val3 * 2 : val3 + val2
                end
            end
            result
            """,
        ]

        nested_codes_nbjit = [
            """
            @persistent n = 2000
            @hole _v = 1
            result = 0
            for i in 1:n
                for j in 1:n
                    result += i + j
                end
            end
            result
            """,
            """
            @persistent n = 2000
            @hole _v = 2
            result = 0
            for i in 1:n
                for j in 1:n
                    result += i * j
                end
            end
            result
            """,
            """
            @persistent n = 2000
            @hole _v = 3
            result = 0
            for i in 1:n
                for j in 1:n
                    result += (i * j) % 100
                end
            end
            result
            """,
            """
            @persistent n = 2000
            @hole _v = 4
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    result += val < 50 ? val : 0
                end
            end
            result
            """,
            """
            @persistent n = 2000
            @hole _v = 5
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    result += val < 50 ? val * 2 : val
                end
            end
            result
            """,
            """
            @persistent n = 2000
            @hole _v = 6
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = val + i
                    result += val2 < 100 ? val2 : 0
                end
            end
            result
            """,
            """
            @persistent n = 2000
            @hole _v = 7
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = val + i + j
                    result += val2 < 150 ? val2 : 0
                end
            end
            result
            """,
            """
            @persistent n = 2000
            @hole _v = 8
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = (val + i + j) % 200
                    result += val2 < 100 ? val2 * 2 : val2
                end
            end
            result
            """,
            """
            @persistent n = 2000
            @hole _v = 9
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = (val + i + j) % 200
                    val3 = val2 * 3
                    result += val3 < 300 ? val3 : val2
                end
            end
            result
            """,
            """
            @persistent n = 2000
            @hole _v = 10
            result = 0
            for i in 1:n
                for j in 1:n
                    val = (i * j) % 100
                    val2 = (val + i + j) % 200
                    val3 = (val2 * 3) % 500
                    result += val3 < 250 ? val3 * 2 : val3 + val2
                end
            end
            result
            """,
        ]

        push!(results, benchmark_scenario(
            "Nested Loops",
            nested_codes_julia,
            nested_codes_nbjit,
            "nested_loops"
        ))
    end

    # ==========================================================================
    # Scenario 5: Hyperparameter Grid Search (100 iterations)
    # nbjit's BEST case: expensive computation, many parameter-only changes
    # Simulates ML hyperparameter tuning with grid search
    # ==========================================================================
    if should_run("Grid Search")
        # Generate 100 parameter combinations
        grid_params = [(lr, reg, mom)
            for lr in [1, 2, 5, 10, 20]
            for reg in [1, 2, 5, 10]
            for mom in [1, 3, 5, 7, 9]]

        grid_codes_julia = ["""
            n = 20000000
            data_sum = 0
            for i in 1:n
                data_sum += i % 1000
            end

            learning_rate = $(p[1])
            regularization = $(p[2])
            momentum = $(p[3])

            result = data_sum % 1000000
            for epoch in 1:500
                for batch in 1:100
                    update = (epoch * learning_rate + batch * momentum) % 10000
                    penalty = regularization * epoch
                    result += update - penalty
                end
            end
            result
        """ for p in grid_params]

        grid_codes_nbjit = ["""
            @persistent n = 20000000
            @persistent data_sum = begin
                s = 0
                for i in 1:n
                    s += i % 1000
                end
                s
            end

            @hole learning_rate = $(p[1])
            @hole regularization = $(p[2])
            @hole momentum = $(p[3])

            result = data_sum % 1000000
            for epoch in 1:500
                for batch in 1:100
                    update = (epoch * learning_rate + batch * momentum) % 10000
                    penalty = regularization * epoch
                    result += update - penalty
                end
            end
            result
        """ for p in grid_params]

        push!(results, benchmark_scenario(
            "Grid Search",
            grid_codes_julia,
            grid_codes_nbjit,
            "grid_search"
        ))
    end

    # ==========================================================================
    # Scenario 6: Monte Carlo Simulation (50 iterations)
    # nbjit's BEST case: same simulation code, different parameters
    # Simulates running experiments with different seeds/thresholds
    # ==========================================================================
    if should_run("Monte Carlo")
        # 50 different parameter combinations
        mc_params = [(seed, thresh, mult)
            for seed in [12345, 23456, 34567, 45678, 56789]
            for thresh in [300, 400, 500, 600, 700]
            for mult in [2, 3]]

        mc_codes_julia = ["""
            n_samples = 10000000
            base = 0
            for i in 1:n_samples
                base += i % 1000
            end

            seed = $(p[1])
            threshold = $(p[2])
            multiplier = $(p[3])

            result = (base + seed) % 1000000
            for i in 1:n_samples
                val = ((i * seed) % 1000) * multiplier
                result += val < threshold ? val : 0
            end
            result
        """ for p in mc_params]

        mc_codes_nbjit = ["""
            @persistent n_samples = 10000000
            @persistent base = begin
                b = 0
                for i in 1:n_samples
                    b += i % 1000
                end
                b
            end

            @hole seed = $(p[1])
            @hole threshold = $(p[2])
            @hole multiplier = $(p[3])

            result = (base + seed) % 1000000
            for i in 1:n_samples
                val = ((i * seed) % 1000) * multiplier
                result += val < threshold ? val : 0
            end
            result
        """ for p in mc_params]

        push!(results, benchmark_scenario(
            "Monte Carlo",
            mc_codes_julia,
            mc_codes_nbjit,
            "monte_carlo"
        ))
    end

    # ==========================================================================
    # Scenario 7: Physics Simulation (50 iterations)
    # nbjit's BEST case: same physics engine, different constants
    # Simulates tuning physical parameters in a simulation
    # ==========================================================================
    if should_run("Physics Sim")
        # 50 different physical constant combinations
        phys_params = [(g, f, v)
            for g in [5, 10, 15, 20, 25]
            for f in [1, 2, 3, 4, 5]
            for v in [50, 100]]

        phys_codes_julia = ["""
            n_particles = 500
            n_steps = 10000

            gravity = $(p[1])
            friction = $(p[2])
            initial_velocity = $(p[3])

            total_energy = 0
            for particle in 1:n_particles
                velocity = initial_velocity
                position = 0
                for step in 1:n_steps
                    velocity = velocity - gravity + (friction * step % 10)
                    position = position + velocity
                    total_energy += (velocity * velocity + position * gravity) % 100000
                end
            end
            total_energy
        """ for p in phys_params]

        phys_codes_nbjit = ["""
            @persistent n_particles = 500
            @persistent n_steps = 10000

            @hole gravity = $(p[1])
            @hole friction = $(p[2])
            @hole initial_velocity = $(p[3])

            total_energy = 0
            for particle in 1:n_particles
                velocity = initial_velocity
                position = 0
                for step in 1:n_steps
                    velocity = velocity - gravity + (friction * step % 10)
                    position = position + velocity
                    total_energy += (velocity * velocity + position * gravity) % 100000
                end
            end
            total_energy
        """ for p in phys_params]

        push!(results, benchmark_scenario(
            "Physics Sim",
            phys_codes_julia,
            phys_codes_nbjit,
            "physics_sim"
        ))
    end

    # ==========================================================================
    # Scenario 8: Image Processing (30 iterations)
    # nbjit's BEST case: same filter code, different parameters
    # Simulates tweaking image filter parameters
    # ==========================================================================
    if should_run("Image Filter")
        # 30 different filter parameter combinations
        img_params = [(b, c, t)
            for b in [0, 25, 50]
            for c in [80, 100, 120]
            for t in [100, 128, 150, 180]]
        # Take first 30
        img_params = img_params[1:min(30, length(img_params))]

        img_codes_julia = ["""
            width = 1500
            height = 1500
            base_val = width * height * 128

            brightness = $(p[1])
            contrast = $(p[2])
            threshold = $(p[3])

            result = 0
            for x in 1:width
                for y in 1:height
                    pixel = (base_val + x * y) % 256
                    adjusted = ((pixel * contrast) / 100 + brightness) % 256
                    result += adjusted > threshold ? adjusted : 0
                end
            end
            result
        """ for p in img_params]

        img_codes_nbjit = ["""
            @persistent width = 1500
            @persistent height = 1500
            @persistent base_val = width * height * 128

            @hole brightness = $(p[1])
            @hole contrast = $(p[2])
            @hole threshold = $(p[3])

            result = 0
            for x in 1:width
                for y in 1:height
                    pixel = (base_val + x * y) % 256
                    adjusted = ((pixel * contrast) / 100 + brightness) % 256
                    result += adjusted > threshold ? adjusted : 0
                end
            end
            result
        """ for p in img_params]

        push!(results, benchmark_scenario(
            "Image Filter",
            img_codes_julia,
            img_codes_nbjit,
            "image_filter"
        ))
    end

    results
end

function save_results_to_csv(results, filepath)
    open(filepath, "w") do io
        if !isempty(results) && results[1].executor !== nothing
            # Single executor mode
            println(io, "scenario,step,time,executor")
            for r in results
                for i in 1:length(r.times)
                    println(io, "$(r.name),$i,$(r.times[i]),$(r.executor)")
                end
            end
        else
            # Standalone mode
            println(io, "scenario,step,julia_time,nbjit_time")
            for r in results
                for i in 1:length(r.julia)
                    println(io, "$(r.name),$i,$(r.julia[i]),$(r.nbjit[i])")
                end
            end
        end
    end
    println("Results saved to: $filepath")
end

function print_rebench_results(results)
    for r in results
        # RebenchLog format: BenchmarkName: iterations=N runtime: VALUEms
        # Remove spaces from name to match rebench.conf benchmark names
        name = replace(r.name, " " => "")

        if r.executor !== nothing
            # Single executor mode (for rebench)
            for i in eachindex(r.times)
                println("$(name): iterations=$(i) runtime: $(r.times[i])ms")
            end
        else
            # Standalone mode: output both
            for i in eachindex(r.julia)
                println("$(name)_$(i)_Julia: iterations=1 runtime: $(r.julia[i])ms")
                println("$(name)_$(i)_nbjit: iterations=1 runtime: $(r.nbjit[i])ms")
            end
        end
    end
end

function print_first_vs_subsequent(results)
    println("\n", "="^80)
    println("FIRST RUN vs SUBSEQUENT RUNS ANALYSIS")
    println("(Shows where nbjit's incremental compilation advantage comes from)")
    println("="^80)
    println()

    println(@sprintf("%-18s │ %20s │ %20s │ %10s",
                    "Scenario", "First Run (ms)", "Subsequent Avg (ms)", "Speedup"))
    println(@sprintf("%-18s │ %9s %9s │ %9s %9s │ %10s",
                    "", "Julia", "nbjit", "Julia", "nbjit", "(Subseq)"))
    println("-"^80)

    for r in results
        julia_first = r.julia[1]
        nbjit_first = r.nbjit[1]

        if length(r.julia) > 1
            julia_subsequent_avg = sum(r.julia[2:end]) / (length(r.julia) - 1)
            nbjit_subsequent_avg = sum(r.nbjit[2:end]) / (length(r.nbjit) - 1)
            subsequent_speedup = julia_subsequent_avg / nbjit_subsequent_avg

            println(@sprintf("%-18s │ %9.2f %9.2f │ %9.2f %9.2f │ %9.2f×",
                            r.name, julia_first, nbjit_first,
                            julia_subsequent_avg, nbjit_subsequent_avg, subsequent_speedup))
        else
            println(@sprintf("%-18s │ %9.2f %9.2f │ %9s %9s │ %10s",
                            r.name, julia_first, nbjit_first, "N/A", "N/A", "N/A"))
        end
    end
    println()
end

function print_cumulative_analysis(results)
    println("\n", "="^80)
    println("CUMULATIVE DEVELOPMENT TIME (what users actually experience)")
    println("(Shows total wait time after N iterations of development)")
    println("="^80)

    for r in results
        julia_cumulative = cumsum(r.julia)
        nbjit_cumulative = cumsum(r.nbjit)

        println("\n$(r.name) - Cumulative time after N iterations:")
        println(@sprintf("  %10s │ %12s │ %12s │ %10s",
                        "Iteration", "Julia (ms)", "nbjit (ms)", "Speedup"))
        println("  ", "-"^55)

        # Show key milestones
        n = length(r.julia)
        milestones = unique([1, min(5, n), min(10, n), min(25, n), min(50, n), n])
        filter!(m -> m <= n, milestones)

        for i in milestones
            speedup = julia_cumulative[i] / nbjit_cumulative[i]
            println(@sprintf("  %10d │ %12.2f │ %12.2f │ %9.2f×",
                            i, julia_cumulative[i], nbjit_cumulative[i], speedup))
        end
    end
    println()
end

function print_summary(results)
    if isempty(results)
        println("No results to display.")
        return
    end

    if results[1].executor !== nothing
        # Single executor mode
        executor = results[1].executor
        println("\n", "="^50)
        println("BENCHMARK RESULTS (Executor: $executor)")
        println("="^50)
        println()

        println(@sprintf("%-18s │ %12s", "Scenario", "Total (ms)"))
        println("-"^50)

        total_time = 0.0
        for r in results
            scenario_total = sum(r.times)
            total_time += scenario_total
            println(@sprintf("%-18s │ %12.2f", r.name, scenario_total))
        end

        println("-"^50)
        println(@sprintf("%-18s │ %12.2f", "TOTAL", total_time))
        println()

        # Detailed per-step table
        println("\n", "="^50)
        println("DETAILED PER-STEP RESULTS")
        println("="^50)

        for r in results
            println("\n$(r.name):")
            println(@sprintf("  %5s │ %12s", "Step", "Time (ms)"))
            println("  ", "-"^25)
            for i in 1:length(r.times)
                println(@sprintf("  %5d │ %12.2f", i, r.times[i]))
            end
        end
        println()
    else
        # Standalone mode: compare Julia vs nbjit
        println("\n", "="^70)
        println("SPEEDUP SUMMARY")
        println("="^70)
        println()

        println(@sprintf("%-18s │ %12s │ %12s │ %10s",
                        "Scenario", "Julia (ms)", "nbjit (ms)", "Speedup"))
        println("-"^70)

        total_julia = 0.0
        total_nbjit = 0.0

        for r in results
            julia_total = sum(r.julia)
            nbjit_total = sum(r.nbjit)

            total_julia += julia_total
            total_nbjit += nbjit_total

            speedup = julia_total / nbjit_total

            println(@sprintf("%-18s │ %12.2f │ %12.2f │ %9.2f×",
                            r.name, julia_total, nbjit_total, speedup))
        end

        println("-"^70)

        overall_speedup = total_julia / total_nbjit
        println(@sprintf("%-18s │ %12.2f │ %12.2f │ %9.2f×",
                        "OVERALL", total_julia, total_nbjit, overall_speedup))

        # First vs Subsequent analysis
        print_first_vs_subsequent(results)

        # Cumulative development time analysis
        print_cumulative_analysis(results)

        # Detailed per-step table
        println("\n", "="^70)
        println("DETAILED PER-STEP RESULTS")
        println("="^70)

        for r in results
            println("\n$(r.name):")
            println(@sprintf("  %5s │ %12s │ %12s │ %10s",
                            "Step", "Julia (ms)", "nbjit (ms)", "Speedup"))
            println("  ", "-"^50)
            for i in 1:length(r.julia)
                speedup = r.julia[i] / r.nbjit[i]
                println(@sprintf("  %5d │ %12.2f │ %12.2f │ %9.2f×",
                                i, r.julia[i], r.nbjit[i], speedup))
            end
        end
        println()
    end
end

function main()
    if !("--rebench" in ARGS)
        println("Running benchmarks...")
    end

    # Start IJulia kernel - always needed now since both julia and nbjit run through kernel
    println("Starting IJulia kernel...")
    # Initialize nbjit in kernel if running nbjit benchmarks
    init_nbjit = (EXECUTOR == "nbjit" || EXECUTOR === nothing)
    start_ijulia_kernel(; init_nbjit=init_nbjit)

    results = try
        run_benchmarks()
    finally
        # Stop kernel when done
        stop_ijulia_kernel()
    end

    if "--rebench" in ARGS
        print_rebench_results(results)
    else
        print_summary(results)

        # Save results to CSV
        timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
        csv_path = joinpath(@__DIR__, "notebook_simulation_results_$(timestamp).csv")
        save_results_to_csv(results, csv_path)

        # Also save to a fixed filename for easy visualization
        latest_path = joinpath(@__DIR__, "notebook_simulation_results.csv")
        save_results_to_csv(results, latest_path)

        println("\nDone! Run visualize_notebook_simulation.jl to generate plots.")
    end
    results
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
