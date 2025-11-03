using LLVM
using LLVM.Interop

include("./jit_scope.jl")

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

    CodeGen() =
        new(
            LLVM.IRBuilder(),
            CurrentScope(),
            LLVM.Module("nbjit"),
            Dict{String, LLVM.LLVMType}(),
            Dict{String, LLVM.Value}()
        )
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
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.fadd!(cg.builder, L, R, "addtmp")
            else
                return LLVM.add!(cg.builder, L, R, "addtmp")
            end
        elseif expr.args[1] == :-
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.fsub!(cg.builder, L, R, "subtmp")
            else
                return LLVM.sub!(cg.builder, L, R, "subtmp")
            end
        elseif expr.args[1] == :*
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.fmul!(cg.builder, L, R, "multmp")
            else
                return LLVM.mul!(cg.builder, L, R, "multmp")
            end
        elseif expr.args[1] == :/
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.fdiv!(cg.builder, L, R, "divtmp")
            else
                return LLVM.sdiv!(cg.builder, L, R, "divtmp")
            end
        elseif expr.args[1] == :%
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.frem!(cg.builder, L, R, "modtmp")
            else
                return LLVM.srem!(cg.builder, L, R, "modtmp")
            end
        elseif expr.args[1] == :<
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOLT, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSLT, L, R, "cmptmp")
            end
        elseif expr.args[1] == :>
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOGT, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSGT, L, R, "cmptmp")
            end
        elseif expr.args[1] == :<=
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOLE, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSLE, L, R, "cmptmp")
            end
        elseif expr.args[1] == :>=
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOGE, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSGE, L, R, "cmptmp")
            end
        elseif expr.args[1] == :(==)
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
                return LLVM.fcmp!(cg.builder, LLVM.API.LLVMRealOEQ, L, R, "cmptmp")
            else
                return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntEQ, L, R, "cmptmp")
            end
        elseif expr.args[1] == :(!=)
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            if LLVM.value_type(L) == LLVM.DoubleType() || LLVM.value_type(R) == LLVM.DoubleType()
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
        elseif expr.args[1] isa Symbol
            callee = expr.args[1]
            julia_args = expr.args[2:end]

            if !haskey(LLVM.functions(cg.mod), string(callee))
                error("encountered undeclared function $(callee)")
            end
            func =  LLVM.functions(cg.mod)[string(callee)]

            if length(LLVM.parameters(func)) != length(julia_args)
                error("number of parameters mismatch")
            end

            args = LLVM.Value[]
            for v in julia_args
                push!(args, codegen(cg, v))
            end
            ft = LLVM.function_type(func)
            return LLVM.call!(cg.builder, ft, func, args, "calltmp")
        else
            error("unreachable path", expr)
        end
    elseif expr.head == :function
        signature = expr.args[1]
        func_name = string(signature.args[1])
        args = [LLVM.IntType(64) for _ in signature.args[2:end]]
        func_type = LLVM.FunctionType(LLVM.IntType(64), args)
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

            # Convert return value to Int64 if necessary
            if body === nothing
                ret_val = LLVM.ConstantInt(LLVM.IntType(64), 0)
            else
                body_type = LLVM.value_type(body)
                if body_type == LLVM.DoubleType()
                    # Cast float to int
                    ret_val = LLVM.fptosi!(cg.builder, body, LLVM.IntType(64), "fptosi")
                elseif body_type == LLVM.Int1Type()
                    # Extend bool to int64
                    ret_val = LLVM.zext!(cg.builder, body, LLVM.IntType(64), "zext")
                else
                    ret_val = body
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
        local result = LLVM.ConstantInt(LLVM.IntType(64), 0)
        for stmt in expr.args
            if stmt isa LineNumberNode
                continue
            end
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

function generate_IR(ctx::LLVM.Context, expr::Expr)
    cg = CodeGen()
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
