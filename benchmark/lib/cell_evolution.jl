"""
Cell Evolution Module

Core data structures for modeling realistic notebook cell development patterns.
"""
module CellEvolutionLib

export CellEvolution, CellExecution, NotebookScenario, ChangeType
export INITIAL, PARAMETER, STRUCTURE, BUGFIX, REFACTOR, DEPENDENCY
export create_execution_trace, get_cell_code

"""
Types of changes that can occur in a cell.
"""
@enum ChangeType begin
    INITIAL         # First version of the cell
    PARAMETER       # Only @hole values changed (fast path for nbjit)
    STRUCTURE       # Code structure changed (requires recompilation)
    BUGFIX          # Fix a bug (usually structure change)
    REFACTOR        # Refactoring (structure change)
    DEPENDENCY      # Re-run due to upstream cell change
end

"""
Represents a single cell's evolution through development.

# Fields
- `cell_id`: Unique identifier for the cell
- `versions`: Vector of code strings, one per iteration
- `change_types`: Type of change for each version transition
- `description`: Human-readable description of the cell's purpose
- `depends_on`: List of cell_ids this cell depends on
"""
struct CellEvolution
    cell_id::String
    versions::Vector{String}
    change_types::Vector{ChangeType}
    description::String
    depends_on::Vector{String}

    function CellEvolution(
        cell_id::String,
        versions::Vector{String},
        change_types::Vector{ChangeType},
        description::String = "";
        depends_on::Vector{String} = String[]
    )
        if length(change_types) != length(versions)
            error("change_types must have same length as versions")
        end
        if !isempty(change_types) && change_types[1] != INITIAL
            error("First change_type must be INITIAL")
        end
        new(cell_id, versions, change_types, description, depends_on)
    end
end

"""
Represents execution of a cell at a specific version.

# Fields
- `cell_id`: Which cell is being executed
- `version`: Which version of the cell (1-indexed)
- `change_type`: Type of change that triggered this execution
- `triggered_by`: Cell that caused this re-execution (for dependency cascades)
"""
struct CellExecution
    cell_id::String
    version::Int
    change_type::ChangeType
    triggered_by::Union{Nothing, String}

    function CellExecution(
        cell_id::String,
        version::Int,
        change_type::ChangeType;
        triggered_by::Union{Nothing, String} = nothing
    )
        new(cell_id, version, change_type, triggered_by)
    end
end

"""
Full notebook simulation scenario.

# Fields
- `name`: Scenario name for reporting
- `description`: What this scenario simulates
- `cells`: All cells in the notebook
- `execution_trace`: Ordered sequence of cell executions
"""
struct NotebookScenario
    name::String
    description::String
    cells::Dict{String, CellEvolution}
    execution_trace::Vector{CellExecution}

    function NotebookScenario(
        name::String,
        description::String,
        cells::Vector{CellEvolution},
        execution_trace::Vector{CellExecution}
    )
        cells_dict = Dict(c.cell_id => c for c in cells)
        # Validate execution trace references valid cells and versions
        for exec in execution_trace
            if !haskey(cells_dict, exec.cell_id)
                error("Execution references unknown cell: $(exec.cell_id)")
            end
            cell = cells_dict[exec.cell_id]
            if exec.version < 1 || exec.version > length(cell.versions)
                error("Invalid version $(exec.version) for cell $(exec.cell_id)")
            end
        end
        new(name, description, cells_dict, execution_trace)
    end
end

"""
Get the code for a specific cell execution.
"""
function get_cell_code(scenario::NotebookScenario, exec::CellExecution)::String
    cell = scenario.cells[exec.cell_id]
    return cell.versions[exec.version]
end

"""
Create a simple linear execution trace from cells.

Executes each cell version in order, respecting dependencies.
"""
function create_execution_trace(cells::Vector{CellEvolution})::Vector{CellExecution}
    trace = CellExecution[]

    # Track current version of each cell
    current_versions = Dict{String, Int}()

    # Build dependency graph
    dependents = Dict{String, Vector{String}}()
    for cell in cells
        for dep in cell.depends_on
            if !haskey(dependents, dep)
                dependents[dep] = String[]
            end
            push!(dependents[dep], cell.cell_id)
        end
        current_versions[cell.cell_id] = 0
    end

    # Execute cells in order, running all versions
    for cell in cells
        for (version, change_type) in enumerate(cell.change_types)
            # Execute this version
            push!(trace, CellExecution(cell.cell_id, version, change_type))
            current_versions[cell.cell_id] = version

            # Cascade to dependents if this cell changed
            if haskey(dependents, cell.cell_id)
                for dep_id in dependents[cell.cell_id]
                    dep_version = current_versions[dep_id]
                    if dep_version > 0
                        push!(trace, CellExecution(
                            dep_id, dep_version, DEPENDENCY;
                            triggered_by=cell.cell_id
                        ))
                    end
                end
            end
        end
    end

    return trace
end

"""
Create an interleaved execution trace simulating back-and-forth development.

This models a more realistic pattern where users jump between cells.
"""
function create_interleaved_trace(
    cells::Vector{CellEvolution},
    pattern::Vector{Tuple{String, Int}}  # (cell_id, version) pairs
)::Vector{CellExecution}
    trace = CellExecution[]
    cells_dict = Dict(c.cell_id => c for c in cells)

    for (cell_id, version) in pattern
        cell = cells_dict[cell_id]
        change_type = cell.change_types[version]
        push!(trace, CellExecution(cell_id, version, change_type))
    end

    return trace
end

end # module
