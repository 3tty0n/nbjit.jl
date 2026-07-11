/*
 * Runtime stub library for nbjit
 * This file provides C-callable stubs that forward to Julia runtime functions
 * Also provides dynamic external function dispatch for imported modules
 */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>

// External declarations for Julia runtime functions
// These will be resolved via @cfunction when the library is loaded

extern void* nbjit_dict_new_impl(void);
extern void* nbjit_dict_getindex_impl(void*, void*);
extern void nbjit_dict_setindex_impl(void*, void*, void*);
extern void* nbjit_symbol_from_cstr_impl(const char*);
extern void* nbjit_global_get_impl(const char*);
extern void nbjit_global_set_int64_impl(const char*, int64_t);
extern void nbjit_global_set_float64_impl(const char*, double);
extern void nbjit_global_set_object_impl(const char*, void*);
extern void* nbjit_box_int64_impl(int64_t);
extern void* nbjit_box_float64_impl(double);
extern int64_t nbjit_unbox_int64_impl(void*);
extern double nbjit_unbox_float64_impl(void*);

// External function registry for imported module calls
#define MAX_EXTERNAL_FUNCS 256

typedef struct {
    char name[128];
    void* func_ptr;
} ExternalFuncEntry;

static ExternalFuncEntry external_funcs[MAX_EXTERNAL_FUNCS];
static int num_external_funcs = 0;

// Forward declarations for the stubs
void* nbjit_dict_new(void);
void* nbjit_dict_getindex(void* dict, void* key);
void nbjit_dict_setindex_bang(void* dict, void* value, void* key);
void* nbjit_symbol_from_cstr(const char* str);
void* nbjit_global_get(const char* name);
void nbjit_global_set_int64(const char* name, int64_t value);
void nbjit_global_set_float64(const char* name, double value);
void nbjit_global_set_object(const char* name, void* value);
void* nbjit_box_int64(int64_t val);
void* nbjit_box_float64(double val);
int64_t nbjit_unbox_int64(void* ptr);
double nbjit_unbox_float64(void* ptr);

// Global function pointers that will be set by Julia
static void* (*fp_dict_new)(void) = 0;
static void* (*fp_dict_getindex)(void*, void*) = 0;
static void (*fp_dict_setindex_bang)(void*, void*, void*) = 0;
static void* (*fp_symbol_from_cstr)(const char*) = 0;
static void* (*fp_global_get)(const char*) = 0;
static void (*fp_global_set_int64)(const char*, int64_t) = 0;
static void (*fp_global_set_float64)(const char*, double) = 0;
static void (*fp_global_set_object)(const char*, void*) = 0;
static void* (*fp_box_int64)(int64_t) = 0;
static void* (*fp_box_float64)(double) = 0;
static int64_t (*fp_unbox_int64)(void*) = 0;
static double (*fp_unbox_float64)(void*) = 0;

// Array function pointers
static void* (*fp_array_new_float64)(int64_t) = 0;
static void* (*fp_array_new_int64)(int64_t) = 0;
static double (*fp_array_getindex_float64)(void*, int64_t) = 0;
static int64_t (*fp_array_getindex_int64)(void*, int64_t) = 0;
static void (*fp_array_setindex_float64)(void*, double, int64_t) = 0;
static void (*fp_array_setindex_int64)(void*, int64_t, int64_t) = 0;
static int64_t (*fp_array_length)(void*) = 0;
static void* (*fp_array_push_float64)(void*, double) = 0;
static void* (*fp_array_push_int64)(void*, int64_t) = 0;
static void* (*fp_zeros)(int64_t) = 0;
static void* (*fp_ones)(int64_t) = 0;

// Initialization function called from Julia
void nbjit_init_runtime(
    void* dict_new,
    void* dict_getindex,
    void* dict_setindex_bang,
    void* symbol_from_cstr,
    void* box_int64,
    void* box_float64,
    void* unbox_int64,
    void* unbox_float64
) {
    fp_dict_new = dict_new;
    fp_dict_getindex = dict_getindex;
    fp_dict_setindex_bang = dict_setindex_bang;
    fp_symbol_from_cstr = symbol_from_cstr;
    fp_box_int64 = box_int64;
    fp_box_float64 = box_float64;
    fp_unbox_int64 = unbox_int64;
    fp_unbox_float64 = unbox_float64;
}

void nbjit_init_global_runtime(
    void* global_get,
    void* global_set_int64,
    void* global_set_float64,
    void* global_set_object
) {
    fp_global_get = global_get;
    fp_global_set_int64 = global_set_int64;
    fp_global_set_float64 = global_set_float64;
    fp_global_set_object = global_set_object;
}

// Array initialization function
void nbjit_init_array_runtime(
    void* array_new_float64,
    void* array_new_int64,
    void* array_getindex_float64,
    void* array_getindex_int64,
    void* array_setindex_float64,
    void* array_setindex_int64,
    void* array_length,
    void* array_push_float64,
    void* array_push_int64,
    void* zeros_fn,
    void* ones_fn
) {
    fp_array_new_float64 = array_new_float64;
    fp_array_new_int64 = array_new_int64;
    fp_array_getindex_float64 = array_getindex_float64;
    fp_array_getindex_int64 = array_getindex_int64;
    fp_array_setindex_float64 = array_setindex_float64;
    fp_array_setindex_int64 = array_setindex_int64;
    fp_array_length = array_length;
    fp_array_push_float64 = array_push_float64;
    fp_array_push_int64 = array_push_int64;
    fp_zeros = zeros_fn;
    fp_ones = ones_fn;
}

// Stub implementations
void* nbjit_dict_new(void) {
    return fp_dict_new();
}

void* nbjit_dict_getindex(void* dict, void* key) {
    return fp_dict_getindex(dict, key);
}

void nbjit_dict_setindex_bang(void* dict, void* value, void* key) {
    fp_dict_setindex_bang(dict, value, key);
}

void* nbjit_symbol_from_cstr(const char* str) {
    return fp_symbol_from_cstr(str);
}

void* nbjit_global_get(const char* name) {
    return fp_global_get(name);
}

void nbjit_global_set_int64(const char* name, int64_t value) {
    fp_global_set_int64(name, value);
}

void nbjit_global_set_float64(const char* name, double value) {
    fp_global_set_float64(name, value);
}

void nbjit_global_set_object(const char* name, void* value) {
    fp_global_set_object(name, value);
}

void* nbjit_box_int64(int64_t val) {
    return fp_box_int64(val);
}

void* nbjit_box_float64(double val) {
    return fp_box_float64(val);
}

int64_t nbjit_unbox_int64(void* ptr) {
    return fp_unbox_int64(ptr);
}

double nbjit_unbox_float64(void* ptr) {
    return fp_unbox_float64(ptr);
}

// Array stub implementations
void* nbjit_array_new_float64(int64_t n) {
    return fp_array_new_float64(n);
}

void* nbjit_array_new_int64(int64_t n) {
    return fp_array_new_int64(n);
}

double nbjit_array_getindex_float64(void* arr, int64_t idx) {
    return ((double(*)(void*, int64_t))fp_array_getindex_float64)(arr, idx);
}

int64_t nbjit_array_getindex_int64(void* arr, int64_t idx) {
    return ((int64_t(*)(void*, int64_t))fp_array_getindex_int64)(arr, idx);
}

void nbjit_array_setindex_float64(void* arr, double val, int64_t idx) {
    ((void(*)(void*, double, int64_t))fp_array_setindex_float64)(arr, val, idx);
}

void nbjit_array_setindex_int64(void* arr, int64_t val, int64_t idx) {
    ((void(*)(void*, int64_t, int64_t))fp_array_setindex_int64)(arr, val, idx);
}

int64_t nbjit_array_length(void* arr) {
    return ((int64_t(*)(void*))fp_array_length)(arr);
}

void* nbjit_array_push_float64(void* arr, double val) {
    return ((void*(*)(void*, double))fp_array_push_float64)(arr, val);
}

void* nbjit_array_push_int64(void* arr, int64_t val) {
    return ((void*(*)(void*, int64_t))fp_array_push_int64)(arr, val);
}

void* nbjit_zeros(int64_t n) {
    return ((void*(*)(int64_t))fp_zeros)(n);
}

void* nbjit_ones(int64_t n) {
    return ((void*(*)(int64_t))fp_ones)(n);
}

// External function registration
void nbjit_register_external_func(const char* name, void* func_ptr) {
    if (num_external_funcs >= MAX_EXTERNAL_FUNCS) {
        return; // TODO: error handling
    }
    strncpy(external_funcs[num_external_funcs].name, name, 127);
    external_funcs[num_external_funcs].name[127] = '\0';
    external_funcs[num_external_funcs].func_ptr = func_ptr;
    num_external_funcs++;
}

void* nbjit_lookup_external_func(const char* name) {
    for (int i = 0; i < num_external_funcs; i++) {
        if (strcmp(external_funcs[i].name, name) == 0) {
            return external_funcs[i].func_ptr;
        }
    }
    return 0;
}

void nbjit_clear_external_funcs(void) {
    num_external_funcs = 0;
}
