function get_descendants(expr)
    return expr.args
end

function has_same_label_and_value(expr1::Symbol, expr2::Symbol)
    return expr1 == expr2
end

function has_same_label_and_value(expr1::Expr, expr2::Expr)
    if expr1.head != expr2.head
        return false
    end

    for (arg1, arg2) in zip(expr1.args, expr2.args)
        if arg1 != arg2
            return false
        end
    end

    return true
end

function isomorphic(t1::Expr, t2::Expr)
    if !has_same_label_and_value(t1, t2)
        return false
    end

    t1_children = t1.args
    t2_children = t2.args

    if length(t1_children) != length(t2_children)
        return false
    end

    for (c1, c2) in zip(t1_children, t2_children)
        if c1 isa Expr && c2 isa Expr
           if !isomorphic(c1, c2)
               return false
           end
        end
    end

    return true
end

function test()
    prog1 = "x = 1; y = 2; z = a + b"
    ex = Meta.parse(prog1)
    dump(ex)
    println(get_descendants(ex))
end

# test()

function test2()
    prog1 = "x = 1"
    prog2 = "x = 21"
    ex1 = Meta.parse(prog1)
    ex2 = Meta.parse(prog2)
    println(has_same_label_and_value(ex1, ex2))
    println(isomorphic(ex1, ex2))
end

test2()
