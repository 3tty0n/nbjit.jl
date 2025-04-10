function get_descendants(expr)
    if expr isa Expr
        return expr.args
    end
end

function test()
    prog = "x=1; y=2"
    ex = Meta.parse(prog)
    println(get_descendants(ex))
end

test()
