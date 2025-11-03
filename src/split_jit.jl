"""
Split-and-compile pipeline using @hole markers, partial evaluation, and LLVM.jl.

The workflow:
  1. Convert @hole annotations into explicit :hole nodes.
  2. Split the AST at each hole, capturing guard symbols.
  3. Partially evaluate the main block and each hole block.
  4. Compile the partially evaluated blocks to LLVM IR modules via LLVM.jl.
  5. Allow selective recompilation of individual hole blocks when they change,
     without recompiling the main block.
"""

using LLVM

include("./split_ast.jl")
include("./partial_evaluate.jl")
include("./jit.jl")

mutable struct CompiledSplitCode
    main_mod::Union{Nothing, LLVM.Module}
    main_ctx::Union{Nothing, LLVM.Context}
    main_fname::Symbol
    main_inputs::Vector{Symbol}
    main_func_expr::Expr
    hole_mods::Vector{Union{Nothing, LLVM.Module}}
    hole_ctxs::Vector{Union{Nothing, LLVM.Context}}
    hole_fnames::Vector{Symbol}
    hole_inputs::Vector{Vector{Symbol}}
    hole_func_exprs::Vector{Expr}
    guard_syms::Vector{Vector{Symbol}}
    guard_values::Dict{Symbol, Any}
    main_ast::Expr
    hole_asts::Vector{Expr}
end

const LLVM_COMPILATION_CACHE = Dict{UInt64, CompiledSplitCode}()

function unique_symbols(syms::Vector{Symbol})
    seen = Set{Symbol}()
    ordered = Symbol[]
    for sym in syms
        if !(sym in seen)
            push!(ordered, sym)
            push!(seen, sym)
        end
    end
    return ordered
end

function flatten_guard_syms(guard_payload)::Vector{Symbol}
    syms = Symbol[]
    _flatten_guard_syms!(guard_payload, syms)
    return unique_symbols(syms)
end

_flatten_guard_syms!(sym::Symbol, acc::Vector{Symbol}) = push!(acc, sym)

function _flatten_guard_syms!(payload, acc::Vector{Symbol})
    for item in payload
        if item isa Symbol
            push!(acc, item)
        elseif item isa AbstractVector
            _flatten_guard_syms!(item, acc)
        end
    end
end

function strip_hole_markers(block::Expr)
    new_args = Any[]
    for arg in block.args
        if isa(arg, Expr) && arg.head == :hole
            continue
        else
            push!(new_args, deepcopy(arg))
        end
    end
    return Expr(block.head, new_args...)
end

function extract_function_expr(func_expr::Expr)
    if func_expr.head == :function
        return func_expr
    elseif func_expr.head == :block
        for arg in func_expr.args
            if arg isa Expr && arg.head == :function
                return arg
            end
        end
    end
    return nothing
end

function compile_function(func_expr::Expr, fname::Symbol)
    func_ast = extract_function_expr(func_expr)
    func_ast === nothing && error("Failed to locate function definition for $fname")
    compile_to_llvm(func_ast, fname)
end

function compute_ast_hash(ast)
    normalized = Base.remove_linenums!(deepcopy(ast))
    return hash(string(normalized))
end

"""
    prepare_split(code::Expr) -> (main_ast, hole_blocks, guard_syms)

Convert @hole annotations, validate the AST, and return the main block (with
hole placeholders), the hole blocks, and guard symbols for each hole.
"""
function prepare_split(code)
    ast_with_holes = SplitAst.convert_ast_with_hole(code)

    if !isa(ast_with_holes, Expr) || !(ast_with_holes.head in (:block, :toplevel, :begin))
        ast_with_holes = Expr(:block, ast_with_holes)
    end

    hole_count = count(x -> isa(x, Expr) && x.head === :hole, ast_with_holes.args)
    hole_count == 0 && error("No @hole markers found in code")

    is_valid, msg = SplitAst.validate_ast_for_splitting(ast_with_holes)
    is_valid || error("AST validation failed: $msg")

    if hole_count == 1
        main_block, hole_block = SplitAst.split_at_hole(ast_with_holes)
        main_ast = deepcopy(main_block)
        hole_blocks = [deepcopy(hole_block)]
        hole_expr_idx = findfirst(x -> isa(x, Expr) && x.head === :hole, main_block.args)
        guard_syms = [hole_expr_idx === nothing ? Symbol[] : flatten_guard_syms(main_block.args[hole_expr_idx].args)]
    else
        results = SplitAst.split_at_holes(ast_with_holes)
        main_ast = deepcopy(results[1][1])
        hole_blocks = [deepcopy(r[2]) for r in results]
        guard_syms = [flatten_guard_syms(r[3]) for r in results]
    end

    return main_ast, hole_blocks, guard_syms
end

"""
    split_and_compile(code::Expr) -> CompiledSplitCode

Split the input code at `@hole` annotations, partially evaluate each block, and
compile the resulting functions to LLVM modules. Returns a `CompiledSplitCode`
object that can be reused or selectively updated.
"""
function split_and_compile(code)
    main_ast, hole_blocks, guard_syms = prepare_split(code)

    clean_main_block = strip_hole_markers(main_ast)
    main_inputs = unique_symbols(reduce(vcat, guard_syms; init=Symbol[]))
    main_func_expr, main_fname = partial_evaluate_and_make_entry(clean_main_block; params=main_inputs)
    main_mod, main_ctx = compile_function(main_func_expr, main_fname)

    hole_mods = Vector{Union{Nothing, LLVM.Module}}()
    hole_ctxs = Vector{Union{Nothing, LLVM.Context}}()
    hole_fnames = Symbol[]
    hole_inputs = Vector{Vector{Symbol}}()
    hole_func_exprs = Expr[]
    hole_asts = Expr[]

    for (i, hole_block) in enumerate(hole_blocks)
        params = guard_syms[i]
        hole_block_expr = isa(hole_block, Expr) ? hole_block : Expr(:block, hole_block)
        hole_func_expr, hole_fname = partial_evaluate_and_make_entry(hole_block_expr; params=params)
        push!(hole_func_exprs, hole_func_expr)
        push!(hole_fnames, hole_fname)
        push!(hole_inputs, params)
        push!(hole_asts, deepcopy(hole_block_expr))

        func_ast = extract_function_expr(hole_func_expr)
        if func_ast === nothing
            push!(hole_mods, nothing)
            push!(hole_ctxs, nothing)
        else
            mod, ctx = compile_to_llvm(func_ast, hole_fname)
            push!(hole_mods, mod)
            push!(hole_ctxs, ctx)
        end
    end

    compiled = CompiledSplitCode(
        main_mod,
        main_ctx,
        main_fname,
        main_inputs,
        main_func_expr,
        hole_mods,
        hole_ctxs,
        hole_fnames,
        hole_inputs,
        hole_func_exprs,
        guard_syms,
        Dict{Symbol, Any}(),
        main_ast,
        hole_asts
    )

    code_hash = compute_ast_hash(code)
    LLVM_COMPILATION_CACHE[code_hash] = compiled
    return compiled
end

"""
    check_guards(compiled, env) -> Bool

Verify that guard symbols have not changed relative to the cached values.
"""
function check_guards(compiled::CompiledSplitCode, env::Dict{Symbol, Any})
    guard_list = unique_symbols(reduce(vcat, compiled.guard_syms; init=Symbol[]))
    if isempty(compiled.guard_values)
        for sym in guard_list
            if haskey(env, sym)
                compiled.guard_values[sym] = env[sym]
            end
        end
        return true
    end

    for sym in guard_list
        old_val = get(compiled.guard_values, sym, nothing)
        new_val = get(env, sym, nothing)
        if old_val !== new_val
            return false
        end
    end
    return true
end

"""
    recompile_hole!(compiled, hole_index, new_code)

Recompile only the specified hole block. Guard symbols must remain unchanged.
"""
function recompile_hole!(compiled::CompiledSplitCode, hole_index::Int, new_code)
    @assert 1 <= hole_index <= length(compiled.hole_mods) "Invalid hole index $hole_index"

    new_block = new_code isa Expr && new_code.head == :block ? new_code : Expr(:block, new_code)
    existing_guards = compiled.guard_syms[hole_index]

    new_syms = SplitAst.collect_symbols(new_block)
    if !all(sym -> sym in existing_guards, new_syms)
        missing = [sym for sym in new_syms if !(sym in existing_guards)]
        error("Guard symbols changed ($missing); full recompilation required.")
    end

    hole_func_expr, hole_fname = partial_evaluate_and_make_entry(new_block; params=existing_guards)
    compiled.hole_func_exprs[hole_index] = hole_func_expr
    compiled.hole_fnames[hole_index] = hole_fname
    compiled.hole_asts[hole_index] = deepcopy(new_block)

    func_ast = extract_function_expr(hole_func_expr)
    if func_ast === nothing
        compiled.hole_mods[hole_index] = nothing
        compiled.hole_ctxs[hole_index] = nothing
    else
        mod, ctx = compile_to_llvm(func_ast, hole_fname)
        compiled.hole_mods[hole_index] = mod
        compiled.hole_ctxs[hole_index] = ctx
    end

    empty!(compiled.guard_values)
    return compiled
end
