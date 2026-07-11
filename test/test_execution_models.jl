"""
Test file demonstrating the three execution models:

| Code State | User Intent    | Annotation    | Behavior                              |
|------------|----------------|---------------|---------------------------------------|
| Unchanged  | Don't recalc   | @persistent   | Constant propagation, skip execution  |
| Unchanged  | Do recalculate | (unmarked)    | Reuse compilation, execute            |
| Changed    | Do recalculate | @hole         | Recompile & re-execute                |

Note: The system requires at least one @hole marker. "Unmarked" refers to code
that is not annotated with @persistent or @hole within a block that contains @hole.
"""

using Test

include("test_helper.jl")
using .IJuliaIntegration
const NB = IJuliaIntegration

@testset "Execution Models" begin
    session = NB.NotebookSession()

    @testset "@persistent annotation" begin
        println("\n=== Test 1: @persistent annotation ===")
        println("Code unchanged, don't need recalculation")
        println("Expected: Value computed once and propagated as constant\n")

        code1 = quote
            @persistent expensive_constant = 100 * 50  # Computed once, constant-folded
            x = 10                                     # Unmarked: part of main code
            @hole y = x + 5                            # Hole: can be recompiled
            result = expensive_constant + y
            result
        end

        result1 = NB.run_cell!(session, code1; cell_id="cell_1")
        println("First execution (cell_1):")
        display(result1)
        println("\nResult: ", result1.result)

        # Re-execute with same code
        result1_again = NB.run_cell!(session, code1; cell_id="cell_1")
        println("\nRe-execution with identical code (cell_1):")
        display(result1_again)
        println("\nResult: ", result1_again.result)

        @test result1.result == 5015
        @test result1_again.result == 5015
        @test result1.result == result1_again.result

        # Verify that main was cached on re-execution
        @test result1_again.rebuilt_main == false
    end

    @testset "Unmarked (default) behavior" begin
        println("\n\n=== Test 2: Unmarked (default) behavior ===")
        println("Code unchanged, unmarked code is part of main compilation")
        println("Expected: Main code is cached, reused when unchanged\n")

        code2 = quote
            a = 20              # Unmarked: part of main
            b = 30              # Unmarked: part of main
            c = a + b           # Unmarked: part of main
            @hole d = c * 2     # Hole: can be updated
            d
        end

        result2 = NB.run_cell!(session, code2; cell_id="cell_2")
        println("First execution (cell_2):")
        display(result2)
        println("\nResult: ", result2.result)

        # Re-execute - main is reused
        result2_again = NB.run_cell!(session, code2; cell_id="cell_2")
        println("\nRe-execution (cell_2):")
        display(result2_again)
        println("\nResult: ", result2_again.result)

        @test result2.result == 100
        @test result2_again.result == 100
        @test result2.result == result2_again.result

        # Verify that main was cached on re-execution
        @test result2_again.rebuilt_main == false
    end

    @testset "@hole annotation" begin
        println("\n\n=== Test 3: @hole annotation ===")
        println("Code changed, needs recompilation")
        println("Expected: Recompile only changed holes\n")

        code3a = quote
            x = 5
            @hole y = 10 * 2
            z = x + y
            z
        end

        result3a = NB.run_cell!(session, code3a; cell_id="cell_3")
        println("First execution with @hole y = 10 * 2 (cell_3):")
        display(result3a)
        println("\nResult: ", result3a.result)

        @test result3a.result == 25
        @test result3a.rebuilt_main == true  # First execution

        # Change the hole content
        code3b = quote
            x = 5
            @hole y = 10 * 3  # Changed from 10 * 2 to 10 * 3
            z = x + y
            z
        end

        result3b = NB.run_cell!(session, code3b; cell_id="cell_3")
        println("\nSecond execution with changed hole @hole y = 10 * 3 (cell_3):")
        display(result3b)
        println("\nResult: ", result3b.result)

        @test result3b.result == 35
        @test result3b.rebuilt_main == false  # Main was reused
        @test 1 in result3b.recompiled_holes   # Hole 1 was recompiled
    end

    @testset "Combined execution models" begin
        println("\n\n=== Test 4: Combined execution models ===")
        println("Mix of @persistent, unmarked, and @hole\n")

        code4 = quote
            @persistent constant_data = 1000  # Persistent: computed once
            regular_var = 50                  # Unmarked: recompiled if changed
            @hole dynamic_calc = 100 + 200   # Hole: can be updated independently
            result = constant_data + regular_var + dynamic_calc
            result
        end

        result4 = NB.run_cell!(session, code4; cell_id="cell_4")
        println("First execution (cell_4):")
        display(result4)
        println("\nResult: ", result4.result)

        @test result4.result == 1350
        @test result4.rebuilt_main == true  # First execution

        # Modify only the hole
        code4b = quote
            @persistent constant_data = 1000  # Unchanged
            regular_var = 50                  # Unchanged
            @hole dynamic_calc = 100 + 500   # Changed
            result = constant_data + regular_var + dynamic_calc
            result
        end

        result4b = NB.run_cell!(session, code4b; cell_id="cell_4")
        println("\nSecond execution with changed hole (cell_4):")
        display(result4b)
        println("\nResult: ", result4b.result)
        println("Notice: Only the hole was recompiled, main was reused")

        @test result4b.result == 1650
        @test result4b.rebuilt_main == false  # Main was reused
        @test 1 in result4b.recompiled_holes   # Hole 1 was recompiled
    end
end
