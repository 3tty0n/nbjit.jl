"""
JIT Runtime Support for Julia Objects
"""

# Active committed notebook-level variable bindings.
# Imported/library calls should always observe this committed snapshot.
const ACTIVE_GLOBAL_BINDINGS = Ref{Dict{Symbol, Any}}(Dict{Symbol, Any}())

# Per-cell staging bindings used during transactional execution.
const STAGING_GLOBAL_BINDINGS = Ref{Union{Nothing, Dict{Symbol, Any}}}(nothing)
const GLOBAL_BINDINGS_IN_TRANSACTION = Ref(false)

"""
Switch the active notebook variable table used by cross-cell reads/writes.
"""
function nbjit_set_global_bindings!(bindings::Dict{Symbol, Any})::Cvoid
    ACTIVE_GLOBAL_BINDINGS[] = bindings
    return nothing
end

"""
Begin a transactional global-binding update.
Reads continue to observe committed bindings while writes are staged.
"""
function nbjit_begin_global_transaction!(bindings::Dict{Symbol, Any})::Cvoid
    ACTIVE_GLOBAL_BINDINGS[] = bindings
    STAGING_GLOBAL_BINDINGS[] = copy(bindings)
    GLOBAL_BINDINGS_IN_TRANSACTION[] = true
    return nothing
end

"""
Commit staged global-binding writes into the committed bindings.
"""
function nbjit_commit_global_transaction!()::Cvoid
    if !GLOBAL_BINDINGS_IN_TRANSACTION[]
        return nothing
    end
    committed = ACTIVE_GLOBAL_BINDINGS[]
    staged = STAGING_GLOBAL_BINDINGS[]
    if staged !== nothing
        empty!(committed)
        merge!(committed, staged)
    end
    STAGING_GLOBAL_BINDINGS[] = nothing
    GLOBAL_BINDINGS_IN_TRANSACTION[] = false
    return nothing
end

"""
Rollback staged global-binding writes.
"""
function nbjit_rollback_global_transaction!()::Cvoid
    STAGING_GLOBAL_BINDINGS[] = nothing
    GLOBAL_BINDINGS_IN_TRANSACTION[] = false
    return nothing
end

"""
Clear the active notebook variable table.
"""
function nbjit_clear_global_bindings!()::Cvoid
    empty!(ACTIVE_GLOBAL_BINDINGS[])
    STAGING_GLOBAL_BINDINGS[] = nothing
    GLOBAL_BINDINGS_IN_TRANSACTION[] = false
    return nothing
end

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
Get a notebook-global variable by name.
Returns boxed pointer for primitive values and object pointer for heap objects.
Throws if the variable is undefined.
"""
function nbjit_global_get(name_ptr::Ptr{UInt8})::Ptr{Nothing}
    name = Symbol(unsafe_string(name_ptr))
    bindings = ACTIVE_GLOBAL_BINDINGS[]
    if !haskey(bindings, name)
        error("Undefined notebook variable: $name")
    end

    value = bindings[name]
    if value isa Int64
        return nbjit_box_int64(value)
    elseif value isa Float64
        return nbjit_box_float64(value)
    elseif value isa Bool
        return nbjit_box_int64(value ? 1 : 0)
    elseif value === nothing
        return Ptr{Nothing}(0)
    else
        id = nbjit_register_object(value)
        return nbjit_get_object(id)
    end
end

"""
Set a notebook-global variable to Int64.
"""
function nbjit_global_set_int64(name_ptr::Ptr{UInt8}, value::Int64)::Cvoid
    name = Symbol(unsafe_string(name_ptr))
    target = GLOBAL_BINDINGS_IN_TRANSACTION[] ? STAGING_GLOBAL_BINDINGS[] : ACTIVE_GLOBAL_BINDINGS[]
    target[name] = value
    return nothing
end

"""
Set a notebook-global variable to Float64.
"""
function nbjit_global_set_float64(name_ptr::Ptr{UInt8}, value::Float64)::Cvoid
    name = Symbol(unsafe_string(name_ptr))
    target = GLOBAL_BINDINGS_IN_TRANSACTION[] ? STAGING_GLOBAL_BINDINGS[] : ACTIVE_GLOBAL_BINDINGS[]
    target[name] = value
    return nothing
end

"""
Set a notebook-global variable to an object pointer.
"""
function nbjit_global_set_object(name_ptr::Ptr{UInt8}, value_ptr::Ptr{Nothing})::Cvoid
    name = Symbol(unsafe_string(name_ptr))
    target = GLOBAL_BINDINGS_IN_TRANSACTION[] ? STAGING_GLOBAL_BINDINGS[] : ACTIVE_GLOBAL_BINDINGS[]
    if value_ptr == C_NULL
        target[name] = nothing
        return nothing
    end

    value_obj = unsafe_pointer_to_objref(value_ptr)
    value = value_obj isa Base.RefValue ? value_obj[] : value_obj
    target[name] = value
    return nothing
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
    if obj isa Base.RefValue
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
    if obj isa Base.RefValue
        return Float64(obj[])
    else
        return Float64(obj)
    end
end

"""
Create a new empty Vector{Float64} with given size (initialized to zeros)
"""
function nbjit_array_new_float64(n::Int64)::Ptr{Nothing}
    arr = Vector{Float64}(undef, n)
    fill!(arr, 0.0)
    id = nbjit_register_object(arr)
    return nbjit_get_object(id)
end

"""
Create a new empty Vector{Int64} with given size (initialized to zeros)
"""
function nbjit_array_new_int64(n::Int64)::Ptr{Nothing}
    arr = Vector{Int64}(undef, n)
    fill!(arr, 0)
    id = nbjit_register_object(arr)
    return nbjit_get_object(id)
end

"""
Get element from array (1-based indexing)
"""
function nbjit_array_getindex_float64(arr_ptr::Ptr{Nothing}, idx::Int64)::Float64
    arr = unsafe_pointer_to_objref(arr_ptr)
    return Float64(arr[idx])
end

function nbjit_array_getindex_int64(arr_ptr::Ptr{Nothing}, idx::Int64)::Int64
    arr = unsafe_pointer_to_objref(arr_ptr)
    return Int64(arr[idx])
end

"""
Set element in array (1-based indexing)
"""
function nbjit_array_setindex_float64(arr_ptr::Ptr{Nothing}, val::Float64, idx::Int64)::Cvoid
    arr = unsafe_pointer_to_objref(arr_ptr)
    arr[idx] = val
    return nothing
end

function nbjit_array_setindex_int64(arr_ptr::Ptr{Nothing}, val::Int64, idx::Int64)::Cvoid
    arr = unsafe_pointer_to_objref(arr_ptr)
    arr[idx] = val
    return nothing
end

"""
Get length of array
"""
function nbjit_array_length(arr_ptr::Ptr{Nothing})::Int64
    arr = unsafe_pointer_to_objref(arr_ptr)
    return Int64(length(arr))
end

"""
Push element to array
"""
function nbjit_array_push_float64(arr_ptr::Ptr{Nothing}, val::Float64)::Ptr{Nothing}
    arr = unsafe_pointer_to_objref(arr_ptr)
    push!(arr, val)
    return arr_ptr
end

function nbjit_array_push_int64(arr_ptr::Ptr{Nothing}, val::Int64)::Ptr{Nothing}
    arr = unsafe_pointer_to_objref(arr_ptr)
    push!(arr, val)
    return arr_ptr
end

"""
Create array from literal values (Float64)
"""
function nbjit_array_from_values_float64(n::Int64, vals_ptr::Ptr{Float64})::Ptr{Nothing}
    arr = Vector{Float64}(undef, n)
    for i in 1:n
        arr[i] = unsafe_load(vals_ptr, i)
    end
    id = nbjit_register_object(arr)
    return nbjit_get_object(id)
end

"""
Create array from literal values (Int64)
"""
function nbjit_array_from_values_int64(n::Int64, vals_ptr::Ptr{Int64})::Ptr{Nothing}
    arr = Vector{Int64}(undef, n)
    for i in 1:n
        arr[i] = unsafe_load(vals_ptr, i)
    end
    id = nbjit_register_object(arr)
    return nbjit_get_object(id)
end

"""
Create zeros(n) -> Vector{Float64}
"""
function nbjit_zeros(n::Int64)::Ptr{Nothing}
    arr = zeros(Float64, n)
    id = nbjit_register_object(arr)
    return nbjit_get_object(id)
end

"""
Create ones(n) -> Vector{Float64}
"""
function nbjit_ones(n::Int64)::Ptr{Nothing}
    arr = ones(Float64, n)
    id = nbjit_register_object(arr)
    return nbjit_get_object(id)
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
    :nbjit_global_get,
    :nbjit_global_set_int64,
    :nbjit_global_set_float64,
    :nbjit_global_set_object,
    :nbjit_box_int64,
    :nbjit_box_float64,
    :nbjit_unbox_int64,
    :nbjit_unbox_float64,
    :nbjit_set_global_bindings!,
    :nbjit_begin_global_transaction!,
    :nbjit_commit_global_transaction!,
    :nbjit_rollback_global_transaction!,
    :nbjit_clear_global_bindings!,
    :nbjit_register_object,
    :nbjit_get_object,
    :nbjit_unregister_object,
    :nbjit_array_new_float64,
    :nbjit_array_new_int64,
    :nbjit_array_getindex_float64,
    :nbjit_array_getindex_int64,
    :nbjit_array_setindex_float64,
    :nbjit_array_setindex_int64,
    :nbjit_array_length,
    :nbjit_array_push_float64,
    :nbjit_array_push_int64,
    :nbjit_zeros,
    :nbjit_ones,
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
    RUNTIME_FUNCTION_POINTERS[:nbjit_global_get] = @cfunction(nbjit_global_get, Ptr{Cvoid}, (Ptr{UInt8},))
    RUNTIME_FUNCTION_POINTERS[:nbjit_global_set_int64] = @cfunction(nbjit_global_set_int64, Cvoid, (Ptr{UInt8}, Int64))
    RUNTIME_FUNCTION_POINTERS[:nbjit_global_set_float64] = @cfunction(nbjit_global_set_float64, Cvoid, (Ptr{UInt8}, Float64))
    RUNTIME_FUNCTION_POINTERS[:nbjit_global_set_object] = @cfunction(nbjit_global_set_object, Cvoid, (Ptr{UInt8}, Ptr{Cvoid}))
    RUNTIME_FUNCTION_POINTERS[:nbjit_box_int64] = @cfunction(nbjit_box_int64, Ptr{Cvoid}, (Int64,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_box_float64] = @cfunction(nbjit_box_float64, Ptr{Cvoid}, (Float64,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_unbox_int64] = @cfunction(nbjit_unbox_int64, Int64, (Ptr{Cvoid},))
    RUNTIME_FUNCTION_POINTERS[:nbjit_unbox_float64] = @cfunction(nbjit_unbox_float64, Float64, (Ptr{Cvoid},))
    RUNTIME_FUNCTION_POINTERS[:nbjit_register_object] = @cfunction(nbjit_register_object, UInt, (Any,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_get_object] = @cfunction(nbjit_get_object, Ptr{Cvoid}, (UInt,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_unregister_object] = @cfunction(nbjit_unregister_object, Cvoid, (UInt,))

    # Array runtime functions
    RUNTIME_FUNCTION_POINTERS[:nbjit_array_new_float64] = @cfunction(nbjit_array_new_float64, Ptr{Cvoid}, (Int64,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_array_new_int64] = @cfunction(nbjit_array_new_int64, Ptr{Cvoid}, (Int64,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_array_getindex_float64] = @cfunction(nbjit_array_getindex_float64, Float64, (Ptr{Cvoid}, Int64))
    RUNTIME_FUNCTION_POINTERS[:nbjit_array_getindex_int64] = @cfunction(nbjit_array_getindex_int64, Int64, (Ptr{Cvoid}, Int64))
    RUNTIME_FUNCTION_POINTERS[:nbjit_array_setindex_float64] = @cfunction(nbjit_array_setindex_float64, Cvoid, (Ptr{Cvoid}, Float64, Int64))
    RUNTIME_FUNCTION_POINTERS[:nbjit_array_setindex_int64] = @cfunction(nbjit_array_setindex_int64, Cvoid, (Ptr{Cvoid}, Int64, Int64))
    RUNTIME_FUNCTION_POINTERS[:nbjit_array_length] = @cfunction(nbjit_array_length, Int64, (Ptr{Cvoid},))
    RUNTIME_FUNCTION_POINTERS[:nbjit_array_push_float64] = @cfunction(nbjit_array_push_float64, Ptr{Cvoid}, (Ptr{Cvoid}, Float64))
    RUNTIME_FUNCTION_POINTERS[:nbjit_array_push_int64] = @cfunction(nbjit_array_push_int64, Ptr{Cvoid}, (Ptr{Cvoid}, Int64))
    RUNTIME_FUNCTION_POINTERS[:nbjit_zeros] = @cfunction(nbjit_zeros, Ptr{Cvoid}, (Int64,))
    RUNTIME_FUNCTION_POINTERS[:nbjit_ones] = @cfunction(nbjit_ones, Ptr{Cvoid}, (Int64,))

    return RUNTIME_FUNCTION_POINTERS
end

# Auto-register on module load
const RUNTIME_PTRS = register_runtime_functions()

export register_runtime_functions, RUNTIME_FUNCTION_POINTERS
