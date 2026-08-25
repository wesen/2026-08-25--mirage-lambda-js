#ifndef MLQJS_ALLOCATOR_H
#define MLQJS_ALLOCATOR_H
/*
 * qjs/c/qjs_allocator.h — invocation-owned allocator for QuickJS (§5.4).
 * See qjs_allocator.c for the contract.
 */
#include <stddef.h>

typedef struct {
    size_t limit;       /* js_heap_bytes */
    size_t used;        /* current bytes (diagnostic) */
    size_t peak;        /* peak bytes (diagnostic) */
    size_t alloc_count; /* number of live allocations (diagnostic) */
} mlqjs_alloc_state;

const void *mlqjs_alloc_functions(void);  /* returns const JSMallocFunctions* */
mlqjs_alloc_state *mlqjs_alloc_state_new(size_t heap_limit);
void mlqjs_alloc_state_free(mlqjs_alloc_state *st);
size_t mlqjs_alloc_used(const mlqjs_alloc_state *st);
size_t mlqjs_alloc_peak(const mlqjs_alloc_state *st);
size_t mlqjs_alloc_count(const mlqjs_alloc_state *st);

#endif
