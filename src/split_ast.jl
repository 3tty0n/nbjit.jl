module SplitAst

import Base.Iterators: flatten

"""
    collect_symbols(ex::Any) -> Set{Symbol}

Walks `ex` and returns a Set of every Symbol found.
"""
function collect_symbols(ex)
    syms = Set{Symbol}()
    _collect!(ex, syms)
    return syms
end

function _collect!(x::Symbol, syms::Set{Symbol})
    if !startswith(string(x), "@") # ignore macro
        push!(syms, x)
    end
end

function _collect!(e::Expr, syms::Set{Symbol})
    # If you prefer to skip the function-name in `call`, you can do:
    if e.head === :call && !isempty(e.args)
        # skip e.args[1] if it's the function being called
        for arg in e.args[2:end]
            _collect!(arg, syms)
        end
    else
        for arg in e.args
            _collect!(arg, syms)
        end
    end
end

# any other types—literals etc.—are ignored
function _collect!(_, _) end


function collect_hole(expr::Number)
    return nothing
end

function collect_hole(expr::Symbol)
    return nothing
end

function collect_hole(expr::LineNumberNode)
    return nothing
end

function collect_hole(expr::Expr)
    if expr.head == :macrocall
        args = expr.args
        annot = args[1]
        if annot isa Symbol && string(annot) == "@hole"
            return filter(x -> !(x isa LineNumberNode), args[2:end])
        end
    else
        return filter(x -> !(x isa LineNumberNode),
                      collect(
                          flatten(
                              filter(!isnothing,
                                     [collect_hole(e) for e in expr.args]))))

    end
end

hole_id = -1

function get_hole_id()
    global hole_id += 1
    return hole_id
end

convert_ast_with_hole(expr) = expr

"""
    conert_ast_with_hole(expr) -> expr

    convert the ast into the `holing' ast
    it converts @hole annotated expr into Expr(:hole, ...)
"""
function convert_ast_with_hole(expr::Expr)
    if expr.head == :macrocall
        args = expr.args
        annot = args[1]
        if annot isa Symbol && string(annot) == "@hole"
            newargs = collect(
                filter(
                    x -> !(x isa LineNumberNode),
                    args[2:end]
                ))
            return Expr(:hole, newargs..., get_hole_id())
        end
        return expr
    elseif expr.head == :if
        return Expr(
            :if,
            [convert_ast_with_hole(e) for e in expr.args[2]],
            [convert_ast_with_hole(e) for e in expr.args[3]]
        )
    elseif expr.head == :for || expr.head == :while || expr.head == :let
        new_args = [convert_ast_with_hole(a) for a in expr.args]
        return Expr(expr.head, new_args...)
    elseif expr.head == :block || expr.head == :return || expr.head == :break || expr.head == :continue
        new_args = [convert_ast_with_hole(a) for a in expr.args]
        return Expr(expr.head, new_args...)
    elseif expr.head == :function
        fname = expr.args[1]
        body = expr.args[2]
        new_body = convert_ast_with_hole(body)
        return Expr(:function, fname, new_body)
    else
        return Expr(expr.head, [convert_ast_with_hole(a) for a in expr.args]...)
    end
end

"""
    create_hole_block(expr) -> expr

    Create a block that contains a hole AST node
"""
function create_hole_block(expr::Expr)
    hole_id = expr.args[end]

    new_expr = expr.args[1:end-1]

    return quote
        $(new_expr...)
    end
end

"""
    split_at_hole(expr) -> expr, int

    Split ast at the place of a hole node
    When splitting the ast, it estimates the guard symbols by
    calculating free variables in `pre_args'.
    Then returns the block with a hole and hole block

    NOTE: This function only handles a single hole for backward compatibility.
    For multiple holes, use `split_at_holes`.
"""
function split_at_hole(block::Expr)
    @assert block.head in (:block, :toplevel, :begin) "Expected :block, :toplevel, or :begin, got: $(block.head)"

    # locate the hole
    idx = findfirst(x -> isa(x,Expr) && x.head === :hole, block.args)
    if idx === nothing
        error("no hole found in: $block")
    end

    hole_count = count(x -> isa(x,Expr) && x.head === :hole, block.args)
    if hole_count != 1
        error("expected exactly one hole, got $hole_count. Use split_at_holes for multiple holes.")
    end

    # slice into before / hole / after
    pre_args  = block.args[1:idx-1]
    hole_expr = block.args[idx]
    post_args = block.args[idx+1:end]

    syms_in_pre = collect(flatten([collect_symbols(a) for a in pre_args]))
    syms_in_hole = collect(flatten([collect_symbols(a) for a in hole_expr.args]))
    guard_syms = unique(vcat(syms_in_pre, syms_in_hole))

    block.args[idx] = Expr(:hole, guard_syms)
    hole_block = create_hole_block(hole_expr)

    return block, hole_block
end

"""
    split_at_holes(expr) -> [(expr, hole_block, guard_syms)]

    Split AST at all hole nodes, returning a list of results.
    Each result is a tuple of (modified_block, hole_block, guard_symbols).

    This function handles multiple holes by processing them in order,
    keeping track of symbols defined before each hole for guard calculation.
"""
function split_at_holes(block::Expr)
    @assert block.head in (:block, :toplevel, :begin) "Expected :block, :toplevel, or :begin, got: $(block.head)"

    # Find all hole indices
    hole_indices = findall(x -> isa(x, Expr) && x.head === :hole, block.args)

    if isempty(hole_indices)
        error("no holes found in: $block")
    end

    results = []

    for idx in hole_indices
        # Get symbols defined before this hole
        pre_args = block.args[1:idx-1]
        hole_expr = block.args[idx]

        # Collect symbols from before the hole and in the hole
        syms_in_pre = collect(flatten([collect_symbols(a) for a in pre_args]))
        syms_in_hole = collect(flatten([collect_symbols(a) for a in hole_expr.args]))
        guard_syms = unique(vcat(syms_in_pre, syms_in_hole))

        # Create the hole block
        hole_block = create_hole_block(hole_expr)

        # Create a copy of the block with this hole replaced by guard info
        modified_block = copy(block)
        modified_block.args[idx] = Expr(:hole, guard_syms)

        push!(results, (modified_block, hole_block, guard_syms))
    end

    return results
end

"""
    validate_ast_for_splitting(expr) -> Bool

    Validates that an AST is suitable for splitting:
    - Contains at least one hole
    - Holes are properly formed
    - No nested holes (holes within holes)
"""
function validate_ast_for_splitting(block::Expr)
    if !(block.head in (:block, :toplevel, :begin))
        return false, "Block must have head :block, :toplevel, or :begin, got: $(block.head)"
    end

    # Check for holes
    hole_count = count(x -> isa(x, Expr) && x.head === :hole, block.args)
    if hole_count == 0
        return false, "No holes found in block"
    end

    # Check for nested holes (not supported)
    for arg in block.args
        if isa(arg, Expr) && arg.head === :hole
            for inner_arg in arg.args
                if isa(inner_arg, Expr) && contains_hole(inner_arg)
                    return false, "Nested holes are not supported"
                end
            end
        end
    end

    return true, "Valid"
end

"""
    contains_hole(expr) -> Bool

    Recursively checks if an expression contains a hole node.
"""
function contains_hole(expr::Expr)
    if expr.head === :hole
        return true
    end
    for arg in expr.args
        if isa(arg, Expr) && contains_hole(arg)
            return true
        end
    end
    return false
end

contains_hole(::Any) = false

end
