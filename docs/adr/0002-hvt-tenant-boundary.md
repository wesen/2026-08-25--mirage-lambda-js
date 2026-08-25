# ADR 0002 — HVT as the tenant boundary

- **Status:** proposed
- **Date:** 2026-08-25
- **Phase:** 6

## Context
A QuickJS `JSRuntime` is a language-level containment unit, not a native
memory-protection boundary (§Security scope, §4.1). Hostile tenants need a
stronger boundary.

## Decision
The hard isolation unit is a Solo5 HVT worker VM: normally one tenant per VM
and one active compute-bound invocation per worker (§4.2). The control plane
and a minimal host launcher (ADR 0004) create/destroy/supervise workers.

## Consequences
- Requires a dedicated Mirage opam switch (ADR 0000).
- Worker boot, lease, and recycling semantics are part of the contract (§25, §41).
- Single-appliance mode (Phase 4) remains valuable for trusted/development use.

## Status note
Accepted at the Phase 6 gate when the HVT worker boots and runs the probe.
