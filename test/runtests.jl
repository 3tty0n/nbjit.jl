using Test

println("Running nbjit.jl Test Suite\n")
println("=" ^ 70)

@testset "nbjit.jl Test Suite" begin
    @testset "Partial evaluation (constant folding)" begin
        include("test_peval.jl")
    end

    @testset "JIT Backend" begin
        include("test_jit.jl")
    end

    @testset "Dylib JIT Backends" begin
        include("test_jit_dylib.jl")
    end

    @testset "JIT Compilation Runtime w/ AST Splitting" begin
        include("test_jit_split.jl")
    end

    @testset "JIT Compilation for Imported modules" begin
        include("test_imports.jl")
    end

    @testset "Execution model" begin
        include("test_execution_models.jl")
    end

    @testset "Notebook simulation" begin
        include("test_demo.jl")
    end

    @testset "Array and Float64 support" begin
        include("test_array_and_float.jl")
    end

    @testset "Inter-cell dependency tracking" begin
        include("test_cell_deps.jl")
    end

    @testset "Automatic hole detection" begin
        include("test_auto_diff.jl")
    end

    @testset "GumTree tree diff" begin
        include("test_tree_diff.jl")
    end
end

println("\n" * "=" ^ 70)
println("All tests completed!")
