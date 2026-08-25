# qjs/ — QuickJS port and OCaml/C wrapper

This directory owns everything that touches the QuickJS C API. Only `qjs/c/`
includes `quickjs.h`; only `qjs/lib/` uses the private foreign primitives; the
worker imports the stable `QJS_ENGINE` interface (§36.1).

## Layout

```
qjs/
├── vendor/quickjs-2026-06-04/   vendored engine core (Phase 0: pending vendor)
├── c/                            C: port boundary, allocator, host queue, stubs
│   ├── qjs_port.h                §21.4 freestanding platform boundary
│   ├── qjs_port_unix.c            Unix platform impl
│   ├── qjs_port_solo5.c           Solo5 HVT platform impl
│   ├── qjs_allocator.c            custom JS_NewRuntime2 allocator (Phase 2)
│   ├── qjs_host_queue.{c,h}       bounded plain-C host request queue (Phase 2)
│   └── qjs_stubs.{c,h}           OCaml FFI entry points (Phase 2)
├── lib/                          OCaml wrapper (Phase 2)
│   ├── qjs_handle.{ml,mli}
│   ├── qjs_engine.{ml,mli}        implements §20.1 QJS_ENGINE
│   ├── qjs_module_loader.{ml,mli}
│   └── qjs_host_request.{ml,mli}
└── test/                          engine tests + probe
    ├── probe.ml                   Phase 0 probe driver (§34.2)
    ├── probe.js                   Phase 0 probe program (§34.2)
    ├── test_limits.ml             (Phase 2)
    ├── test_promises.ml            (Phase 2)
    ├── test_modules.ml             (Phase 2)
    └── fuzz_bundle_to_qjs.ml       (Phase 2)
```

## Ownership table (§36.3)

Update this table with every API addition.

| Object | Creator | Owner while live | Release action | May cross async wait? |
|---|---|---|---|---|
| `JSRuntime *` | C wrapper | `Qjs_handle.t` | `JS_FreeRuntime` | yes, invocation lifetime |
| `JSContext *` | C wrapper | runtime wrapper | `JS_FreeContext` | yes |
| handler `JSValue` | module loader | wrapper | `JS_FreeValue` | yes if duplicated/rooted |
| Promise resolving fns | QuickJS | request registry | `JS_FreeValue` each | yes |
| module source bytes | OCaml/bundle | module registry | OCaml owns until compile done | bounded |
| host request payload | C callback | C queue, then OCaml copy | queue destructor | yes |
| OCaml callback/root | OCaml | wrapper | unregister root before free | yes |

Invariant on runtime destruction:

```
pending_host_requests = 0
rooted_OCaml_values    = 0
retained_JSValues      = 0
contexts               = 0 before runtime free
```

## Build

Unix probe scaffold (Phase 0):

```bash
./scripts/build-unix-probe.sh   # compiles the platform boundary; gates on vendor
```

Engine library + tests land in Phase 2.
