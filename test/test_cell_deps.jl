using Test

include("test_helper.jl")

@testset "Symbol Extraction" begin
    @testset "extract_definitions" begin
        # Simple assignment
        code = quote
            x = 1
            y = 2
        end
        defs = IJuliaIntegration.extract_definitions(code)
        @test :x in defs
        @test :y in defs

        # Compound assignment
        code2 = quote
            x = 0
            x += 1
        end
        defs2 = IJuliaIntegration.extract_definitions(code2)
        @test :x in defs2

        # Function definition
        code3 = quote
            function f(a)
                return a + 1
            end
        end
        defs3 = IJuliaIntegration.extract_definitions(code3)
        @test :f in defs3

        # For loop iterator
        code4 = quote
            for i = 1:10
                x = i * 2
            end
        end
        defs4 = IJuliaIntegration.extract_definitions(code4)
        @test :i in defs4
        @test :x in defs4

        # @hole annotated assignment
        code5 = quote
            @hole y = 100
        end
        defs5 = IJuliaIntegration.extract_definitions(code5)
        @test :y in defs5

        # @preserve annotated assignment
        code6 = quote
            @preserve data = load_data()
        end
        defs6 = IJuliaIntegration.extract_definitions(code6)
        @test :data in defs6
    end

    @testset "extract_references" begin
        # Simple reference to external symbol
        code = quote
            y = x + 1
        end
        refs = IJuliaIntegration.extract_references(code)
        @test :x in refs

        # Function call reference
        code2 = quote
            y = f(x)
        end
        refs2 = IJuliaIntegration.extract_references(code2)
        @test :f in refs2
        @test :x in refs2

        # For loop with external range
        code3 = quote
            for i = 1:n
                x = i + offset
            end
        end
        refs3 = IJuliaIntegration.extract_references(code3)
        @test :n in refs3
        @test :offset in refs3

        # @hole referencing external
        code4 = quote
            @hole y = base + 1
        end
        refs4 = IJuliaIntegration.extract_references(code4)
        @test :base in refs4

        # Built-in symbols should be excluded
        code5 = quote
            y = zeros(10)
            z = length(y)
        end
        refs5 = IJuliaIntegration.extract_references(code5)
        @test :zeros ∉ refs5
        @test :length ∉ refs5
    end
end

@testset "CellDependencyGraph" begin
    @testset "Basic dependency detection" begin
        graph = IJuliaIntegration.CellDependencyGraph()

        # Cell A defines x
        code_a = quote
            x = 42
            @hole delta = 1
            y = x + delta
        end
        stale_a = IJuliaIntegration.update_cell!(graph, "A", code_a)
        @test isempty(stale_a)  # No downstream cells yet

        # Cell B references x (defined by A)
        code_b = quote
            result = x * 2
            @hole scale = 1
            output = result * scale
        end
        stale_b = IJuliaIntegration.update_cell!(graph, "B", code_b)
        @test isempty(stale_b)  # B just registered, nothing downstream

        # Verify edges
        @test "A" in IJuliaIntegration.get_upstream(graph, "B")
        @test "B" in IJuliaIntegration.get_downstream(graph, "A")
    end

    @testset "Staleness propagation" begin
        graph = IJuliaIntegration.CellDependencyGraph()

        # Cell 1 defines data
        code1 = quote
            data = 100
            @hole threshold = 50
            filtered = data + threshold
        end
        IJuliaIntegration.update_cell!(graph, "cell1", code1)

        # Cell 2 uses data, defines result
        code2 = quote
            result = data * 2
            @hole factor = 3
            output = result + factor
        end
        IJuliaIntegration.update_cell!(graph, "cell2", code2)

        # Cell 3 uses result from cell2
        code3 = quote
            final = result + 10
            @hole bonus = 5
            answer = final + bonus
        end
        IJuliaIntegration.update_cell!(graph, "cell3", code3)

        # Re-execute cell1 — should mark cell2 and cell3 as stale
        stale = IJuliaIntegration.update_cell!(graph, "cell1", code1)
        @test "cell2" in stale
        @test "cell3" in stale  # Transitive: cell3 depends on cell2 depends on cell1

        # cell1 itself should NOT be stale
        @test "cell1" ∉ IJuliaIntegration.get_stale_cells(graph)
    end

    @testset "Topological ordering of stale cells" begin
        graph = IJuliaIntegration.CellDependencyGraph()

        # Linear chain: A → B → C
        IJuliaIntegration.update_cell!(graph, "A", quote
            x = 1
            @hole h = 0
            x = x + h
        end)
        IJuliaIntegration.update_cell!(graph, "B", quote
            y = x + 1
            @hole h = 0
            y = y + h
        end)
        IJuliaIntegration.update_cell!(graph, "C", quote
            z = y + 1
            @hole h = 0
            z = z + h
        end)

        # Re-execute A
        stale = IJuliaIntegration.update_cell!(graph, "A", quote
            x = 2
            @hole h = 0
            x = x + h
        end)

        # B should come before C in topological order
        b_idx = findfirst(==("B"), stale)
        c_idx = findfirst(==("C"), stale)
        @test b_idx !== nothing
        @test c_idx !== nothing
        @test b_idx < c_idx
    end

    @testset "Diamond dependency" begin
        graph = IJuliaIntegration.CellDependencyGraph()

        # A defines x
        IJuliaIntegration.update_cell!(graph, "A", quote
            x = 10
            @hole h = 0
            x = x + h
        end)

        # B and C both depend on A
        IJuliaIntegration.update_cell!(graph, "B", quote
            b = x + 1
            @hole h = 0
            b = b + h
        end)
        IJuliaIntegration.update_cell!(graph, "C", quote
            c = x + 2
            @hole h = 0
            c = c + h
        end)

        # D depends on both B and C
        IJuliaIntegration.update_cell!(graph, "D", quote
            d = b + c
            @hole h = 0
            d = d + h
        end)

        # Re-execute A — all of B, C, D should be stale
        stale = IJuliaIntegration.update_cell!(graph, "A", quote
            x = 20
            @hole h = 0
            x = x + h
        end)
        @test length(stale) == 3
        @test "B" in stale
        @test "C" in stale
        @test "D" in stale

        # D should come after both B and C
        d_idx = findfirst(==("D"), stale)
        b_idx = findfirst(==("B"), stale)
        c_idx = findfirst(==("C"), stale)
        @test d_idx > b_idx
        @test d_idx > c_idx
    end

    @testset "No false dependencies" begin
        graph = IJuliaIntegration.CellDependencyGraph()

        # Two independent cells
        IJuliaIntegration.update_cell!(graph, "X", quote
            a = 1
            @hole h = 0
            a = a + h
        end)
        IJuliaIntegration.update_cell!(graph, "Y", quote
            b = 2
            @hole h = 0
            b = b + h
        end)

        # Re-execute X — Y should NOT be stale
        stale = IJuliaIntegration.update_cell!(graph, "X", quote
            a = 99
            @hole h = 0
            a = a + h
        end)
        @test isempty(stale)
        @test "Y" ∉ IJuliaIntegration.get_stale_cells(graph)
    end

    @testset "Redefinition updates provider" begin
        graph = IJuliaIntegration.CellDependencyGraph()

        # Cell A defines x
        IJuliaIntegration.update_cell!(graph, "A", quote
            x = 1
            @hole h = 0
            x = x + h
        end)

        # Cell B uses x
        IJuliaIntegration.update_cell!(graph, "B", quote
            y = x + 1
            @hole h = 0
            y = y + h
        end)

        @test "A" in IJuliaIntegration.get_upstream(graph, "B")

        # Cell C now also defines x (later cell, overwrites provider)
        IJuliaIntegration.update_cell!(graph, "C", quote
            x = 999
            @hole h = 0
            x = x + h
        end)

        # After C defines x, B should now depend on C (last writer wins)
        @test "C" in IJuliaIntegration.get_upstream(graph, "B")
    end

    @testset "remove_cell!" begin
        graph = IJuliaIntegration.CellDependencyGraph()

        IJuliaIntegration.update_cell!(graph, "A", quote
            x = 1
            @hole h = 0
            x = x + h
        end)
        IJuliaIntegration.update_cell!(graph, "B", quote
            y = x + 1
            @hole h = 0
            y = y + h
        end)

        @test "A" in IJuliaIntegration.get_upstream(graph, "B")

        IJuliaIntegration.remove_cell!(graph, "A")
        @test !haskey(graph.definitions, "A")
        @test !haskey(graph.references, "A")
    end

    @testset "mark_fresh!" begin
        graph = IJuliaIntegration.CellDependencyGraph()

        IJuliaIntegration.update_cell!(graph, "A", quote
            x = 1
            @hole h = 0
            x = x + h
        end)
        IJuliaIntegration.update_cell!(graph, "B", quote
            y = x + 1
            @hole h = 0
            y = y + h
        end)

        # Make B stale
        IJuliaIntegration.update_cell!(graph, "A", quote
            x = 2
            @hole h = 0
            x = x + h
        end)
        @test "B" in IJuliaIntegration.get_stale_cells(graph)

        # Mark B as fresh
        IJuliaIntegration.mark_fresh!(graph, "B")
        @test "B" ∉ IJuliaIntegration.get_stale_cells(graph)
    end
end

@testset "Integration with NotebookSession" begin
    @testset "run_cell! populates dependency graph" begin
        session = IJuliaIntegration.NotebookSession()

        # Cell that defines x and value
        code1 = quote
            x = 10
            @hole delta = 1
            value = x + delta
        end
        res1 = IJuliaIntegration.run_cell!(session, code1; cell_id="cell1")

        # Verify the dependency graph was populated
        defs = IJuliaIntegration.get_cell_definitions(session.dep_graph, "cell1")
        @test :x in defs
        @test :value in defs
        @test :delta in defs
    end

    @testset "run_cell! reports stale cells via dep graph" begin
        session = IJuliaIntegration.NotebookSession()

        # Cell 1: defines x
        code1 = quote
            x = 10
            @hole delta = 1
            value = x + delta
        end
        res1 = IJuliaIntegration.run_cell!(session, code1; cell_id="cell1")
        @test isempty(res1.stale_cells)

        # Cell 2: reads x from cell1 via cross-cell global bindings
        code2 = quote
            result = x * 3
            @hole scale = 2
            output = result + scale
        end
        res2 = IJuliaIntegration.run_cell!(session, code2; cell_id="cell2")
        @test res2.result == 32

        # Re-execute cell1 — cell2 should appear in stale_cells
        code1_v2 = quote
            x = 20
            @hole delta = 1
            value = x + delta
        end
        res3 = IJuliaIntegration.run_cell!(session, code1_v2; cell_id="cell1")
        @test "cell2" in res3.stale_cells
    end

    @testset "clear_cache! resets dependency graph" begin
        session = IJuliaIntegration.NotebookSession()

        code = quote
            x = 1
            @hole y = 2
            z = x + y
        end
        IJuliaIntegration.run_cell!(session, code; cell_id="test")

        @test !isempty(session.dep_graph.definitions)

        IJuliaIntegration.clear_cache!(session)
        @test isempty(session.dep_graph.definitions)
        @test isempty(session.dep_graph.references)
        @test isempty(session.dep_graph.upstream)
        @test isempty(session.dep_graph.downstream)
    end

    @testset "cross-cell bindings are session-scoped" begin
        session1 = IJuliaIntegration.NotebookSession()
        session2 = IJuliaIntegration.NotebookSession()

        IJuliaIntegration.run_cell!(session1, quote
            x = 7
            @hole y = 1
            z = x + y
        end; cell_id="s1_cell")

        @test_throws ErrorException IJuliaIntegration.run_cell!(session2, quote
            x + 1
        end; cell_id="s2_cell")
    end
end

println("\nAll inter-cell dependency tracking tests passed!")
