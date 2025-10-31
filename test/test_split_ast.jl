include("../src/split_ast.jl")

using Test

@testset "collect_symbols" begin
    # Test basic symbol collection
    syms = SplitAst.collect_symbols(:(
        begin
            x = 1
            y = 2
            z = x + y
        end
    ))
    @test :x in syms
    @test :y in syms
    @test :z in syms
    @test length(syms) >= 3

    # Test that macros are ignored
    syms = SplitAst.collect_symbols(:(@hole x = 1))
    @test :x in syms
    @test !(:hole in syms) || !any(s -> startswith(string(s), "@"), syms)
end

@testset "collect_hole" begin
    # Test simple hole collection
    holes = SplitAst.collect_hole(:(
        begin
            x = 1
            @hole y = 2
            z = x + y
        end
    ))
    @test !isnothing(holes)
    @test length(holes) >= 1

    # Test nested holes
    holes = SplitAst.collect_hole(:(
        begin
            x = 1
            @hole y = 2
            z = x + y
            begin
                @hole r = 1
                if r < 1
                    @hole z = z + r
                else
                    @hole x = 1000
                end
            end
        end
    ))
    @test !isnothing(holes)
    @test length(holes) >= 2
end

@testset "convert_ast_with_hole" begin
    prog = :(
        begin
            x = 1
            @hole y = 2
            z = x + y
        end
    )

    ast_with_hole = SplitAst.convert_ast_with_hole(prog)
    @test ast_with_hole isa Expr
    @test ast_with_hole.head == :block

    # Check that @hole was converted to :hole
    has_hole = any(arg -> isa(arg, Expr) && arg.head == :hole, ast_with_hole.args)
    @test has_hole
end

@testset "split_at_hole - single hole" begin
    prog = :(
        begin
            x = 1
            @hole y = 2
            z = x + y
        end
    )

    ast_with_hole = SplitAst.convert_ast_with_hole(prog)
    block, hole_block = SplitAst.split_at_hole(ast_with_hole)

    @test block isa Expr
    @test hole_block isa Expr
    @test block.head == :block

    # Verify the hole was replaced with guard symbols
    hole_expr = findfirst(x -> isa(x, Expr) && x.head == :hole, block.args)
    @test !isnothing(hole_expr)
end

@testset "split_at_holes - multiple holes" begin
    prog = :(
        begin
            x = 1
            @hole y = 2
            z = x + y
            @hole w = 3
            q = z + w
        end
    )

    ast_with_hole = SplitAst.convert_ast_with_hole(prog)
    results = SplitAst.split_at_holes(ast_with_hole)

    @test length(results) == 2
    @test all(r -> length(r) == 3, results)  # Each result has 3 elements

    for (block, hole_block, guard_syms) in results
        @test block isa Expr
        @test hole_block isa Expr
        @test guard_syms isa Vector
    end
end

@testset "validate_ast_for_splitting" begin
    # Valid AST with hole
    valid_prog = :(
        begin
            x = 1
            @hole y = 2
        end
    )
    ast_with_hole = SplitAst.convert_ast_with_hole(valid_prog)
    is_valid, msg = SplitAst.validate_ast_for_splitting(ast_with_hole)
    @test is_valid
    @test msg == "Valid"

    # Invalid AST without hole
    invalid_prog = :(
        begin
            x = 1
            y = 2
        end
    )
    is_valid, msg = SplitAst.validate_ast_for_splitting(invalid_prog)
    @test !is_valid
    @test occursin("No holes", msg)
end

@testset "contains_hole" begin
    # AST with hole
    prog_with_hole = SplitAst.convert_ast_with_hole(:(
        begin
            @hole x = 1
        end
    ))
    @test SplitAst.contains_hole(prog_with_hole)

    # AST without hole
    prog_without_hole = :(
        begin
            x = 1
        end
    )
    @test !SplitAst.contains_hole(prog_without_hole)
end

@testset "create_hole_block" begin
    prog = :(
        begin
            x = 1
            @hole y = 2
            z = x + y
        end
    )

    ast_with_hole = SplitAst.convert_ast_with_hole(prog)
    hole_expr = findfirst(x -> isa(x, Expr) && x.head == :hole, ast_with_hole.args)
    @test !isnothing(hole_expr)

    hole_block = SplitAst.create_hole_block(ast_with_hole.args[hole_expr])
    @test hole_block isa Expr
    @test hole_block.head == :block
end
