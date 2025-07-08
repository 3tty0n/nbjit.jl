using LLVM

tbl_func = Dict{Symbol, Any}()

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

function simplify_function(code::String, const_map)
    ast = Meta.parse(code)
    folded_ast = partial_evaluate(ast, const_map)
    return folded_ast
end

function simplify_function(code::Expr, const_map)
    folded_ast = partial_evaluate(code, const_map)
    return folded_ast
end

function collect_variables(expr, const_map)
    vars = Set{Symbol}()
    known_locals = Set{Symbol}()

    function traverse(e)
        if e isa Expr
            if e.head == :call
                for arg in e.args[2:end]
                    traverse(arg)
                end
            elseif e.head == :(=) && e.args[1] isa Symbol
                push!(known_locals, e.args[1])
                traverse(e.args[2])
            else
                for arg in e.args
                    traverse(arg)
                end
            end
        elseif e isa Symbol
            if !haskey(const_map, e) && !(e in known_locals) && !isdefined(Base, e) && !isdefined(Core, e)
                push!(vars, e)
            end
        end
    end

    traverse(expr)
    return vars
end

function collect_variables_with_types(expr, const_map)
    vars_with_types = Dict{Symbol, DataType}()
    known_locals = Set{Symbol}()

    function traverse(e)
        if e isa Expr
            if e.head == :function
                call_sig = e.args[1]
                for arg_expr in call_sig.args[2:end]
                    arg_name = (arg_expr isa Symbol) ? arg_expr : arg_expr.args[1]
                    push!(known_locals, arg_name)
                end
                traverse(e.args[2])

            elseif e.head == :call
                for arg in e.args[2:end]
                    traverse(arg)
                end

            elseif e.head == :(=) && e.args[1] isa Symbol
                push!(known_locals, e.args[1])
                traverse(e.args[2])

            else
                for arg in e.args
                    traverse(arg)
                end
            end
        elseif e isa Symbol
            if !haskey(const_map, e) && !(e in known_locals) &&
                !isdefined(Base, e) && !isdefined(Core, e)

                # Try to infer type from const_map or fallback to Any
                typ = haskey(const_map, e) ? typeof(const_map[e]) : Any
                vars_with_types[e] = typ
            end
        end
    end

    traverse(expr)
    return vars_with_types
end

function create_entry(code, const_map)
    folded_ast = simplify_function(code, const_map)
    unfolded_vars = collect_variables(folded_ast, const_map)
    fname = Symbol(gen_func_id())
    func_expr = quote
        function $(fname)($(unfolded_vars...))
            $(folded_ast.args[2])
        end
    end
    # TODO: inesrt guards by the types of
    # un-folded (dynamic = edited) variables
    tbl_func[fname] = func_expr
    return func_expr, fname
end

function lookup_function(fname)
    if haskey(tbl_func, fname)
        return tbl_func[fname]
    else
        throw("$fname is not found in tbl_func")
    end
end
