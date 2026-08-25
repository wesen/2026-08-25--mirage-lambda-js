# ADR 0000 — Toolchain baseline

- **Status:** proposed
- **Date:** 2026-08-25
- **Phase:** 0 — Feasibility and toolchain lock
- **Supersedes:** —

## Context

The Mirage Lambda Service is built from MirageOS unikernels, an embedded
QuickJS engine, and a Solo5 HVT guest boundary. MirageOS, Solo5, OCaml, and
their libraries evolve independently, so the guide (§34) requires pinning the
exact toolchain and proving the smallest required QuickJS facilities work on
both Unix and HVT **before** service architecture accumulates around them.
`opam.locked` and the vendored QuickJS digest become release inputs; a moving
QuickJS branch must never be tracked in production builds.

This ADR records the baseline captured during Phase 0 on the development
host. It is the input to `opam.locked` and the evidence report
(`docs/evidence/phase-0.md`).

## Decision

Pin the following baseline for Phase 0/1 (Unix development) and defer the
Mirage/Solo5 lock to a dedicated switch before Phase 5/6.

### Compiler and build (captured)

| Component | Value | How captured |
|---|---|---|
| opam | 2.5.2 | `opam --version` |
| OCaml | 4.14.2 (`ocaml-variants.4.14.2+options` + `ocaml-option-flambda.1`) | `opam switch list`; switch `CP.2025.08.0~8.20~2025.01` |
| Dune | available via opam (`>= 3.15`) | `dune --version` |
| Yojson | 2.2.2 (manifest + bundle header JSON) | `opam list` |
| ppx_yojson_conv | v0.16.0 (optional deriving) | `opam list` |

### Test / fuzz (to install before Phase 1)

| Component | Target | Purpose |
|---|---|---|
| qcheck | `>= 0.21` | property tests for `common/` |
| alcotest | `>= 1.7` | unit test runner |
| crowbar | `>= 0.4` | fuzz harness for bundle/manifest parsers |

### JavaScript engine (vendored, not opam)

| Component | Value | Notes |
|---|---|---|
| QuickJS | release `2026-06-04` | vendored under `qjs/vendor/quickjs-2026-06-04/`; **digest recorded at vendor time** (Phase 0 step still pending: download archive, record SHA-256). Keep only the engine core: `quickjs.{c,h}`, `cutils.{c,h}`, `dtoa.{c,h}`, `libregexp.{c,h}` + opcode header, `libunicode.{c,h}` + generated tables, `VERSION`, `LICENSE`. **Exclude** `quickjs-libc.c` (POSIX/`dlopen`/`pthread`). |

### Mirage / Solo5 (deferred — dedicated switch for Phase 5/6)

Not installed in the current Coq-flavored switch. Before Phase 5, create a
dedicated Mirage switch and pin:

- `mirage`, `ocaml-solo5`, `solo5`, `mirage-clock`, `mirage-kv`, `mirage-crypto`
- `tls`, `cohttp`, `mtime`
- the exact HVT tender and Albatross versions used in integration tests.

## Consequences

- Phase 1 (`common/`) builds on plain OCaml 4.14.2 + dune + yojson + qcheck +
  alcotest; no Mirage/Unix dependency is allowed to leak into `common/`.
- Phase 2 (QuickJS embedding) depends on the vendored QuickJS release and the
  C compiler/linker versions recorded in the evidence report.
- Phases 5/6 are blocked on a dedicated Mirage switch; this is a documented
  gate, not an oversight.
- Upgrading QuickJS or any pinned package requires a new evidence run and an
  update to this ADR (see `docs/adr/` and appendix G.1).

## Open items (Phase 0 exit gate)

1. Download the `quickjs-2026-06-04` release archive and record its SHA-256.
2. Run `scripts/build-unix-probe.sh` against the vendored engine and capture
   the probe's state trace (§34.2) into `docs/evidence/phase-0.md`.
3. Create the dedicated Mirage switch and run `scripts/build-hvt-probe.sh`;
   capture the HVT boot + digest report.
4. Complete the missing-symbol audit table (§34.3) against the HVT target libc.
5. Record the go/no-go decision.

## Status note

This ADR is **proposed**. It becomes **accepted** when the Phase 0 exit gate
(§34.4) passes and the evidence report records a go decision. The Unix
scaffolding committed in Phase 0 lets Phase 1 proceed in parallel with the
remaining QuickJS-vendoring and HVT-switch items above.
