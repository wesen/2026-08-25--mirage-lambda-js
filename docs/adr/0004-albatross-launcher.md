# ADR 0004 — Albatross-compatible host launcher

- **Status:** proposed
- **Date:** 2026-08-25
- **Phase:** 7

## Context
Solo5 intentionally provides no orchestration (§7.3). Something must create,
destroy, and supervise worker unikernels.

## Decision
Use Albatross (or an adapter compatible with it) as the privileged-but-narrow
host launcher (§7.1, §27.1). The adapter implements the `LAUNCHER` interface
(§20.6); a fake launcher supports scripted failure modes for fault tests.

## Consequences
- The launcher is privileged but narrow; its trust surface is explicit.
- Worker boot args, network topology, and egress are launcher/stack concerns (§27.2, §16).

## Status note
Accepted at the Phase 7 gate when the fake + Albatross adapters pass fault tests.
