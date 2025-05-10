using DataStructures
using PyCall
using Pkg

ENV["PYTHON"] = "/home/yusuke/.pyenv/versions/3.12.0/bin/python"
# Pkg.build("PyCall")

apted = pyimport("apted")

@pydef mutable struct CustomConfig <: apted.Config
    function rename(self, node1, node2)
        return node1.label == node2.label ? 0 : 1
    end

    function children(self, node)
        return node.children
    end
end


function all_pairs(v1::Vector, v2::Vector)
    return [(x, y) for x in v1, y in v2]
end

mutable struct TreeNode
    label::Any
    children::Vector{TreeNode}
end

function is_leaf(node)
    return isempty(node.children)
end

function expr_to_treenode(expr)::TreeNode
    if expr isa Expr
        children = [expr_to_treenode(arg) for arg in expr.args]
        return TreeNode(expr.head, children)
    elseif isprimitivetype(expr)
        return TreeNode(expr, [])
    else
        return TreeNode(expr, [])
    end
end

# Height calculation function for a tree node
function height(node::TreeNode)
    if isempty(node.children)
        return 1
    else
        return 1 + maximum(height(child) for child in node.children)
    end
end

# open(t, l) inserts all the children of t into l
function open(node::TreeNode, L::Dict{Int, Vector{TreeNode}})
    for child in get_descendants(node)
        if haskey(L, height(child))
            push!(L[height(child)], child)
        else
            L[height(child)] = [child]
        end
    end
end

# Function to check isomorphism between two trees
function isomorphic(t1::TreeNode, t2::TreeNode)
    if is_leaf(t1) || is_leaf(t2)
        return false
    end

    if t1.label != t2.label
        return false
    end

    if length(t1.children) != length(t2.children)
        return false
    end

    for (c1, c2) in zip(t1.children, t2.children)
        # TODO: should we check all children?
        # if !isomorphic(c1, c2)
        #     return false
        # end
        if c1.label != c2.label
            return false
        end
    end

    return true
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

function peek(l::Dict{Int, Vector{TreeNode}})
    if isempty(l)
        return -1
    else
        return maximum(keys(l))
    end
end

function pop(l)
    max_height = peek(l)
    return pop!(l, max_height, Vector{Any}())
end

function push(l, height, t)
    if haskey(l, height)
        push!(l[height], t)
    else
        l[height] = [t]
    end
end

function get_descendants(T::TreeNode)
    result = []
    for child in T.children
        if !(child in result)
            push!(result, child)
        end
        append!(result, get_descendants(child))
    end
    return result
end

function make_height_indexed_list(t, l::Dict{Int64, Vector{TreeNode}})
    l[height(t)] = [t]
    for child in get_descendants(t)
        make_height_indexed_list(child, l)
    end
end

function top_down(T1, T2, minHeight=2)
    # Priority Queue for height-indexed priority lists
    L1 = Dict{Int, Vector{TreeNode}}()
    L2 = Dict{Int, Vector{TreeNode}}()

    # Candidate mappings and final set of mappings
    A = []  # List of candidate mappings
    M = Set()  # Set of final mappings

    # make_height_indexed_list(T1, L1)
    # make_height_indexed_list(T2, L2)
    push(L1, height(T1), T1)
    push(L2, height(T2), T2)

    while min(peek(L1), peek(L2)) > minHeight
        if peek(L1) != peek(L2)
            if peek(L1) > peek(L2)
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

            for (t1, t2) in all_pairs(H1, H2)
                if isomorphic(t1, t2)
                    for tx in get_descendants(T2)
                        if isomorphic(t1, tx) && tx != t2
                            if !is_leaf(t1) && !is_leaf(t2)
                                push!(A, (t1, t2))
                            end
                        end
                    end
                    for tx in get_descendants(T1)
                        if isomorphic(tx, t2) && tx != t1
                            if !is_leaf(t1) && !is_leaf(t2)
                                push!(A, (t1, t2))
                            end
                        end
                    end
                    for st1 in get_descendants(t1), st2 in get_descendants(t2)
                        if isomorphic(st1, st2)
                            if !is_leaf(t1) && !is_leaf(t2)
                                push!(M, (st1, st2))
                            end
                        end
                    end
                end
            end

            for t1 in H1
                if !any((t1, tx) in union(A, M) for tx in H2)
                    open(t1, L1)
                end
            end

            for t2 in H2
                if !any((tx, t2) in union(A, M) for tx in H1)
                    open(t2, L2)
                end
            end
        end
    end

    # Sorting A using the dice function
    sort!(A, by = x -> dice(x[1], x[2], M))

    while !isempty(A)
        (t1, t2) = popfirst!(A)
        A = filter(x -> x[1] != t1 && x[2] != t2, A)
        push!(M, (t1, t2))
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

function has_matched_children(T, M)
    for child in get_descendants(T)
        if contains(child, M)
            return true
        end
        has_matched_children(child, M)
    end

    return false
end

function opt(t1, t2)
    apt = apted.APTED(t1, t2, CustomConfig())
    mapping = apt.compute_edit_mapping()
    return mapping
end

function bottom_up(T1, T2, M, minDice=0.5, maxSize=100)
    for t1 in get_unmatched_nodes_in_postorder(T1, M)
        candidates = []
        for c in get_unmatched_nodes(T2, M)
            if t1.label == c.label && has_matched_children(c, M)
                push!(candidates, c)
            end
        end

        for t2 in candidates
            d = dice(t1, t2, M)
            if d > minDice
                if !is_leaf(t1) && !is_leaf(t2)
                    push!(M, (t1, t2))
                end
                if maximum([length(get_descendants(t1)), length(get_descendants(t2))]) < maxSize
                    R = opt(t1, t2)
                    for (ta, tb) in R
                        if ta == tb
                            if !is_leaf(ta) && !is_leaf(tb)
                                push!(M, (ta, tb))
                            end
                        end
                    end
                end
            end
        end
    end

    return M
end

function print_mapping(M)
    for (t1, t2) in M
        println(t1, "\nmaps to\n", t2, "\n")
    end
end

ex1 = Meta.parse("""
function foo()
    x = 1
    y = 2
    if x < 1
        z = 3
        z = 3
    end
end""")

ex2 = Meta.parse("""
function foo()
    x = 1
    y = 2
    if x <= 1
        z = 3
        z = 293
    end
end""")


t1 = expr_to_treenode(ex1)
t2 = expr_to_treenode(ex2)

M = top_down(t1, t2, 2)
M = bottom_up(t1, t2, M, 0.5, 100)
print_mapping(M)
