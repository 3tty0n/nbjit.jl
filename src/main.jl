include("./split_jit.jl")

"""
    run_file(path; env=Dict{Symbol,Any}())

Compile the code at `path` using the split JIT runtime and execute it against
an optional environment dictionary. The resulting bindings from the execution
are merged back into `env`, which is also returned to the caller.
"""
function run_file(path; env::Dict{Symbol,Any}=Dict{Symbol,Any}())
    source = read(path, String)
    code = Meta.parse(source)
    compiled = split_and_compile(code)
    println("Main function: $(compiled.main_fname) with inputs $(compiled.main_inputs)")
    for (i, fname) in enumerate(compiled.hole_fnames)
        println("Hole $i -> $(fname) with inputs $(compiled.hole_inputs[i])")
    end
    return compiled
end

function main(path)
    run_file(path)
end

if abspath(PROGRAM_FILE) == @__FILE__ && !isempty(ARGS)
    main(ARGS[1])
end
