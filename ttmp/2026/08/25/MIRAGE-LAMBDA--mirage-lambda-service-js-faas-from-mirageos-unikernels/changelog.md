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

