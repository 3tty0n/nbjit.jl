"""
Dependency Graph Module

Track dependencies between notebook cells for realistic cascade simulation.
"""
module DependencyGraphLib

export DependencyGraph, add_dependency!, get_dependents, get_dependencies
export get_affected_cells, topological_sort, build_from_cells

using ..CellEvolutionLib: CellEvolution

"""
Directed graph tracking cell dependencies.

If cell B depends on cell A, then when A changes, B needs to be re-executed.
"""
mutable struct DependencyGraph
    # cell_id → cells it depends on (upstream)
    dependencies::Dict{String, Set{String}}
    # cell_id → cells that depend on it (downstream)
    dependents::Dict{String, Set{String}}

    function DependencyGraph()
        new(Dict{String, Set{String}}(), Dict{String, Set{String}}())
    end
end

"""
Add a dependency: `dependent` depends on `dependency`.
"""
function add_dependency!(graph::DependencyGraph, dependent::String, dependency::String)
    # Add to dependencies (what does `dependent` need?)
    if !haskey(graph.dependencies, dependent)
        graph.dependencies[dependent] = Set{String}()
    end
    push!(graph.dependencies[dependent], dependency)

    # Add to dependents (what needs `dependency`?)
    if !haskey(graph.dependents, dependency)
        graph.dependents[dependency] = Set{String}()
    end
    push!(graph.dependents[dependency], dependent)
end

"""
Get all cells that `cell_id` depends on (upstream).
"""
function get_dependencies(graph::DependencyGraph, cell_id::String)::Set{String}
    return get(graph.dependencies, cell_id, Set{String}())
end

"""
Get all cells that depend on `cell_id` (downstream).
"""
function get_dependents(graph::DependencyGraph, cell_id::String)::Set{String}
    return get(graph.dependents, cell_id, Set{String}())
end

"""
Get all cells affected when `changed_cell` is modified.

Returns cells in execution order (topologically sorted).
"""
function get_affected_cells(graph::DependencyGraph, changed_cell::String)::Vector{String}
    affected = Set{String}()
    queue = [changed_cell]

    while !isempty(queue)
        current = popfirst!(queue)
        for dep in get_dependents(graph, current)
            if dep ∉ affected
                push!(affected, dep)
                push!(queue, dep)
            end
        end
    end

    # Sort topologically to get execution order
    return topological_sort(graph, collect(affected))
end

"""
Topologically sort cells based on dependency graph.
"""
function topological_sort(graph::DependencyGraph, cells::Vector{String})::Vector{String}
    if isempty(cells)
        return String[]
    end

    # Compute in-degree for each cell (only considering cells in the input)
    cells_set = Set(cells)
    in_degree = Dict{String, Int}()
    for cell in cells
        in_degree[cell] = 0
    end
    for cell in cells
        for dep in get_dependencies(graph, cell)
            if dep in cells_set
                in_degree[cell] += 1
            end
        end
    end

    # Start with cells that have no dependencies in the set
    queue = [cell for cell in cells if in_degree[cell] == 0]
    result = String[]

    while !isempty(queue)
        current = popfirst!(queue)
        push!(result, current)

        for dep in get_dependents(graph, current)
            if dep in cells_set
                in_degree[dep] -= 1
                if in_degree[dep] == 0
                    push!(queue, dep)
                end
            end
        end
    end

    # If we didn't process all cells, there's a cycle
    if length(result) != length(cells)
        @warn "Cycle detected in dependency graph, returning partial order"
        # Add remaining cells in arbitrary order
        for cell in cells
            if cell ∉ result
                push!(result, cell)
            end
        end
    end

    return result
end

"""
Build a dependency graph from a vector of CellEvolution objects.
"""
function build_from_cells(cells::Vector{CellEvolution})::DependencyGraph
    graph = DependencyGraph()
    for cell in cells
        for dep in cell.depends_on
            add_dependency!(graph, cell.cell_id, dep)
        end
    end
    return graph
end

end # module
