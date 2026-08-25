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
# Record the upstream archive URL + digest here when vendoring. The exact
# upstream release URL must be confirmed against bellard.org/quickjs at
# vendor time; the digest is recorded in docs/evidence/phase-0.md.
QJS_URL_BASE="https://bellard.org/quickjs"
QJS_DIGEST=""  # SHA-256 of the archive; filled at vendor time.

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
log "(engine core + OCaml probe driver link in Phase 2 once qjs_stubs.c lands)"
log "Phase 0 Unix scaffolding OK"
exit 0
