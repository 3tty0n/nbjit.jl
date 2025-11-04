#!/usr/bin/env julia

include("../src/ijulia_integration.jl")

using .IJuliaIntegration
using Printf

function print_section(title::AbstractString)
    println()
    println("="^60)
    println(title)
    println("="^60)
end

function print_table(headers::Vector{String}, rows::Vector{Vector{String}})
    widths = [length(h) for h in headers]
    for row in rows
        for (i, cell) in enumerate(row)
            widths[i] = max(widths[i], length(cell))
        end
    end

    header_line = join([rpad(headers[i], widths[i]) for i in eachindex(headers)], "  ")
    separator = join([repeat("-", widths[i]) for i in eachindex(headers)], "  ")

    println(header_line)
    println(separator)
    for row in rows
        println(join([rpad(row[i], widths[i]) for i in eachindex(headers)], "  "))
    end
end

format_bool(flag::Bool) = flag ? "yes" : "no"
format_holes(h::Vector{Int}) = isempty(h) ? "-" : join(string.(h), ",")
format_result(value) = value === nothing ? "-" : string(value)
format_time(seconds) = @sprintf("%.3f ms", seconds * 1000)

function measure_cell(session, code, cell_id)
    local result
    elapsed = @elapsed result = run_cell!(session, code; cell_id=cell_id)
    return result, elapsed
end

function showcase_notebook_flow()
    print_section("Notebook Cell Flow")

    session = NotebookSession()
    scenarios = [
        ("cold run", quote
            base = 10
            @hole delta = 5
            value = base + delta
        end),
        ("repeat (cached)", quote
            base = 10
            @hole delta = 5
            value = base + delta
        end),
        ("hole changed", quote
            base = 10
            @hole delta = 20
            value = base + delta
        end),
        ("structure tweaked", quote
            base = 10
            temp = base * 2
            @hole delta = 20
            value = temp + delta
        end),
        ("structure cached", quote
            base = 10
            temp = base * 2
            @hole delta = 20
            value = temp + delta
        end)
    ]

    rows = Vector{Vector{String}}()
    for (label, code) in scenarios
        result, elapsed = measure_cell(session, code, "demo-cell")
        push!(rows, [
            label,
            String(result.exec_tier),
            format_bool(result.rebuilt_main),
            format_holes(result.recompiled_holes),
            format_result(result.result),
            format_time(elapsed)
        ])
    end

    print_table(
        ["scenario", "tier", "main rebuilt", "holes", "result", "time"],
        rows
    )
end

function hole_lib_summary(paths::Vector{String})
    isempty(paths) && return "-"
    return join(basename.(paths), ",")
end

function showcase_dylib_flow()
    print_section("Separate Dylib Flow")

    code1 = quote
        x = 100
        @hole y = 42
        result = x + y
        result
    end

    compiled = IJuliaIntegration.compile_to_separate_dylibs(code1)
    result1 = IJuliaIntegration.execute_dylib(compiled)

    rows = Vector{Vector{String}}()
    push!(rows, [
        "initial compile",
        basename(compiled.main_lib_path),
        hole_lib_summary(compiled.hole_lib_paths),
        format_result(result1),
        "-"
    ])

    code2 = quote
        x = 100
        @hole y = 99
        result = x + y
        result
    end

    changed, main_reset = redirect_stdout(devnull) do
        IJuliaIntegration.update_dylib!(compiled, code2)
    end
    result2 = IJuliaIntegration.execute_dylib(compiled)
    push!(rows, [
        "hole update",
        basename(compiled.main_lib_path),
        hole_lib_summary(compiled.hole_lib_paths),
        format_result(result2),
        main_reset ? "main rebuilt" : "holes " * format_holes(changed)
    ])

    changed2, main_reset2 = redirect_stdout(devnull) do
        IJuliaIntegration.update_dylib!(compiled, code2)
    end
    result3 = IJuliaIntegration.execute_dylib(compiled)
    push!(rows, [
        "no changes",
        basename(compiled.main_lib_path),
        hole_lib_summary(compiled.hole_lib_paths),
        format_result(result3),
        main_reset2 ? "main rebuilt" : "reuse"
    ])

    code3 = quote
        x = 100
        temp = x * 2
        @hole y = 99
        result = temp + y
        result
    end

    changed3, main_reset3 = redirect_stdout(devnull) do
        IJuliaIntegration.update_dylib!(compiled, code3)
    end
    result4 = IJuliaIntegration.execute_dylib(compiled)
    push!(rows, [
        "structure change",
        basename(compiled.main_lib_path),
        hole_lib_summary(compiled.hole_lib_paths),
        format_result(result4),
        main_reset3 ? "main rebuilt" : "holes " * format_holes(changed3)
    ])

    IJuliaIntegration.cleanup_dylib!(compiled)

    print_table(
        ["stage", "main dylib", "hole dylibs", "result", "notes"],
        rows
    )
end

function main()
    println("="^60)
    println("nbjit.jl showcase")
    println("="^60)
    showcase_notebook_flow()
    showcase_dylib_flow()
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
