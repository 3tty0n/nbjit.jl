using Test

include("test_helper.jl")

@testset "has_hole_markers" begin
    # Code with @hole
    code_with_hole = quote
        x = 1
        @hole y = 2
        z = x + y
    end
    @test IJuliaIntegration.has_hole_markers(code_with_hole) == true

    # Code without @hole
    code_without = quote
        x = 1
        y = 2
        z = x + y
    end
    @test IJuliaIntegration.has_hole_markers(code_without) == false

    # Nested @hole
    code_nested = quote
        if true
            @hole x = 1
        end
    end
    @test IJuliaIntegration.has_hole_markers(code_nested) == true
end

@testset "extract_statements" begin
    code = quote
        x = 1
        y = 2
        z = x + y
    end
    stmts = IJuliaIntegration.extract_statements(code)
    @test length(stmts) == 3
    @test all(s -> s isa Expr, stmts)
end

@testset "LCS indices" begin
    # Identical sequences
    h1 = UInt64[1, 2, 3]
    h2 = UInt64[1, 2, 3]
    old_m, new_m = IJuliaIntegration.lcs_indices(h1, h2)
    @test length(new_m) == 3

    # One element changed
    h3 = UInt64[1, 99, 3]
    old_m2, new_m2 = IJuliaIntegration.lcs_indices(h1, h3)
    @test 1 in new_m2
    @test 3 in new_m2
    @test 2 ∉ new_m2  # The changed element

    # Insertion
    h4 = UInt64[1, 99, 2, 3]
    old_m3, new_m3 = IJuliaIntegration.lcs_indices(h1, h4)
    @test length(new_m3) == 3  # 1, 2, 3 all matched
    @test 2 ∉ new_m3  # Position 2 is the inserted 99

    # Deletion
    h5 = UInt64[1, 3]
    old_m4, new_m4 = IJuliaIntegration.lcs_indices(h1, h5)
    @test length(new_m4) == 2  # 1, 3 matched

    # Completely different
    h6 = UInt64[4, 5, 6]
    old_m5, new_m5 = IJuliaIntegration.lcs_indices(h1, h6)
    @test isempty(new_m5)
end

@testset "auto_prepare_split" begin
    @testset "First execution (no previous code)" begin
        code = quote
            x = 1
            y = 2
            z = x + y
        end
        main_ast, holes, guards = IJuliaIntegration.auto_prepare_split(nothing, code)
        @test isempty(holes)
        @test isempty(guards)
        # main_ast should contain all statements
        stmts = [s for s in main_ast.args if !(s isa LineNumberNode)]
        @test length(stmts) == 3
    end

    @testset "No changes" begin
        code = quote
            x = 1
            y = 2
            z = x + y
        end
        main_ast, holes, guards = IJuliaIntegration.auto_prepare_split(code, code)
        @test isempty(holes)
        @test isempty(guards)
    end

    @testset "Single statement changed" begin
        old_code = quote
            x = 1
            y = 2
            z = x + y
        end
        new_code = quote
            x = 1
            y = 99
            z = x + y
        end
        main_ast, holes, guards = IJuliaIntegration.auto_prepare_split(old_code, new_code)

        @test length(holes) == 1  # Only y = 99 is a hole

        # Main should have 2 unchanged statements + 1 hole placeholder
        main_stmts = [s for s in main_ast.args if !(s isa LineNumberNode)]
        @test length(main_stmts) == 3
        hole_nodes = [s for s in main_stmts if s isa Expr && s.head == :hole]
        @test length(hole_nodes) == 1
    end

    @testset "Multiple statements changed" begin
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
        main_ast, holes, guards = IJuliaIntegration.auto_prepare_split(old_code, new_code)

        @test length(holes) == 2  # b and d changed
    end

    @testset "Statement inserted" begin
        old_code = quote
            x = 1
            z = x + 1
        end
        new_code = quote
            x = 1
            y = 2
            z = x + 1
        end
        main_ast, holes, guards = IJuliaIntegration.auto_prepare_split(old_code, new_code)

        @test length(holes) == 1  # y = 2 is new
        # x = 1 and z = x + 1 should be matched (main)
        main_stmts = [s for s in main_ast.args if !(s isa LineNumberNode)]
        non_hole = [s for s in main_stmts if !(s isa Expr && s.head == :hole)]
        @test length(non_hole) == 2
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
        main_ast, holes, guards = IJuliaIntegration.auto_prepare_split(old_code, new_code)

        # Complete rewrite → no holes, full main (triggers full recompile)
        @test isempty(holes)
    end

    @testset "Guard symbols computed correctly" begin
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
        main_ast, holes, guards = IJuliaIntegration.auto_prepare_split(old_code, new_code)

        @test length(holes) == 1
        @test length(guards) == 1
        # The hole (y = x + 99) references x, which is defined before it
        @test :x in guards[1]
    end
end

@testset "Auto mode integration with run_cell!" begin
    @testset "First execution without @hole compiles successfully" begin
        session = IJuliaIntegration.NotebookSession()

        code = quote
            x = 10
            y = 20
            z = x + y
        end
        res = IJuliaIntegration.run_cell!(session, code; cell_id="auto1")
        @test res.rebuilt_main == true
        @test contains(res.dylib_info, "auto")
    end

    @testset "Re-execution with same code reuses cache" begin
        session = IJuliaIntegration.NotebookSession()

        code = quote
            a = 5
            b = 3
            c = a + b
        end
        res1 = IJuliaIntegration.run_cell!(session, code; cell_id="auto2")
        @test res1.rebuilt_main == true

        res2 = IJuliaIntegration.run_cell!(session, code; cell_id="auto2")
        @test res2.rebuilt_main == false
        @test isempty(res2.recompiled_holes)
    end

    @testset "Re-execution with changed statement detects hole" begin
        session = IJuliaIntegration.NotebookSession()

        code_v1 = quote
            p = 10
            q = 20
            r = p + q
        end
        res1 = IJuliaIntegration.run_cell!(session, code_v1; cell_id="auto3")
        @test res1.rebuilt_main == true

        # Change q from 20 to 50
        code_v2 = quote
            p = 10
            q = 50
            r = p + q
        end
        res2 = IJuliaIntegration.run_cell!(session, code_v2; cell_id="auto3")
        @test contains(res2.dylib_info, "hole")
    end

    @testset "Third execution reuses main (only hole recompiled)" begin
        session = IJuliaIntegration.NotebookSession()

        code_v1 = quote
            m = 3
            n = 4
            o = m + n
        end
        res1 = IJuliaIntegration.run_cell!(session, code_v1; cell_id="auto4")
        @test res1.rebuilt_main == true

        # v2: change n → creates hole structure
        code_v2 = quote
            m = 3
            n = 7
            o = m + n
        end
        res2 = IJuliaIntegration.run_cell!(session, code_v2; cell_id="auto4")
        @test contains(res2.dylib_info, "hole")

        # v3: change n again (same hole position) → should reuse main
        code_v3 = quote
            m = 3
            n = 100
            o = m + n
        end
        res3 = IJuliaIntegration.run_cell!(session, code_v3; cell_id="auto4")
        @test contains(res3.dylib_info, "hole")
        # Main should NOT be rebuilt — only the hole changed
        @test !isempty(res3.recompiled_holes)
    end

    @testset "Manual @hole mode still works" begin
        session = IJuliaIntegration.NotebookSession()

        code = quote
            base_val = 42
            @hole delta_val = 1
            result_val = base_val + delta_val
        end
        res = IJuliaIntegration.run_cell!(session, code; cell_id="manual1")
        @test res.rebuilt_main == true

        code_v2 = quote
            base_val = 42
            @hole delta_val = 5
            result_val = base_val + delta_val
        end
        res2 = IJuliaIntegration.run_cell!(session, code_v2; cell_id="manual1")
        @test res2.rebuilt_main == false
        @test res2.recompiled_holes == [1]
    end
end

println("\nAll auto diff tests passed!")
