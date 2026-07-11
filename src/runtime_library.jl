"""
Runtime library compilation and initialization for nbjit dylibs
"""

using Libdl

# Global handle to the runtime library
const RUNTIME_LIB_HANDLE = Ref{Ptr{Cvoid}}(C_NULL)
const RUNTIME_LIB_PATH = Ref{String}("")

"""
Compile the runtime stub library that provides C-callable wrappers
for Julia runtime functions. This library gets linked with all dylibs.
"""
function compile_runtime_library()
    lib_handle = RUNTIME_LIB_HANDLE[]
    lib_path = RUNTIME_LIB_PATH[]

    if lib_handle == C_NULL
        runtime_c = joinpath(@__DIR__, "runtime_stub.c")
        if !isfile(runtime_c)
            error("Runtime stub file not found: $runtime_c")
        end

        # Use a process-shared stable path so all module redefinitions reuse the
        # same runtime stub instance and symbol table.
        lib_path = joinpath(tempdir(), "nbjit_runtime_shared.$(Libdl.dlext)")

        if !isfile(lib_path)
            if Sys.islinux()
                run(`gcc -shared -fPIC -o $lib_path $runtime_c`)
            elseif Sys.isapple()
                run(`clang -shared -fPIC -o $lib_path $runtime_c`)
            elseif Sys.iswindows()
                # Windows compilation would go here
                error("Windows not yet supported for runtime library")
            else
                error("Unsupported platform")
            end
        end

        # Load the library
        lib_handle = dlopen(lib_path, RTLD_NOW | RTLD_GLOBAL)
        RUNTIME_LIB_HANDLE[] = lib_handle
        RUNTIME_LIB_PATH[] = lib_path
    end

    # Initialize it with function pointers from Julia
    init_func = dlsym(lib_handle, :nbjit_init_runtime)

    # Get @cfunction pointers for all runtime functions
    dict_new_ptr = @cfunction(nbjit_dict_new, Ptr{Cvoid}, ())
    dict_getindex_ptr = @cfunction(nbjit_dict_getindex, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}))
    dict_setindex_ptr = @cfunction(nbjit_dict_setindex!, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
    symbol_from_cstr_ptr = @cfunction(nbjit_symbol_from_cstr, Ptr{Cvoid}, (Ptr{UInt8},))
    box_int64_ptr = @cfunction(nbjit_box_int64, Ptr{Cvoid}, (Int64,))
    box_float64_ptr = @cfunction(nbjit_box_float64, Ptr{Cvoid}, (Float64,))
    unbox_int64_ptr = @cfunction(nbjit_unbox_int64, Int64, (Ptr{Cvoid},))
    unbox_float64_ptr = @cfunction(nbjit_unbox_float64, Float64, (Ptr{Cvoid},))

    # Call init function
    ccall(init_func, Cvoid, (
        Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
        Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}
    ),
        dict_new_ptr, dict_getindex_ptr, dict_setindex_ptr, symbol_from_cstr_ptr,
        box_int64_ptr, box_float64_ptr, unbox_int64_ptr, unbox_float64_ptr
    )

    # Initialize array runtime functions
    array_init_func = dlsym(lib_handle, :nbjit_init_array_runtime)
    array_new_f64_ptr = @cfunction(nbjit_array_new_float64, Ptr{Cvoid}, (Int64,))
    array_new_i64_ptr = @cfunction(nbjit_array_new_int64, Ptr{Cvoid}, (Int64,))
    array_get_f64_ptr = @cfunction(nbjit_array_getindex_float64, Float64, (Ptr{Cvoid}, Int64))
    array_get_i64_ptr = @cfunction(nbjit_array_getindex_int64, Int64, (Ptr{Cvoid}, Int64))
    array_set_f64_ptr = @cfunction(nbjit_array_setindex_float64, Cvoid, (Ptr{Cvoid}, Float64, Int64))
    array_set_i64_ptr = @cfunction(nbjit_array_setindex_int64, Cvoid, (Ptr{Cvoid}, Int64, Int64))
    array_length_ptr = @cfunction(nbjit_array_length, Int64, (Ptr{Cvoid},))
    array_push_f64_ptr = @cfunction(nbjit_array_push_float64, Ptr{Cvoid}, (Ptr{Cvoid}, Float64))
    array_push_i64_ptr = @cfunction(nbjit_array_push_int64, Ptr{Cvoid}, (Ptr{Cvoid}, Int64))
    zeros_ptr = @cfunction(nbjit_zeros, Ptr{Cvoid}, (Int64,))
    ones_ptr = @cfunction(nbjit_ones, Ptr{Cvoid}, (Int64,))

    ccall(array_init_func, Cvoid, (
        Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
        Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid},
        Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}
    ),
        array_new_f64_ptr, array_new_i64_ptr,
        array_get_f64_ptr, array_get_i64_ptr,
        array_set_f64_ptr, array_set_i64_ptr,
        array_length_ptr,
        array_push_f64_ptr, array_push_i64_ptr,
        zeros_ptr, ones_ptr
    )

    # Initialize cross-cell global variable runtime functions
    global_init_func = dlsym(lib_handle, :nbjit_init_global_runtime)
    global_get_ptr = @cfunction(nbjit_global_get, Ptr{Cvoid}, (Ptr{UInt8},))
    global_set_i64_ptr = @cfunction(nbjit_global_set_int64, Cvoid, (Ptr{UInt8}, Int64))
    global_set_f64_ptr = @cfunction(nbjit_global_set_float64, Cvoid, (Ptr{UInt8}, Float64))
    global_set_obj_ptr = @cfunction(nbjit_global_set_object, Cvoid, (Ptr{UInt8}, Ptr{Cvoid}))

    ccall(global_init_func, Cvoid, (
        Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}
    ),
        global_get_ptr, global_set_i64_ptr, global_set_f64_ptr, global_set_obj_ptr
    )

    return lib_path
end

"""
Get the path to the runtime library, compiling it if necessary
"""
function get_runtime_library_path()
    # Always (re)initialize function pointers for the current Julia module.
    return compile_runtime_library()
end

"""
Register an external function pointer in the runtime library.
This makes the function available for LLVM-compiled code to call.
"""
function runtime_register_external_func(name::String, func_ptr::Ptr{Cvoid})
    # Ensure runtime library is loaded
    get_runtime_library_path()

    if RUNTIME_LIB_HANDLE[] == C_NULL
        error("Runtime library not loaded")
    end

    register_func = dlsym(RUNTIME_LIB_HANDLE[], :nbjit_register_external_func)
    ccall(register_func, Cvoid, (Cstring, Ptr{Cvoid}), name, func_ptr)
end

"""
Look up an external function pointer by name
"""
function runtime_lookup_external_func(name::String)::Ptr{Cvoid}
    get_runtime_library_path()

    if RUNTIME_LIB_HANDLE[] == C_NULL
        error("Runtime library not loaded")
    end

    lookup_func = dlsym(RUNTIME_LIB_HANDLE[], :nbjit_lookup_external_func)
    return ccall(lookup_func, Ptr{Cvoid}, (Cstring,), name)
end

"""
Clear all registered external functions
"""
function runtime_clear_external_funcs()
    get_runtime_library_path()

    if RUNTIME_LIB_HANDLE[] == C_NULL
        return
    end

    clear_func = dlsym(RUNTIME_LIB_HANDLE[], :nbjit_clear_external_funcs)
    ccall(clear_func, Cvoid, ())
end

export compile_runtime_library, get_runtime_library_path
export runtime_register_external_func, runtime_lookup_external_func, runtime_clear_external_funcs
