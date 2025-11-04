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
    execution_counts::Dict{String, Int}  # Track execution count per cell
    guard_env::Dict{String, Dict{Symbol, Any}}  # Track guard variable values
    # Content-based lookup: (main_hash, guard_sig) -> cell_id
    content_index::Dict{Tuple{UInt64, Vector{Vector{Symbol}}}, String}
end

NotebookSession() = NotebookSession(
    Dict{String, CompiledSplitCode}(),
    Dict{String, UInt64}(),
    Dict{String, Vector{UInt64}}(),
    Dict{String, Vector{Vector{Symbol}}}(),
    Dict{String, UInt64}(),
    Dict{String, Int}(),
    Dict{String, Dict{Symbol, Any}}(),
    Dict{Tuple{UInt64, Vector{Vector{Symbol}}}, String}()
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

"""
    run_cell!(session::NotebookSession, code::Expr; cell_id::AbstractString) -> CellResult

Execute code following the multi-phase execution model from ex1.jl:
  - 1st execution: HOLE detection → constant propagation → split compilation
  - 2nd+ executions: Guard checking → fast path (reuse) or slow path (recompile)
    - Fast path: only recompile holes that changed
    - Slow path: full recompile if guards change or holes modify guard variables

Content-based caching: If the same code is executed in different cells (e.g., re-executing
a notebook cell creates a new cell ID), we reuse the cached compilation.
"""
function run_cell!(session::NotebookSession, code::Expr; cell_id::AbstractString)
    cell_key = String(cell_id)

    # Increment execution count
    exec_count = get(session.execution_counts, cell_key, 0) + 1
    session.execution_counts[cell_key] = exec_count

    main_ast, hole_blocks, guard_syms = prepare_split(code)
    main_hash = compute_ast_hash(main_ast)
    hole_hashes = [compute_ast_hash(block) for block in hole_blocks]

    rebuilt_main = false
    recompiled_holes = Int[]
    compiled = nothing

    # Content-based lookup: check if we've seen this exact structure before
    content_key = (main_hash, guard_syms)
    similar_cell_id = get(session.content_index, content_key, nothing)

    # Check if current cell has cached data
    has_cell_cache = haskey(session.cells, cell_key)

    # Try to reuse from similar cell if current cell has no cache
    if !has_cell_cache && similar_cell_id !== nothing && haskey(session.cells, similar_cell_id)
        # Found similar cell with same main structure and guards
        compiled = session.cells[similar_cell_id]
        old_hole_hashes = session.hole_hashes[similar_cell_id]

        # Fast path: only recompile changed holes
        recompiled = Int[]
        for (idx, hhash) in enumerate(hole_hashes)
            if idx <= length(old_hole_hashes) && hhash != old_hole_hashes[idx]
                recompile_hole!(compiled, idx, hole_blocks[idx])
                push!(recompiled, idx)
            elseif idx > length(old_hole_hashes)
                # New hole added
                compiled = split_and_compile(code)
                rebuilt_main = true
                recompiled_holes = collect(1:length(hole_blocks))
                @goto update_cache
            end
        end
        recompiled_holes = recompiled
        rebuilt_main = false
    # Use existing cache for this cell
    elseif has_cell_cache
        compiled = session.cells[cell_key]
        old_main_hash = session.main_hashes[cell_key]
        old_hole_hashes = session.hole_hashes[cell_key]
        old_guards = session.guard_signatures[cell_key]

        # Check if guard symbols changed or main block structure changed
        if main_hash != old_main_hash ||
           length(hole_hashes) != length(old_hole_hashes) ||
           guard_syms != old_guards
            # Slow path: full recompilation needed
            compiled = split_and_compile(code)
            rebuilt_main = true
            recompiled_holes = collect(1:length(hole_blocks))
        else
            # Fast path: only recompile changed holes
            recompiled = Int[]
            for (idx, hhash) in enumerate(hole_hashes)
                if hhash != old_hole_hashes[idx]
                    recompile_hole!(compiled, idx, hole_blocks[idx])
                    push!(recompiled, idx)
                end
            end
            recompiled_holes = recompiled
        end
    # First time seeing this code structure
    else
        compiled = split_and_compile(code)
        rebuilt_main = true
        recompiled_holes = collect(1:length(hole_blocks))
    end

    @label update_cache
    compiled isa CompiledSplitCode || error("Unexpected compilation state")
    update_cache!(session, cell_key, compiled, main_hash, hole_hashes, guard_syms)

    # Update content index to point to this cell
    session.content_index[content_key] = cell_key

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
    compile_to_native_library(mod::LLVM.Module, fname::Symbol) -> NativeCode

Compile LLVM module to a shared library and load it with dlopen.
Returns NativeCode struct with library handle and function pointer.
"""
function compile_to_native_library(mod::LLVM.Module, fname::Symbol)
    # Create target machine with PIC relocation model
    triple = Sys.MACHINE
    target = LLVM.Target(triple=triple)
    # Create target machine with PIC (Position Independent Code) for shared libraries
    tm = LLVM.TargetMachine(
        target,
        triple,
        reloc=LLVM.API.LLVMRelocPIC,
        optlevel=LLVM.API.LLVMCodeGenLevelDefault
    )

    # Compile to object file
    obj_path = tempname() * ".o"
    LLVM.emit(tm, mod, LLVM.API.LLVMObjectFile, obj_path)

    # Link to shared library
    lib_ext = Sys.iswindows() ? ".dll" : Sys.isapple() ? ".dylib" : ".so"
    lib_path = tempname() * lib_ext

    try
        if Sys.islinux()
            run(`gcc -shared -o $lib_path $obj_path`)
        elseif Sys.isapple()
            run(`clang -shared -o $lib_path $obj_path`)
        elseif Sys.iswindows()
            run(`cl /LD /Fe:$lib_path $obj_path`)
        else
            error("Unsupported platform for native library compilation")
        end
    finally
        isfile(obj_path) && rm(obj_path)
    end

    lib_handle = Libdl.dlopen(lib_path)
    func_ptr = Libdl.dlsym(lib_handle, fname)

    return NativeCode(lib_handle, lib_path, fname, func_ptr)
end


"""
    compile_and_execute(code::Expr) -> result
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

    native_code = compile_to_native_library(mod, fname)
    LLVM.dispose(ctx)

    try
        return ccall(native_code.func_ptr, Int64, ())
    finally
        try
            if native_code.lib_handle != C_NULL
                Libdl.dlclose(native_code.lib_handle)
            end
        catch e
            @warn "Failed to close pure cell library: $e"
        end
        if isfile(native_code.lib_path)
            try
                rm(native_code.lib_path)
            catch e
                @warn "Failed to remove pure cell library file: $e"
            end
        end
    end
end

"""
    run_pure_cell!(session, code, cell_id) -> nothing | result

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
