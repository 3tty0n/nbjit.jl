using DataStructures
using PyCall
using Pkg

ENV["PYTHON"] = "/home/yusuke/.pyenv/versions/3.12.0/bin/python"
#Pkg.build("PyCall")

apted = pyimport("apted")

# Define a Python-compatible tree node
struct PyTreeNode
    name::String
    children::Vector{PyTreeNode}
end

function expr_to_pytree(expr)
    if expr isa Expr
        children = [expr_to_pytree(arg) for arg in expr.args]
        return PyTreeNode(string(expr.head), children)
    elseif expr isa Symbol
        return PyTreeNode(string(expr), [])
    else
        return PyTreeNode(string(expr), [])
    end
end

function pytree_to_expr(node)
    # Convert leaf node
    if isempty(node.children)
        try
            return Meta.parse(node.name)
        catch
            return Symbol(node.name)
        end
    end

    head = Symbol(node.name)
    args = [pytree_to_expr(c) for c in node.children]
    return Expr(head, args...)
end

function rename_cost(n1::PyTreeNode, n2::PyTreeNode)
    return n1.label == n2.label ? 0 : 1
end

insert_cost(node::PyTreeNode) = 1
delete_cost(node::PyTreeNode) = 1

function all_pairs(v1::Vector, v2::Vector)
    return [(x, y) for x in v1, y in v2]
end

function get_descendants(expr::Expr)
    result = []
    for arg in expr.args
        if arg isa Expr
            push!(result, arg)
        end
    end
    return result
end

function get_descendants(t::PyTreeNode)
    result = []
    for arg in t.children
        push!(result, arg)
    end
    return result
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

function has_same_label_and_value(t1::PyTreeNode, t2::PyTreeNode)
    if t1.name != t2.name
        return false
    end

    for (arg1, arg2) in zip(t1.children, t2.children)
        if arg1 != arg2
            return false
        end
    end

    return true
end

function get_height(node)
    height = 0
    q = Queue{Union{typeof(node), Nothing}}()
    enqueue!(q, node)
    enqueue!(q, nothing)
    while !isempty(q)
        curr = dequeue!(q)
        if curr === nothing
            height += 1
            if !isempty(q)
                enqueue!(q, nothing)
            end
        else
            for child in get_descendants(curr)
                enqueue!(q, child)
            end
        end
    end
    return height
end

function peek_max(l)
    if isempty(l)
        return -1
    else
        return maximum(keys(l))
    end
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

function isomorphic(t1::PyTreeNode, t2::PyTreeNode)
    if !has_same_label_and_value(t1, t2)
        return false
    end

    t1_children = t1.children
    t2_children = t2.children

    if length(t1_children) != length(t2_children)
        return false
    end

    for (c1, c2) in zip(t1_children, t2_children)
        if !isomorphic(c1, c2)
            return false
        end
    end
    return true
end

function open(node, priority_list)
    height = get_height(node)
    if !haskey(priority_list, height)
        priority_list[height] = Vector{typeof(node)}()
    end
    append!(priority_list[height], get_descendants(node))
end

function pop(l)
    max_height = peek_max(l)
    return pop!(l, max_height, Vector{Any}())
end

function make_height_indexed_list(t, l)
    l[get_height(t)] = [t]
    for child in get_descendants(t)
        make_height_indexed_list(child, l)
    end
end

function dice(t1, t2, M)
    t1_desc = get_descendants(t1)
    t2_desc = get_descendants(t2)
    common_anchors = sum(1 for (s1, _) in M if s1 in t1_desc; init=0)
    total_desc = length(t1_desc) + length(t2_desc)
    if total_desc > 0
        return (2 * common_anchors) / total_desc
    else
        return 0
    end
end

function top_down(T1, T2, minHeight=1)
    L1 = Dict{Int, Vector{typeof(T1)}}()
    L2 = Dict{Int, Vector{typeof(T2)}}()
    A = Vector{Tuple{typeof(T1), typeof(T2)}}()
    M = Set{Tuple{typeof(T1), typeof(T2)}}()

    make_height_indexed_list(T1, L1)
    make_height_indexed_list(T2, L2)

    while min(peek_max(L1), peek_max(L2)) >= minHeight # should be >
        if peek_max(L1) != peek_max(L2)
            if peek_max(L1) > peek_max(L2)
                for t in pop(L1)
                    open(t, L1)
                end
            else
                for t in pop(L2)
                    open(t, L2)
                end
            end
        else
            H1 = pop(L1)
            H2 = pop(L2)
            println(H1, " ", H2)
            for (t1, t2) in all_pairs(H1, H2)
                if isomorphic(t1, t2)
                    push!(A, (t1, t2))
                end
            end

            for t1 in H1
                if !any((t1, x) in A || (t1, x) in M for x in H2)
                    open(t1, L1)
                end
            end
            for t2 in H2
                if !any((x, t2) in A || (x, t2) in M for x in H1)
                    open(t2, L2)
                end
            end
        end
    end

    sort!(A, by = x -> -dice(x[1], x[2], M))
    while !isempty(A)
        (t1, t2) = popfirst!(A)
        push!(M, (t1, t2))
        A = [pair for pair in A if pair[1] != t1 && pair[2] != t2]
    end

    return M
end

function contains(T, M, edited=true)
    for (t1, t2) in M
        if edited
            if t2 == T
                return true
            end
        else
            if t1 == T
                return true
            end
        end
    end
    return false
end

function get_unmatched_nodes(T, M)
    result = []
    if !contains(T, M)
        push!(result, T)
    end
    for child in get_descendants(T)
        append!(result, get_unmatched_nodes_in_postorder(child, M))
    end
    result
end

function get_unmatched_nodes_in_postorder(T, M)
    result = []
    for child in get_descendants(T)
        append!(result, get_unmatched_nodes_in_postorder(child, M))
    end
    if !contains(T, M)
        push!(result, T)
    end
    return result
end

function opt(t1, t2)
    py_t1 = expr_to_pytree(t1)
    py_t2 = expr_to_pytree(t2)
    ed = apted.APTED(py_t1, py_t2)
    mapping = ed.compute_edit_mapping()
    return mapping
end

function ast_label(node)
    if isa(node, Expr)
        return string(node.head)
    elseif isa(node, Symbol)
        return string(node)
    elseif node === nothing
        return "nothing"
    else
        return string(node)  # for literals like numbers or strings
    end
end

function bottom_up(T1, T2, M, minDice=0.5, maxSize=100)
    for t1 in get_unmatched_nodes_in_postorder(T1, M)
        candidates = []
        for c in get_unmatched_nodes(T2, M)
            if has_same_label_and_value(t1, c) # && has_matched_children(c)
                push!(candidates, c)
            end
        end

        for t2 in candidates
            d = dice(t1, t2, M)
            if dice(t1, t2, M) > minDice # or >?
                push!(M, (t1, t2))
                if maximum([length(get_descendants(t1)), length(get_descendants(t2))]) < maxSize
                    R = opt(t1, t2)
                    for (ta, tb) in R
                        j_ta = pytree_to_expr(ta)
                        j_tb = pytree_to_expr(tb)
                        if ast_label(ta) == ast_label(t2)
                            push!(M, (j_ta, j_tb))
                        end
                    end
                end
            end
        end
    end

    return M
end

function test_apted()
    # Define your Julia expressions
    ex1 = :(a + b)
    ex2 = :(a - b)

    # Convert Julia expressions to PyTreeNode structures
    tree1 = expr_to_pytree(ex1)
    tree2 = expr_to_pytree(ex2)

    # Create an APTED instance and compute the edit distance
    apt = apted.APTED(tree1, tree2)
    distance = apt.compute_edit_distance()
    println("Edit distance: ", distance)

    mapping = apt.compute_edit_mapping()
    for (t1, t2) in mapping
        jt1 = pytree_to_expr(t1)
        jt2 = pytree_to_expr(t2)
        println("Mapping (converted): ", jt1, " : ", jt2)
    end
end

function test_bottom_up()
    ex1 = :(x = 1; y = 2)
    ex2 = :(x = 1; y = 3)

    t1 = expr_to_pytree(ex1)
    t2 = expr_to_pytree(ex2)

    M = top_down(t1, t2, 1)
    println(M)
    M = bottom_up(t1, t2, M)
    println(M)
end

test_bottom_up()
