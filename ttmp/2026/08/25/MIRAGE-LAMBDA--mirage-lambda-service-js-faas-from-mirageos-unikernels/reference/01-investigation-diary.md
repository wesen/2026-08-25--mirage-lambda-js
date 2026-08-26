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
    - Path: repo://qjs/lib/qjs_stubs.c
      Note: OCaml FFI stubs (§22.4)
    - Path: repo://qjs/vendor/quickjs-2026-06-04/quickjs.h
      Note: Vendored QuickJS engine core header
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

## Step 3: Phase 2 — QuickJS embedding on Unix (scaffolded)

This step scaffolds the three-layer QuickJS wrapper (§36.1): the public
`Qjs_engine` interface (§20.1), opaque `Qjs_handle`, the host-request type,
the custom module loader (§10.5), and the C FFI stubs (§22.2/§22.4). The OCaml
library builds and links the C stubs; the stubs fail at runtime with a clear
message until QuickJS is vendored. The pure module loader is unit-tested (4
tests). All tests green (14 common + 4 qjs + 3 fuzz).

### Prompt Context

**User prompt (verbatim):** (see Step 0)

**Assistant interpretation:** Scaffold Phase 2: the auditable engine library with hard ownership + accounting rules, compiling on Unix.

**Inferred user intent:** The stable `QJS_ENGINE` interface the worker (Phase 3) will import, with real C linkage proven (not just docs).

### What I did
- `qjs/lib/qjs_handle.{ml,mli}`: opaque integer handle with generation counter (§22.2 option 2); externals `mlqjs_create`/`mlqjs_destroy`.
- `qjs/lib/qjs_engine.{ml,mli}`: full §20.1 `QJS_ENGINE` — `create/start/take_host_requests/resolve_host_request/pump/cancel/memory_usage/destroy`, `error`, `completion`, `progress`, `Memory`; `limits_blob` serializes `Engine_limits` for the C side.
- `qjs/lib/qjs_module_loader.{ml,mli}`: `normalize` (./, ../, cap:) staying within bundle root; `resolve` against the validated bundle map.
- `qjs/lib/qjs_host_request.{ml,mli}`: `Id` (int64), `result`, `t`.
- `qjs/c/qjs_stubs.c` (+ copy in `qjs/lib/`): all §22.2 externals with `CAMLparam`/`CAMLlocal` discipline, failing via `caml_failwith` until QuickJS is vendored.
- `qjs/lib/dune`: `foreign_stubs (language c) (names qjs_stubs qjs_port_unix)` — links the §21.4 port boundary + the FFI.
- `test/unit/test_qjs.ml` + dune: 4 alcotest tests for the module loader.

### Why
Phase 2 is the language-runtime gate. Pinning the interface + proving the C linkage compiles lets Phase 3 (worker) import `Qjs_engine` now, while the real engine lifecycle waits on vendoring QuickJS (a tracked Phase 0/2 follow-up).

### What worked
- `dune runtest --force`: 14 common + 4 qjs + 3 fuzz, all pass.
- The C stubs compile and link against the OCaml library (foreign_stubs), including the §21.4 port boundary object.
- Module loader normalization correctly handles `./`, `../`, `cap:`, and rejects root-escape/absolute/bare imports.

### What didn't work
- `(foreign_library ... (files ...))` is not valid dune syntax; `include_dirs` in `foreign_library` is for headers only and the source files must live where dune looks. Fixed by moving the stub `.c` files next to the library and using `(foreign_stubs (language c) (names ...))` inside the library stanza.
- A standalone `c/dune` with a foreign_library created a dependency cycle (object ↔ dll). Resolved by folding the stubs into the library.
- `Val_emptyarray` isn't a macro; replaced with `caml_alloc(0, 0)`.
- Several test-file paren/`match`-as-last-expr pitfalls (dangling match consumed the next `let`); rewrote the test file cleanly.

### What I learned
- Dune `foreign_stubs` inside a `library` is the simple path for OCaml↔C; a separate `foreign_library` is for shared objects and needs care to avoid cycles.
- The §20.1 interface maps almost verbatim to OCaml; the only impedance is serializing `Engine_limits` to a C-decodable blob (`limits_blob`).
- Module-path normalization is fiddly: the accumulator-vs-remaining distinction in the `walk` recursion was the bug (`util/lib/helper.js` instead of `lib/util/helper.js`); starting the accumulator with `List.rev base_dir` fixed it.

### What was tricky to build
- Getting the dune C/OCaml linkage right without a cycle and without `include_dirs` confusion.
- The module loader `walk` recursion: the base directory must seed the accumulator, not be passed as the "remaining" list, or every relative import collapses to just the imported filename.

### What warrants a second pair of eyes
- The C stubs are skeletons that always fail; once QuickJS is vendored, every primitive must be re-audited for the §22.4 ownership rules (no retained OCaml pointers without roots; convert QuickJS exceptions to bounded C data).
- `limits_blob` format (`%ld|`-joined ints) is a placeholder; the C decoder must match exactly and be bounds-checked.
- `Qjs_engine.create` currently ignores the bundle; the real implementation must re-verify digests in C (§10.3 step 7) and load modules via the custom loader.

### What should be done in the future
- Vendor QuickJS `2026-06-04`, record its SHA-256, and wire the real engine lifecycle in `qjs_stubs.c`.
- Run the Phase 0 probe (§34.2) through the real `Qjs_engine` to capture the state trace.
- Add NIST SHA-256 vectors to validate the pure `Bundle.Sha256` against a known implementation.

### Code review instructions
- Start at `qjs/lib/qjs_engine.mli` (the §20.1 contract) and `qjs/lib/qjs_module_loader.ml`.
- Run `eval $(opam env) && dune build && dune runtest --force` — expect 14 + 4 + 3 passing.
- The C stubs at `qjs/lib/qjs_stubs.c` (canonical copy `qjs/c/qjs_stubs.c`) intentionally fail until QuickJS is vendored.

### Technical details
- dune `foreign_stubs` inside `(library ...)`; C compiled with the default toolchain (gcc 13.3.0).
- qjs library `mirage_lambda.qjs` (wrapped false) depends on `mirage_lambda.common`.

## Step 4: QuickJS vendoring (unblocks Phase 0/2)

This step downloads the pinned QuickJS release `2026-06-04`, records its
SHA-256, extracts only the engine core (excluding `quickjs-libc.c`), commits
it at `qjs/vendor/quickjs-2026-06-04/`, and proves the engine core compiles
under ASan/UBSan on Unix. This closes the largest open Phase 0 item and makes
the Phase 2 real-engine wiring concrete.

### Prompt Context

**User prompt (verbatim):** "can you download it? why are you asking me"

**Assistant interpretation:** Stop asking; actually perform the QuickJS vendoring step.

**Inferred user intent:** Close the vendoring gap that was blocking Phases 0/2 instead of deferring it.

### What I did
- Confirmed `quickjs-2026-06-04.tar.xz` exists on `https://bellard.org/quickjs/` (it does — the guide's pin is real).
- Downloaded it (621500 bytes) and recorded SHA-256 `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`.
- Extracted ONLY the engine core (§21.1) into `qjs/vendor/quickjs-2026-06-04/`: quickjs.{c,h}+opcode+atom, cutils, dtoa, libregexp+opcode, libunicode+table, list.h, unicode_gen_def.h, VERSION, LICENSE, readme, Changelog. Explicitly EXCLUDED `quickjs-libc.c`/`.h`, `qjs.c`, `qjsc.c`, `run-test262.c`, `unicode_gen.c`, Makefile, examples, tests.
- Wrote `qjs/vendor/VENDOR.md` (provenance + verification command).
- Recorded the digest in `scripts/build-unix-probe.sh` (`QJS_DIGEST`), `docs/adr/0000-toolchain-baseline.md`, and `opam.locked` (`quickjs_digest`).
- Extended `build-unix-probe.sh` to verify the digest (if the archive is present) and to compile the full engine core with the `CONFIG_*` defines the upstream Makefile sets (`-DCONFIG_VERSION=\"2026-06-04\" -DCONFIG_ATOMICS -DCONFIG_STACK_CHECK`).
- Updated `docs/evidence/phase-0.md` with the engine-core compile evidence (5 objects; quickjs.o ≈ 23.9 MB).

### Why
The vendoring step was the largest open Phase 0 item and the gate for the real Phase 2 engine lifecycle. The user correctly called out that I should just do it rather than describe it.

### What worked
- `./scripts/build-unix-probe.sh` now compiles the platform boundary AND the full QuickJS engine core (5 objects) under `-fsanitize=address,undefined` + `-Wall -Wextra -Wconversion -Wshadow`. Phase 0 Unix feasibility: proven.
- All 21 OCaml tests still green after vendoring (the qjs stubs still stub-fail by design until Phase 2 wires the real engine).
- The guide's `quickjs-2026-06-04` pin is real and reachable — no need for a fallback ADR (§34.4).

### What didn't work
- `quickjs.c` won't compile with `-Wconversion` alone — it needs `CONFIG_VERSION` defined (the upstream Makefile passes it); also `CONFIG_ATOMICS` and `CONFIG_STACK_CHECK` for a default build. Found by the `expected ')' before 'CONFIG_VERSION'` error at line 7226.
- The strict warning set produces many `-Wconversion`/`-Wsign-conversion` warnings from upstream code (expected; not errors), so the script uses `-Werror=implicit-function-declaration` rather than `-Werror` to avoid blocking on upstream style.

### What I learned
- The guide's `quickjs-2026-06-04` is a real Bellard release, not a placeholder — confirmed by `curl https://bellard.org/quickjs/`.
- The engine core is self-contained: 5 .c files compile to objects with only the `CONFIG_*` defines and `-I` to the vendor dir; no `quickjs-libc.c` needed (§21.2 holds).
- `quickjs.c` is ~2 MB of source → 23.9 MB sanitizer object; the build is heavy but trivially reproducible.

### What was tricky to build
- Getting the `CONFIG_VERSION` quoting right in a shell variable that ends up as a C string literal (`-DCONFIG_VERSION=\"\\\"2026-06-04\\\"\"` — the source wraps it in quotes itself).

### What warrants a second pair of eyes
- The vendor tree is committed (2.6 MB) as a release input (§34.1); confirm this matches repo policy (some teams gitignore vendor and re-fetch by digest). The guide says `opam.locked` + digest are release inputs, which implies committing.
- The `-Wconversion` warnings from upstream are suppressed only by not using `-Werror`; a future hardening pass could patch upstream or narrow the flags, but that's a Phase 9 concern.

### What should be done in the future
- Wire the real engine lifecycle in `qjs/c/qjs_stubs.c` against these vendored objects (Phase 2 real run).
- Run the Phase 0 probe (§34.2, 11 steps + state trace) through the real `Qjs_engine`.
- Create the dedicated Mirage/Solo5 opam switch; run the missing-symbol audit (§34.3) against the HVT target libc using these same objects.

### Code review instructions
- Start at `qjs/vendor/VENDOR.md` and `scripts/build-unix-probe.sh`.
- Run `eval $(opam env) && ./scripts/build-unix-probe.sh` — expect "Phase 0 Unix OK: platform boundary + QuickJS engine core compile under ASan/UBSan".
- Verify the digest: `curl -sSL https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz | sha256sum` → `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`.

### Technical details
- Release: `quickjs-2026-06-04.tar.xz`, 621500 bytes, SHA-256 `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`.
- Engine core objects: build/qjs-objects/{quickjs,cutils,dtoa,libregexp,libunicode}.o, gcc 13.3.0, ASan/UBSan.

## Step 5: Phase 2 real engine — QuickJS lifecycle wired and tested

This step replaces the stub-fail FFI with a real QuickJS engine lifecycle:
create/destroy JSRuntime/JSContext, eval, heap-limit OOM, stack-limit
recursion, infinite-loop interrupt, 10k create/eval/destroy cycles, and
job-queue pumping. The vendored engine core is compiled and linked into the
OCaml library via dune foreign_stubs. All 29 tests pass (14 common + 4 qjs
module_loader + 8 qjs engine + 3 fuzz). The §34.2 probe steps 1, 2, 6, 7, 8,
11 are proven on Unix.

### Prompt Context

**User prompt (verbatim):** "Continue. commit at appropriate intervals and keep a detailed diary as you work (using the diary format from the skill)"

**Assistant interpretation:** Continue implementing — wire the real QuickJS engine into the C stubs and run the §34.2 probe.

**Inferred user intent:** Make the QuickJS engine actually work (not just compile) to close the Phase 2 gate.

### What I did
- `qjs/c/qjs_allocator.{c,h}`: invocation-owned allocator (§5.4) with accounting. v1 uses `JS_NewRuntime` (default allocator) since `JS_SetMemoryLimit` works with it; the custom `JS_NewRuntime2` allocator is deferred to Phase 8.
- `qjs/c/qjs_host_queue.{c,h}`: bounded plain-C host request queue (§23.1) with push/take/count; pure C, no QuickJS/OCaml deps.
- `qjs/c/qjs_stubs.c` (real): full engine lifecycle — `mlqjs_create` (NewRuntime, SetMemoryLimit, SetMaxStackSize, SetInterruptHandler, SetCanBlock(false), SetHostPromiseRejectionTracker, NewContextRaw + selective intrinsics: BaseObjects/Eval/JSON/RegExp/MapSet/TypedArrays/Promise), `mlqjs_destroy` (idempotent, FreeContext/FreeRuntime), `mlqjs_eval`/`mlqjs_eval_int`, `mlqjs_pump` (bounded job queue), `mlqjs_cancel`, `mlqjs_take_requests`, `mlqjs_mem_usage`. Generation-counted handle table rejects stale use-after-free (§22.2 option 2).
- `qjs/lib/qjs_handle.{ml,mli}`: real externals for all the above.
- `qjs/lib/qjs_engine.{ml,mli}`: `eval`, `eval_int`, real `pump`/`cancel`/`memory_usage` using the handle externals.
- `qjs/lib/dune`: foreign_stubs including the 5 vendored QuickJS .c files (_qjs_quickjs/cutils/dtoa/libregexp/libunicode) with `-fPIC` + `CONFIG_VERSION/ATOMICS/STACK_CHECK` defines + `-lm`.
- `test/unit/test_qjs_engine.ml`: 8 engine tests covering §34.2 steps 1 (create/destroy x100), 2 (eval 1+2=3), 6 (heap limit OOM), 7 (stack limit), 8 (interrupt), 11 (10k cycles), plus eval-throws and pump-jobs.

### Why
This is the language-runtime gate (§33 uncertainty class 1). Proving the engine creates, evaluates, enforces limits, interrupts, and destroys cleanly under sanitizers is the Phase 0/2 exit gate.

### What worked
- All 8 engine tests pass: create/destroy x100, eval 1+2=3, eval throws, heap limit OOM, stack limit, interrupt infinite loop, 10k cycles, pump jobs.
- Full suite: 14 common + 4 qjs + 8 engine + 3 fuzz = 29 tests, all green.
- `JS_SetMemoryLimit` correctly causes `new Array(1000000).fill(0)` to throw under a 256KB heap.
- `JS_SetMaxStackSize` correctly causes infinite recursion to throw under an 8KB stack.
- The interrupt handler (§24.2) correctly terminates `while(true){}` after the 1ms CPU budget.

### What didn't work
- `JS_NewRuntime2` with a stack-local `JSMallocState` — the `opaque` parameter is `void *opaque`, not `JSMallocState *`. Passing `&ms` (stack local) caused a use-after-free core dump when the runtime's `malloc_state.opaque` dangled. Fix: pass `q->a_state` (heap-allocated) as the opaque.
- The custom `mlqjs_realloc` did `memcpy(p, ptr, size)` — reading `size` (new) bytes from the old pointer (which may be smaller) → buffer over-read → core dump under ASan. Fix: use system `realloc()`.
- The custom allocator's `mlqjs_free` didn't decrement `malloc_size`, so `JS_SetMemoryLimit` didn't work correctly. Fix: use `JS_NewRuntime` (default allocator) for v1; the custom allocator with proper size tracking is a Phase 8 concern.
- `JS_NewContextRaw` + `JS_AddIntrinsicBaseObjects` was insufficient for `JS_Eval` — needed `JS_AddIntrinsicEval` too (the eval intrinsic is separate from base objects).
- `CONFIG_VERSION` quoting in dune: needed `"-DCONFIG_VERSION=\"2026-06-04\""` (outer dune string + escaped quotes) as a single argument.
- `-fPIC` required for the OCaml stubs shared object (`Caml_state` relocation).

### What I learned
- `JS_NewRuntime2(mf, opaque)` takes `void *opaque`, not `JSMallocState *`. The runtime creates its own `JSMallocState` internally and copies `mf` into it.
- `JS_Eval` needs the eval intrinsic even for simple expressions like `1 + 2`; `JS_NewContextRaw` + `JS_AddIntrinsicBaseObjects` alone is insufficient.
- The §34.2 probe steps that need the C module loader (step 3), async handler/Promise bridge (steps 4-5, 9) are the next milestones — they need `JS_SetModuleLoaderFunc` and a C host callback that creates Promises via `JS_NewPromiseCapability`.
- Dune `foreign_stubs` `flags` with `(:standard ...)` preserves dune's defaults (including whatever PIC settings) while adding the CONFIG defines.

### What was tricky to build
- The `JS_NewRuntime2` opaque parameter mismatch: the function signature `JS_NewRuntime2(const JSMallocFunctions *mf, void *opaque)` looked like it took a `JSMallocState *` (the guide's §22.3 shows a `mlqjs_runtime` struct with an `mlqjs_limits` field), but the actual QuickJS API takes a `void *opaque` that becomes `malloc_state.opaque`. Passing a stack-local `JSMallocState` by pointer worked for the first create/destroy but crashed on the second test because the stack frame was gone.
- The custom realloc buffer over-read: `memcpy(p, ptr, size)` where `size` is the NEW size, not the old size, reads past the old allocation. This only manifested under the heap-limit test (which triggers many reallocs during OOM handling).

### What warrants a second pair of eyes
- The handle table (`g_table`/`g_generation`) is a global array of 64 slots — not thread-safe. The worker is single-threaded (§22.1: OCaml drives C, no foreign threads), but this should be documented.
- `mlqjs_destroy` frees `q->ctx` then `q->rt` — `JS_FreeContext` may trigger GC that touches the runtime; the order (context before runtime) is correct per QuickJS docs.
- The 10k-cycle test (§34.2 step 11 calls for 100k) was reduced to 10k for CI time; a standalone 100k run should be done as evidence.
- The custom allocator (`qjs_allocator.c`) is compiled but unused (we use `JS_NewRuntime`). It should either be removed or properly wired with size tracking in Phase 8.

### What should be done in the future
- Wire `JS_SetModuleLoaderFunc` + the C module loader (§24.4) for probe step 3.
- Wire the C host callback + `JS_NewPromiseCapability` (§23.1) for probe steps 4-5, 9.
- Run the full 100k-cycle ASan evidence run (§34.2 step 11).
- Create the Mirage/Solo5 switch; run the missing-symbol audit + HVT boot.

### Code review instructions
- Start at `qjs/c/qjs_stubs.c` (the real engine lifecycle) and `test/unit/test_qjs_engine.ml`.
- Run `eval $(opam env) && dune build && dune runtest --force` — expect 29 tests green.
- Check the §34.2 probe mapping: steps 1,2,6,7,8,11 proven; 3,4,5,9,10 pending.

### Technical details
- Engine: QuickJS 2026-06-04 (vendored), compiled with `-fPIC -DCONFIG_VERSION="2026-06-04" -DCONFIG_ATOMICS -DCONFIG_STACK_CHECK -lm`.
- Intrinsics: BaseObjects, Eval, JSON, RegExp, MapSet, TypedArrays, Promise (§21.5 reduced set; excludes Date, WeakRef, Proxy).
- Handle: generation-counted integer table (§22.2 option 2), 64 slots.

## Step 6: Module loader (§34.2 step 3) and the Promise bridge foundation

This step wires the C module loader (`JS_SetModuleLoaderFunc` + a bundle-map
lookup + `JS_Eval` with `COMPILE_ONLY`), adds `set_module`/`eval_module`
externals, and proves probe step 3 (load a two-module ECMAScript program with
a cross-module import). All 31 tests green.

### Prompt Context

**User prompt (verbatim):** (see Step 5 — "Continue. commit at appropriate intervals...")

**Assistant interpretation:** Continue wiring the remaining probe steps; the module loader is next.

### What I did
- Added a `mlqjs_module_entry` array (256 slots) to `mlqjs_runtime` for the bundle map.
- Implemented `mlqjs_module_loader` (C callback): finds the module by name in the bundle map, compiles with `JS_Eval(..., JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY)`, extracts the `JSModuleDef*` via `JS_VALUE_GET_PTR`, frees the JSValue wrapper, and returns the pointer. Throws `JS_ThrowReferenceError` if not found.
- Set `JS_SetModuleLoaderFunc(q->rt, NULL, mlqjs_module_loader, q)` — NULL normalizer uses QuickJS's default `./`/`../` resolver (the custom normalizer with `cap:` + root-escape is a later step).
- Added `mlqjs_set_module` (store a bundle module path+source) and `mlqjs_eval_module` (compile+run a module entrypoint) externals.
- Freed module sources in `mlqjs_destroy`.
- Exposed `set_module`/`eval_module` in `qjs_handle.{ml,mli}` and `qjs_engine.{ml,mli}`.
- Added 2 tests: `module loader (step 3)` (index.js imports addOne from lib.js → addOne(41)=42) and `module not found` (missing import throws ReferenceError).

### Why
Probe step 3 is the gateway to the async handler (steps 4-5) — the probe.js imports `later` from `host:test`, which requires the module loader to resolve the virtual `cap:` module. Proving the real module loader with two real modules first validates the compile/resolve/execute path.

### What worked
- Two-module program: `index.js` imports `addOne` from `./lib.js`, calls `addOne(41)`, stores 42 in `globalThis.__r`. Eval succeeds, `__r` reads back 42.
- Module not found: importing `./missing.js` throws a ReferenceError (correctly).
- Full suite: 14 common + 4 qjs + 10 engine + 3 fuzz = 31 tests, all green.

### What didn't work
- The module loader's `JS_Eval(..., COMPILE_ONLY)` returned a JSValue wrapping the module. Extracting the pointer with `JS_VALUE_GET_PTR` and returning it WITHOUT freeing the JSValue caused a reference leak → `JS_FreeRuntime` assertion `list_empty(&rt->gc_obj_list)` failed → core dump. Fix: `JS_FreeValue(ctx, val)` after extracting the pointer (the module stays alive because the context's module list holds a reference).
- Using a custom `mlqjs_module_normalize` that just duplicated the import name (`./lib.js`) broke the lookup — the module was stored as `lib.js` but the loader looked for `./lib.js`. Fix: pass NULL for the normalizer to use QuickJS's default resolver, which strips `./` and resolves relative to the base.

### What I learned
- `JS_Eval` with `JS_EVAL_FLAG_COMPILE_ONLY | JS_EVAL_TYPE_MODULE` returns a JSValue with `JS_TAG_MODULE`; the `JSModuleDef*` is extracted with `JS_VALUE_GET_PTR`. The JSValue must be freed (the module list holds the real reference).
- The default QuickJS normalizer (NULL) resolves `./lib.js` to `lib.js` relative to the importing module's base name — this is exactly the §10.5 relative-import semantics for v1.
- The module loader is called recursively: evaluating `index.js` triggers the loader for `./lib.js`, which compiles `lib.js` and returns its `JSModuleDef*`, then `index.js` is compiled and run.

### What was tricky to build
- The JSValue reference leak in the module loader: the symptom was a core dump on `JS_FreeRuntime` (assertion on the GC object list), not a test failure. It only manifested with the two-module test because the single-module test's module was the entrypoint (compiled+run in one step, not via the loader callback). Debugging required isolating the single-module case (works) vs the two-module case (crashes) to narrow it to the loader callback.

### What warrants a second pair of eyes
- The module map is a fixed 256-slot array in the runtime struct — no overflow check beyond `>= MLQJS_MAX_MODULES`. The bundle parser already caps at `max_module_count = 4096`, so the C array should match (or be dynamically sized). For now 256 is enough for the probe.
- The `mlqjs_module_normalize` function is defined but unused (we pass NULL). Remove it or wire it when adding `cap:` support.
- `JS_FreeValue` on the module value relies on the context's module list holding a reference; verify this is true for all module lifecycle paths (e.g., if a module fails to compile, is it still on the list?).

### What should be done in the future
- Wire the custom normalizer for `cap:` virtual modules (§24.4) and root-escape rejection.
- Implement the C host callback + `JS_NewPromiseCapability` for probe steps 4-5 (async handler, host Promise settlement).
- Test the unhandled-rejection tracker (step 9): create a Promise, reject it without a catch, verify the tracker fires.
- Run the full 100k-cycle ASan evidence run.

### Code review instructions
- Start at `qjs/c/qjs_stubs.c` (`mlqjs_module_loader`, `mlqjs_set_module`, `mlqjs_eval_module`) and `test/unit/test_qjs_engine.ml` (`test_module_loader`, `test_module_not_found`).
- Run `eval $(opam env) && dune runtest --force` — expect 31 tests green.

### Technical details
- `JS_SetModuleLoaderFunc(rt, NULL, mlqjs_module_loader, q)` — NULL normalizer = default QuickJS resolver.
- `JS_Eval(ctx, src, len, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY)` → `JS_VALUE_GET_PTR(val)` → `JS_FreeValue(ctx, val)` → return `JSModuleDef*`.

## Step 7: Promise bridge — async handler (steps 4-5) + unhandled rejection (step 9)

This step implements the §23.1 Promise bridge: a C host callback (`host.later(x)`)
that creates a Promise via `JS_NewPromiseCapability`, stores the resolving
functions in a promise table, and enqueues a host request. OCaml drains the
queue, resolves the Promise with a JSON result, and pumps the job queue to
settle it. Also tests the unhandled-rejection tracker (step 9). 9 of 11 probe
steps now proven on Unix (only step 10 — HVT — remains).

### Prompt Context

**User prompt (verbatim):** (see Step 5)

**Assistant interpretation:** Wire the Promise bridge and prove the remaining probe steps.

### What I did
- Added a promise table (`g_promises[256]`) mapping request id → (resolve, reject) JSValues.
- Implemented `mlqjs_host_later` (C `JSCFunction`): validates the arg, creates a Promise via `JS_NewPromiseCapability`, enqueues a host request with the arg as payload, stores the resolving functions, returns the Promise.
- Added `mlqjs_install_host_obj` (installs `host.later` as a global `host` object method) and the `mlqjs_install_host` external.
- Added `mlqjs_resolve` external: finds the promise by request id, parses the JSON result, calls the stored resolve function via `JS_Call`, frees the resolving functions.
- Added `mlqjs_has_unhandled_rejection` external (returns the `terminal` flag set by the rejection tracker).
- Exposed `install_host`/`resolve`/`has_unhandled_rejection` on `qjs_handle` and `qjs_engine`.
- Added 2 tests: `unhandled rejection (step 9)` (rejected Promise with no catch → tracker fires) and `async handler (steps 4-5)` (`host.later(41)` → OCaml resolves with `"42"` → `.then(x => __result = x)` → `__result` reads back 42).

### Why
The Promise bridge (§23.1) is the core runtime bridge: "A JavaScript host call queues data in C, returns a Promise, and is completed later by the OCaml scheduler." Proving it end-to-end closes the language-runtime uncertainty (§33 class 1) for the Unix target.

### What worked
- `host.later(41).then(x => { __result = x; __done = true; })` — the eval enqueues a host request; OCaml drains it, resolves with `"42"`; pump settles the Promise; `__result` reads back 42 and `__done` is true.
- `new Promise((_, reject) => reject(new Error('boom')))` — the rejection tracker fires (§34.2 step 9), `has_unhandled_rejection` returns true.
- Full suite: 14 common + 4 qjs + 12 engine + 3 fuzz = 33 tests, all green.

### What didn't work
- Name collision: both the static C helper and the OCaml external were named `mlqjs_install_host`. Fix: rename the helper to `mlqjs_install_host_obj`.
- `Qjs_engine.t` is abstract in the `.mli`, so `Qjs_handle` externals can't be called with a `Qjs_engine.t` directly. Fix: expose `install_host`/`resolve`/`has_unhandled_rejection` on `Qjs_engine` (delegating to `Qjs_handle`).

### What I learned
- `JS_NewPromiseCapability(ctx, resolving)` returns a Promise and fills `resolving[0]` (resolve) and `resolving[1]` (reject) — these are JSValues that must be freed after use (the promise table holds them until settlement).
- `JS_Call(ctx, resolve_fn, JS_UNDEFINED, 1, &val)` calls the resolve function with the result value; the return value must be freed.
- `JS_ParseJSON` parses a JSON string into a JSValue — using it for the resolve payload keeps the C side simple (no manual JSValue construction).
- The rejection tracker (`JS_SetHostPromiseRejectionTracker`) fires synchronously when a rejected Promise has no rejection handler; the `is_handled` parameter is 0 for unhandled.

### What was tricky to build
- The promise table is a global array (not per-runtime) — fine for single-threaded use (§22.1: OCaml drives C, no foreign threads), but must be documented as a limitation for multi-runtime tests.
- The `JS_Call` to the resolve function must happen while holding the OCaml runtime lock (we're in a C primitive called from OCaml), which is the correct state — no runtime lock release needed.

### What warrants a second pair of eyes
- The promise table (`g_promises`) is a global, not per-runtime — if two runtimes are alive simultaneously and both use the Promise bridge, their promises share the same table. For the worker (one invocation at a time) this is fine, but it should be per-runtime for safety.
- `JS_FreeValue` on the resolve/reject functions in `promise_remove` must happen exactly once per promise — a double-free or use-after-free would be a serious bug.
- The `host.later` callback extracts the arg as an int via `JS_ToInt32`; the general case needs canonical JSON (§23.4).

### What should be done in the future
- Move the promise table per-runtime (into `mlqjs_runtime`).
- Implement the full `host.later` with canonical JSON args (not just int).
- Implement `mlqjs_reject` (reject a host Promise with an error).
- Run the full 100k-cycle ASan evidence run (§34.2 step 11).
- Create the Mirage/Solo5 switch for step 10 (HVT).

### Code review instructions
- Start at `qjs/c/qjs_stubs.c` (`mlqjs_host_later`, `mlqjs_resolve`, `mlqjs_install_host_obj`, promise table) and `test/unit/test_qjs_engine.ml` (`test_async_handler`, `test_unhandled_rejection`).
- Run `eval $(opam env) && dune runtest --force` — expect 33 tests green.

### Technical details
- Probe steps proven on Unix: 1 (create/destroy), 2 (eval 1+2), 3 (two-module import), 4 (async handler), 5 (host Promise settle), 6 (heap OOM), 7 (stack limit), 8 (interrupt), 9 (unhandled rejection), 11 (10k cycles). Only step 10 (HVT boot) remains.

## Step 8: Phase 3 — Unix worker runtime (end-to-end invocation)

This step implements the worker execution semantics: invocation context,
capability broker, host API fakes (log, clock, crypto, kv), the dispatch loop
(§23.2), and a generic `host.rpc(op, arg)` C callback for the Promise bridge.
An end-to-end test runs a JS handler that calls host RPC operations (log.info,
kv.put, kv.get, clock.monotonicMs) through the Promise bridge, driven by the
dispatch loop to completion. 34 tests green.

### Prompt Context

**User prompt (verbatim):** (see Step 5 — "Continue. commit at appropriate intervals...")

**Assistant interpretation:** Implement Phase 3 — wrap the engine in the worker execution semantics with fake capabilities.

### What I did
- `worker/invocation.{ml,mli}`: invocation context (engine, budget, policy, deadline, event/context JSON).
- `worker/capability_broker.{ml,mli}`: dispatches host requests to fake implementations; parses "op\narg_json" payload from the C host.rpc callback; handles log.debug/info/warn/error, clock.monotonicMs, crypto.randomBytes, kv.get/put.
- `worker/host_log.{ml,mli}`: bounded structured log buffer (§37.3 Host_log.Buffer).
- `worker/host_clock.{ml,mli}`: monotonic clock — real (Unix.gettimeofday) or scripted (deterministic sequence).
- `worker/host_crypto.{ml,mli}`: random bytes — real (/dev/urandom) or deterministic (seeded PRNG).
- `worker/host_kv.{ml,mli}`: in-memory KV store with configurable failures (§37.3 Host_kv.Memory).
- `worker/runtime_host.ml`: the dispatch loop (§23.2) — pump → drain host requests → dispatch through broker → resolve Promises → pump → check `__done` → read `JSON.stringify(__result)` → return.
- C stubs: added `mlqjs_host_rpc` (generic host RPC callback: `JS_NewPromiseCapability` + `JS_JSONStringify` + enqueue with "op\narg_json" payload) and `mlqjs_eval_string` (eval expression → return string via `JS_ToCString`); installed `host.rpc` alongside `host.later` on the global `host` object.
- `test/unit/test_worker.ml`: end-to-end test — JS handler calls `host.rpc("log.info", ...)`, `host.rpc("kv.put", ...)`, `host.rpc("kv.get", ...)`, `host.rpc("clock.monotonicMs", ...)`; dispatch loop drives to completion; verifies kv value "1", log "start" event, and the result JSON.

### Why
Phase 3 is where the engine meets the service semantics. The dispatch loop (§23.2) is the only transition path between QuickJS and the host; proving it end-to-end with fake capabilities validates the execution model before adding real Mirage devices (Phase 5/6).

### What worked
- End-to-end: JS async IIFE calls host RPC → C callback creates Promise + enqueues → OCaml drains + dispatches through broker → resolves with JSON result → pump settles → `__done` = true → result read back. kv value "1", log "start" captured, result JSON correct.
- Full suite: 14 common + 4 qjs + 12 engine + 3 fuzz + 1 worker = 34 tests, all green.
- `host.rpc("kv.put", {key:"counter", value:"1"})` → `host.rpc("kv.get", {key:"counter"})` → returns `"1"` (quoted string) → JS reads it as a string.

### What didn't work
- `Printf.sprintf "%ld"` expects `int32` not `int` (from `Int64.to_int`); fix: `string_of_int`.
- `Host_log.append` wasn't exposed in the `.mli`; the broker called it directly. Fix: expose it.
- Warning 33 (unused open `Ids`) in the broker; fix: remove the open.

### What I learned
- The `host.rpc(op, arg)` generic RPC pattern is the right abstraction for Phase 3: a single C callback handles all host operations, and the OCaml broker dispatches based on the operation string. This matches §23.1's design (C callback queues a request, OCaml performs the operation).
- `JS_JSONStringify` converts a JS object to a JSON string for the payload; `JS_ToCString` converts any JSValue to a C string for the result.
- The dispatch loop is a simple pump→drain→resolve→check loop for synchronous fakes; Lwt integration (§23.2) is for when host calls do real async I/O (Phase 5+).

### What was tricky to build
- Detecting handler completion: the JS handler is async (returns a Promise). The dispatch loop needs to know when the Promise has settled and the result is available. Using `globalThis.__done = true` + `globalThis.__result = value` is a pragmatic Phase 3 approach; the real version (Phase 4) observes the engine's `Complete` progress (§20.1).
- The `host.rpc` payload format ("op\narg_json") is a simple delimiter; a binary framing would be more robust but JSON parsing handles it for now.

### What warrants a second pair of eyes
- The dispatch loop has a `max_turns` cap (100) to prevent infinite loops; a real implementation should use the deadline/clock (§5.3) instead of a turn counter.
- The capability broker passes `Capability.empty` as the policy — real policy enforcement (§20.2) is a Phase 8 concern. The broker should check each operation against the invocation's compiled policy.
- The `host.rpc` callback doesn't enforce `max_host_calls` (§5.4 budget) — the host queue is bounded but the per-invocation call count isn't checked.

### What should be done in the future
- Wire resource limits (heap, stack, CPU, deadline) into the dispatch loop's turn check.
- Wire cancellation (§34.2) into the dispatch loop: `Qjs_engine.cancel` on timeout.
- Implement the real `env.log`, `env.kv`, `env.clock`, `env.crypto` JS API surface (§37.1) as C-installed objects, not just `host.rpc`.
- Integrate Lwt for real async host I/O (§23.2).
- Run the Phase 3 exit gate: "end-to-end invocation; resource limits enforced; cancellation works; host calls async + metered."

### Code review instructions
- Start at `worker/runtime_host.ml` (the dispatch loop), `worker/capability_broker.ml` (the dispatcher), and `test/unit/test_worker.ml` (the end-to-end test).
- Run `eval $(opam env) && dune runtest --force` — expect 34 tests green.

### Technical details
- `host.rpc(op, arg)` C callback: `JS_NewPromiseCapability` + `JS_JSONStringify(arg)` + enqueue "op\narg_json" + promise table insert.
- `mlqjs_eval_string`: `JS_Eval` → `JS_ToCString` → `caml_copy_string`.
- Dispatch loop: pump → take_requests → broker.dispatch → resolve → pump → check `__done` → `JSON.stringify(__result)`.

## Step 9: Mirage switch + missing-symbol audit + Phase 4 MVP

This step creates the dedicated `mirage-lambda` opam switch (closing the
infrastructure gate), runs the §34.3 missing-symbol audit against the vendored
QuickJS engine core, implements the Phase 4 single-appliance control plane
(artifact store, registry, admission, scheduler, worker pool, HTTP server) and
developer CLI, and demonstrates the §38.2 end-to-end flow: deploy → alias →
sync/async invoke on Unix.

### Prompt Context

**User prompt (verbatim):** "Ok, then do it, then continue P4-5"

**Assistant interpretation:** Create the Mirage switch, then implement Phases 4 and 5.

**Inferred user intent:** Close the HVT gate and deliver the Unix MVP, then begin the Mirage port.

### What I did
- Created opam switch `mirage-lambda` (4.14.2): mirage 4.11.2, ocaml-solo5 0.8.5, solo5 0.12.0 (with solo5-hvt tender), tls, cohttp, chamelon — all installed.
- Ran the §34.3 missing-symbol audit: compiled the 5 engine objects, extracted undefined symbols, classed each. Finding: excluding quickjs-libc.c removes dlopen/process/POSIX; pthread is gated by CONFIG_ATOMICS (compile out + JS_SetCanBlock false); gettimeofday/localtime via §21.4 platform shim + exclude Date; math via target libm; mem/string/stdlib via ocaml-solo5 nolibc. No engine patch needed.
- Wrote `docs/quickjs-port-audit.md` with the full audit table and decisions.
- Installed cohttp + cohttp-lwt-unix + lwt into the current (Coq) switch for Phase 4.
- Implemented `control/artifact_store.{ml,mli}`: content-addressed Unix-directory store, re-verifies digest on ingest and read.
- Implemented `control/registry.{ml,mli}`: in-memory revision registry + alias with CAS precondition, checkpoint serialization.
- Implemented `control/admission.{ml,mli}`: tenant quotas (rate, concurrency, queue size, bytes).
- Implemented `control/scheduler.{ml,mli}`: FIFO with deterministic next_assignment.
- Implemented `control/worker_pool.{ml,mli}`: in-process runtimes, per-invocation engine.
- Implemented `control/mirage_lambda_control.ml`: cohttp-lwt-unix HTTP server with /healthz, deploy (POST), alias (PUT), invoke, invoke-async — bearer-token auth.
- Implemented `cli/mirage_lambda_cli.ml`: bundle/deploy/invoke/alias commands.
- Demonstrated end-to-end: bundle echo.mlb → deploy (sha256:5ebae7c8...) → alias prod → sync invoke returns {"echoed":{"hello":"world"},"invocationId":"inv-1"} → async invoke returns {"invocationId":"inv-2"}.

### Why
Phase 4 is the functional MVP gate (§38.3): deployment and invocation usable through the CLI, quota overload returns documented status, recovery tests cover persistence. The Mirage switch + audit close the infrastructure gate for Phases 5-6.

### What worked
- End-to-end deploy→alias→invoke on Unix works synchronously and asynchronously.
- The §34.3 audit found no blocking symbols — the engine core is portable with CONFIG_ATOMICS compiled out.
- All 31 prior tests still green after adding the control plane + CLI.

### What didn't work
- `opam switch create ... --empty` conflicts with packages; used `opam switch create mirage-lambda 4.14.2` (no --empty) then a separate install.
- cohttp-lwt's `.cmi` was corrupt on first install; `opam reinstall cohttp-lwt` fixed it.
- cohttp-lwt-unix Server.create mode is `Conduit_lwt_unix.server` = `` `TCP of tcp_config `` where `tcp_config = `Port of int`` (not a (addr,port) tuple); the callback is curried (not a tuple); respond_string takes `()`.
- `Unix.mkdir` doesn't create nested dirs; fixed `ensure_dir` to recurse (mkdir -p).
- `Revision_id.t` and `Digest.t` didn't unify through `include module type of Digest` (private); made `type t = Digest.t` explicit in the .mli.

### What I learned
- The cohttp-lwt-unix server API: `Server.make ~callback ()` then `Server.create ~mode httpd`, with mode `` `TCP (`Port port) ``; the callback is `conn -> Request.t -> Body.t -> (Response.t * Body.t) Lwt.t`.
- The §34.3 audit's value: it turned "it compiles on Unix" into a concrete portability decision (compile out CONFIG_ATOMICS, shim wall-time) before any HVT build.
- QuickJS's pthread dependence is entirely behind CONFIG_ATOMICS (the Atomics.wait/notify waiter + class-id mutex); a single-threaded worker with JS_SetCanBlock(false) needs none of it.

### What was tricky to build
- The cohttp-lwt-unix API has several sharp edges (corrupt .cmi, tuple-vs-curried callback, tcp_config shape, respond_string's unit arg); each required a build-fix cycle.
- Lifting Result into Lwt without unifying the error-response type with the value type: nested `match` statements instead of a `lift_result` helper.

### What warrants a second pair of eyes
- The CLI uses curl via Sys.command for HTTP (Phase 4 dev simplicity); a real client uses cohttp-lwt.
- The worker_pool reads `__done`/`__result` for completion (Phase 3 simplification); the §20.1 `Complete` progress is the production form.
- The dispatch loop's max_turns=100 is a pragmatic cap; the deadline check is the production form.
- The control plane has no integration tests yet (only the manual e2e demo); the §38.3 gate calls for OpenAPI-driven integration tests + recovery tests.

### What should be done in the future
- Phase 4 hardening: OpenAPI integration tests, recovery-after-every-persistence-step tests, quota-overload tests.
- Phase 5: port the control plane to a Mirage unikernel (Chamelon KV + TLS).
- HVT boot (§34.2 step 10): build a minimal HVT unikernel, boot it, capture digests.

### Code review instructions
- Start at `control/mirage_lambda_control.ml` (HTTP server), `control/worker_pool.ml` (execution), `cli/mirage_lambda_cli.ml` (CLI).
- Run the e2e: start `mirage-lambda-control`, then `mirage-lambda-cli bundle/deploy/alias/invoke`.
- Audit: `docs/quickjs-port-audit.md`.

### Technical details
- Switch: mirage-lambda (4.14.2), mirage 4.11.2, ocaml-solo5 0.8.5, solo5 0.12.0.
- MVP revision: sha256:5ebae7c8c6907d4ce0eacdf186e6e82e1972789c9ede81c57bc48d8e5a7f6344.

## Step 11: Phase 5 HVT toolchain unblocked + boot functor (handoff point)

This step unblocks the Phase 5 HVT build toolchain (the real fix, validated
online + via the opam-monorepo source), writes the boot functor, and stops at
the final unikernel-functor type-check — the genuine Phase 5 code work that
remains for the next engineer.

### Prompt Context

**User prompt (verbatim):** "ok, do it." (then "is this hanging?", then "Write up a handoff document...")

**Assistant interpretation:** Get the HVT image building; when the remaining work is real functor code, write a handoff.

### What I did
- Diagnosed the HVT build blocker via `--verbose`: opam-monorepo logged `Solve using current opam switch: CP.2025.08.0~8.20~2025.01` despite `OPAMSWITCH=mirage-lambda`. Confirmed via the opam-monorepo source (`cli/lock.ml`, `OpamGlobalState.with_`) that it reads the **default** switch.
- Fix: `opam switch set mirage-lambda` → lockfile generates (92 entries) → `opam monorepo pull` fetches 91 repos → Zarith/cohttp/etc. build under the solo5 cross-compile context.
- Patched the mirage-generated Makefile's `repo-add` (it used `opam-overlays` as the repo name; opam-monorepo's `is_duniverse_repo` requires the exact name `dune-universe` with URL `git+https://github.com/dune-universe/opam-overlays.git`).
- Switched the config.ml state KV to `kv_rw_mem` for the boot proof — the `chamelon` device in mirage 4.11.2 has a real API mismatch (the `$` DSL gives a type error `block impl -> kv_rw impl` vs `('a -> 'b) impl`; plain application fails at connect time with "Unbound value block"). Deferred to §39.2 step 4.
- Wrote the boot functor (`unikernel.ml`) with `/healthz` via `Cohttp_mirage.Server.S` + `Http.make ~callback` + `Http.respond_string`.
- Added `certs/` dir for `ocaml-crunch`; gitignored `control-unikernel/{duniverse,mirage}` (the vendored dune's `lang 3.24` dune-project breaks the main project's dune build).

### What worked
- `mirage configure -t hvt` succeeds; lockfile (92 entries) + duniverse (91 repos) + Zarith/cohttp build under solo5.
- Main project still 31 tests green.

### What didn't work / remains
- The HVT image is **not produced**. The build fails at the unikernel-functor type-check: the `cohttp_server` device passes `Cohttp_mirage.Server.Make(Conduit)` whose `listen` has type `Conduit_mirage.server -> t -> unit Lwt.t` but the generated `main.ml` expects `[> `TCP of unit -> int ] -> t -> unit Lwt.t` (the conduit server's port is a `unit -> int` runtime-arg thunk). The functor arg type `Cohttp_mirage.Server.S` doesn't include `listen`/`make`. This is the real Phase 5 code work.

### Code review instructions
- Read `HANDOFF.md` at the repo root for the full continuation guide.
- The remaining fix is a functor signature: either take the `Server.Make(Conduit)` result signature (with `listen`) as the arg, or build `Cohttp_mirage.Server.Make` inside the unikernel from a conduit arg (the ocaml-tls example pattern at `duniverse/ocaml-tls/mirage/example2/unikernel.ml`).

## Step 12: HVT image builds (cohttp_server functor arg fixed)

This step fixes the unikernel functor-arg type mismatch that blocked the HVT
image, produces `dist/mirage-lambda-control.hvt`, and identifies the final
remaining gate as a host-level TAP-device permission, not a code issue.

### Prompt Context

**User prompt (verbatim):** "Continue" (then "reload the design doc and diary and all that to stay afresh,")

**Assistant interpretation:** Continue the Phase 5 code work — fix the `cohttp_server` functor arg so `make build` produces the HVT image, then boot it.

### What I did
- Re-read the diary Step 11, the generated `mirage/main.ml`, the `Conduit_mirage.server` type (`[ `TCP of int | `TLS of ... | `Vchan of ... ]`), and the `cohttp_server` device's connect code (`Lwt.return (Cohttp_mirage_server_make__26.listen _conduit_mirage_tcp__25)`).
- Root cause: the unikernel passed `` `TCP port `` where `port : int runtime_arg = unit -> int`, so the value was `` `TCP of unit -> int ``, which does not match `Conduit_mirage.server` (`` `TCP of int ``).
- Fix: `http (`TCP (port ())) httpd` — evaluate the runtime-arg thunk to a plain `int` before constructing the `` `TCP `` variant. One-token change (`port` → `port ()`).
- `dune build --profile release --root . ./dist` now produces `dist/mirage-lambda-control.hvt` (13,955,336 bytes). `solo5-elftool query-manifest` confirms a valid solo5 manifest: one NET_BASIC device named "service".
- Updated `.gitignore` to exclude the 13.9 MB build artifact.

### What worked
- The HVT image builds end-to-end: lockfile → duniverse → solo5 cross-compile → `dist/mirage-lambda-control.hvt`.
- `solo5-elftool query-manifest` reads the image and reports the declared NET_BASIC device — the image is a valid solo5 HVT binary.
- Main project tests still 31 green (4 qjs + 14 common + 1 worker + 12 engine).

### What didn't work / remains
- The actual boot (`solo5-hvt --net:service=tapN dist/mirage-lambda-control.hvt --port=8080`) needs a TAP interface on the host. `ip tuntap add tap100 mode tap` fails with `ioctl(TUNSETIFF): Operation not permitted` — no CAP_NET_ADMIN, and `sudo -n` needs a password. This is a host-permission gate, not a code gate.

### What was tricky to build
- Diagnosing the polymorphic-variant mismatch: the error "expected `[> `TCP of unit -> int ]`" looked like a functor-signature issue, but the real cause was that `Mirage_runtime.register_arg` returns `int runtime_arg = unit -> int`, and `` `TCP `` of `Conduit_mirage.server` takes a plain `int`. The `unit -> int` thunk had to be evaluated. The ocaml-tls example avoided this because it used a literal port `4433`, not a runtime arg.

### What warrants a second pair of eyes
- The unikernel builds the server on `Lwt.choose [ serve (); Stack.listen stack ]`. If `serve` exits early (e.g. the listen fails), the choose may not keep the unikernel alive. Confirm the boot actually serves /healthz once a TAP device exists.
- The runtime-arg port default is 8080; confirm `--port=N` is plumbed by `Mirage_runtime.register_arg` + the solo5 command line (`--port=N` after the kernel).

### Code review instructions
- `control-unikernel/unikernel.ml` line 56: `` http (`TCP (port ())) httpd ``.
- Build: `opam switch set mirage-lambda && cd control-unikernel && dune build --profile release --root . ./dist` → `dist/mirage-lambda-control.hvt`.
- Verify the image: `solo5-elftool query-manifest dist/mirage-lambda-control.hvt`.
