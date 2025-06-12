using LLVM

LLVM.Context() do ctx

    mod = LLVM.Module("nbjit_module")
end
