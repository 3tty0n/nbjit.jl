using Test

include("test_helper.jl")

@testset "Float64 Return Values (M2)" begin
    session = IJuliaIntegration.NotebookSession()

    @testset "Pure cell Float64 return" begin
        code = quote
            x = 3.14
            y = 2.71
            x + y
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m2_float_add")
        @test result isa Float64
        @test result ≈ 5.85
    end

    @testset "Pure cell Float64 multiplication" begin
        code = quote
            x = 2.5
            y = 4.0
            x * y
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m2_float_mul")
        @test result isa Float64
        @test result ≈ 10.0
    end

    @testset "Pure cell Float64 division" begin
        code = quote
            x = 10.0
            y = 3.0
            x / y
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m2_float_div")
        @test result isa Float64
        @test result ≈ 10.0 / 3.0
    end

    @testset "Pure cell Int64 return preserved" begin
        code = quote
            x = 10
            y = 20
            x + y
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m2_int_add")
        @test result isa Int64
        @test result == 30
    end

    @testset "Dylib Float64 return with @hole" begin
        code = quote
            @preserve base = 3.14
            @hole scale = 2.0
            result = base * scale
            result
        end
        result = IJuliaIntegration.run_cell!(session, code; cell_id="m2_dylib_float")
        @test result.result isa Float64
        @test result.result ≈ 6.28
    end

    @testset "Dylib Float64 return - hole change" begin
        code1 = quote
            @preserve base = 3.14
            @hole scale = 2.0
            result = base * scale
            result
        end
        result1 = IJuliaIntegration.run_cell!(session, code1; cell_id="m2_dylib_change")

        code2 = quote
            @preserve base = 3.14
            @hole scale = 3.0
            result = base * scale
            result
        end
        result2 = IJuliaIntegration.run_cell!(session, code2; cell_id="m2_dylib_change")
        @test result2.result isa Float64
        @test result2.result ≈ 9.42
    end

    @testset "Mixed int/float promotion" begin
        code = quote
            x = 10
            y = 2.5
            x + y
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m2_mixed")
        @test result isa Float64
        @test result ≈ 12.5
    end

    @testset "Float64 in loop accumulation" begin
        code = quote
            result = 0.0
            for i in 1:5
                result = result + 1.5
            end
            result
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m2_float_loop")
        @test result isa Float64
        @test result ≈ 7.5
    end
end

@testset "Array Type Support (M1)" begin
    session = IJuliaIntegration.NotebookSession()

    @testset "zeros() creates Float64 array" begin
        code = quote
            arr = zeros(5)
            length(arr)
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m1_zeros")
        @test result == 5
    end

    @testset "ones() creates Float64 array" begin
        code = quote
            arr = ones(3)
            length(arr)
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m1_ones")
        @test result == 3
    end

    @testset "Array literal [1, 2, 3]" begin
        code = quote
            arr = [10, 20, 30]
            arr[2]
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m1_int_literal")
        @test result == 20
    end

    @testset "Float64 array literal [1.0, 2.0, 3.0]" begin
        code = quote
            arr = [1.5, 2.5, 3.5]
            arr[1]
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m1_float_literal")
        @test result isa Float64
        @test result ≈ 1.5
    end

    @testset "Array setindex!" begin
        code = quote
            arr = zeros(3)
            arr[1] = 10.0
            arr[2] = 20.0
            arr[3] = 30.0
            arr[2]
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m1_setindex")
        @test result isa Float64
        @test result ≈ 20.0
    end

    @testset "Array in loop - sum" begin
        code = quote
            arr = [10, 20, 30, 40, 50]
            total = 0
            for i in 1:5
                total = total + arr[i]
            end
            total
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m1_loop_sum")
        @test result == 150
    end

    @testset "Array with zeros and accumulation" begin
        code = quote
            arr = zeros(5)
            for i in 1:5
                arr[i] = i * 2.0
            end
            arr[3]
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m1_zeros_fill")
        @test result isa Float64
        @test result ≈ 6.0
    end

    @testset "Array length in loop bound" begin
        code = quote
            arr = [1, 2, 3, 4]
            n = length(arr)
            total = 0
            for i in 1:n
                total = total + arr[i]
            end
            total
        end
        result = IJuliaIntegration.run_pure_cell!(session, code, "m1_length_loop")
        @test result == 10
    end

    @testset "Array with @hole parameter" begin
        code = quote
            @preserve n = 5
            @hole scale = 3
            arr = [1, 2, 3, 4, 5]
            total = 0
            for i in 1:n
                total = total + arr[i] * scale
            end
            total
        end
        result = IJuliaIntegration.run_cell!(session, code; cell_id="m1_hole_array")
        @test result.result == 45  # (1+2+3+4+5)*3 = 45
    end
end
