"""
Simplified Realistic Scenarios

These scenarios model realistic notebook development patterns but use only
simple integer primitives and loops that nbjit can compile.

NOTE: Each cell is self-contained because nbjit compiles cells independently.
Cross-cell variable references are not supported.

Patterns modeled:
1. Data Science Workflow - Single cell with parameter tuning phases
2. Debugging Session - Single cell with iterative bug fixes
3. Hyperparameter Sweep - Many parameter-only changes (nbjit's best case)
4. Visualization Tweaks - Incremental parameter adjustments
5. Algorithm Refinement - Structure changes followed by parameter tuning
"""

using ..CellEvolutionLib
using ..CellEvolutionLib: INITIAL, PARAMETER, STRUCTURE, BUGFIX, DEPENDENCY

# ============================================================================
# Scenario 1: Simplified Data Science Workflow
# Single cell that evolves through data processing phases
# ============================================================================

function create_simplified_data_workflow()::NotebookScenario
    # Single cell that evolves through different phases of a data workflow
    workflow_versions = String[]
    workflow_types = ChangeType[]

    # Phase 1: Initial data loading and basic computation
    push!(workflow_versions, """
        @persistent n = 5000000
        @hole phase = 1
        @hole scale = 1
        result = 0
        for i in 1:n
            result += i * scale
        end
        result
    """)
    push!(workflow_types, INITIAL)

    # Phase 2-4: Preprocessing with structure changes
    push!(workflow_versions, """
        @persistent n = 5000000
        @hole phase = 2
        @hole scale = 2
        result = 0
        for i in 1:n
            result += (i * scale) % 1000
        end
        result
    """)
    push!(workflow_types, STRUCTURE)

    push!(workflow_versions, """
        @persistent n = 5000000
        @hole phase = 3
        @hole scale = 2
        @hole offset = 100
        result = offset
        for i in 1:n
            result += (i * scale) % 1000
        end
        result
    """)
    push!(workflow_types, STRUCTURE)

    push!(workflow_versions, """
        @persistent n = 5000000
        @hole phase = 4
        @hole scale = 2
        @hole offset = 100
        @hole modval = 10000
        result = offset
        for i in 1:n
            result += ((i * scale) % 1000) % modval
        end
        result
    """)
    push!(workflow_types, STRUCTURE)

    # Phase 5-14: Training with hyperparameter tuning (10 parameter iterations)
    for (idx, (lr, batch)) in enumerate([(10, 100), (5, 100), (5, 200), (2, 200),
                                          (2, 500), (1, 500), (1, 1000), (1, 2000),
                                          (1, 5000), (1, 10000)])
        code = """
        @persistent n = 5000000
        @hole phase = $(4 + idx)
        @hole learning_rate = $lr
        @hole batch_size = $batch
        result = 0
        for i in 1:n
            result += (i * learning_rate + batch_size) % 10000
        end
        result
        """
        push!(workflow_versions, code)
        push!(workflow_types, PARAMETER)
    end

    # Phase 15-19: Report formatting tweaks (5 parameter iterations)
    for (idx, (precision, width)) in enumerate([(10, 20), (100, 20), (100, 50), (1000, 50), (1000, 100)])
        code = """
        @persistent n = 5000000
        @hole phase = $(14 + idx)
        @hole precision = $precision
        @hole format_width = $width
        result = 0
        for i in 1:n
            result += (i % precision) * format_width
        end
        result % (precision * format_width)
        """
        push!(workflow_versions, code)
        push!(workflow_types, PARAMETER)
    end

    cell = CellEvolution(
        "workflow",
        workflow_versions,
        workflow_types,
        "Data workflow: load → preprocess → train → report";
        depends_on = String[]
    )

    cells = [cell]
    execution_trace = create_execution_trace(cells)

    return NotebookScenario(
        "Simplified Data Workflow",
        "Single-cell workflow with 19 iterations (4 structure + 15 parameter)",
        cells,
        execution_trace
    )
end

# ============================================================================
# Scenario 2: Simplified Debugging Session
# Single cell with iterative bug fixes
# ============================================================================

function create_simplified_debugging()::NotebookScenario
    # Single cell that evolves through bug fixes
    cell = CellEvolution(
        "compute",
        [
            # v1: Initial (has "bug" - wrong multiplier)
            """
            @persistent n = 1000000
            @hole version = 1
            result = 0
            for i in 1:n
                result += i * 2
            end
            result
            """,
            # v2: "Fix" - change multiplier
            """
            @persistent n = 1000000
            @hole version = 2
            result = 0
            for i in 1:n
                result += i * 3
            end
            result
            """,
            # v3: Add bounds check
            """
            @persistent n = 1000000
            @hole version = 3
            @hole max_val = 1000000000
            result = 0
            for i in 1:n
                val = i * 3
                result += val < max_val ? val : max_val
            end
            result
            """,
            # v4: Fix edge case
            """
            @persistent n = 1000000
            @hole version = 4
            @hole max_val = 1000000000
            result = 0
            for i in 1:n
                val = i * 3
                result += val < max_val ? val : 0
            end
            result
            """,
            # v5: Optimize
            """
            @persistent n = 1000000
            @hole version = 5
            @hole max_val = 1000000000
            @hole step = 1
            result = 0
            for i in 1:step:n
                val = i * 3
                result += val < max_val ? val : 0
            end
            result
            """,
            # v6-v10: Parameter tuning after fixes
            """
            @persistent n = 1000000
            @hole version = 6
            @hole max_val = 500000000
            @hole step = 1
            result = 0
            for i in 1:step:n
                val = i * 3
                result += val < max_val ? val : 0
            end
            result
            """,
            """
            @persistent n = 1000000
            @hole version = 7
            @hole max_val = 250000000
            @hole step = 1
            result = 0
            for i in 1:step:n
                val = i * 3
                result += val < max_val ? val : 0
            end
            result
            """,
            """
            @persistent n = 1000000
            @hole version = 8
            @hole max_val = 100000000
            @hole step = 1
            result = 0
            for i in 1:step:n
                val = i * 3
                result += val < max_val ? val : 0
            end
            result
            """,
            """
            @persistent n = 1000000
            @hole version = 9
            @hole max_val = 100000000
            @hole step = 2
            result = 0
            for i in 1:step:n
                val = i * 3
                result += val < max_val ? val : 0
            end
            result
            """,
            """
            @persistent n = 1000000
            @hole version = 10
            @hole max_val = 100000000
            @hole step = 5
            result = 0
            for i in 1:step:n
                val = i * 3
                result += val < max_val ? val : 0
            end
            result
            """,
        ],
        [INITIAL, BUGFIX, STRUCTURE, BUGFIX, STRUCTURE, PARAMETER, PARAMETER, PARAMETER, PARAMETER, PARAMETER],
        "Computation with iterative fixes and tuning";
        depends_on = String[]
    )

    cells = [cell]
    execution_trace = create_execution_trace(cells)

    return NotebookScenario(
        "Simplified Debugging",
        "Single-cell debugging: 5 fixes then 5 parameter tuning",
        cells,
        execution_trace
    )
end

# ============================================================================
# Scenario 3: Hyperparameter Sweep (50 iterations)
# Best case for nbjit - parameter-only changes in a single cell
# ============================================================================

function create_simplified_hyperparam_sweep()::NotebookScenario
    # Single cell with 50 parameter variations
    sweep_versions = String[]
    sweep_types = ChangeType[]

    # Generate 50 different parameter combinations
    for idx in 1:50
        lr = (idx % 10) + 1
        batch = ((idx ÷ 10) + 1) * 100
        reg = (idx % 5) * 10

        code = """
        @persistent n = 10000000
        @hole learning_rate = $lr
        @hole batch_size = $batch
        @hole regularization = $reg
        result = 0
        for epoch in 1:50
            for b in 1:100
                update = (epoch * learning_rate + b * batch_size) % 10000
                penalty = regularization * epoch
                result += update - penalty
            end
        end
        result
        """
        push!(sweep_versions, code)
        push!(sweep_types, idx == 1 ? INITIAL : PARAMETER)
    end

    cell = CellEvolution(
        "train",
        sweep_versions,
        sweep_types,
        "Training with 50 hyperparameter combinations";
        depends_on = String[]
    )

    cells = [cell]
    execution_trace = create_execution_trace(cells)

    return NotebookScenario(
        "Hyperparameter Sweep",
        "50 parameter-only iterations (nbjit best case)",
        cells,
        execution_trace
    )
end

# ============================================================================
# Scenario 4: Visualization Tweaks (15 iterations)
# Small parameter adjustments in a single cell
# ============================================================================

function create_simplified_viz_tweaks()::NotebookScenario
    # Single cell with 15 visualization parameter tweaks
    viz_versions = String[]
    viz_types = ChangeType[]

    tweaks = [
        (10, 100, 1),
        (20, 100, 1),
        (20, 200, 1),
        (20, 200, 2),
        (50, 200, 2),
        (50, 500, 2),
        (50, 500, 5),
        (100, 500, 5),
        (100, 1000, 5),
        (100, 1000, 10),
        (200, 1000, 10),
        (200, 2000, 10),
        (200, 2000, 20),
        (500, 2000, 20),
        (500, 5000, 50),
    ]

    for (idx, (width, height, scale)) in enumerate(tweaks)
        code = """
        @persistent base_data = 12345678
        @hole plot_width = $width
        @hole plot_height = $height
        @hole scale_factor = $scale
        output = 0
        for x in 1:plot_width
            for y in 1:plot_height
                pixel = (base_data + x * y * scale_factor) % 256
                output += pixel
            end
        end
        output
        """
        push!(viz_versions, code)
        push!(viz_types, idx == 1 ? INITIAL : PARAMETER)
    end

    cell = CellEvolution(
        "visualize",
        viz_versions,
        viz_types,
        "Visualization with aesthetic tweaks";
        depends_on = String[]
    )

    cells = [cell]
    execution_trace = create_execution_trace(cells)

    return NotebookScenario(
        "Visualization Tweaks",
        "15 parameter adjustments for visualization",
        cells,
        execution_trace
    )
end

# ============================================================================
# Scenario 5: Algorithm Refinement
# Structure changes followed by parameter tuning
# ============================================================================

function create_simplified_algorithm_refinement()::NotebookScenario
    algo_versions = [
        # v1: Naive approach
        """
        @persistent n = 5000000
        @hole version = 1
        result = 0
        for i in 1:n
            result += i
        end
        result
        """,
        # v2: Add multiplier
        """
        @persistent n = 5000000
        @hole version = 2
        result = 0
        for i in 1:n
            result += i * 2
        end
        result
        """,
        # v3: Add modulo
        """
        @persistent n = 5000000
        @hole version = 3
        result = 0
        for i in 1:n
            result += (i * 2) % 1000
        end
        result
        """,
        # v4: Add conditional
        """
        @persistent n = 5000000
        @hole version = 4
        result = 0
        for i in 1:n
            val = (i * 2) % 1000
            result += val < 500 ? val : 0
        end
        result
        """,
        # v5: Parameterize threshold
        """
        @persistent n = 5000000
        @hole version = 5
        @hole threshold = 500
        result = 0
        for i in 1:n
            val = (i * 2) % 1000
            result += val < threshold ? val : 0
        end
        result
        """,
    ]

    algo_types = [INITIAL, STRUCTURE, STRUCTURE, STRUCTURE, STRUCTURE]

    # Add 10 parameter variations
    for (idx, threshold) in enumerate([400, 300, 250, 200, 150, 100, 75, 50, 25, 10])
        code = """
        @persistent n = 5000000
        @hole version = $(5 + idx)
        @hole threshold = $threshold
        result = 0
        for i in 1:n
            val = (i * 2) % 1000
            result += val < threshold ? val : 0
        end
        result
        """
        push!(algo_versions, code)
        push!(algo_types, PARAMETER)
    end

    cell1 = CellEvolution(
        "algorithm",
        algo_versions,
        algo_types,
        "Algorithm: 5 structural + 10 parameter changes";
        depends_on = String[]
    )

    cells = [cell1]
    execution_trace = create_execution_trace(cells)

    return NotebookScenario(
        "Algorithm Refinement",
        "5 structural changes then 10 parameter variations",
        cells,
        execution_trace
    )
end

# ============================================================================
# Export all simplified scenarios
# ============================================================================

function get_all_simplified_scenarios()
    return [
        create_simplified_data_workflow(),
        create_simplified_debugging(),
        create_simplified_hyperparam_sweep(),
        create_simplified_viz_tweaks(),
        create_simplified_algorithm_refinement(),
    ]
end
