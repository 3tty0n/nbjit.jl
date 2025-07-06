using Test

include("../src/diff.jl")
include("../src/peval.jl")
include("../src/jit.jl")

function test_run()
    run(:(function entry()
            x = 1
            y = x + 1
            return y + 2
        end), "entry") == 4


    return run(:(function entry()
            x = 1
            if x > 2
                return 1
            else
                return 2
            end
        end), "entry") == 2
end

@test test_run()

function test()
    code = """
function entry()
    x = 1
    y = x + 1
    return y + 2
end"""
    res = run(code, "entry")
    return res == 4
end

# @test test()

function test2()
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
    func = create_entry(code2, env)
    println("\nCreated function entry:")
    println(func)

    f = eval(func)
    return Base.invokelatest(f, 12) == 23
end

@test test2()
