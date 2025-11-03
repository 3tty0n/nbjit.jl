#!/usr/bin/env julia

using LLVM

include("../src/jit.jl")

println("=== println Support in nbjit.jl ===\n")

# Example 1: Print integers
println("Example 1: Printing integers")
code1 = quote
    function demo_int()
        x = 10
        y = 20
        z = x + y
        println(z)
        z
    end
end

ctx1 = LLVM.Context()
mod1 = generate_IR(ctx1, code1)
result1 = LLVM.JIT(mod1) do engine
    func_ptr = LLVM.lookup(engine, "demo_int")
    ccall(func_ptr, Int64, ())
end
println("Returned value: $result1\n")
LLVM.dispose(ctx1)

# Example 2: Print strings
println("Example 2: Printing strings")
code2 = quote
    function demo_string()
        println("Hello from JIT compiled code!")
        println("Second line")
        42
    end
end

ctx2 = LLVM.Context()
mod2 = generate_IR(ctx2, code2)
result2 = LLVM.JIT(mod2) do engine
    func_ptr = LLVM.lookup(engine, "demo_string")
    ccall(func_ptr, Int64, ())
end
println("Returned value: $result2\n")
LLVM.dispose(ctx2)

# Example 3: Print floats
println("Example 3: Printing floats")
code3 = quote
    function demo_float()
        pi_val = 3.14159
        println(pi_val)
        0
    end
end

ctx3 = LLVM.Context()
mod3 = generate_IR(ctx3, code3)
result3 = LLVM.JIT(mod3) do engine
    func_ptr = LLVM.lookup(engine, "demo_float")
    ccall(func_ptr, Int64, ())
end
println("Returned value: $result3\n")
LLVM.dispose(ctx3)

# Example 4: Print booleans
println("Example 4: Printing booleans")
code4 = quote
    function demo_bool()
        is_true = true
        is_false = false
        println(is_true)
        println(is_false)
        0
    end
end

ctx4 = LLVM.Context()
mod4 = generate_IR(ctx4, code4)
result4 = LLVM.JIT(mod4) do engine
    func_ptr = LLVM.lookup(engine, "demo_bool")
    ccall(func_ptr, Int64, ())
end
println("Returned value: $result4\n")
LLVM.dispose(ctx4)

# Example 5: Mixed types in loop
println("Example 5: Printing in a loop")
code5 = quote
    function demo_loop()
        sum = 0
        for i = 1:5
            sum = sum + i
            println(sum)
        end
        sum
    end
end

ctx5 = LLVM.Context()
mod5 = generate_IR(ctx5, code5)
result5 = LLVM.JIT(mod5) do engine
    func_ptr = LLVM.lookup(engine, "demo_loop")
    ccall(func_ptr, Int64, ())
end
println("Final sum: $result5\n")
LLVM.dispose(ctx5)

println("✅ All println examples completed!")
