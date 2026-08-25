#!/usr/bin/env bash
# scripts/build-hvt-probe.sh — Phase 0: build and run the Solo5 HVT probe.
#
# Cross-compiles the QuickJS engine core against the ocaml-solo5 freestanding
# target and boots the probe as a Solo5 HVT unikernel. Requires a dedicated
# Mirage opam switch (mirage + ocaml-solo5 + solo5) — NOT installed in the
# current Coq-flavored switch.
#
# This is the HVT half of the Phase 0 exit gate (§34.4).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

QJS_VERSION="2026-06-04"
QJS_DIR="qjs/vendor/quickjs-${QJS_VERSION}"

log() { printf '[build-hvt-probe] %s\n' "$*" >&2; }

if ! command -v mirage >/dev/null 2>&1; then
  log "ERROR: 'mirage' not found. The HVT probe requires a dedicated Mirage"
  log "opam switch with: mirage, ocaml-solo5, solo5, mirage-clock,"
  log "mirage-kv, mirage-crypto, tls, cohttp, mtime."
  log "Create it before Phase 5/6 (see docs/adr/0000-toolchain-baseline.md)."
  exit 2
fi
if ! command -v solo5-hvt >/dev/null 2>&1 && ! command -v solo5 >/dev/null 2>&1; then
  log "ERROR: Solo5 tender not found. Install solo5 in the Mirage switch."
  exit 2
fi
if [[ ! -d "$QJS_DIR" ]]; then
  log "ERROR: vendored QuickJS not found at $QJS_DIR (see build-unix-probe.sh)."
  exit 2
fi

log "Mirage + Solo5 present; vendored QuickJS present"
log "TODO (Phase 6): mirage configure -t hvt for the worker unikernel,"
log "  cross-compile qjs/c/qjs_port_solo5.c against ocaml-solo5 freestanding libc,"
log "  run the missing-symbol audit (§34.3) against the HVT target libc,"
log "  boot the HVT image, and capture the QuickJS/OCaml/Mirage/build digests."
log "Phase 0 HVT scaffolding OK (gated on the Mirage switch)"
