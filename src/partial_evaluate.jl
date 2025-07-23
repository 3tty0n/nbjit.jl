function is_constant(expr)
    return expr isa Number || expr == :(true) || expr == :(false)
end

function partial_evaluate(expr, unfolded_vars, env)
    if is_constant(expr)
        return expr
    elseif expr.head in [:+, :-, :*, :/, :<, :>, :<=, :>=]
        return partial_evaluate_binary(expr, unfolded_vars, env)
    end
end

function partial_evaluate_binary(expr, unfolded_vars, env)
    op = expr.head
    lhs = expr.args[2]
    rhs = expr.args[3]
    if !(lhs in unfolded_vars) && !(rhs in unfolded_vars)
        lhs = env[lhs]
        rhs = env[lhs]
        return lhs + rhs
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

function partial_evaluate_stmt(expr, unfolded_vars, env)
    op = expr.head
    lhs = expr.args[2]
    rhs = expr.args[3]
    if op == :(=)
        env[lhs] = rhs
        if !(lhs in unfolded_vars)
            return nothing
        else
            return Expr(:call, :(=), lhs, rhs)
        end
    elseif op == :(+=)
        env[lhs] += rhs
        if !(lhs in unfolded_vars)
            return nothing
        else
            return Expr(:call, :(=), lhs, rhs)
        end
    elseif op == :(-=)
        env[lhs] -= rhs
        if !(lhs in unfolded_vars)
            return nothing
        else
            return Expr(:call, :(=), lhs, rhs)
        end
    end
end
