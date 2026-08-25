/*
 * qjs/c/qjs_port_solo5.c — Solo5 HVT freestanding implementation of the
 * platform boundary (mirage_lambda_service_implementation_guide.md §21.4).
 *
 * This is the production/HVT target. It has no libc beyond ocaml-solo5's
 * minimal libc, no /dev/urandom, no filesystem. Time and randomness come
 * from Mirage devices (mirage-clock, mirage-crypto entropy) supplied to the
 * worker unikernel and exposed to C through the OCaml-supplied platform
 * callbacks.
 *
 * NOTE: scaffolded in Phase 0. The Solo5 implementation requires a dedicated
 * Mirage opam switch (mirage + ocaml-solo5) and is compiled in Phase 6
 * (worker/unikernel.ml). Until then this file documents the HVT contract and
 * is NOT compiled into the Unix build.
 */
#include "qjs_port.h"

/* Supplied by the worker unikernel at boot (mirage-clock device) and stored in
 * a per-runtime platform context. Phase 6 wires these function pointers. */
typedef struct {
    uint64_t (*monotonic_ns)(void);
    int64_t  (*wall_time_ms)(void);      /* may be NULL when wall time is not granted */
    void     (*random_bytes)(void *dst, size_t len);
    void     (*abort)(const char *reason);
} mlqjs_platform;

static mlqjs_platform g_platform = { NULL, NULL, NULL, NULL };

void mlqjs_platform_init(const mlqjs_platform *p)
{
    g_platform = *p;
    /* monotonic_ns and abort are always required; randomness is required for
     * any invocation that declares the cryptographic-random capability. */
    if (g_platform.monotonic_ns == NULL || g_platform.abort == NULL) {
        g_platform.abort("mlqjs_platform_init: required callbacks missing");
    }
}

uint64_t mlqjs_monotonic_ns(void)
{
    return g_platform.monotonic_ns();
}

int64_t mlqjs_wall_time_ms(void)
{
    if (g_platform.wall_time_ms == NULL)
        return 0;   /* wall time not granted to this worker (§21.3) */
    return g_platform.wall_time_ms();
}

void mlqjs_random_bytes(void *dst, size_t len)
{
    if (g_platform.random_bytes == NULL || len == 0) {
        if (len == 0)
            return;
        g_platform.abort("mlqjs_random_bytes: no crypto capability");
    }
    g_platform.random_bytes(dst, len);
}

void mlqjs_abort(const char *reason)
{
    g_platform.abort(reason ? reason : "(no reason)");
    /* g_platform.abort is expected not to return. */
    for (;;) { }   /* should never be reached */
}
