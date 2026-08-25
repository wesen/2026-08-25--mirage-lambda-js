# QuickJS freestanding port audit

- **Phase:** 0 (§21.3, §34.3)
- **Status:** template — to be filled after the QuickJS engine objects are
  compiled against the HVT target libc.

QuickJS is self-contained in the sense of external engine dependencies, but it is
not automatically freestanding C. The public header includes standard C headers,
and the core source uses math, time, floating-point environment, memory, and
optional atomics/pthread facilities.

## Symbol/header class — expected action

| Symbol/header class | Expected action | Status |
|---|---|---|
| `memcpy`, `memmove`, `strlen`, integer helpers | use ocaml-solo5/minimal libc if provided | pending compile probe |
| `malloc`, `free`, `realloc` | route engine allocations through `JS_NewRuntime2` custom fns; audit other direct uses | pending |
| `snprintf`, formatting | verify minimal libc behavior; bound all buffers | pending |
| `math.h` functions | link/test freestanding math support; add compile-time probe | pending |
| floating-point environment | test or patch behind platform interface | pending |
| `gettimeofday`/time | replace with explicit port fn (`mlqjs_*`); do not grant wall time accidentally | done in `qjs_port_*` |
| `pthread`/atomics | compile atomics/worker support out; `JS_SetCanBlock(rt,false)` | pending |
| files, signals, `dlopen`, process APIs | absent because `quickjs-libc.c` is not linked | by exclusion |
| locale | force deterministic locale-independent behavior or patch | pending |
| randomness | do not treat `Math.random` as cryptographic; expose host crypto capability | done in `qjs_port_*` |

## Per-symbol audit (filled after HVT compile)

| Symbol | Referenced by | Unix availability | HVT availability | Decision |
|---|---|---|---|---|
| `malloc`/`free`/`realloc` | allocator path | libc | ocaml-solo5 minimal libc | route through `JS_NewRuntime2` custom fns |
| `malloc_usable_size` | accounting path | platform-specific | unknown | avoid via custom allocator |
| `clock_gettime` | optional time path | yes | target-dependent | host-provided JS clock only |
| `dlopen` | standard module loader | yes | no | exclude `quickjs-libc.c` |
| `pthread_create` | QuickJS worker helper | yes | unsuitable | exclude worker API; `JS_SetCanBlock(rt,false)` |
| `snprintf` | formatting | libc | verify minimal libc | bound all buffers |

Do not invent shims blindly. A shim must preserve the semantics QuickJS actually depends
on, or the dependent path must be removed (§34.3).
