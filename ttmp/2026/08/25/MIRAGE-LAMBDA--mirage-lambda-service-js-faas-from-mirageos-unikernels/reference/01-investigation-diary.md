---
Title: Investigation diary
Ticket: MIRAGE-LAMBDA
Status: active
Topics:
    - mirage
    - ocaml
    - quickjs
DocType: reference
Intent: long-term
Owners: []
RelatedFiles:
    - Path: repo://qjs/c/qjs_port.h
      Note: Freestanding platform boundary contract
    - Path: repo://scripts/build-unix-probe.sh
      Note: Compiles the §21.4 platform boundary under ASan/UBSan
ExternalSources: []
Summary: Chronological diary of the Mirage Lambda Service implementation, following the diary skill format.
LastUpdated: 2026-08-25T17:20:00-04:00
WhatFor: Recording what changed, why, what worked/failed, and how to review each phase.
WhenToUse: Read before resuming work on MIRAGE-LAMBDA to recover context.
---



# Diary

## Goal

Implement the Mirage Lambda Service (`mirage_lambda_service_implementation_guide.md`) in
phase order, committing at appropriate intervals, keeping this diary, and printing brutalist
work slips before and after each phase.

## Step 0: Ticket creation and phase map

This step bootstraps the docmgr ticket `MIRAGE-LAMBDA`, writes the phase-map design doc, and
sets up the task list for the 11 delivery phases. It commits the source guide as the git
baseline so all later work has a stable reference point.

### Prompt Context

**User prompt (verbatim):** "Create a new docmgr ticket to implement mirage_lambda_service_implementation_guide.md . Then implement, commit at appropriate intervals and keep a detailed diary as you work (using the diary format from the skill). Print out a brutalist work slip with the plan / different phases for the ticket. then before stsarting a phase, plrint a split about the phase, and print one when the phase is done."

**Assistant interpretation:** Create a docmgr ticket for the implementation guide, implement it phase by phase with commits and a diary, and emit brutalist thermal work slips: one plan slip up front, one slip before each phase starts, and one when each phase completes.

**Inferred user intent:** A traceable, paper-and-documented phased implementation of the guide, with physical progress artifacts (thermal slips) marking each phase boundary.

### What I did
- Inspected the repo: only the guide was present (untracked); OCaml 4.14.2 + dune available via `opam` switch `CP.2025.08.0~8.20~2025.01`; `ocaml`/`mirage` not on PATH until `eval $(opam env)`.
- Added vocabulary topics: mirage, unikernel, ocaml, quickjs, lambda, common-library, capability-security.
- Committed the guide as the git baseline (`96a609f`).
- Created ticket `MIRAGE-LAMBDA`, design doc `01-implementation-plan-and-phase-map.md`, diary `01-investigation-diary.md`, and the 11-phase task list.

### Why
The guide is a 5081-line design spanning 11 phases (0-10); a ticket + phase map is the only way to track progress against its stage-gate rule without losing context.

### What worked
- Ticket and docs created cleanly; docmgr vocabulary accepts new topics.
- The guide's phase structure (sections 33-44) maps directly to a clean phase map.

### What didn't work
- `ocaml`/`mirage`/`dune` not on the default PATH; must `eval $(opam env)` before any build. `alcotest`/`qcheck`/`crowbar` are available in opam but not installed yet (needed for Phase 1 tests/fuzz).

### What I learned
- The Coq-flavored opam switch is active; OCaml 4.14.2 + flambda. Standard OCaml libraries and dune work; MirageOS/Solo5 packages are NOT installed and would need a dedicated switch for Phases 5-6.
- Phases 0-4 are Unix-targetable in this session; 5-10 need Solo5/Mirage + fleet infra.

### What was tricky to build
- Mapping a 5081-line guide to a phase plan that fits a brutalist slip (≤~40 chars per phase) while staying faithful to the guide's dependency graph and effort classes.

### What warrants a second pair of eyes
- The phase-map scope decisions (which phases are "session-target complete" vs "scaffolded") — these set expectations for the whole ticket.

### What should be done in the future
- Install `alcotest`, `qcheck`, `crowbar` for Phase 1 (done in Step 1).
- Create a dedicated Mirage/Solo5 opam switch before Phase 5-6.

### Code review instructions
- Start at `ttmp/2026/08/25/MIRAGE-LAMBDA--mirage-lambda-service-js-faas-from-mirageos-unikernels/design-doc/01-implementation-plan-and-phase-map.md`.
- Validate the phase list against guide sections 34-44.

### Technical details
- Ticket path: `ttmp/2026/08/25/MIRAGE-LAMBDA--mirage-lambda-service-js-faas-from-mirageos-unikernels/`
- Baseline commit: `96a609f`

## Step 1: Phase 0 — Feasibility and toolchain lock (scaffolded)

This step creates the repository skeleton, pins the toolchain in an ADR and `opam.locked`,
scaffolds the QuickJS probes (platform boundary header + Unix + Solo5 implementations + probe
driver + probe program), writes the build scripts, and produces the Phase 0 evidence report.
The Unix platform boundary is proven to compile under ASan/UBSan; the QuickJS engine link
and the Solo5 HVT boot are documented gaps gated on vendoring QuickJS and a dedicated Mirage
switch, which unblock Phase 1 to proceed in parallel.

### Prompt Context

**User prompt (verbatim):** (see Step 0)

**Assistant interpretation:** Implement Phase 0 of the guide: repo skeleton, toolchain pin, QuickJS probe scaffolding, build scripts, and evidence.

**Inferred user intent:** A real, committed Phase 0 foundation with verifiable artifacts (not just docs), so Phase 1 can build on it.

### What I did
- Top-level: `dune-project` (package `mirage_lambda`, `allow_empty`), `mirage_lambda.opam`, `opam.locked` (hand-maintained pin record), `Makefile`, `README.md`, `LICENSE`, `.gitignore`.
- Created the full repo structure from §19 (`common/`, `qjs/{c,lib,vendor,test}/`, `control/`, `worker/`, `launcher/`, `cli/`, `api/`, `test/*`, `deploy/*`) with `.gitkeep` markers.
- `docs/adr/0000-toolchain-baseline.md` capturing the real toolchain (opam 2.5.2, OCaml 4.14.2+flambda, dune 3.19.1, gcc 13.3.0, yojson 2.2.2). ADRs 0001–0004 stubbed for later phases.
- `qjs/c/qjs_port.h` (§21.4 freestanding boundary), `qjs/c/qjs_port_unix.c` (real clock/urandom/abort), `qjs/c/qjs_port_solo5.c` (callback-table HVT impl).
- `qjs/test/probe.js` (§34.2 probe program) and `qjs/test/probe.ml` (probe driver mirroring §20.1 `QJS_ENGINE` + the 11 steps + expected state trace).
- `scripts/build-unix-probe.sh` (compiles the platform boundary under `-fsanitize=address,undefined` + strict warnings; gates on missing QuickJS vendor) and `scripts/build-hvt-probe.sh` (gates on missing `mirage`/`solo5`).
- `docs/evidence/phase-0.md` (captured toolchain, output checklist, smoke-test output, audit template, exit-gate status, provisional GO).
- `docs/quickjs-port-audit.md` (§21.3 template), `docs/{architecture,threat-model,operations}.md` stubs, `docs/diagrams/README.md`, `qjs/README.md` (ownership table §36.3).

### Why
Phase 0 is the gate that separates language-runtime uncertainty from architecture. Pinning the toolchain + proving the smallest QuickJS facilities before building on them is required by §34. The platform boundary has no QuickJS dependency, so I could produce real compile evidence now without vendoring QuickJS.

### What worked
- `./scripts/build-unix-probe.sh` compiles `qjs_port_unix.c` cleanly under ASan/UBSan with `-Wall -Wextra -Wconversion -Wshadow`, producing `build/probe/qjs_port_unix.o` (ELF x86-64, debug_info, 156664 bytes). Real evidence the §21.4 boundary is sound.
- `./scripts/build-hvt-probe.sh` correctly gates with a clear message that `mirage`/`solo5` are missing.
- `dune build` passes on the empty project after fixing the opam-file-name / `(allow_empty)` requirements.

### What didn't work
- `mirage-lambda.opam` (hyphen) didn't match package name `mirage_lambda` (underscore); dune error: "doesn't have a corresponding (package ...) stanza". Fix: rename to `mirage_lambda.opam`.
- After that, dune required `(allow_empty)` on the package stanza since Phase 0 has no library stanzas yet.

### What I learned
- The freestanding platform boundary is decoupled from QuickJS, so Phase 0 can prove it independently — a useful decomposition the guide implies via §21.4.
- `opam switch show` here returns a Coq-flavored switch; Mirage/Solo5 packages must NOT be installed into it.

### What was tricky to build
- Making the build script produce real evidence (compile the boundary) while honestly gating the engine link on the missing QuickJS vendor. Solved by always compiling the boundary as a smoke test, then gating only the engine link, and exiting 0 with a clear "pending vendor" message.
- Dune package/opam-file name correspondence (`mirage_lambda.opam` ↔ `(name mirage_lambda)`) plus `(allow_empty)` for a Phase-0 project with no stanzas.

### What warrants a second pair of eyes
- The `opam.locked` pins are hand-maintained (versions captured from the live switch) and will need a real `opam lock` at the exit gate.
- The QuickJS release `quickjs-2026-06-04` URL/digest is provisional and must be confirmed upstream.
- The probe.ml `QJS_ENGINE` signature is a Phase 0 mirror of §20.1; it must be reconciled with the Phase 2 implementation in `qjs/lib/qjs_engine.mli`.

### What should be done in the future
- Vendor QuickJS `2026-06-04`, record its SHA-256, link the engine core, and run the probe to capture the real state trace.
- Create a dedicated Mirage opam switch; run the missing-symbol audit and the HVT boot.
- Install `qcheck`/`alcotest`/`crowbar` before Phase 1 tests.

### Code review instructions
- Start at `docs/adr/0000-toolchain-baseline.md` and `docs/evidence/phase-0.md`.
- Run `eval $(opam env) && ./scripts/build-unix-probe.sh` to reproduce the boundary smoke test.
- Validate the probe contract in `qjs/test/probe.{ml,js}` against §34.2 and §20.1.

### Technical details
- dune 3.19.1, OCaml 4.14.2, opam 2.5.2, gcc 13.3.0.
- Boundary object: `build/probe/qjs_port_unix.o`, sanitizer build with `-O1 -g3 -fno-omit-frame-pointer -fsanitize=address,undefined`.
