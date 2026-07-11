"""
Inter-cell dependency tracking for notebook sessions.

Analyzes cell ASTs to extract symbol definitions (writes) and references (reads),
builds a dependency DAG between cells, and computes which downstream cells become
stale when a cell is re-executed with changed definitions.
"""

"""
    extract_definitions(code::Expr) -> Set{Symbol}

Extract all symbols that are assigned (defined) in the given expression.
Handles: plain assignment, compound assignment (+=, etc.), for-loop iteration variables,
and function definitions.
"""
function extract_definitions(code)
    defs = Set{Symbol}()
    _extract_defs!(code, defs)
    return defs
end

function _extract_defs!(expr::Expr, defs::Set{Symbol})
    head = expr.head

    if head == :(=) || head in (:+=, :-=, :*=, :/=, :^=, :%=)
        lhs = expr.args[1]
        if lhs isa Symbol
            push!(defs, lhs)
        elseif lhs isa Expr && lhs.head == :call
            # Function definition: f(x) = ...
            push!(defs, lhs.args[1])
        elseif lhs isa Expr && lhs.head == :ref
            # Array/dict indexing assignment: a[i] = v — the container is not a new def
        elseif lhs isa Expr && lhs.head == :tuple
            # Destructuring: (a, b) = ...
            for arg in lhs.args
                if arg isa Symbol
                    push!(defs, arg)
                end
            end
        end
        # Also recurse into the RHS
        for arg in expr.args[2:end]
            _extract_defs!(arg, defs)
        end
    elseif head == :function
        # function f(x) ... end
        call_expr = expr.args[1]
        if call_expr isa Expr && call_expr.head == :call
            push!(defs, call_expr.args[1])
        elseif call_expr isa Symbol
            push!(defs, call_expr)
        end
        # Recurse into body
        for arg in expr.args[2:end]
            _extract_defs!(arg, defs)
        end
    elseif head == :for
        # for i = range ... end — i is defined in the loop scope
        iter_spec = expr.args[1]
        if iter_spec isa Expr && iter_spec.head == :(=)
            iter_var = iter_spec.args[1]
            if iter_var isa Symbol
                push!(defs, iter_var)
            end
        end
        for arg in expr.args
            _extract_defs!(arg, defs)
        end
    elseif head == :macrocall
        # Handle @hole, @preserve, @persistent — extract definitions from the inner assignment
        annot = expr.args[1]
        annot_str = annot isa Symbol ? string(annot) : ""
        if annot_str in ("@hole", "@preserve", "@persistent")
            for arg in expr.args[2:end]
                if arg isa Expr && arg.head == :(=)
                    lhs = arg.args[1]
                    if lhs isa Symbol
                        push!(defs, lhs)
                    end
                end
                _extract_defs!(arg, defs)
            end
        else
            for arg in expr.args
                _extract_defs!(arg, defs)
            end
        end
    else
        for arg in expr.args
            _extract_defs!(arg, defs)
        end
    end
end

_extract_defs!(::Any, ::Set{Symbol}) = nothing

"""
    extract_references(code::Expr) -> Set{Symbol}

Extract all symbols that are referenced (read) in the given expression.
Returns only "free" references: symbols that are used but not defined within
the same expression. Built-in operators and keywords are excluded.
"""
function extract_references(code)
    refs = Set{Symbol}()
    _extract_refs!(code, refs)
    # Remove symbols that are defined within this same expression
    defs = extract_definitions(code)
    # Keep references to symbols that are also defined (they may reference
    # a prior cell's definition before reassigning), but exclude pure
    # self-contained locals.
    # For inter-cell tracking, we want all symbols that appear in read position,
    # even if the cell also writes to them. The dependency graph uses this to
    # detect "cell B reads X which cell A defines".
    return setdiff(refs, _BUILTIN_SYMBOLS)
end

const _BUILTIN_SYMBOLS = Set{Symbol}([
    # Operators
    :+, :-, :*, :/, :%, :^, :(==), :(!=), :<, :>, :<=, :>=,
    :&&, :||, :!, :&, :|,
    # Built-in functions commonly used
    :println, :print, :string, :length, :push!, :pop!, :append!,
    :zeros, :ones, :fill, :Vector, :Dict, :Array, :Set,
    :range, :collect, :map, :filter, :reduce, :sum, :maximum, :minimum,
    :abs, :sqrt, :exp, :log, :sin, :cos, :tan,
    :typeof, :isa, :convert, :parse,
    :error, :throw, :try, :catch,
    :nothing, :missing, :Inf, :NaN,
    :Int64, :Float64, :Bool, :String, :Symbol, :Any,
    :Main, :Base, :Core,
    # Range/indexing
    :(:), :end,
    # Macros
    Symbol("@hole"), Symbol("@preserve"), Symbol("@persistent"),
    Symbol("@jit"), Symbol("@cache"),
    # Setindex
    :setindex!, :getindex,
])

function _extract_refs!(expr::Expr, refs::Set{Symbol})
    head = expr.head

    if head == :(=) || head in (:+=, :-=, :*=, :/=, :^=, :%=)
        lhs = expr.args[1]
        # For compound assignment, the LHS is also read
        if head != :(=) && lhs isa Symbol
            push!(refs, lhs)
        end
        # For indexing assignment a[i] = v, both a and i are read
        if lhs isa Expr && lhs.head == :ref
            _extract_refs!(lhs, refs)
        end
        # RHS is always read
        for arg in expr.args[2:end]
            _extract_refs!(arg, refs)
        end
    elseif head == :call
        # First arg is the function name — could be a reference if it's a user-defined function
        fname = expr.args[1]
        if fname isa Symbol
            push!(refs, fname)
        elseif fname isa Expr
            _extract_refs!(fname, refs)
        end
        # Remaining args are references
        for arg in expr.args[2:end]
            _extract_refs!(arg, refs)
        end
    elseif head == :.
        # Module-qualified: Mod.func — treat Mod as a reference
        if expr.args[1] isa Symbol
            push!(refs, expr.args[1])
        end
    elseif head == :macrocall
        annot = expr.args[1]
        annot_str = annot isa Symbol ? string(annot) : ""
        if annot_str in ("@hole", "@preserve", "@persistent")
            for arg in expr.args[2:end]
                if arg isa Expr && arg.head == :(=)
                    # RHS of annotated assignment is a reference
                    _extract_refs!(arg.args[2], refs)
                elseif !(arg isa LineNumberNode)
                    _extract_refs!(arg, refs)
                end
            end
        else
            for arg in expr.args[2:end]
                _extract_refs!(arg, refs)
            end
        end
    elseif head == :for
        # Iteration range is a reference
        iter_spec = expr.args[1]
        if iter_spec isa Expr && iter_spec.head == :(=)
            _extract_refs!(iter_spec.args[2], refs)
        end
        # Body
        for arg in expr.args[2:end]
            _extract_refs!(arg, refs)
        end
    else
        for arg in expr.args
            _extract_refs!(arg, refs)
        end
    end
end

function _extract_refs!(sym::Symbol, refs::Set{Symbol})
    push!(refs, sym)
end

_extract_refs!(::LineNumberNode, ::Set{Symbol}) = nothing
_extract_refs!(::Any, ::Set{Symbol}) = nothing

"""
    CellDependencyGraph

Tracks inter-cell dependencies based on symbol definitions and references.

When cell A defines symbol `x` and cell B references `x`, B depends on A.
When A is re-executed and its definitions change, B is marked stale.
"""
mutable struct CellDependencyGraph
    # cell_id → symbols defined by this cell
    definitions::Dict{String, Set{Symbol}}
    # cell_id → symbols referenced by this cell (free variables from other cells)
    references::Dict{String, Set{Symbol}}
    # cell_id → set of cell_ids this cell depends on (upstream)
    upstream::Dict{String, Set{String}}
    # cell_id → set of cell_ids that depend on this cell (downstream)
    downstream::Dict{String, Set{String}}
    # symbol → cell_id that most recently defined it (last-writer-wins for notebooks)
    symbol_provider::Dict{Symbol, String}
    # cell_ids that are currently marked as stale
    stale_cells::Set{String}
end

CellDependencyGraph() = CellDependencyGraph(
    Dict{String, Set{Symbol}}(),
    Dict{String, Set{Symbol}}(),
    Dict{String, Set{String}}(),
    Dict{String, Set{String}}(),
    Dict{Symbol, String}(),
    Set{String}()
)

"""
    update_cell!(graph::CellDependencyGraph, cell_id::String, code::Expr) -> Vector{String}

Analyze the cell's code, update the dependency graph, and return the list of
downstream cell IDs that have become stale as a result of this cell's
(re-)execution. The returned list is in topological order.
"""
function update_cell!(graph::CellDependencyGraph, cell_id::String, code::Expr)
    new_defs = extract_definitions(code)
    new_refs = extract_references(code)

    old_defs = get(graph.definitions, cell_id, Set{Symbol}())

    # Remove old edges where this cell was upstream
    _remove_edges!(graph, cell_id)

    # Update definitions and references
    graph.definitions[cell_id] = new_defs
    graph.references[cell_id] = new_refs

    # Update symbol_provider: this cell is now the provider for its defined symbols
    for sym in new_defs
        graph.symbol_provider[sym] = cell_id
    end

    # Clean up symbol_provider for symbols this cell no longer defines
    for sym in setdiff(old_defs, new_defs)
        if get(graph.symbol_provider, sym, nothing) == cell_id
            delete!(graph.symbol_provider, sym)
        end
    end

    # Rebuild edges for ALL cells (not just this one), since this cell's
    # new definitions may satisfy references in other cells
    _rebuild_all_edges!(graph)

    # Compute stale cells: downstream cells whose inputs may have changed
    # A cell becomes stale if:
    #   1. It depends on the re-executed cell, AND
    #   2. The re-executed cell's definitions overlap with the dependent cell's references
    # For simplicity and correctness, we mark all transitive downstream cells as stale.
    stale = _compute_stale_cells(graph, cell_id)

    # The re-executed cell itself is no longer stale
    delete!(graph.stale_cells, cell_id)

    # Add newly stale cells
    union!(graph.stale_cells, stale)

    return _topological_sort(graph, collect(stale))
end

"""
    get_stale_cells(graph::CellDependencyGraph) -> Set{String}

Return the set of cell IDs currently marked as stale.
"""
get_stale_cells(graph::CellDependencyGraph) = copy(graph.stale_cells)

"""
    mark_fresh!(graph::CellDependencyGraph, cell_id::String)

Remove a cell from the stale set (e.g., after it has been re-executed).
"""
mark_fresh!(graph::CellDependencyGraph, cell_id::String) = delete!(graph.stale_cells, cell_id)

"""
    get_upstream(graph::CellDependencyGraph, cell_id::String) -> Set{String}

Return the set of cell IDs that this cell depends on.
"""
get_upstream(graph::CellDependencyGraph, cell_id::String) =
    get(graph.upstream, cell_id, Set{String}())

"""
    get_downstream(graph::CellDependencyGraph, cell_id::String) -> Set{String}

Return the set of cell IDs that depend on this cell.
"""
get_downstream(graph::CellDependencyGraph, cell_id::String) =
    get(graph.downstream, cell_id, Set{String}())

"""
    get_cell_definitions(graph::CellDependencyGraph, cell_id::String) -> Set{Symbol}

Return the set of symbols defined by this cell.
"""
get_cell_definitions(graph::CellDependencyGraph, cell_id::String) =
    get(graph.definitions, cell_id, Set{Symbol}())

"""
    get_cell_references(graph::CellDependencyGraph, cell_id::String) -> Set{Symbol}

Return the set of symbols referenced by this cell.
"""
get_cell_references(graph::CellDependencyGraph, cell_id::String) =
    get(graph.references, cell_id, Set{Symbol}())

"""
    remove_cell!(graph::CellDependencyGraph, cell_id::String)

Remove a cell and all its edges from the dependency graph.
"""
function remove_cell!(graph::CellDependencyGraph, cell_id::String)
    # Clean up symbol_provider
    old_defs = get(graph.definitions, cell_id, Set{Symbol}())
    for sym in old_defs
        if get(graph.symbol_provider, sym, nothing) == cell_id
            delete!(graph.symbol_provider, sym)
        end
    end

    _remove_edges!(graph, cell_id)
    delete!(graph.definitions, cell_id)
    delete!(graph.references, cell_id)
    delete!(graph.upstream, cell_id)
    delete!(graph.downstream, cell_id)
    delete!(graph.stale_cells, cell_id)
end

# --- Internal helpers ---

function _remove_edges!(graph::CellDependencyGraph, cell_id::String)
    # Remove this cell from downstream sets of its current upstream cells
    for up_id in get(graph.upstream, cell_id, Set{String}())
        if haskey(graph.downstream, up_id)
            delete!(graph.downstream[up_id], cell_id)
        end
    end
    # Remove this cell from upstream sets of its current downstream cells
    for down_id in get(graph.downstream, cell_id, Set{String}())
        if haskey(graph.upstream, down_id)
            delete!(graph.upstream[down_id], cell_id)
        end
    end
    graph.upstream[cell_id] = Set{String}()
    graph.downstream[cell_id] = Set{String}()
end

function _rebuild_all_edges!(graph::CellDependencyGraph)
    # Clear all edges
    for cell_id in keys(graph.upstream)
        graph.upstream[cell_id] = Set{String}()
    end
    for cell_id in keys(graph.downstream)
        graph.downstream[cell_id] = Set{String}()
    end

    # Rebuild: for each cell, find which other cells provide the symbols it references.
    # Only consider symbols that are NOT also defined in the same cell (truly free variables).
    for (cell_id, refs) in graph.references
        cell_defs = get(graph.definitions, cell_id, Set{Symbol}())
        free_refs = setdiff(refs, cell_defs)
        for sym in free_refs
            provider = get(graph.symbol_provider, sym, nothing)
            if provider !== nothing && provider != cell_id
                # cell_id depends on provider
                if !haskey(graph.upstream, cell_id)
                    graph.upstream[cell_id] = Set{String}()
                end
                push!(graph.upstream[cell_id], provider)

                if !haskey(graph.downstream, provider)
                    graph.downstream[provider] = Set{String}()
                end
                push!(graph.downstream[provider], cell_id)
            end
        end
    end
end

function _compute_stale_cells(graph::CellDependencyGraph, changed_cell::String)
    stale = Set{String}()
    queue = String[changed_cell]

    while !isempty(queue)
        current = popfirst!(queue)
        for dep in get(graph.downstream, current, Set{String}())
            if dep ∉ stale
                push!(stale, dep)
                push!(queue, dep)
            end
        end
    end

    return stale
end

function _topological_sort(graph::CellDependencyGraph, cells::Vector{String})
    isempty(cells) && return String[]

    cells_set = Set(cells)

    # Compute in-degree within the subset
    in_degree = Dict{String, Int}()
    for cell in cells
        in_degree[cell] = 0
    end
    for cell in cells
        for up in get(graph.upstream, cell, Set{String}())
            if up in cells_set
                in_degree[cell] += 1
            end
        end
    end

    queue = [cell for cell in cells if in_degree[cell] == 0]
    result = String[]

    while !isempty(queue)
        current = popfirst!(queue)
        push!(result, current)

        for dep in get(graph.downstream, current, Set{String}())
            if dep in cells_set
                in_degree[dep] -= 1
                if in_degree[dep] == 0
                    push!(queue, dep)
                end
            end
        end
    end

    # Handle cycles: append remaining cells
    if length(result) != length(cells)
        for cell in cells
            if cell ∉ result
                push!(result, cell)
            end
        end
    end

    return result
end
