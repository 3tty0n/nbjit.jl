"""
Tests for imported library support in nbjit
"""

using Test

# Include the main jit module (via ijulia_integration which handles all includes)
include("test_helper.jl")
using .IJuliaIntegration

# Import specific functions from the module for testing
const is_module_call = IJuliaIntegration.is_module_call
const parse_module_call = IJuliaIntegration.parse_module_call
const extract_import_statements = IJuliaIntegration.extract_import_statements
const register_imports! = IJuliaIntegration.register_imports!
const ImportContext = IJuliaIntegration.ImportContext
const generate_runtime_func_name = IJuliaIntegration.generate_runtime_func_name
const create_external_call_bridge = IJuliaIntegration.create_external_call_bridge
const setup_external_call = IJuliaIntegration.setup_external_call
const get_external_func_pointer = IJuliaIntegration.get_external_func_pointer
const generate_IR = IJuliaIntegration.generate_IR

# LLVM is used in the module
using LLVM

@testset "Import Parsing" begin
    @testset "Extract using statements" begin
        # Single module
        expr1 = :(using LinearAlgebra)
        imports1 = extract_import_statements(expr1)
        @test length(imports1) == 1
        @test imports1[1][1] == :using
        @test imports1[1][2] == [:LinearAlgebra]

        # Module with specific imports
        expr2 = :(using Statistics: mean, std)
        imports2 = extract_import_statements(expr2)
        @test length(imports2) == 1
        @test imports2[1][1] == :using
        @test imports2[1][2] == [:Statistics]
        @test :mean in imports2[1][3]
        @test :std in imports2[1][3]
    end

    @testset "Extract import statements" begin
        expr = :(import Base.Iterators)
        imports = extract_import_statements(expr)
        @test length(imports) >= 1
    end

    @testset "Module qualified call detection" begin
        # Simple module call
        expr1 = :(Math.sin(x))
        @test is_module_call(expr1)

        # Not a module call
        expr2 = :(sin(x))
        @test !is_module_call(expr2)

        # Nested module call
        expr3 = :(Base.Math.sin(x))
        @test is_module_call(expr3)
    end

    @testset "Parse module call" begin
        expr = :(LinearAlgebra.norm(v))
        parsed = parse_module_call(expr)
        @test parsed !== nothing
        module_path, func_name, args = parsed
        @test module_path == [:LinearAlgebra]
        @test func_name == :norm
        @test length(args) == 1
    end
end

@testset "Import Context" begin
    ctx = ImportContext()

    @testset "Module registration" begin
        # Register Base module
        register_imports!(ctx, :(using Base))
        @test haskey(ctx.modules, :Base)
    end

    @testset "Direct imports" begin
        # Reset context
        ctx2 = ImportContext()

        # This should register specific functions from Base
        code = quote
            using Base: println, print
        end
        register_imports!(ctx2, code)
        # Check that direct imports were registered
        @test haskey(ctx2.direct_imports, :println) || haskey(ctx2.modules, :Base)
    end

    @testset "Session import preprocessing" begin
        session = IJuliaIntegration.NotebookSession()
        IJuliaIntegration.apply_imports!(session, quote
            using LinearAlgebra
            using Statistics: mean
        end)
        @test haskey(session.import_context.modules, :LinearAlgebra)
        @test haskey(session.import_context.direct_imports, :mean)
    end
end

@testset "External Call Bridges" begin
    @testset "Bridge function name generation" begin
        name = generate_runtime_func_name([:LinearAlgebra], :norm)
        @test occursin("LinearAlgebra", name)
        @test occursin("norm", name)
    end

    @testset "Create bridge for Base function" begin
        # Test with a simple Base function
        bridge = create_external_call_bridge(Base, :length, 1)
        @test bridge isa Function

        # Test calling the bridge
        arr = [1, 2, 3]
        arr_ptr = pointer_from_objref(arr)
        result_ptr = bridge(arr_ptr)
        @test result_ptr != C_NULL
    end

    @testset "Setup external call" begin
        # Test setting up an external call for Base.length
        # Note: @cfunction with closures is not supported on some platforms (e.g., ARM64)
        # so we test the name generation and dispatch table setup, not the cfunction pointer
        runtime_name = generate_runtime_func_name([:Base], :length)
        @test !isempty(runtime_name)
        @test occursin("Base", runtime_name)
        @test occursin("length", runtime_name)

        # Test that the bridge function can be created and called
        bridge = create_external_call_bridge(Base, :length, 1)
        @test bridge isa Function

        # Test calling the bridge through Julia (not via cfunction)
        arr = [1, 2, 3, 4, 5]
        arr_ptr = pointer_from_objref(arr)
        result_ptr = bridge(arr_ptr)
        @test result_ptr != C_NULL
    end
end

@testset "Integration - Module Calls in JIT" begin
    @testset "Simple function compilation" begin
        # Test basic compilation still works
        code = quote
            function test_add()
                x = 5
                return x + 1
            end
        end

        ctx = LLVM.Context()
        try
            mod = generate_IR(ctx, code)
            @test mod !== nothing
            @test haskey(LLVM.functions(mod), "test_add")
        finally
            LLVM.dispose(ctx)
        end
    end

    @testset "Module call code generation" begin
        # Test that module-qualified calls generate correct IR
        # Note: This test verifies the AST detection works correctly
        code = quote
            x = 10
            y = Base.abs(-5)
            x + y
        end

        # Check that module call is detected
        @test is_module_call(:(Base.abs(-5)))

        # Parse the module call
        parsed = parse_module_call(:(Base.abs(-5)))
        @test parsed !== nothing
        module_path, func_name, args = parsed
        @test module_path == [:Base]
        @test func_name == :abs
        @test length(args) == 1
    end
end

@testset "Integration - Direct Import Calls in JIT" begin
    session = IJuliaIntegration.NotebookSession()
    res = IJuliaIntegration.run_cell!(session, quote
        using LinearAlgebra: norm
        v = [3.0, 4.0]
        n = norm(v)
    end; cell_id="direct_import_norm")
    @test res.result ≈ 5.0
end

@testset "Import Calls Observe Committed Globals" begin
    # Module function used as an imported/external call target.
    if !isdefined(Main, :NBJitImportTxnDemo)
        Core.eval(Main, :(module NBJitImportTxnDemo
            get_x() = Main.IJuliaIntegration.ACTIVE_GLOBAL_BINDINGS[][:x]
        end))
    end

    session = IJuliaIntegration.NotebookSession()

    # Commit x = 10
    IJuliaIntegration.run_cell!(session, quote
        x = 10
        @hole delta = 0
        x = x + delta
    end; cell_id="txn_seed")

    # Simulate an in-flight cell write (staged update) and ensure imported
    # code still sees the committed snapshot.
    IJuliaIntegration.nbjit_begin_global_transaction!(session.global_bindings)
    cname = Base.cconvert(Cstring, "x")
    ptr = Base.unsafe_convert(Ptr{UInt8}, cname)
    IJuliaIntegration.nbjit_global_set_int64(ptr, 99)

    # Import-side read should observe committed value, not staged write.
    @test Main.NBJitImportTxnDemo.get_x() == 10

    # Commit and verify imported code now sees the new value.
    IJuliaIntegration.nbjit_commit_global_transaction!()
    @test Main.NBJitImportTxnDemo.get_x() == 99
end

println("Import tests completed!")
