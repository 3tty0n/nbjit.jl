"""
Visualization Iteration Scenario

Simulates the common pattern of tweaking plot/output aesthetics.
Users often make many small parameter changes to get the visualization right.

- Cell 1: Data computation (stable)
- Cell 2: Visualization with many aesthetic tweaks (15 iterations)
"""

using ..CellEvolutionLib
using ..CellEvolutionLib: INITIAL, PARAMETER, STRUCTURE

function create_visualization_iteration()::NotebookScenario
    # Cell 1: Data computation (stable)
    cell1 = CellEvolution(
        "compute",
        [
            """
            @hole _v = 1
            # Simulate some analysis results
            @persistent n_points = 1000
            @persistent x_data = range(0, 10, length=n_points)
            @persistent y_data = sin.(x_data) .+ 0.1 .* randn(n_points)

            # Compute statistics
            @persistent mean_y = sum(y_data) / n_points
            @persistent std_y = sqrt(sum((y_data .- mean_y).^2) / n_points)
            @persistent min_y = minimum(y_data)
            @persistent max_y = maximum(y_data)

            println("Data computed: \$n_points points, mean=\$(round(mean_y, digits=3))")
            (x_data, y_data, mean_y, std_y, min_y, max_y)
            """,
        ],
        [INITIAL],
        "Data computation";
        depends_on = String[]
    )

    # Cell 2: Visualization with many parameter tweaks
    viz_versions = [
        # v1: Basic output
        """
        @hole title = "Data"
        println(title)
        println("Points: \$n_points")
        title
        """,
        # v2: Add subtitle
        """
        @hole title = "Analysis Results"
        @hole subtitle = "Time Series"
        println("\$title: \$subtitle")
        println("Points: \$n_points")
        (title, subtitle)
        """,
        # v3: Add range info
        """
        @hole title = "Analysis Results"
        @hole subtitle = "Time Series Data"
        @hole show_range = true
        println("\$title: \$subtitle")
        if show_range
            println("Range: [\$(round(min_y, digits=2)), \$(round(max_y, digits=2))]")
        end
        (title, subtitle, show_range)
        """,
        # v4: Add statistics
        """
        @hole title = "Analysis Results"
        @hole subtitle = "Time Series Data"
        @hole show_range = true
        @hole show_stats = true
        println("\$title: \$subtitle")
        if show_range
            println("Range: [\$(round(min_y, digits=2)), \$(round(max_y, digits=2))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=3)), Std: \$(round(std_y, digits=3))")
        end
        (title, subtitle, show_range, show_stats)
        """,
        # v5: Adjust precision
        """
        @hole title = "Analysis Results"
        @hole subtitle = "Time Series Data"
        @hole show_range = true
        @hole show_stats = true
        @hole precision = 4
        println("\$title: \$subtitle")
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        precision
        """,
        # v6: Change precision
        """
        @hole title = "Analysis Results"
        @hole subtitle = "Time Series Data"
        @hole show_range = true
        @hole show_stats = true
        @hole precision = 6
        println("\$title: \$subtitle")
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        precision
        """,
        # v7: Update title
        """
        @hole title = "Sensor Analysis"
        @hole subtitle = "Temperature Time Series"
        @hole show_range = true
        @hole show_stats = true
        @hole precision = 6
        println("\$title: \$subtitle")
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        title
        """,
        # v8: Add separator
        """
        @hole title = "Sensor Analysis"
        @hole subtitle = "Temperature Time Series"
        @hole show_range = true
        @hole show_stats = true
        @hole precision = 6
        @hole separator = "="
        println(separator^40)
        println("\$title: \$subtitle")
        println(separator^40)
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        separator
        """,
        # v9: Change separator
        """
        @hole title = "Sensor Analysis"
        @hole subtitle = "Temperature Time Series"
        @hole show_range = true
        @hole show_stats = true
        @hole precision = 6
        @hole separator = "-"
        println(separator^40)
        println("\$title: \$subtitle")
        println(separator^40)
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        separator
        """,
        # v10: Add count
        """
        @hole title = "Sensor Analysis"
        @hole subtitle = "Temperature Time Series"
        @hole show_range = true
        @hole show_stats = true
        @hole show_count = true
        @hole precision = 6
        @hole separator = "-"
        println(separator^40)
        println("\$title: \$subtitle")
        println(separator^40)
        if show_count
            println("Data points: \$n_points")
        end
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        show_count
        """,
        # v11: Adjust width
        """
        @hole title = "Sensor Analysis"
        @hole subtitle = "Temperature Time Series"
        @hole show_range = true
        @hole show_stats = true
        @hole show_count = true
        @hole precision = 6
        @hole separator = "-"
        @hole width = 50
        println(separator^width)
        println("\$title: \$subtitle")
        println(separator^width)
        if show_count
            println("Data points: \$n_points")
        end
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        width
        """,
        # v12: Change width again
        """
        @hole title = "Sensor Analysis"
        @hole subtitle = "Temperature Time Series"
        @hole show_range = true
        @hole show_stats = true
        @hole show_count = true
        @hole precision = 6
        @hole separator = "-"
        @hole width = 60
        println(separator^width)
        println("\$title: \$subtitle")
        println(separator^width)
        if show_count
            println("Data points: \$n_points")
        end
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        width
        """,
        # v13: Final title adjustment
        """
        @hole title = "IoT Sensor Analysis Report"
        @hole subtitle = "Temperature Readings"
        @hole show_range = true
        @hole show_stats = true
        @hole show_count = true
        @hole precision = 4
        @hole separator = "="
        @hole width = 60
        println(separator^width)
        println("\$title")
        println("\$subtitle")
        println(separator^width)
        if show_count
            println("Data points: \$n_points")
        end
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        println(separator^width)
        title
        """,
        # v14: One more precision tweak
        """
        @hole title = "IoT Sensor Analysis Report"
        @hole subtitle = "Temperature Readings"
        @hole show_range = true
        @hole show_stats = true
        @hole show_count = true
        @hole precision = 3
        @hole separator = "="
        @hole width = 60
        println(separator^width)
        println("\$title")
        println("\$subtitle")
        println(separator^width)
        if show_count
            println("Data points: \$n_points")
        end
        if show_range
            println("Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("Mean: \$(round(mean_y, digits=precision)), Std: \$(round(std_y, digits=precision))")
        end
        println(separator^width)
        precision
        """,
        # v15: Final version
        """
        @hole title = "IoT Sensor Analysis Report"
        @hole subtitle = "Temperature Readings (Celsius)"
        @hole show_range = true
        @hole show_stats = true
        @hole show_count = true
        @hole precision = 2
        @hole separator = "="
        @hole width = 60
        println(separator^width)
        println("\$title")
        println("\$subtitle")
        println(separator^width)
        if show_count
            println("  Data points: \$n_points")
        end
        if show_range
            println("  Range: [\$(round(min_y, digits=precision)), \$(round(max_y, digits=precision))]")
        end
        if show_stats
            println("  Mean: \$(round(mean_y, digits=precision))")
            println("  Std:  \$(round(std_y, digits=precision))")
        end
        println(separator^width)
        "Complete"
        """,
    ]

    viz_types = [INITIAL]
    append!(viz_types, fill(PARAMETER, length(viz_versions) - 1))

    cell2 = CellEvolution(
        "visualize",
        viz_versions,
        viz_types,
        "Visualization with aesthetic iterations";
        depends_on = ["compute"]
    )

    cells = [cell1, cell2]
    execution_trace = create_execution_trace(cells)

    return NotebookScenario(
        "Visualization Iteration",
        "15 aesthetic parameter tweaks - common in report generation",
        cells,
        execution_trace
    )
end
