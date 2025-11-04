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

    @testset "Notebook simulation" begin
        include("test_demo.jl")
    end
end

println("\n" * "=" ^ 70)
println("All tests completed!")
