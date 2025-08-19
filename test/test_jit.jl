using Test

include("../src/diff.jl")
include("../src/peval.jl")
include("../src/jit.jl")

function test_jit_with_annot()
    code = quote
        x = 1
        @constant y = 2
        z = x + y
        if x < 3
            z = z + 10
        else
            x = 3
        end
        return z
    end
    begin
        fname, func_expr = create_entry(code)
        @show res = compile_and_run(func_expr, string(fname), 123)
    end
    return true
end

@test test_jit_with_annot()

function test_jit_with_annot_2()
    code = quote
        function f()
            x = 1
            return x
        end

        x = f()
        return x
    end

    begin
        fname, func_expr = create_entry(code)
        @show res = compile_and_run(func_expr, string(fname), 123)
    end
    return true
end

@test test_jit_with_annot_2()

function test_jit_with_gumtree()
    code1 = :(
        function cell1_0(y)
            x = 123
            if x <= 1
                x = x + 2
            end
            return x + y
        end)

    code2 = :(
        function cell1_1(y)
            x = 124
            if x <= 1
                x = x + 2
            end
            x = x * 2
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
    # TODO: Precise extract variables that have been designated as "edited."
    @show N
    @show env = create_env_from_mapping(N)
    # env[:x] = :(123)
    func_expr, fname = simply_and_make_entry(code2, env)
    @show func_expr
    @show res = compile_and_run(func_expr, string(fname), 123)
    return res == 369
end

#@test test_jit_with_gumtree()
