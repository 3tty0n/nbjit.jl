"""
External Call Runtime Support for nbjit

This module provides runtime bridges for calling external Julia functions
(from packages or user modules) from JIT-compiled code.

The approach:
1. External function calls are compiled as calls to runtime bridge functions
2. The bridge functions use Julia's dynamic dispatch to call the actual functions
3. Arguments and return values are marshalled between LLVM primitives and Julia objects
4. Function pointers are exported via the runtime stub C library for linking
"""

include("./imports.jl")

# Registry for external function call bridges
const EXTERNAL_CALL_REGISTRY = Dict{String, Tuple{Function, Ptr{Cvoid}}}()

"""
Registry to store (module, function_name) pairs for bridge dispatch.
Key: unique bridge ID
Value: (Module, Symbol)
"""
const BRIDGE_DISPATCH_TABLE = Dict{UInt64, Tuple{Module, Symbol}}()
const NEXT_BRIDGE_ID = Ref{UInt64}(1)
const STATIC_BRIDGE_NAME_TABLE = Dict{String, Symbol}()

"""
Get the next bridge ID and increment the counter
"""
function next_bridge_id()::UInt64
    id = NEXT_BRIDGE_ID[]
    NEXT_BRIDGE_ID[] += 1
    return id
end

"""
Generic bridge caller that looks up and calls the function from the dispatch table.
This avoids creating closures.
"""
function _bridge_call_0(bridge_id::UInt64)::Ptr{Nothing}
    mod, func_name = BRIDGE_DISPATCH_TABLE[bridge_id]
    actual_func = getfield(mod, func_name)
    result = actual_func()
    return box_result(result)
end

function _bridge_call_1(bridge_id::UInt64, arg1::Ptr{Nothing})::Ptr{Nothing}
    mod, func_name = BRIDGE_DISPATCH_TABLE[bridge_id]
    actual_func = getfield(mod, func_name)
    a1 = unbox_arg(arg1)
    result = actual_func(a1)
    return box_result(result)
end

function _bridge_call_2(bridge_id::UInt64, arg1::Ptr{Nothing}, arg2::Ptr{Nothing})::Ptr{Nothing}
    mod, func_name = BRIDGE_DISPATCH_TABLE[bridge_id]
    actual_func = getfield(mod, func_name)
    a1 = unbox_arg(arg1)
    a2 = unbox_arg(arg2)
    result = actual_func(a1, a2)
    return box_result(result)
end

function _bridge_call_3(bridge_id::UInt64, arg1::Ptr{Nothing}, arg2::Ptr{Nothing}, arg3::Ptr{Nothing})::Ptr{Nothing}
    mod, func_name = BRIDGE_DISPATCH_TABLE[bridge_id]
    actual_func = getfield(mod, func_name)
    a1 = unbox_arg(arg1)
    a2 = unbox_arg(arg2)
    a3 = unbox_arg(arg3)
    result = actual_func(a1, a2, a3)
    return box_result(result)
end

function _bridge_call_4(bridge_id::UInt64, arg1::Ptr{Nothing}, arg2::Ptr{Nothing}, arg3::Ptr{Nothing}, arg4::Ptr{Nothing})::Ptr{Nothing}
    mod, func_name = BRIDGE_DISPATCH_TABLE[bridge_id]
    actual_func = getfield(mod, func_name)
    a1 = unbox_arg(arg1)
    a2 = unbox_arg(arg2)
    a3 = unbox_arg(arg3)
    a4 = unbox_arg(arg4)
    result = actual_func(a1, a2, a3, a4)
    return box_result(result)
end

function _bridge_call_5(bridge_id::UInt64, arg1::Ptr{Nothing}, arg2::Ptr{Nothing}, arg3::Ptr{Nothing}, arg4::Ptr{Nothing}, arg5::Ptr{Nothing})::Ptr{Nothing}
    mod, func_name = BRIDGE_DISPATCH_TABLE[bridge_id]
    actual_func = getfield(mod, func_name)
    a1 = unbox_arg(arg1)
    a2 = unbox_arg(arg2)
    a3 = unbox_arg(arg3)
    a4 = unbox_arg(arg4)
    a5 = unbox_arg(arg5)
    result = actual_func(a1, a2, a3, a4, a5)
    return box_result(result)
end

"""
Create a bridge function for calling an external Julia function.
The bridge accepts Julia object pointers and returns a Julia object pointer.

Arguments:
- mod: The module containing the function
- func_name: The name of the function
- n_args: Expected number of arguments (for generating the right ccall signature)

Returns: bridge_function (non-closure wrapper)
"""
function create_external_call_bridge(mod::Module, func_name::Symbol, n_args::Int)
    # Get the actual function
    if !isdefined(mod, func_name)
        error("Function $func_name not found in module $(nameof(mod))")
    end

    # Register in dispatch table
    bridge_id = next_bridge_id()
    BRIDGE_DISPATCH_TABLE[bridge_id] = (mod, func_name)

    # Return a wrapper that calls the dispatch function with the bridge_id
    # This creates a closure, but it's just for the Julia side - not for @cfunction
    if n_args == 0
        return () -> _bridge_call_0(bridge_id)
    elseif n_args == 1
        return (a1) -> _bridge_call_1(bridge_id, a1)
    elseif n_args == 2
        return (a1, a2) -> _bridge_call_2(bridge_id, a1, a2)
    elseif n_args == 3
        return (a1, a2, a3) -> _bridge_call_3(bridge_id, a1, a2, a3)
    elseif n_args == 4
        return (a1, a2, a3, a4) -> _bridge_call_4(bridge_id, a1, a2, a3, a4)
    elseif n_args == 5
        return (a1, a2, a3, a4, a5) -> _bridge_call_5(bridge_id, a1, a2, a3, a4, a5)
    else
        error("External calls with more than 5 arguments not yet supported")
    end
end

"""
Unbox a pointer argument to a Julia value
"""
function unbox_arg(ptr::Ptr{Nothing})
    if ptr == C_NULL
        return nothing
    end
    obj = unsafe_pointer_to_objref(ptr)
    # Unwrap Ref if necessary
    if obj isa Base.RefValue
        return obj[]
    end
    return obj
end

"""
Box a result value to a pointer
"""
function box_result(result)::Ptr{Nothing}
    if result === nothing
        return Ptr{Nothing}(0)
    elseif result isa Int64 || result isa Float64 || result isa Bool
        # Box primitive values
        boxed = Ref(result)
        id = nbjit_register_object(boxed)
        return nbjit_get_object(id)
    else
        # Register the object to prevent GC
        id = nbjit_register_object(result)
        return nbjit_get_object(id)
    end
end

"""
Register an external function bridge and get its C function pointer.
The pointer can be used for LLVM external linkage.
"""
function register_external_bridge(mod::Module, func_name::Symbol, n_args::Int)::Ptr{Cvoid}
    key = "$(nameof(mod))_$(func_name)_$(n_args)"

    if haskey(EXTERNAL_CALL_REGISTRY, key)
        return EXTERNAL_CALL_REGISTRY[key][2]
    end

    bridge_func = create_external_call_bridge(mod, func_name, n_args)

    # Generate cfunction pointer based on arity (must use literal tuples)
    cfunc_ptr = _make_cfunc_ptr(bridge_func, n_args)

    EXTERNAL_CALL_REGISTRY[key] = (bridge_func, cfunc_ptr)
    return cfunc_ptr
end

function make_static_bridge_name(key::String)::Symbol
    sanitized = replace(key, r"[^A-Za-z0-9_]" => "_")
    return Symbol("nbjit_bridge_" * sanitized)
end

function ensure_static_bridge_function!(key::String, mod::Module, func_name::Symbol, n_args::Int)::Symbol
    if haskey(STATIC_BRIDGE_NAME_TABLE, key)
        return STATIC_BRIDGE_NAME_TABLE[key]
    end

    bridge_id = next_bridge_id()
    BRIDGE_DISPATCH_TABLE[bridge_id] = (mod, func_name)
    fname = make_static_bridge_name(key)

    if n_args == 0
        @eval function $(fname)()::Ptr{Nothing}
            return _bridge_call_0($bridge_id)
        end
    elseif n_args == 1
        @eval function $(fname)(a1::Ptr{Nothing})::Ptr{Nothing}
            return _bridge_call_1($bridge_id, a1)
        end
    elseif n_args == 2
        @eval function $(fname)(a1::Ptr{Nothing}, a2::Ptr{Nothing})::Ptr{Nothing}
            return _bridge_call_2($bridge_id, a1, a2)
        end
    elseif n_args == 3
        @eval function $(fname)(a1::Ptr{Nothing}, a2::Ptr{Nothing}, a3::Ptr{Nothing})::Ptr{Nothing}
            return _bridge_call_3($bridge_id, a1, a2, a3)
        end
    elseif n_args == 4
        @eval function $(fname)(a1::Ptr{Nothing}, a2::Ptr{Nothing}, a3::Ptr{Nothing}, a4::Ptr{Nothing})::Ptr{Nothing}
            return _bridge_call_4($bridge_id, a1, a2, a3, a4)
        end
    elseif n_args == 5
        @eval function $(fname)(a1::Ptr{Nothing}, a2::Ptr{Nothing}, a3::Ptr{Nothing}, a4::Ptr{Nothing}, a5::Ptr{Nothing})::Ptr{Nothing}
            return _bridge_call_5($bridge_id, a1, a2, a3, a4, a5)
        end
    else
        error("External calls with more than 5 arguments not yet supported")
    end

    STATIC_BRIDGE_NAME_TABLE[key] = fname
    return fname
end

function get_static_bridge_cfunc_ptr(key::String, mod::Module, func_name::Symbol, n_args::Int)::Ptr{Cvoid}
    fname = ensure_static_bridge_function!(key, mod, func_name, n_args)
    if n_args == 0
        return @eval @cfunction($fname, Ptr{Cvoid}, ())
    elseif n_args == 1
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid},))
    elseif n_args == 2
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}))
    elseif n_args == 3
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    elseif n_args == 4
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    elseif n_args == 5
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    else
        error("External calls with more than 5 arguments not yet supported")
    end
end

function cfunc_ptr_from_symbol(fname::Symbol, n_args::Int)::Ptr{Cvoid}
    if n_args == 0
        return @eval @cfunction($fname, Ptr{Cvoid}, ())
    elseif n_args == 1
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid},))
    elseif n_args == 2
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}))
    elseif n_args == 3
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    elseif n_args == 4
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    elseif n_args == 5
        return @eval @cfunction($fname, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    else
        error("External calls with more than 5 arguments not yet supported")
    end
end

# Helper to create cfunc pointers with literal tuple types
function _make_cfunc_ptr(f::Function, n_args::Int)::Ptr{Cvoid}
    if n_args == 0
        return @cfunction($f, Ptr{Cvoid}, ())
    elseif n_args == 1
        return @cfunction($f, Ptr{Cvoid}, (Ptr{Cvoid},))
    elseif n_args == 2
        return @cfunction($f, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}))
    elseif n_args == 3
        return @cfunction($f, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    elseif n_args == 4
        return @cfunction($f, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    elseif n_args == 5
        return @cfunction($f, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    else
        error("External calls with more than 5 arguments not yet supported")
    end
end

"""
Get a registered bridge pointer, or nothing if not registered
"""
function get_external_bridge(mod::Module, func_name::Symbol, n_args::Int)::Union{Ptr{Cvoid}, Nothing}
    key = "$(nameof(mod))_$(func_name)_$(n_args)"
    if haskey(EXTERNAL_CALL_REGISTRY, key)
        return EXTERNAL_CALL_REGISTRY[key][2]
    end
    return nothing
end

"""
Clear all registered external bridges
"""
function clear_external_bridges!()
    empty!(EXTERNAL_CALL_REGISTRY)
end

# Registry for keeping bridge functions alive (prevent GC)
const BRIDGE_FUNCTION_REGISTRY = Dict{String, Any}()

"""
Create and register a bridge for calling a module function.
Returns the runtime function name that should be declared in LLVM.
Also registers the C function pointer for linking.
"""
function setup_external_call(module_path::Vector{Symbol}, func_name::Symbol, n_args::Int)::String
    # Resolve the module
    mod = resolve_module(module_path)
    if mod === nothing
        error("Could not resolve module: $(join(module_path, "."))")
    end

    # Generate the runtime function name
    runtime_name = generate_runtime_func_name(module_path, func_name)

    # Check if we already have a bridge for this exact call
    key = "$(runtime_name)_$(n_args)"
    if haskey(BRIDGE_FUNCTION_REGISTRY, key)
        return runtime_name
    end

    cfunc_ptr = get_static_bridge_cfunc_ptr(key, mod, func_name, n_args)
    BRIDGE_FUNCTION_REGISTRY[key] = STATIC_BRIDGE_NAME_TABLE[key]
    register_external_func_pointer!(runtime_name, cfunc_ptr)

    # Also register in the runtime library for dynamic linking (if available)
    if @isdefined(runtime_register_external_func)
        try
            runtime_register_external_func(runtime_name, cfunc_ptr)
        catch e
            # Runtime library may not be initialized yet
            @debug "Could not register external func in runtime: $e"
        end
    end

    return runtime_name
end

"""
Create and register a bridge for calling a function from a known Module object.
Use this for direct-import calls where module resolution is already complete.
"""
function setup_external_call_for_module(mod::Module, func_name::Symbol, n_args::Int)::String
    runtime_name = generate_runtime_func_name([nameof(mod)], func_name)
    key = "$(runtime_name)_$(n_args)"
    if haskey(BRIDGE_FUNCTION_REGISTRY, key)
        return runtime_name
    end

    cfunc_ptr = get_static_bridge_cfunc_ptr(key, mod, func_name, n_args)
    BRIDGE_FUNCTION_REGISTRY[key] = STATIC_BRIDGE_NAME_TABLE[key]
    register_external_func_pointer!(runtime_name, cfunc_ptr)

    if @isdefined(runtime_register_external_func)
        try
            runtime_register_external_func(runtime_name, cfunc_ptr)
        catch e
            @debug "Could not register external func in runtime: $e"
        end
    end

    return runtime_name
end

"""
Get the C function pointer for a bridge function with given arity.
Alias for _make_cfunc_ptr for backward compatibility.
"""
get_bridge_cfunc_ptr(bridge_func::Function, n_args::Int) = _make_cfunc_ptr(bridge_func, n_args)

"""
Get the C function pointer for a registered bridge
"""
function get_bridge_cfunc(module_path::Vector{Symbol}, func_name::Symbol, n_args::Int)::Ptr{Cvoid}
    runtime_name = generate_runtime_func_name(module_path, func_name)
    key = "$(runtime_name)_$(n_args)"

    if !haskey(BRIDGE_FUNCTION_REGISTRY, key)
        error("Bridge not registered: $key")
    end

    bridge = BRIDGE_FUNCTION_REGISTRY[key]
    if bridge isa Symbol
        return cfunc_ptr_from_symbol(bridge, n_args)
    end
    return _make_cfunc_ptr(bridge, n_args)
end

"""
Store function pointer globally so it can be resolved at link time
"""
const EXTERNAL_FUNC_POINTERS = Dict{String, Ptr{Cvoid}}()

"""
Register an external function pointer with a name that LLVM can resolve
"""
function register_external_func_pointer!(name::String, ptr::Ptr{Cvoid})
    EXTERNAL_FUNC_POINTERS[name] = ptr
end

"""
Get an external function pointer by name
"""
function get_external_func_pointer(name::String)::Union{Ptr{Cvoid}, Nothing}
    return get(EXTERNAL_FUNC_POINTERS, name, nothing)
end

export create_external_call_bridge, register_external_bridge, get_external_bridge
export clear_external_bridges!, setup_external_call, get_bridge_cfunc
export setup_external_call_for_module
export register_external_func_pointer!, get_external_func_pointer
export EXTERNAL_FUNC_POINTERS, BRIDGE_FUNCTION_REGISTRY
