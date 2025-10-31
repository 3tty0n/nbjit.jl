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
    elseif expr isa Expr
        new_args = [propagate_constants(arg, unfolded_vars, env)
                    for arg in expr.args]
        return Expr(expr.head, new_args...)
    else
        return expr
    end
end

function _can_fold(expr, unfolded_vars)
    # Returns true if expr is NOT in unfolded_vars (i.e., it can be folded)
    # Returns false if expr IS in unfolded_vars (i.e., it should remain dynamic)
    for unfolded_expr in unfolded_vars
        if unfolded_expr == expr
            return false  # expr is in unfolded_vars, so it CANNOT be folded
        end
    end
    return true  # expr is not in unfolded_vars, so it CAN be folded
end

function can_fold(expr, unfolded_vars, env)
    # Check if the expression can be folded (i.e., it's not in unfolded_vars)
    # Also check if it's actually in the environment (for symbols)
    if expr isa Symbol
        return _can_fold(expr, unfolded_vars) && haskey(env, expr)
    else
        return _can_fold(expr, unfolded_vars)
    end
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

    # Recursively evaluate operands
    lhs_eval = partial_evaluate(lhs, unfolded_vars, env)
    rhs_eval = partial_evaluate(rhs, unfolded_vars, env)

    # If both operands are constants, evaluate at compile time
    if is_constant(lhs_eval) && is_constant(rhs_eval)
        try
            return evaluate_binary(op, lhs_eval, rhs_eval)
        catch
            return Expr(:call, op, lhs_eval, rhs_eval)
        end
    else
        # Return expression with evaluated operands
        return Expr(:call, op, lhs_eval, rhs_eval)
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
            return
        else
            return expr
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
    elseif head == :for
        # For loop: for <iter_spec> <body> end
        # args[1] is the iteration specification (e.g., i = 1:10)
        # args[2] is the loop body
        iter_spec = expr.args[1]
        body = expr.args[2]

        # Create a new environment for the loop scope
        inner_env = copy(env)

        # Try to evaluate the iteration specification
        if iter_spec isa Expr && iter_spec.head == :(=)
            iter_var = iter_spec.args[1]
            iter_range = partial_evaluate(iter_spec.args[2], unfolded_vars, env)

            # Check if we can fully evaluate the range at compile time
            if is_constant(iter_range) || (iter_range isa Expr && iter_range.head == :call && iter_range.args[1] == :(:))
                # Try to unroll if the range is known and small
                if iter_range isa Expr && iter_range.args[1] == :(:) &&
                   all(is_constant, iter_range.args[2:end])
                    # Evaluate the range
                    try
                        start_val = iter_range.args[2]
                        end_val = iter_range.args[3]
                        if is_constant(start_val) && is_constant(end_val)
                            range_vals = start_val:end_val
                            # Only unroll small loops (max 10 iterations)
                            if length(range_vals) <= 10
                                unrolled = []
                                for val in range_vals
                                    loop_env = copy(inner_env)
                                    loop_env[iter_var] = val
                                    unrolled_body = partial_evaluate(body, unfolded_vars, loop_env)
                                    push!(unrolled, unrolled_body)
                                end
                                return Expr(:block, unrolled...)
                            end
                        end
                    catch
                        # Fall through to regular handling
                    end
                end
            end

            # If we can't unroll, just propagate constants through the body
            new_iter_spec = Expr(:(=), iter_var, iter_range)
            new_body = partial_evaluate(body, unfolded_vars, inner_env)
            return Expr(:for, new_iter_spec, new_body)
        else
            # Unknown iteration format, process conservatively
            new_args = [partial_evaluate(a, unfolded_vars, inner_env) for a in expr.args]
            return Expr(:for, new_args...)
        end
    elseif head == :while
        # While loop: while <condition> <body> end
        cond = expr.args[1]
        body = expr.args[2]

        # Create a new environment for the loop scope
        inner_env = copy(env)

        # Evaluate the condition
        new_cond = partial_evaluate(cond, unfolded_vars, env)

        # Check if the condition is a constant
        if new_cond === false
            # Loop never executes
            return nothing
        elseif new_cond === true
            # Infinite loop - keep as is but optimize body
            new_body = partial_evaluate(body, unfolded_vars, inner_env)
            return Expr(:while, true, new_body)
        else
            # Condition is dynamic, optimize the body
            new_body = partial_evaluate(body, unfolded_vars, inner_env)
            return Expr(:while, new_cond, new_body)
        end
    elseif head == :let
        # Let binding: let <bindings> <body> end
        # Create a new environment for the let scope
        inner_env = copy(env)
        new_args = [partial_evaluate(a, unfolded_vars, inner_env)
                    for a in expr.args]
        return Expr(:let, new_args...)
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
