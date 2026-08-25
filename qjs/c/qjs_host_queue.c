/*
 * qjs/c/qjs_host_queue.c — bounded plain-C host request queue (§23.1).
 * See qjs_host_queue.h for the contract. This is pure C (no QuickJS, no
 * OCaml), so it is unit-testable and portable to the Solo5 target.
 */
#include "qjs_host_queue.h"
#include "qjs_port.h"
#include <stdlib.h>
#include <string.h>

void mlqjs_host_queue_init(mlqjs_host_queue *q)
{
    memset(q, 0, sizeof(*q));
    q->next_id = 1;   /* ids start at 1; 0 means "no id / failure" */
}

void mlqjs_host_queue_destroy(mlqjs_host_queue *q)
{
    for (size_t i = 0; i < MLQJS_QUEUE_CAP; i++) {
        free(q->slots[i].payload);
        q->slots[i].payload = NULL;
    }
    memset(q, 0, sizeof(*q));
}

static void req_set(mlqjs_request *r, uint64_t id, const char *op,
                    char *payload, size_t payload_len)
{
    r->id = id;
    r->payload = payload;
    r->payload_len = payload_len;
    /* copy operation string (bounded) */
    size_t op_len = op ? strlen(op) : 0;
    if (op_len >= MLQJS_MAX_OP_LEN) op_len = MLQJS_MAX_OP_LEN - 1;
    memcpy(r->operation, op ? op : "", op_len);
    r->operation[op_len] = '\0';
}

uint64_t mlqjs_host_queue_push(mlqjs_host_queue *q, const char *op,
                                char *payload, size_t payload_len)
{
    if (q->count >= MLQJS_QUEUE_CAP) {
        free(payload);   /* take ownership then drop; avoid leak */
        return 0;        /* full -> caller rejects as overload */
    }
    size_t slot = q->tail;
    uint64_t id = q->next_id++;
    req_set(&q->slots[slot], id, op, payload, payload_len);
    q->tail = (q->tail + 1) % MLQJS_QUEUE_CAP;
    q->count++;
    return id;
}

int mlqjs_host_queue_take(mlqjs_host_queue *q, mlqjs_request *out)
{
    if (q->count == 0) return 0;
    mlqjs_request *src = &q->slots[q->head];
    /* transfer ownership of payload to the caller */
    req_set(out, src->id, src->operation, src->payload, src->payload_len);
    src->payload = NULL;
    src->payload_len = 0;
    src->id = 0;
    q->head = (q->head + 1) % MLQJS_QUEUE_CAP;
    q->count--;
    return 1;
}

size_t mlqjs_host_queue_count(const mlqjs_host_queue *q)
{
    return q->count;
}
