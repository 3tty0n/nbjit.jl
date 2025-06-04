using LLVM

LLVM.Context() do ctx

    # set-up
    mod = LLVM.Module("my_module")
    func_type = LLVM.FunctionType(LLVM.Int32Type(), [LLVM.Int32Type(), LLVM.Int32Type()])

    add = LLVM.Function(mod, "add", func_type)

    # generate IR
    IRBuilder() do builder
        entry = BasicBlock(add, "entry")
        position!(builder, entry)

        tmp = add!(builder, parameters(add)[1], parameters(add)[2], "tmp")
        ret!(builder, tmp)

        verify(mod)
    end

    # analysis and execution
    JIT(mod) do engine
        add = lookup(engine, "add")
        res = ccall(add, Int32, (Int32, Int32), Int32(1), Int32(2))
        println(res)
    end

end

