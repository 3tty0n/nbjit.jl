using Test

println("Running nbjit.jl Test Suite\n")
println("=" ^ 70)

@testset "nbjit.jl Test Suite" begin
    @testset "Partial evaluation (constant folding)" begin
        include("test_peval.jl")
    end

    @testset "Split JIT Compilation" begin
        include("test_split_jit.jl")
    end

    @testset "JIT Features" begin
        include("test_jit.jl")
    end

    @testset "Dylib JIT features" begin
        include("test_jit_dylib.jl")
    end

    @testset "Notebook simulation" begin
        include("test_demo.jl")
    end
end

println("\n" * "=" ^ 70)
println("All tests completed!")
