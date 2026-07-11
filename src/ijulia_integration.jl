module IJuliaIntegration

using Libdl  # For dlopen, dlsym, dlclose

include("./jit_split.jl")
if !isdefined(@__MODULE__, :nbjit_dict_new)
    include("./jit_runtime.jl")
end
if !isdefined(@__MODULE__, :compile_runtime_library)
    include("./runtime_library.jl")
end
include("./jit_dylib.jl")
include("./cell_deps.jl")
include("./auto_diff.jl")
include("./tree_diff.jl")

export NotebookSession, current_session, set_default_session!, run_cell!
export @jit, @cache, get_cell_id
export enable_dylib_mode!, disable_dylib_mode!
export clear_cache!
export CellDependencyGraph, get_stale_cells, get_upstream, get_downstream
export get_cell_definitions, get_cell_references
export has_hole_markers, auto_prepare_split, gumtree_prepare_split
export gumtree_diff, changed_statement_indices

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
    dep_graph::CellDependencyGraph  # Inter-cell dependency tracking
    cell_codes::Dict{String, Expr}  # Previous cell code for auto diff
    diff_algorithm::Symbol  # :lcs or :gumtree
    global_bindings::Dict{Symbol, Any}  # Cross-cell notebook variables
    import_context::ImportContext  # Session-local import tracking
end

NotebookSession(; diff_algorithm::Symbol=:lcs) = NotebookSession(
    Dict{String, DylibCompiledCode}(),
    Dict{String, UInt64}(),
    Dict{String, Vector{UInt64}}(),
    Dict{String, Vector{Vector{Symbol}}}(),
    Dict{String, UInt64}(),
    Dict{String, Int}(),
    Dict{Tuple{UInt64, Vector{Vector{Symbol}}}, String}(),
    Dict{String, String}(),
    CellDependencyGraph(),
    Dict{String, Expr}(),
    diff_algorithm,
    Dict{Symbol, Any}(),
    ImportContext()
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
    result::Any  # Execution result (Int64, Float64, Ptr, etc.)
    exec_tier::Symbol  # Execution tier: :native, :ir, :recompiled, :full, or :dylib
    dylib_info::Union{Nothing, String}  # Info about dylib compilation
    stale_cells::Vector{String}  # Downstream cells that need re-execution
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
    if !isempty(res.stale_cells)
        println(io, "  stale downstream: $(join(res.stale_cells, ", "))")
    end
end

Base.show(io::IO, ::MIME"text/plain", res::CellResult) = show(io, res)

function current_session()
    DEFAULT_SESSION[]
end

function set_default_session!(session::NotebookSession)
    DEFAULT_SESSION[] = session
end

"""
    qualify_direct_import_calls(code::Expr, ctx::ImportContext) -> Expr

Rewrite direct-imported bare calls such as `plot(x)` into module-qualified calls
like `Plots.plot(x)` based on the session import context.
"""
function qualify_direct_import_calls(code::Expr, ctx::ImportContext)::Expr
    rewritten = deepcopy(code)

    function walk!(node)
        if node isa Expr
            if node.head == :quote
                return
            end

            if node.head == :call && !isempty(node.args) && node.args[1] isa Symbol
                callee = node.args[1]
                import_info = get_direct_import(ctx, callee)
                if import_info !== nothing
                    mod, orig_name = import_info
                    node.args[1] = Expr(:., nameof(mod), QuoteNode(orig_name))
                end
            end

            for arg in node.args
                walk!(arg)
            end
        end
    end

    walk!(rewritten)
    return rewritten
end

"""
    apply_imports!(session::NotebookSession, code::Expr)

Evaluate top-level `using`/`import` statements in source order so package/module
initialization happens before JIT compilation. Also updates the session import
context used by external call resolution.
"""
function apply_imports!(session::NotebookSession, code::Expr)
    resolve_loaded_module(path::Vector{Symbol}) = begin
        isempty(path) && return nothing
        first_name = path[1]
        current = if isdefined(Main, first_name)
            obj = getfield(Main, first_name)
            obj isa Module ? obj : nothing
        else
            try
                Base.require(Main, first_name)
            catch
                nothing
            end
        end
        current === nothing && return nothing

        for name in path[2:end]
            if !isdefined(current, name)
                return nothing
            end
            obj = getfield(current, name)
            if !(obj isa Module)
                return nothing
            end
            current = obj
        end
        return current
    end

    for (stmt_type, module_path, specific_imports) in extract_import_statements(code)
        isempty(module_path) && continue
        module_ref = join(string.(module_path), ".")
        stmt_str = if isempty(specific_imports)
            "$(stmt_type) $(module_ref)"
        else
            imported_names = join(string.(specific_imports), ", ")
            "$(stmt_type) $(module_ref): $(imported_names)"
        end
        stmt = Meta.parse(stmt_str)

        Core.eval(Main, stmt)
        mod = resolve_loaded_module(module_path)
        mod === nothing && continue
        session.import_context.modules[module_path[end]] = mod

        if !isempty(specific_imports)
            for func_name in specific_imports
                if isdefined(mod, func_name)
                    session.import_context.direct_imports[func_name] = (mod, func_name)
                end
            end
        elseif stmt_type == :using
            for name in names(mod)
                if isdefined(mod, name)
                    value = getfield(mod, name)
                    if value isa Function
                        session.import_context.direct_imports[name] = (mod, name)
                    end
                end
            end
        end
    end
    return nothing
end

"""
    clear_cache!(session::NotebookSession=current_session())

Clear all cached compiled code and force recompilation on next execution.
This is useful when the compiler implementation changes and you want to
recompile all code with the new compiler.
"""
function clear_cache!(session::NotebookSession=current_session())
    empty!(session.dylib_cells)
    empty!(session.main_hashes)
    empty!(session.hole_hashes)
    empty!(session.guard_signatures)
    empty!(session.pure_cache)
    empty!(session.execution_counts)
    empty!(session.content_index)
    empty!(session.cell_aliases)
    session.dep_graph = CellDependencyGraph()
    empty!(session.cell_codes)
    empty!(session.import_context.modules)
    empty!(session.import_context.function_bindings)
    empty!(session.import_context.direct_imports)
    println("Cache cleared. All code will be recompiled on next execution.")
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

Execute code following the multi-phase execution model:
  - If code contains @hole markers: use explicit hole mode (manual annotation)
  - If code has no @hole markers: use automatic hole detection via statement-level diff

In both modes:
  - 1st execution: full compilation (no previous version to diff against)
  - 2nd+ executions: detect changes, recompile only changed parts
"""
function run_cell!(session::NotebookSession, code::Expr; cell_id::AbstractString)
    cell_key = String(cell_id)
    apply_imports!(session, code)
    normalized_code = qualify_direct_import_calls(code, session.import_context)
    nbjit_begin_global_transaction!(session.global_bindings)
    try
        result = if has_hole_markers(normalized_code)
            run_cell_dylib!(session, normalized_code, cell_key)
        else
            run_cell_auto!(session, normalized_code, cell_key)
        end
        nbjit_commit_global_transaction!()
        session.cell_codes[cell_key] = deepcopy(normalized_code)
        return result
    catch
        nbjit_rollback_global_transaction!()
        rethrow()
    finally
        nbjit_set_global_bindings!(session.global_bindings)
    end
end

"""
    run_cell_dylib!(session, code, cell_key) -> CellResult

Execute cell using separate dylib compilation mode.
Main and holes are compiled to separate .so/.dylib files.
"""
function run_cell_dylib!(session::NotebookSession, code::Expr, cell_key::String)
    exec_count = get(session.execution_counts, cell_key, 0) + 1
    session.execution_counts[cell_key] = exec_count

    # Update the dependency graph and get stale downstream cells
    stale_cells = update_cell!(session.dep_graph, cell_key, code)

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
            return CellResult(cell_key, compiled, Int[], false, result, :dylib, dylib_info, stale_cells)
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
        recompiled_holes, rebuilt_main = update_dylib!(compiled, code; import_context=session.import_context)
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
                return CellResult(cell_key, compiled, Int[], false, result, :dylib, dylib_info, stale_cells)
            else
                compiled = session.dylib_cells[similar_canonical]
                session.cell_aliases[cell_key] = similar_canonical
                recompiled_holes, rebuilt_main = update_dylib!(compiled, code; import_context=session.import_context)
                update_cache!(session, similar_canonical, compiled, main_hash, hole_hashes, guard_syms)
                session.main_hashes[cell_key] = main_hash
                session.hole_hashes[cell_key] = hole_hashes
                session.guard_signatures[cell_key] = guard_syms
                session.dylib_cells[cell_key] = compiled
            end
        else
            compiled = compile_to_separate_dylibs(code; import_context=session.import_context)
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

    return CellResult(cell_key, compiled, recompiled_holes, rebuilt_main, result, :dylib, dylib_info, stale_cells)
end

"""
    run_cell_auto!(session, code, cell_key) -> CellResult

Execute cell using automatic hole detection via statement-level diff.
On first execution, compiles everything as a single main block.
On re-execution, diffs against the previous version to detect changed statements,
which become holes for selective recompilation.
"""
function run_cell_auto!(session::NotebookSession, code::Expr, cell_key::String)
    exec_count = get(session.execution_counts, cell_key, 0) + 1
    session.execution_counts[cell_key] = exec_count

    # Update the dependency graph
    stale_cells = update_cell!(session.dep_graph, cell_key, code)

    # Get previous version for diffing
    old_code = get(session.cell_codes, cell_key, nothing)

    # Auto-split: diff against previous version using selected algorithm
    split_fn = session.diff_algorithm == :gumtree ? gumtree_prepare_split : auto_prepare_split
    main_ast, hole_blocks, guard_syms = split_fn(old_code, code)
    main_hash = compute_ast_hash(main_ast)
    hole_hashes = [compute_ast_hash(block) for block in hole_blocks]

    has_holes = !isempty(hole_blocks)
    presplit = (main_ast, hole_blocks, guard_syms)

    if haskey(session.dylib_cells, cell_key)
        compiled = session.dylib_cells[cell_key]

        if !has_holes
            # No changes detected (or complete rewrite) — check if code hash changed
            code_hash = compute_ast_hash(code)
            old_hash = get(session.pure_cache, cell_key, UInt64(0))
            if code_hash == old_hash
                # Identical code — reuse cached result
                result = execute_dylib(compiled)
                dylib_info = "Main: $(basename(compiled.main_lib_path)), auto (cached)"
                return CellResult(cell_key, compiled, Int[], false, result, :dylib, dylib_info, stale_cells)
            else
                # Complete rewrite — full recompilation with no holes
                cleanup_dylib!(compiled)
                new_compiled = compile_to_separate_dylibs(code; presplit=presplit, import_context=session.import_context)
                session.dylib_cells[cell_key] = new_compiled
                session.pure_cache[cell_key] = code_hash
                update_cache!(session, cell_key, new_compiled, main_hash, hole_hashes, guard_syms)
                result = execute_dylib(new_compiled)
                dylib_info = "Main: $(basename(new_compiled.main_lib_path)), auto (full recompile)"
                return CellResult(cell_key, new_compiled, collect(1:length(hole_blocks)), true, result, :dylib, dylib_info, stale_cells)
            end
        else
            # Has auto-detected holes — use update path with presplit
            recompiled_holes, rebuilt_main = update_dylib!(compiled, code;
                                                           presplit=presplit,
                                                           import_context=session.import_context)
            update_cache!(session, cell_key, compiled, main_hash, hole_hashes, guard_syms)
            result = execute_dylib(compiled)
            n_holes = length(hole_blocks)
            dylib_info = "Main: $(basename(compiled.main_lib_path)), auto ($n_holes hole(s) detected)"
            return CellResult(cell_key, compiled, recompiled_holes, rebuilt_main, result, :dylib, dylib_info, stale_cells)
        end
    else
        # First compilation for this cell
        compiled = compile_to_separate_dylibs(code; presplit=presplit, import_context=session.import_context)
        session.dylib_cells[cell_key] = compiled
        session.pure_cache[cell_key] = compute_ast_hash(code)
        recompiled_holes = collect(1:length(hole_blocks))
        update_cache!(session, cell_key, compiled, main_hash, hole_hashes, guard_syms)
        result = execute_dylib(compiled)
        n_holes = length(hole_blocks)
        info_suffix = has_holes ? "auto ($n_holes hole(s))" : "auto (first run)"
        dylib_info = "Main: $(basename(compiled.main_lib_path)), $info_suffix"
        return CellResult(cell_key, compiled, recompiled_holes, true, result, :dylib, dylib_info, stale_cells)
    end
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
    # Ensure runtime library is available
    runtime_lib = get_runtime_library_path()

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

    # Link to shared library (with runtime lib for Dict/Array/etc. support)
    lib_ext = Sys.iswindows() ? ".dll" : Sys.isapple() ? ".dylib" : ".so"
    lib_path = tempname() * lib_ext

    try
        if Sys.islinux()
            run(`gcc -shared -o $lib_path $obj_path $runtime_lib`)
        elseif Sys.isapple()
            run(`clang -shared -undefined dynamic_lookup -o $lib_path $obj_path $runtime_lib`)
        elseif Sys.iswindows()
            run(`cl /LD /Fe:$lib_path $obj_path $runtime_lib`)
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

    # Detect return type from compiled function
    func = LLVM.functions(mod)[string(fname)]
    func_type = LLVM.function_type(func)
    ret_llvm = LLVM.return_type(func_type)
    returns_float = (ret_llvm == LLVM.DoubleType())

    native_code = compile_to_native_library(mod, fname)
    LLVM.dispose(ctx)

    try
        if returns_float
            return ccall(native_code.func_ptr, Float64, ())
        else
            return ccall(native_code.func_ptr, Int64, ())
        end
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
