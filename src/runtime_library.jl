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
    # Check if already compiled
    if RUNTIME_LIB_HANDLE[] != C_NULL
        return RUNTIME_LIB_PATH[]
    end

    runtime_c = joinpath(@__DIR__, "runtime_stub.c")
    if !isfile(runtime_c)
        error("Runtime stub file not found: $runtime_c")
    end

    # Compile to shared library
    lib_path = tempname() * "_runtime.$(Libdl.dlext)"

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

    # Load the library
    lib_handle = dlopen(lib_path, RTLD_NOW | RTLD_GLOBAL)

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

    # Store globally
    RUNTIME_LIB_HANDLE[] = lib_handle
    RUNTIME_LIB_PATH[] = lib_path

    return lib_path
end

"""
Get the path to the runtime library, compiling it if necessary
"""
function get_runtime_library_path()
    if RUNTIME_LIB_PATH[] == ""
        compile_runtime_library()
    end
    return RUNTIME_LIB_PATH[]
end

export compile_runtime_library, get_runtime_library_path
