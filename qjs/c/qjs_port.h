/*
 * qjs/c/qjs_port.h — freestanding platform boundary for the Mirage Lambda
 * QuickJS port.  See mirage_lambda_service_implementation_guide.md §21.4.
 *
 * The C engine sees ONLY memory, the time needed for engine semantics, and
 * host-callback registration.  Application I/O crosses to OCaml through the
 * host request queue (qjs_host_queue.{c,h}).  QuickJS must never call the
 * Mirage network or KV stack directly through this header.
 *
 * Two implementations:
 *   qjs_port_unix.c   — Unix development (real clock + urandom + abort)
 *   qjs_port_solo5.c  — Solo5 HVT freestanding (host-supplied clock + RNG)
 */
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t monotonic_ns;
    int64_t  wall_time_ms;   /* available only when the worker is configured to see wall time */
} mlqjs_time_snapshot;

/* Monotonic nanoseconds for engine timing / deadlines. Always available. */
uint64_t mlqjs_monotonic_ns(void);

/* Wall time in milliseconds since the Unix epoch. Returns 0 when the worker
 * is not configured to see wall time — wall time must never be granted by
 * accident (§21.3). */
int64_t  mlqjs_wall_time_ms(void);

/* Cryptographic randomness sourced from the host capability, never from
 * Math.random. The caller provides a destination buffer; the implementation
 * fills exactly `len` bytes. */
void     mlqjs_random_bytes(void *dst, size_t len);

/* Deterministic abort path. Must not raise into OCaml. Used only for
 * unrecoverable engine invariants. */
void     mlqjs_abort(const char *reason);

#ifdef __cplusplus
}
#endif
