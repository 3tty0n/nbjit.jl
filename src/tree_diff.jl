"""
Pure Julia implementation of the GumTree algorithm for AST differencing.

Reference: Falleri et al., "Fine-grained and Accurate Source Code Differencing" (ASE 2014)

The algorithm has two phases:
1. Top-down: greedily match isomorphic subtrees from largest to smallest
2. Bottom-up: match remaining nodes using dice similarity + optimal recovery

This replaces the PyCall-dependent diff.jl with a self-contained implementation.
"""

# ─── Tree representation ───────────────────────────────────────────────

mutable struct ASTNode
    label::String           # Expr head (e.g. "=", "call", "block") or type tag for leaves
    value::Any              # Literal value for leaves, nothing for inner nodes
    children::Vector{ASTNode}
    parent::Union{Nothing, ASTNode}
    id::Int                 # Unique ID within a tree
    height::Int             # Precomputed height (1 for leaves)
    size::Int               # Number of nodes in subtree (including self)
    hash::UInt64            # Structure+value hash for fast isomorphism checks
end

# Global ID counter for tree construction
const _NODE_ID_COUNTER = Ref(0)

function _next_node_id()
    _NODE_ID_COUNTER[] += 1
    return _NODE_ID_COUNTER[]
end

function reset_node_ids!()
    _NODE_ID_COUNTER[] = 0
end

"""
    expr_to_tree(expr) -> ASTNode

Convert a Julia Expr (or literal) into an ASTNode tree.
LineNumberNodes are skipped.
"""
function expr_to_tree(expr::Expr)
    children = ASTNode[]
    for arg in expr.args
        if arg isa LineNumberNode
            continue
        end
        child = expr_to_tree(arg)
        push!(children, child)
    end
    node = ASTNode(string(expr.head), nothing, children, nothing, _next_node_id(), 0, 0, UInt64(0))
    for c in children
        c.parent = node
    end
    _compute_metrics!(node)
    return node
end

function expr_to_tree(val::LineNumberNode)
    # Should not be reached due to filtering, but handle gracefully
    return ASTNode("line", nothing, ASTNode[], nothing, _next_node_id(), 1, 1, hash("line"))
end

function expr_to_tree(val)
    # Leaf node: literal value (Int, Float, Symbol, String, etc.)
    label = val isa Symbol ? "Symbol" : string(typeof(val))
    h = hash((label, val))
    return ASTNode(label, val, ASTNode[], nothing, _next_node_id(), 1, 1, h)
end

"""
    tree_to_expr(node::ASTNode) -> Any

Convert an ASTNode tree back to a Julia Expr.
"""
function tree_to_expr(node::ASTNode)
    if isempty(node.children)
        return node.value
    else
        head = Symbol(node.label)
        args = [tree_to_expr(c) for c in node.children]
        return Expr(head, args...)
    end
end

function _compute_metrics!(node::ASTNode)
    if isempty(node.children)
        node.height = 1
        node.size = 1
        node.hash = hash((node.label, node.value))
    else
        node.height = 1 + maximum(c.height for c in node.children)
        node.size = 1 + sum(c.size for c in node.children)
        # Structural hash: label + ordered children hashes
        node.hash = hash((node.label, Tuple(c.hash for c in node.children)))
    end
end

is_leaf(node::ASTNode) = isempty(node.children)

function node_label(node::ASTNode)
    if is_leaf(node)
        return "$(node.label):$(node.value)"
    else
        return node.label
    end
end

# ─── Tree traversal helpers ────────────────────────────────────────────

"""
    descendants(node) -> Vector{ASTNode}

Return all descendants of node (not including node itself), in pre-order.
"""
function descendants(node::ASTNode)
    result = ASTNode[]
    for child in node.children
        push!(result, child)
        append!(result, descendants(child))
    end
    return result
end

"""
    postorder(node) -> Vector{ASTNode}

Return all nodes in the subtree rooted at node, in post-order.
"""
function postorder(node::ASTNode)
    result = ASTNode[]
    for child in node.children
        append!(result, postorder(child))
    end
    push!(result, node)
    return result
end

"""
    subtree_nodes(node) -> Vector{ASTNode}

Return node and all its descendants (pre-order).
"""
function subtree_nodes(node::ASTNode)
    result = ASTNode[node]
    append!(result, descendants(node))
    return result
end

# ─── Isomorphism check ─────────────────────────────────────────────────

"""
    isomorphic(t1, t2) -> Bool

Two trees are isomorphic if they have identical structure and leaf values.
Uses precomputed hashes for O(1) comparison.
"""
isomorphic(t1::ASTNode, t2::ASTNode) = t1.hash == t2.hash

# ─── Matching data structure ───────────────────────────────────────────

"""
    TreeMapping

Stores the bidirectional mapping between nodes of two trees.
"""
mutable struct TreeMapping
    # old node id → new node id
    old_to_new::Dict{Int, Int}
    # new node id → old node id
    new_to_old::Dict{Int, Int}
    # id → node lookup
    old_nodes::Dict{Int, ASTNode}
    new_nodes::Dict{Int, ASTNode}
end

TreeMapping() = TreeMapping(Dict{Int,Int}(), Dict{Int,Int}(), Dict{Int,ASTNode}(), Dict{Int,ASTNode}())

function add_match!(m::TreeMapping, old_node::ASTNode, new_node::ASTNode)
    m.old_to_new[old_node.id] = new_node.id
    m.new_to_old[new_node.id] = old_node.id
    m.old_nodes[old_node.id] = old_node
    m.new_nodes[new_node.id] = new_node
end

is_matched_old(m::TreeMapping, node::ASTNode) = haskey(m.old_to_new, node.id)
is_matched_new(m::TreeMapping, node::ASTNode) = haskey(m.new_to_old, node.id)

function match_count(m::TreeMapping)
    return length(m.old_to_new)
end

# ─── Dice coefficient ──────────────────────────────────────────────────

"""
    dice(t1, t2, mapping) -> Float64

Dice coefficient: 2 * |common matched descendants| / (|desc(t1)| + |desc(t2)|).
Measures how similar two subtrees are based on how many of their descendants
are already matched to each other.
"""
function dice(t1::ASTNode, t2::ASTNode, m::TreeMapping)
    desc1 = subtree_nodes(t1)
    desc2_ids = Set(n.id for n in subtree_nodes(t2))

    common = 0
    for n in desc1
        if haskey(m.old_to_new, n.id) && m.old_to_new[n.id] in desc2_ids
            common += 1
        end
    end

    total = length(desc1) + length(desc2_ids)
    return total > 0 ? (2.0 * common) / total : 0.0
end

# ─── GumTree Phase 1: Top-Down ─────────────────────────────────────────

"""
    top_down!(T1, T2, mapping; min_height=2)

GumTree top-down phase. Greedily matches isomorphic subtrees from
largest (tallest) to smallest using height-indexed priority lists.
"""
function top_down!(T1::ASTNode, T2::ASTNode, mapping::TreeMapping; min_height::Int=2)
    # Height-indexed priority lists
    L1 = Dict{Int, Vector{ASTNode}}()
    L2 = Dict{Int, Vector{ASTNode}}()

    _hpush!(L1, T1.height, T1)
    _hpush!(L2, T2.height, T2)

    candidates = Tuple{ASTNode, ASTNode}[]  # Ambiguous matches

    while true
        p1 = _hpeek(L1)
        p2 = _hpeek(L2)
        (p1 < min_height || p2 < min_height) && break

        if p1 != p2
            # Heights differ: open the taller side
            if p1 > p2
                for t in _hpop!(L1)
                    _open_node!(t, L1)
                end
            else
                for t in _hpop!(L2)
                    _open_node!(t, L2)
                end
            end
        else
            H1 = _hpop!(L1)
            H2 = _hpop!(L2)

            # Try to match nodes at the same height
            for t1 in H1, t2 in H2
                if isomorphic(t1, t2)
                    # Check if this is an unambiguous match
                    # (t1 is the only node in H1 isomorphic to something in H2, and vice versa)
                    t1_matches_in_H2 = count(x -> isomorphic(t1, x), H2)
                    t2_matches_in_H1 = count(x -> isomorphic(x, t2), H1)

                    if t1_matches_in_H2 == 1 && t2_matches_in_H1 == 1
                        # Unambiguous: match all descendant pairs
                        _match_subtrees!(t1, t2, mapping)
                    else
                        # Ambiguous: add to candidates for later resolution
                        push!(candidates, (t1, t2))
                    end
                end
            end

            # Open unmatched nodes
            for t1 in H1
                if !is_matched_old(mapping, t1) && !any(p -> p[1] === t1, candidates)
                    _open_node!(t1, L1)
                end
            end
            for t2 in H2
                if !is_matched_new(mapping, t2) && !any(p -> p[2] === t2, candidates)
                    _open_node!(t2, L2)
                end
            end
        end
    end

    # Resolve ambiguous candidates by dice coefficient (best first)
    sort!(candidates, by=((t1, t2),) -> -dice(t1, t2, mapping))
    for (t1, t2) in candidates
        if !is_matched_old(mapping, t1) && !is_matched_new(mapping, t2)
            _match_subtrees!(t1, t2, mapping)
        end
    end
end

function _match_subtrees!(t1::ASTNode, t2::ASTNode, mapping::TreeMapping)
    add_match!(mapping, t1, t2)
    # Match children recursively by position (they're isomorphic, so same structure)
    for (c1, c2) in zip(t1.children, t2.children)
        _match_subtrees!(c1, c2, mapping)
    end
end

function _hpush!(L::Dict{Int, Vector{ASTNode}}, h::Int, node::ASTNode)
    if haskey(L, h)
        push!(L[h], node)
    else
        L[h] = ASTNode[node]
    end
end

function _hpeek(L::Dict{Int, Vector{ASTNode}})
    isempty(L) ? -1 : maximum(keys(L))
end

function _hpop!(L::Dict{Int, Vector{ASTNode}})
    h = _hpeek(L)
    return pop!(L, h, ASTNode[])
end

function _open_node!(node::ASTNode, L::Dict{Int, Vector{ASTNode}})
    for child in node.children
        if !is_leaf(child)
            _hpush!(L, child.height, child)
        end
    end
end

# ─── GumTree Phase 2: Bottom-Up ───────────────────────────────────────

"""
    bottom_up!(T1, T2, mapping; min_dice=0.5, max_size=100)

GumTree bottom-up phase. For each unmatched node in T1 (post-order),
find a candidate in T2 with the same label and high dice similarity.
For small subtrees, recover additional matches via greedy child matching.
"""
function bottom_up!(T1::ASTNode, T2::ASTNode, mapping::TreeMapping;
                    min_dice::Float64=0.5, max_size::Int=100)
    for t1 in postorder(T1)
        is_matched_old(mapping, t1) && continue
        is_leaf(t1) && continue

        # Find best candidate in T2
        best_t2 = nothing
        best_dice = min_dice

        for t2 in postorder(T2)
            is_matched_new(mapping, t2) && continue
            is_leaf(t2) && continue
            t1.label != t2.label && continue

            # t2 must have at least one matched descendant (anchor)
            has_anchor = any(is_matched_new(mapping, d) for d in descendants(t2))
            !has_anchor && continue

            d = dice(t1, t2, mapping)
            if d > best_dice
                best_dice = d
                best_t2 = t2
            end
        end

        if best_t2 !== nothing
            add_match!(mapping, t1, best_t2)

            # For small subtrees, recover additional leaf matches
            if max(t1.size, best_t2.size) < max_size
                _recover_matches!(t1, best_t2, mapping)
            end
        end
    end
end

"""
    _recover_matches!(t1, t2, mapping)

Greedy recovery of additional matches between children of two matched inner nodes.
Uses label+value equality for leaves, and label+structure for inner nodes.
This replaces the APTED-based optimal edit mapping with a simpler greedy approach.
"""
function _recover_matches!(t1::ASTNode, t2::ASTNode, mapping::TreeMapping)
    # Try to match unmatched children by label (and value for leaves)
    unmatched1 = [c for c in t1.children if !is_matched_old(mapping, c)]
    unmatched2 = [c for c in t2.children if !is_matched_new(mapping, c)]

    # First pass: match by exact isomorphism (hash equality)
    remaining2 = Set(1:length(unmatched2))
    for (i, c1) in enumerate(unmatched1)
        for j in remaining2
            c2 = unmatched2[j]
            if isomorphic(c1, c2)
                _match_subtrees!(c1, c2, mapping)
                delete!(remaining2, j)
                break
            end
        end
    end

    # Second pass: match remaining by label equality
    # For leaves: match only if same label (type tag) — value may differ, which is a real change.
    #   We still add the match so the parent structure is linked, but the value difference
    #   will be detected by the change-detection layer.
    # For inner nodes: match by label and recurse.
    unmatched1 = [c for c in t1.children if !is_matched_old(mapping, c)]
    remaining2_nodes = [c for c in t2.children if !is_matched_new(mapping, c)]

    for c1 in unmatched1
        for (j, c2) in enumerate(remaining2_nodes)
            if is_matched_new(mapping, c2)
                continue
            end
            if c1.label == c2.label
                add_match!(mapping, c1, c2)
                # Recurse into inner nodes
                if !is_leaf(c1) && !is_leaf(c2)
                    _recover_matches!(c1, c2, mapping)
                end
                break
            end
        end
    end
end

# ─── Main GumTree entry point ──────────────────────────────────────────

"""
    gumtree_diff(old_expr::Expr, new_expr::Expr) -> TreeMapping

Run the full GumTree algorithm on two Julia expressions.
Returns a TreeMapping containing the matched node pairs.
"""
function gumtree_diff(old_expr::Expr, new_expr::Expr;
                      min_height::Int=2, min_dice::Float64=0.4, max_size::Int=100)
    reset_node_ids!()
    old_tree = expr_to_tree(old_expr)
    new_tree = expr_to_tree(new_expr)

    mapping = TreeMapping()

    # Phase 1: Top-down greedy matching of isomorphic subtrees
    top_down!(old_tree, new_tree, mapping; min_height=min_height)

    # Phase 2: Bottom-up recovery of remaining matches
    bottom_up!(old_tree, new_tree, mapping; min_dice=min_dice, max_size=max_size)

    return mapping, old_tree, new_tree
end

# ─── Statement-level change detection ──────────────────────────────────

"""
    changed_statement_indices(old_code::Expr, new_code::Expr) -> Set{Int}

Run GumTree diff on old and new code, then determine which top-level
statements in new_code contain unmatched (changed) nodes.

Returns the set of 1-based indices into the new code's statement list
that have at least one unmatched node.
"""
function changed_statement_indices(old_code::Expr, new_code::Expr)
    mapping, old_tree, new_tree = gumtree_diff(old_code, new_code)

    # Get top-level statement nodes in the new tree
    stmt_nodes = new_tree.children
    changed = Set{Int}()

    for (i, stmt_node) in enumerate(stmt_nodes)
        all_nodes = subtree_nodes(stmt_node)
        is_changed = false

        for n in all_nodes
            if !is_matched_new(mapping, n)
                # Node has no match at all → changed
                is_changed = true
                break
            end
            # Node is matched — check if it's a value-equivalent match
            if is_leaf(n)
                old_id = mapping.new_to_old[n.id]
                old_node = mapping.old_nodes[old_id]
                if old_node.value != n.value
                    # Matched by label (same type) but different value → changed
                    is_changed = true
                    break
                end
            end
        end

        if is_changed
            push!(changed, i)
        end
    end

    return changed
end

"""
    gumtree_prepare_split(old_code::Union{Nothing, Expr}, new_code::Expr)
        -> (main_ast::Expr, hole_blocks::Vector{Expr}, guard_syms::Vector{Vector{Symbol}})

GumTree-based variant of auto_prepare_split.

Uses tree-level differencing to identify changed statements with higher
precision than statement-level LCS hashing. For example, if a single
constant within a statement changes, GumTree still recognizes the statement
structure as matched — but detects the leaf-level change, correctly
classifying it as a hole.
"""
function gumtree_prepare_split(old_code::Union{Nothing, Expr}, new_code::Expr)
    new_stmts = extract_statements(new_code)

    if isempty(new_stmts)
        return (Expr(:block), Expr[], Vector{Symbol}[])
    end

    # First execution: no previous version
    if old_code === nothing
        main_ast = Expr(:block, [deepcopy(s) for s in new_stmts]...)
        return (main_ast, Expr[], Vector{Symbol}[])
    end

    old_stmts = extract_statements(old_code)

    # Run GumTree diff
    changed = changed_statement_indices(old_code, new_code)

    # Handle edge cases
    if isempty(changed)
        # No changes
        main_ast = Expr(:block, [deepcopy(s) for s in new_stmts]...)
        return (main_ast, Expr[], Vector{Symbol}[])
    end
    if length(changed) == length(new_stmts)
        # Everything changed → full recompile
        main_ast = Expr(:block, [deepcopy(s) for s in new_stmts]...)
        return (main_ast, Expr[], Vector{Symbol}[])
    end

    # Build main_ast with hole placeholders
    main_args = Any[]
    hole_blocks = Expr[]
    guard_syms_list = Vector{Symbol}[]
    defined_so_far = Set{Symbol}()
    hole_count = 0

    for (i, stmt) in enumerate(new_stmts)
        if i ∉ changed
            # Unchanged statement → main block
            push!(main_args, deepcopy(stmt))
            union!(defined_so_far, collect_defined_symbols(stmt))
        else
            # Changed statement → hole
            hole_count += 1
            push!(main_args, Expr(:hole, hole_count))

            hole_block = Expr(:block, deepcopy(stmt))
            push!(hole_blocks, hole_block)

            syms_before = collect(defined_so_far)
            syms_in_hole = collect(SplitAst.collect_symbols(stmt))
            guards = unique(vcat(syms_before, syms_in_hole))
            push!(guard_syms_list, guards)

            union!(defined_so_far, collect_defined_symbols(stmt))
        end
    end

    main_ast = Expr(:block, main_args...)
    return (main_ast, hole_blocks, guard_syms_list)
end
