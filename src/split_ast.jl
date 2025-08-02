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

convert_ast_with_hole(expr) = expr

"""
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
            return Expr(:hole, newargs...)
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
    split_at_hole(expr) -> expr, expr

    Split ast at the place of a hole node
    When splitting the ast, it estimates the guard symbols by
    calculating free variables in `pre_args'.
"""
function split_at_hole(block::Expr)
    @assert block.head in (:block, :toplevel, :begin)
    # locate the hole
    idx = findfirst(x -> isa(x,Expr) && x.head === :hole, block.args)
    if idx === nothing
        error("no hole found in: $block")
    elseif count(x -> isa(x,Expr) && x.head === :hole, block.args) != 1
        error("expected exactly one hole, got multiple")
    end

    # slice into before / hole / after
    pre_args  = block.args[1:idx-1]
    hole_expr = block.args[idx]
    post_args = block.args[idx+1:end]


    syms_in_pre = collect(flatten([collect_symbols(a) for a in pre_args]))
    syms_in_hole = collect(flatten([collect_symbols(a) for a in hole_expr.args]))
    guard_syms = vcat(syms_in_pre, syms_in_hole)

    hole_expr = Expr(:hole, guard_syms)

    return block, hole_expr
end

end

function test()
    println(SplitAst.collect_symbols(:(
        begin
            x = 1
            @hole y = 2
            z = x + y
        end
    )))


    println(SplitAst.collect_hole(:(
        begin
            x = 1
            @hole y = 2
            z = x + y
            begin
                @hole r = 1
                if r < 1
                    @hole z = z + r
                else
                    @hole x = 1000
                end
            end
        end
    )))

    prog = :(
        begin
            x = 1
            @hole y = 2
            z = x + y
        end
    )

    ast_with_hole = SplitAst.convert_ast_with_hole(prog)
    println(SplitAst.split_at_hole(ast_with_hole))
end

# test()
