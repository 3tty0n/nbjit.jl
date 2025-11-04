using Test

include("../src/jit_dylib.jl")

@testset "Separate Dylib Compilation" begin
    println("\n=== Test 1: Initial Compilation to Separate Dylibs ===")

    code1 = quote
        x = 10
        @hole y = 5
        z = x + y
        z
    end

    println("Compiling code to separate dylibs...")
    compiled = compile_to_separate_dylibs(code1)

    # Check that separate libraries were created
    @test compiled.main_lib_path !== nothing
    @test isfile(compiled.main_lib_path)
    @test compiled.main_lib_handle != C_NULL
    println("✓ Main dylib created: ", basename(compiled.main_lib_path))

    @test length(compiled.hole_lib_paths) == 1
    @test isfile(compiled.hole_lib_paths[1])
    @test compiled.hole_lib_handles[1] != C_NULL
    println("✓ Hole 1 dylib created: ", basename(compiled.hole_lib_paths[1]))

    # Execute
    result1 = execute_dylib(compiled)
    @test result1 == 15
    println("✓ Execution result: ", result1, " (expected 15)")

    # Save library paths for inspection
    main_lib1 = compiled.main_lib_path
    hole_lib1 = compiled.hole_lib_paths[1]

    println("\n=== Test 2: Change Hole - Recompile Only Hole ===")

    code2 = quote
        x = 10
        @hole y = 20  # Changed from 5 to 20
        z = x + y
        z
    end

    println("Updating code with changed hole...")
    changed_holes, rebuilt_main = update_dylib!(compiled, code2)
    @test !rebuilt_main
    @test changed_holes == [1]

    # Check that hole library changed but main structure is tracked
    hole_lib2 = compiled.hole_lib_paths[1]
    @test hole_lib2 != hole_lib1  # New hole library created
    println("✓ Hole dylib recompiled: ", basename(hole_lib2))

    main_lib2 = compiled.main_lib_path
    @test main_lib2 == main_lib1  # Main dylib reused
    println("✓ Main dylib reused: ", basename(main_lib2))

    # Execute with new code
    result2 = execute_dylib(compiled)
    @test result2 == 30
    println("✓ Execution result: ", result2, " (expected 30)")

    println("\n=== Test 3: Change Main Structure - Full Recompilation ===")

    code3 = quote
        x = 100  # Changed from 10 to 100
        @hole y = 20
        z = x + y
        z
    end

    println("Updating code with changed main...")
    changed_holes3, rebuilt_main3 = update_dylib!(compiled, code3)
    @test rebuilt_main3
    @test changed_holes3 == [1]  # Hole rebuilt along with main

    result3 = execute_dylib(compiled)
    @test result3 == 120
    println("✓ Execution result: ", result3, " (expected 120)")

    println("\n=== Test 4: Multiple Holes ===")

    code4 = quote
        x = 10
        @hole a = 5
        @hole b = 3
        y = x + a + b
        y
    end

    println("Compiling code with multiple holes...")
    compiled2 = compile_to_separate_dylibs(code4)

    @test length(compiled2.hole_lib_paths) == 2
    @test all(isfile, compiled2.hole_lib_paths)
    println("✓ Created 2 hole dylibs:")
    for (i, path) in enumerate(compiled2.hole_lib_paths)
        println("  Hole $i: ", basename(path))
    end

    result4 = execute_dylib(compiled2)
    @test result4 == 18
    println("✓ Execution result: ", result4, " (expected 18)")

    println("\n=== Test 5: Change One of Multiple Holes ===")

    code5 = quote
        x = 10
        @hole a = 5
        @hole b = 7  # Changed from 3 to 7
        y = x + a + b
        y
    end

    hole1_before = compiled2.hole_lib_paths[1]
    hole2_before = compiled2.hole_lib_paths[2]

    println("Updating code with second hole changed...")
    changed_holes5, rebuilt_main5 = update_dylib!(compiled2, code5)
    @test !rebuilt_main5
    @test changed_holes5 == [2]

    # Ensure only second hole dylib changed
    hole1_after = compiled2.hole_lib_paths[1]
    hole2_after = compiled2.hole_lib_paths[2]
    @test hole1_after == hole1_before
    @test hole2_after != hole2_before
    println("✓ Hole 2 dylib recompiled: ", basename(hole2_after))

    result5 = execute_dylib(compiled2)
    @test result5 == 22
    println("✓ Execution result: ", result5, " (expected 22)")

    println("\n=== Test 6: Performance - Multiple Executions ===")

    println("Executing 1000 times to measure dylib call overhead...")
    total_time = @elapsed begin
        for i in 1:1000
            result = execute_dylib(compiled2)
            @assert result == 22
        end
    end
    println("✓ 1000 executions in ", round(total_time * 1000, digits=2), " ms")
    println("  Average: ", round(total_time * 1000000 / 1000, digits=2), " μs per execution")

    # Cleanup
    println("\n=== Cleanup ===")
    cleanup_dylib!(compiled)
    cleanup_dylib!(compiled2)
    println("✓ All dylibs cleaned up")
end
