# Mirage Lambda Service

A JavaScript function-as-a-service built from [MirageOS] unikernels.

Users deploy small ECMAScript modules, assign explicit capabilities and resource
limits, and invoke named function revisions through an authenticated HTTPS API.
[QuickJS] supplies the language runtime; [Solo5] HVT supplies the hardware-virtualized
guest boundary; a minimal host launcher creates, destroys, and supervises worker
unikernels.

This repository implements the design in
[`mirage_lambda_service_implementation_guide.md`](./mirage_lambda_service_implementation_guide.md).
Delivery is staged into 11 phases (Phase 0–10); see
[the phase map](./ttmp/2026/08/25/MIRAGE-LAMBDA--mirage-lambda-service-js-faas-from-mirageos-unikernels/design-doc/01-implementation-plan-and-phase-map.md).

## Repository layout

```
mirage-lambda/
├── common/    pure domain model (ids, budget, capability, manifest, bundle, protocol) — Phase 1
├── qjs/       QuickJS port + OCaml/C wrapper (vendor/, c/, lib/, test/) — Phase 0/2
├── control/   control-plane unikernel — Phase 4/5
├── worker/    worker unikernel + capability broker — Phase 3/6
├── launcher/  host launcher adapters (fake, unix, albatross) — Phase 7
├── cli/       developer CLI — Phase 4
├── api/       OpenAPI + JSON Schema fixtures — Phase 1
├── test/      unit / integration / e2e / fuzz / fault — Phase 1+
├── deploy/    albatross / systemd / network / certs / scripts — Phase 5+
├── docs/      architecture, threat-model, operations, adr/, evidence/ — Phase 0+
└── scripts/   build + probe scripts — Phase 0
```

## Status

| Phase | Status | Notes |
|---|---|---|
| 0 — Feasibility & toolchain lock | scaffolded | toolchain pinned; QuickJS probes scaffolded; Unix C run + HVT boot pending QuickJS vendoring + Solo5 switch |
| 1 — Pure common library | in progress | `common/` + property tests |
| 2–10 | not started | |

## Build (Unix, Phase 1)

```bash
eval $(opam env)
opam install . --deps-only --with-test   # after Phase 1 deps land
dune build
dune runtest
```

[MirageOS]: https://mirage.io/
[QuickJS]: https://bellard.org/quickjs/
[Solo5]: https://github.com/Solo5/solo5
