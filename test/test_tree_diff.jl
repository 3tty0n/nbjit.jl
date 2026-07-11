using Test

include("test_helper.jl")

@testset "ASTNode construction" begin
    code = quote
        x = 1
        y = x + 2
    end
    IJuliaIntegration.reset_node_ids!()
    tree = IJuliaIntegration.expr_to_tree(code)
    @test tree.label == "block"
    @test tree.height >= 2
    @test tree.size > 1
    @test length(tree.children) == 2  # two statements (LineNumberNodes filtered)
end

@testset "expr_to_tree / tree_to_expr roundtrip" begin
    code = :(x = 1 + 2)
    IJuliaIntegration.reset_node_ids!()
    tree = IJuliaIntegration.expr_to_tree(code)
    recovered = IJuliaIntegration.tree_to_expr(tree)
    @test recovered == code
end

@testset "Isomorphism detection" begin
    IJuliaIntegration.reset_node_ids!()
    t1 = IJuliaIntegration.expr_to_tree(:(x = 1 + 2))
    t2 = IJuliaIntegration.expr_to_tree(:(x = 1 + 2))
    @test IJuliaIntegration.isomorphic(t1, t2)

    t3 = IJuliaIntegration.expr_to_tree(:(x = 1 + 3))
    @test !IJuliaIntegration.isomorphic(t1, t3)
end

@testset "GumTree top-down matching" begin
    old_code = quote
        x = 10
        y = 20
        z = x + y
    end
    new_code = quote
        x = 10
        y = 99
        z = x + y
    end

    IJuliaIntegration.reset_node_ids!()
    mapping, old_tree, new_tree = IJuliaIntegration.gumtree_diff(old_code, new_code)

    # x = 10 and z = x + y are unchanged, so they should be fully matched
    # y = 20 vs y = 99 differs only in the literal value
    @test IJuliaIntegration.match_count(mapping) > 0

    # The root block nodes should be matched
    @test IJuliaIntegration.is_matched_old(mapping, old_tree)
    @test IJuliaIntegration.is_matched_new(mapping, new_tree)
end

@testset "GumTree bottom-up matching" begin
    # Bottom-up should recover matches for structurally similar but not identical subtrees
    old_code = quote
        x = 10
        y = f(x, 20)
    end
    new_code = quote
        x = 10
        y = f(x, 30)
    end

    IJuliaIntegration.reset_node_ids!()
    mapping, old_tree, new_tree = IJuliaIntegration.gumtree_diff(old_code, new_code)

    # x = 10 should be fully matched (isomorphic)
    # y = f(x, 20) vs y = f(x, 30): structurally similar, bottom-up should recover some matches
    # At minimum: the root blocks + x = 10 subtree
    @test IJuliaIntegration.match_count(mapping) >= 3
end

@testset "changed_statement_indices" begin
    @testset "Single constant change" begin
        old_code = quote
            x = 10
            y = 20
            z = x + y
        end
        new_code = quote
            x = 10
            y = 99
            z = x + y
        end

        changed = IJuliaIntegration.changed_statement_indices(old_code, new_code)
        @test 2 in changed      # y = 99 changed
        @test 1 ∉ changed       # x = 10 unchanged
        @test 3 ∉ changed       # z = x + y unchanged
    end

    @testset "Multiple changes" begin
        old_code = quote
            a = 1
            b = 2
            c = 3
            d = 4
        end
        new_code = quote
            a = 1
            b = 20
            c = 3
            d = 40
        end

        changed = IJuliaIntegration.changed_statement_indices(old_code, new_code)
        @test 2 in changed
        @test 4 in changed
        @test 1 ∉ changed
        @test 3 ∉ changed
    end

    @testset "No changes" begin
        code = quote
            x = 1
            y = 2
        end
        changed = IJuliaIntegration.changed_statement_indices(code, code)
        @test isempty(changed)
    end

    @testset "Structural change" begin
        old_code = quote
            x = 1
            y = 2
        end
        new_code = quote
            x = 1
            y = x + 2
        end

        changed = IJuliaIntegration.changed_statement_indices(old_code, new_code)
        @test 2 in changed
        @test 1 ∉ changed
    end
end

@testset "gumtree_prepare_split" begin
    @testset "First execution" begin
        code = quote
            x = 1
            y = 2
            z = x + y
        end
        main_ast, holes, guards = IJuliaIntegration.gumtree_prepare_split(nothing, code)
        @test isempty(holes)
        @test isempty(guards)
    end

    @testset "No changes" begin
        code = quote
            x = 1
            y = 2
        end
        main_ast, holes, guards = IJuliaIntegration.gumtree_prepare_split(code, code)
        @test isempty(holes)
    end

    @testset "Single statement changed" begin
        old_code = quote
            x = 10
            y = 20
            z = x + y
        end
        new_code = quote
            x = 10
            y = 99
            z = x + y
        end

        main_ast, holes, guards = IJuliaIntegration.gumtree_prepare_split(old_code, new_code)
        @test length(holes) == 1

        # Main should have 2 unchanged + 1 hole placeholder
        main_stmts = [s for s in main_ast.args if !(s isa LineNumberNode)]
        @test length(main_stmts) == 3
        hole_nodes = [s for s in main_stmts if s isa Expr && s.head == :hole]
        @test length(hole_nodes) == 1
    end

    @testset "Guard symbols" begin
        old_code = quote
            x = 10
            y = x + 1
            z = y + 2
        end
        new_code = quote
            x = 10
            y = x + 99
            z = y + 2
        end

        main_ast, holes, guards = IJuliaIntegration.gumtree_prepare_split(old_code, new_code)
        @test length(holes) == 1
        @test length(guards) == 1
        @test :x in guards[1]
    end

    @testset "Complete rewrite" begin
        old_code = quote
            x = 1
            y = 2
        end
        new_code = quote
            a = 10
            b = 20
        end

        main_ast, holes, guards = IJuliaIntegration.gumtree_prepare_split(old_code, new_code)
        # Complete rewrite → no holes, full recompile
        @test isempty(holes)
    end
end

@testset "GumTree vs LCS comparison" begin
    # Case where GumTree is more precise: small change in a complex statement
    old_code = quote
        x = 10
        result = x * 2 + 100
        z = result
    end
    new_code = quote
        x = 10
        result = x * 2 + 200
        z = result
    end

    # LCS: statement hash differs for "result = x * 2 + 100" vs "result = x * 2 + 200"
    #   → correctly identifies it as changed
    _, lcs_holes, _ = IJuliaIntegration.auto_prepare_split(old_code, new_code)

    # GumTree: tree diff sees most of the statement structure matches,
    #   only the literal 100→200 differs → also identifies the statement as changed
    _, gt_holes, _ = IJuliaIntegration.gumtree_prepare_split(old_code, new_code)

    # Both should detect exactly 1 changed statement
    @test length(lcs_holes) == 1
    @test length(gt_holes) == 1
end

@testset "GumTree integration with run_cell! (gumtree mode)" begin
    session = IJuliaIntegration.NotebookSession(diff_algorithm=:gumtree)

    code_v1 = quote
        x = 10
        y = 20
        z = x + y
    end
    res1 = IJuliaIntegration.run_cell!(session, code_v1; cell_id="gt1")
    @test res1.rebuilt_main == true

    # Same code → cached
    res2 = IJuliaIntegration.run_cell!(session, code_v1; cell_id="gt1")
    @test res2.rebuilt_main == false
    @test isempty(res2.recompiled_holes)

    # Change y
    code_v2 = quote
        x = 10
        y = 50
        z = x + y
    end
    res3 = IJuliaIntegration.run_cell!(session, code_v2; cell_id="gt1")
    @test contains(res3.dylib_info, "hole") || contains(res3.dylib_info, "auto")
end

println("\nAll GumTree tree diff tests passed!")
