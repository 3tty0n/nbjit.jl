parse_annot(expr::LineNumberNode, unconstant_expr) = nothing

function parse_annot(expr::Symbol, unconstant_expr)
    return expr
end

function parse_annot(expr::Number, unconstant_expr)
    return expr
end

function parse_annot(expr::Expr, unconstant_expr)
    if expr.head == :macrocall
        args = expr.args
        annot = args[1]
        if annot isa Symbol && string(annot) == "@hole"
            if args[2] isa Symbol
                push!(unconstant_expr, args[2])
            else
                push!(unconstant_expr, args[2:end]...)
            end
        end
    else
        [parse_annot(e, unconstant_expr) for e in expr.args]
    end
end

using Test

# unconstant_expr = []
# parse_annot(quote
# 	            @hole x = 1
#                 @hole f()
#             end, unconstant_expr)
# println(unconstant_expr)
