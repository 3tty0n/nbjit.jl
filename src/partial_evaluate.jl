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
    for unfolded_expr in unfolded_vars
        if unfolded_expr == expr
            return false
        end
    end
    return true
end

function can_fold(expr, unfolded_vars, env)
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
    elseif op == :%
        return lhs % rhs
    elseif op == :<
        return lhs < rhs
    elseif op == :>
        return lhs > rhs
    elseif op == :<=
        return lhs <= rhs
    elseif op == :>=
        return lhs >= rhs
    elseif op == :(==)
        return lhs == rhs
    elseif op == :(!=)
        return lhs != rhs
    else
        error("unsupported op ", op)
    end
end

function partial_evaluate_binary(expr, unfolded_vars, env)
    op = expr.args[1]

    # Handle variadic operations (e.g., x + a + b is represented as (:call, :+, :x, :a, :b))
    if length(expr.args) > 3
        # Evaluate all operands
        operands = [partial_evaluate(arg, unfolded_vars, env) for arg in expr.args[2:end]]

        # If all operands are constants, evaluate the whole expression
        if all(is_constant, operands)
            try
                # Fold left: ((x op y) op z) op ...
                result = operands[1]
                for operand in operands[2:end]
                    result = evaluate_binary(op, result, operand)
                end
                return result
            catch
                return Expr(:call, op, operands...)
            end
        else
            return Expr(:call, op, operands...)
        end
    else
        # Binary operation with exactly 2 operands
        lhs = expr.args[2]
        rhs = expr.args[3]

        lhs_eval = partial_evaluate(lhs, unfolded_vars, env)
        rhs_eval = partial_evaluate(rhs, unfolded_vars, env)

        if is_constant(lhs_eval) && is_constant(rhs_eval)
            try
                return evaluate_binary(op, lhs_eval, rhs_eval)
            catch
                return Expr(:call, op, lhs_eval, rhs_eval)
            end
        else
            return Expr(:call, op, lhs_eval, rhs_eval)
        end
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
    elseif head == :hole
        return expr
    elseif head in [:+, :-, :*, :/, :%, :<, :>, :<=, :>=, :(==), :(!=)]
        return partial_evaluate_binary(expr, unfolded_vars, env)
    elseif head == :&& || head == :||
        lhs = partial_evaluate(expr.args[1], unfolded_vars, env)
        rhs = partial_evaluate(expr.args[2], unfolded_vars, env)
        if expr.head == :&&
            return lhs === false ? false :
                   lhs === true  ? rhs   :
                   rhs === false ? false :
                   Expr(:&&, lhs, rhs)
        else
            return lhs === true  ? true  :
                   lhs === false ? rhs   :
                   rhs === true  ? true  :
                   Expr(:||, lhs, rhs)
        end
    elseif head == :(=) || head in (:+=, :-=, :*=, :/=, :^=, :%=)
        lhs_sym = expr.args[1]
        rhs_val = partial_evaluate(expr.args[2], unfolded_vars, env)
        op_head = head

        if op_head == :(=)
            env[lhs_sym] = rhs_val
        else
            base_op = Symbol(String(op_head)[1:end-1])
            env[lhs_sym] = Base._apply(base_op, get(env, lhs_sym, lhs_sym), rhs_val)
        end

        return lhs_sym ∈ unfolded_vars ? Expr(:(=), lhs_sym, rhs_val) : nothing
    elseif expr.head == :tuple || expr.head == :vect
        elems = [partial_evaluate(a, unfolded_vars, env) for a in expr.args]
        if all(is_constant, elems)
            return expr.head == :tuple ? tuple(elems...) : collect(elems)
        end
        return Expr(expr.head, elems...)
    elseif expr.head == :call
        args = expr.args

        if args[1] in [:+, :-, :*, :/, :%, :<, :>, :<=, :>=, :(==), :(!=)]
            return partial_evaluate_binary(expr, unfolded_vars, env)
        end

        folded_args = [propagate_constants(arg, unfolded_vars, env) for arg in expr.args]
        return Expr(:call, folded_args...)
    elseif head == :function
        fname = expr.args[1]
        body = expr.args[2]
        new_env = copy(env)
        new_body = partial_evaluate(body, unfolded_vars, new_env)
        return Expr(:function, fname, new_body)
    elseif head == :block
        args = [partial_evaluate(arg, unfolded_vars, env) for arg in expr.args]
        filtered = [arg for arg in args if !(arg === nothing)]
        return Expr(expr.head, filtered...)
    elseif head == :if
        cond = expr.args[1]
        then = expr.args[2]

        eval_cond = partial_evaluate(cond, unfolded_vars, env)

        if length(expr.args) == 2
            if is_constant(eval_cond)
                if eval_cond == true || eval_cond == :(true)
                    return partial_evaluate(then, unfolded_vars, env)
                else
                    return nothing
                end
            else
                eval_then = partial_evaluate(then, unfolded_vars, env)
                return Expr(:if, eval_cond, eval_then)
            end
        else
            els = expr.args[3]
            if is_constant(eval_cond)
                if eval_cond == true || eval_cond == :(true)
                    return partial_evaluate(then, unfolded_vars, env)
                else
                    return partial_evaluate(els, unfolded_vars, env)
                end
            else
                eval_then = partial_evaluate(then, unfolded_vars, env)
                eval_els = partial_evaluate(els, unfolded_vars, env)
                return Expr(:if, eval_cond, eval_then, eval_els)
            end
        end
    elseif head == :for
        iter_spec = expr.args[1]
        body = expr.args[2]
        inner_env = copy(env)

        if iter_spec isa Expr && iter_spec.head == :(=)
            iter_var = iter_spec.args[1]
            iter_range = partial_evaluate(iter_spec.args[2], unfolded_vars, env)

            if is_constant(iter_range) || (iter_range isa Expr && iter_range.head == :call && iter_range.args[1] == :(:))
                if iter_range isa Expr && iter_range.args[1] == :(:) &&
                   all(is_constant, iter_range.args[2:end])
                    try
                        start_val = iter_range.args[2]
                        end_val = iter_range.args[3]
                        if is_constant(start_val) && is_constant(end_val)
                            range_vals = start_val:end_val
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
                    end
                end
            end

            new_iter_spec = Expr(:(=), iter_var, iter_range)
            new_body = partial_evaluate(body, unfolded_vars, inner_env)
            return Expr(:for, new_iter_spec, new_body)
        else
            new_args = [partial_evaluate(a, unfolded_vars, inner_env) for a in expr.args]
            return Expr(:for, new_args...)
        end
    elseif head == :while
        cond = expr.args[1]
        body = expr.args[2]
        inner_env = copy(env)
        new_cond = partial_evaluate(cond, unfolded_vars, env)

        if new_cond === false
            return nothing
        elseif new_cond === true
            new_body = partial_evaluate(body, unfolded_vars, inner_env)
            return Expr(:while, true, new_body)
        else
            new_body = partial_evaluate(body, unfolded_vars, inner_env)
            return Expr(:while, new_cond, new_body)
        end
    elseif head == :let
        inner_env = copy(env)
        new_args = [partial_evaluate(a, unfolded_vars, inner_env)
                    for a in expr.args]
        return Expr(:let, new_args...)
    elseif head == :return || head == :break || head == :continue
        new_args = [partial_evaluate(a, unfolded_vars, env) for a in expr.args]
        return Expr(head, new_args...)
    else
        new_args = [partial_evaluate(a, unfolded_vars, env) for a in expr.args]
        return Expr(head, new_args...)
    end
end

const _FUNC_COUNTER = Ref(0)

function fresh_func_name()
    _FUNC_COUNTER[] += 1
    return Symbol("func_" * string(_FUNC_COUNTER[]))
end

function ensure_block(expr)
    if expr isa Expr && expr.head == :block
        return expr
    elseif expr === nothing
        return Expr(:block)
    else
        return Expr(:block, expr)
    end
end

function find_last_expression(code::Expr)
    """
    Find the last meaningful expression in the code block.
    Returns the expression itself if it's not an assignment,
    or the assigned variable if it's an assignment.
    """
    if code.head != :block
        return code
    end

    # Find the last non-LineNumberNode statement
    for stmt in reverse(code.args)
        if stmt isa LineNumberNode
            continue
        elseif stmt isa Expr && stmt.head == :block
            # Recurse into nested blocks
            return find_last_expression(stmt)
        elseif stmt isa Expr && stmt.head == :(=) && stmt.args[1] isa Symbol
            # Assignment: return the variable name
            return stmt.args[1]
        else
            # Any other expression: return it as is
            return stmt
        end
    end
    return nothing
end

function partial_evaluate_and_make_entry(code; params::Vector{Symbol}=Symbol[], fname::Union{Nothing,Symbol}=nothing)
    env = Dict{Symbol,Any}()
    unfolded_vars = copy(params)

    parse_annot(code, unfolded_vars)
    filtered = Symbol[]
    seen = Set{Symbol}()
    for item in unfolded_vars
        if item isa Symbol && !(item in seen)
            push!(filtered, item)
            push!(seen, item)
        end
    end
    unfolded_vars = filtered

    # Find the last expression before partial evaluation
    last_expr = find_last_expression(code)

    folded_ast = partial_evaluate(code, unfolded_vars, env)
    folded_block = ensure_block(folded_ast)

    # Add explicit return statement for the last expression
    if last_expr !== nothing
        if last_expr isa Symbol
            # It's a variable - return its value (folded or not)
            return_val = get(env, last_expr, last_expr)
        else
            # It's an expression - evaluate it and append
            return_val = partial_evaluate(last_expr, unfolded_vars, env)
        end

        # Only add return if it's not already there
        # Remove the last expression if it's the same as what we want to return
        if !isempty(folded_block.args)
            last_stmt = folded_block.args[end]
            # Check if the last statement is LineNumberNode
            while !isempty(folded_block.args) && folded_block.args[end] isa LineNumberNode
                pop!(folded_block.args)
            end
        end

        push!(folded_block.args, return_val)
    end

    func_name = fname === nothing ? fresh_func_name() : fname
    func_expr = Expr(:block,
        Expr(:function,
             Expr(:call, func_name, unfolded_vars...),
             folded_block))

    return func_expr, func_name
end
