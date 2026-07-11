"""
Algorithm Development Scenario

Simulates incremental algorithm refinement in a single cell.
This is the worst case for nbjit (structure changes require recompilation),
but still represents a realistic development pattern.

The algorithm evolves from naive to optimized implementation.
"""

using ..CellEvolutionLib
using ..CellEvolutionLib: INITIAL, STRUCTURE, PARAMETER

function create_algorithm_development()::NotebookScenario
    # Single cell that evolves through algorithm development
    algo_versions = [
        # v1: Naive O(n^2) implementation
        """
        @hole _v = 1
        function find_pairs(data, target)
            n = length(data)
            pairs = Tuple{Int,Int}[]
            for i in 1:n
                for j in (i+1):n
                    if data[i] + data[j] == target
                        push!(pairs, (i, j))
                    end
                end
            end
            pairs
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = find_pairs(test_data, target_sum)
        println("Found \$(length(result)) pairs (naive)")
        result
        """,

        # v2: Add early termination
        """
        @hole _v = 2
        function find_pairs(data, target; max_pairs=100)
            n = length(data)
            pairs = Tuple{Int,Int}[]
            for i in 1:n
                for j in (i+1):n
                    if data[i] + data[j] == target
                        push!(pairs, (i, j))
                        length(pairs) >= max_pairs && return pairs
                    end
                end
            end
            pairs
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = find_pairs(test_data, target_sum)
        println("Found \$(length(result)) pairs (with early exit)")
        result
        """,

        # v3: Use Set for O(n) lookup
        """
        @hole _v = 3
        function find_pairs(data, target; max_pairs=100)
            seen = Set{Int}()
            pairs = Tuple{Int,Int}[]

            for (i, val) in enumerate(data)
                complement = target - val
                if complement in seen
                    push!(pairs, (i, findfirst(==(complement), data)))
                    length(pairs) >= max_pairs && return pairs
                end
                push!(seen, val)
            end
            pairs
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = find_pairs(test_data, target_sum)
        println("Found \$(length(result)) pairs (Set-based)")
        result
        """,

        # v4: Use Dict for index tracking
        """
        @hole _v = 4
        function find_pairs(data, target; max_pairs=100)
            seen = Dict{Int, Int}()  # value -> index
            pairs = Tuple{Int,Int}[]

            for (i, val) in enumerate(data)
                complement = target - val
                if haskey(seen, complement)
                    push!(pairs, (seen[complement], i))
                    length(pairs) >= max_pairs && return pairs
                end
                seen[val] = i
            end
            pairs
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = find_pairs(test_data, target_sum)
        println("Found \$(length(result)) pairs (Dict-based)")
        result
        """,

        # v5: Handle duplicates properly
        """
        @hole _v = 5
        function find_pairs(data, target; max_pairs=100)
            seen = Dict{Int, Vector{Int}}()  # value -> list of indices
            pairs = Tuple{Int,Int}[]

            for (i, val) in enumerate(data)
                complement = target - val
                if haskey(seen, complement)
                    for j in seen[complement]
                        push!(pairs, (j, i))
                        length(pairs) >= max_pairs && return pairs
                    end
                end
                if !haskey(seen, val)
                    seen[val] = Int[]
                end
                push!(seen[val], i)
            end
            pairs
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = find_pairs(test_data, target_sum)
        println("Found \$(length(result)) pairs (handles duplicates)")
        result
        """,

        # v6: Add type annotations for performance
        """
        @hole _v = 6
        function find_pairs(data::Vector{Int}, target::Int; max_pairs::Int=100)
            seen = Dict{Int, Vector{Int}}()
            pairs = Vector{Tuple{Int,Int}}()
            sizehint!(pairs, max_pairs)

            for (i, val) in enumerate(data)
                complement = target - val
                if haskey(seen, complement)
                    for j in seen[complement]
                        push!(pairs, (j, i))
                        length(pairs) >= max_pairs && return pairs
                    end
                end
                indices = get!(Vector{Int}, seen, val)
                push!(indices, i)
            end
            pairs
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = find_pairs(test_data, target_sum)
        println("Found \$(length(result)) pairs (typed)")
        result
        """,

        # v7: Pre-allocate more aggressively
        """
        @hole _v = 7
        function find_pairs(data::Vector{Int}, target::Int; max_pairs::Int=100)
            n = length(data)
            seen = Dict{Int, Vector{Int}}()
            sizehint!(seen, n)
            pairs = Vector{Tuple{Int,Int}}()
            sizehint!(pairs, max_pairs)

            @inbounds for i in 1:n
                val = data[i]
                complement = target - val
                if haskey(seen, complement)
                    for j in seen[complement]
                        push!(pairs, (j, i))
                        length(pairs) >= max_pairs && return pairs
                    end
                end
                indices = get!(Vector{Int}, seen, val)
                push!(indices, i)
            end
            pairs
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = find_pairs(test_data, target_sum)
        println("Found \$(length(result)) pairs (pre-allocated)")
        result
        """,

        # v8: Return count instead of pairs for benchmarking
        """
        @hole _v = 8
        function count_pairs(data::Vector{Int}, target::Int)
            n = length(data)
            seen = Dict{Int, Int}()  # value -> count
            sizehint!(seen, n)
            pair_count = 0

            @inbounds for i in 1:n
                val = data[i]
                complement = target - val
                pair_count += get(seen, complement, 0)
                seen[val] = get(seen, val, 0) + 1
            end
            pair_count
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = count_pairs(test_data, target_sum)
        println("Found \$result pairs (count-only)")
        result
        """,

        # v9: Add SIMD hint
        """
        @hole _v = 9
        function count_pairs(data::Vector{Int}, target::Int)
            n = length(data)
            seen = Dict{Int, Int}()
            sizehint!(seen, n)
            pair_count = 0

            @simd for i in 1:n
                @inbounds val = data[i]
                complement = target - val
                pair_count += get(seen, complement, 0)
                seen[val] = get(seen, val, 0) + 1
            end
            pair_count
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = count_pairs(test_data, target_sum)
        println("Found \$result pairs (SIMD hint)")
        result
        """,

        # v10: Final optimized version
        """
        @hole _v = 10
        @inline function count_pairs_optimized(data::Vector{Int}, target::Int)
            n = length(data)
            # Use array instead of Dict for small value ranges
            max_val = maximum(data)
            min_val = minimum(data)

            if max_val - min_val < 10000
                # Array-based counting for small ranges
                offset = 1 - min_val
                counts = zeros(Int, max_val - min_val + 1)
                pair_count = 0

                @inbounds for i in 1:n
                    val = data[i]
                    complement = target - val
                    if min_val <= complement <= max_val
                        pair_count += counts[complement + offset]
                    end
                    counts[val + offset] += 1
                end
                return pair_count
            else
                # Dict-based for large ranges
                seen = Dict{Int, Int}()
                sizehint!(seen, n)
                pair_count = 0

                @inbounds for i in 1:n
                    val = data[i]
                    complement = target - val
                    pair_count += get(seen, complement, 0)
                    seen[val] = get(seen, val, 0) + 1
                end
                return pair_count
            end
        end

        test_data = rand(1:100, 1000)
        target_sum = 50
        result = count_pairs_optimized(test_data, target_sum)
        println("Found \$result pairs (final optimized)")
        result
        """,

        # v11-v20: Parameter variations on the optimized version
        """
        @inline function count_pairs_optimized(data::Vector{Int}, target::Int)
            n = length(data)
            max_val = maximum(data)
            min_val = minimum(data)

            @hole threshold = 10000

            if max_val - min_val < threshold
                offset = 1 - min_val
                counts = zeros(Int, max_val - min_val + 1)
                pair_count = 0
                @inbounds for i in 1:n
                    val = data[i]
                    complement = target - val
                    if min_val <= complement <= max_val
                        pair_count += counts[complement + offset]
                    end
                    counts[val + offset] += 1
                end
                return pair_count
            else
                seen = Dict{Int, Int}()
                sizehint!(seen, n)
                pair_count = 0
                @inbounds for i in 1:n
                    val = data[i]
                    complement = target - val
                    pair_count += get(seen, complement, 0)
                    seen[val] = get(seen, val, 0) + 1
                end
                return pair_count
            end
        end

        @persistent test_data = rand(1:100, 5000)
        @hole target_sum = 50
        result = count_pairs_optimized(test_data, target_sum)
        println("Found \$result pairs (threshold=10000, target=50)")
        result
        """,
    ]

    # Add more parameter variations
    for target in [60, 70, 80, 90, 100, 110, 120, 130, 140]
        push!(algo_versions, """
        @inline function count_pairs_optimized(data::Vector{Int}, target::Int)
            n = length(data)
            max_val = maximum(data)
            min_val = minimum(data)

            @hole threshold = 10000

            if max_val - min_val < threshold
                offset = 1 - min_val
                counts = zeros(Int, max_val - min_val + 1)
                pair_count = 0
                @inbounds for i in 1:n
                    val = data[i]
                    complement = target - val
                    if min_val <= complement <= max_val
                        pair_count += counts[complement + offset]
                    end
                    counts[val + offset] += 1
                end
                return pair_count
            else
                seen = Dict{Int, Int}()
                sizehint!(seen, n)
                pair_count = 0
                @inbounds for i in 1:n
                    val = data[i]
                    complement = target - val
                    pair_count += get(seen, complement, 0)
                    seen[val] = get(seen, val, 0) + 1
                end
                return pair_count
            end
        end

        @persistent test_data = rand(1:100, 5000)
        @hole target_sum = $target
        result = count_pairs_optimized(test_data, target_sum)
        println("Found \$result pairs (threshold=10000, target=$target)")
        result
        """)
    end

    algo_types = vcat(
        [INITIAL],            # v1 is the initial version
        fill(STRUCTURE, 9),   # v2-v10 are structural changes
        [STRUCTURE],          # v11 introduces @persistent/@hole (still a structure change)
        fill(PARAMETER, 9)    # v12-v20 are parameter changes
    )

    cell1 = CellEvolution(
        "algorithm",
        algo_versions,
        algo_types,
        "Algorithm development from naive to optimized";
        depends_on = String[]
    )

    cells = [cell1]
    execution_trace = create_execution_trace(cells)

    return NotebookScenario(
        "Algorithm Development",
        "20 iterations: 10 structural + 10 parameter changes",
        cells,
        execution_trace
    )
end
