#ifndef MLQJS_HOST_QUEUE_H
#define MLQJS_HOST_QUEUE_H
/*
 * qjs/c/qjs_host_queue.h — bounded plain-C host request queue (§23.1).
 * A JavaScript host callback validates args, accounts the operation, creates
 * a Promise, stores duplicated resolver functions in the promise table, and
 * enqueues a bounded plain-C request here. The callback performs NO I/O.
 * OCaml drains the queue, performs the authorized/metered operation, and
 * resolves/rejects the Promise.
 */
#include <stddef.h>
#include <stdint.h>

#define MLQJS_MAX_OP_LEN 64
#define MLQJS_QUEUE_CAP  256   /* bounded; overflow -> reject as overload */

typedef struct {
    uint64_t id;                         /* request id = promise-table slot */
    char operation[MLQJS_MAX_OP_LEN];    /* e.g. "kv.get", "clock.monotonic" */
    char *payload;                       /* malloc'd canonical JSON args */
    size_t payload_len;
} mlqjs_request;

typedef struct {
    mlqjs_request slots[MLQJS_QUEUE_CAP];
    size_t head;      /* next slot to drain (OCaml side) */
    size_t tail;      /* next slot to fill (C side) */
    size_t count;     /* live requests */
    uint64_t next_id; /* monotonic request id */
} mlqjs_host_queue;

void mlqjs_host_queue_init(mlqjs_host_queue *q);
void mlqjs_host_queue_destroy(mlqjs_host_queue *q);

/* Push a request. Returns the assigned id (>=1) on success, or 0 if the queue
 * is full (caller rejects the Promise as overload). Takes ownership of
 * [payload] (freed when the request is taken or the queue is destroyed). */
uint64_t mlqjs_host_queue_push(mlqjs_host_queue *q, const char *op,
                                char *payload, size_t payload_len);

/* Take the next request (OCaml side). Returns 1 and fills [out] on success,
 * 0 if empty. The caller inherits ownership of [out.payload]. */
int mlqjs_host_queue_take(mlqjs_host_queue *q, mlqjs_request *out);

/* Live request count. */
size_t mlqjs_host_queue_count(const mlqjs_host_queue *q);

#endif
