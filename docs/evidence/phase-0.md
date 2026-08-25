# Evidence report — Phase 0: Feasibility and toolchain lock

- **Ticket:** MIRAGE-LAMBDA
- **Phase:** 0 (§34)
- **Date:** 2026-08-25
- **Status:** partial — Unix platform boundary proven; QuickJS vendor + HVT switch pending

## 1. Toolchain baseline (captured)

| Component | Value | Captured via |
|---|---|---|
| opam | 2.5.2 | `opam --version` |
| switch | `CP.2025.08.0~8.20~2025.01` | `opam switch show` |
| OCaml | 4.14.2 (flambda) | `ocaml -version` |
| Dune | 3.19.1 | `dune --version` |
| C compiler | Ubuntu gcc 13.3.0 (`cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`) | `cc --version` |
| Yojson | 2.2.2 | `opam list` |
| ppx_yojson_conv | v0.16.0 | `opam list` |

Pinned in `opam.locked` and `docs/adr/0000-toolchain-baseline.md`.

## 2. Phase 0 required outputs (§34.1)

| Output | Status | Path |
|---|---|---|
| `docs/adr/0000-toolchain-baseline.md` | ✅ done | `docs/adr/0000-toolchain-baseline.md` |
| `qjs/vendor/quickjs-2026-06-04/` | ⏳ pending vendor | download + digest record pending |
| `qjs/test/probe.ml` | ✅ scaffolded | `qjs/test/probe.ml` |
| `qjs/test/probe.js` | ✅ scaffolded | `qjs/test/probe.js` |
| `qjs/c/qjs_port_unix.c` | ✅ done + compiles | `qjs/c/qjs_port_unix.c` |
| `qjs/c/qjs_port_solo5.c` | ✅ scaffolded (HVT) | `qjs/c/qjs_port_solo5.c` |
| `qjs/c/qjs_port.h` | ✅ done | `qjs/c/qjs_port.h` |
| `scripts/build-unix-probe.sh` | ✅ done + runs | `scripts/build-unix-probe.sh` |
| `scripts/build-hvt-probe.sh` | ✅ done + gates | `scripts/build-hvt-probe.sh` |
| `docs/evidence/phase-0.md` | ✅ this file | `docs/evidence/phase-0.md` |
| `opam.locked` | ✅ done (hand-maintained) | `opam.locked` |

## 3. Unix platform-boundary smoke test (§21.4)

Command:

```text
$ eval $(opam env)
$ ./scripts/build-unix-probe.sh
[build-unix-probe] compiling platform boundary (qjs_port_unix.c) as a smoke test
[build-unix-probe] (no QuickJS dependency; proves the §21.4 boundary is sound)
[build-unix-probe] platform boundary compiled: build/probe/qjs_port_unix.o
[build-unix-probe] Phase 0 Unix platform-boundary OK (engine link pending vendor)
```

Compiler flags (§36.4): `-O1 -g3 -fno-omit-frame-pointer -fsanitize=address,undefined
-Wall -Wextra -Wconversion -Wshadow`.

Artifact: `build/probe/qjs_port_unix.o` — `ELF 64-bit LSB relocatable, x86-64, version 1
(SYSV), with debug_info, not stripped` (156664 bytes).

Interpretation: the freestanding platform boundary header (`qjs_port.h`) and its Unix
implementation (`mlqjs_monotonic_ns`, `mlqjs_wall_time_ms`, `mlqjs_random_bytes`,
`mlqjs_abort`) compile cleanly under ASan/UBSan with the strict warning set. This is real
evidence that the §21.4 boundary is sound on Unix before QuickJS is vendored.

## 4. Feasibility probe (§34.2) — status

The probe contract is fully specified in `qjs/test/probe.{ml,js}` (11 steps + expected state
trace). It depends on the `Qjs_engine` interface (§20.1), implemented in Phase 2. Until
QuickJS is vendored and `qjs_stubs.c` lands, the probe cannot be run. **Pending:** vendor
`quickjs-2026-06-04`, record its SHA-256, link the engine core, and run the probe to capture
the state trace.

## 5. Missing-symbol audit (§34.3) — template

To be filled after the QuickJS engine objects are compiled against the HVT target libc.
Template lives in `docs/quickjs-port-audit.md`.

| Symbol | Referenced by | Unix availability | HVT availability | Decision |
|---|---|---|---|---|
| `malloc`/`free`/`realloc` | allocator path | libc | ocaml-solo5 minimal libc | route through `JS_NewRuntime2` custom fns |
| `malloc_usable_size` | accounting path | platform-specific | unknown | avoid via custom allocator |
| `clock_gettime` | optional time path | yes | target-dependent | host-provided JS clock only |
| `dlopen` | standard module loader | yes | no | exclude `quickjs-libc.c` |
| `pthread_create` | QuickJS worker helper | yes | unsuitable | exclude worker API; `JS_SetCanBlock(rt,false)` |
| `snprintf` | formatting | libc | verify minimal libc | bound all buffers |

## 6. HVT status

The HVT probe (`scripts/build-hvt-probe.sh`) correctly gates: `mirage`/`solo5` are not
installed in the current switch. A dedicated Mirage opam switch is required before Phase 5/6.
**Pending:** create the switch, cross-compile `qjs_port_solo5.c` against ocaml-solo5, run the
missing-symbol audit, boot the HVT image, capture QuickJS/OCaml/Mirage/build digests.

## 7. Phase 0 exit gate (§34.4) — status

| Gate | Status |
|---|---|
| both target probes execute with pinned toolchain | ⏳ pending QuickJS vendor + HVT switch |
| memory and stack limits fail cleanly | ⏳ pending engine link (Phase 2) |
| infinite-loop interrupt terminates within tolerance | ⏳ pending engine link (Phase 2) |
| async Promise settlement without foreign-thread re-entry | ⏳ pending engine link (Phase 2) |
| C/OCaml ownership rules documented beside wrapper | ✅ in ADR 0000 + port headers (Phase 2 adds full table) |
| HVT image boots + reports digests | ⏳ pending HVT switch |
| no unresolved critical libc dependency | ⏳ pending missing-symbol audit |
| explicit go/no-go record | ⏳ pending (this report is partial) |

## 8. Go / no-go

**Provisional GO to proceed with Phase 1** in parallel: the pure `common/` library has no
QuickJS, Mirage, or Solo5 dependency, so it can be fully built and tested while the remaining
Phase 0 items (QuickJS vendor, HVT switch, missing-symbol audit) are completed as a tracked
follow-up. The full Phase 0 gate remains OPEN until the engine probe runs on both targets.

## 9. Unresolved risks

- QuickJS release `2026-06-04` upstream URL + digest must be confirmed (the exact release
  archive name is provisional).
- The Coq-flavored opam switch must NOT be polluted with Mirage packages; a separate switch
  is mandatory for Phases 5/6.
- C FFI ownership invariant (§36.3) is not yet enforced by code; it lands in Phase 2.
