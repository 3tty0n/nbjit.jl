using Test

include("../src/split_jit.jl")

function first_function_name(expr::Expr)
    if expr.head == :block
        for arg in expr.args
            if arg isa Expr && arg.head == :function
                return arg.args[1].args[1]
            end
        end
    elseif expr.head == :function
        return expr.args[1].args[1]
    end
    return nothing
end

@testset "Split and compile pipeline" begin
    code = quote
        x = 10
        @hole y = 2
        z = x + y
    end

    compiled = split_and_compile(code)

    @testset "Main function compilation" begin
        @test compiled.main_fname isa Symbol
        @test compiled.main_mod !== nothing
        @test compiled.main_inputs == [:x, :y]
        main_ir = string(compiled.main_mod)
        @test occursin("define i64 @$(compiled.main_fname)", main_ir)

        main_func_name = first_function_name(compiled.main_func_expr)
        @test main_func_name == compiled.main_fname
    end

    @testset "Hole function compilation" begin
        @test length(compiled.hole_mods) == 1
        @test compiled.hole_mods[1] !== nothing
        @test compiled.hole_inputs[1] == [:x, :y]
        hole_ir = string(compiled.hole_mods[1])
        @test occursin("define i64 @$(compiled.hole_fnames[1])", hole_ir)

        hole_func_name = first_function_name(compiled.hole_func_exprs[1])
        @test hole_func_name == compiled.hole_fnames[1]
    end

    @testset "Guard checking" begin
        guard_env = Dict{Symbol, Any}(:x => 10, :y => 2)
        @test check_guards(compiled, guard_env)

        # Modify guard value - should fail check
        guard_env[:x] = 20
        @test !check_guards(compiled, guard_env)
    end
end

@testset "Selective hole recompilation" begin
    code = quote
        a = 5
        @hole b = a + 1
        result = a * b
    end

    compiled = split_and_compile(code)
    main_mod_before = compiled.main_mod
    hole_mod_before = compiled.hole_mods[1]

    @testset "Successful hole recompilation" begin
        new_hole = quote
            b = a + 10
        end

        recompile_hole!(compiled, 1, new_hole)

        # Main module should remain unchanged
        @test compiled.main_mod === main_mod_before

        # Hole module should be different
        @test compiled.hole_mods[1] !== hole_mod_before

        # Function name should be consistent
        @test first_function_name(compiled.hole_func_exprs[1]) == compiled.hole_fnames[1]

        # Guard values should be cleared
        @test isempty(compiled.guard_values)
    end

    @testset "Hole recompilation with invalid guards" begin
        bad_hole = quote
            b = a + c  # c is not in guard symbols
        end
        @test_throws ErrorException recompile_hole!(compiled, 1, bad_hole)
    end
end
