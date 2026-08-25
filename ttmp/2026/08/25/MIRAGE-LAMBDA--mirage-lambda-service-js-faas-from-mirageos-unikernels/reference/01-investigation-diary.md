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
    - Path: repo://common/manifest.ml
      Note: Strict manifest parser (§10.2/§10.3)
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

## Step 2: Phase 1 — Domain model, schemas, and pure common library (complete)

This step implements the entire pure `common/` library — identifiers, bounded
bytes, the stable error taxonomy, resource arithmetic, the capability system,
the strict manifest parser, the MLB1 bundle parser/writer (with a pure-OCaml
SHA-256), the internal protocol, and canonical JSON — plus property tests,
a crowbar fuzz harness, and the `api/` JSON Schema / OpenAPI fixtures. The
library has no Unix/Lwt/Mirage/TLS/QuickJS dependency, so it builds and tests
on the plain OCaml switch. All 14 alcotest tests and 3 crowbar fuzz tests pass.

### Prompt Context

**User prompt (verbatim):** (see Step 0)

**Assistant interpretation:** Implement Phase 1 of the guide: the pure common library, schemas, property tests, and fuzz harness.

**Inferred user intent:** A tested, dependency-free foundation that every later phase (worker, control plane, CLI) imports.

### What I did
- `common/canonical_json.{ml,mli}`: deterministic JSON with recursively sorted keys, fixed float repr, no whitespace.
- `common/error.{ml,mli}`: `Validation`, `Resource`, `Js`, `Host` modules; `failure_class` (§18.1) + stable `code` (§9.5) with HTTP status; top-level `Error.t` with request id + retryable.
- `common/bounded_bytes.{ml,mli}`: bound-checked byte strings; `create`/`append`/`sub` return `Payload_too_large` on overflow.
- `common/ids.{ml,mli}`: `Slug` functor for `Function_name`/`Tenant_id`/`Alias`/`Store_id`/`Log_stream`/`Qualifier`; separate `Binding_name` (JS-identifier, camelCase); `Digest` (64 hex + constant-time equal); `Key_prefix` (allows single trailing slash); `Module_path` (§10.4/§10.5); `Revision_id`.
- `common/budget.{ml,mli}`: `Engine_limits` + `Usage` with saturating counters; `take_*`/`release_*` never underflow; `deadline_expired`.
- `common/capability.{ml,mli}`: `operation`, `grant`, `policy`, `declarations`; `compile`; `intersection` (§F.1 — never grants more than either operand); `grants`; `Http_policy`, `Secret_policy`, `Function_ref`, `Operation_limits`.
- `common/manifest.{ml,mli}`: strict Yojson parser; rejects unknown + duplicate fields; validates ids/limits/capabilities; ordered cheapest→most expensive (§10.3).
- `common/bundle.{ml,mli}`: MLB1 parser/writer + inline `Sha256` (pure OCaml); bounds/overflow checks, path validation, sorted+unique modules, per-module + footer digest verification with constant-time compare, size caps.
- `common/protocol.{ml,mli}`: `Worker_id`/`Invocation_id`/`Lease_id`; `invocation_envelope`, `assignment`, `metering`, `completion`, `completion_envelope`, `start_handshake`; all carry `protocol_version`; `check_version`.
- `test/unit/test_common.ml` + `dune`: 14 alcotest tests incl. property tests (slug roundtrip, budget no-underflow, capability intersection invariant).
- `test/fuzz/fuzz_common.ml` + `dune`: 3 crowbar tests (no-crash on arbitrary bytes for bundle/manifest; bundle write/parse roundtrip).
- `api/function-manifest.schema.json`, `api/invocation-envelope.schema.json`, `api/openapi.yaml`, `api/worker-protocol.md`.

### Why
Phase 1 is the dependency-free foundation everything imports (§35.1). Pure code is fuzzable and reusable by CLI/control/worker/tests (§35.1).

### What worked
- `dune runtest --force`: 14/14 alcotest tests pass; 3/3 crowbar fuzz tests pass.
- The bundle write→parse roundtrip preserves content and verifies digests; truncation and a flipped footer byte are both rejected.
- Capability intersection correctly grants `Kv_get` (in both) but not `Kv_put` (only one operand), proving the §F.1 invariant.

### What didn't work
- `let*` (Result bind) is NOT in scope from `open Result` in OCaml 4.14.2 stdlib; had to `let (let*) = Result.bind` per file.
- Record-field punning resolved to the record *accessors* (e.g. `Validated.modules`) instead of local `let` variables; renamed locals to `mods`/`manifest_v` and used explicit `field = value`.
- `Result.of_string`/field-access precedence (`f m.path` parsed as `(f m).path`); parenthesized or annotated lambda params.
- `Key_prefix.of_string "tenant-a/"` rejected the trailing slash (empty segment); fixed to allow a single trailing slash.
- `Binding_name` used the strict slug policy, but the guide's manifest uses camelCase bindings ("metadataApi"); gave `Binding_name` a JS-identifier validator.
- Invoke bindings derived from hyphenated function names ("resize-helper") failed the JS-identifier check; map `-`→`_`.
- opam-file name had to match the package name (`mirage_lambda.opam`), and the package stanza needed `(allow_empty)` for a Phase-0 project with no library stanzas; later added the real library.
- `qcheck`/`crowbar` API friction (no `QCheck.elements`, `QCheck_alcotest` package absent); used a seeded-Random property helper inside alcotest and `Crowbar.add_test [Crowbar.bytes]` directly.

### What I learned
- The freestanding platform boundary (Phase 0) and the pure common library (Phase 1) are cleanly decoupled — Phase 1 needs only `yojson` + the test stack.
- Record-field disambiguation in `wrapped false` libraries bites when accessors share names with intended locals; explicit field assignment is the reliable fix.
- The guide's manifest example (§10.2) intentionally uses camelCase bindings and hyphenated function names, so the identifier policies must differ per type.

### What was tricky to build
- Keeping the bundle parser total on arbitrary bytes: every `String.sub`/`read_u16`/`read_u32` is bounds-checked with `Int64` arithmetic to avoid overflow, and the footer offset is asserted to be exactly `len - 32`. A mutable offset ref inside a `let*` chain needed `let () = off := !off + N in` sequencing (not `let* x = e in off := .. in ..`).
- Unifying error types in `Bundle.parse`: it mixes `Error.t` (public) and `Error.Validation.t`/`string` (sub-parsers); added `validation_err`/`invalid` converters so `parse` returns a uniform `(Validated.t, Error.t) result`.
- Faithful strict manifest parsing with duplicate + unknown field detection using Yojson's assoc lists (Yojson preserves duplicate keys).

### What warrants a second pair of eyes
- The pure-OCaml SHA-256 in `bundle.ml` is hand-written; verify against NIST vectors / `mirage-crypto` in Phase 2 before relying on it for real digests.
- `Canonical_json` float representation is not RFC 8785 (§canonical_json limitation); fine for the manifest/bundle (mostly strings/ints) but must be hardened before floats cross a digest boundary.
- The `Http_policy` equality in `op_equal` is structural; Phase 8 must harden egress (§16).
- `Binding_name` allows `_`-start and arbitrary camelCase; confirm this matches the intended JS API surface in Phase 3.

### What should be done in the future
- Validate `canonical_json` against RFC 8785 floats; add NIST SHA-256 vectors to the bundle tests.
- Add a `common/` cross-compile check for the target switch (§35.4: no accidental Unix deps) — currently only Unix-verified.
- Phase 2: implement `qjs/lib/qjs_engine.mli` to match the §20.1 interface the probe references.

### Code review instructions
- Start at `common/` `.mli` files (the public contracts) and `test/unit/test_common.ml`.
- Run `eval $(opam env) && dune build && dune runtest --force` — expect 14 unit + 3 fuzz passing.
- Check the §35.3 properties: `decode(encode(x))=x`, budget no-underflow, capability intersection subset, bundle parser consumes exact lengths, manifest rejects unknown fields.

### Technical details
- Switch `CP.2025.08.0~8.20~2025.01`, OCaml 4.14.2, dune 3.19.1, yojson 2.2.2, alcotest 1.9.1, qcheck 0.91, crowbar (installed).
- Test results: `Test Successful in 0.026s. 14 tests run.` + `test1/test2/test3: PASS`.
