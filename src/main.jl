include("./peval.jl")
include("./jit.jl")

function main(path)
    # read file
    f = open(path, "r")
    s = read(f, String)
    ex = Meta.parse(s)

    # partial the source program
    @show func_expr, fname = partial_evaluate_and_make_entry(ex)

    # compile code and run
    # TODO: think about the way to integrate with notebook
    res = compile_and_run(func_expr, string(fname), 123)
    println(res)
end

main(ARGS[1])
