/*
 * qjs/c/qjs_stubs.c — real OCaml FFI for the QuickJS engine (§22.2, §22.4,
 * §24, §23). OCaml drives C; C never re-enters OCaml during async I/O.
 *
 * Only this file (and qjs_allocator.c / qjs_host_queue.c) include quickjs.h.
 * The OCaml side never sees a JSValue or a raw pointer.
 *
 * The handle is an integer: (generation << 16) | index into a C-side table of
 * mlqjs_runtime* (§22.2 option 2). Generation counters reject stale
 * use-after-free from OCaml.
 */
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/callback.h>

#include "qjs_port.h"
#include "qjs_allocator.h"
#include "qjs_host_queue.h"
#include <quickjs.h>
#include <stdlib.h>
#include <string.h>

#define MLQJS_TABLE_CAP 64
#define MLQJS_GEN_SHIFT 16
#define MLQJS_INDEX_MASK ((1 << MLQJS_GEN_SHIFT) - 1)

typedef enum {
    MLQJS_REASON_NONE = 0,
    MLQJS_REASON_DEADLINE,
    MLQJS_REASON_CPU,
    MLQJS_REASON_CANCEL
} mlqjs_interrupt_reason;

#define MLQJS_MAX_MODULES 256
#define MLQJS_MAX_PATH_LEN 512

typedef struct {
    char path[MLQJS_MAX_PATH_LEN];
    char *source;     /* malloc'd source bytes */
    size_t source_len;
} mlqjs_module_entry;

typedef struct {
    JSRuntime *rt;
    JSContext *ctx;
    mlqjs_alloc_state *a_state;     /* invocation-owned counter (§5.4) */
    mlqjs_host_queue requests;      /* bounded host request queue (§23.1) */
    mlqjs_module_entry modules[MLQJS_MAX_MODULES]; /* bundle module map (§24.4) */
    int module_count;
    uint64_t deadline_ns;
    uint64_t cpu_budget_ns;
    uint64_t engine_start_ns;
    int cancelled;
    int terminal;
    mlqjs_interrupt_reason interrupt_reason;
    int gen;
} mlqjs_runtime;

static mlqjs_runtime *g_table[MLQJS_TABLE_CAP];
static int g_generation[MLQJS_TABLE_CAP];

/* ---- module loader callback (§24.4) ---- */
/* Find a module by name in the bundle map and compile it. The module source
 * comes from the already-validated in-memory bundle; the loader never does I/O. */
static JSModuleDef *mlqjs_module_loader(JSContext *ctx,
                                        const char *module_name, void *opaque)
{
    mlqjs_runtime *q = (mlqjs_runtime *)opaque;
    for (int i = 0; i < q->module_count; i++) {
        if (strcmp(q->modules[i].path, module_name) == 0) {
            JSValue val = JS_Eval(ctx, q->modules[i].source, q->modules[i].source_len,
                                 module_name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
            if (JS_IsException(val))
                return NULL;
            JSModuleDef *m = (JSModuleDef *)JS_VALUE_GET_PTR(val);
            JS_FreeValue(ctx, val);  /* free the value wrapper; module stays alive (held by ctx module list) */
            return m;
        }
    }
    /* module not found — throw a JS TypeError */
    JS_ThrowReferenceError(ctx, "could not load module '%s'", module_name);
    return NULL;
}

/* simple normalize: just duplicate the name (relative imports handled by QuickJS) */
static char *mlqjs_module_normalize(JSContext *ctx,
                                    const char *base, const char *name, void *opaque)
{
    (void)base; (void)opaque;
    char *ret = js_malloc(ctx, strlen(name) + 1);
    if (!ret) return NULL;
    strcpy(ret, name);
    return ret;
}

/* ---- interrupt handler (§24.2) ---- */
static int mlqjs_interrupt(JSRuntime *rt, void *opaque)
{
    (void)rt;
    mlqjs_runtime *q = (mlqjs_runtime *)opaque;
    if (q->cancelled) {
        q->interrupt_reason = MLQJS_REASON_CANCEL;
        return 1;
    }
    uint64_t now = mlqjs_monotonic_ns();
    if (q->deadline_ns && now >= q->deadline_ns) {
        q->interrupt_reason = MLQJS_REASON_DEADLINE;
        return 1;
    }
    if (q->cpu_budget_ns) {
        uint64_t used = now - q->engine_start_ns;
        if (used >= q->cpu_budget_ns) {
            q->interrupt_reason = MLQJS_REASON_CPU;
            return 1;
        }
    }
    return 0;
}

/* ---- Promise rejection tracker (§34.2 step 9) ---- */
static void mlqjs_rejection_tracker(JSContext *ctx, JSValueConst promise,
                                   JSValueConst reason, int is_handled, void *opaque)
{
    (void)ctx; (void)promise; (void)reason;
    mlqjs_runtime *q = (mlqjs_runtime *)opaque;
    if (!is_handled) {
        q->terminal = 1;
    }
}

/* ---- handle table ---- */
static int table_alloc(mlqjs_runtime *q)
{
    for (int i = 0; i < MLQJS_TABLE_CAP; i++) {
        if (g_table[i] == NULL) {
            g_table[i] = q;
            g_generation[i] = (g_generation[i] + 1) & 0xffff;
            if (g_generation[i] == 0) g_generation[i] = 1;
            q->gen = g_generation[i];
            return (g_generation[i] << MLQJS_GEN_SHIFT) | i;
        }
    }
    return 0;
}

static mlqjs_runtime *table_get(value v_handle, int *out_index)
{
    int h = Int_val(v_handle);
    int index = h & MLQJS_INDEX_MASK;
    int gen = h >> MLQJS_GEN_SHIFT;
    if (index < 0 || index >= MLQJS_TABLE_CAP) return NULL;
    if (g_table[index] == NULL || g_table[index]->gen != gen) return NULL;
    if (out_index) *out_index = index;
    return g_table[index];
}

/* ---- limits blob decoder (limits_blob from qjs_engine.ml) ---- */
static int decode_limits(const char *s, size_t *heap, size_t *stack,
                         uint64_t *timeout_ns, uint64_t *cpu_ns)
{
    long vals[11] = {0};
    int n = 0;
    const char *p = s;
    while (*p && n < 11) {
        char *end;
        vals[n++] = strtol(p, &end, 10);
        if (end == p) break;
        p = end;
        if (*p == '|') p++;
    }
    *heap = (size_t)vals[0];
    *stack = (size_t)vals[2];
    *timeout_ns = (uint64_t)vals[3] * 1000000ULL;
    *cpu_ns = (uint64_t)vals[4] * 1000000ULL;
    return 0;
}

/* ---- [mlqjs_create] : bytes -> int handle ---- */
CAMLprim value mlqjs_create(value v_limits)
{
    CAMLparam1(v_limits);
    mlqjs_runtime *q = (mlqjs_runtime *)calloc(1, sizeof(*q));
    if (!q) caml_failwith("mlqjs_create: out of memory");

    size_t heap = 0, stack = 0;
    uint64_t timeout_ns = 0, cpu_ns = 0;
    decode_limits(String_val(v_limits), &heap, &stack, &timeout_ns, &cpu_ns);

    q->a_state = mlqjs_alloc_state_new(heap);
    q->deadline_ns = timeout_ns ? (mlqjs_monotonic_ns() + timeout_ns) : 0;
    q->cpu_budget_ns = cpu_ns;
    q->engine_start_ns = mlqjs_monotonic_ns();
    mlqjs_host_queue_init(&q->requests);

    /* 2. allocator: use the default JS_NewRuntime for the Phase 2 probe. The
     * custom allocator (JS_NewRuntime2) is a Phase 8 accounting concern (§5.4).
     * JS_SetMemoryLimit works with the default allocator's size tracking. */
    q->rt = JS_NewRuntime();
    if (!q->rt) { free(q->a_state); free(q); caml_failwith("mlqjs_create: JS_NewRuntime"); }

    JS_SetMemoryLimit(q->rt, heap);
    JS_SetMaxStackSize(q->rt, stack);
    JS_SetInterruptHandler(q->rt, mlqjs_interrupt, q);
    JS_SetCanBlock(q->rt, 0);
    JS_SetHostPromiseRejectionTracker(q->rt, mlqjs_rejection_tracker, q);

    q->ctx = JS_NewContextRaw(q->rt);
    if (!q->ctx) { JS_FreeRuntime(q->rt); free(q->a_state); free(q); caml_failwith("mlqjs_create: JS_NewContextRaw"); }
    JS_AddIntrinsicBaseObjects(q->ctx);
    JS_AddIntrinsicEval(q->ctx);
    JS_AddIntrinsicJSON(q->ctx);
    JS_AddIntrinsicRegExp(q->ctx);
    JS_AddIntrinsicMapSet(q->ctx);
    JS_AddIntrinsicTypedArrays(q->ctx);
    JS_AddIntrinsicPromise(q->ctx);
    JS_SetContextOpaque(q->ctx, q);

    /* 9. module loader (§24.1 step 9, §24.4). Use the default normalizer (NULL)
     * which resolves ./ and ../ relative imports; the custom normalizer that
     * handles cap: and root-escape is a later step. */
    JS_SetModuleLoaderFunc(q->rt, NULL, mlqjs_module_loader, q);
    q->module_count = 0;

    int handle = table_alloc(q);
    if (!handle) {
        JS_FreeContext(q->ctx); JS_FreeRuntime(q->rt);
        mlqjs_host_queue_destroy(&q->requests); free(q->a_state); free(q);
        caml_failwith("mlqjs_create: handle table full");
    }
    CAMLreturn(Val_int(handle));
}

/* ---- [mlqjs_destroy] : int -> unit (idempotent) ---- */
CAMLprim value mlqjs_destroy(value v_handle)
{
    CAMLparam1(v_handle);
    int index = -1;
    mlqjs_runtime *q = table_get(v_handle, &index);
    if (q && index >= 0) {
        g_table[index] = NULL;
        if (q->ctx) JS_FreeContext(q->ctx);
        if (q->rt) JS_FreeRuntime(q->rt);
        mlqjs_host_queue_destroy(&q->requests);
        mlqjs_alloc_state_free(q->a_state);
        /* free module sources (§24.4) */
        for (int i = 0; i < q->module_count; i++)
            free(q->modules[i].source);
        free(q);
    }
    CAMLreturn(Val_unit);
}

/* ---- [mlqjs_eval] : int -> string -> bool ---- */
CAMLprim value mlqjs_eval(value v_handle, value v_src)
{
    CAMLparam2(v_handle, v_src);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_eval: stale handle");
    JSValue r = JS_Eval(q->ctx, String_val(v_src), caml_string_length(v_src),
                        "<eval>", JS_EVAL_TYPE_GLOBAL);
    int is_exc = JS_IsException(r);
    if (is_exc) { JSValue e = JS_GetException(q->ctx); JS_FreeValue(q->ctx, e); }
    JS_FreeValue(q->ctx, r);
    CAMLreturn(Val_bool(is_exc));
}

/* ---- [mlqjs_eval_int] : int -> string -> int ---- */
CAMLprim value mlqjs_eval_int(value v_handle, value v_src)
{
    CAMLparam2(v_handle, v_src);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_eval_int: stale handle");
    JSValue r = JS_Eval(q->ctx, String_val(v_src), caml_string_length(v_src),
                        "<eval>", JS_EVAL_TYPE_GLOBAL);
    int32_t out = 0;
    if (JS_IsException(r)) {
        JSValue e = JS_GetException(q->ctx); JS_FreeValue(q->ctx, e); JS_FreeValue(q->ctx, r);
        caml_failwith("mlqjs_eval_int: eval threw");
    }
    if (JS_ToInt32(q->ctx, &out, r) != 0) {
        JS_FreeValue(q->ctx, r); caml_failwith("mlqjs_eval_int: not an int");
    }
    JS_FreeValue(q->ctx, r);
    CAMLreturn(Val_int(out));
}

/* ---- [mlqjs_set_module] : int -> string -> string -> unit
 * Store a bundle module (path, source) in the runtime for the module loader. ---- */
CAMLprim value mlqjs_set_module(value v_handle, value v_path, value v_src)
{
    CAMLparam3(v_handle, v_path, v_src);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_set_module: stale handle");
    if (q->module_count >= MLQJS_MAX_MODULES) caml_failwith("mlqjs_set_module: too many modules");
    const char *path = String_val(v_path);
    size_t path_len = caml_string_length(v_path);
    if (path_len >= MLQJS_MAX_PATH_LEN) caml_failwith("mlqjs_set_module: path too long");
    memcpy(q->modules[q->module_count].path, path, path_len);
    q->modules[q->module_count].path[path_len] = '\0';
    size_t src_len = caml_string_length(v_src);
    q->modules[q->module_count].source = malloc(src_len ? src_len : 1);
    if (!q->modules[q->module_count].source) caml_failwith("mlqjs_set_module: oom");
    memcpy(q->modules[q->module_count].source, String_val(v_src), src_len);
    q->modules[q->module_count].source_len = src_len;
    q->module_count++;
    CAMLreturn(Val_unit);
}

/* ---- [mlqjs_eval_module] : int -> string -> bool
 * Evaluate a module entrypoint (by path). Returns true if exception. ---- */
CAMLprim value mlqjs_eval_module(value v_handle, value v_path)
{
    CAMLparam2(v_handle, v_path);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_eval_module: stale handle");
    /* find the entrypoint in the module map */
    const char *path = String_val(v_path);
    for (int i = 0; i < q->module_count; i++) {
        if (strcmp(q->modules[i].path, path) == 0) {
            JSValue val = JS_Eval(q->ctx, q->modules[i].source, q->modules[i].source_len,
                                  path, JS_EVAL_TYPE_MODULE);
            int is_exc = JS_IsException(val);
            if (is_exc) { JSValue e = JS_GetException(q->ctx); JS_FreeValue(q->ctx, e); }
            JS_FreeValue(q->ctx, val);
            CAMLreturn(Val_bool(is_exc));
        }
    }
    caml_failwith("mlqjs_eval_module: entrypoint not found");
}

/* ---- [mlqjs_pump] : int -> int -> int ---- */
CAMLprim value mlqjs_pump(value v_handle, value v_max_jobs)
{
    CAMLparam2(v_handle, v_max_jobs);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_pump: stale handle");
    int max_jobs = Int_val(v_max_jobs);
    int ran = 0;
    for (int i = 0; i < max_jobs; i++) {
        if (q->cancelled) CAMLreturn(Val_int(2));
        if (!JS_IsJobPending(q->rt)) break;
        JSContext *ctx2;
        int rc = JS_ExecutePendingJob(q->rt, &ctx2);
        if (rc == 0) break;
        if (rc < 0) { JSValue e = JS_GetException(ctx2); JS_FreeValue(ctx2, e); }
        ran = 1;
    }
    if (q->interrupt_reason != MLQJS_REASON_NONE) CAMLreturn(Val_int(2));
    CAMLreturn(Val_int(ran ? 1 : 0));
}

/* ---- [mlqjs_cancel] : int -> int -> unit ---- */
CAMLprim value mlqjs_cancel(value v_handle, value v_reason)
{
    CAMLparam2(v_handle, v_reason); (void)v_reason;
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (q) q->cancelled = 1;
    CAMLreturn(Val_unit);
}

/* ---- [mlqjs_take_requests] : int -> (int64 * string * string) array ---- */
CAMLprim value mlqjs_take_requests(value v_handle)
{
    CAMLparam1(v_handle);
    CAMLlocal2(v_arr, v_tuple);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_take_requests: stale handle");
    size_t n = mlqjs_host_queue_count(&q->requests);
    v_arr = caml_alloc(n, 0);
    for (size_t i = 0; i < n; i++) {
        mlqjs_request r;
        if (!mlqjs_host_queue_take(&q->requests, &r)) break;
        v_tuple = caml_alloc(3, 0);
        Store_field(v_tuple, 0, caml_copy_int64((int64_t)r.id));
        Store_field(v_tuple, 1, caml_copy_string(r.operation));
        Store_field(v_tuple, 2, caml_alloc_initialized_string(r.payload_len, r.payload));
        free(r.payload);
        Store_field(v_arr, i, v_tuple);
    }
    CAMLreturn(v_arr);
}

/* ---- [mlqjs_host_call_count] : int -> int ---- */
CAMLprim value mlqjs_host_call_count(value v_handle)
{
    CAMLparam1(v_handle);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_host_call_count: stale handle");
    CAMLreturn(Val_int((int)mlqjs_host_queue_count(&q->requests)));
}

/* ---- [mlqjs_mem_usage] : int -> (int * int * int) ---- */
CAMLprim value mlqjs_mem_usage(value v_handle)
{
    CAMLparam1(v_handle);
    CAMLlocal1(v_tup);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_mem_usage: stale handle");
    JSMemoryUsage stats;
    JS_ComputeMemoryUsage(q->rt, &stats);
    v_tup = caml_alloc(3, 0);
    Store_field(v_tup, 0, Val_int((int)stats.memory_used_size));
    Store_field(v_tup, 1, Val_int((int)(q->a_state ? q->a_state->limit : 0)));
    Store_field(v_tup, 2, Val_int(JS_IsJobPending(q->rt) ? 1 : 0));
    CAMLreturn(v_tup);
}
