using Test

include("../src/jit_dylib.jl")

@testset "AST splitting utilities" begin
    code = quote
        x = 10
        temp = x + 1
        @hole y = temp
        result = x + y
        result
    end

    main_ast, hole_blocks, guard_syms = prepare_split(code)
    @test length(hole_blocks) == 1
    @test guard_syms == [[:x, :temp, :y]]

    placeholders = [stmt for stmt in main_ast.args if stmt isa Expr && stmt.head == :hole]
    @test length(placeholders) == 1
    @test first(placeholders[1].args) == 1

    hole_block = hole_blocks[1]
    @test occursin("temp", sprint(show, hole_block))
end

@testset "Separate dylib compilation metadata" begin
    code = quote
        base = 5
        @hole scale = base + 2
        @hole offset = scale - 1
        result = base * scale + offset
        result
    end

    compiled = compile_to_separate_dylibs(code)

    try
        @test compiled.main_lib_path !== nothing
        @test isfile(compiled.main_lib_path)
        @test length(compiled.hole_lib_paths) == 2
        @test all(isfile, compiled.hole_lib_paths)
        @test compiled.guard_syms == [[:base, :scale], [:base, :scale, :offset]]
        @test compiled.hole_inputs == [[:base], [:base, :scale]]

        result = execute_dylib(compiled)
        @test result == 5 * 7 + 6  # Expected 41
    finally
        cleanup_dylib!(compiled)
    end
end

@testset "Selective hole recompilation via update_dylib!" begin
    code = quote
        a = 5
        @hole b = a + 1
        result = a * b
        result
    end

    compiled = compile_to_separate_dylibs(code)

    try
        changed, rebuilt = update_dylib!(compiled, code)
        @test isempty(changed)
        @test !rebuilt

        new_code = quote
            a = 5
            @hole b = a + 10
            result = a * b
            result
        end

        changed, rebuilt = update_dylib!(compiled, new_code)
        @test changed == [1]
        @test !rebuilt
        @test execute_dylib(compiled) == 75
    finally
        cleanup_dylib!(compiled)
    end
end
