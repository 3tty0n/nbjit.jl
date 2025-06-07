tbl_func = Dict{Symbol, Expr}()

const id_ref = Ref(-1)

function gen_func_id()
    id_ref[] += 1
    return "func_$(id_ref[])"
end

function is_constant(expr)
    return expr isa Number || expr == :(true) || expr == :(false)
end

function propagate_constants(expr, const_map)
    if isa(expr, Symbol) && haskey(const_map, expr)
        return const_map[expr]  # Replace symbol with its constant value
    elseif isa(expr, Expr)
        new_args = [propagate_constants(arg, const_map) for arg in expr.args]
        return Expr(expr.head, new_args...)
    else
        return expr
    end
end

function can_fold(expr)
    return (expr.head == :call &&
        expr.args[1] in [:+, :-, :*, :/, :<, :>, :<=, :>=] &&
        is_constant(expr.args[2]) &&
        is_constant(expr.args[3]))
end

function partial_evaluate(expr, const_map)
    if is_constant(expr)
        return expr
    elseif isa(expr, Expr)
        if expr.head == :(=) && isa(expr.args[1], Symbol)
            var = expr.args[1]
            value = propagate_constants(expr.args[2], const_map)

            if can_fold(value)
                value = eval(value)
                const_map[var] = value
            end
            return Expr(:(=), var, value)

        elseif expr.head == :if
            condition = propagate_constants(expr.args[1], const_map)
            then_block = partial_evaluate(expr.args[2], const_map)
            if length(expr.args) == 2
                if can_fold(condition)
                    if eval(condition)
                        return then_block
                    else
                        return :nothing
                    end
                end
                return Expr(:if, condition, then_block)
            else
                else_block = partial_evaluate(expr.args[3], const_map)
                if can_fold(condition)
                    if eval(condition)
                        return then_block
                    else
                        return else_block
                    end
                end
                return Expr(:if, condition, then_block, else_block)
            end

        elseif expr.head == :function
            # Get function name and arguments
            fname = expr.args[1]
            body = expr.args[2]
            # Create a fresh map for each function scope
            new_body = partial_evaluate(body, const_map)
            return Expr(:function, fname, new_body)

        elseif expr.head == :call
            # Try to fold constants
            folded_args = [propagate_constants(arg, const_map) for arg in expr.args]
            # Attempt to evaluate if all arguments are constants
            if all(is_constant, folded_args[2:end]) && folded_args[1] in [:+, :-, :*, :/]
                try
                    result = Base._apply(folded_args[1], folded_args[2:end]...)
                    return result
                catch
                    return Expr(:call, folded_args...)
                end
            end
            return Expr(:call, folded_args...)
        else
            # Recursively evaluate other expressions
            new_args = [partial_evaluate(arg, const_map) for arg in expr.args]
            return Expr(expr.head, new_args...)
        end
    else
        return expr
    end
end

function simplify_function(code, const_map)
    ast = Meta.parse(code)
    folded_ast = partial_evaluate(ast, const_map)
    return folded_ast
end

function collect_variables(expr, const_map)
    vars = Set{Symbol}()
    function traverse(e)
        if e isa Symbol
            if haskey(const_map, e)
                push!(vars, e)
            end
        elseif e isa Expr
            for arg in e.args
                traverse(arg)
            end
        end
    end
    traverse(expr)
    return vars
end

function create_entry(code, const_map)
    @show folded_ast = simplify_function(code, const_map)
    @show unfolded_vars = collect_variables(folded_ast, const_map)
    fname = Symbol(gen_func_id())
    func_expr = quote
        function $(fname)(args...)
            $(folded_ast.args[2])
        end
    end
    # TODO: inesrt guards by the types of
    # un-folded (dynamic = edited) variables
    tbl_func[fname] = func_expr
    return func_expr
end
