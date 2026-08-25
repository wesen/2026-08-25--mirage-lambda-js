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
RelatedFiles: []
ExternalSources: []
Summary: "Chronological diary of the Mirage Lambda Service implementation, following the diary skill format."
LastUpdated: 2026-08-25T17:20:00.000000000-04:00
WhatFor: "Recording what changed, why, what worked/failed, and how to review each phase."
WhenToUse: "Read before resuming work on MIRAGE-LAMBDA to recover context."
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
