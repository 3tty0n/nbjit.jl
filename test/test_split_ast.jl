include("../src/split_ast.jl")

using Test

function test()
    # println(SplitAst.collect_symbols(:(
    #     begin
    #         x = 1
    #         @hole y = 2
    #         z = x + y
    #     end
    # )))

    # println(SplitAst.collect_hole(:(
    #     begin
    #         x = 1
    #         @hole y = 2
    #         z = x + y
    #         begin
    #             @hole r = 1
    #             if r < 1
    #                 @hole z = z + r
    #             else
    #                 @hole x = 1000
    #             end
    #         end
    #     end
    # )))

    prog = :(
        begin
            x = 1
            @hole y = 2
            z = x + y
        end
    )

    ast_with_hole = SplitAst.convert_ast_with_hole(prog)
    println(ast_with_hole)
    println(SplitAst.split_at_hole(ast_with_hole))
    return true
end

@test test()
