using Test

include("../src/diff.jl")
include("../src/peval.jl")
include("../src/jit.jl")

function test_run()
    compile_and_run(:(function entry()
            x = 1
            y = x + 1
            return y + 2
        end), "entry") == 4


    return compile_and_run(:(function entry()
            x = 1
            if x > 2
                return 1
            else
                return 2
            end
        end), "entry") == 2
end

# @test test_run()

function test_jit_with_gumtree()
    code1 = :(
        function f(x, y)
            if x <= 1
                x = x + 2
            end
            return x + y
        end)

    code2 = :(
        function f(x, y)
            if x <= 1
                x = x + 10
            end
            return x + y
        end)

    t1 = expr_to_treenode(code1)
    t2 = expr_to_treenode(code2)

    M = top_down(t1, t2, 2)
    M = bottom_up(t1, t2, M, 0.5, 100)

    N = []
    for (t1, t2) in M
        expr1 = treenode_to_expr(t1)
        expr2 = treenode_to_expr(t2)
        push!(N, (expr1, expr2))
    end
    env = create_env_from_mapping(N)
    env[:x] = :(1)
    fname = create_entry(code2, env)
    func_expr = lookup_function(fname)
    mod = compile(func_expr)
    return true

end

@test test_jit_with_gumtree()
