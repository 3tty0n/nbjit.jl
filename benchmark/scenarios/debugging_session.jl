"""
Debugging Session Scenario

Simulates back-and-forth debugging:
- Cell 1: Function definition (multiple bug fixes)
- Cell 2: Test cell (re-run after each fix)
- Cell 3: Additional tests

This models the iterative nature of debugging where users frequently
switch between editing code and running tests.
"""

using ..CellEvolutionLib
using ..CellEvolutionLib: INITIAL, PARAMETER, STRUCTURE, BUGFIX, DEPENDENCY

function create_debugging_session()::NotebookScenario
    # Cell 1: Function definition with bug fixes
    cell1 = CellEvolution(
        "function_def",
        [
            # v1: Initial buggy implementation
            """
            @hole _v = 1
            function compute_stats(data)
                # Bug: doesn't handle empty input
                mean_val = sum(data) / length(data)
                return mean_val
            end
            """,
            # v2: Fix empty input bug
            """
            @hole _v = 2
            function compute_stats(data)
                if isempty(data)
                    return 0.0
                end
                mean_val = sum(data) / length(data)
                return mean_val
            end
            """,
            # v3: Add variance calculation (feature)
            """
            @hole _v = 3
            function compute_stats(data)
                if isempty(data)
                    return (mean=0.0, var=0.0)
                end
                mean_val = sum(data) / length(data)
                var_val = sum((x - mean_val)^2 for x in data) / length(data)
                return (mean=mean_val, var=var_val)
            end
            """,
            # v4: Fix variance for single element
            """
            @hole _v = 4
            function compute_stats(data)
                if isempty(data)
                    return (mean=0.0, var=0.0)
                end
                mean_val = sum(data) / length(data)
                if length(data) == 1
                    return (mean=mean_val, var=0.0)
                end
                var_val = sum((x - mean_val)^2 for x in data) / length(data)
                return (mean=mean_val, var=var_val)
            end
            """,
            # v5: Add standard deviation
            """
            @hole _v = 5
            function compute_stats(data)
                if isempty(data)
                    return (mean=0.0, var=0.0, std=0.0)
                end
                mean_val = sum(data) / length(data)
                if length(data) == 1
                    return (mean=mean_val, var=0.0, std=0.0)
                end
                var_val = sum((x - mean_val)^2 for x in data) / length(data)
                std_val = sqrt(var_val)
                return (mean=mean_val, var=var_val, std=std_val)
            end
            """,
            # v6: Add median
            """
            @hole _v = 6
            function compute_stats(data)
                if isempty(data)
                    return (mean=0.0, var=0.0, std=0.0, median=0.0)
                end
                sorted = sort(collect(data))
                n = length(sorted)
                mean_val = sum(data) / n
                median_val = n % 2 == 1 ? sorted[div(n+1, 2)] : (sorted[div(n,2)] + sorted[div(n,2)+1]) / 2

                if n == 1
                    return (mean=mean_val, var=0.0, std=0.0, median=median_val)
                end
                var_val = sum((x - mean_val)^2 for x in data) / n
                std_val = sqrt(var_val)
                return (mean=mean_val, var=var_val, std=std_val, median=median_val)
            end
            """,
        ],
        [INITIAL, BUGFIX, STRUCTURE, BUGFIX, STRUCTURE, STRUCTURE],
        "Main function with iterative bug fixes";
        depends_on = String[]
    )

    # Cell 2: Test cell (re-run after each function change)
    cell2 = CellEvolution(
        "test_basic",
        [
            # v1: Basic test
            """
            @hole _v = 1
            test_data = [1.0, 2.0, 3.0, 4.0, 5.0]
            result = compute_stats(test_data)
            println("Test result: \$result")
            result
            """,
            # v2: Add edge case test
            """
            @hole _v = 2
            test_data = [1.0, 2.0, 3.0, 4.0, 5.0]
            result = compute_stats(test_data)
            println("Normal case: \$result")

            empty_result = compute_stats(Float64[])
            println("Empty case: \$empty_result")
            (result, empty_result)
            """,
            # v3: Add more edge cases
            """
            @hole _v = 3
            test_data = [1.0, 2.0, 3.0, 4.0, 5.0]
            result = compute_stats(test_data)
            println("Normal case: \$result")

            empty_result = compute_stats(Float64[])
            println("Empty case: \$empty_result")

            single_result = compute_stats([42.0])
            println("Single element: \$single_result")
            (result, empty_result, single_result)
            """,
        ],
        [INITIAL, STRUCTURE, STRUCTURE],
        "Basic test cases";
        depends_on = ["function_def"]
    )

    # Cell 3: Performance test (added later)
    cell3 = CellEvolution(
        "test_perf",
        [
            # v1: Initial perf test
            """
            @hole _v = 1
            large_data = randn(100000)
            @elapsed compute_stats(large_data)
            """,
            # v2: Multiple runs for timing
            """
            @hole _v = 2
            large_data = randn(100000)
            times = [@elapsed compute_stats(large_data) for _ in 1:5]
            println("Avg time: \$(sum(times)/5) seconds")
            times
            """,
        ],
        [INITIAL, STRUCTURE],
        "Performance testing";
        depends_on = ["function_def"]
    )

    cells = [cell1, cell2, cell3]

    # Create realistic debugging execution trace (back and forth)
    execution_trace = CellExecution[
        # Initial implementation
        CellExecution("function_def", 1, INITIAL),
        CellExecution("test_basic", 1, INITIAL),

        # Fix bug, re-run test
        CellExecution("function_def", 2, BUGFIX),
        CellExecution("test_basic", 1, DEPENDENCY; triggered_by="function_def"),

        # Add variance, update test
        CellExecution("function_def", 3, STRUCTURE),
        CellExecution("test_basic", 2, STRUCTURE),

        # Fix single element bug, re-run test
        CellExecution("function_def", 4, BUGFIX),
        CellExecution("test_basic", 2, DEPENDENCY; triggered_by="function_def"),

        # Add std, add performance test
        CellExecution("function_def", 5, STRUCTURE),
        CellExecution("test_basic", 3, STRUCTURE),
        CellExecution("test_perf", 1, INITIAL),

        # Final version with median
        CellExecution("function_def", 6, STRUCTURE),
        CellExecution("test_basic", 3, DEPENDENCY; triggered_by="function_def"),
        CellExecution("test_perf", 2, STRUCTURE),

        # Re-run all tests one more time
        CellExecution("test_basic", 3, DEPENDENCY; triggered_by="function_def"),
        CellExecution("test_perf", 2, DEPENDENCY; triggered_by="function_def"),
    ]

    return NotebookScenario(
        "Debugging Session",
        "Simulates iterative debugging: define → test → fix → re-test",
        cells,
        execution_trace
    )
end
