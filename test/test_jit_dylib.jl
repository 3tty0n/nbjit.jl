using Test

include("../src/jit_dylib.jl")

@testset "Separate Dylib Compilation" begin
    code1 = quote
        x = 10
        @hole y = 5
        z = x + y
        z
    end

    compiled = compile_to_separate_dylibs(code1)

    # Check that separate libraries were created
    @test compiled.main_lib_path !== nothing
    @test isfile(compiled.main_lib_path)
    @test compiled.main_lib_handle != C_NULL

    @test length(compiled.hole_lib_paths) == 1
    @test isfile(compiled.hole_lib_paths[1])
    @test compiled.hole_lib_handles[1] != C_NULL

    # Execute
    result1 = execute_dylib(compiled)
    @test result1 == 15

    # Save library paths for inspection
    main_lib1 = compiled.main_lib_path
    hole_lib1 = compiled.hole_lib_paths[1]

    code2 = quote
        x = 10
        @hole y = 20  # Changed from 5 to 20
        z = x + y
        z
    end

    changed_holes, rebuilt_main = update_dylib!(compiled, code2)
    @test !rebuilt_main
    @test changed_holes == [1]

    # Check that hole library changed but main structure is tracked
    hole_lib2 = compiled.hole_lib_paths[1]
    @test hole_lib2 != hole_lib1  # New hole library created

    main_lib2 = compiled.main_lib_path
    @test main_lib2 == main_lib1  # Main dylib reused

    # Execute with new code
    result2 = execute_dylib(compiled)
    @test result2 == 30

    code3 = quote
        x = 100  # Changed from 10 to 100
        @hole y = 20
        z = x + y
        z
    end

    changed_holes3, rebuilt_main3 = update_dylib!(compiled, code3)
    @test rebuilt_main3
    @test changed_holes3 == [1]  # Hole rebuilt along with main

    result3 = execute_dylib(compiled)
    @test result3 == 120

    code4 = quote
        x = 10
        @hole a = 5
        @hole b = 3
        y = x + a + b
        y
    end

    compiled2 = compile_to_separate_dylibs(code4)

    @test length(compiled2.hole_lib_paths) == 2
    @test all(isfile, compiled2.hole_lib_paths)

    result4 = execute_dylib(compiled2)
    @test result4 == 18

    code5 = quote
        x = 10
        @hole a = 5
        @hole b = 7  # Changed from 3 to 7
        y = x + a + b
        y
    end

    hole1_before = compiled2.hole_lib_paths[1]
    hole2_before = compiled2.hole_lib_paths[2]

    changed_holes5, rebuilt_main5 = update_dylib!(compiled2, code5)
    @test !rebuilt_main5
    @test changed_holes5 == [2]

    # Ensure only second hole dylib changed
    hole1_after = compiled2.hole_lib_paths[1]
    hole2_after = compiled2.hole_lib_paths[2]
    @test hole1_after == hole1_before
    @test hole2_after != hole2_before

    # Cleanup
    cleanup_dylib!(compiled)
    cleanup_dylib!(compiled2)
end
