using LLVM
using LLVM.Interop

if !isdefined(@__MODULE__, :CurrentScope)
    include("./jit_scope.jl")
end
if !isdefined(@__MODULE__, :nbjit_dict_new)
    include("./jit_runtime.jl")
end
if !isdefined(@__MODULE__, :GLOBAL_IMPORT_CONTEXT)
    include("./external_calls.jl")
end

FUNC_TBL = Dict()

function get_func_ptr(name, typ)
    key = (name, typ...,)
    if haskey(FUNC_TBL, key)
        return FUNC_TBL[key]
    else
        error("$name is not defined in the function table")
    end
end

function store_func_ptr(name, typ, ptr)
    key = (name, typ...,)
    FUNC_TBL[key]  = ptr
end

mutable struct CodeGen
    builder::LLVM.IRBuilder
    current_scope::CurrentScope
    mod::LLVM.Module
    type_env::Dict{String, LLVM.LLVMType}  # Track variable types
    string_cache::Dict{String, LLVM.Value}  # Cache for string constants
    object_vars::Set{String}  # Track which variables are Julia objects (not primitives)
    import_context::ImportContext  # Track imported modules and functions
    external_bridges::Dict{String, Ptr{Cvoid}}  # Cache external function bridge pointers
    indirect_syms::Set{Symbol}  # Symbols to be called indirectly via global pointers
    external_sigs::Dict{Symbol, Tuple{Int, Symbol}} # Signatures: (n_params, return_type) where return_type is :int64, :float64, or :object
    array_element_types::Dict{String, Symbol}  # Track array element types (:float64 or :int64)
    global_vars::Set{String}  # Variables that should be mirrored to notebook-global bindings
    function_depth::Int  # Nesting level of function codegen (entry function = 1)

    CodeGen() =
        new(
            LLVM.IRBuilder(),
            CurrentScope(),
            LLVM.Module("nbjit"),
            Dict{String, LLVM.LLVMType}(),
            Dict{String, LLVM.Value}(),
            Set{String}(),
            GLOBAL_IMPORT_CONTEXT,
            Dict{String, Ptr{Cvoid}}(),
            Set{Symbol}(),
            Dict{Symbol, Tuple{Int, Symbol}}(),
            Dict{String, Symbol}(),
            Set{String}(),
            0
        )
end

# Helper: Get LLVM type for Julia object pointers (opaque i8*)
julia_object_type() = LLVM.PointerType(LLVM.Int8Type())

"""
Infer parameter types from function body by looking at assignments.
Returns a Dict{Symbol, Symbol} mapping parameter name to type (:primitive or :object)
"""
function infer_parameter_types(func_body::Expr, param_names::Vector{Symbol})::Dict{Symbol, Symbol}
    types = Dict{Symbol, Symbol}()

    # Default: all parameters are primitives (Int64)
    for param in param_names
        types[param] = :primitive
    end

    # Scan the function body for assignments to parameters
    function scan_expr(e)
        if e isa Expr
            if e.head == :(=) && e.args[1] in param_names
                var = e.args[1]
                rhs = e.args[2]

                # Check if RHS is a Dict or Array construction
                if rhs isa Expr && rhs.head == :call && rhs.args[1] == :Dict
                    types[var] = :object
                elseif rhs isa Expr && rhs.head == :call && rhs.args[1] in (:Vector, :zeros, :ones, :fill)
                    types[var] = :object
                elseif rhs isa Expr && rhs.head == :vect
                    types[var] = :object
                elseif rhs isa Float64
                    types[var] = :float64
                end
            elseif e.head == :block
                for arg in e.args
                    scan_expr(arg)
                end
            end
        end
    end

    scan_expr(func_body)
    return types
end

"""
Infer the return type of a function by analyzing the last expression.
Returns :int64, :float64, :object, or :bool.
"""
function infer_return_type(func_body::Expr)::Symbol
    # Track variable types through assignments
    var_types = Dict{Symbol, Symbol}()

    # Scan all assignments to build var_types map
    function scan_assignments(e)
        if e isa Expr
            if e.head == :(=) && e.args[1] isa Symbol
                var = e.args[1]
                rhs = e.args[2]

                # Determine type of RHS
                if rhs isa Expr && rhs.head == :call && rhs.args[1] == :Dict
                    var_types[var] = :object
                elseif rhs isa Expr && rhs.head == :call && rhs.args[1] in (:zeros, :ones)
                    var_types[var] = :array_float64
                elseif rhs isa Expr && rhs.head == :call && rhs.args[1] == :fill
                    fill_val = length(rhs.args) >= 2 ? rhs.args[2] : nothing
                    var_types[var] = fill_val isa Float64 ? :array_float64 : :array_int64
                elseif rhs isa Expr && rhs.head == :call && rhs.args[1] == :Vector
                    var_types[var] = :object
                elseif rhs isa Expr && rhs.head == :vect
                    has_float = any(a -> a isa Float64, rhs.args)
                    var_types[var] = has_float ? :array_float64 : :array_int64
                elseif rhs isa Float64
                    var_types[var] = :float64
                elseif rhs isa Int64
                    var_types[var] = :int64
                elseif rhs isa Expr && rhs.head == :call && rhs.args[1] in (:/, :sqrt, :sin, :cos, :exp, :log)
                    # Division and math functions always return Float64
                    var_types[var] = :float64
                elseif rhs isa Expr && rhs.head == :call && rhs.args[1] in (:+, :-, :*, :%, :^)
                    # Arithmetic: float64 if any operand is float64
                    arg_types = [get_expr_type(a, var_types) for a in rhs.args[2:end]]
                    var_types[var] = any(t -> t == :float64, arg_types) ? :float64 : :int64
                elseif rhs isa Symbol && haskey(var_types, rhs)
                    var_types[var] = var_types[rhs]
                else
                    var_types[var] = :int64
                end
            elseif e.head == :block
                for arg in e.args
                    scan_assignments(arg)
                end
            elseif e.head == :for
                # Scan loop body for assignments
                if length(e.args) >= 2
                    scan_assignments(e.args[2])
                end
            end
        end
    end

    scan_assignments(func_body)

    # Find the last non-LineNumberNode expression
    last_expr = nothing
    if func_body.head == :block
        for i in length(func_body.args):-1:1
            arg = func_body.args[i]
            if !(arg isa LineNumberNode)
                last_expr = arg
                break
            end
        end
    else
        last_expr = func_body
    end

    if last_expr === nothing
        return :int64
    end

    return get_expr_type(last_expr, var_types)
end

"""
Helper to determine the type of an expression given variable type tracking.
Returns :int64, :float64, :object, or :bool.
"""
function get_expr_type(e, var_types::Dict{Symbol, Symbol})::Symbol
    if e isa Float64
        return :float64
    elseif e isa Int64
        return :int64
    elseif e isa Bool
        return :bool
    elseif e isa Symbol
        return get(var_types, e, :int64)
    elseif e isa Expr
        if e.head == :call
            if e.args[1] == :Dict
                return :object
            elseif e.args[1] in (:Vector, :zeros, :ones, :fill)
                return :object
            elseif e.args[1] in (:/, :sqrt, :sin, :cos, :exp, :log)
                return :float64
            elseif e.args[1] in (:<, :>, :<=, :>=, :(==), :(!=))
                return :bool
            elseif e.args[1] in (:+, :-, :*, :%, :^)
                arg_types = [get_expr_type(a, var_types) for a in e.args[2:end]]
                return any(t -> t == :float64, arg_types) ? :float64 : :int64
            elseif e.args[1] == :length
                return :int64
            end
        elseif e.head == :(=)
            return get_expr_type(e.args[2], var_types)
        elseif e.head == :ref
            # Array/dict indexing: check the container type
            if length(e.args) >= 1 && e.args[1] isa Symbol
                container_type = get(var_types, e.args[1], :int64)
                # If the container is an array with known element type, return that
                if container_type == :array_float64
                    return :float64
                elseif container_type == :array_int64
                    return :int64
                end
            end
            return :int64
        elseif e.head == :vect
            return :object
        end
    end
    return :int64
end

current_scope(cg::CodeGen) = cg.current_scope
function new_scope(f, cg::CodeGen)
    open_scope!(current_scope(cg))
    result = f()
    pop!(current_scope(cg))
    return result
end
Base.show(io::IO, cg::CodeGen) = print(io, "CodeGen")

function codegen(cg::CodeGen, expr::Int64)
    return LLVM.ConstantInt(LLVM.IntType(64), expr)
end

function codegen(cg::CodeGen, expr::Float64)
    return LLVM.ConstantFP(LLVM.DoubleType(), expr)
end

function codegen(cg::CodeGen, expr::Bool)
    return LLVM.ConstantInt(LLVM.Int1Type(), expr ? 1 : 0)
end

function codegen(cg::CodeGen, expr::QuoteNode)
    # Convert QuoteNode to Symbol using runtime helper
    # Get the symbol name as a string
    sym_name = String(expr.value)

    # Create C string for the symbol name
    str_ptr = codegen_cstring(cg, sym_name; add_newline=false)

    # Call runtime helper to create Symbol
    symbol_func = declare_symbol_from_cstr(cg)
    ft = LLVM.function_type(symbol_func)
    sym_ptr = LLVM.call!(cg.builder, ft, symbol_func, [str_ptr], "symbol")

    return sym_ptr
end

function ensure_int64(cg::CodeGen, val::LLVM.Value)
    val_type = LLVM.value_type(val)
    if val_type == LLVM.IntType(64)
        return val
    elseif val_type == LLVM.Int1Type()
        return LLVM.zext!(cg.builder, val, LLVM.IntType(64), "bool_to_int64")
    elseif val_type == LLVM.DoubleType()
        return LLVM.fptosi!(cg.builder, val, LLVM.IntType(64), "float_to_int64")
    elseif val_type == julia_object_type()
        # Unbox Julia object to Int64
        unbox_func = declare_unbox_int64(cg)
        ft = LLVM.function_type(unbox_func)
        return LLVM.call!(cg.builder, ft, unbox_func, [val], "unboxed")
    else
        error("Unsupported argument type $(val_type) for external call")
    end
end

"""
Ensure value is a primitive type (Int64 or Double), unboxing if needed.
Returns (value, :int64 or :double)
"""
function ensure_primitive(cg::CodeGen, val::LLVM.Value)
    val_type = LLVM.value_type(val)
    if val_type == LLVM.IntType(64)
        return (val, :int64)
    elseif val_type == LLVM.DoubleType()
        return (val, :double)
    elseif val_type == LLVM.Int1Type()
        return (LLVM.zext!(cg.builder, val, LLVM.IntType(64), "bool_to_int64"), :int64)
    elseif val_type == julia_object_type()
        # Try to unbox to Float64 first (more general), then Int64
        unbox_func = declare_unbox_float64(cg)
        ft = LLVM.function_type(unbox_func)
        return (LLVM.call!(cg.builder, ft, unbox_func, [val], "unboxed_float"), :double)
    else
        error("Cannot use $(val_type) in arithmetic operation")
    end
end

function codegen(cg::CodeGen, expr::Symbol)
    if expr == :nothing
        return
    end

    # Handle special boolean symbols
    if expr == :true
        return LLVM.ConstantInt(LLVM.Int1Type(), 1)
    elseif expr == :false
        return LLVM.ConstantInt(LLVM.Int1Type(), 0)
    end

    V = get(current_scope(cg), string(expr), nothing)
    if V == nothing
        # Fallback to notebook-global bindings for cross-cell variable access.
        var_name_ptr = codegen_cstring(cg, string(expr); add_newline=false)
        global_get = declare_global_get(cg)
        ft = LLVM.function_type(global_get)
        return LLVM.call!(cg.builder, ft, global_get, [var_name_ptr], "global_$(expr)")
    end

    # Get the type from type_env
    var_type = get(cg.type_env, string(expr), LLVM.Int64Type())
    return LLVM.load!(cg.builder, var_type, V, string(expr))
end

function codegen(cg::CodeGen, ::Nothing)
    return
end

function codegen_cstring(cg::CodeGen, str::String; add_newline::Bool=true)
    # Handle string literals by creating global string constants
    cache_key = add_newline ? str * "\n" : str
    if haskey(cg.string_cache, cache_key)
        return cg.string_cache[cache_key]
    end

    # Create a global string constant with null terminator.
    bytes = Vector{UInt8}(cache_key)
    push!(bytes, 0)  # null terminator

    str_type = LLVM.ArrayType(LLVM.Int8Type(), length(bytes))
    str_global = LLVM.GlobalVariable(cg.mod, str_type, "str")
    LLVM.linkage!(str_global, LLVM.API.LLVMPrivateLinkage)

    # Create constant data array from bytes
    str_init = LLVM.ConstantDataArray(bytes)
    LLVM.initializer!(str_global, str_init)

    # Get pointer to string
    zero = LLVM.ConstantInt(LLVM.Int64Type(), 0)
    str_ptr = LLVM.gep!(cg.builder, str_type, str_global, [zero, zero])

    cg.string_cache[cache_key] = str_ptr
    return str_ptr
end

function codegen(cg::CodeGen, str::String)
    # printf-oriented string literal path keeps legacy newline behavior.
    return codegen_cstring(cg, str; add_newline=true)
end

function get_or_declare_printf(cg::CodeGen)
    # Check if printf is already declared
    if haskey(LLVM.functions(cg.mod), "printf")
        return LLVM.functions(cg.mod)["printf"]
    end

    # Declare printf as external function
    # int printf(const char *format, ...)
    i8_ptr = LLVM.PointerType(LLVM.Int8Type())
    printf_type = LLVM.FunctionType(LLVM.Int32Type(), [i8_ptr]; vararg=true)
    printf_func = LLVM.Function(cg.mod, "printf", printf_type)
    LLVM.linkage!(printf_func, LLVM.API.LLVMExternalLinkage)

    return printf_func
end

# Declare runtime helper functions for Dict operations
function get_or_declare_runtime_function(cg::CodeGen, name::String, ret_type::LLVM.LLVMType, arg_types::Vector{LLVM.LLVMType})
    if haskey(LLVM.functions(cg.mod), name)
        return LLVM.functions(cg.mod)[name]
    end

    func_type = LLVM.FunctionType(ret_type, arg_types)
    func = LLVM.Function(cg.mod, name, func_type)
    LLVM.linkage!(func, LLVM.API.LLVMExternalLinkage)

    return func
end

# Specific runtime function declarations
function declare_dict_new(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_dict_new", obj_ptr, LLVM.LLVMType[])
end

function declare_dict_getindex(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_dict_getindex", obj_ptr, LLVM.LLVMType[obj_ptr, obj_ptr])
end

function declare_dict_setindex(cg::CodeGen)
    obj_ptr = julia_object_type()
    # Use C-compatible name without exclamation mark
    return get_or_declare_runtime_function(cg, "nbjit_dict_setindex_bang", LLVM.VoidType(), LLVM.LLVMType[obj_ptr, obj_ptr, obj_ptr])
end

function declare_symbol_from_cstr(cg::CodeGen)
    obj_ptr = julia_object_type()
    i8_ptr = LLVM.PointerType(LLVM.Int8Type())
    return get_or_declare_runtime_function(cg, "nbjit_symbol_from_cstr", obj_ptr, LLVM.LLVMType[i8_ptr])
end

function declare_global_get(cg::CodeGen)
    obj_ptr = julia_object_type()
    i8_ptr = LLVM.PointerType(LLVM.Int8Type())
    return get_or_declare_runtime_function(cg, "nbjit_global_get", obj_ptr, LLVM.LLVMType[i8_ptr])
end

function declare_global_set_int64(cg::CodeGen)
    i8_ptr = LLVM.PointerType(LLVM.Int8Type())
    return get_or_declare_runtime_function(cg, "nbjit_global_set_int64", LLVM.VoidType(), LLVM.LLVMType[i8_ptr, LLVM.Int64Type()])
end

function declare_global_set_float64(cg::CodeGen)
    i8_ptr = LLVM.PointerType(LLVM.Int8Type())
    return get_or_declare_runtime_function(cg, "nbjit_global_set_float64", LLVM.VoidType(), LLVM.LLVMType[i8_ptr, LLVM.DoubleType()])
end

function declare_global_set_object(cg::CodeGen)
    obj_ptr = julia_object_type()
    i8_ptr = LLVM.PointerType(LLVM.Int8Type())
    return get_or_declare_runtime_function(cg, "nbjit_global_set_object", LLVM.VoidType(), LLVM.LLVMType[i8_ptr, obj_ptr])
end

function declare_box_int64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_box_int64", obj_ptr, LLVM.LLVMType[LLVM.Int64Type()])
end

function declare_box_float64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_box_float64", obj_ptr, LLVM.LLVMType[LLVM.DoubleType()])
end

function declare_unbox_int64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_unbox_int64", LLVM.Int64Type(), LLVM.LLVMType[obj_ptr])
end

function declare_unbox_float64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_unbox_float64", LLVM.DoubleType(), LLVM.LLVMType[obj_ptr])
end

# Array runtime function declarations
function declare_array_new_float64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_array_new_float64", obj_ptr, LLVM.LLVMType[LLVM.Int64Type()])
end

function declare_array_new_int64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_array_new_int64", obj_ptr, LLVM.LLVMType[LLVM.Int64Type()])
end

function declare_array_getindex_float64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_array_getindex_float64", LLVM.DoubleType(), LLVM.LLVMType[obj_ptr, LLVM.Int64Type()])
end

function declare_array_getindex_int64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_array_getindex_int64", LLVM.Int64Type(), LLVM.LLVMType[obj_ptr, LLVM.Int64Type()])
end

function declare_array_setindex_float64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_array_setindex_float64", LLVM.VoidType(), LLVM.LLVMType[obj_ptr, LLVM.DoubleType(), LLVM.Int64Type()])
end

function declare_array_setindex_int64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_array_setindex_int64", LLVM.VoidType(), LLVM.LLVMType[obj_ptr, LLVM.Int64Type(), LLVM.Int64Type()])
end

function declare_array_length(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_array_length", LLVM.Int64Type(), LLVM.LLVMType[obj_ptr])
end

function declare_array_push_float64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_array_push_float64", obj_ptr, LLVM.LLVMType[obj_ptr, LLVM.DoubleType()])
end

function declare_array_push_int64(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_array_push_int64", obj_ptr, LLVM.LLVMType[obj_ptr, LLVM.Int64Type()])
end

function declare_zeros(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_zeros", obj_ptr, LLVM.LLVMType[LLVM.Int64Type()])
end

function declare_ones(cg::CodeGen)
    obj_ptr = julia_object_type()
    return get_or_declare_runtime_function(cg, "nbjit_ones", obj_ptr, LLVM.LLVMType[LLVM.Int64Type()])
end

"""
Declare an external module function bridge.
All arguments and return value are julia_object_type (i8*).
"""
function declare_external_bridge(cg::CodeGen, bridge_name::String, n_args::Int)
    obj_ptr = julia_object_type()
    arg_types = LLVM.LLVMType[obj_ptr for _ in 1:n_args]
    return get_or_declare_runtime_function(cg, bridge_name, obj_ptr, arg_types)
end

"""
Declare (or fetch) an external bridge function-pointer global:
  ptr_<bridge_name> :: Ptr{FunctionType(obj_ptr, obj_ptr...)}
"""
function declare_external_bridge_ptr(cg::CodeGen, bridge_name::String, n_args::Int)
    obj_ptr = julia_object_type()
    arg_types = LLVM.LLVMType[obj_ptr for _ in 1:n_args]
    func_type = LLVM.FunctionType(obj_ptr, arg_types)
    ptr_type = LLVM.PointerType(func_type)
    ptr_name = "ptr_" * bridge_name

    gvar = if haskey(LLVM.globals(cg.mod), ptr_name)
        LLVM.globals(cg.mod)[ptr_name]
    else
        gv = LLVM.GlobalVariable(cg.mod, ptr_type, ptr_name)
        LLVM.linkage!(gv, LLVM.API.LLVMExternalLinkage)
        LLVM.initializer!(gv, LLVM.null(ptr_type))
        gv
    end

    return gvar, func_type
end

"""
Check if an expression is a module-qualified call (e.g., Mod.func(args...))
"""
function is_module_call(expr)::Bool
    if expr isa Expr && expr.head == :call
        callee = expr.args[1]
        return callee isa Expr && callee.head == :.
    end
    return false
end

"""
Parse a module-qualified call and return (module_path, func_name, args)
"""
function parse_module_call(expr)::Union{Tuple{Vector{Symbol}, Symbol, Vector{Any}}, Nothing}
    if !is_module_call(expr)
        return nothing
    end

    callee = expr.args[1]
    args = expr.args[2:end]

    # Parse the module path and function name from the callee (X.Y.func)
    path = Symbol[]
    current = callee

    while current isa Expr && current.head == :.
        if length(current.args) >= 2
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
        return (module_path, func_name, args)
    end

    return nothing
end

"""
Generate code for a module-qualified function call (e.g., LinearAlgebra.norm(x))
"""
function codegen_module_call(cg::CodeGen, expr::Expr)
    parsed = parse_module_call(expr)
    if parsed === nothing
        error("Invalid module-qualified call: $expr")
    end

    module_path, func_name, julia_args = parsed
    n_args = length(julia_args)

    # Setup the external call bridge. Prefer the already-loaded module from
    # import context to avoid relying on global module resolution.
    bridge_name = if length(module_path) == 1 && haskey(cg.import_context.modules, module_path[1])
        setup_external_call_for_module(cg.import_context.modules[module_path[1]], func_name, n_args)
    else
        setup_external_call(module_path, func_name, n_args)
    end

    # Compile arguments
    arg_vals = LLVM.Value[]
    for arg in julia_args
        val = codegen(cg, arg)
        # Box the argument if it's a primitive type
        val_type = LLVM.value_type(val)
        if val_type == LLVM.IntType(64)
            box_func = declare_box_int64(cg)
            box_ft = LLVM.function_type(box_func)
            val = LLVM.call!(cg.builder, box_ft, box_func, [val], "boxed_arg")
        elseif val_type == LLVM.DoubleType()
            box_func = declare_box_float64(cg)
            box_ft = LLVM.function_type(box_func)
            val = LLVM.call!(cg.builder, box_ft, box_func, [val], "boxed_arg")
        elseif val_type == LLVM.Int1Type()
            # Convert bool to int64 first, then box
            int_val = LLVM.zext!(cg.builder, val, LLVM.IntType(64), "bool_to_int")
            box_func = declare_box_int64(cg)
            box_ft = LLVM.function_type(box_func)
            val = LLVM.call!(cg.builder, box_ft, box_func, [int_val], "boxed_arg")
        end
        # If already julia_object_type, no boxing needed
        push!(arg_vals, val)
    end

    # Call external bridge through pointer global to avoid unresolved-symbol
    # failures during dlopen of compiled cells.
    bridge_ptr_gvar, bridge_ft = declare_external_bridge_ptr(cg, bridge_name, n_args)
    bridge_ptr = LLVM.load!(cg.builder, LLVM.value_type(bridge_ptr_gvar), bridge_ptr_gvar, "ext_bridge_ptr")
    result = LLVM.call!(cg.builder, bridge_ft, bridge_ptr, arg_vals, "ext_call_result")

    return result
end

function codegen(cg::CodeGen, expr::Expr)
    if expr.head == :(=) && isa(expr.args[1], Symbol)
        local initval
        local V
        var = string(expr.args[1])

        # Track array element types before codegen
        rhs = expr.args[2]
        if rhs isa Expr
            if rhs.head == :vect
                # Literal array - check element types
                has_float = any(a -> a isa Float64, rhs.args)
                cg.array_element_types[var] = has_float ? :float64 : :int64
            elseif rhs.head == :call
                callee = rhs.args[1]
                if callee == :zeros || callee == :ones
                    cg.array_element_types[var] = :float64
                elseif callee == :fill
                    fill_val = length(rhs.args) >= 2 ? rhs.args[2] : nothing
                    cg.array_element_types[var] = fill_val isa Float64 ? :float64 : :int64
                elseif callee isa Expr && callee.head == :curly && callee.args[1] == :Vector
                    type_arg = callee.args[2]
                    cg.array_element_types[var] = (type_arg == :Float64 || type_arg == :Float) ? :float64 : :int64
                end
            end
        end

        initval = codegen(cg, expr.args[2])

        # Determine type from the initializer
        llvm_type = LLVM.value_type(initval)

        # Auto-extend Int1 (bool) to Int64 for easier arithmetic
        if llvm_type == LLVM.Int1Type()
            initval = LLVM.zext!(cg.builder, initval, LLVM.IntType(64), "bool_to_int")
            llvm_type = LLVM.IntType(64)
        end

        cg.type_env[var] = llvm_type

        if isglobalscope(current_scope(cg))
            V = LLVM.GlobalVariable(cg.mod, llvm_type, var)
            LLVM.initializer!(V, initval)
            current_scope(cg)[var] = V
        else
            # Check if variable already exists in scope (including parent scopes)
            existing = get(current_scope(cg), var, nothing)
            if existing !== nothing
                # Reuse existing allocation - just store the new value
                LLVM.store!(cg.builder, initval, existing)
                # V is already in scope from when it was first created
            else
                # Create new allocation for this variable
                func = LLVM.parent(LLVM.position(cg.builder))
                V = create_entry_block_allocation(cg, func, var, llvm_type)
                LLVM.store!(cg.builder, initval, V)
                current_scope(cg)[var] = V
            end
        end

        # Mirror entry-function assignments into notebook-global bindings so
        # later cells can read them.
        if cg.function_depth == 1
            var_name_ptr = codegen_cstring(cg, var; add_newline=false)
            if llvm_type == LLVM.IntType(64)
                set_i64 = declare_global_set_int64(cg)
                ft = LLVM.function_type(set_i64)
                LLVM.call!(cg.builder, ft, set_i64, [var_name_ptr, initval])
            elseif llvm_type == LLVM.DoubleType()
                set_f64 = declare_global_set_float64(cg)
                ft = LLVM.function_type(set_f64)
                LLVM.call!(cg.builder, ft, set_f64, [var_name_ptr, initval])
            elseif llvm_type == julia_object_type()
                set_obj = declare_global_set_object(cg)
                ft = LLVM.function_type(set_obj)
                LLVM.call!(cg.builder, ft, set_obj, [var_name_ptr, initval])
            elseif llvm_type == LLVM.Int1Type()
                as_i64 = LLVM.zext!(cg.builder, initval, LLVM.IntType(64), "global_bool_to_int")
                set_i64 = declare_global_set_int64(cg)
                ft = LLVM.function_type(set_i64)
                LLVM.call!(cg.builder, ft, set_i64, [var_name_ptr, as_i64])
            end
        end
        return initval
    elseif expr.head == :call
        # Check for module-qualified call first (e.g., Mod.func(x))
        if is_module_call(expr)
            return codegen_module_call(cg, expr)
        elseif expr.args[1] == :+
            operands = expr.args[2:end]
            @assert !isempty(operands) ":+ requires at least one operand"
            acc_raw = codegen(cg, operands[1])
            acc, acc_type = ensure_primitive(cg, acc_raw)
            for operand in operands[2:end]
                next_raw = codegen(cg, operand)
                next, next_type = ensure_primitive(cg, next_raw)
                if acc_type == :double || next_type == :double
                    if acc_type != :double
                        acc = LLVM.sitofp!(cg.builder, acc, LLVM.DoubleType(), "add_promote_lhs")
                        acc_type = :double
                    end
                    if next_type != :double
                        next = LLVM.sitofp!(cg.builder, next, LLVM.DoubleType(), "add_promote_rhs")
                    end
                    acc = LLVM.fadd!(cg.builder, acc, next, "addtmp")
                else
                    acc = LLVM.add!(cg.builder, acc, next, "addtmp")
                end
            end
            return acc
        elseif expr.args[1] == :-
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "sub_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "sub_promote_rhs")
                end
                return LLVM.fsub!(cg.builder, L, R, "subtmp")
            else
                return LLVM.sub!(cg.builder, L, R, "subtmp")
            end
        elseif expr.args[1] == :*
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "mult_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "mult_promote_rhs")
                end
                return LLVM.fmul!(cg.builder, L, R, "multmp")
            else
                return LLVM.mul!(cg.builder, L, R, "multmp")
            end
        elseif expr.args[1] == :/
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "div_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "div_promote_rhs")
                end
                return LLVM.fdiv!(cg.builder, L, R, "divtmp")
            else
                return LLVM.sdiv!(cg.builder, L, R, "divtmp")
            end
        elseif expr.args[1] == :%
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "mod_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "mod_promote_rhs")
                end
                return LLVM.frem!(cg.builder, L, R, "modtmp")
            else
                return LLVM.srem!(cg.builder, L, R, "modtmp")
            end
        elseif expr.args[1] == :<
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "lt_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "lt_promote_rhs")
                end
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOLT, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSLT, L, R, "cmptmp")
            end
        elseif expr.args[1] == :>
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "gt_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "gt_promote_rhs")
                end
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOGT, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSGT, L, R, "cmptmp")
            end
        elseif expr.args[1] == :<=
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "le_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "le_promote_rhs")
                end
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOLE, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSLE, L, R, "cmptmp")
            end
        elseif expr.args[1] == :>=
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "ge_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "ge_promote_rhs")
                end
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOGE, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSGE, L, R, "cmptmp")
            end
        elseif expr.args[1] == :(==)
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "eq_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "eq_promote_rhs")
                end
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOEQ, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntEQ, L, R, "cmptmp")
            end
        elseif expr.args[1] == :(!=)
            lhs = expr.args[2]
            rhs = expr.args[3]
            L_raw = codegen(cg, lhs)
            R_raw = codegen(cg, rhs)
            L, L_type = ensure_primitive(cg, L_raw)
            R, R_type = ensure_primitive(cg, R_raw)
            if L_type == :double || R_type == :double
                if L_type != :double
                    L = LLVM.sitofp!(cg.builder, L, LLVM.DoubleType(), "ne_promote_lhs")
                end
                if R_type != :double
                    R = LLVM.sitofp!(cg.builder, R, LLVM.DoubleType(), "ne_promote_rhs")
                end
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealONE, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntNE, L, R, "cmptmp")
            end
        elseif expr.args[1] == :zeros
            # zeros(n) -> Vector{Float64} of zeros
            n_val = codegen(cg, expr.args[2])
            n_int = ensure_int64(cg, n_val)
            zeros_func = declare_zeros(cg)
            ft = LLVM.function_type(zeros_func)
            arr_ptr = LLVM.call!(cg.builder, ft, zeros_func, [n_int], "zeros_arr")
            return arr_ptr
        elseif expr.args[1] == :ones
            # ones(n) -> Vector{Float64} of ones
            n_val = codegen(cg, expr.args[2])
            n_int = ensure_int64(cg, n_val)
            ones_func = declare_ones(cg)
            ft = LLVM.function_type(ones_func)
            arr_ptr = LLVM.call!(cg.builder, ft, ones_func, [n_int], "ones_arr")
            return arr_ptr
        elseif expr.args[1] == :length
            # length(arr)
            arr_val = codegen(cg, expr.args[2])
            len_func = declare_array_length(cg)
            ft = LLVM.function_type(len_func)
            return LLVM.call!(cg.builder, ft, len_func, [arr_val], "arr_len")
        elseif expr.args[1] == :push!
            # push!(arr, val)
            arr_val = codegen(cg, expr.args[2])
            elem_val = codegen(cg, expr.args[3])
            elem_type = LLVM.value_type(elem_val)
            if elem_type == LLVM.DoubleType()
                push_func = declare_array_push_float64(cg)
                ft = LLVM.function_type(push_func)
                return LLVM.call!(cg.builder, ft, push_func, [arr_val, elem_val], "push_result")
            else
                int_val = ensure_int64(cg, elem_val)
                push_func = declare_array_push_int64(cg)
                ft = LLVM.function_type(push_func)
                return LLVM.call!(cg.builder, ft, push_func, [arr_val, int_val], "push_result")
            end
        elseif expr.args[1] == :Vector || (expr.args[1] isa Expr && expr.args[1].head == :curly && expr.args[1].args[1] == :Vector)
            # Vector{T}(undef, n) or similar - create new array
            # For simplicity, support Vector(n) as creating a zero-initialized array
            if length(expr.args) >= 2
                n_val = codegen(cg, expr.args[end])
                n_int = ensure_int64(cg, n_val)
                # Check if type is specified
                elem_type = :float64  # default
                if expr.args[1] isa Expr && expr.args[1].head == :curly
                    type_arg = expr.args[1].args[2]
                    if type_arg == :Int64 || type_arg == :Int
                        elem_type = :int64
                    end
                end
                if elem_type == :int64
                    new_func = declare_array_new_int64(cg)
                else
                    new_func = declare_array_new_float64(cg)
                end
                ft = LLVM.function_type(new_func)
                return LLVM.call!(cg.builder, ft, new_func, [n_int], "new_arr")
            end
            error("Unsupported Vector construction: $expr")
        elseif expr.args[1] == :fill
            # fill(val, n) - create array filled with val
            fill_val = codegen(cg, expr.args[2])
            n_val = codegen(cg, expr.args[3])
            n_int = ensure_int64(cg, n_val)
            fill_type = LLVM.value_type(fill_val)
            if fill_type == LLVM.DoubleType()
                new_func = declare_array_new_float64(cg)
                ft = LLVM.function_type(new_func)
                arr_ptr = LLVM.call!(cg.builder, ft, new_func, [n_int], "fill_arr")
                # Fill with values using a loop
                set_func = declare_array_setindex_float64(cg)
                set_ft = LLVM.function_type(set_func)
                func = LLVM.parent(LLVM.position(cg.builder))
                fill_cond = LLVM.BasicBlock(func, "fill_cond")
                fill_body = LLVM.BasicBlock(func, "fill_body")
                fill_inc = LLVM.BasicBlock(func, "fill_inc")
                fill_end = LLVM.BasicBlock(func, "fill_end")
                idx_alloc = create_entry_block_allocation(cg, func, "_fill_idx", LLVM.Int64Type())
                one = LLVM.ConstantInt(LLVM.Int64Type(), 1)
                LLVM.store!(cg.builder, one, idx_alloc)
                LLVM.br!(cg.builder, fill_cond)
                LLVM.position!(cg.builder, fill_cond)
                idx_val = LLVM.load!(cg.builder, LLVM.Int64Type(), idx_alloc, "_fill_idx")
                cond = LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSLE, idx_val, n_int, "fill_cond")
                LLVM.br!(cg.builder, cond, fill_body, fill_end)
                LLVM.position!(cg.builder, fill_body)
                LLVM.call!(cg.builder, set_ft, set_func, [arr_ptr, fill_val, idx_val])
                LLVM.br!(cg.builder, fill_inc)
                LLVM.position!(cg.builder, fill_inc)
                next_idx = LLVM.add!(cg.builder, idx_val, one, "next_fill_idx")
                LLVM.store!(cg.builder, next_idx, idx_alloc)
                LLVM.br!(cg.builder, fill_cond)
                LLVM.position!(cg.builder, fill_end)
                return arr_ptr
            else
                int_val = ensure_int64(cg, fill_val)
                new_func = declare_array_new_int64(cg)
                ft = LLVM.function_type(new_func)
                arr_ptr = LLVM.call!(cg.builder, ft, new_func, [n_int], "fill_arr")
                set_func = declare_array_setindex_int64(cg)
                set_ft = LLVM.function_type(set_func)
                func = LLVM.parent(LLVM.position(cg.builder))
                fill_cond = LLVM.BasicBlock(func, "fill_cond")
                fill_body = LLVM.BasicBlock(func, "fill_body")
                fill_inc = LLVM.BasicBlock(func, "fill_inc")
                fill_end = LLVM.BasicBlock(func, "fill_end")
                idx_alloc = create_entry_block_allocation(cg, func, "_fill_idx", LLVM.Int64Type())
                one = LLVM.ConstantInt(LLVM.Int64Type(), 1)
                LLVM.store!(cg.builder, one, idx_alloc)
                LLVM.br!(cg.builder, fill_cond)
                LLVM.position!(cg.builder, fill_cond)
                idx_val = LLVM.load!(cg.builder, LLVM.Int64Type(), idx_alloc, "_fill_idx")
                cond = LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSLE, idx_val, n_int, "fill_cond")
                LLVM.br!(cg.builder, cond, fill_body, fill_end)
                LLVM.position!(cg.builder, fill_body)
                LLVM.call!(cg.builder, set_ft, set_func, [arr_ptr, int_val, idx_val])
                LLVM.br!(cg.builder, fill_inc)
                LLVM.position!(cg.builder, fill_inc)
                next_idx = LLVM.add!(cg.builder, idx_val, one, "next_fill_idx")
                LLVM.store!(cg.builder, next_idx, idx_alloc)
                LLVM.br!(cg.builder, fill_cond)
                LLVM.position!(cg.builder, fill_end)
                return arr_ptr
            end
        elseif expr.args[1] == :println
            # Handle println specially
            printf_func = get_or_declare_printf(cg)
            printf_type = LLVM.function_type(printf_func)

            if length(expr.args) == 1
                # println() with no arguments - just print newline
                format_str = codegen(cg, "")
                LLVM.call!(cg.builder, printf_type, printf_func, [format_str])
            else
                # println with arguments
                for arg in expr.args[2:end]
                    arg_val = codegen(cg, arg)

                    if arg isa String
                        # Already has newline from codegen(cg, str)
                        LLVM.call!(cg.builder, printf_type, printf_func, [arg_val])
                    elseif LLVM.value_type(arg_val) == LLVM.Int64Type()
                        format_str = codegen(cg, "%ld")
                        LLVM.call!(cg.builder, printf_type, printf_func, [format_str, arg_val])
                    elseif LLVM.value_type(arg_val) == LLVM.DoubleType()
                        format_str = codegen(cg, "%f")
                        LLVM.call!(cg.builder, printf_type, printf_func, [format_str, arg_val])
                    elseif LLVM.value_type(arg_val) == LLVM.Int1Type()
                        # Convert bool to int64 for printing
                        int_val = LLVM.zext!(cg.builder, arg_val, LLVM.Int64Type(), "bool_to_int")
                        format_str = codegen(cg, "%ld")
                        LLVM.call!(cg.builder, printf_type, printf_func, [format_str, int_val])
                    end
                end
            end
            return LLVM.ConstantInt(LLVM.Int64Type(), 0)
        elseif expr.args[1] == :Dict
            # Dict construction: Dict(:key1 => val1, :key2 => val2, ...)
            # For now, support only empty Dict or Pair syntax
            dict_func = declare_dict_new(cg)
            ft = LLVM.function_type(dict_func)
            dict_ptr = LLVM.call!(cg.builder, ft, dict_func, LLVM.Value[], "dict")

            # If there are => pairs, add them
            for arg in expr.args[2:end]
                if arg isa Expr && arg.head == :call && arg.args[1] == :(=>)
                    key = codegen(cg, arg.args[2])
                    value = codegen(cg, arg.args[3])

                    # Box key if it's a primitive
                    key_type = LLVM.value_type(key)
                    if key_type == LLVM.Int64Type()
                        box_func = declare_box_int64(cg)
                        box_ft = LLVM.function_type(box_func)
                        key = LLVM.call!(cg.builder, box_ft, box_func, [key], "boxed")
                    elseif key_type == LLVM.DoubleType()
                        box_func = declare_box_float64(cg)
                        box_ft = LLVM.function_type(box_func)
                        key = LLVM.call!(cg.builder, box_ft, box_func, [key], "boxed")
                    end

                    # Box value if it's a primitive
                    value_type = LLVM.value_type(value)
                    if value_type == LLVM.Int64Type()
                        box_func = declare_box_int64(cg)
                        box_ft = LLVM.function_type(box_func)
                        value = LLVM.call!(cg.builder, box_ft, box_func, [value], "boxed")
                    elseif value_type == LLVM.DoubleType()
                        box_func = declare_box_float64(cg)
                        box_ft = LLVM.function_type(box_func)
                        value = LLVM.call!(cg.builder, box_ft, box_func, [value], "boxed")
                    end

                    # Call setindex!
                    setindex_func = declare_dict_setindex(cg)
                    setindex_ft = LLVM.function_type(setindex_func)
                    LLVM.call!(cg.builder, setindex_ft, setindex_func, [dict_ptr, value, key])
                end
            end

            return dict_ptr
        elseif expr.args[1] == :setindex!
            # setindex!(container, value, key/index)
            container = codegen(cg, expr.args[2])
            value = codegen(cg, expr.args[3])
            key = codegen(cg, expr.args[4])

            # Check if this is an array setindex by looking at the container variable name
            container_name = expr.args[2] isa Symbol ? string(expr.args[2]) : ""
            is_array = haskey(cg.array_element_types, container_name)

            if is_array
                # Array setindex!
                idx_int = ensure_int64(cg, key)
                elem_type = cg.array_element_types[container_name]
                if elem_type == :float64
                    fval = if LLVM.value_type(value) != LLVM.DoubleType()
                        LLVM.sitofp!(cg.builder, ensure_int64(cg, value), LLVM.DoubleType(), "to_float")
                    else
                        value
                    end
                    set_func = declare_array_setindex_float64(cg)
                    ft = LLVM.function_type(set_func)
                    LLVM.call!(cg.builder, ft, set_func, [container, fval, idx_int])
                else
                    ival = ensure_int64(cg, value)
                    set_func = declare_array_setindex_int64(cg)
                    ft = LLVM.function_type(set_func)
                    LLVM.call!(cg.builder, ft, set_func, [container, ival, idx_int])
                end
                return container
            else
                # Dict setindex! (original behavior)
                # Box key if it's a primitive
                key_type = LLVM.value_type(key)
                if key_type == LLVM.Int64Type()
                    box_func = declare_box_int64(cg)
                    box_ft = LLVM.function_type(box_func)
                    key = LLVM.call!(cg.builder, box_ft, box_func, [key], "boxed")
                elseif key_type == LLVM.DoubleType()
                    box_func = declare_box_float64(cg)
                    box_ft = LLVM.function_type(box_func)
                    key = LLVM.call!(cg.builder, box_ft, box_func, [key], "boxed")
                end

                # Box value if it's a primitive
                value_type = LLVM.value_type(value)
                if value_type == LLVM.Int64Type()
                    box_func = declare_box_int64(cg)
                    box_ft = LLVM.function_type(box_func)
                    value = LLVM.call!(cg.builder, box_ft, box_func, [value], "boxed")
                elseif value_type == LLVM.DoubleType()
                    box_func = declare_box_float64(cg)
                    box_ft = LLVM.function_type(box_func)
                    value = LLVM.call!(cg.builder, box_ft, box_func, [value], "boxed")
                end

                setindex_func = declare_dict_setindex(cg)
                ft = LLVM.function_type(setindex_func)
                LLVM.call!(cg.builder, ft, setindex_func, [container, value, key])
                return container
            end
        elseif expr.args[1] isa Symbol
            callee = expr.args[1]
            julia_args = expr.args[2:end]
            arg_vals = LLVM.Value[]
            for v in julia_args
                push!(arg_vals, codegen(cg, v))
            end

            func_name = string(callee)

            # Check if this is an indirect call
            if callee in cg.indirect_syms
                ptr_name = "ptr_" * func_name
                if haskey(LLVM.globals(cg.mod), ptr_name)
                    gvar = LLVM.globals(cg.mod)[ptr_name]
                    # Load the function pointer
                    func_ptr = LLVM.load!(cg.builder, LLVM.value_type(gvar), gvar, "func_ptr")
                    
                    # Reconstruct function type from external_sigs
                    if haskey(cg.external_sigs, callee)
                        (n_params, ret_type_sym) = cg.external_sigs[callee]
                        param_types = fill(LLVM.Int64Type(), n_params)
                        ret_type = if ret_type_sym == :object
                            julia_object_type()
                        elseif ret_type_sym == :float64
                            LLVM.DoubleType()
                        else
                            LLVM.Int64Type()
                        end
                        func_type = LLVM.FunctionType(ret_type, param_types)
                        converted_args = LLVM.Value[]
                        for (i, val) in enumerate(arg_vals)
                            expected_type = param_types[i]
                            if expected_type == LLVM.IntType(64)
                                push!(converted_args, ensure_int64(cg, val))
                            elseif expected_type == LLVM.DoubleType()
                                v = LLVM.value_type(val) == LLVM.DoubleType() ? val :
                                    LLVM.sitofp!(cg.builder, ensure_int64(cg, val), LLVM.DoubleType(), "indirect_to_float")
                                push!(converted_args, v)
                            else
                                push!(converted_args, val)
                            end
                        end
                        return LLVM.call!(cg.builder, func_type, func_ptr, converted_args, "indirect_call")
                    else
                        error("Missing signature for indirect call: $callee")
                    end
                else
                    error("Indirect function pointer $ptr_name not found")
                end
            # Check if function already exists in module
            elseif haskey(LLVM.functions(cg.mod), func_name)
                func = LLVM.functions(cg.mod)[func_name]
                if length(LLVM.parameters(func)) != length(arg_vals)
                    error("number of parameters mismatch for $(callee)")
                end

                # Get expected parameter types from function signature
                ft = LLVM.function_type(func)
                param_types = LLVM.parameters(ft)

                # Convert arguments to match function signature
                args = LLVM.Value[]
                for (i, val) in enumerate(arg_vals)
                    expected_type = param_types[i]
                    val_type = LLVM.value_type(val)

                    if expected_type == val_type
                        push!(args, val)
                    elseif expected_type == LLVM.IntType(64)
                        push!(args, ensure_int64(cg, val))
                    else
                        # For now, assume no conversion needed for other types
                        push!(args, val)
                    end
                end

                return LLVM.call!(cg.builder, ft, func, args, "calltmp")
            else
                # Function not yet defined - create forward declaration
                # Convert all args to Int64 for now (this is a limitation)
                args = LLVM.Value[]
                for val in arg_vals
                    push!(args, ensure_int64(cg, val))
                end

                arg_types = fill(LLVM.IntType(64), length(args))
                func_type = LLVM.FunctionType(LLVM.IntType(64), arg_types)
                func = LLVM.Function(cg.mod, func_name, func_type)
                LLVM.linkage!(func, LLVM.API.LLVMExternalLinkage)

                ft = LLVM.function_type(func)
                return LLVM.call!(cg.builder, ft, func, args, "calltmp")
            end
        else
            error("unreachable path", expr)
        end
    elseif expr.head == :function
        cg.function_depth += 1
        try
            signature = expr.args[1]
            func_name = string(signature.args[1])

        # Extract parameter symbols (filter out non-Symbol elements like type annotations)
        param_symbols = Symbol[]
        for i in 2:length(signature.args)
            arg = signature.args[i]
            if arg isa Symbol
                push!(param_symbols, arg)
            elseif arg isa Expr && arg.head == :(::)
                # Handle type annotations: x::Int64 -> extract x
                push!(param_symbols, arg.args[1])
            end
        end

        # Infer parameter types from function body
        param_types = infer_parameter_types(expr.args[2], param_symbols)

        # Infer return type from function body
        return_type_sym = infer_return_type(expr.args[2])

        # Create LLVM function with inferred types
        args = LLVM.LLVMType[]
        for param_sym in param_symbols
            if param_types[param_sym] == :object
                push!(args, julia_object_type())
                push!(cg.object_vars, string(param_sym))
            elseif param_types[param_sym] == :float64
                push!(args, LLVM.DoubleType())
            else
                push!(args, LLVM.IntType(64))
            end
        end

        # Set return type based on inference
        return_llvm_type = if return_type_sym == :object
            julia_object_type()
        elseif return_type_sym == :float64
            LLVM.DoubleType()
        else
            LLVM.IntType(64)
        end

        func_type = LLVM.FunctionType(return_llvm_type, args)
        func = LLVM.Function(cg.mod, func_name, func_type)
        LLVM.linkage!(func, LLVM.API.LLVMExternalLinkage)

        for (i, param) in enumerate(LLVM.parameters(func))
            arg = string(signature.args[i+1])
            LLVM.name!(param, arg)
        end

        entry = LLVM.BasicBlock(func, "entry")
        LLVM.position!(cg.builder, entry)

        new_scope(cg) do
            for (i, param) in enumerate(LLVM.parameters(func))
                argname = string(signature.args[i+1])
                alloc = create_entry_block_allocation(cg, func, argname)
                LLVM.store!(cg.builder, param, alloc)
                current_scope(cg)[argname] = alloc
            end
            body = codegen(cg, expr.args[2])

            # Convert return value to match function signature
            if body === nothing
                if return_type_sym == :object
                    ret_val = LLVM.null(julia_object_type())
                elseif return_type_sym == :float64
                    ret_val = LLVM.ConstantFP(LLVM.DoubleType(), 0.0)
                else
                    ret_val = LLVM.ConstantInt(LLVM.IntType(64), 0)
                end
            else
                body_type = LLVM.value_type(body)
                if return_type_sym == :object
                    # Function returns object - body should be a pointer
                    if body_type == julia_object_type()
                        ret_val = body
                    else
                        error("Function declared to return object but body returns $(body_type)")
                    end
                elseif return_type_sym == :float64
                    # Function returns Float64
                    if body_type == LLVM.DoubleType()
                        ret_val = body
                    elseif body_type == LLVM.IntType(64)
                        ret_val = LLVM.sitofp!(cg.builder, body, LLVM.DoubleType(), "int_to_float")
                    elseif body_type == LLVM.Int1Type()
                        int_val = LLVM.zext!(cg.builder, body, LLVM.IntType(64), "bool_to_int")
                        ret_val = LLVM.sitofp!(cg.builder, int_val, LLVM.DoubleType(), "int_to_float")
                    elseif body_type == julia_object_type()
                        unbox_func = declare_unbox_float64(cg)
                        ft = LLVM.function_type(unbox_func)
                        ret_val = LLVM.call!(cg.builder, ft, unbox_func, [body], "unboxed_float")
                    else
                        ret_val = body
                    end
                else
                    # Function returns primitive (Int64)
                    if body_type == LLVM.IntType(64)
                        ret_val = body
                    elseif body_type == LLVM.DoubleType()
                        # Cast float to int
                        ret_val = LLVM.fptosi!(cg.builder, body, LLVM.IntType(64), "fptosi")
                    elseif body_type == LLVM.Int1Type()
                        # Extend bool to int64
                        ret_val = LLVM.zext!(cg.builder, body, LLVM.IntType(64), "zext")
                    elseif body_type == julia_object_type()
                        # Unbox object to int64
                        unbox_func = declare_unbox_int64(cg)
                        ft = LLVM.function_type(unbox_func)
                        ret_val = LLVM.call!(cg.builder, ft, unbox_func, [body], "unboxed")
                    else
                        ret_val = body
                    end
                end
            end
            LLVM.ret!(cg.builder, ret_val)
        end
            return func
        finally
            cg.function_depth -= 1
        end
    elseif expr.head == :return
        rhs = expr.args[1]
        retval = codegen(cg, rhs)
        return retval
    elseif expr.head == :&&
        # Short-circuit AND: if lhs is false, return false, else return rhs
        lhs = codegen(cg, expr.args[1])
        func = LLVM.parent(LLVM.position(cg.builder))
        rhs_block = LLVM.BasicBlock(func, "and_rhs")
        merge_block = LLVM.BasicBlock(func, "and_merge")

        # Check if lhs is true
        zero = LLVM.ConstantInt(LLVM.Int1Type(), 0)
        lhs_bool = LLVM.icmp!(cg.builder, LLVM.API.LLVMIntNE, lhs, zero, "lhs_bool")
        lhs_pos = LLVM.position(cg.builder)
        LLVM.br!(cg.builder, lhs_bool, rhs_block, merge_block)

        # Evaluate rhs
        LLVM.position!(cg.builder, rhs_block)
        rhs = codegen(cg, expr.args[2])
        rhs_pos = LLVM.position(cg.builder)
        LLVM.br!(cg.builder, merge_block)

        # Merge
        LLVM.position!(cg.builder, merge_block)
        phi = LLVM.phi!(cg.builder, LLVM.Int1Type(), "and_result")
        append!(LLVM.incoming(phi), [(zero, lhs_pos), (rhs, rhs_pos)])
        return phi
    elseif expr.head == :||
        # Short-circuit OR: if lhs is true, return true, else return rhs
        lhs = codegen(cg, expr.args[1])
        func = LLVM.parent(LLVM.position(cg.builder))
        rhs_block = LLVM.BasicBlock(func, "or_rhs")
        merge_block = LLVM.BasicBlock(func, "or_merge")

        # Check if lhs is false
        zero = LLVM.ConstantInt(LLVM.Int1Type(), 0)
        one = LLVM.ConstantInt(LLVM.Int1Type(), 1)
        lhs_bool = LLVM.icmp!(cg.builder, LLVM.API.LLVMIntEQ, lhs, zero, "lhs_bool")
        lhs_pos = LLVM.position(cg.builder)
        LLVM.br!(cg.builder, lhs_bool, rhs_block, merge_block)

        # Evaluate rhs
        LLVM.position!(cg.builder, rhs_block)
        rhs = codegen(cg, expr.args[2])
        rhs_pos = LLVM.position(cg.builder)
        LLVM.br!(cg.builder, merge_block)

        # Merge
        LLVM.position!(cg.builder, merge_block)
        phi = LLVM.phi!(cg.builder, LLVM.Int1Type(), "or_result")
        append!(LLVM.incoming(phi), [(one, lhs_pos), (rhs, rhs_pos)])
        return phi
    elseif expr.head == :ref
        # Array or dictionary indexing: arr[i] or dict[:key]
        container = codegen(cg, expr.args[1])
        index = codegen(cg, expr.args[2])

        # Determine if this is an array access by checking the container variable name
        container_name = expr.args[1] isa Symbol ? string(expr.args[1]) : ""
        is_array = haskey(cg.array_element_types, container_name)

        if is_array
            # Array indexing - use typed getindex
            idx_int = ensure_int64(cg, index)
            elem_type = cg.array_element_types[container_name]
            if elem_type == :float64
                get_func = declare_array_getindex_float64(cg)
                ft = LLVM.function_type(get_func)
                return LLVM.call!(cg.builder, ft, get_func, [container, idx_int], "arr_get")
            else
                get_func = declare_array_getindex_int64(cg)
                ft = LLVM.function_type(get_func)
                return LLVM.call!(cg.builder, ft, get_func, [container, idx_int], "arr_get")
            end
        elseif container_name != "" && container_name in cg.object_vars
            # Could be an array we don't have element type info for - default to dict
            # Box index if it's a primitive
            index_type = LLVM.value_type(index)
            if index_type == LLVM.Int64Type()
                box_func = declare_box_int64(cg)
                box_ft = LLVM.function_type(box_func)
                index = LLVM.call!(cg.builder, box_ft, box_func, [index], "boxed")
            elseif index_type == LLVM.DoubleType()
                box_func = declare_box_float64(cg)
                box_ft = LLVM.function_type(box_func)
                index = LLVM.call!(cg.builder, box_ft, box_func, [index], "boxed")
            end
            getindex_func = declare_dict_getindex(cg)
            ft = LLVM.function_type(getindex_func)
            return LLVM.call!(cg.builder, ft, getindex_func, [container, index], "getindex")
        else
            # Dictionary indexing (default)
            index_type = LLVM.value_type(index)
            if index_type == LLVM.Int64Type()
                box_func = declare_box_int64(cg)
                box_ft = LLVM.function_type(box_func)
                index = LLVM.call!(cg.builder, box_ft, box_func, [index], "boxed")
            elseif index_type == LLVM.DoubleType()
                box_func = declare_box_float64(cg)
                box_ft = LLVM.function_type(box_func)
                index = LLVM.call!(cg.builder, box_ft, box_func, [index], "boxed")
            end
            getindex_func = declare_dict_getindex(cg)
            ft = LLVM.function_type(getindex_func)
            return LLVM.call!(cg.builder, ft, getindex_func, [container, index], "getindex")
        end
    elseif expr.head == :vect
        # Literal array: [1, 2, 3] or [1.0, 2.0, 3.0]
        n = length(expr.args)
        if n == 0
            # Empty array - default to Float64
            n_val = LLVM.ConstantInt(LLVM.Int64Type(), 0)
            new_func = declare_array_new_float64(cg)
            ft = LLVM.function_type(new_func)
            return LLVM.call!(cg.builder, ft, new_func, [n_val], "empty_arr")
        end

        # Compile all elements to determine type
        elem_vals = LLVM.Value[]
        has_float = false
        for arg in expr.args
            val = codegen(cg, arg)
            push!(elem_vals, val)
            if LLVM.value_type(val) == LLVM.DoubleType()
                has_float = true
            end
        end

        n_val = LLVM.ConstantInt(LLVM.Int64Type(), n)
        if has_float
            new_func = declare_array_new_float64(cg)
            ft = LLVM.function_type(new_func)
            arr_ptr = LLVM.call!(cg.builder, ft, new_func, [n_val], "lit_arr")
            set_func = declare_array_setindex_float64(cg)
            set_ft = LLVM.function_type(set_func)
            for (i, val) in enumerate(elem_vals)
                fval = if LLVM.value_type(val) != LLVM.DoubleType()
                    LLVM.sitofp!(cg.builder, ensure_int64(cg, val), LLVM.DoubleType(), "to_float")
                else
                    val
                end
                idx = LLVM.ConstantInt(LLVM.Int64Type(), i)
                LLVM.call!(cg.builder, set_ft, set_func, [arr_ptr, fval, idx])
            end
        else
            new_func = declare_array_new_int64(cg)
            ft = LLVM.function_type(new_func)
            arr_ptr = LLVM.call!(cg.builder, ft, new_func, [n_val], "lit_arr")
            set_func = declare_array_setindex_int64(cg)
            set_ft = LLVM.function_type(set_func)
            for (i, val) in enumerate(elem_vals)
                ival = ensure_int64(cg, val)
                idx = LLVM.ConstantInt(LLVM.Int64Type(), i)
                LLVM.call!(cg.builder, set_ft, set_func, [arr_ptr, ival, idx])
            end
        end
        return arr_ptr
    elseif expr.head == :if
        func = LLVM.parent(LLVM.position(cg.builder))
        then_block = LLVM.BasicBlock(func, "then")
        else_block = LLVM.BasicBlock(func, "else")
        merge_block = LLVM.BasicBlock(func, "ifcont")

        new_scope(cg) do
            cond_exp = expr.args[1]
            cond = codegen(cg, cond_exp)
            zero = LLVM.ConstantInt(LLVM.Int1Type(), 0)
            condv = LLVM.icmp!(cg.builder, LLVM.API.LLVMIntNE, cond, zero, "ifcond")
            LLVM.br!(cg.builder, condv, then_block, else_block)

            LLVM.position!(cg.builder, then_block)
            then_val = codegen(cg, expr.args[2])
            LLVM.br!(cg.builder, merge_block)
            then_pos = LLVM.position(cg.builder)

            LLVM.position!(cg.builder, else_block)
            else_val = codegen(cg, expr.args[3])
            LLVM.br!(cg.builder, merge_block)
            else_pos = LLVM.position(cg.builder)

            LLVM.position!(cg.builder, merge_block)
            # Infer type from then branch
            result_type = LLVM.value_type(then_val)
            phi = LLVM.phi!(cg.builder, result_type, "iftmp")
            append!(LLVM.incoming(phi), [(then_val, then_pos), (else_val, else_pos)])
            return phi
        end
    elseif expr.head == :for
        # Handle for loops: for i = start:end ... end
        iter_spec = expr.args[1]
        body = expr.args[2]

        if !(iter_spec isa Expr && iter_spec.head == :(=))
            error("Unsupported for loop format")
        end

        iter_var = string(iter_spec.args[1])
        range_expr = iter_spec.args[2]

        # Parse range (assume start:end format)
        if !(range_expr isa Expr && range_expr.head == :call && range_expr.args[1] == :(:))
            error("For loop range must be start:end")
        end

        start_val = codegen(cg, range_expr.args[2])
        end_val = codegen(cg, range_expr.args[3])

        func = LLVM.parent(LLVM.position(cg.builder))
        loop_cond = LLVM.BasicBlock(func, "loop_cond")
        loop_body = LLVM.BasicBlock(func, "loop_body")
        loop_inc = LLVM.BasicBlock(func, "loop_inc")
        loop_end = LLVM.BasicBlock(func, "loop_end")

        # Allocate loop variable
        iter_alloc = create_entry_block_allocation(cg, func, iter_var, LLVM.value_type(start_val))
        LLVM.store!(cg.builder, start_val, iter_alloc)
        current_scope(cg)[iter_var] = iter_alloc
        cg.type_env[iter_var] = LLVM.value_type(start_val)

        # Jump to condition
        LLVM.br!(cg.builder, loop_cond)

        # Condition: check if iter <= end
        LLVM.position!(cg.builder, loop_cond)
        iter_val = LLVM.load!(cg.builder, LLVM.value_type(start_val), iter_alloc, iter_var)
        is_int = LLVM.value_type(start_val) == LLVM.IntType(64)
        cond = if is_int
            LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSLE, iter_val, end_val, "loop_cond")
        else
            LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOLE, iter_val, end_val, "loop_cond")
        end
        LLVM.br!(cg.builder, cond, loop_body, loop_end)

        # Body
        LLVM.position!(cg.builder, loop_body)
        codegen(cg, body)
        LLVM.br!(cg.builder, loop_inc)

        # Increment
        LLVM.position!(cg.builder, loop_inc)
        current_iter = LLVM.load!(cg.builder, LLVM.value_type(start_val), iter_alloc, iter_var)
        one = if is_int
            LLVM.ConstantInt(LLVM.IntType(64), 1)
        else
            LLVM.ConstantFP(LLVM.DoubleType(), 1.0)
        end
        next_iter = if is_int
            LLVM.add!(cg.builder, current_iter, one, "next_iter")
        else
            LLVM.fadd!(cg.builder, current_iter, one, "next_iter")
        end
        LLVM.store!(cg.builder, next_iter, iter_alloc)
        LLVM.br!(cg.builder, loop_cond)

        # End
        LLVM.position!(cg.builder, loop_end)
        return nothing  # For loops don't return a value in Julia
    elseif expr.head == :while
        # Handle while loops: while cond ... end
        cond_expr = expr.args[1]
        body = expr.args[2]

        func = LLVM.parent(LLVM.position(cg.builder))
        loop_cond = LLVM.BasicBlock(func, "while_cond")
        loop_body = LLVM.BasicBlock(func, "while_body")
        loop_end = LLVM.BasicBlock(func, "while_end")

        # Jump to condition
        LLVM.br!(cg.builder, loop_cond)

        # Condition
        LLVM.position!(cg.builder, loop_cond)
        cond = codegen(cg, cond_expr)
        zero = LLVM.ConstantInt(LLVM.Int1Type(), 0)
        cond_bool = LLVM.icmp!(cg.builder, LLVM.API.LLVMIntNE, cond, zero, "while_cond")
        LLVM.br!(cg.builder, cond_bool, loop_body, loop_end)

        # Body
        LLVM.position!(cg.builder, loop_body)
        new_scope(cg) do
            codegen(cg, body)
        end
        LLVM.br!(cg.builder, loop_cond)

        # End
        LLVM.position!(cg.builder, loop_end)
        return LLVM.ConstantInt(LLVM.IntType(64), 0)
    elseif expr.head == :using || expr.head == :import
        # Handle using/import statements by registering them in the import context
        register_imports!(cg.import_context, Expr(:block, expr); warn_on_unresolved=false)
        # using/import don't produce a runtime value
        return LLVM.ConstantInt(LLVM.IntType(64), 0)
    elseif expr.head == :block
        # First pass: process imports and compile function definitions
        # Process in reverse order so callees are defined before callers
        functions = []
        non_functions = []

        for stmt in expr.args
            if stmt isa LineNumberNode
                continue
            elseif stmt isa Expr && (stmt.head == :using || stmt.head == :import)
                # Process imports first
                register_imports!(cg.import_context, Expr(:block, stmt); warn_on_unresolved=false)
            elseif stmt isa Expr && stmt.head == :function
                push!(functions, stmt)
            else
                push!(non_functions, stmt)
            end
        end

        # Compile functions in reverse order
        for func_expr in reverse(functions)
            codegen(cg, func_expr)
        end

        # Then compile non-function statements
        local result = LLVM.ConstantInt(LLVM.IntType(64), 0)
        for stmt in non_functions
            value = codegen(cg, stmt)
            if value !== nothing
                result = value
            end
        end
        return result
    else
        error("Unsupported expression head $(expr.head)")
    end
end

function create_entry_block_allocation(cg::CodeGen, fn::LLVM.Function, varname::String, llvm_type::LLVM.LLVMType=LLVM.IntType(64))
    LLVM.@dispose builder=LLVM.IRBuilder() begin
        entry_block = LLVM.entry(fn)
        if isempty(LLVM.instructions(entry_block))
            LLVM.position!(builder, entry_block)
        else
            LLVM.position!(builder, first(LLVM.instructions(entry_block)))
        end
        return LLVM.alloca!(builder, llvm_type, varname)
    end
end

function generate_IR(ctx::LLVM.Context, expr::Expr;
                     external_sigs::Dict{Symbol, Tuple{Int, Symbol}}=Dict{Symbol, Tuple{Int, Symbol}}(),
                     import_context::ImportContext=GLOBAL_IMPORT_CONTEXT,
                     indirect_syms::Set{Symbol}=Set{Symbol}())
    cg = CodeGen()
    cg.import_context = import_context
    cg.indirect_syms = indirect_syms
    cg.external_sigs = external_sigs

    # Pre-declare external functions with correct signatures
    for (fname, (n_params, ret_type_sym)) in external_sigs
        param_types = fill(LLVM.Int64Type(), n_params)
        ret_type = if ret_type_sym == :object
            julia_object_type()
        elseif ret_type_sym == :float64
            LLVM.DoubleType()
        else
            LLVM.Int64Type()
        end

        if fname in indirect_syms
            # Declare as global pointer variable
            func_type = LLVM.FunctionType(ret_type, param_types)
            ptr_type = LLVM.PointerType(func_type)

            ptr_name = "ptr_" * string(fname)
            gvar = LLVM.GlobalVariable(cg.mod, ptr_type, ptr_name)
            LLVM.linkage!(gvar, LLVM.API.LLVMExternalLinkage)
            LLVM.initializer!(gvar, LLVM.null(ptr_type))
        else
            # Declare as regular external function
            func_type = LLVM.FunctionType(ret_type, param_types)
            ext_func = LLVM.Function(cg.mod, string(fname), func_type)
            LLVM.linkage!(ext_func, LLVM.API.LLVMExternalLinkage)
        end
    end

    codegen(cg, expr)
    LLVM.verify(cg.mod)
    LLVM.dispose(cg.builder)
    return cg.mod
end

function compile_to_llvm(func_ast::Expr, fname::Symbol)
    ctx = LLVM.Context()
    mod = generate_IR(ctx, func_ast)
    LLVM.linkage!(LLVM.functions(mod)[string(fname)], LLVM.API.LLVMExternalLinkage)
    optimize!(mod)
    return mod, ctx
end

function get_host_cpu_name()
    ptr = LLVM.API.LLVMGetHostCPUName()
    name = unsafe_string(ptr)
    LLVM.API.LLVMDisposeMessage(ptr)
    return name
end

function get_host_cpu_features()
    ptr = LLVM.API.LLVMGetHostCPUFeatures()
    features = unsafe_string(ptr)
    LLVM.API.LLVMDisposeMessage(ptr)
    return features
end

function optimize!(mod::LLVM.Module)
    host_triple = Sys.MACHINE
    host_t = LLVM.Target(triple=host_triple)
    host_cpu = get_host_cpu_name()
    host_features = get_host_cpu_features()
    LLVM.@dispose tm=LLVM.TargetMachine(host_t, host_triple, host_cpu, host_features) pb=LLVM.NewPMPassBuilder() begin
        LLVM.add!(pb, LLVM.InstCombinePass())
        LLVM.add!(pb, LLVM.ReassociatePass())
        LLVM.add!(pb, LLVM.GVNPass())
        LLVM.add!(pb, LLVM.SimplifyCFGPass())
        LLVM.add!(pb, LLVM.PromotePass())
        LLVM.run!(pb, mod, tm)
    end
    return mod
end
