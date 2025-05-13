using Test

include("../src/diff.jl")

function test()
    ex1 = Meta.parse("""
function foo()
    x = 1
    y = 2
    if x < 1
        z = 3
        z = 3
    end
end""")

    ex2 = Meta.parse("""
function foo()
    x = 1
    y = 2
    if x <= 1
        z = 4
        z = 5
        z = 6
        z = 293
    end
end""")


    t1 = expr_to_treenode(ex1)
    t2 = expr_to_treenode(ex2)

    M = top_down(t1, t2, 2)
    M = bottom_up(t1, t2, M, 0.5, 100)

    N = []
    env = Dict()
    for (t1, t2) in M
        push!(N, (treenode_to_expr(t1), treenode_to_expr(t2)))

        create_env_from_mapping(treenode_to_expr(t2), env)
    end

    # print_mapping(N)

    return env == Dict(:y => 2, :x => 1)
end


@test test()
