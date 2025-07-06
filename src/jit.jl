using LLVM
using LLVM.Interop

include("./peval.jl")
include("./jit_scope.jl")

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
    return LLVM.ConstantInt(LLVM.IntType(64), eval(expr))
end

function codegen(cg::CodeGen, expr::Symbol)
    V = get(current_scope(cg), string(expr), nothing)
    V == nothing && error("did not find variable $(expr.name)")
    return LLVM.load!(cg.builder, LLVM.Int64Type(), V, string(expr))
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
            return LLVM.udiv!(cg.builder, L, R, "udivtmp")
        elseif expr.args[1] == :<
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntULT, L, R, "cmptmp")
        elseif expr.args[1] == :>
            lhs = expr.args[2]
            rhs = expr.args[3]
            L = codegen(cg, lhs)
            R = codegen(cg, rhs)
            return LLVM.icmp!(cg.builder, LLVM.API.LLVMIntUGT, L, R, "cmptmp")
        else
            error("unreachable path", expr)
        end
    elseif expr.head == :function
        # prototype
        signature = expr.args[1]
        func_name = string(signature.args[1])
        args = [LLVM.IntType(64) for i in 1:length(signature.args[2:end])]
        func_type = LLVM.FunctionType(LLVM.IntType(64), args)
        func = LLVM.Function(cg.mod, func_name, func_type)
        LLVM.linkage!(func, LLVM.API.LLVMExternalLinkage)

        for (i, param) in enumerate(LLVM.parameters(func))
            LLVM.name!(param, signature.args[i])
        end

        # body
        entry = LLVM.BasicBlock(func, "entry")
        LLVM.position!(cg.builder, entry)

        local alloc
        new_scope(cg) do
            for (i, param) in enumerate(LLVM.parameters(func))
                argname = signature.args[i]
                create_entry_block_allocation(cg, func, argname)
                LLVM.store!(cg.builder, param, alloc)
                current_scope(cg)[argname] = alloc
            end
            body = codegen(cg, expr.args[2])
            LLVM.ret!(cg.builder, body)
            LLVM.verify(func)
        end
        return func
    elseif expr.head == :return
        rhs = expr.args[1]
        retval = codegen(cg, rhs)
        # Caution: should not add terminator here
        return retval
    elseif expr.head == :if
	    func = LLVM.parent(LLVM.position(cg.builder))
        then = LLVM.BasicBlock(func, "then")
        elsee = LLVM.BasicBlock(func, "else")
        merge = LLVM.BasicBlock(func, "ifcont")

        local phi
        new_scope(cg) do
            # if
            cond_exp = expr.args[1]
            cond = codegen(cg, cond_exp)
            zero = LLVM.ConstantInt(LLVM.Int1Type(), 0)
            condv = LLVM.icmp!(cg.builder, LLVM.API.LLVMIntNE, cond, zero, "ifcond")
            LLVM.br!(cg.builder, condv, then, elsee)

            # then
            then_exp = expr.args[2]
            LLVM.position!(cg.builder, then)
            thencg = codegen(cg, then_exp)
            LLVM.br!(cg.builder, merge)
            then_block = position(cg.builder)

            # else
            else_exp = expr.args[3]
            LLVM.position!(cg.builder, elsee)
            elsecg = codegen(cg, else_exp)
            LLVM.br!(cg.builder, merge)
            else_block = position(cg.builder)

            # merge
            LLVM.position!(cg.builder, merge)
            phi = LLVM.phi!(cg.builder, LLVM.Int64Type(), "iftmp")
            append!(LLVM.incoming(phi), [(thencg, then_block), (elsecg, else_block)])
        end
        return phi
    elseif expr.head == :block
        local result
        for expr in expr.args
            if expr isa LineNumberNode
                continue
            end
            result = codegen(cg, expr)
        end
        return result
    end
end

function create_entry_block_allocation(cg::CodeGen, fn::LLVM.Function, varname::String)
    local alloc
    LLVM.@dispose builder=LLVM.IRBuilder() begin
        entry_block = LLVM.entry(fn)
        if isempty(LLVM.instructions(entry_block))
            LLVM.position!(builder, entry_block)
        else
            LLVM.position!(builder, first(LLVM.instructions(entry_block)))
        end
        alloc = LLVM.alloca!(builder, LLVM.IntType(64), varname)
    end
    return alloc
end

function generate_IR(ctx::LLVM.Context, code::String)
    cg = CodeGen()
    expr = Meta.parse(code)
    if expr.head == :incomplete
        error(expr.args[1])
    end

    codegen(cg, expr)
    LLVM.verify(cg.mod)
    LLVM.dispose(cg.builder)
    return cg.mod
end

function generate_IR(ctx::LLVM.Context, expr::Expr)
    cg = CodeGen()
    codegen(cg, expr)
    LLVM.verify(cg.mod)
    LLVM.dispose(cg.builder)
    return cg.mod
end

function run(code::String, entry::String)
    local res_jl
    LLVM.Context() do ctx
        mod = generate_IR(ctx, code)
        LLVM.@dispose engine = LLVM.JIT(mod) begin
            if !haskey(LLVM.functions(engine), entry)
                error("did not find entry function '$entry' in module")
            end
            f = LLVM.functions(engine)[entry]
            res = LLVM.run(engine, f)
            res_jl = convert(Int64, res)
            LLVM.dispose(res)
        end
    end

    #println(res_jl)
    return res_jl
end

function run(code::Expr, entry::String)
    local res_jl
    LLVM.Context() do ctx
        mod = generate_IR(ctx, code)
        LLVM.@dispose engine = LLVM.JIT(mod) begin
            if !haskey(LLVM.functions(engine), entry)
                error("did not find entry function '$entry' in module")
            end
            f = LLVM.functions(engine)[entry]
            res = LLVM.run(engine, f)
            res_jl = convert(Int64, res)
            LLVM.dispose(res)
        end
    end

    #println(res_jl)
    return res_jl
end

function write_objectfile(mod::LLVM.Module, path::String)
    host_triple = Sys.MACHINE # LLVM.triple() might be wrong (see LLVM.jl#108)
    host_t = LLVM.Target(triple=host_triple)
    LLVM.@dispose tm=LLVM.TargetMachine(host_t, host_triple) begin
        LLVM.emit(tm, mod, LLVM.API.LLVMObjectFile, path)
    end
end
