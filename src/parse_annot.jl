function parse_annot(expr::LineNumberNode, unconstant_expr)
    return nothing
end

function parse_annot(expr::Symbol, unconstant_expr)
    return expr
end

function parse_annot(expr::Number, unconstant_expr)
    return expr
end

function parse_annot(expr::String, unconstant_expr)
    return expr
end

function parse_annot(expr::QuoteNode, unconstant_expr)
    return expr
end

# Handle vectors (e.g., guard symbol payloads from split_ast)
function parse_annot(expr::Vector, unconstant_expr)
    for e in expr
        if e isa Symbol
            push!(unconstant_expr, e)
        else
            parse_annot(e, unconstant_expr)
        end
    end
end

function parse_annot(expr::Expr, unconstant_expr)
    if expr.head == :macrocall
        args = expr.args
        annot = args[1]
        if annot isa Symbol && string(annot) == "@hole"
            # args[1] = @hole, args[2] = LineNumberNode, args[3:end] = actual arguments
            if length(args) >= 3
                # Recursively parse the actual macro arguments
                for i in 3:length(args)
                    parse_annot(args[i], unconstant_expr)
                end
            end
        elseif annot isa Symbol && string(annot) == "@preserve"
            # @preserve annotated variables should NOT be added to unconstant_expr
            # because they are evaluated once and propagated as constants.
            # We intentionally skip parsing the contents here.
        elseif annot isa Symbol && string(annot) == "@persistent"
            # @persistent annotated variables should NOT be added to unconstant_expr
            # because they are treated as constant values.
            # We intentionally skip parsing the contents here.
        end
    elseif expr.head == :hole
        for arg in expr.args
            if arg isa Symbol
                push!(unconstant_expr, arg)
            elseif arg isa Vector
                parse_annot(arg, unconstant_expr)
            end
        end
    elseif expr.head == :preserve
        # @preserve nodes: the variable should be constant-folded, not added to unconstant_expr.
        # The RHS will be evaluated at partial-evaluation time and stored in env.
        # We skip adding anything to unconstant_expr here.
    elseif expr.head == :persistent
        # @persistent nodes: the variable should be treated as a constant.
        # We skip adding anything to unconstant_expr here.
    else
        [parse_annot(e, unconstant_expr) for e in expr.args]
    end
end
