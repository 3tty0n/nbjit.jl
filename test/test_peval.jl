using Test

include("../src/diff.jl")
include("../src/peval.jl")

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
    println(Meta.show_sexpr(simplified))
    return true
end

# @test test()

function test2()
    code1 = """
function f(x, y)
    if x < 1
        x = x + 2
    end
    return x + y
end"""

    code2 = """
function f(x, y)
    z = 3
    if x < 1
        x = x + 2
    end
    return x + y + z
end"""

    t1 = expr_to_treenode(Meta.parse(code1))
    t2 = expr_to_treenode(Meta.parse(code2))

    M = top_down(t1, t2, 2)
    M = bottom_up(t1, t2, M, 0.5, 100)

    edited = []
    for (t1, t2) in M
        push!(N, treenode_to_expr(t2))
    end



    return true
end

@test test2()
