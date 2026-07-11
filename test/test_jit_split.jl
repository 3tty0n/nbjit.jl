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

@testset "@preserve AST conversion" begin
    include("../src/split_ast.jl")
    using .SplitAst: convert_ast_with_hole, get_preserve_id

    @testset "convert_ast_with_hole handles @preserve" begin
        # Reset IDs for predictable testing
        SplitAst.preserve_id = -1

        # Create an AST with @preserve annotation
        code = quote
            @preserve x = 42
        end

        converted = convert_ast_with_hole(code)

        # Find the :preserve node in the converted AST
        preserve_nodes = []
        function find_preserve(expr)
            if expr isa Expr
                if expr.head === :preserve
                    push!(preserve_nodes, expr)
                end
                for arg in expr.args
                    find_preserve(arg)
                end
            end
        end
        find_preserve(converted)

        @test length(preserve_nodes) == 1
        preserve_node = preserve_nodes[1]
        @test preserve_node.head === :preserve
        # Last arg should be preserve_id (0 after reset)
        @test preserve_node.args[end] == 0
    end

    @testset "@preserve and @hole coexist" begin
        # Reset IDs for predictable testing
        SplitAst.hole_id = -1
        SplitAst.preserve_id = -1

        # Create an AST with both @preserve and @hole annotations
        code = quote
            @preserve config = 100
            @hole dynamic = config + 1
        end

        converted = convert_ast_with_hole(code)

        # Find all :preserve and :hole nodes
        preserve_nodes = []
        hole_nodes = []
        function find_nodes(expr)
            if expr isa Expr
                if expr.head === :preserve
                    push!(preserve_nodes, expr)
                elseif expr.head === :hole
                    push!(hole_nodes, expr)
                end
                for arg in expr.args
                    find_nodes(arg)
                end
            end
        end
        find_nodes(converted)

        @test length(preserve_nodes) == 1
        @test length(hole_nodes) == 1

        # Verify they have correct structure
        @test preserve_nodes[1].head === :preserve
        @test hole_nodes[1].head === :hole
    end
end

@testset "@preserve with @hole in loop - runtime execution" begin
    # This tests the exact use case from the user:
    # @hole iterations = 10000000
    # @preserve c = 10
    # for i in 1:iterations
    #     result = result + c
    # end

    @testset "@preserve constant used inside @hole loop" begin
        code = quote
            @hole iterations = 5
            @preserve c = 10
            result = 0
            for i in 1:iterations
                result = result + c
            end
            result
        end

        compiled = compile_to_separate_dylibs(code)

        try
            result = execute_dylib(compiled)
            # With iterations=5 and c=10, result should be 50
            @test result == 50
        finally
            cleanup_dylib!(compiled)
        end
    end

    @testset "@preserve value propagates correctly" begin
        code = quote
            @preserve multiplier = 3
            @hole base = 10
            result = base * multiplier
            result
        end

        compiled = compile_to_separate_dylibs(code)

        try
            result = execute_dylib(compiled)
            # multiplier=3, base=10, result=30
            @test result == 30
        finally
            cleanup_dylib!(compiled)
        end
    end

    @testset "@preserve with expression evaluation" begin
        code = quote
            @preserve computed = 2 + 3 * 4
            @hole dynamic = 5
            result = computed + dynamic
            result
        end

        compiled = compile_to_separate_dylibs(code)

        try
            result = execute_dylib(compiled)
            # computed = 2 + 3 * 4 = 14, dynamic = 5, result = 19
            @test result == 19
        finally
            cleanup_dylib!(compiled)
        end
    end
end
