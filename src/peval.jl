
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
    # Base case: If the expression is a constant, return as-is
    if is_constant(expr)
        return expr
    elseif isa(expr, Expr)
        # Handle assignment expressions
        if expr.head == :(=) && isa(expr.args[1], Symbol)
            var = expr.args[1]
            value = propagate_constants(expr.args[2], const_map)
            # If the value can be constant-folded, update the map
            if can_fold(value)
                value = eval(value)
                const_map[var] = value
            end
            return Expr(:(=), var, value)

        # Handle conditional expressions (like if)
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

        # Handle function definitions
        elseif expr.head == :function
            # Get function name and arguments
            fname = expr.args[1]
            body = expr.args[2]
            # Create a fresh map for each function scope
            new_body = partial_evaluate(body, const_map)
            return Expr(:function, fname, new_body)

        # Handle expressions that can be folded
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

"""
Generate the simplified function after partial evaluation.
"""
function simplify_function(code, const_map)
    ast = Meta.parse(code)
    simplified_ast = partial_evaluate(ast, const_map)
    return simplified_ast
end

function test()

    # Test the partial evaluator
    code = """
function f(x, y)
    if x < 1
        x = x + 2
    end
    return x + y
end
"""

    const_map = Dict(Symbol("x") => :(0))
    simplified = simplify_function(code, const_map)
    println("Simplified Function AST:")
    println(simplified)
    println("\nSimplified Code:")
    println(Meta.show_sexpr(simplified), "\n")
    return true
end

using Test

@test test()
