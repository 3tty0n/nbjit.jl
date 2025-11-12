"""
JIT Runtime Support for Julia Objects
"""

"""
Create a new empty Dict{Symbol, Any}
Returns: Ptr{Nothing} pointing to the Dict object
"""
function nbjit_dict_new()::Ptr{Nothing}
    d = Dict{Symbol, Any}()
    # Return pointer to the Dict - Julia's GC will manage it
    return pointer_from_objref(d)
end

"""
Create a Dict with initial key-value pairs
keys: Ptr{Nothing} to Vector of Symbols
values: Ptr{Nothing} to Vector of values
n: number of pairs
"""
function nbjit_dict_new_with_pairs(keys_ptr::Ptr{Nothing}, values_ptr::Ptr{Nothing}, n::Int64)::Ptr{Nothing}
    keys = unsafe_pointer_to_objref(keys_ptr)::Vector{Symbol}
    values = unsafe_pointer_to_objref(values_ptr)::Vector{Any}

    d = Dict{Symbol, Any}()
    for i in 1:n
        d[keys[i]] = values[i]
    end

    return pointer_from_objref(d)
end

"""
Get value from Dict by Symbol key
dict_ptr: Ptr{Nothing} to Dict
key_ptr: Ptr{Nothing} to Symbol
Returns: Ptr{Nothing} to the value
"""
function nbjit_dict_getindex(dict_ptr::Ptr{Nothing}, key_ptr::Ptr{Nothing})::Ptr{Nothing}
    dict = unsafe_pointer_to_objref(dict_ptr)::Dict{Symbol, Any}
    key = unsafe_pointer_to_objref(key_ptr)::Symbol
    value = dict[key]
    return pointer_from_objref(value)
end

"""
Set value in Dict
dict_ptr: Ptr{Nothing} to Dict
key_ptr: Ptr{Nothing} to Symbol
value_ptr: Ptr{Nothing} to the value
"""
function nbjit_dict_setindex!(dict_ptr::Ptr{Nothing}, value_ptr::Ptr{Nothing}, key_ptr::Ptr{Nothing})::Cvoid
    dict = unsafe_pointer_to_objref(dict_ptr)::Dict{Symbol, Any}
    key = unsafe_pointer_to_objref(key_ptr)::Symbol
    value = unsafe_pointer_to_objref(value_ptr)
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
    boxed = val  # Julia will auto-box
    return pointer_from_objref(boxed)
end

"""
Box a Float64 value into a Julia object
"""
function nbjit_box_float64(val::Float64)::Ptr{Nothing}
    boxed = val
    return pointer_from_objref(boxed)
end

"""
Unbox a Julia object to Int64
"""
function nbjit_unbox_int64(obj_ptr::Ptr{Nothing})::Int64
    obj = unsafe_pointer_to_objref(obj_ptr)
    return Int64(obj)
end

"""
Unbox a Julia object to Float64
"""
function nbjit_unbox_float64(obj_ptr::Ptr{Nothing})::Float64
    obj = unsafe_pointer_to_objref(obj_ptr)
    return Float64(obj)
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
