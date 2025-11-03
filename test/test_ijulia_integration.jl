using Test

include("../src/ijulia_integration.jl")

session = IJuliaIntegration.NotebookSession()

@testset "Notebook session compilation" begin
    code1 = quote
        value = 10
        @hole delta = 2
        result = value + delta
    end

    res1 = IJuliaIntegration.run_cell!(session, code1; cell_id="cell1")
    @test res1.rebuilt_main
    @test res1.recompiled_holes == [1]

    res2 = IJuliaIntegration.run_cell!(session, code1; cell_id="cell1")
    @test !res2.rebuilt_main
    @test isempty(res2.recompiled_holes)

    code2 = quote
        value = 10
        @hole delta = 5
        result = value + delta
    end

    res3 = IJuliaIntegration.run_cell!(session, code2; cell_id="cell1")
    @test !res3.rebuilt_main
    @test res3.recompiled_holes == [1]

    code3 = quote
        value = 10
        temp = value + 1
        @hole delta = temp
        result = value + delta
    end

    res4 = IJuliaIntegration.run_cell!(session, code3; cell_id="cell1")
    @test res4.rebuilt_main
    @test res4.recompiled_holes == [1]
end

@testset "Auto cell ID detection" begin
    # Test that get_cell_id returns a valid string
    cell_id = IJuliaIntegration.get_cell_id()
    @test cell_id isa String
    @test !isempty(cell_id)

    # Test that we can use the auto-detected ID
    code = quote
        value = 100
        @hole offset = 5
        result = value + offset
    end

    res = IJuliaIntegration.run_cell!(session, code; cell_id=cell_id)
    @test res.rebuilt_main
    @test res.recompiled_holes == [1]

    # Running again with same ID should cache
    res2 = IJuliaIntegration.run_cell!(session, code; cell_id=cell_id)
    @test !res2.rebuilt_main
    @test isempty(res2.recompiled_holes)
end

@testset "@jit macro" begin
    # Test the @jit macro with auto-detection
    result = @eval IJuliaIntegration.@jit begin
        a = 5
        @hole b = 3
        c = a + b
    end

    @test result isa IJuliaIntegration.CellResult
    @test result.rebuilt_main
    @test result.recompiled_holes == [1]
end
