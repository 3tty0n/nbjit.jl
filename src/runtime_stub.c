/*
 * Runtime stub library for nbjit
 * This file provides C-callable stubs that forward to Julia runtime functions
 */

#include <stdint.h>

// External declarations for Julia runtime functions
// These will be resolved via @cfunction when the library is loaded

extern void* nbjit_dict_new_impl(void);
extern void* nbjit_dict_getindex_impl(void*, void*);
extern void nbjit_dict_setindex_impl(void*, void*, void*);
extern void* nbjit_symbol_from_cstr_impl(const char*);
extern void* nbjit_box_int64_impl(int64_t);
extern void* nbjit_box_float64_impl(double);
extern int64_t nbjit_unbox_int64_impl(void*);
extern double nbjit_unbox_float64_impl(void*);

// Forward declarations for the stubs
void* nbjit_dict_new(void);
void* nbjit_dict_getindex(void* dict, void* key);
void nbjit_dict_setindex_bang(void* dict, void* value, void* key);
void* nbjit_symbol_from_cstr(const char* str);
void* nbjit_box_int64(int64_t val);
void* nbjit_box_float64(double val);
int64_t nbjit_unbox_int64(void* ptr);
double nbjit_unbox_float64(void* ptr);

// Global function pointers that will be set by Julia
static void* (*fp_dict_new)(void) = 0;
static void* (*fp_dict_getindex)(void*, void*) = 0;
static void (*fp_dict_setindex_bang)(void*, void*, void*) = 0;
static void* (*fp_symbol_from_cstr)(const char*) = 0;
static void* (*fp_box_int64)(int64_t) = 0;
static void* (*fp_box_float64)(double) = 0;
static int64_t (*fp_unbox_int64)(void*) = 0;
static double (*fp_unbox_float64)(void*) = 0;

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
