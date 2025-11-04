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
        end
    elseif expr.head == :hole
        for arg in expr.args
            if arg isa Symbol
                push!(unconstant_expr, arg)
            elseif arg isa Vector
                parse_annot(arg, unconstant_expr)
            end
        end
    else
        [parse_annot(e, unconstant_expr) for e in expr.args]
    end
end
