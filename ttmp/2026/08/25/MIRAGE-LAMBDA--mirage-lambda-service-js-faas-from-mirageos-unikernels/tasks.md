# Tasks

## TODO

- [x] P0: Feasibility and toolchain lock (repo skeleton, ADR, scripts, probe scaffolding, evidence; QuickJS vendored; §34.3 audit done; mirage-lambda switch built)
- [x] P1: Domain model, schemas, and pure common library (common/*, api/*, property tests)
- [x] P2: QuickJS embedding on Unix — real engine, 9/11 probe steps proven (31 tests green)
- [x] P3: Unix worker runtime (worker/*, fake capabilities, host API, dispatch loop)
- [x] P4: Single-appliance service on Unix (control/*, CLI, end-to-end deploy/alias/invoke MVP)
- [~] P5: Mirage control-plane unikernel — config.ml + boot functor; `mirage configure -t hvt` + lockfile + duniverse + **`make build` produces `dist/mirage-lambda-control.hvt`** (cohttp_server functor arg fixed); **HVT boot not yet run** (needs a TAP device → CAP_NET_ADMIN/sudo on the host)
- [ ] P5-followup-B: Boot the HVT image with `solo5-hvt --net:service=tapN dist/mirage-lambda-control.hvt --port=8080` (create a TAP device with `ip tuntap add tapN mode tap` + `ip link set tapN up`) and curl `http://<unikernel-ip>/healthz` → closes §34.2 step 10
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
- **P5-followup-A done: the HVT image builds** (`dist/mirage-lambda-control.hvt`, 13.9 MB; solo5 manifest = one NET_BASIC device "service"). The cohttp_server functor arg type is fixed: `` `TCP (port ()) `` evaluates the runtime-arg thunk to a plain `int` to match `Conduit_mirage.server = [ `TCP of int | ... ]`.
