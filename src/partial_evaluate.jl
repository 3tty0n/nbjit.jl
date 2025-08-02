include("./parse_annot.jl")

function is_constant(expr)
    return expr isa Number || expr == :(true) || expr == :(false)
end

function propagate_constants(expr, unfolded_vars, env)
    if expr isa Symbol
        if haskey(env, expr)
            return env[expr]
        else
            return expr
        end
    elseif expr isa Symbol
        new_args = [propagate_constants(arg, unfolded_vars, env)
                    for arg in expr.args]
        return Expr(expr.head, new_args...)
    else
        return expr
    end
end

function _can_fold(expr, unfolded_vars)
    for unfolded_expr in unfolded_vars
        if unfolded_expr == expr
            return true
        else
            return _can_fold(expr, unfolded_expr.arg)
        end
    end
    return false
end

function can_fold(expr, unfolded_vars, env)
    return _can_fold(expr, unfolded_vars)
end

function evaluate_binary(op, lhs, rhs)
    if op == :+
        return lhs + rhs
    elseif op == :-
        return lhs - rhs
    elseif op == :*
        return lhs * rhs
    elseif op == :/
        return lhs / rhs
    elseif op == :<
        return lhs < rhs
    elseif op == :>
        return lhs > rhs
    elseif op == :<=
        return lhs <= rhs
    elseif op == :>=
        return lhs >= rhs
    else
        error("unsupported op ", op)
    end
end

function partial_evaluate_binary(expr, unfolded_vars, env)
    op = expr.args[1]
    lhs = expr.args[2]
    rhs = expr.args[3]

    if can_fold(lhs, unfolded_vars, env) && can_fold(rhs, unfolded_vars, env)
        lhs = get(env, lhs, lhs)
        rhs = get(env, rhs, rhs)
        try
            return evaluate_binary(op, lhs, rhs)
        catch
            return Expr(:call, op, lhs, rhs)
        end
    elseif !(lhs in unfolded_vars)
        lhs = env[lhs]
        return Expr(:call, op, lhs, rhs)
    elseif !(rhs in unfolded_vars)
        rhs = env[rhs]
        return Expr(:call, op, lhs, rhs)
    else
        return expr
    end
end

function partial_evaluate(expr, unfolded_vars, env)
    if expr isa LineNumberNode
        return expr
    end

    if is_constant(expr) || expr isa QuoteNode
        return expr
    end

    if expr isa Symbol
        if can_fold(expr, unfolded_vars, env)
            return get(env, expr, expr)
        else
            return expr
        end
    end

    head = expr.head

    if head == :macrocall
        args = expr.args
        annot = args[1]
        if string(annot) == "@hole"
            return Expr(:hole, args[2:end])
        end
    elseif head in [:+, :-, :*, :/, :<, :>, :<=, :>=]
        return partial_evaluate_binary(expr, unfolded_vars, env)
    elseif head == :&& || head == :||
        lhs = partial_evaluate(expr.args[1], unfolded_vars, env)
        rhs = partial_evaluate(expr.args[2], unfolded_vars, env)
        if expr.head == :&&
            return lhs === false ? false :
                   lhs === true  ? rhs   :
                   rhs === false ? false :
                   Expr(:&&, lhs, rhs)
        else  # :||
            return lhs === true  ? true  :
                   lhs === false ? rhs   :
                   rhs === true  ? true  :
                   Expr(:||, lhs, rhs)
        end
    elseif head == :(=) || head in (:+=, :-=, :*=, :/=, :^=, :%=) # assignment
        lhs_sym = expr.args[1]           # note: index 1 in Julia’s Expr
        rhs_val = partial_evaluate(expr.args[2], unfolded_vars, env)
        op_head = head

        if op_head == :(=)
            env[lhs_sym] = rhs_val
        else
            # expand a ⊕= b  →  a = a ⊕ b
            base_op = Symbol(String(op_head)[1:end-1])   # strip '='
            env[lhs_sym] = Base._apply(base_op, get(env, lhs_sym, lhs_sym), rhs_val)
        end

        return lhs_sym ∈ unfolded_vars ? Expr(:call, :(=), lhs_sym, rhs_val) : nothing
    elseif expr.head == :tuple || expr.head == :vect
        elems = [partial_evaluate(a, unfolded_vars, env) for a in expr.args]
        if all(is_constant, elems)
            return head == :tuple ? tuple(elems...) : collect(elems)
        end
        return Expr(head, elems...)
    elseif expr.head == :call
        args = expr.args

        if args[1] in [:+, :-, :*, :/, :<, :>, :<=, :>=]
            return partial_evaluate_binary(expr, unfolded_vars, env)
        end

        folded_args = [propagate_constants(arg, unfolded_vars, env) for arg in expr.args]
        return Expr(:call, folded_args...)
    elseif head == :function
        # Get function name and arguments
        fname = expr.args[1]
        body = expr.args[2]
        # Create a fresh map for each function scope
        new_env = copy(env)
        new_body = partial_evaluate(body, unfolded_vars, new_env)
        return Expr(:function, fname, new_body)
    elseif head == :block
        args = [partial_evaluate(arg, unfolded_vars, env) for arg in expr.args]
        return Expr(expr.head, args...)
    elseif head == :if
        cond = expr.args[1]
        then = expr.args[2]
        if length(expr.args) == 2 # if-then
            if can_fold(cond, unfolded_vars, env)
                if eval(cond)
                    return partial_evaluate(then, unfolded_vars, env)
                end
            else
                return Expr(:if, partial_evaluate(then, unfolded_vars, env))
            end
        else # if-then-else
            els = expr.args[3]
            if can_fold(cond, unfolded_vars, env)
                cond = partial_evaluate(cond, unfolded_vars, env)
                if eval(cond)
                    return partial_evaluate(then, unfolded_vars, env)
                else
                    return partial_evaluate(els, unfolded_vars, env)
                end
            else
                return Expr(
                    :if,
                    partial_evaluate(then, unfolded_vars, env),
                    partial_evaluate(els, unfolded_vars, env))
            end
        end
    elseif head == :for || head == :while || head == :let
        # TODO: make it work
        inner_env = copy(env)
        new_args = [partial_evaluate(a, unfolded_vars, inner_env)
                    for a in expr.args]
        return Expr(head, new_args...)
    elseif head == :return || head == :break || head == :continue
        new_args = [partial_evaluate(a, unfolded_vars, env) for a in expr.args]
        return Expr(head, new_args...)
    else # generic falback
        new_args = [partial_evaluate(a, unfolded_vars, env) for a in expr.args]
        return Expr(head, new_args...)
    end
end

function partial_evaluate_and_make_entry(code)
    env = Dict()
    unfolded_vars = []
    parse_annot(code, unfolded_vars)
    unfolded_vars = filter(x -> !isnothing(x) && !isa(x, LineNumberNode),
                           unfolded_vars)

    folded_ast = partial_evaluate(code, unfolded_vars, env)
    fname = Symbol("func_0")
    func_expr = quote
        function $(fname)($(unfolded_vars...))
            $(folded_ast)
        end
    end
    return func_expr, fname
end

using Test

function equalto(expr1, expr2)
    @test Base.remove_linenums!(expr1) == Base.remove_linenums!(expr2)
end

env = Dict(:x => 42)
#equalto(partial_evaluate(:(if x < 1 return x else 2 end), [], env), :(begin 2 end))
#equalto(partial_evaluate(:(f(x, y)), [:y], env), :(f(42, y)))
# println(partial_evaluate(:(for x in [1,2,3] y = x + 1 end), [], env))
#equalto(partial_evaluate(:(function f(x, y) return x + y end), [:y], env), :(function f(x, y) return 42 + y end))

println(partial_evaluate(
    :(@hole y = 2),
    [],
    env
))
