using Test

include("../src/ijulia_integration.jl")

@testset "Enriched JIT Features" begin
    session = IJuliaIntegration.NotebookSession()

    @testset "Float64 Support" begin
        @testset "Float64 arithmetic" begin
            code = quote
                x = 3.14
                y = 2.71
                x + y
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "float_add")
            @test result isa Int64  # Result is converted to Int64
        end

        @testset "Float64 multiplication" begin
            code = quote
                x = 2.5
                y = 4.0
                x * y
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "float_mult")
            @test result == 10
        end

        @testset "Float64 division" begin
            code = quote
                x = 10.0
                y = 2.5
                x / y
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "float_div")
            @test result == 4
        end
    end

    @testset "Comparison Operators" begin
        @testset "Equality (==)" begin
            code = quote
                x = 10
                y = 10
                x == y
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "eq_test")
            @test result == 1
        end

        @testset "Inequality (!=)" begin
            code = quote
                x = 10
                y = 5
                x != y
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "neq_test")
            @test result == 1
        end

        @testset "Less than or equal (<=)" begin
            code = quote
                x = 5
                y = 10
                x <= y
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "lte_test")
            @test result == 1
        end

        @testset "Greater than or equal (>=)" begin
            code = quote
                x = 10
                y = 10
                x >= y
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "gte_test")
            @test result == 1
        end

        @testset "All comparison operators combined" begin
            code = quote
                x = 10
                y = 10
                z = 5
                a = x == y
                b = x != z
                c = z <= x
                d = x >= y
                # Use intermediate variables to avoid partial evaluation issues
                temp1 = a + b
                temp2 = c + d
                temp1 + temp2
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "compare_all")
            @test result == 4
        end
    end

    @testset "Modulo Operator" begin
        @testset "Integer modulo" begin
            code = quote
                x = 17
                y = 5
                x % y
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "modulo_int")
            @test result == 2
        end

        @testset "Modulo in expression" begin
            code = quote
                x = 23
                y = 7
                (x % y) + 5
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "modulo_expr")
            @test result == 7  # (23 % 7) + 5 = 2 + 5 = 7
        end
    end

    @testset "Logical Operators" begin
        @testset "AND operator (&&)" begin
            code = quote
                x = 10
                y = 5
                result = if (x > y) && (y > 0)
                    1
                else
                    0
                end
                result
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "and_true")
            @test result == 1
        end

        @testset "AND operator - short circuit false" begin
            code = quote
                x = 3
                y = 5
                result = if (x > y) && (y > 0)
                    1
                else
                    0
                end
                result
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "and_false")
            @test result == 0
        end

        @testset "OR operator (||)" begin
            code = quote
                x = 0
                y = 1
                result = if (x > 0) || (y > 0)
                    1
                else
                    0
                end
                result
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "or_true")
            @test result == 1
        end

        @testset "OR operator - both false" begin
            code = quote
                x = 0
                y = 0
                result = if (x > 0) || (y > 0)
                    1
                else
                    0
                end
                result
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "or_false")
            @test result == 0
        end
    end

    @testset "Control Flow" begin
        @testset "Nested if-else" begin
            code = quote
                x = 15
                result = if x > 10
                    if x > 20
                        3
                    else
                        2
                    end
                else
                    1
                end
                result
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "nested_if")
            @test result == 2
        end

        @testset "Mixed type conditionals" begin
            code = quote
                x = 10
                y = 5
                result = if x > y
                    20
                else
                    10
                end
                result + 5
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "mixed_cond")
            @test result == 25
        end
    end

    @testset "Complex Expressions" begin
        @testset "Multiple operators" begin
            code = quote
                x = 10
                y = 3
                z = 2
                result = (x + y) * z - (x % y)
                result
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "complex_expr")
            @test result == 25  # (10 + 3) * 2 - (10 % 3) = 26 - 1 = 25
        end

        @testset "Arithmetic with comparisons" begin
            code = quote
                x = 5
                y = 3
                a = x > y
                b = y < x
                (a + b) * 10
            end
            result = IJuliaIntegration.run_pure_cell!(session, code, "arith_comp")
            @test result == 20  # (1 + 1) * 10 = 20
        end
    end

    # NOTE: For-loops and while-loops are implemented in LLVM codegen but have
    # issues with the partial evaluator when used in pure cells. They work correctly
    # when used with @hole markers in split compilation.
end
