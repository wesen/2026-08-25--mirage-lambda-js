---
Title: Implementation plan and phase map
Ticket: MIRAGE-LAMBDA
Status: active
Topics:
    - mirage
    - unikernel
    - ocaml
    - quickjs
    - lambda
    - capability-security
DocType: design-doc
Intent: long-term
Owners: []
RelatedFiles:
    - Path: repo://common/ids.ml
      Note: Validated identifier types (§35.2)
    - Path: repo://mirage_lambda_service_implementation_guide.md
      Note: Source design and implementation guide this ticket implements
    - Path: repo://ttmp/2026/08/25/MIRAGE-LAMBDA--mirage-lambda-service-js-faas-from-mirageos-unikernels/tasks.md
      Note: Phase task checklist
ExternalSources: []
Summary: Maps the Mirage Lambda Service guide to 11 delivery phases (0-10) and records scope, exit gates, and what each phase produces.
LastUpdated: 2026-08-25T17:19:21.572379786-04:00
WhatFor: Tracking the phased implementation of the Mirage Lambda Service against the source guide.
WhenToUse: Read before starting any phase to understand its objective, exit gate, and dependency edges.
---





# Implementation plan and phase map

## Executive Summary

The Mirage Lambda Service is a JavaScript function-as-a-service whose service plane and
execution workers are MirageOS unikernels. Users deploy small ECMAScript modules, assign
explicit capabilities and resource limits, and invoke named function revisions through an
authenticated HTTPS API. QuickJS supplies the language runtime; Solo5 HVT supplies the
hardware-virtualized guest boundary; a minimal host launcher (Albatross-compatible) creates,
destroys, and supervises worker unikernels.

The guide (`mirage_lambda_service_implementation_guide.md`, 5081 lines) defines a staged
delivery in **11 phases (Phase 0-10)** that separates three classes of uncertainty:
language-runtime uncertainty (QuickJS embedding), unikernel portability uncertainty
(Solo5 HVT), and distributed-service uncertainty (scheduling, leases, recovery).

## Problem Statement

Implement the guide faithfully, in phase order, behind stable interfaces, so each phase's
exit gate is backed by evidence (merged code + automated tests + updated schemas + an
executable demonstration + an evidence report). The first session delivers the foundational,
fully-Unix-targetable phases (Phase 0 and Phase 1) and scaffolds the later phases.

## Proposed Solution

Work proceeds bottom-up. Phase 0 locks the toolchain and proves the smallest QuickJS
facilities. Phase 1 defines all cross-boundary semantics as pure, fuzzable OCaml in `common/`.
Phase 2 builds the auditable QuickJS OCaml/C wrapper on Unix. Phase 3 realizes execution
semantics in-process with fake capabilities. Phase 4 assembles the single-appliance MVP.
Phases 5-6 port control plane and worker to Mirage/Solo5 HVT. Phase 7 adds fleet
orchestration. Phase 8 hardens capability security and egress. Phase 9 runs reliability,
security, and performance campaigns. Phase 10 reaches production readiness.

## Design Decisions

- **One repository, two Mirage entry points.** `common/` is pure; `qjs/` owns all QuickJS C;
  `control/` and `worker/` are the unikernels; `launcher/`, `cli/`, `test/`, `deploy/` are host-only.
- **`common/` has no Unix/Lwt/Mirage/TLS/QuickJS dependencies.** Pure code is reused by CLI,
  control, worker, and tests and is fuzzable on its own.
- **Identifiers are abstract types with validated constructors**, never raw strings, so they
  can never form an invalid storage path.
- **Phase 1 first.** It is the dependency-free foundation everything else imports.

## Alternatives Considered

- Implementing multiple phases at once: rejected; the guide's stage-gate rule forbids
  advancing on a happy-path demo without evidence.
- Skipping Phase 0 (toolchain lock): rejected; the C/freestanding compatibility surface is
  unknown until compiled.

## Implementation Plan — Phase Map

Each phase below lists its objective, effort class, primary outputs, exit gate, and
dependency edges. Phases 0-4 are Unix-targetable; 5-6 require Solo5 HVT; 7-10 require the
fleet.

### Phase 0 — Feasibility and toolchain lock  (effort XL)
- **Objective:** prove exact toolchain + smallest QuickJS facilities work on Unix and HVT.
- **Outputs:** `docs/adr/0000-toolchain-baseline.md`, vendored QuickJS, Unix + HVT probes
  (`qjs/test/probe.{ml,js}`, `qjs/c/qjs_port_{unix,solo5}.c`), build scripts,
  `docs/evidence/phase-0.md`, `opam.locked`.
- **Exit gate:** both probes run on pinned toolchain; limits fail cleanly; interrupt
  terminates infinite loop; async Promise settlement works without foreign-thread re-entry;
  HVT image boots and reports digests; no critical unresolved libc symbol; go/no-go record.
- **Session scope:** repo skeleton + ADR + toolchain pin + build scripts + probe scaffolding
  + evidence doc. Unix C compile + Solo5 HVT boot require QuickJS vendoring and a Solo5
  switch install (documented gap for a follow-up).

### Phase 1 — Domain model, schemas, and pure common library  (effort L)
- **Objective:** define service semantics as pure OCaml types + deterministic encoders.
- **Outputs:** `common/{ids,bounded_bytes,error,budget,capability,manifest,bundle,protocol,canonical_json}.{ml,mli}`,
  JSON Schema + OpenAPI fixtures under `api/`, property tests + fuzz harness.
- **Exit gate:** schemas/decoders agree on valid+invalid fixtures; cross-boundary types have
  explicit version fields; public errors have stable codes; fuzzing finds no crash; `common/`
  builds without accidental Unix deps.
- **Dependencies:** Phase 0 toolchain. **Session target: fully complete.**

### Phase 2 — QuickJS embedding on Unix  (effort XL)
- **Objective:** minimal auditable engine library with hard ownership + accounting.
- **Outputs:** `qjs/c/*` (stubs, allocator, host queue, port headers), `qjs/lib/*`
  (handle, engine, module loader, host request), engine tests.
- **Exit gate:** wrapper passes all Phase 0 probes via public OCaml interface; foreign
  primitives documented (alloc/raise/release-lock/call-QuickJS); invalid source/module graphs
  cannot crash under sanitizers; precise resource-exhaustion classes; safe destruction after
  failure; no user bytecode path.

### Phase 3 — Unix worker runtime  (effort L)
- **Objective:** complete execution semantics in a normal process with fake capabilities.
- **Outputs:** `worker/{invocation,runtime_host,capability_broker,host_*,artifact_cache,telemetry}`,
  small JS host API (`env.log`, `env.clock`, `env.random`, scripted fakes).
- **Exit gate:** end-to-end invocation on Unix; resource limits enforced; cancellation
  works; host calls are async + metered.

### Phase 4 — Single-appliance service on Unix  (effort L)
- **Objective:** end-to-end MVP: deploy + invoke via HTTPS on one Unix process.
- **Outputs:** `control/{ingress,auth,admin_api,invoke_api,artifact_store,registry,
  metadata_writer,admission,scheduler,worker_pool,launcher_client,recovery,telemetry}`
  with in-memory/fake backends; CLI `cli/*`.
- **Exit gate:** deploy a bundle; resolve an alias; invoke sync + async; observe logs/metrics;
  crash-recover from journal.

### Phase 5 — Mirage control-plane unikernel  (effort L)
- **Objective:** port control plane to a Mirage unikernel over a KV block device + TLS.
- **Exit gate:** unikernel boots; serves API over TLS; persists state to Chamelon image;
  restart recovers from checkpoint.

### Phase 6 — Mirage QuickJS worker unikernel  (effort L)
- **Objective:** port worker + QuickJS to Solo5 HVT.
- **Exit gate:** HVT worker boots; runs the Phase 0 probe; enforces limits; handles malformed
  internal protocol; recycles.

### Phase 7 — Fleet orchestration and scheduling  (effort L)
- **Objective:** launcher adapter + warm pool + reconciliation.
- **Exit gate:** create/drain/destroy workers; warm pool maintained; assignment leases
  enforced; fake launcher fault modes pass.

### Phase 8 — Capability security, egress, and secrets  (effort L)
- **Objective:** capability compiler, egress policy, secret handling.
- **Exit gate:** JS API gated by compiled policy; SSRF blocked; operation-capability secrets.

### Phase 9 — Reliability, security, and performance hardening  (effort XL)
- **Objective:** reliability/security/performance campaigns + fault injection + fuzzing.

### Phase 10 — Production readiness and optional research extensions  (effort XL)
- **Objective:** release qualification, backups, rolling updates, optional deterministic log /
  movable boundaries / snapshot cold-start / per-invocation microVM.

## Open Questions

- Exact pinned versions for Mirage/Solo5/ocaml-solo5/TLS/HTTP/KV/crypto (locked in Phase 0).
- QuickJS release to vendor (guide references `quickjs-2026-06-04`); confirm archive digest.
- Solo5 HVT tender + Albatross versions for integration tests.

## References

- Source guide: `mirage_lambda_service_implementation_guide.md` (sections 19, 20, 33-44,
  appendices A-C).
