using Test

println("Running nbjit.jl Test Suite\n")
println("=" ^ 70)

@testset "nbjit.jl Test Suite" begin
    @testset "Pure Cell Caching" begin
        include("test_pure_cache.jl")
    end

    @testset "Split JIT Compilation" begin
        include("test_split_jit.jl")
    end

    @testset "@cache Macro" begin
        include("test_cache_macro.jl")
    end

    @testset "JIT Features" begin
        include("test_jit.jl")
    end
end

println("\n" * "=" ^ 70)
println("All tests completed!")
