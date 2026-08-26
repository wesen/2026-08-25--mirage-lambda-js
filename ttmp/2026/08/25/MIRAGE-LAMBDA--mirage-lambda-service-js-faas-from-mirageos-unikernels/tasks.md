# Tasks

## TODO

- [x] P0: Feasibility and toolchain lock (repo skeleton, ADR, scripts, probe scaffolding, evidence; QuickJS vendored; §34.3 audit done; mirage-lambda switch built)
- [x] P1: Domain model, schemas, and pure common library (common/*, api/*, property tests)
- [x] P2: QuickJS embedding on Unix — real engine, 9/11 probe steps proven (31 tests green)
- [x] P3: Unix worker runtime (worker/*, fake capabilities, host API, dispatch loop)
- [x] P4: Single-appliance service on Unix (control/*, CLI, end-to-end deploy/alias/invoke MVP)
- [~] P5: Mirage control-plane unikernel — config.ml + boot functor written; `mirage configure -t hvt` + lockfile + duniverse build now work; **HVT image not yet produced** (blocked on the `cohttp_server` functor arg type; see HANDOFF.md)
- [ ] P5-followup-A: Fix the `cohttp_server` functor arg so the unikernel builds → produce `dist/mirage-lambda-control.hvt`
- [ ] P5-followup-B: Boot the HVT image with `solo5-hvt` → closes §34.2 step 10 (the only open probe gate)
- [ ] P5-followup-C: Wire the Chamelon state KV (the `chamelon` device API mismatch; §39.2 step 4)
- [ ] P5-followup-D: Wire TLS (§39.2 step 2) + the KV-backed registry (step 3)
- [ ] P6: Mirage QuickJS worker unikernel (Solo5 HVT)
- [ ] P7: Fleet orchestration and scheduling
- [ ] P8: Capability security, egress, and secrets
- [ ] P9: Reliability, security, and performance hardening
- [ ] P10: Production readiness and optional research extensions

## DONE

- P0–P4 complete on Unix (31 tests green across common/qjs/engine/worker).
- Phase 5 HVT toolchain unblocked (opam-monorepo default-switch fix; lockfile 92 entries; duniverse 91 repos).
- §34.3 missing-symbol audit complete (no engine patch needed; compile out CONFIG_ATOMICS, shim wall-time).
