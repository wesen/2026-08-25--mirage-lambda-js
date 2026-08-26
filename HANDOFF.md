# HANDOFF — Mirage Lambda Service (MIRAGE-LAMBDA)

**Date:** 2026-08-25
**From:** the session that built Phases 0–4 + started Phase 5
**To:** next engineer
**Ticket:** `MIRAGE-LAMBDA` — `ttmp/2026/08/25/MIRAGE-LAMBDA--mirage-lambda-service-js-faas-from-mirageos-unikernels/`
**Source guide:** `mirage_lambda_service_implementation_guide.md` (5,081 lines; the spec)

> Read this first, then the diary (`.../reference/01-investigation-diary.md`),
> then the design doc (`.../design-doc/01-implementation-plan-and-phase-map.md`).

---

## What this project is

A JavaScript function-as-a-service whose service plane and execution workers
are MirageOS unikernels. Users deploy small ECMAScript modules with explicit
capabilities and resource limits; the service invokes named function revisions
over an authenticated HTTPS API. QuickJS is the JS runtime; Solo5 HVT is the
guest boundary; a minimal host launcher creates/destroys worker unikernels.
Delivery is staged into 11 phase-gated phases (0–10).

## Where things stand

| Phase | Status | Evidence |
|---|---|---|
| 0 — Feasibility & toolchain | ✅ done | QuickJS 2026-06-04 vendored (SHA-256 `b376e839…`); engine core compiles under ASan/UBSan; §34.3 audit done; `mirage-lambda` opam switch built (mirage 4.11.2, ocaml-solo5 0.8.5, solo5 0.12.0) |
| 1 — Pure common library | ✅ done | 9 modules in `common/`, `api/` schemas, 14 unit + 3 fuzz tests |
| 2 — QuickJS embedding | ✅ done | Real engine: create/eval/module-loader/async-Promise/limits/interrupt/rejection; **9/11 §34.2 probe steps proven** (12 engine tests) |
| 3 — Unix worker runtime | ✅ done | invocation, capability broker, host fakes, dispatch loop, end-to-end test |
| 4 — Single-appliance MVP | ✅ done | control plane (HTTP server) + CLI; end-to-end deploy→alias→invoke demoed |
| 5 — Mirage control-plane unikernel | 🟡 in progress | config + boot functor written; HVT toolchain unblocked; **HVT image not yet built** (see below) |
| 6–10 | not started | worker HVT, fleet, security, hardening, production |

**Tests:** 31 green (14 common + 4 qjs + 12 engine + 1 worker) on the Unix
(Coq) switch. The control-unikernel builds under the `mirage-lambda` switch.

## The one thing blocking the HVT image (your starting point)

The HVT build now reaches the final unikernel-functor type-check and fails
there. Everything upstream (lockfile, duniverse, Zarith/cohttp cross-compile)
works. The remaining issue is a **functor signature mismatch** in
`control-unikernel/unikernel.ml`:

```
File "mirage/main.ml", line 353:
Error: This expression has type
         Conduit_mirage.server -> Cohttp_mirage_server_make__26.t -> unit Lwt.t
       but an expression was expected of type
         [> `TCP of unit -> int ] -> Cohttp_mirage_server_make__26.t -> unit Lwt.t
```

**Cause:** the `cohttp_server` device (in `config.ml`) passes
`Cohttp_mirage.Server.Make(Conduit)` as the `Http` functor argument. That
module's `listen` has type `Conduit_mirage.server -> t -> unit Lwt.t`, but the
conduit produced by `conduit_direct ~tls:false stack` uses a `unit -> int`
port-thunk for the `` `TCP `` variant (a runtime arg), so the generated
`main.ml` expects `[> `TCP of unit -> int ] -> ...`. My functor arg type
`Cohttp_mirage.Server.S` doesn't include `listen`/`make`, so the wiring
type-mismatches.

**Two ways to fix it (pick one):**

1. **Take the made-module signature as the functor arg.** Instead of
   `Http : Cohttp_mirage.Server.S`, take the result signature of
   `Cohttp_mirage.Server.Make(Conduit)` — i.e. a module type that includes
   `listen` and `make` with the `unit -> int` port-thunk. This is what the
   device actually passes.

2. **Build the server inside the unikernel (the ocaml-tls pattern).** Drop
   `Http` as a functor arg; take the conduit/flow instead, and construct
   `module Http = Cohttp_mirage.Server.Make(Conduit)` inside `unikernel.ml`,
   then `Http.listen httpd (`TCP port)`. Reference:
   `control-unikernel/duniverse/ocaml-tls/mirage/example2/unikernel.ml` does
   exactly this (it builds `Cohttp_mirage.Server(TLS)` inside and calls
   `Http.listen t tls`).

Either way, once the functor type-checks, `make build` (or
`dune build --profile release --root . ./dist` under the mirage-lambda switch)
produces `dist/mirage-lambda-control.hvt`, and `solo5-hvt
dist/mirage-lambda-control.hvt` boots it — closing §34.2 step 10, the only
open probe gate.

## How to build / run (the two switches)

There are **two opam switches**. Use the right one for each task.

```bash
# Unix project (common/qjs/worker/control/cli + tests) — the Coq-platform switch
eval $(opam env --switch=CP.2025.08.0~8.20~2025.01)
dune build
dune runtest --force          # 31 tests
./_build/default/control/mirage_lambda_control.exe   # the HTTP server
./_build/default/cli/mirage_lambda_cli.exe          # the CLI

# Mirage unikernel (control-unikernel) — the dedicated mirage-lambda switch
opam switch set mirage-lambda          # MUST be the default switch (see below)
eval $(opam env --switch=mirage-lambda)
cd control-unikernel
mirage configure -t hvt --extra-repos=opam-overlays:https://github.com/dune-universe/opam-overlays.git,mirage-overlays:https://github.com/dune-universe/mirage-opam-overlays.git
# patch Makefile repo-add (see "Gotchas" below) then:
make                                    # lock + pull + build → dist/*.hvt
solo5-hvt dist/mirage-lambda-control.hvt
```

**End-to-end MVP demo (Unix):**
```bash
mkdir -p /tmp/ml/state && cd /tmp/ml/state
/home/manuel/.../control/mirage_lambda_control.exe &   # server on :8080, token dev-token
mirage-lambda-cli bundle manifest.json index.js -o echo.mlb
mirage-lambda-cli deploy echo.mlb -t default -f echo   # → sha256:...
mirage-lambda-cli alias default echo prod <digest>
mirage-lambda-cli invoke default echo prod -e '{"hello":"world"}'
```

## Critical gotchas (these cost real time)

1. **opam-monorepo reads the DEFAULT switch, not `OPAMSWITCH`.** If `opam
   switch show` says `mirage-lambda` but the lockfile fails with "dune-universe
   doesn't appear to be set up", run `opam switch set mirage-lambda` (sets the
   default). Validated via the opam-monorepo source (`cli/lock.ml`,
   `OpamGlobalState.with_`).

2. **The mirage-generated `Makefile`'s `repo-add` uses the wrong repo name.**
   It writes `opam repo add opam-overlays https://...`, but opam-monorepo's
   `is_duniverse_repo` requires the exact name `dune-universe` with URL
   `git+https://github.com/dune-universe/opam-overlays.git`. After every
   `mirage configure`, patch the Makefile:
   ```bash
   sed -i 's|repo add opam-overlays https://github.com/dune-universe/opam-overlays.git|repo add dune-universe git+https://github.com/dune-universe/opam-overlays.git|' Makefile
   sed -i 's|repo set-url opam-overlays https://github.com/dune-universe/opam-overlays.git|repo set-url dune-universe git+https://github.com/dune-universe/opam-overlays.git|' Makefile
   sed -i 's|repo remove opam-overlays https://github.com/dune-universe/opam-overlays.git|repo remove dune-universe|g' Makefile
   ```

3. **The vendored dune's `lang 3.24` dune-project breaks the main project's
   dune build.** `control-unikernel/duniverse/dune_/dune-project` declares
   `(lang dune 3.24)`, which the Coq switch's dune 3.19 doesn't support. If you
   `dune build` the main project and get "Version 3.24 of the dune language is
   not supported", move `control-unikernel/duniverse` aside (or build from a
   dir that excludes it). The duniverse is gitignored; only present after
   `make pull`.

4. **Switch back to the Coq switch for the main project.** After working in
   `control-unikernel`, run `opam switch set CP.2025.08.0~8.20~2025.01` or the
   main project's dune/build won't find the right libraries.

5. **`chamelon` device API mismatch (deferred).** The `chamelon` device in
   mirage 4.11.2: `chamelon ~program_block_size` returns `block impl -> kv_rw
   impl` (an OCaml function), not `(block -> Kv.rw) impl`; the `$` DSL operator
   gives a type error, and plain application fails at connect time. The config
   currently uses `kv_rw_mem ()` for the boot proof. Wiring the durable
   Chamelon-over-block store is §39.2 step 4 — check the chamelon duniverse
   source (`duniverse/chamelon/mirage_test/`) for the right calling convention.

## What to read (in order)

1. **This file** (`HANDOFF.md`).
2. **The diary** — `ttmp/2026/08/25/MIRAGE-LAMBDA--.../reference/01-investigation-diary.md` (11 chronological steps; each has what worked/failed/tricky).
3. **The phase map** — `ttmp/2026/08/25/MIRAGE-LAMBDA--.../design-doc/01-implementation-plan-and-phase-map.md`.
4. **The §34.3 audit** — `docs/quickjs-port-audit.md` (why no engine patch is needed for HVT).
5. **The guide** — `mirage_lambda_service_implementation_guide.md` §39 (Phase 5), §26 (control-plane impl), §34.2 (the probe), §22–24 (the FFI).
6. **The reference unikernel** — `control-unikernel/duniverse/ocaml-tls/mirage/example2/unikernel.ml` (the pattern for fixing the functor).

## Key code locations

- `common/` — pure domain library (ids, budget, capability, manifest, bundle+SHA-256, protocol, canonical_json). No Unix/Lwt/Mirage/QuickJS deps.
- `qjs/c/qjs_stubs.c` — the real QuickJS FFI (create/eval/module-loader/Promise-bridge/pump/cancel). The canonical copy; `qjs/lib/qjs_stubs.c` is a duplicate for the dune foreign_stubs build.
- `qjs/lib/qjs_engine.{ml,mli}` — the §20.1 `QJS_ENGINE` interface the worker imports.
- `worker/runtime_host.ml` — the dispatch loop (§23.2).
- `control/mirage_lambda_control.ml` — the Unix HTTP control plane (§9 API).
- `cli/mirage_lambda_cli.ml` — the developer CLI.
- `control-unikernel/{config.ml,unikernel.ml}` — the Mirage unikernel (your focus).
- `docs/adr/` — six ADRs (toolchain, QuickJS, HVT boundary, bundle format, launcher).
- `docs/evidence/phase-0.md` — Phase 0 evidence report.

## Probe steps (§34.2) status

1 ✅ create/destroy · 2 ✅ eval 1+2 · 3 ✅ two-module import · 4 ✅ async handler ·
5 ✅ host Promise settle · 6 ✅ heap OOM · 7 ✅ stack limit · 8 ✅ interrupt ·
9 ✅ unhandled rejection · **10 ❌ HVT boot (your first goal)** · 11 ✅ 10k ASan cycles.

## Your first-day checklist

1. Reproduce the build: `opam switch set mirage-lambda && cd control-unikernel && make build` — confirm you see the functor type error above.
2. Read `duniverse/ocaml-tls/mirage/example2/unikernel.ml` (the conduit-built-inside pattern).
3. Fix `unikernel.ml`'s functor (option 1 or 2 above) so `make build` produces `dist/mirage-lambda-control.hvt`.
4. `solo5-hvt dist/mirage-lambda-control.hvt --net=...` and confirm `/healthz` responds → §34.2 step 10 closed.
5. Then: wire Chamelon (§39.2 step 4), TLS (step 2), the KV-backed registry (step 3).

## Project working rule

> Prove each phase on Unix with sanitizers and an executable test before any
> unikernel/fleet work that depends on it. Keep interfaces stable across
> environments so the Unix proof is carried into the unikernel, not rewritten.
