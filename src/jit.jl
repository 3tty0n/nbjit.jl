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
    return LLVM.load!(cg.builder, LLVM.IntType(64), V, string(expr))
end

function codegen(cg::CodeGen, expr::Expr)
    if expr.head == :(=) && isa(expr.args[1], Symbol)
        local initval
        local V
        var = string(expr.args[1])
        initval = codegen(cg, expr.args[2])
        V = LLVM.GlobalVariable(cg.mod, LLVM.IntType(64), var)
        LLVM.initializer!(V, initval)
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
            return LLVM.div!(cg.builder, L, R, "divtmp")
        else
            error("unreachable path")
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
    elseif expr.head == :block
        local result
        for expr in expr.args
            if expr isa LineNumberNode
                continue
            end
            result = codegen(cg, expr)
        end
        return result
    elseif expr.head == :return
        rhs = expr.args[1]
        retval = codegen(cg, rhs)
        return retval
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
        alloc = LLVM.allocate!(builder, LLVM.IntType(64), varname)
    end
    return alloc
end

function generate_IR(code)
    ctx = LLVM.Context()
    cg = CodeGen()
    expr = Meta.parse(code)
    codegen(cg, expr)
    LLVM.verify(cg.mod)
    LLVM.dispose(cg.builder)
    return cg.mod
end

function run(code::String, entry::String)
    local res_jl
    @show m = generate_IR(code)
    LLVM.@dispose engine=LLVM.JIT(m) begin
        f = LLVM.functions(engine)[entry]
        res = LLVM.run(engine, f)
        res_jl = convert(Int64, res)
        LLVM.dispose(res)
    end

    println(res_jl)
    return res_jl
end

run("function entry() x=1; return x+2 end", "entry")
