module nbjit

include("ijulia_integration.jl")

using .IJuliaIntegration

export IJuliaIntegration
export NotebookSession, current_session, set_default_session!, run_cell!
export @jit, @cache, get_cell_id
export enable_dylib_mode!, disable_dylib_mode!
export clear_cache!
export CellDependencyGraph, get_stale_cells, get_upstream, get_downstream
export get_cell_definitions, get_cell_references
export has_hole_markers, auto_prepare_split, gumtree_prepare_split
export gumtree_diff, changed_statement_indices

end # module
