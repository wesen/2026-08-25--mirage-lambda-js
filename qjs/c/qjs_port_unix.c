/*
 * qjs/c/qjs_port_unix.c — Unix implementation of the freestanding platform
 * boundary (mirage_lambda_service_implementation_guide.md §21.4).
 *
 * This is the development/debug target. It uses real monotonic time, wall
 * time, /dev/urandom, and a normal abort. It is NOT linked into any Mirage
 * unikernel.
 *
 * NOTE: scaffolded in Phase 0. The QuickJS engine core is vendored and
 * linked in Phase 2 (qjs/c/qjs_stubs.c, qjs/c/qjs_allocator.c). Until then
 * this file compiles standalone to prove the platform boundary is sound.
 */
#include "qjs_port.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

uint64_t mlqjs_monotonic_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        /* Monotonic clock is required for engine timing; treat failure as fatal. */
        mlqjs_abort("mlqjs_monotonic_ns: clock_gettime failed");
    }
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

int64_t mlqjs_wall_time_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        return 0;
    }
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)ts.tv_nsec / 1000000LL;
}

void mlqjs_random_bytes(void *dst, size_t len)
{
    if (len == 0)
        return;
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        mlqjs_abort("mlqjs_random_bytes: cannot open /dev/urandom");
    }
    unsigned char *p = (unsigned char *)dst;
    size_t got = 0;
    while (got < len) {
        ssize_t r = read(fd, p + got, len - got);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            close(fd);
            mlqjs_abort("mlqjs_random_bytes: read failed");
        }
        if (r == 0) {
            close(fd);
            mlqjs_abort("mlqjs_random_bytes: unexpected EOF");
        }
        got += (size_t)r;
    }
    close(fd);
}

void mlqjs_abort(const char *reason)
{
    fprintf(stderr, "mlqjs_abort: %s\n", reason ? reason : "(no reason)");
    fflush(stderr);
    abort();
}
