"""
True separate compilation using dynamic libraries with function pointer tables.

Architecture:
- Main is compiled once with a function pointer table for holes
- Each hole is compiled to a separate .so/.dylib file
- When a hole changes, only that hole is recompiled
- Main's .so is reused without recompilation
"""

using LLVM
using Libdl
using Random

if !isdefined(@__MODULE__, :prepare_split)
    include("./jit_split.jl")
end
if !isdefined(@__MODULE__, :generate_IR)
    include("./jit.jl")
end
if !isdefined(@__MODULE__, :partial_evaluate_and_make_entry)
    include("./partial_evaluate.jl")
end
if !isdefined(@__MODULE__, :compile_runtime_library)
    include("./runtime_library.jl")
end

"""
Tracks separately compiled libraries for main and holes
"""
mutable struct DylibCompiledCode
    # Main library (never changes unless main code changes)
    main_lib_path::Union{Nothing,String}
    main_lib_handle::Ptr{Cvoid}
    main_func_name::Symbol

    # Hole libraries (can be recompiled independently)
    hole_lib_paths::Vector{String}
    hole_lib_handles::Vector{Ptr{Cvoid}}
    hole_func_names::Vector{Symbol}
    hole_inputs::Vector{Vector{Symbol}}

    # Cached ASTs
    main_ast::Expr
    hole_asts::Vector{Expr}
    guard_syms::Vector{Vector{Symbol}}
    main_hash::UInt64
    hole_hashes::Vector{UInt64}
    hole_ptr_locs::Vector{Ptr{Cvoid}}

    # Return type of the main function (:int64, :float64, or :object)
    return_type::Symbol
end

"""
Identify the first assignment target within a hole block.
Returns the assigned Symbol if found, otherwise `nothing`.
"""
function infer_hole_assignment_target(hole_block)::Union{Nothing,Symbol}
    if hole_block isa Expr
        if hole_block.head == :block
            for stmt in hole_block.args
                if stmt isa LineNumberNode
                    continue
                end
                target = infer_hole_assignment_target(stmt)
                target !== nothing && return target
            end
        elseif hole_block.head == :(=) && hole_block.args[1] isa Symbol
            return hole_block.args[1]
        end
    end
    return nothing
end

"""
Compute the guard inputs required for each hole based on variables defined before the hole.
"""
function compute_hole_inputs(main_ast::Expr, guard_syms::Vector{Vector{Symbol}}, hole_blocks::Vector{Expr})
    defined = Set{Symbol}()
    inputs = Vector{Vector{Symbol}}()
    hole_idx = 1

    for stmt in main_ast.args
        if stmt isa Expr && stmt.head == :(=) && stmt.args[1] isa Symbol
            push!(defined, stmt.args[1])
        elseif stmt isa Expr && stmt.head == :hole
            guards = hole_idx <= length(guard_syms) ? guard_syms[hole_idx] : Symbol[]
            hole_ast = hole_idx <= length(hole_blocks) ? hole_blocks[hole_idx] : Expr(:block)
            seen = Set{Symbol}()
            input_syms = Symbol[]
            for sym in guards
                if sym isa Symbol && sym in defined && !(sym in seen)
                    push!(input_syms, sym)
                    push!(seen, sym)
                end
            end

            push!(inputs, input_syms)

            assignment_target = infer_hole_assignment_target(hole_ast)
            if assignment_target isa Symbol
                push!(defined, assignment_target)
            end
            hole_idx += 1
        end
    end

    return inputs
end

"""
Generate a main AST where each @hole marker is replaced by a call to the compiled hole function.
If the hole originally assigned to a variable, emit an assignment that uses the hole call result.
"""
function generate_main_with_hole_calls(main_ast::Expr, hole_func_names::Vector{Symbol},
                                       hole_asts::Vector{Expr}, hole_inputs::Vector{Vector{Symbol}})
    modified_ast = deepcopy(main_ast)
    hole_idx = 1
    defined = Set{Symbol}()
    for (i, stmt) in enumerate(modified_ast.args)
        if stmt isa Expr && stmt.head == :(=) && stmt.args[1] isa Symbol
            push!(defined, stmt.args[1])
        elseif stmt isa Expr && stmt.head == :hole
            if hole_idx <= length(hole_func_names)
                hole_fname = hole_func_names[hole_idx]
                guards = hole_idx <= length(hole_inputs) ? hole_inputs[hole_idx] : Symbol[]
                hole_ast = hole_idx <= length(hole_asts) ? hole_asts[hole_idx] : Expr(:block)
                assignment_target = infer_hole_assignment_target(hole_ast)

                call_args = guards

                call_expr = isempty(call_args) ? Expr(:call, hole_fname) : Expr(:call, hole_fname, call_args...)
                replacement = assignment_target === nothing ? call_expr : Expr(:(=), assignment_target, call_expr)
                modified_ast.args[i] = replacement
                if assignment_target isa Symbol
                    push!(defined, assignment_target)
                end
                hole_idx += 1
            end
        end
    end
    return modified_ast
end

"""
Compile an LLVM module to a shared library (.so/.dylib/.dll)
"""
function sanitize_symbol_name(sym::Symbol)
    name = String(sym)
    sanitized = replace(name, r"[^A-Za-z0-9_]" => "_")
    return isempty(sanitized) ? "anon" : sanitized
end

function generate_dylib_path(prefix::String, fname::Symbol)
    lib_ext = Sys.iswindows() ? ".dll" : Sys.isapple() ? ".dylib" : ".so"
    fname_part = sanitize_symbol_name(fname)
    suffix = randstring(8)
    return joinpath(tempdir(), "nbjit_$(prefix)_$(fname_part)_$(suffix)$(lib_ext)")
end

function compile_module_to_dylib(mod::LLVM.Module, fname::Symbol, prefix::String="lib";
                                  extra_libs::Vector{String}=String[],
                                  allow_undefined::Bool=false)
    # Ensure runtime library is compiled and available
    runtime_lib = get_runtime_library_path()

    # Create target machine with PIC
    triple = Sys.MACHINE
    target = LLVM.Target(triple=triple)
    tm = LLVM.TargetMachine(
        target,
        triple,
        get_host_cpu_name(),
        get_host_cpu_features();
        reloc=LLVM.API.LLVMRelocPIC,
        optlevel=LLVM.API.LLVMCodeGenLevelDefault
    )

    obj_path = tempname() * ".o"
    LLVM.emit(tm, mod, LLVM.API.LLVMObjectFile, obj_path)

    lib_path = generate_dylib_path(prefix, fname)

    try
        if Sys.islinux()
            # Link against the runtime library and any extra libraries
            libs = [runtime_lib; extra_libs]
            if allow_undefined
                run(`gcc -shared -Wl,--allow-shlib-undefined -o $lib_path $obj_path $libs`)
            else
                run(`gcc -shared -o $lib_path $obj_path $libs`)
            end
        elseif Sys.isapple()
            # On macOS, link against the runtime library and any extra libraries
            # Use -undefined dynamic_lookup to allow symbols to be resolved at runtime
            libs = [runtime_lib; extra_libs]
            if allow_undefined
                run(`clang -shared -undefined dynamic_lookup -o $lib_path $obj_path $libs`)
            else
                run(`clang -shared -o $lib_path $obj_path $libs`)
            end
        elseif Sys.iswindows()
            libs = [runtime_lib; extra_libs]
            run(`cl /LD /Fe:$lib_path $obj_path $libs`)
        else
            error("Unsupported platform for shared library compilation")
        end
    finally
        isfile(obj_path) && rm(obj_path)
    end

    return lib_path
end

"""
Compile main and holes to separate dylibs. Returns DylibCompiledCode.
"""
function compile_to_separate_dylibs(code::Expr;
    presplit::Union{Nothing, Tuple{Expr, Vector{Expr}, Vector{Vector{Symbol}}}}=nothing,
    import_context::ImportContext=GLOBAL_IMPORT_CONTEXT)
    # Split code (use presplit if provided, otherwise split via @hole markers)
    main_ast, hole_blocks, guard_syms = presplit !== nothing ? presplit : prepare_split(code)
    main_hash = compute_ast_hash(main_ast)
    hole_hashes = [compute_ast_hash(block) for block in hole_blocks]

    # Normalize hole blocks and compute input symbols per hole
    normalized_hole_blocks = [hole_block isa Expr ? hole_block : Expr(:block, hole_block) for hole_block in hole_blocks]
    hole_inputs = compute_hole_inputs(main_ast, guard_syms, normalized_hole_blocks)

    # Compile holes to separate dylibs
    hole_lib_paths = String[]
    hole_lib_handles = Ptr{Cvoid}[]
    hole_func_names = Symbol[]
    hole_asts = Expr[]
    hole_func_signatures = []  # Store signature info: (nparams, return_type_sym)

    for (i, hole_block_expr) in enumerate(normalized_hole_blocks)
        push!(hole_asts, deepcopy(hole_block_expr))

        # Compile hole
        params = i <= length(hole_inputs) ? hole_inputs[i] : Symbol[]
        hole_func_expr, hole_fname = partial_evaluate_and_make_entry(hole_block_expr; params=params)
        push!(hole_func_names, hole_fname)

        func_ast = extract_function_expr(hole_func_expr)

        if func_ast !== nothing
            # Compile to LLVM module
            ctx = LLVM.Context()
            mod = generate_IR(ctx, func_ast; import_context=import_context)
            LLVM.linkage!(LLVM.functions(mod)[string(hole_fname)], LLVM.API.LLVMExternalLinkage)
            optimize!(mod)

            # Extract function signature info before disposing context
            hole_func = LLVM.functions(mod)[string(hole_fname)]
            func_type = LLVM.function_type(hole_func)
            n_params = length(LLVM.parameters(func_type))
            hole_ret_llvm = LLVM.return_type(func_type)
            ret_type_sym = if hole_ret_llvm == LLVM.DoubleType()
                :float64
            elseif hole_ret_llvm == julia_object_type()
                :object
            else
                :int64
            end
            push!(hole_func_signatures, (n_params, ret_type_sym))

            # Compile to dylib
            lib_path = compile_module_to_dylib(mod, hole_fname, "hole$(i)")
            push!(hole_lib_paths, lib_path)

            LLVM.dispose(ctx)

            # Load library
            lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_NOW | Libdl.RTLD_GLOBAL)
            push!(hole_lib_handles, lib_handle)
        else
            push!(hole_lib_paths, "")
            push!(hole_lib_handles, C_NULL)
            push!(hole_func_signatures, (0, :int64))
        end
    end

    # Generate main code that calls holes via external function calls
    main_with_calls = generate_main_with_hole_calls(main_ast, hole_func_names, hole_asts, hole_inputs)

    # Flatten nested blocks for stable compilation
    flattened_args = []
    for stmt in main_with_calls.args
        if stmt isa Expr && stmt.head == :block
            append!(flattened_args, stmt.args)
        else
            push!(flattened_args, stmt)
        end
    end
    main_block = Expr(:block, flattened_args...)

    # Compile main to dylib (no inlined holes)
    main_func_expr, main_fname = partial_evaluate_and_make_entry(main_block; params=Symbol[])
    main_func_ast = extract_function_expr(main_func_expr)

    if main_func_ast === nothing
        error("Failed to generate main function")
    end

    # Build external signatures dictionary for hole functions
    external_sigs = Dict{Symbol, Tuple{Int, Symbol}}()
    for (i, hole_fname) in enumerate(hole_func_names)
        if i <= length(hole_func_signatures)
            external_sigs[hole_fname] = hole_func_signatures[i]
        end
    end

    # Use indirect calls for holes to avoid dlclose/dlopen of main lib
    hole_names_set = Set(hole_func_names)

    ctx = LLVM.Context()
    mod = generate_IR(ctx, main_func_ast;
                      external_sigs=external_sigs,
                      import_context=import_context,
                      indirect_syms=hole_names_set)
    LLVM.linkage!(LLVM.functions(mod)[string(main_fname)], LLVM.API.LLVMExternalLinkage)

    # Detect return type from the compiled LLVM function
    main_func = LLVM.functions(mod)[string(main_fname)]
    main_func_type = LLVM.function_type(main_func)
    main_ret_llvm = LLVM.return_type(main_func_type)
    return_type_sym = if main_ret_llvm == LLVM.DoubleType()
        :float64
    elseif main_ret_llvm == julia_object_type()
        :object
    else
        :int64
    end

    optimize!(mod)

    main_lib_path = compile_module_to_dylib(mod, main_fname, "main";
                                            allow_undefined=true)
    LLVM.dispose(ctx)

    main_lib_handle = Libdl.dlopen(main_lib_path, Libdl.RTLD_NOW | Libdl.RTLD_GLOBAL)

    # Resolve and update function pointers in the main library
    hole_ptr_locs = Ptr{Cvoid}[]
    for (i, hole_fname) in enumerate(hole_func_names)
        ptr_name = "ptr_" * string(hole_fname)
        ptr_loc = Libdl.dlsym(main_lib_handle, Symbol(ptr_name); throw_error=false)

        if !(ptr_loc isa Ptr{Cvoid}) || ptr_loc == C_NULL
            @warn "Could not find pointer variable $ptr_name in main library"
        else
            hole_handle = hole_lib_handles[i]
            if hole_handle != C_NULL
                func_ptr = Libdl.dlsym(hole_handle, hole_fname)
                unsafe_store!(convert(Ptr{Ptr{Cvoid}}, ptr_loc), func_ptr)
            end
        end
        push!(hole_ptr_locs, ptr_loc)
    end

    # Patch external bridge pointers (module-qualified/imported calls) into the
    # compiled main library's pointer globals.
    for (bridge_name, func_ptr) in EXTERNAL_FUNC_POINTERS
        ptr_loc = Libdl.dlsym(main_lib_handle, Symbol("ptr_" * bridge_name); throw_error=false)
        if ptr_loc isa Ptr{Cvoid} && ptr_loc != C_NULL
            unsafe_store!(convert(Ptr{Ptr{Cvoid}}, ptr_loc), func_ptr)
        end
    end

    return DylibCompiledCode(
        main_lib_path,
        main_lib_handle,
        main_fname,
        hole_lib_paths,
        hole_lib_handles,
        hole_func_names,
        hole_inputs,
        main_ast,
        hole_asts,
        guard_syms,
        main_hash,
        hole_hashes,
        hole_ptr_locs,
        return_type_sym
    )
end

"""
Execute by calling main dylib function.
"""
function execute_dylib(compiled::DylibCompiledCode)
    if compiled.main_lib_handle == C_NULL
        error("Main library not loaded")
    end

    func_ptr = Libdl.dlsym(compiled.main_lib_handle, compiled.main_func_name)
    if compiled.return_type == :float64
        result = ccall(func_ptr, Float64, ())
        return result
    elseif compiled.return_type == :object
        result_ptr = ccall(func_ptr, Ptr{Nothing}, ())
        return result_ptr
    else
        result = ccall(func_ptr, Int64, ())
        return result
    end
end

"""
Recompile only changed holes and main, reusing main dylib if possible.
"""
function update_dylib!(compiled::DylibCompiledCode, new_code::Expr;
    presplit::Union{Nothing, Tuple{Expr, Vector{Expr}, Vector{Vector{Symbol}}}}=nothing,
    import_context::ImportContext=GLOBAL_IMPORT_CONTEXT)
    # Split new code (use presplit if provided)
    new_main_ast, new_hole_blocks, new_guard_syms = presplit !== nothing ? presplit : prepare_split(new_code)
    new_main_hash = compute_ast_hash(new_main_ast)
    new_hole_hashes = [compute_ast_hash(block) for block in new_hole_blocks]

    # Check if main structure changed
    main_changed = new_main_hash != compiled.main_hash || new_guard_syms != compiled.guard_syms

    # Find which holes changed
    changed_holes = Int[]
    for (i, new_hash) in enumerate(new_hole_hashes)
        if i <= length(compiled.hole_hashes)
            if new_hash != compiled.hole_hashes[i]
                push!(changed_holes, i)
            end
        else
            # New hole added
            push!(changed_holes, i)
        end
    end

    if main_changed
        println("Main structure changed - full recompilation required")
        # Clean up old libraries
        cleanup_dylib!(compiled)
        # Recompile everything (pass presplit through if available)
        new_compiled = compile_to_separate_dylibs(new_code; presplit=presplit, import_context=import_context)
        # Copy to current struct
        compiled.main_lib_path = new_compiled.main_lib_path
        compiled.main_lib_handle = new_compiled.main_lib_handle
        compiled.main_func_name = new_compiled.main_func_name
        compiled.hole_lib_paths = new_compiled.hole_lib_paths
        compiled.hole_lib_handles = new_compiled.hole_lib_handles
        compiled.hole_func_names = new_compiled.hole_func_names
        compiled.hole_inputs = new_compiled.hole_inputs
        compiled.main_ast = new_compiled.main_ast
        compiled.hole_asts = new_compiled.hole_asts
        compiled.guard_syms = new_compiled.guard_syms
        compiled.main_hash = new_compiled.main_hash
        compiled.hole_hashes = new_compiled.hole_hashes
        compiled.hole_ptr_locs = new_compiled.hole_ptr_locs
        compiled.return_type = new_compiled.return_type
        return (collect(1:length(new_hole_blocks)), true)
    elseif !isempty(changed_holes)
        println("Holes changed: ", changed_holes, " - recompiling holes only (reusing main dylib)")
        # Recompile only changed holes
        for hole_idx in changed_holes
            if hole_idx <= length(new_hole_blocks)
                recompile_single_hole!(compiled, hole_idx, new_hole_blocks[hole_idx], new_guard_syms[hole_idx];
                                       import_context=import_context)

                # Update function pointer in main library directly
                if hole_idx <= length(compiled.hole_ptr_locs)
                    ptr_loc = compiled.hole_ptr_locs[hole_idx]
                    if ptr_loc != C_NULL
                        # Get new function address
                        hole_handle = compiled.hole_lib_handles[hole_idx]
                        hole_fname = compiled.hole_func_names[hole_idx]
                        new_func_ptr = Libdl.dlsym(hole_handle, hole_fname)
                        
                        # Atomic update (pointer size)
                        unsafe_store!(convert(Ptr{Ptr{Cvoid}}, ptr_loc), new_func_ptr)
                    end
                end
            end
        end

        compiled.guard_syms = new_guard_syms
        compiled.main_hash = new_main_hash
        compiled.hole_hashes = new_hole_hashes
        compiled.hole_inputs = compute_hole_inputs(new_main_ast, new_guard_syms, compiled.hole_asts)
        return (changed_holes, false)
    else
        println("No changes detected - reusing cached dylibs")
        return (Int[], false)
    end
end

"""
Recompile a single hole dylib.
"""
function recompile_single_hole!(compiled::DylibCompiledCode, hole_idx::Int, new_hole_block, new_guards::Vector{Symbol};
                                import_context::ImportContext=GLOBAL_IMPORT_CONTEXT)
    # Close and remove old hole library
    if hole_idx <= length(compiled.hole_lib_handles) && compiled.hole_lib_handles[hole_idx] != C_NULL
        try
            Libdl.dlclose(compiled.hole_lib_handles[hole_idx])
        catch e
            @warn "Failed to close hole $hole_idx library: $e"
        end

        old_path = compiled.hole_lib_paths[hole_idx]
        if isfile(old_path)
            try
                rm(old_path)
            catch e
                @warn "Failed to remove old hole $hole_idx library: $e"
            end
        end
    end

    # Compile new hole
    hole_block_expr = new_hole_block isa Expr ? new_hole_block : Expr(:block, new_hole_block)

    target_name = hole_idx <= length(compiled.hole_func_names) ? compiled.hole_func_names[hole_idx] : nothing
    params = hole_idx <= length(compiled.hole_inputs) ? compiled.hole_inputs[hole_idx] : new_guards
    hole_func_expr, hole_fname = partial_evaluate_and_make_entry(hole_block_expr; params=params, fname=target_name)
    func_ast = extract_function_expr(hole_func_expr)

    if func_ast !== nothing
        ctx = LLVM.Context()
        mod = generate_IR(ctx, func_ast; import_context=import_context)
        LLVM.linkage!(LLVM.functions(mod)[string(hole_fname)], LLVM.API.LLVMExternalLinkage)
        optimize!(mod)

        lib_path = compile_module_to_dylib(mod, hole_fname, "hole$(hole_idx)")
        LLVM.dispose(ctx)

        lib_handle = Libdl.dlopen(lib_path, Libdl.RTLD_NOW | Libdl.RTLD_GLOBAL)

        # Update compiled structure
        if hole_idx <= length(compiled.hole_lib_paths)
            compiled.hole_lib_paths[hole_idx] = lib_path
            compiled.hole_lib_handles[hole_idx] = lib_handle
            compiled.hole_func_names[hole_idx] = hole_fname
            compiled.hole_asts[hole_idx] = deepcopy(hole_block_expr)
            compiled.guard_syms[hole_idx] = new_guards
            if hole_idx <= length(compiled.hole_inputs)
                compiled.hole_inputs[hole_idx] = params
            end
        else
            push!(compiled.hole_lib_paths, lib_path)
            push!(compiled.hole_lib_handles, lib_handle)
            push!(compiled.hole_func_names, hole_fname)
            push!(compiled.hole_asts, deepcopy(hole_block_expr))
            push!(compiled.guard_syms, new_guards)
            push!(compiled.hole_inputs, params)
        end
    end
end



"""
Create a copy of an existing `DylibCompiledCode`, duplicating the on-disk shared libraries
and loading fresh dlopen handles for independent management.
"""
function clone_dylib_compiled(base::DylibCompiledCode)
    # Duplicate main library
    new_main_path = nothing
    new_main_handle = C_NULL
    if base.main_lib_path !== nothing && isfile(base.main_lib_path)
        new_main_path = generate_dylib_path("main", base.main_func_name)
        cp(base.main_lib_path, new_main_path; force=true)
        new_main_handle = Libdl.dlopen(new_main_path, Libdl.RTLD_NOW | Libdl.RTLD_GLOBAL)
    end

    # Duplicate hole libraries
    new_hole_paths = String[]
    new_hole_handles = Ptr{Cvoid}[]
    for (idx, path) in enumerate(base.hole_lib_paths)
        if !isempty(path) && isfile(path)
            fname = idx <= length(base.hole_func_names) ? base.hole_func_names[idx] : Symbol("hole$(idx)")
            new_path = generate_dylib_path("hole$(idx)", fname)
            cp(path, new_path; force=true)
            handle = Libdl.dlopen(new_path, Libdl.RTLD_NOW | Libdl.RTLD_GLOBAL)
            push!(new_hole_paths, new_path)
            push!(new_hole_handles, handle)
        else
            push!(new_hole_paths, path)
            push!(new_hole_handles, C_NULL)
        end
    end

    # Resolve and update function pointers in the new main library
    new_hole_ptr_locs = Ptr{Cvoid}[]
    if new_main_handle != C_NULL
        for (i, hole_fname) in enumerate(base.hole_func_names)
            ptr_name = "ptr_" * string(hole_fname)
            ptr_loc = Libdl.dlsym(new_main_handle, Symbol(ptr_name); throw_error=false)
            
            if ptr_loc != C_NULL && i <= length(new_hole_handles) && new_hole_handles[i] != C_NULL
                # Find the function address from the new hole library
                func_ptr = Libdl.dlsym(new_hole_handles[i], hole_fname)
                # Write the function address to the pointer variable
                unsafe_store!(convert(Ptr{Ptr{Cvoid}}, ptr_loc), func_ptr)
            end
            push!(new_hole_ptr_locs, ptr_loc)
        end
    end

    return DylibCompiledCode(
        new_main_path,
        new_main_handle,
        base.main_func_name,
        new_hole_paths,
        new_hole_handles,
        copy(base.hole_func_names),
        deepcopy(base.hole_inputs),
        deepcopy(base.main_ast),
        deepcopy(base.hole_asts),
        deepcopy(base.guard_syms),
        base.main_hash,
        copy(base.hole_hashes),
        new_hole_ptr_locs,
        base.return_type
    )
end

"""
Clean up all dylib resources.
"""
function cleanup_dylib!(compiled::DylibCompiledCode)
    # Close main
    if compiled.main_lib_handle != C_NULL
        try
            Libdl.dlclose(compiled.main_lib_handle)
        catch e
            @warn "Failed to close main library: $e"
        end
        compiled.main_lib_handle = C_NULL
    end

    if compiled.main_lib_path !== nothing && isfile(compiled.main_lib_path)
        try
            rm(compiled.main_lib_path)
        catch e
            @warn "Failed to remove main library file: $e"
        end
    end
    compiled.main_lib_path = nothing

    # Close holes
    for (i, handle) in enumerate(compiled.hole_lib_handles)
        if handle != C_NULL
            try
                Libdl.dlclose(handle)
            catch e
                @warn "Failed to close hole $i library: $e"
            end
        end

        path = compiled.hole_lib_paths[i]
        if isfile(path)
            try
                rm(path)
            catch e
                @warn "Failed to remove hole $i library file: $e"
            end
        end
    end

    empty!(compiled.hole_lib_handles)
    empty!(compiled.hole_lib_paths)
    empty!(compiled.hole_inputs)
end
