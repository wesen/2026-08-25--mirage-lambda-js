# QuickJS vendor provenance — `quickjs-2026-06-04`

- **Source URL:** `https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz`
- **Archive size:** 621500 bytes
- **SHA-256:** `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`
- **Vendored at:** `qjs/vendor/quickjs-2026-06-04/`
- **Date vendored:** 2026-08-25

## Engine core kept (§21.1)

```
quickjs.c        quickjs.h        quickjs-opcode.h   quickjs-atom.h
cutils.c         cutils.h
dtoa.c           dtoa.h
libregexp.c      libregexp.h     libregexp-opcode.h
libunicode.c     libunicode.h    libunicode-table.h
list.h           unicode_gen_def.h
VERSION          LICENSE         readme.txt         Changelog
```

## Excluded (§21.2)

`quickjs-libc.c`, `quickjs-libc.h`, `qjs.c`, `qjsc.c`, `run-test262.c`,
`unicode_gen.c`, `Makefile`, `release.sh`, `unicode_download.sh`, `repl.js`,
`examples/`, `tests/`, `test262*`. These pull in POSIX (`dlopen`,
`pthread_create`, filesystem, signals, the standard OS module) that must not
exist in a Solo5 HVT freestanding guest.

## Verification

```bash
# Confirm the vendored tree matches the recorded digest's archive.
curl -sSL https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz -o /tmp/qjs.tar.xz
sha256sum /tmp/qjs.tar.xz
# expect: b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a
```
