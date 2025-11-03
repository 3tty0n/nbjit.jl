module IJuliaIntegration

include("./split_jit.jl")

export NotebookSession, current_session, set_default_session!, run_cell!
export @ijit, @jit, @cache, get_cell_id

mutable struct NotebookSession
    cells::Dict{String, CompiledSplitCode}
    main_hashes::Dict{String, UInt64}
    hole_hashes::Dict{String, Vector{UInt64}}
    guard_signatures::Dict{String, Vector{Vector{Symbol}}}
    pure_cache::Dict{String, UInt64}  # For cells without holes
end

NotebookSession() = NotebookSession(
    Dict{String, CompiledSplitCode}(),
    Dict{String, UInt64}(),
    Dict{String, Vector{UInt64}}(),
    Dict{String, Vector{Vector{Symbol}}}(),
    Dict{String, UInt64}()
)

const DEFAULT_SESSION = Ref{NotebookSession}(NotebookSession())

struct CellResult
    cell_id::String
    compiled::CompiledSplitCode
    recompiled_holes::Vector{Int}
    rebuilt_main::Bool
end

function Base.show(io::IO, res::CellResult)
    rebuilt = res.rebuilt_main ? "recompiled" : "cached"
    println(io, "Cell $(res.cell_id): main $(res.compiled.main_fname) ($rebuilt)")
    for (i, fname) in enumerate(res.compiled.hole_fnames)
        status = i in res.recompiled_holes ? "recompiled" : "cached"
        println(io, "  hole $i -> $(fname) ($status)")
    end
end

Base.show(io::IO, ::MIME"text/plain", res::CellResult) = show(io, res)

function current_session()
    DEFAULT_SESSION[]
end

function set_default_session!(session::NotebookSession)
    DEFAULT_SESSION[] = session
end

function update_cache!(session::NotebookSession, cell_id::String,
                       compiled::CompiledSplitCode,
                       main_hash::UInt64,
                       hole_hashes::Vector{UInt64},
                       guard_syms::Vector{Vector{Symbol}})
    session.cells[cell_id] = compiled
    session.main_hashes[cell_id] = main_hash
    session.hole_hashes[cell_id] = hole_hashes
    session.guard_signatures[cell_id] = guard_syms
end

function run_cell!(session::NotebookSession, code::Expr; cell_id::AbstractString)
    cell_key = String(cell_id)
    main_ast, hole_blocks, guard_syms = prepare_split(code)
    main_hash = compute_ast_hash(main_ast)
    hole_hashes = [compute_ast_hash(block) for block in hole_blocks]

    rebuilt_main = false
    recompiled_holes = Int[]
    compiled = nothing

    if !haskey(session.cells, cell_key)
        compiled = split_and_compile(code)
        rebuilt_main = true
        recompiled_holes = collect(1:length(hole_blocks))
    else
        compiled = session.cells[cell_key]
        old_main_hash = session.main_hashes[cell_key]
        old_hole_hashes = session.hole_hashes[cell_key]
        old_guards = session.guard_signatures[cell_key]

        if main_hash != old_main_hash ||
           length(hole_hashes) != length(old_hole_hashes) ||
           guard_syms != old_guards
            compiled = split_and_compile(code)
            rebuilt_main = true
            recompiled_holes = collect(1:length(hole_blocks))
        else
            recompiled = Int[]
            for (idx, hhash) in enumerate(hole_hashes)
                if hhash != old_hole_hashes[idx]
                    recompile_hole!(compiled, idx, hole_blocks[idx])
                    push!(recompiled, idx)
                end
            end
            recompiled_holes = recompiled
        end
    end

    compiled isa CompiledSplitCode || error("Unexpected compilation state")
    update_cache!(session, cell_key, compiled, main_hash, hole_hashes, guard_syms)

    return CellResult(cell_key, compiled, recompiled_holes, rebuilt_main)
end

"""
    get_cell_id() -> String

Attempt to retrieve the current IJulia cell execution count. Falls back to a
default identifier if IJulia is not available or the execution count cannot be
determined.
"""
function get_cell_id()
    # Try to get IJulia's execution count if available
    if isdefined(Main, :IJulia) && isdefined(Main.IJulia, :In)
        try
            # IJulia.In is a vector of input strings, length gives us the current count
            cell_num = length(Main.IJulia.In)
            return "In[$cell_num]"
        catch
            # Fall through to auto-generated ID
        end
    end

    # Fall back to a timestamp-based ID if IJulia is not available
    return "cell_$(time_ns())"
end

macro ijit(cell_id, code)
    id_string = cell_id isa Symbol ? string(cell_id) :
                cell_id isa String ? cell_id :
                throw(ArgumentError("@ijit expects a Symbol or String cell identifier"))
    return quote
        local _session = IJuliaIntegration.current_session()
        local _code = $(Expr(:quote, code))
        local _result = IJuliaIntegration.run_cell!(_session, _code; cell_id=$id_string)
        display(_result)
        _result
    end
end

"""
    @jit code

Auto-detecting version of @ijit that retrieves the cell ID from IJulia's
execution context. Use this in IJulia/Jupyter notebooks for automatic cell
tracking.

# Example
```julia
@jit begin
    x = 10
    @hole y = 2
    z = x + y
end
```
"""
macro jit(code)
    return quote
        local _session = IJuliaIntegration.current_session()
        local _code = $(Expr(:quote, code))
        local _cell_id = IJuliaIntegration.get_cell_id()
        local _result = IJuliaIntegration.run_cell!(_session, _code; cell_id=_cell_id)
        display(_result)
        _result
    end
end

"""
    @cache code

Simple caching macro for cells WITHOUT @hole markers. Caches based on code hash.
If the code hasn't changed, displays "(cached)" and skips re-evaluation.

# Example
```julia
@cache begin
    data = expensive_load()
    result = expensive_computation(data)
end
```
"""
macro cache(code)
    return quote
        local _session = IJuliaIntegration.current_session()
        local _code = $(Expr(:quote, code))
        local _cell_id = IJuliaIntegration.get_cell_id()
        IJuliaIntegration.run_pure_cell!(_session, _code, _cell_id)
    end
end

"""
    compile_and_execute(code::Expr) -> Int64

Compile a code block to LLVM IR and execute it via JIT. Returns the result
as an Int64.
"""
function compile_and_execute(code::Expr)
    # Wrap code in a zero-parameter function
    func_expr, fname = partial_evaluate_and_make_entry(code; params=Symbol[])

    # Extract the function definition
    func_ast = extract_function_expr(func_expr)
    if func_ast === nothing
        error("Failed to create function from code block")
    end

    mod, ctx = compile_to_llvm(func_ast, fname)

    # Execute via JIT
    result = LLVM.JIT(mod) do engine
        func_ptr = LLVM.lookup(engine, string(fname))
        ccall(func_ptr, Int64, ())
    end

    LLVM.dispose(ctx)

    return result
end

"""
    run_pure_cell!(session, code, cell_id)

Execute and cache a cell without @hole markers. Returns the cell result or
cached marker.
"""
function run_pure_cell!(session::NotebookSession, code::Expr, cell_id::String)
    code_hash = compute_ast_hash(code)

    if haskey(session.pure_cache, cell_id)
        cached_hash = session.pure_cache[cell_id]
        if cached_hash == code_hash
            # println("Cell $cell_id: (cached)")
            return nothing
        end
    end

    # Code changed or first run - execute it via LLVM
    result = compile_and_execute(code)
    session.pure_cache[cell_id] = code_hash
    result
end

end # module
