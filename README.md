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

**Dictionary Support**: ✅ **NOW FULLY SUPPORTED!** You can use dictionaries directly in `@hole` blocks:

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

## Execution Flow

1. **Load runtime:** `include("src/ijulia_integration.jl")` (optionally `set_default_session!`).
2. **First run:** `@jit` parses the cell, splits out `@hole`s, generates LLVM IR, builds main/hole dylibs, executes them, and records hashes/guards (`exec_tier == :full`).
3. **Edit only a hole:** guard/main hashes match, so the runtime recompiles just the affected hole dylib, keeps the main dylib cached, and reports the hole indices (`exec_tier == :dylib`).
4. **Change structure/guards:** any mismatch triggers a full rebuild of the main dylib and updated guard signatures; caches refresh automatically.
5. **Pure cells:** `@cache` memoises hole-free cells by AST hash and skips execution once the code is unchanged.

## Development

### Prerequisite

- Julia module
  - DataStructures
  - PyCall
- Python module
  - apted
