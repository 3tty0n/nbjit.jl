"""
JIT Runtime Support for Julia Objects
"""

"""
Create a new empty Dict{Any, Any}
Returns: Ptr{Nothing} pointing to the Dict object
"""
function nbjit_dict_new()::Ptr{Nothing}
    d = Dict{Any, Any}()
    # Return pointer to the Dict - Julia's GC will manage it
    return pointer_from_objref(d)
end

"""
Create a Dict with initial key-value pairs
keys: Ptr{Nothing} to Vector of keys
values: Ptr{Nothing} to Vector of values
n: number of pairs
"""
function nbjit_dict_new_with_pairs(keys_ptr::Ptr{Nothing}, values_ptr::Ptr{Nothing}, n::Int64)::Ptr{Nothing}
    keys = unsafe_pointer_to_objref(keys_ptr)::Vector{Any}
    values = unsafe_pointer_to_objref(values_ptr)::Vector{Any}

    d = Dict{Any, Any}()
    for i in 1:n
        d[keys[i]] = values[i]
    end

    return pointer_from_objref(d)
end

"""
Get value from Dict by key
dict_ptr: Ptr{Nothing} to Dict
key_ptr: Ptr{Nothing} to key
Returns: Ptr{Nothing} to the value
"""
function nbjit_dict_getindex(dict_ptr::Ptr{Nothing}, key_ptr::Ptr{Nothing})::Ptr{Nothing}
    dict = unsafe_pointer_to_objref(dict_ptr)::Dict{Any, Any}
    key_obj = unsafe_pointer_to_objref(key_ptr)
    # Unwrap Ref if necessary
    key = key_obj isa Base.RefValue ? key_obj[] : key_obj
    value = dict[key]
    # Re-box primitive values to make them pointer-compatible
    if value isa Int64 || value isa Float64
        boxed_value = Ref(value)
        id = nbjit_register_object(boxed_value)
        return nbjit_get_object(id)
    else
        return pointer_from_objref(value)
    end
end

"""
Set value in Dict
dict_ptr: Ptr{Nothing} to Dict
key_ptr: Ptr{Nothing} to key
value_ptr: Ptr{Nothing} to the value
"""
function nbjit_dict_setindex!(dict_ptr::Ptr{Nothing}, value_ptr::Ptr{Nothing}, key_ptr::Ptr{Nothing})::Cvoid
    dict = unsafe_pointer_to_objref(dict_ptr)::Dict{Any, Any}
    key_obj = unsafe_pointer_to_objref(key_ptr)
    # Unwrap Ref if necessary
    key = key_obj isa Base.RefValue ? key_obj[] : key_obj
    value_obj = unsafe_pointer_to_objref(value_ptr)
    # Unwrap Ref if necessary
    value = value_obj isa Base.RefValue ? value_obj[] : value_obj
    dict[key] = value
    return nothing
end

"""
Create a Symbol from string (for QuoteNode handling)
str_ptr: Ptr{UInt8} to C string
Returns: Ptr{Nothing} to Symbol
"""
function nbjit_symbol_from_cstr(str_ptr::Ptr{UInt8})::Ptr{Nothing}
    str = unsafe_string(str_ptr)
    sym = Symbol(str)
    return pointer_from_objref(sym)
end

"""
Box an Int64 value into a Julia object
"""
function nbjit_box_int64(val::Int64)::Ptr{Nothing}
    # Wrap in Ref to make it mutable so pointer_from_objref works
    boxed = Ref(val)
    id = nbjit_register_object(boxed)
    return nbjit_get_object(id)
end

"""
Box a Float64 value into a Julia object
"""
function nbjit_box_float64(val::Float64)::Ptr{Nothing}
    # Wrap in Ref to make it mutable so pointer_from_objref works
    boxed = Ref(val)
    id = nbjit_register_object(boxed)
    return nbjit_get_object(id)
end

"""
Unbox a Julia object to Int64
"""
function nbjit_unbox_int64(obj_ptr::Ptr{Nothing})::Int64
    obj = unsafe_pointer_to_objref(obj_ptr)
    # Handle both Ref-wrapped and direct values
    if obj isa Base.RefValue{Int64}
        return obj[]
    else
        return Int64(obj)
    end
end

"""
Unbox a Julia object to Float64
"""
function nbjit_unbox_float64(obj_ptr::Ptr{Nothing})::Float64
    obj = unsafe_pointer_to_objref(obj_ptr)
    # Handle both Ref-wrapped and direct values
    if obj isa Base.RefValue{Float64}
        return obj[]
    else
        return Float64(obj)
    end
end

# Global registry to keep objects alive (prevent GC)
const OBJECT_REGISTRY = Dict{UInt, Any}()
const NEXT_OBJECT_ID = Ref{UInt}(1)

"""
Register an object to prevent GC and return its ID
"""
function nbjit_register_object(obj::Any)::UInt
    id = NEXT_OBJECT_ID[]
    NEXT_OBJECT_ID[] += 1
    OBJECT_REGISTRY[id] = obj
    return id
end

"""
Get an object by its registered ID
"""
function nbjit_get_object(id::UInt)::Ptr{Nothing}
    obj = OBJECT_REGISTRY[id]
    return pointer_from_objref(obj)
end

"""
Unregister an object (allow GC)
"""
function nbjit_unregister_object(id::UInt)::Cvoid
    delete!(OBJECT_REGISTRY, id)
    return nothing
end

# Export all runtime functions
for name in [
    :nbjit_dict_new,
    :nbjit_dict_new_with_pairs,
    :nbjit_dict_getindex,
    :nbjit_dict_setindex!,
    :nbjit_symbol_from_cstr,
    :nbjit_box_int64,
    :nbjit_box_float64,
    :nbjit_unbox_int64,
    :nbjit_unbox_float64,
    :nbjit_register_object,
    :nbjit_get_object,
    :nbjit_unregister_object
]
    @eval export $name
end

# Global dictionary to store C function pointers for runtime functions
const RUNTIME_FUNCTION_POINTERS = Dict{Symbol, Ptr{Cvoid}}()

"""
Register all runtime functions as C-callable and store their pointers.
This makes them available to dynamically loaded libraries.
"""
function register_runtime_functions()
    # Register each runtime function with @cfunction
    RUNTIME_FUNCTION_POINTERS[:nbjit_dict_new] = @cfunction(nbjit_dict_new, Ptr{Cvoid}, ())
    RUNTIME_FUNCTION_POINTERS[:nbjit_dict_new_with_pairs] = @cfunction(nbjit_dict_new_with_pairs, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Int64))
    RUNTIME_FUNCTION_POINTERS[:nbjit_dict_getindex] = @cfunction(nbjit_dict_getindex, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}))
    RUNTIME_FUNCTION_POINTERS[:nbjit_dict_setindex!] = @cfunction(nbjit_dict_setindex!, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    RUNTIME_FUNCTION_POINTERS[:nbjit_symbol_from_cstr] = @cfunction(nbjit_symbol_from_cstr, Ptr{Cvoid}, (Ptr{UInt8},))
    RUNTIME_FUNCTION_POINTERS[:nbjit_box_int64] = @cfunction(nbjit_box_int64, Ptr{Cvoid}, (Int64,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_box_float64] = @cfunction(nbjit_box_float64, Ptr{Cvoid}, (Float64,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_unbox_int64] = @cfunction(nbjit_unbox_int64, Int64, (Ptr{Cvoid},))
    RUNTIME_FUNCTION_POINTERS[:nbjit_unbox_float64] = @cfunction(nbjit_unbox_float64, Float64, (Ptr{Cvoid},))
    RUNTIME_FUNCTION_POINTERS[:nbjit_register_object] = @cfunction(nbjit_register_object, UInt, (Any,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_get_object] = @cfunction(nbjit_get_object, Ptr{Cvoid}, (UInt,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_unregister_object] = @cfunction(nbjit_unregister_object, Cvoid, (UInt,))

    return RUNTIME_FUNCTION_POINTERS
end

# Auto-register on module load
const RUNTIME_PTRS = register_runtime_functions()

export register_runtime_functions, RUNTIME_FUNCTION_POINTERS
