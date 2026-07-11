# nbjit.jl

An IJulia kernel integration that enables an incremental computation for Julia in Jupyter Notebook.

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
    @persist dataset = load_large_dataset()   # Compiled to native code
    @persist model = build_model(dataset)     # Compiled to native code

    @hole learning_rate = 0.001      # Fast to change!
    @hole epochs = 100               # Fast to change!

    trained = train(model, learning_rate, epochs)
end
```

Adjust `learning_rate` and `epochs` without reloading data or rebuilding the model.

### Iterative Analysis
```julia
@jit begin
    @persist data = expensive_preprocessing()  # Cached

    @hole filter_threshold = 0.5      # Experiment here
    filtered = filter(data, filter_threshold)

    results = analyze(filtered)
end
```

Try different thresholds without repeating preprocessing.

### Algorithm Development

```julia
@jit begin
    @persist setup = initialize_environment()

    @hole algorithm_params = Dict(
        :max_iter => 1000,
        :tolerance => 1e-6
    )

    result = run_algorithm(setup, algorithm_params)
end
```

## Benchmark

This project uses [ReBench](https://github.com/smarr/ReBench) to measure the performance.
You can install it as follows:

```shell
$ pip3 install rebench
```

Then, you can run its benchmark:

```shell
$ rebench rebench.conf
```

Finally, you can get `benchmark.data` that keeps information that is captured by ReBench.

If you use cgroup v2 in your environment, please turn off rebench-denoise because it uses cset, which depends on cgroup v1. Simply do the following:


```shell
$ rebench rebench.conf --no-denoise
```
