/*
 * qjs/c/qjs_stubs.c — OCaml FFI entry points (§22.2, §22.4).
 *
 * Phase 2 scaffold: every primitive currently fails at runtime with a clear
 * message because the QuickJS engine core is not yet vendored under
 * qjs/vendor/. Once vendored, this file includes <quickjs.h> and implements
 * the real engine lifecycle, host-request queue, and Promise bridge (§23).
 *
 * Only this file (and qjs_allocator.c / qjs_host_queue.c) include quickjs.h.
 * The OCaml side never sees a JSValue or a raw pointer.
 *
 * Stub discipline (§22.4): CAMLparam/CAMLlocal on every primitive; never retain
 * an OCaml heap pointer in C without a registered root; convert QuickJS
 * exceptions to bounded C data then OCaml error values; make destroy
 * idempotent.
 */
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>

/* qjs_port.h is the freestanding platform boundary (§21.4); it does not
 * depend on QuickJS, so it is safe to include in the scaffold. */
#include "qjs_port.h"

#define QJS_NOT_VENDORED() caml_failwith("mlqjs: QuickJS engine not vendored yet (Phase 2 scaffold)")

/* [mlqjs_create] : bytes -> int handle  (§22.2) */
CAMLprim value mlqjs_create(value v_limits)
{
  CAMLparam1(v_limits);
  (void)v_limits;
  (void)mlqjs_monotonic_ns;   /* link the port object in the scaffold build */
  QJS_NOT_VENDORED();
  CAMLreturn(Val_int(0));     /* unreachable */
}

/* [mlqjs_destroy] : int handle -> unit  (idempotent from the OCaml side) */
CAMLprim value mlqjs_destroy(value v_handle)
{
  CAMLparam1(v_handle);
  (void)v_handle;
  QJS_NOT_VENDORED();
  CAMLreturn(Val_unit);
}

/* The remaining externals from §22.2 are declared here for the Phase 2 real
 * wiring. They are unreferenced by the scaffold OCaml, but defined so the
 * symbol table is complete once the OCaml side wires them. */
CAMLprim value mlqjs_eval_entry(value v_h, value v_bundle, value v_entry)
{ CAMLparam3(v_h, v_bundle, v_entry); (void)v_h; (void)v_bundle; (void)v_entry; QJS_NOT_VENDORED(); CAMLreturn(Val_unit); }

CAMLprim value mlqjs_call_handler(value v_h, value v_event, value v_ctx)
{ CAMLparam3(v_h, v_event, v_ctx); (void)v_h; (void)v_event; (void)v_ctx; QJS_NOT_VENDORED(); CAMLreturn(Val_unit); }

CAMLprim value mlqjs_take_requests(value v_h)
{ CAMLparam1(v_h); (void)v_h; QJS_NOT_VENDORED(); CAMLreturn(caml_alloc(0, 0)); }

CAMLprim value mlqjs_resolve(value v_h, value v_id, value v_bytes)
{ CAMLparam3(v_h, v_id, v_bytes); (void)v_h; (void)v_id; (void)v_bytes; QJS_NOT_VENDORED(); CAMLreturn(Val_unit); }

CAMLprim value mlqjs_reject(value v_h, value v_id, value v_err)
{ CAMLparam3(v_h, v_id, v_err); (void)v_h; (void)v_id; (void)v_err; QJS_NOT_VENDORED(); CAMLreturn(Val_unit); }

CAMLprim value mlqjs_pump(value v_h, value v_max_jobs)
{ CAMLparam2(v_h, v_max_jobs); (void)v_h; (void)v_max_jobs; QJS_NOT_VENDORED(); CAMLreturn(Val_int(0)); }

CAMLprim value mlqjs_cancel(value v_h, value v_reason)
{ CAMLparam2(v_h, v_reason); (void)v_h; (void)v_reason; QJS_NOT_VENDORED(); CAMLreturn(Val_unit); }
