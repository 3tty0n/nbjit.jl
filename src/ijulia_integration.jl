module IJuliaIntegration

using Libdl  # For dlopen, dlsym, dlclose

include("./jit_split.jl")
include("./jit_dylib.jl")

export NotebookSession, current_session, set_default_session!, run_cell!
export @jit, @cache, get_cell_id
export enable_dylib_mode!, disable_dylib_mode!

"""
Cached native code as shared library for direct execution (fastest trampoline)
Uses dlopen to load compiled native code, avoiding recompilation entirely.
"""
mutable struct NativeCode
    lib_handle::Ptr{Cvoid}  # dlopen handle to shared library
    lib_path::String        # Path to shared library file
    func_name::Symbol
    func_ptr::Ptr{Cvoid}    # dlsym result - function pointer
end

"""
Cached executable code with LLVM IR for trampoline-based reuse
"""
mutable struct ExecutableCode
    llvm_ir::String  # Cached LLVM IR text
    func_name::Symbol
    ast::Expr  # Original AST for regeneration if needed
end

mutable struct NotebookSession
    dylib_cells::Dict{String, DylibCompiledCode}
    main_hashes::Dict{String, UInt64}
    hole_hashes::Dict{String, Vector{UInt64}}
    guard_signatures::Dict{String, Vector{Vector{Symbol}}}
    pure_cache::Dict{String, UInt64}  # For cells without holes
    execution_counts::Dict{String, Int}  # Track execution count per cell
    # Content-based lookup: (main_hash, guard_sig) -> cell_id
    content_index::Dict{Tuple{UInt64, Vector{Vector{Symbol}}}, String}
    cell_aliases::Dict{String, String}  # Track cell lineage/aliases
end

NotebookSession() = NotebookSession(
    Dict{String, DylibCompiledCode}(),
    Dict{String, UInt64}(),
    Dict{String, Vector{UInt64}}(),
    Dict{String, Vector{Vector{Symbol}}}(),
    Dict{String, UInt64}(),
    Dict{String, Int}(),
    Dict{Tuple{UInt64, Vector{Vector{Symbol}}}, String}(),
    Dict{String, String}()
)

const DEFAULT_SESSION = Ref{NotebookSession}(NotebookSession())

function resolve_alias!(session::NotebookSession, cell_id::String)
    path = String[]
    current = cell_id
    while haskey(session.cell_aliases, current)
        push!(path, current)
        current = session.cell_aliases[current]
    end
    for alias in path
        session.cell_aliases[alias] = current
    end
    return current
end

clear_alias!(session::NotebookSession, cell_id::String) = delete!(session.cell_aliases, cell_id)

"""
    Result of IJulia kernel
"""
struct CellResult
    cell_id::String
    compiled::DylibCompiledCode
    recompiled_holes::Vector{Int}
    rebuilt_main::Bool
    result::Union{Nothing, Int64}  # Execution result
    exec_tier::Symbol  # Execution tier: :native, :ir, :recompiled, :full, or :dylib
    dylib_info::Union{Nothing, String}  # Info about dylib compilation
end

function Base.show(io::IO, res::CellResult)
    rebuilt = res.rebuilt_main ? "recompiled" : "cached"

    # Show execution tier
    tier_str = if res.exec_tier == :native
        "Native trampoline"
    elseif res.exec_tier == :ir
        "IR trampoline"
    elseif res.exec_tier == :recompiled
        "Recompiled (main cached)"
    elseif res.exec_tier == :dylib
        "Dylib (separate compilation)"
    else
        "Full compile"
    end

    println(io, "Cell $(res.cell_id): main $(res.compiled.main_func_name) ($rebuilt) [$tier_str]")
    if res.dylib_info !== nothing
        println(io, "  $(res.dylib_info)")
    end
    for (i, fname) in enumerate(res.compiled.hole_func_names)
        status = i in res.recompiled_holes ? "recompiled" : "cached"
        println(io, "  hole $i -> $(fname) ($status)")
    end
    if res.result !== nothing
        println(io, "  result: $(res.result)")
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
                       compiled::DylibCompiledCode,
                       main_hash::UInt64,
                       hole_hashes::Vector{UInt64},
                       guard_syms::Vector{Vector{Symbol}})
    session.dylib_cells[cell_id] = compiled
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
    return run_cell_dylib!(session, code, cell_key)
end

"""
    run_cell_dylib!(session, code, cell_key) -> CellResult

Execute cell using separate dylib compilation mode.
Main and holes are compiled to separate .so/.dylib files.
"""
function run_cell_dylib!(session::NotebookSession, code::Expr, cell_key::String)
    exec_count = get(session.execution_counts, cell_key, 0) + 1
    session.execution_counts[cell_key] = exec_count

    main_ast, hole_blocks, guard_syms = prepare_split(code)
    main_hash = compute_ast_hash(main_ast)
    hole_hashes = [compute_ast_hash(block) for block in hole_blocks]
    content_key = (main_hash, guard_syms)

    # Resolve to canonical cell if this ID is an alias
    canonical_key = resolve_alias!(session, cell_key)
    if canonical_key != cell_key
        stored_main = get(session.main_hashes, canonical_key, UInt64(0))
        stored_holes = get(session.hole_hashes, canonical_key, Vector{UInt64}())
        stored_guards = get(session.guard_signatures, canonical_key, Vector{Vector{Symbol}}())
        if main_hash == stored_main && hole_hashes == stored_holes && guard_syms == stored_guards
            compiled = session.dylib_cells[canonical_key]
            session.cell_aliases[cell_key] = canonical_key
            session.main_hashes[cell_key] = main_hash
            session.hole_hashes[cell_key] = hole_hashes
            session.guard_signatures[cell_key] = guard_syms
            session.content_index[content_key] = canonical_key
            result = execute_dylib(compiled)
            dylib_info = "Main: $(basename(compiled.main_lib_path)), " *
                         "Holes: $(length(compiled.hole_lib_paths))"
            return CellResult(cell_key, compiled, Int[], false, result, :dylib, dylib_info)
        else
            clear_alias!(session, cell_key)
            canonical_key = cell_key
        end
    end

    compiled = nothing
    rebuilt_main = false
    recompiled_holes = Int[]

    if haskey(session.dylib_cells, cell_key)
        compiled = session.dylib_cells[cell_key]
        recompiled_holes, rebuilt_main = update_dylib!(compiled, code)
        update_cache!(session, cell_key, compiled, main_hash, hole_hashes, guard_syms)
    else
        similar_cell_id = get(session.content_index, content_key, nothing)
        if similar_cell_id !== nothing && haskey(session.dylib_cells, similar_cell_id)
            similar_canonical = resolve_alias!(session, similar_cell_id)
            base_main_hash = session.main_hashes[similar_canonical]
            base_hole_hashes = session.hole_hashes[similar_canonical]
            base_guards = session.guard_signatures[similar_canonical]

            if main_hash == base_main_hash && hole_hashes == base_hole_hashes && guard_syms == base_guards
                compiled = session.dylib_cells[similar_canonical]
                session.cell_aliases[cell_key] = similar_canonical
                session.main_hashes[cell_key] = main_hash
                session.hole_hashes[cell_key] = hole_hashes
                session.guard_signatures[cell_key] = guard_syms
                session.content_index[content_key] = similar_canonical
                result = execute_dylib(compiled)
                dylib_info = "Main: $(basename(compiled.main_lib_path)), " *
                             "Holes: $(length(compiled.hole_lib_paths))"
                return CellResult(cell_key, compiled, Int[], false, result, :dylib, dylib_info)
            else
                compiled = clone_dylib_compiled(session.dylib_cells[similar_canonical])
                recompiled_holes = Int[]
                for (idx, new_hash) in enumerate(hole_hashes)
                    needs_new = idx > length(base_hole_hashes) || new_hash != base_hole_hashes[idx]
                    if needs_new
                        recompile_single_hole!(compiled, idx, hole_blocks[idx], guard_syms[idx])
                        push!(recompiled_holes, idx)
                    end
                end
                if !isempty(recompiled_holes)
                    refresh_main_link!(compiled)
                end
                compiled.main_hash = main_hash
                compiled.hole_hashes = hole_hashes
                compiled.guard_syms = guard_syms
                session.dylib_cells[cell_key] = compiled
                rebuilt_main = false
                update_cache!(session, cell_key, compiled, main_hash, hole_hashes, guard_syms)
            end
        else
            compiled = compile_to_separate_dylibs(code)
            session.dylib_cells[cell_key] = compiled
            recompiled_holes = collect(1:length(hole_blocks))
            rebuilt_main = true
            update_cache!(session, cell_key, compiled, main_hash, hole_hashes, guard_syms)
        end
    end

    session.content_index[content_key] = resolve_alias!(session, cell_key)

    result = execute_dylib(compiled)
    dylib_info = "Main: $(basename(compiled.main_lib_path)), " *
                 "Holes: $(length(compiled.hole_lib_paths))"

    return CellResult(cell_key, compiled, recompiled_holes, rebuilt_main, result, :dylib, dylib_info)
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
