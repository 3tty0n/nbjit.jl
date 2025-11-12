using LLVM
using LLVM.Interop

include("./jit_scope.jl")
include("./jit_runtime.jl")

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

    CodeGen() =
        new(
            LLVM.IRBuilder(),
            CurrentScope(),
            LLVM.Module("nbjit"),
            Dict{String, LLVM.LLVMType}(),
            Dict{String, LLVM.Value}(),
            Set{String}()
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

                # Check if RHS is a Dict construction
                if rhs isa Expr && rhs.head == :call && rhs.args[1] == :Dict
                    types[var] = :object
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
Returns :primitive for Int64/Float64/Bool, :object for Dict/Symbol, etc.
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
                elseif rhs isa Symbol && haskey(var_types, rhs)
                    # Variable assigned from another variable
                    var_types[var] = var_types[rhs]
                else
                    var_types[var] = :primitive
                end
            elseif e.head == :block
                for arg in e.args
                    scan_assignments(arg)
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
        return :primitive
    end

    # Check if last expression is a Dict construction or reference
    function check_expr(e)::Symbol
        if e isa Symbol
            # Look up variable type from our tracking
            return get(var_types, e, :primitive)
        elseif e isa Expr
            if e.head == :call
                if e.args[1] == :Dict
                    return :object
                end
            elseif e.head == :(=)
                # Return type is based on RHS
                return check_expr(e.args[2])
            elseif e.head == :ref
                # dict[key] returns an object that needs unboxing
                # But since arithmetic operations unbox it, check context
                # For now, assume :primitive (since it will be unboxed for use)
                return :primitive
            end
        end
        return :primitive
    end

    return check_expr(last_expr)
end

current_scope(cg::CodeGen) = cg.current_scope
function new_scope(f, cg::CodeGen)
    open_scope!(current_scope(cg))
    f()
    pop!(current_scope(cg))
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
    str_ptr = codegen(cg, sym_name)

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
        # Try to unbox to Int64 (we can add Float64 support later)
        unbox_func = declare_unbox_int64(cg)
        ft = LLVM.function_type(unbox_func)
        return (LLVM.call!(cg.builder, ft, unbox_func, [val], "unboxed"), :int64)
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
    V == nothing && error("did not find variable $(expr)")

    # Get the type from type_env
    var_type = get(cg.type_env, string(expr), LLVM.Int64Type())
    return LLVM.load!(cg.builder, var_type, V, string(expr))
end

function codegen(cg::CodeGen, ::Nothing)
    return
end

function codegen(cg::CodeGen, str::String)
    # Handle string literals by creating global string constants
    if haskey(cg.string_cache, str)
        return cg.string_cache[str]
    end

    # Create a global string constant with newline and null terminator
    str_with_newline = str * "\n"
    bytes = Vector{UInt8}(str_with_newline)
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

    cg.string_cache[str] = str_ptr
    return str_ptr
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

function codegen(cg::CodeGen, expr::Expr)
    if expr.head == :(=) && isa(expr.args[1], Symbol)
        local initval
        local V
        var = string(expr.args[1])
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
        else
            func = LLVM.parent(LLVM.position(cg.builder))
            V = create_entry_block_allocation(cg, func, var, llvm_type)
            LLVM.store!(cg.builder, initval, V)
        end
        current_scope(cg)[var] = V
        return initval
    elseif expr.head == :call
        if expr.args[1] == :+
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
            # setindex!(dict, value, key)
            dict_ptr = codegen(cg, expr.args[2])
            value = codegen(cg, expr.args[3])
            key = codegen(cg, expr.args[4])

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
            LLVM.call!(cg.builder, ft, setindex_func, [dict_ptr, value, key])

            # setindex! returns nothing, but we return the dict_ptr for convenience
            return dict_ptr
        elseif expr.args[1] isa Symbol
            callee = expr.args[1]
            julia_args = expr.args[2:end]
            arg_vals = LLVM.Value[]
            for v in julia_args
                push!(arg_vals, codegen(cg, v))
            end

            func_name = string(callee)

            # Check if function already exists in module
            if haskey(LLVM.functions(cg.mod), func_name)
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
            else
                push!(args, LLVM.IntType(64))
            end
        end

        # Set return type based on inference
        return_llvm_type = if return_type_sym == :object
            julia_object_type()
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
                    # Return null pointer for object type
                    ret_val = LLVM.ConstantPointerNull(julia_object_type())
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
        # Dictionary/array indexing: dict[:key]
        container = codegen(cg, expr.args[1])
        index = codegen(cg, expr.args[2])

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

        # Call getindex runtime function
        getindex_func = declare_dict_getindex(cg)
        ft = LLVM.function_type(getindex_func)
        value_ptr = LLVM.call!(cg.builder, ft, getindex_func, [container, index], "getindex")

        # For now, return the object pointer
        # If we need to unbox to int64, caller should handle it
        return value_ptr
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
        new_scope(cg) do
            codegen(cg, body)
        end
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
        return LLVM.ConstantInt(LLVM.IntType(64), 0)
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
    elseif expr.head == :block
        # First pass: compile all function definitions
        # Process in reverse order so callees are defined before callers
        functions = []
        non_functions = []

        for stmt in expr.args
            if stmt isa LineNumberNode
                continue
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

function generate_IR(ctx::LLVM.Context, expr::Expr; external_sigs::Dict{Symbol, Tuple{Int, Bool}}=Dict{Symbol, Tuple{Int, Bool}}())
    cg = CodeGen()

    # Pre-declare external functions with correct signatures
    for (fname, (n_params, returns_object)) in external_sigs
        param_types = fill(LLVM.Int64Type(), n_params)
        ret_type = returns_object ? julia_object_type() : LLVM.Int64Type()
        func_type = LLVM.FunctionType(ret_type, param_types)
        ext_func = LLVM.Function(cg.mod, string(fname), func_type)
        LLVM.linkage!(ext_func, LLVM.API.LLVMExternalLinkage)
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

function optimize!(mod::LLVM.Module)
    host_triple = Sys.MACHINE
    host_t = LLVM.Target(triple=host_triple)
    LLVM.@dispose tm=LLVM.TargetMachine(host_t, host_triple) pb=LLVM.NewPMPassBuilder() begin
        LLVM.add!(pb, LLVM.InstCombinePass())
        LLVM.add!(pb, LLVM.ReassociatePass())
        LLVM.add!(pb, LLVM.GVNPass())
        LLVM.add!(pb, LLVM.SimplifyCFGPass())
        LLVM.add!(pb, LLVM.PromotePass())
        LLVM.run!(pb, mod, tm)
    end
    return mod
end
