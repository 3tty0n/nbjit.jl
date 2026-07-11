"""
Hyperparameter Tuning Scenario

Focused parameter-only changes - the best case for nbjit.
Simulates a user systematically trying different hyperparameter combinations.

- Cell 1: Data and model setup (stable, expensive)
- Cell 2: Training loop (50 parameter variations)
"""

using ..CellEvolutionLib
using ..CellEvolutionLib: INITIAL, PARAMETER

function create_hyperparameter_tuning()::NotebookScenario
    # Cell 1: Expensive setup (executed once)
    cell1 = CellEvolution(
        "setup",
        [
            """
            @hole _v = 1
            # Expensive data preparation
            @persistent n_samples = 50000
            @persistent n_features = 100

            # Generate synthetic dataset
            @persistent X = [randn(n_samples) for _ in 1:n_features]
            @persistent y = rand(0:1, n_samples)

            # Precompute feature matrix operations
            @persistent feature_sums = [sum(x) for x in X]
            @persistent feature_vars = [sum((x .- mean(x)).^2) for x in X]

            println("Setup complete: \$n_samples samples, \$n_features features")
            (X, y, feature_sums, feature_vars)
            """,
        ],
        [INITIAL],
        "Data and model setup";
        depends_on = String[]
    )

    # Cell 2: Training with many parameter variations
    # Generate 50 different hyperparameter combinations
    learning_rates = [0.1, 0.05, 0.01, 0.005, 0.001, 0.0005, 0.0001]
    batch_sizes = [32, 64, 128, 256, 512]
    regularizations = [0.0, 0.001, 0.01]

    # Create a grid of parameters (take first 50)
    param_grid = Tuple{Float64, Int, Float64}[]
    for lr in learning_rates
        for bs in batch_sizes
            for reg in regularizations
                push!(param_grid, (lr, bs, reg))
                length(param_grid) >= 50 && break
            end
            length(param_grid) >= 50 && break
        end
        length(param_grid) >= 50 && break
    end

    training_versions = String[]
    training_types = ChangeType[]

    for (i, (lr, bs, reg)) in enumerate(param_grid)
        code = """
        # Hyperparameters (these change each iteration)
        @hole learning_rate = $lr
        @hole batch_size = $bs
        @hole regularization = $reg
        @persistent n_epochs = 100

        # Training loop
        weights = zeros(n_features)
        n_batches = div(n_samples, batch_size)

        total_loss = 0.0
        for epoch in 1:n_epochs
            epoch_loss = 0.0
            for batch in 1:min(10, n_batches)  # Limit batches for benchmark
                start_idx = (batch - 1) * batch_size + 1
                end_idx = min(batch * batch_size, n_samples)

                # Simple gradient computation
                gradient = zeros(n_features)
                batch_loss = 0.0
                for j in start_idx:end_idx
                    pred = sum(weights[k] * X[k][j] for k in 1:n_features)
                    error = pred - y[j]
                    batch_loss += error^2
                    for k in 1:n_features
                        gradient[k] += error * X[k][j]
                    end
                end

                # Update weights with regularization
                for k in 1:n_features
                    weights[k] -= learning_rate * (gradient[k] / batch_size + regularization * weights[k])
                end
                epoch_loss += batch_loss
            end
            total_loss = epoch_loss
        end

        final_loss = total_loss / (10 * batch_size)
        println("LR=\$learning_rate, BS=\$batch_size, Reg=\$regularization → Loss: \$(round(final_loss, digits=4))")
        (learning_rate, batch_size, regularization, final_loss)
        """
        push!(training_versions, code)
        push!(training_types, i == 1 ? INITIAL : PARAMETER)
    end

    cell2 = CellEvolution(
        "train",
        training_versions,
        training_types,
        "Training loop with hyperparameter sweep";
        depends_on = ["setup"]
    )

    cells = [cell1, cell2]
    execution_trace = create_execution_trace(cells)

    return NotebookScenario(
        "Hyperparameter Tuning",
        "50 parameter-only iterations - nbjit's best case scenario",
        cells,
        execution_trace
    )
end
