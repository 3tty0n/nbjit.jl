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

    CodeGen() =
        new(
            LLVM.IRBuilder(),
            CurrentScope(),
            LLVM.Module("nbjit")
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

function codegen(cg::CodeGen, expr::Symbol)
    if expr == :nothing
        return
    end

    V = get(current_scope(cg), string(expr), nothing)
    V == nothing && error("did not find variable $(expr)")
    return LLVM.load!(cg.builder, LLVM.Int64Type(), V, string(expr))
end

function codegen(cg::CodeGen, ::Nothing)
    return
end

function codegen(cg::CodeGen, expr::Expr)
    if expr.head == :(=) && isa(expr.args[1], Symbol)
        local initval
        local V
        var = string(expr.args[1])
        initval = codegen(cg, expr.args[2])
        if isglobalscope(current_scope(cg))
            V = LLVM.GlobalVariable(cg.mod, LLVM.IntType(64), var)
            LLVM.initializer!(V, initval)
        else
            func = LLVM.parent(LLVM.position(cg.builder))
            V = create_entry_block_allocation(cg, func, var)
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
            return LLVM.add!(cg.builder, L, R, "addtmp")
        elseif expr.args[1] == :-
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            return LLVM.sub!(cg.builder, L, R, "subtmp")
        elseif expr.args[1] == :*
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            return LLVM.mul!(cg.builder, L, R, "multmp")
        elseif expr.args[1] == :/
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            return LLVM.sdiv!(cg.builder, L, R, "divtmp")
        elseif expr.args[1] == :<
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSLT, L, R, "cmptmp")
        elseif expr.args[1] == :>
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntSGT, L, R, "cmptmp")
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
            LLVM.ret!(cg.builder, body === nothing ? LLVM.ConstantInt(LLVM.IntType(64), 0) : body)
        end
        return func
    elseif expr.head == :return
        rhs = expr.args[1]
        retval = codegen(cg, rhs)
        return retval
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
            phi = LLVM.phi!(cg.builder, LLVM.Int64Type(), "iftmp")
            append!(LLVM.incoming(phi), [(then_val, then_pos), (else_val, else_pos)])
            return phi
        end
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

function create_entry_block_allocation(cg::CodeGen, fn::LLVM.Function, varname::String)
    LLVM.@dispose builder=LLVM.IRBuilder() begin
        entry_block = LLVM.entry(fn)
        if isempty(LLVM.instructions(entry_block))
            LLVM.position!(builder, entry_block)
        else
            LLVM.position!(builder, first(LLVM.instructions(entry_block)))
        end
        return LLVM.alloca!(builder, LLVM.IntType(64), varname)
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
