"""
Data Science Workflow Scenario

Simulates a typical EDA (Exploratory Data Analysis) session:
- Cell 1: Data loading (stable)
- Cell 2: Preprocessing (structure changes)
- Cell 3: Feature engineering (mixed changes)
- Cell 4: Model training (parameter tuning - many iterations)
- Cell 5: Visualization (parameter tweaks)
"""

using ..CellEvolutionLib
using ..CellEvolutionLib: INITIAL, PARAMETER, STRUCTURE, DEPENDENCY

function create_data_science_workflow()::NotebookScenario
    # Cell 1: Data Loading (executed once, stable)
    cell1 = CellEvolution(
        "data_load",
        [
            """
            @hole _v = 1
            @persistent n_samples = 10000
            @persistent n_features = 20
            @persistent raw_data = [randn(n_samples) for _ in 1:n_features]
            @persistent labels = rand(0:1, n_samples)
            println("Data loaded: \$n_samples samples, \$n_features features")
            (raw_data, labels)
            """,
        ],
        [INITIAL],
        "Load dataset";
        depends_on = String[]
    )

    # Cell 2: Preprocessing (3 structural iterations)
    cell2 = CellEvolution(
        "preprocess",
        [
            # v1: Simple scaling
            """
            @hole _v = 1
            processed = [x .* 2 for x in raw_data]
            println("Preprocessed with scaling")
            processed
            """,
            # v2: Add normalization
            """
            @hole _v = 2
            processed = [(x .- mean(x)) ./ std(x) for x in raw_data]
            println("Preprocessed with normalization")
            processed
            """,
            # v3: Add clipping
            """
            @hole _v = 3
            processed = [clamp.((x .- mean(x)) ./ std(x), -3, 3) for x in raw_data]
            println("Preprocessed with normalization + clipping")
            processed
            """,
        ],
        [INITIAL, STRUCTURE, STRUCTURE],
        "Data preprocessing";
        depends_on = ["data_load"]
    )

    # Cell 3: Feature Engineering (5 iterations mixing structure and parameters)
    cell3 = CellEvolution(
        "features",
        [
            # v1: Simple sum features
            """
            @hole _v = 1
            n_features = length(processed)
            features = zeros(length(processed[1]))
            for i in 1:n_features
                features .+= processed[i]
            end
            features
            """,
            # v2: Add polynomial features
            """
            @hole _v = 2
            n_features = length(processed)
            features = zeros(length(processed[1]))
            for i in 1:n_features
                features .+= processed[i] .+ processed[i].^2
            end
            features
            """,
            # v3: Add interactions
            """
            @hole _v = 3
            n_features = length(processed)
            features = zeros(length(processed[1]))
            for i in 1:n_features
                features .+= processed[i] .+ processed[i].^2
            end
            # Add first interaction term
            features .+= processed[1] .* processed[2]
            features
            """,
            # v4: More interactions
            """
            @hole _v = 4
            n_features = length(processed)
            features = zeros(length(processed[1]))
            for i in 1:n_features
                features .+= processed[i] .+ processed[i].^2
            end
            # Add multiple interaction terms
            for i in 1:min(5, n_features-1)
                features .+= processed[i] .* processed[i+1]
            end
            features
            """,
            # v5: Final version with threshold
            """
            @hole _v = 5
            n_features = length(processed)
            threshold = 0.5
            features = zeros(length(processed[1]))
            for i in 1:n_features
                features .+= processed[i] .+ processed[i].^2
            end
            for i in 1:min(5, n_features-1)
                features .+= processed[i] .* processed[i+1]
            end
            features = clamp.(features, -threshold * n_features, threshold * n_features)
            features
            """,
        ],
        [INITIAL, STRUCTURE, STRUCTURE, STRUCTURE, STRUCTURE],
        "Feature engineering";
        depends_on = ["preprocess"]
    )

    # Cell 4: Model Training (15 parameter iterations - nbjit's sweet spot)
    # Using @hole for parameters that change frequently
    training_params = [
        (0.1, 10),
        (0.01, 10),
        (0.01, 20),
        (0.01, 50),
        (0.001, 50),
        (0.001, 100),
        (0.0005, 100),
        (0.0005, 150),
        (0.0001, 150),
        (0.0001, 200),
        (0.00005, 200),
        (0.00005, 250),
        (0.00001, 250),
        (0.00001, 300),
        (0.000005, 300),
    ]

    training_versions = String[]
    training_types = ChangeType[]

    for (i, (lr, epochs)) in enumerate(training_params)
        code = """
        # Hyperparameters
        @persistent n_samples = length(features)
        @hole learning_rate = $lr
        @hole n_epochs = $epochs

        # Simple gradient descent simulation
        weights = randn(1)
        for epoch in 1:n_epochs
            gradient = 0.0
            for j in 1:min(1000, n_samples)
                pred = weights[1] * features[j]
                error = pred - labels[j]
                gradient += error * features[j]
            end
            weights[1] -= learning_rate * gradient / 1000
        end
        loss = sum((weights[1] .* features[1:1000] .- labels[1:1000]).^2) / 1000
        println("Epoch \$n_epochs, LR=\$learning_rate, Loss: \$loss")
        (weights, loss)
        """
        push!(training_versions, code)
        push!(training_types, i == 1 ? INITIAL : PARAMETER)
    end

    cell4 = CellEvolution(
        "train",
        training_versions,
        training_types,
        "Model training with hyperparameter tuning";
        depends_on = ["features"]
    )

    # Cell 5: Visualization (6 parameter tweaks)
    viz_versions = [
        """
        result = "Training complete, loss: \$(loss)"
        println(result)
        result
        """,
        """
        @hole title = "Model Training Results"
        result = "\$title - Loss: \$(round(loss, digits=4))"
        println(result)
        result
        """,
        """
        @hole title = "Model Training Results"
        @hole precision = 6
        result = "\$title - Loss: \$(round(loss, digits=precision))"
        println(result)
        result
        """,
        """
        @hole title = "Final Model Performance"
        @hole precision = 6
        result = "\$title\\nFinal Loss: \$(round(loss, digits=precision))\\nWeights: \$(weights)"
        println(result)
        result
        """,
        """
        @hole title = "Final Model Performance"
        @hole precision = 8
        @hole show_weights = true
        result = "\$title\\nFinal Loss: \$(round(loss, digits=precision))"
        if show_weights
            result *= "\\nWeights: \$(weights)"
        end
        println(result)
        result
        """,
        """
        @hole title = "ML Model Summary"
        @hole precision = 8
        @hole show_weights = true
        @hole show_samples = true
        result = "\$title\\nFinal Loss: \$(round(loss, digits=precision))"
        if show_weights
            result *= "\\nWeights: \$(weights)"
        end
        if show_samples
            result *= "\\nSamples: \$n_samples"
        end
        println(result)
        result
        """,
    ]

    cell5 = CellEvolution(
        "visualize",
        viz_versions,
        [INITIAL, PARAMETER, PARAMETER, PARAMETER, PARAMETER, PARAMETER],
        "Visualization and reporting";
        depends_on = ["train"]
    )

    cells = [cell1, cell2, cell3, cell4, cell5]

    # Create execution trace
    execution_trace = create_execution_trace(cells)

    return NotebookScenario(
        "Data Science Workflow",
        "Simulates EDA: load → preprocess → features → train → visualize",
        cells,
        execution_trace
    )
end

# Julia-only versions (without @persistent/@hole macros)
function get_julia_code(scenario::NotebookScenario, cell_id::String, version::Int)::String
    code = scenario.cells[cell_id].versions[version]
    # Remove @persistent and @hole macros for plain Julia execution
    code = replace(code, r"@persistent\s+" => "")
    code = replace(code, r"@hole\s+" => "")
    return code
end

# nbjit versions (keep @persistent/@hole macros)
function get_nbjit_code(scenario::NotebookScenario, cell_id::String, version::Int)::String
    return scenario.cells[cell_id].versions[version]
end
