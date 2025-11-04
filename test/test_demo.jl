using Test

include("../src/ijulia_integration.jl")

@testset "Notebook Runtime Behavior" begin

    @testset "Basic single hole caching" begin
        session = IJuliaIntegration.NotebookSession()

        # 1st execution: compile
        code1 = quote
            x = 1
            @hole y = 100
            z = x + y
        end

        res1 = IJuliaIntegration.run_cell!(session, code1; cell_id="basic")
        @test res1.rebuilt_main == true
        @test res1.recompiled_holes == [1]

        # 2nd execution: same code, should cache
        res2 = IJuliaIntegration.run_cell!(session, code1; cell_id="basic")
        @test res2.rebuilt_main == false
        @test isempty(res2.recompiled_holes)

        # 3rd execution: change hole content only
        code2 = quote
            x = 1
            @hole y = 200  # Changed from 100
            z = x + y
        end

        res3 = IJuliaIntegration.run_cell!(session, code2; cell_id="basic")
        @test res3.rebuilt_main == false
        @test res3.recompiled_holes == [1]

        # 4th execution: same as 3rd, should cache
        res4 = IJuliaIntegration.run_cell!(session, code2; cell_id="basic")
        @test res4.rebuilt_main == false
        @test isempty(res4.recompiled_holes)
    end

    @testset "Main block changes trigger full recompilation" begin
        session2 = IJuliaIntegration.NotebookSession()

        code1 = quote
            base = 42
            @hole delta = 1
            value = base + delta
        end

        res1 = IJuliaIntegration.run_cell!(session2, code1; cell_id="main_change")
        @test res1.rebuilt_main == true

        # Change main block
        code2 = quote
            base = 100  # Changed
            @hole delta = 1
            value = base + delta
        end

        res2 = IJuliaIntegration.run_cell!(session2, code2; cell_id="main_change")
        @test res2.rebuilt_main == true
        @test res2.recompiled_holes == [1]
    end

    @testset "Hole modifies guard variable" begin
        session3 = IJuliaIntegration.NotebookSession()

        code1 = quote
            x = 1
            @hole begin
                x = x * 3  # Modifies guard variable
            end
            z = x
        end

        res1 = IJuliaIntegration.run_cell!(session3, code1; cell_id="guard_mod")
        @test res1.rebuilt_main == true

        res2 = IJuliaIntegration.run_cell!(session3, code1; cell_id="guard_mod")
        @test res2.rebuilt_main == false
        @test isempty(res2.recompiled_holes)
    end

    @testset "Multiple holes selective recompilation" begin
        session4 = IJuliaIntegration.NotebookSession()

        code1 = quote
            base = 42
            @hole delta1 = 1
            temp = base + delta1
            @hole delta2 = 2
            value = temp + delta2
        end

        res1 = IJuliaIntegration.run_cell!(session4, code1; cell_id="multi")
        @test res1.rebuilt_main == true
        @test res1.recompiled_holes == [1, 2]

        code2 = quote
            base = 42
            @hole delta1 = 1
            temp = base + delta1
            @hole delta2 = 5  # Changed
            value = temp + delta2
        end

        res2 = IJuliaIntegration.run_cell!(session4, code2; cell_id="multi")
        @test res2.rebuilt_main == false
        @test res2.recompiled_holes == [2]  # Only second hole

        res3 = IJuliaIntegration.run_cell!(session4, code2; cell_id="multi")
        @test res3.rebuilt_main == false
        @test isempty(res3.recompiled_holes)
    end

    @testset "Guard symbol changes trigger full recompilation" begin
        session5 = IJuliaIntegration.NotebookSession()

        code1 = quote
            base = 100
            @hole delta = 5  # Only base defined before
            value = base + delta
        end

        res1 = IJuliaIntegration.run_cell!(session5, code1; cell_id="guard_change")
        @test res1.rebuilt_main == true

        # Add new variable before hole (changes available guards)
        code2 = quote
            base = 100
            temp = base + 10  # NEW variable before hole
            @hole delta = 5
            value = base + delta
        end

        res2 = IJuliaIntegration.run_cell!(session5, code2; cell_id="guard_change")
        @test res2.rebuilt_main == true  # Main structure changed
        @test res2.recompiled_holes == [1]
    end

    @testset "Ex1.jl line 1-5: constant propagation scenario" begin
        session6 = IJuliaIntegration.NotebookSession()

        code1 = quote
            x = 1
            @hole y = 100
            @hole z = x + y  # TODO: check (constant, constant)
        end

        res1 = IJuliaIntegration.run_cell!(session6, code1; cell_id="const_prop")
        @test res1.rebuilt_main == true
        @test length(res1.recompiled_holes) == 2

        # Verify execution count
        @test session6.execution_counts["const_prop"] == 1
    end

    @testset "Notebook demo: single hole main caching" begin
        session = IJuliaIntegration.NotebookSession()

        # Demo Example 1 & 2: Basic caching behavior
        code1 = quote
            base = 42
            @hole delta = 1
            value = base + delta
        end

        res1 = IJuliaIntegration.run_cell!(session, code1; cell_id="demo_basic")
        @test res1.rebuilt_main == true
        @test res1.recompiled_holes == [1]

        # Change only hole content (delta = 1 -> delta = 5)
        code2 = quote
            base = 42
            @hole delta = 5
            value = base + delta
        end

        res2 = IJuliaIntegration.run_cell!(session, code2; cell_id="demo_basic")
        @test res2.rebuilt_main == false  # Main MUST be cached!
        @test res2.recompiled_holes == [1]
    end

    @testset "Notebook demo: multiple holes main caching" begin
        session = IJuliaIntegration.NotebookSession()

        # Demo Example 4: Multiple holes
        code1 = quote
            start = 5
            @hole step = start + 1
            @hole total = step * 2
            answer = start + total
        end

        res1 = IJuliaIntegration.run_cell!(session, code1; cell_id="demo_multi")
        @test res1.rebuilt_main == true
        @test res1.recompiled_holes == [1, 2]

        # Change only first hole (step = start + 1 -> step = start + 10)
        code2 = quote
            start = 5
            @hole step = start + 10
            @hole total = step * 2
            answer = start + total
        end

        res2 = IJuliaIntegration.run_cell!(session, code2; cell_id="demo_multi")
        @test res2.rebuilt_main == false  # Main MUST be cached!
        @test res2.recompiled_holes == [1]  # Only first hole

        # Change both holes
        code3 = quote
            start = 5
            @hole step = start + 100
            @hole total = step * 200
            answer = start + total
        end

        res3 = IJuliaIntegration.run_cell!(session, code3; cell_id="demo_multi")
        @test res3.rebuilt_main == false  # Main MUST be cached!
        @test res3.recompiled_holes == [1, 2]  # Both holes
    end

    @testset "Notebook demo: main block changes" begin
        session = IJuliaIntegration.NotebookSession()

        # Demo Example 5: Main block unchanged
        code1 = quote
            base = 42
            @hole delta = 5
            value = base + delta
        end

        res1 = IJuliaIntegration.run_cell!(session, code1; cell_id="demo_main")
        @test res1.rebuilt_main == true

        # Add line to main block
        code2 = quote
            base = 42
            temp = base + 1
            @hole delta = temp
            value = base + delta
        end

        res2 = IJuliaIntegration.run_cell!(session, code2; cell_id="demo_main")
        @test res2.rebuilt_main == true  # Main changed, must rebuild
        @test res2.recompiled_holes == [1]
    end

    @testset "Content-based caching: different cell IDs, same code" begin
        session = IJuliaIntegration.NotebookSession()

        code = quote
            x = 10
            @hole y = 20
            z = x + y
        end

        # Execute with cell_id_1
        res1 = IJuliaIntegration.run_cell!(session, code; cell_id="cell_001")
        @test res1.rebuilt_main == true
        @test res1.recompiled_holes == [1]

        # Execute same code with different cell_id (simulates re-execution)
        res2 = IJuliaIntegration.run_cell!(session, code; cell_id="cell_002")
        @test res2.rebuilt_main == false  # Should reuse via alias
        @test isempty(res2.recompiled_holes)

        # Execute same code with yet another cell_id
        res3 = IJuliaIntegration.run_cell!(session, code; cell_id="cell_003")
        @test res3.rebuilt_main == false
        @test isempty(res3.recompiled_holes)
    end

    @testset "Content-based caching: different cell IDs, hole changes" begin
        session = IJuliaIntegration.NotebookSession()

        code1 = quote
            x = 10
            @hole y = 20
            z = x + y
        end

        res1 = IJuliaIntegration.run_cell!(session, code1; cell_id="cell_100")
        @test res1.rebuilt_main == true

        # Change hole content, different cell ID
        code2 = quote
            x = 10
            @hole y = 30  # Changed
            z = x + y
        end

        res2 = IJuliaIntegration.run_cell!(session, code2; cell_id="cell_101")
        @test res2.rebuilt_main == false  # Reuse main, recompile hole
        @test res2.recompiled_holes == [1]
    end

    @testset "Content-based caching: multiple holes across cells" begin
        session = IJuliaIntegration.NotebookSession()

        code1 = quote
            base = 42
            @hole delta1 = 1
            temp = base + delta1
            @hole delta2 = 2
            result = temp + delta2
        end

        res1 = IJuliaIntegration.run_cell!(session, code1; cell_id="multi_001")
        @test res1.rebuilt_main == true
        @test res1.recompiled_holes == [1, 2]

        # Execute same code in different cell (simulates re-execution)
        res2 = IJuliaIntegration.run_cell!(session, code1; cell_id="multi_002")
        @test res2.rebuilt_main == false
        @test isempty(res2.recompiled_holes)

        # Change first hole in new cell
        code2 = quote
            base = 42
            @hole delta1 = 10  # Changed
            temp = base + delta1
            @hole delta2 = 2
            result = temp + delta2
        end

        res3 = IJuliaIntegration.run_cell!(session, code2; cell_id="multi_003")
        @test res3.rebuilt_main == false
        @test res3.recompiled_holes == [1]  # Only first hole changed
    end
end

println("\n✅ All notebook runtime behavior tests passed!")
