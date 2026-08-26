# Changelog

## 2026-08-25

- Initial workspace created


## 2026-08-25

Phase 0: repo skeleton + toolchain pin + QuickJS probe scaffolding + build scripts + evidence (provisional GO to Phase 1)

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/docs/adr/0000-toolchain-baseline.md — Toolchain baseline ADR


## 2026-08-25

Phase 1: pure common library (ids, bounded_bytes, error, budget, capability, manifest, bundle+SHA256, protocol, canonical_json) + 14 unit tests + 3 fuzz tests + api/ schemas (all green)

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/common/bundle.ml — MLB1 parser/writer + pure SHA-256


## 2026-08-25

Phase 2 (scaffold): Qjs_engine/handle/module_loader/host_request interface + C FFI stubs (§20.1, §22.2); module loader unit tests (4); all 21 tests green

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/qjs/lib/qjs_engine.mli — Public engine interface (§20.1)


## 2026-08-25

Vendored QuickJS 2026-06-04 (SHA-256 b376e839...); engine core compiles under ASan/UBSan on Unix; closes largest Phase 0 open item

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/qjs/vendor/VENDOR.md — Vendor provenance + digest


## 2026-08-25

Phase 2 real engine: QuickJS lifecycle wired (create/eval/limits/interrupt/pump) + 8 engine tests; 29 tests green; §34.2 steps 1,2,6,7,8,11 proven on Unix

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/qjs/c/qjs_stubs.c — Real QuickJS engine FFI lifecycle


## 2026-08-25

Module loader wired (§34.2 step 3): two-module ESM import works; set_module/eval_module externals; 31 tests green

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/qjs/c/qjs_stubs.c — C module loader callback (§24.4)


## 2026-08-25

Promise bridge (§23.1): host.later async handler + resolve + unhandled rejection tracker; 9/11 probe steps proven on Unix; 33 tests green

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/qjs/c/qjs_stubs.c — Promise bridge + host callback


## 2026-08-25

Phase 3: Unix worker runtime — invocation context, capability broker, host fakes (log/clock/crypto/kv), dispatch loop (§23.2), end-to-end test; 34 tests green

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/worker/runtime_host.ml — Worker dispatch loop (§23.2)


## 2026-08-25

Phase 4: single-appliance MVP — control plane (artifact store, registry, admission, scheduler, worker pool, HTTP server) + developer CLI + end-to-end deploy/alias/invoke demo; mirage-lambda switch built + §34.3 audit done

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/control/mirage_lambda_control.ml — HTTP control plane (§9)


## 2026-08-25

Phase 5 (start): Mirage control-plane unikernel config.ml + unikernel.ml; mirage configure -t hvt succeeds; HVT build gated on opam-monorepo lockfile (dune-universe overlay)

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/control-unikernel/config.ml — Mirage device composition (§26.1)


## 2026-08-25

Phase 5 HVT toolchain unblocked (opam-monorepo default-switch fix; lockfile 92 entries; duniverse 91 repos); boot functor written; HVT image blocked on cohttp_server functor arg type — handoff point

### Related Files

- /home/manuel/code/wesen/2026-08-25--mirage-lambda-js/control-unikernel/unikernel.ml — Boot functor /healthz

