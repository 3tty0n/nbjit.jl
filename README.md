# nbjit.jl

An IJulia kernel integration that enables a selective just-in-time (JIT) compilation for Julia.

## Usage

In your Jupyter notebook, load the IJulia integration module:

```julia
include("src/ijulia_integration.jl")
using .IJuliaIntegration: @jit
```

## Use Cases

### Parameter Tuning
```julia
@jit begin
    dataset = load_large_dataset()  # Slow
    model = build_model(dataset)     # Slow

    @hole learning_rate = 0.001      # Fast to change!
    @hole epochs = 100               # Fast to change!

    trained = train(model, learning_rate, epochs)
end
```

Adjust `learning_rate` and `epochs` without reloading data or rebuilding the model.

### Iterative Analysis
```julia
@jit begin
    data = expensive_preprocessing()  # Cached

    @hole filter_threshold = 0.5      # Experiment here
    filtered = filter(data, filter_threshold)

    results = analyze(filtered)
end
```

Try different thresholds without repeating preprocessing.

### Algorithm Development

NOTE: Currently (05.11.2025) `@hole` supports only integer assignment (very restricted, sorry!).

```julia
@jit begin
    setup = initialize_environment()

    @hole algorithm_params = Dict(
        :max_iter => 1000,
        :tolerance => 1e-6
    )

    result = run_algorithm(setup, algorithm_params)
end
```

## Development

### Prerequisite

- Julia module
  - DataStructures
  - PyCall
- Python module
  - apted
