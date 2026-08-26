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
| 5 — Mirage control-plane unikernel | 🟡 in progress | config + boot functor; HVT toolchain unblocked; **HVT image BUILDS** (`dist/mirage-lambda-control.hvt`, 13.9 MB; solo5 manifest = one NET_BASIC device); boot not yet run (needs a TAP device → CAP_NET_ADMIN) |
| 6–10 | not started | worker HVT, fleet, security, hardening, production |

**Tests:** 31 green (14 common + 4 qjs + 12 engine + 1 worker) on the Unix
(Coq) switch. The control-unikernel builds under the `mirage-lambda` switch.

## Where the HVT image stands now (was: the blocking issue)

**The image builds.** The `cohttp_server` functor-arg mismatch is fixed. The
root cause: `Mirage_runtime.register_arg` returns `int runtime_arg = unit ->
int`, but `Conduit_mirage.server = [ `TCP of int | ... ]` needs a plain `int`.
The fix is one token — evaluate the thunk:

```ocaml
let serve () = http (`TCP (port ())) httpd   (* was: `TCP port *)
```

`make build` now produces `dist/mirage-lambda-control.hvt` (13,955,336 bytes;
`solo5-elftool query-manifest` reports one NET_BASIC device named `service`).

## The remaining gate: boot the image (§34.2 step 10)

The boot needs a TAP network device on the host, which requires
`CAP_NET_ADMIN` (or `sudo`):

```bash
opam switch set mirage-lambda && eval $(opam env)
cd control-unikernel
sudo ip tuntap add tap100 mode tap && sudo ip link set tap100 up
sudo ip addr add 10.0.0.1/24 dev tap100          # give the host an address
solo5-hvt --net:service=tap100 dist/mirage-lambda-control.hvt --port=8080
# in another shell, once the unikernel prints its IPv4:
curl http://<unikernel-ip>:8080/healthz   # → {"status":"ok"}
```

The dev machine lacks `CAP_NET_ADMIN` (`ip tuntap add` → `Operation not
permitted`; `sudo -n` needs a password), so the boot could not be run in this
session. This is a host-permission gate, not a code gate — the image is valid.

If the unikernel does not acquire an IP via DHCP, pass a static IPv4 via
`--ipv4=<addr>/<mask>` (the `generic_stackv4v6` device accepts it).

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
9 ✅ unhandled rejection · **10 🟡 HVT image built, boot pending a TAP device** · 11 ✅ 10k ASan cycles.

## Your first-day checklist

1. Boot the image (needs root): create a TAP device, `solo5-hvt --net:service=tap100 dist/mirage-lambda-control.hvt --port=8080`, curl `/healthz` → §34.2 step 10 closed.
2. If the build needs reproducing: `opam switch set mirage-lambda && cd control-unikernel && make build`.
3. Then: wire Chamelon (§39.2 step 4), TLS (step 2), the KV-backed registry (step 3).

## Project working rule

> Prove each phase on Unix with sanitizers and an executable test before any
> unikernel/fleet work that depends on it. Keep interfaces stable across
> environments so the Unix proof is carried into the unikernel, not rewritten.
