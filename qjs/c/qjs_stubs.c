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

/* ---- [mlqjs_eval_string] : int -> string -> string
 * Eval an expression that should produce a string; return it. Raises on exception. ---- */
CAMLprim value mlqjs_eval_string(value v_handle, value v_src)
{
    CAMLparam2(v_handle, v_src);
    CAMLlocal1(v_result);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_eval_string: stale handle");
    JSValue r = JS_Eval(q->ctx, String_val(v_src), caml_string_length(v_src),
                        "<eval>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(r)) {
        JSValue e = JS_GetException(q->ctx); JS_FreeValue(q->ctx, e); JS_FreeValue(q->ctx, r);
        caml_failwith("mlqjs_eval_string: eval threw");
    }
    const char *s = JS_ToCString(q->ctx, r);
    if (!s) { JS_FreeValue(q->ctx, r); caml_failwith("mlqjs_eval_string: not a string-convertible"); }
    v_result = caml_copy_string(s);
    JS_FreeCString(q->ctx, s);
    JS_FreeValue(q->ctx, r);
    CAMLreturn(v_result);
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

/* ---- Promise bridge (§23.1, §34.2 steps 4-5, 9) ----
 *
 * A simple host callback `host.later(x)` that creates a Promise, stores the
 * resolving functions, and enqueues a host request. OCaml drains the queue,
 * computes the result, and calls mlqjs_resolve to settle the Promise. */

/* promise table: maps request id -> (resolve, reject) JSValues */
#define MLQJS_MAX_PROMISES 256
typedef struct {
    uint64_t id;
    JSValue resolve;
    JSValue reject;
    int in_use;
} mlqjs_promise_slot;

static mlqjs_promise_slot g_promises[MLQJS_MAX_PROMISES];

static int promise_insert(JSContext *ctx, JSValue resolve, JSValue reject, uint64_t id)
{
    for (int i = 0; i < MLQJS_MAX_PROMISES; i++) {
        if (!g_promises[i].in_use) {
            g_promises[i].id = id;
            g_promises[i].resolve = resolve;
            g_promises[i].reject = reject;
            g_promises[i].in_use = 1;
            return 1;
        }
    }
    JS_FreeValue(ctx, resolve);
    JS_FreeValue(ctx, reject);
    return 0;  /* table full */
}

static mlqjs_promise_slot *promise_find(uint64_t id)
{
    for (int i = 0; i < MLQJS_MAX_PROMISES; i++)
        if (g_promises[i].in_use && g_promises[i].id == id)
            return &g_promises[i];
    return NULL;
}

static void promise_remove(JSContext *ctx, mlqjs_promise_slot *s)
{
    JS_FreeValue(ctx, s->resolve);
    JS_FreeValue(ctx, s->reject);
    s->in_use = 0;
}

/* the host.later(x) C callback: creates a Promise, enqueues a host request */
static JSValue mlqjs_host_later(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    (void)this_val;
    if (argc < 1)
        return JS_ThrowTypeError(ctx, "host.later expects 1 argument");
    mlqjs_runtime *q = (mlqjs_runtime *)JS_GetContextOpaque(ctx);

    /* extract the argument as a JSON string (for simplicity, use int) */
    int32_t arg = 0;
    if (JS_ToInt32(ctx, &arg, argv[0]) != 0)
        return JS_ThrowTypeError(ctx, "host.later expects an int");

    /* create a Promise and get resolving functions */
    JSValue resolving[2] = { JS_UNDEFINED, JS_UNDEFINED };
    JSValue promise = JS_NewPromiseCapability(ctx, resolving);
    if (JS_IsException(promise))
        return promise;

    /* enqueue a host request */
    char payload[32];
    int plen = snprintf(payload, sizeof(payload), "%d", arg);
    char *payload_copy = malloc(plen + 1);
    if (!payload_copy) { JS_FreeValue(ctx, promise); JS_FreeValue(ctx, resolving[0]); JS_FreeValue(ctx, resolving[1]); return JS_ThrowTypeError(ctx, "oom"); }
    memcpy(payload_copy, payload, plen + 1);
    uint64_t id = mlqjs_host_queue_push(&q->requests, "host.later", payload_copy, plen);
    if (id == 0) {
        JS_FreeValue(ctx, promise);
        JS_FreeValue(ctx, resolving[0]);
        JS_FreeValue(ctx, resolving[1]);
        return JS_ThrowInternalError(ctx, "host request queue full");
    }

    /* store resolving functions in the promise table */
    if (!promise_insert(ctx, resolving[0], resolving[1], id))
        return JS_ThrowInternalError(ctx, "promise table full");

    return promise;
}

/* the generic host.rpc(op, arg) C callback: creates a Promise, enqueues a
 * host request with operation name + JSON arg as payload. The OCaml side
 * dispatches based on the operation string (§23.1, §37.1). */
static JSValue mlqjs_host_rpc(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    (void)this_val;
    if (argc < 2)
        return JS_ThrowTypeError(ctx, "host.rpc expects (op, arg)");
    mlqjs_runtime *q = (mlqjs_runtime *)JS_GetContextOpaque(ctx);

    /* extract operation string */
    const char *op = JS_ToCString(ctx, argv[0]);
    if (!op) return JS_ThrowTypeError(ctx, "host.rpc: op must be a string");

    /* extract arg as JSON string */
    JSValue json_val = JS_JSONStringify(ctx, argv[1], JS_UNDEFINED, JS_UNDEFINED);
    const char *arg_json = NULL;
    if (!JS_IsException(json_val)) {
        arg_json = JS_ToCString(ctx, json_val);
        JS_FreeValue(ctx, json_val);
    }
    if (!arg_json) { JS_FreeCString(ctx, op); return JS_ThrowTypeError(ctx, "host.rpc: bad arg"); }

    /* create a Promise */
    JSValue resolving[2] = { JS_UNDEFINED, JS_UNDEFINED };
    JSValue promise = JS_NewPromiseCapability(ctx, resolving);
    if (JS_IsException(promise)) { JS_FreeCString(ctx, op); JS_FreeCString(ctx, arg_json); return promise; }

    /* enqueue: payload = "op\narg_json" (newline-delimited for easy parsing) */
    size_t op_len = strlen(op);
    size_t arg_len = strlen(arg_json);
    size_t plen = op_len + 1 + arg_len;
    char *payload = malloc(plen + 1);
    if (!payload) { JS_FreeCString(ctx, op); JS_FreeCString(ctx, arg_json); JS_FreeValue(ctx, promise); JS_FreeValue(ctx, resolving[0]); JS_FreeValue(ctx, resolving[1]); return JS_ThrowInternalError(ctx, "oom"); }
    memcpy(payload, op, op_len);
    payload[op_len] = '\n';
    memcpy(payload + op_len + 1, arg_json, arg_len);
    payload[plen] = '\0';
    JS_FreeCString(ctx, op);
    JS_FreeCString(ctx, arg_json);

    uint64_t id = mlqjs_host_queue_push(&q->requests, "host.rpc", payload, plen);
    if (id == 0) { JS_FreeValue(ctx, promise); JS_FreeValue(ctx, resolving[0]); JS_FreeValue(ctx, resolving[1]); return JS_ThrowInternalError(ctx, "queue full"); }

    if (!promise_insert(ctx, resolving[0], resolving[1], id))
        return JS_ThrowInternalError(ctx, "promise table full");

    return promise;
}

/* install the host object with host.later() and host.rpc() */
static void mlqjs_install_host_obj(JSContext *ctx)
{
    JSValue host = JS_NewObject(ctx);
    JSValue later_fn = JS_NewCFunction(ctx, mlqjs_host_later, "later", 1);
    JSValue rpc_fn = JS_NewCFunction(ctx, mlqjs_host_rpc, "rpc", 2);
    JS_SetPropertyStr(ctx, host, "later", later_fn);
    JS_SetPropertyStr(ctx, host, "rpc", rpc_fn);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "host", host);
    JS_FreeValue(ctx, global);
}

/* ---- [mlqjs_resolve] : int -> int64 -> string -> unit
 * Resolve a host Promise by request id with a JSON result string. ---- */
CAMLprim value mlqjs_resolve(value v_handle, value v_id, value v_result)
{
    CAMLparam3(v_handle, v_id, v_result);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_resolve: stale handle");
    uint64_t id = Int64_val(v_id);
    mlqjs_promise_slot *s = promise_find(id);
    if (!s) CAMLreturn(Val_unit);  /* stale/unknown id — ignore */
    /* parse the result as JSON and call the resolve function */
    const char *json = String_val(v_result);
    size_t json_len = caml_string_length(v_result);
    JSValue val = JS_ParseJSON(q->ctx, json, json_len, "<result>");
    if (JS_IsException(val)) {
        JSValue err = JS_NewString(q->ctx, "bad result JSON");
        JS_Call(q->ctx, s->reject, JS_UNDEFINED, 1, &err);
        JS_FreeValue(q->ctx, err);
    } else {
        JSValue ret = JS_Call(q->ctx, s->resolve, JS_UNDEFINED, 1, &val);
        JS_FreeValue(q->ctx, ret);
        JS_FreeValue(q->ctx, val);
    }
    promise_remove(q->ctx, s);
    CAMLreturn(Val_unit);
}

/* ---- [mlqjs_has_unhandled_rejection] : int -> bool (§34.2 step 9) ---- */
CAMLprim value mlqjs_has_unhandled_rejection(value v_handle)
{
    CAMLparam1(v_handle);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_has_unhandled_rejection: stale handle");
    CAMLreturn(Val_bool(q->terminal));
}

/* ---- [mlqjs_install_host] : int -> unit (install host.later) ---- */
CAMLprim value mlqjs_install_host(value v_handle)
{
    CAMLparam1(v_handle);
    mlqjs_runtime *q = table_get(v_handle, NULL);
    if (!q) caml_failwith("mlqjs_install_host: stale handle");
    mlqjs_install_host_obj(q->ctx);
    CAMLreturn(Val_unit);
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
