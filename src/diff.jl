using Base: max_values
using DataStructures

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

function dice(t1, t2, mapping)
    t1_descendants = get_descendants(t1)
    t2_descendants = get_descendants(t2)
    return
end

function max(a, b)
    if a > b
        return a
    else
        return b
    end
end

function get_height(expr)
    queue = Deque{Tuple{Any, Int}}()
    push!(queue, (expr, 1))
    max_depth = 0

    while !isempty(queue)
        node, depth = popfirst!(queue)
        max_depth = max(max_depth, depth)

        if node isa Expr
            for arg in node.args
                push!(queue, (arg, depth + 1))
            end
        end
    end

    return max_depth - 1
end

function push(expr, l)
    push!(l[get_height(expr)], expr)
end

function peek_max(l)
    if isempty(l)
        return -1
    else
        return maximum(keys(l))
    end
end

function pop(l)
    max_height = peek_max(l)
    return l[max_height]
end

function make_height_indexed_list(t, l)
    push!(l[get_height(t)], l)
    for child in get_descendants(t)
        if child isa Expr
            make_height_indexed_list(child, l)
        end
    end
end

function top_down(t1, t2, minHeight=1)
    L1 = Dict()
    L2 = Dict()
    A = []
    M = Set()

    make_height_indexed_list(t1, L1)
    make_height_indexed_list(t2, L2)
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

    ex = :(a + b * (c - d))
    println(get_height(ex))
end

test2()
