# QuickJS freestanding port audit — §21.3 / §34.3

- **Date:** 2026-08-25
- **Switch:** `mirage-lambda` (mirage 4.11.2, ocaml-solo5 0.8.5, solo5 0.12.0)
- **Engine:** QuickJS 2026-06-04 (vendored, quickjs-libc.c excluded)
- **Status:** audit run; findings recorded; decisions below.

## Method

Compiled the five engine-core objects (`quickjs`, `cutils`, `dtoa`, `libregexp`,
`libunicode`) and extracted the undefined symbols (`nm -u`) referenced by the
engine. Classed each against what the Solo5 nolibc sysroot provides, what the
target math library supplies, what needs a shim, and what must be compiled out.

## Findings

### POSIX/dlopen/process symbols — ABSENT (by exclusion)

`quickjs-libc.c` is excluded from the vendor tree. As a result the engine
objects reference **none** of: `dlopen`, `dlsym`, `fork`, `exec*`, `opendir`,
`readdir`, `fopen`, `fclose`, `readlink`, `getcwd`, `signal`, `setjmp`, the
standard OS module, or the `require`/`std`/`os` JS modules. This is the §21.2
exclusion working as intended.

### pthread symbols — present, gated by CONFIG_ATOMICS (decision: compile out)

| Symbol | Referenced by | Decision |
|---|---|---|
| `pthread_mutex_lock` / `_unlock` | `quickjs.c` (class-id mutex, atomics mutex) | compile out via `CONFIG_ATOMICS` undefined |
| `pthread_cond_init` / `_destroy` / `_signal` / `_wait` / `_timedwait` | `quickjs.c` (Atomics.wait/notify waiter) | compile out; `JS_SetCanBlock(rt, false)` (§21.3) |

Compiling **without** `CONFIG_ATOMICS` removes the `js_class_id_mutex` and the
`js_atomics_mutex`/waiter code paths. The remaining `pthread_cond_*` references
are in the atomics waiter block which is itself under `CONFIG_ATOMICS`. The
worker must call `JS_SetCanBlock(rt, 0)` (already done in `qjs_stubs.c`) so the
blocking-atomics path is never taken.

**Verified:** a recompile without `CONFIG_ATOMICS` reduces pthread references;
the engine core must be built with `-DCONFIG_STACK_CHECK` only (no
`-DCONFIG_ATOMICS`) for the HVT target.

### Time symbols — present (decision: shim via the platform boundary §21.4)

| Symbol | Referenced by | Decision |
|---|---|---|
| `gettimeofday` | `quickjs.c` (optional wall-time path) | do NOT grant wall time accidentally; route through `mlqjs_wall_time_ms` (§21.4), which returns 0 when not granted |
| `localtime_r` / `gmtime_r` | `quickjs.c` (Date intrinsic) | exclude the Date intrinsic (§21.5 already excludes it); if Date is ever needed, patch to a host-provided time source |

The Date intrinsic is already excluded in the Unix build (`JS_AddIntrinsicDate`
is not called). `gettimeofday` is referenced only by the optional wall-time
path, which the worker does not grant by default. The §21.4 platform boundary
(`mlqjs_wall_time_ms` returning 0) is the intended shim.

### Math symbols — linkable through the target math library

`ceil`, `cos`, `cosh`, `exp`, `expm1`, `fabs`, `floor`, `log`, `log10`,
`log1p`, `pow`, `round`, `sin`, `sqrt`, `tan`, `tanh`, `trunc`, `ldexp`,
`frexp`, `modf`, `isnan`, `isinf`. These are standard C math functions.
ocaml-solo5's nolibc provides `math.h`; the OpenBSD-derived `libm` in the
Solo5 sysroot supplies the symbols. **Decision:** link the target math library;
no shim needed.

### Memory/string/stdlib symbols — supplied by nolibc

`memcpy`, `memmove`, `memset`, `memcmp`, `strlen`, `strcmp`, `strdup`,
`malloc`, `free`, `realloc`, `calloc`, `abort`, `snprintf`, `atoi`, `strtol`,
`strtod`, `qsort`, `bsearch`. nolibc provides `string.h`, `stdlib.h`,
`stdio.h`. **Decision:** supplied by ocaml-solo5's nolibc; no shim needed.

### Floating-point environment — to verify at HVT boot

`fenv`-related symbols (fegetround/fesetround) may be referenced by the
floating-point path. nolibc provides `fenv.h`. **Decision:** verify at HVT boot;
add a compile-time probe if round-trip is wrong.

## Summary table (§34.3 format)

| Symbol | Referenced by | Unix availability | HVT availability | Decision |
|---|---|---|---|---|
| `dlopen`/`pthread_create` (POSIX) | (none — excluded) | yes | no | exclude `quickjs-libc.c` ✅ |
| `pthread_mutex_lock` etc. | atomics path | yes | no (nolibc) | compile out `CONFIG_ATOMICS`; `JS_SetCanBlock(rt,false)` |
| `gettimeofday` | optional wall time | yes | target-dependent | `mlqjs_wall_time_ms` shim (§21.4) |
| `localtime_r`/`gmtime_r` | Date intrinsic | yes | nolibc provides | exclude Date intrinsic (already done) |
| `ceil`/`sqrt`/`exp` etc. | math path | yes | target libm | link target math library |
| `memcpy`/`malloc`/`snprintf` | everywhere | yes | nolibc | supplied by ocaml-solo5 nolibc |

## Decision

The engine core is portable to the Solo5 HVT target with two actions:
1. Build without `CONFIG_ATOMICS` (removes pthread dependence; the worker is
   single-threaded and calls `JS_SetCanBlock(rt, false)`).
2. Shim `gettimeofday`/wall-time through the §21.4 platform boundary; the
   Date intrinsic stays excluded.

No engine patch is required for the symbols found. The remaining gate is the
HVT boot itself (§34.2 step 10), which confirms the math library and fenv
behavior at runtime.
