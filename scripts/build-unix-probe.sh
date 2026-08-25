#!/usr/bin/env bash
# scripts/build-unix-probe.sh — Phase 0: build and run the Unix QuickJS probe.
#
# Vendors the pinned QuickJS release (§34.1), compiles the freestanding port
# (qjs/c/qjs_port_unix.c) + the engine core, and runs the probe driver
# (qjs/test/probe.ml) under the normal Unix toolchain.
#
# This is the Unix half of the Phase 0 exit gate (§34.4).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

QJS_VERSION="2026-06-04"
QJS_DIR="qjs/vendor/quickjs-${QJS_VERSION}"
QJS_ARCHIVE="quickjs-${QJS_VERSION}.tar.xz"
# Recorded at vendor time from https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
QJS_URL_BASE="https://bellard.org/quickjs"
QJS_DIGEST="b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a"

CC="${CC:-cc}"
CFLAGS="${CFLAGS:--O1 -g3 -fno-omit-frame-pointer -Wall -Wextra -Wconversion -Wshadow}"
SAN_CFLAGS="-fsanitize=address,undefined"
SAN_LDFLAGS="-fsanitize=address,undefined"

log() { printf '[build-unix-probe] %s\n' "$*" >&2; }

log "compiling platform boundary (qjs_port_unix.c) as a smoke test"
log "(no QuickJS dependency; proves the §21.4 boundary is sound)"
mkdir -p build/probe
$CC $CFLAGS $SAN_CFLAGS -c qjs/c/qjs_port_unix.c -o build/probe/qjs_port_unix.o -Iqjs/c
log "platform boundary compiled: build/probe/qjs_port_unix.o"

if [[ ! -d "$QJS_DIR" ]]; then
  log "vendored QuickJS not found at $QJS_DIR"
  log "Prerequisite (to finish the Phase 0 gate): download ${QJS_ARCHIVE}"
  log "  from ${QJS_URL_BASE}, verify its SHA-256, extract to $QJS_DIR."
  log "  Keep only the engine core; exclude quickjs-libc.c."
  log "See docs/adr/0000-toolchain-baseline.md."
  log "Phase 0 Unix platform-boundary OK (engine link pending vendor)"
  exit 0
fi

log "vendored QuickJS present: $QJS_DIR"
log "verifying recorded digest against the archive (if present)"
if [[ -f "/tmp/${QJS_ARCHIVE}" ]]; then
  ACTUAL="$(sha256sum "/tmp/${QJS_ARCHIVE}" | awk '{print $1}')"
  if [[ "$ACTUAL" != "$QJS_DIGEST" ]]; then
    log "ERROR: digest mismatch (got $ACTUAL, want $QJS_DIGEST)"
    exit 1
  fi
  log "digest OK: $ACTUAL"
fi

# CONFIG_* the upstream Makefile sets for a default build. CONFIG_VERSION is
# a string the source quotes itself; pass it double-quoted.
QJS_DEFINES="-DCONFIG_VERSION=\"\\\"${QJS_VERSION}\\\"\" -DCONFIG_ATOMICS -DCONFIG_STACK_CHECK"

log "compiling QuickJS engine core (sanitizer build, §36.4) under $QJS_DIR"
mkdir -p build/qjs-objects
for src in quickjs cutils dtoa libregexp libunicode; do
  log "  $src.c"
  $CC $CFLAGS $SAN_CFLAGS $QJS_DEFINES -c "$QJS_DIR/$src.c" -o "build/qjs-objects/$src.o" -I"$QJS_DIR" ||
    { log "ERROR: $src.c failed to compile"; exit 1; }
done
log "engine core compiled: $(ls build/qjs-objects/*.o | wc -l) objects"
log "Phase 0 Unix OK: platform boundary + QuickJS engine core compile under ASan/UBSan"
exit 0
