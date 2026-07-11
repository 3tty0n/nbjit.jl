"""
Import Tracking and External Function Resolution for nbjit

This module handles:
1. Parsing `using` and `import` statements from Julia AST
2. Tracking imported modules and their exported functions
3. Resolving module-qualified function calls (e.g., `LinearAlgebra.norm`)
4. Creating runtime bridges to call external Julia functions from compiled code
"""

# Track imported modules and their bindings
mutable struct ImportContext
    # Module name => Module object
    modules::Dict{Symbol, Module}

    # Fully qualified name (Module.func) => function pointer info
    # Stores (Module, function_name, arity_hints)
    function_bindings::Dict{String, Tuple{Module, Symbol, Vector{Int}}}

    # Direct imports (from `using X: func` or `import X: func`)
    # func_name => (Module, original_name)
    direct_imports::Dict{Symbol, Tuple{Module, Symbol}}
end

ImportContext() = ImportContext(
    Dict{Symbol, Module}(),
    Dict{String, Tuple{Module, Symbol, Vector{Int}}}(),
    Dict{Symbol, Tuple{Module, Symbol}}()
)

# Global import context for the current session
const GLOBAL_IMPORT_CONTEXT = ImportContext()

"""
Reset the global import context
"""
function reset_import_context!()
    empty!(GLOBAL_IMPORT_CONTEXT.modules)
    empty!(GLOBAL_IMPORT_CONTEXT.function_bindings)
    empty!(GLOBAL_IMPORT_CONTEXT.direct_imports)
end

"""
Parse an AST and extract all `using` and `import` statements.
Returns a list of (statement_type, module_path, specific_imports) tuples.

- statement_type: :using or :import
- module_path: Vector{Symbol} for the module path (e.g., [:LinearAlgebra] or [:Base, :Iterators])
- specific_imports: Vector{Symbol} for specific imports (empty if importing whole module)
"""
function extract_import_statements(expr)::Vector{Tuple{Symbol, Vector{Symbol}, Vector{Symbol}}}
    imports = Tuple{Symbol, Vector{Symbol}, Vector{Symbol}}[]

    function traverse(e)
        if e isa Expr
            if e.head == :using
                parse_using_import!(imports, :using, e.args)
            elseif e.head == :import
                parse_using_import!(imports, :import, e.args)
            elseif e.head == :block || e.head == :toplevel
                for arg in e.args
                    traverse(arg)
                end
            end
        end
    end

    traverse(expr)
    return imports
end

"""
Parse the arguments of a using/import statement
"""
function parse_using_import!(imports, stmt_type, args)
    for arg in args
        if arg isa Expr
            if arg.head == :(:)
                # `using X: a, b` or `import X: a, b`
                module_part = arg.args[1]
                specific = Symbol[]
                for i in 2:length(arg.args)
                    item = arg.args[i]
                    if item isa Symbol
                        push!(specific, item)
                    elseif item isa Expr && item.head == :.
                        # Handle renamed imports like `using X: a as b`
                        push!(specific, item.args[1])
                    end
                end
                module_path = parse_module_path(module_part)
                push!(imports, (stmt_type, module_path, specific))
            elseif arg.head == :.
                # `using X.Y.Z` - full module path
                module_path = Symbol[]
                for part in arg.args
                    if part isa Symbol
                        push!(module_path, part)
                    end
                end
                push!(imports, (stmt_type, module_path, Symbol[]))
            end
        elseif arg isa Symbol
            push!(imports, (stmt_type, [arg], Symbol[]))
        end
    end
end

"""
Parse a module path expression into a vector of symbols
"""
function parse_module_path(expr)::Vector{Symbol}
    if expr isa Symbol
        return [expr]
    elseif expr isa Expr && expr.head == :.
        path = Symbol[]
        for part in expr.args
            if part isa Symbol
                push!(path, part)
            elseif part isa Expr
                append!(path, parse_module_path(part))
            end
        end
        return path
    end
    return Symbol[]
end

"""
Resolve a module path to an actual Module object
"""
function resolve_module(path::Vector{Symbol})::Union{Module, Nothing}
    if isempty(path)
        return nothing
    end

    # Start from Main module
    current = Main

    for (i, name) in enumerate(path)
        # Try to get the module
        if isdefined(current, name)
            obj = getfield(current, name)
            if obj isa Module
                current = obj
            else
                return nothing
            end
        else
            # Module might need to be loaded first
            # Try using the module
            try
                if i == 1
                    # Top-level module - try to load it
                    Core.eval(Main, Expr(:using, Expr(:., name)))
                    if isdefined(Main, name)
                        current = getfield(Main, name)
                    else
                        return nothing
                    end
                else
                    return nothing
                end
            catch
                return nothing
            end
        end
    end

    return current
end

"""
Register imports from an AST into the import context
"""
function register_imports!(ctx::ImportContext, expr; warn_on_unresolved::Bool=true)
    import_stmts = extract_import_statements(expr)

    for (stmt_type, module_path, specific_imports) in import_stmts
        mod = resolve_module(module_path)
        if mod === nothing
            if warn_on_unresolved
                @warn "Could not resolve module: $(join(module_path, "."))"
            end
            continue
        end

        # Register the module
        mod_name = module_path[end]
        ctx.modules[mod_name] = mod

        # If specific imports are specified, register them as direct imports
        if !isempty(specific_imports)
            for func_name in specific_imports
                if isdefined(mod, func_name)
                    ctx.direct_imports[func_name] = (mod, func_name)
                end
            end
        elseif stmt_type == :using
            # `using Module` makes exported names directly callable without
            # qualification. Track function exports for bridge dispatch.
            for name in names(mod)
                if isdefined(mod, name)
                    value = getfield(mod, name)
                    if value isa Function
                        ctx.direct_imports[name] = (mod, name)
                    end
                end
            end
        end
    end

    return ctx
end

"""
Check if a symbol is a module-qualified call (e.g., `LinearAlgebra.norm`)
"""
function is_module_qualified_call(expr)::Bool
    if expr isa Expr && expr.head == :call
        callee = expr.args[1]
        return callee isa Expr && callee.head == :.
    end
    return false
end

"""
Extract module and function name from a module-qualified call
Returns (module_path, function_name) or nothing
"""
function parse_qualified_call(expr)::Union{Tuple{Vector{Symbol}, Symbol}, Nothing}
    if !is_module_qualified_call(expr)
        return nothing
    end

    callee = expr.args[1]  # The X.func part

    # Parse the module path and function name
    path = Symbol[]
    current = callee

    while current isa Expr && current.head == :.
        if length(current.args) >= 2
            # The second arg is the field/function name (as QuoteNode)
            field = current.args[2]
            if field isa QuoteNode
                pushfirst!(path, field.value)
            elseif field isa Symbol
                pushfirst!(path, field)
            end
            current = current.args[1]
        else
            break
        end
    end

    if current isa Symbol
        pushfirst!(path, current)
    end

    if length(path) >= 2
        func_name = path[end]
        module_path = path[1:end-1]
        return (module_path, func_name)
    end

    return nothing
end

"""
Resolve a function from a module
Returns the function object or nothing
"""
function resolve_module_function(ctx::ImportContext, module_path::Vector{Symbol}, func_name::Symbol)
    # First check if we have the module registered
    if length(module_path) == 1
        mod_name = module_path[1]
        if haskey(ctx.modules, mod_name)
            mod = ctx.modules[mod_name]
            if isdefined(mod, func_name)
                return getfield(mod, func_name)
            end
        end
    end

    # Try to resolve the full path
    mod = resolve_module(module_path)
    if mod !== nothing && isdefined(mod, func_name)
        return getfield(mod, func_name)
    end

    return nothing
end

"""
Check if a function call is to a directly imported function
"""
function is_direct_import_call(ctx::ImportContext, func_name::Symbol)::Bool
    return haskey(ctx.direct_imports, func_name)
end

"""
Get the module and original name for a directly imported function
"""
function get_direct_import(ctx::ImportContext, func_name::Symbol)::Union{Tuple{Module, Symbol}, Nothing}
    return get(ctx.direct_imports, func_name, nothing)
end

"""
Scan an expression for all module-qualified calls and collect unique (module, function) pairs
"""
function collect_external_calls(expr, ctx::ImportContext=GLOBAL_IMPORT_CONTEXT)::Set{Tuple{Vector{Symbol}, Symbol}}
    calls = Set{Tuple{Vector{Symbol}, Symbol}}()

    function traverse(e)
        if e isa Expr
            if e.head == :call
                # Check for module-qualified call
                parsed = parse_qualified_call(e)
                if parsed !== nothing
                    push!(calls, parsed)
                else
                    # Check for direct import call
                    callee = e.args[1]
                    if callee isa Symbol && is_direct_import_call(ctx, callee)
                        import_info = get_direct_import(ctx, callee)
                        if import_info !== nothing
                            mod, orig_name = import_info
                            # Get the module name
                            mod_name = nameof(mod)
                            push!(calls, ([mod_name], orig_name))
                        end
                    end
                end
            end

            # Traverse all arguments
            for arg in e.args
                traverse(arg)
            end
        end
    end

    traverse(expr)
    return calls
end

"""
Generate a unique runtime function name for a module function call
"""
function generate_runtime_func_name(module_path::Vector{Symbol}, func_name::Symbol)::String
    mod_str = join(string.(module_path), "_")
    return "nbjit_call_$(mod_str)_$(func_name)"
end

export ImportContext, GLOBAL_IMPORT_CONTEXT, reset_import_context!
export extract_import_statements, register_imports!
export is_module_qualified_call, parse_qualified_call
export resolve_module, resolve_module_function
export collect_external_calls, generate_runtime_func_name
export is_direct_import_call, get_direct_import
