# ADR 0001 — QuickJS engine choice

- **Status:** proposed
- **Date:** 2026-08-25
- **Phase:** 0/2

## Context
The worker needs an embedded JavaScript runtime with a small, auditable C API,
memory limits, an interrupt callback, Promise/job-queue control, and a custom
module loader — and must be portable to the Solo5 HVT freestanding target
(see ADR 0000, §21, §H).

## Decision
Use QuickJS (release `quickjs-2026-06-04`), vendoring only the engine core
(`quickjs`, `cutils`, `dtoa`, `libregexp`, `libunicode` + generated tables),
excluding `quickjs-libc.c`. Compile intrinsics down to a versioned profile
`quickjs-2026-06-04-mlambda-v1` (§21.5).

## Consequences
- Freestanding port effort (§21.3 audit) is a real Phase 0 cost.
- No Node/npm/`require`/`fs` ambient authority (§10.1, §H.1).
- Fallbacks (quickjs-ng, WASM guest engine, minimal-Linux worker) require a
  new ADR changing the trusted computing base (§34.4).

## Status note
To be accepted at the Phase 0/2 gate once the probe runs on both targets.
