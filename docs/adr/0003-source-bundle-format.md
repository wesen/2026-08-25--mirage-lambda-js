# ADR 0003 — Deterministic source bundle format (MLB1)

- **Status:** proposed
- **Date:** 2026-08-25
- **Phase:** 1

## Context
ZIP introduces path and parser complexity unnecessary for a small module
graph (§10.4). Bundling happens outside the unikernel (§10.1).

## Decision
Use the versioned `MLB1` format: magic + lengths + canonical header/manifest
JSON + modules sorted by normalized path with per-module SHA-256 + footer
SHA-256 over all preceding bytes (§10.4). Phase 1 implements the parser/writer
in `common/bundle.ml` with overflow/duplicate/path-segment validation and
property tests.

## Consequences
- Canonical encoding enables digest stability and fuzzing.
- No decompression/native-build hooks in the worker.
- Module resolution is limited to `./`, `../`, and `cap:` virtual modules (§10.5).

## Status note
Accepted at the Phase 1 gate when the bundle parser passes property + fuzz tests.
