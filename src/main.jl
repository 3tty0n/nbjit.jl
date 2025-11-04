include("./jit_dylib.jl")

"""
    run_file(path; env=Dict{Symbol,Any}())

Compile the code at `path` using the separate dylib JIT runtime and execute it.
"""
function run_file(path; env::Dict{Symbol,Any}=Dict{Symbol,Any}())
    source = read(path, String)
    code = Meta.parse(source)
    compiled = compile_to_separate_dylibs(code)

    println("Main dylib: $(compiled.main_lib_path)")
    println("Holes:")
    for (i, name) in enumerate(compiled.hole_func_names)
        println("  [$i] $(name) -> $(compiled.hole_lib_paths[i])")
    end

    result = execute_dylib(compiled)
    cleanup_dylib!(compiled)
    return result
end

function main(path)
    run_file(path)
end

if abspath(PROGRAM_FILE) == @__FILE__ && !isempty(ARGS)
    main(ARGS[1])
end
