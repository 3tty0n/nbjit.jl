"""
Automatic hole detection via statement-level diff.

When a cell is re-executed without explicit @hole markers, this module diffs the
new code against the previous version at the statement level. Unchanged statements
become the "main" block (reused), changed statements become "holes" (recompiled).

Uses LCS (Longest Common Subsequence) on statement hashes to handle insertions
and deletions, not just in-place edits.
"""

using .SplitAst: collect_symbols

"""
    has_hole_markers(code) -> Bool

Check if the expression contains any @hole macrocall annotations.
"""
function has_hole_markers(code::Expr)
    if code.head == :macrocall && length(code.args) >= 1
        annot = code.args[1]
        if annot isa Symbol && string(annot) == "@hole"
            return true
        end
    end
    return any(has_hole_markers, code.args)
end

has_hole_markers(::Any) = false

"""
    extract_statements(code::Expr) -> Vector{Any}

Extract top-level statements from a block expression, filtering out LineNumberNodes.
"""
function extract_statements(code::Expr)
    if code.head in (:block, :toplevel, :begin)
        return [s for s in code.args if !(s isa LineNumberNode)]
    else
        return Any[code]
    end
end

"""
    stmt_hash(stmt) -> UInt64

Compute a content-based hash for a statement, ignoring line numbers.
"""
function stmt_hash(stmt)
    compute_ast_hash(stmt isa Expr ? stmt : Expr(:block, stmt))
end

"""
    lcs_indices(old_hashes, new_hashes) -> (Set{Int}, Set{Int})

Compute the Longest Common Subsequence of two hash sequences.
Returns (matched_old_indices, matched_new_indices) — the indices in each
sequence that participate in the LCS.
"""
function lcs_indices(old_hashes::Vector{UInt64}, new_hashes::Vector{UInt64})
    m = length(old_hashes)
    n = length(new_hashes)

    # DP table: dp[i+1, j+1] = LCS length of old[1:i], new[1:j]
    # Row 0 and column 0 are the empty-sequence base cases (all zeros).
    dp = zeros(Int, m + 1, n + 1)
    for i in 1:m
        for j in 1:n
            if old_hashes[i] == new_hashes[j]
                dp[i+1, j+1] = dp[i, j] + 1
            else
                dp[i+1, j+1] = max(dp[i, j+1], dp[i+1, j])
            end
        end
    end

    # Backtrack to find matched indices
    matched_old = Set{Int}()
    matched_new = Set{Int}()
    i, j = m, n
    while i > 0 && j > 0
        if old_hashes[i] == new_hashes[j]
            push!(matched_old, i)
            push!(matched_new, j)
            i -= 1
            j -= 1
        elseif dp[i, j+1] >= dp[i+1, j]
            i -= 1
        else
            j -= 1
        end
    end

    return (matched_old, matched_new)
end

"""
    collect_defined_symbols(stmt) -> Set{Symbol}

Collect symbols that are assigned/defined in a single statement.
Handles: assignment, compound assignment, function definition, for loop variable.
"""
function collect_defined_symbols(stmt)
    defs = Set{Symbol}()
    _collect_defs_stmt!(stmt, defs)
    return defs
end

function _collect_defs_stmt!(expr::Expr, defs::Set{Symbol})
    if expr.head == :(=) || expr.head in (:+=, :-=, :*=, :/=, :^=, :%=)
        lhs = expr.args[1]
        if lhs isa Symbol
            push!(defs, lhs)
        elseif lhs isa Expr && lhs.head == :call
            push!(defs, lhs.args[1])
        elseif lhs isa Expr && lhs.head == :tuple
            for a in lhs.args
                a isa Symbol && push!(defs, a)
            end
        end
    elseif expr.head == :function && length(expr.args) >= 1
        call_expr = expr.args[1]
        if call_expr isa Expr && call_expr.head == :call
            push!(defs, call_expr.args[1])
        elseif call_expr isa Symbol
            push!(defs, call_expr)
        end
    elseif expr.head == :for && length(expr.args) >= 1
        iter_spec = expr.args[1]
        if iter_spec isa Expr && iter_spec.head == :(=) && iter_spec.args[1] isa Symbol
            push!(defs, iter_spec.args[1])
        end
    end
end

_collect_defs_stmt!(::Any, ::Set{Symbol}) = nothing

"""
    auto_prepare_split(old_code::Union{Nothing, Expr}, new_code::Expr)
        -> (main_ast::Expr, hole_blocks::Vector{Expr}, guard_syms::Vector{Vector{Symbol}})

Automatically detect changed statements between old and new versions of a cell
and produce the same output format as `prepare_split`.

- If `old_code` is `nothing` (first execution): returns the full code as main with 0 holes.
- If all statements changed: returns the full code as main with 0 holes (full recompile).
- Otherwise: unchanged statements → main, changed statements → holes.
"""
function auto_prepare_split(old_code::Union{Nothing, Expr}, new_code::Expr)
    new_stmts = extract_statements(new_code)

    if isempty(new_stmts)
        return (Expr(:block), Expr[], Vector{Symbol}[])
    end

    # First execution: no previous version, compile everything as main
    if old_code === nothing
        main_ast = Expr(:block, [deepcopy(s) for s in new_stmts]...)
        return (main_ast, Expr[], Vector{Symbol}[])
    end

    old_stmts = extract_statements(old_code)
    old_hashes = UInt64[stmt_hash(s) for s in old_stmts]
    new_hashes = UInt64[stmt_hash(s) for s in new_stmts]

    # LCS to find matched (unchanged) statements
    _, matched_new = lcs_indices(old_hashes, new_hashes)

    # If nothing matched (complete rewrite) or everything matched (no change),
    # return as main with 0 holes
    if isempty(matched_new)
        main_ast = Expr(:block, [deepcopy(s) for s in new_stmts]...)
        return (main_ast, Expr[], Vector{Symbol}[])
    end
    if length(matched_new) == length(new_stmts)
        # No changes — everything matches
        main_ast = Expr(:block, [deepcopy(s) for s in new_stmts]...)
        return (main_ast, Expr[], Vector{Symbol}[])
    end

    # Build main_ast with hole placeholders, and collect hole blocks
    main_args = Any[]
    hole_blocks = Expr[]
    guard_syms_list = Vector{Symbol}[]
    defined_so_far = Set{Symbol}()
    hole_count = 0

    for (i, stmt) in enumerate(new_stmts)
        if i in matched_new
            # Unchanged statement → main block
            push!(main_args, deepcopy(stmt))
            union!(defined_so_far, collect_defined_symbols(stmt))
        else
            # Changed/new statement → hole
            hole_count += 1
            push!(main_args, Expr(:hole, hole_count))

            hole_block = Expr(:block, deepcopy(stmt))
            push!(hole_blocks, hole_block)

            # Guard symbols: all symbols from statements before this hole,
            # plus symbols referenced in the hole itself.
            # This matches the convention in split_ast.jl.
            syms_before = collect(defined_so_far)
            syms_in_hole = collect(collect_symbols(stmt))
            guards = unique(vcat(syms_before, syms_in_hole))
            push!(guard_syms_list, guards)

            # Track definitions from the hole too
            union!(defined_so_far, collect_defined_symbols(stmt))
        end
    end

    main_ast = Expr(:block, main_args...)
    return (main_ast, hole_blocks, guard_syms_list)
end
