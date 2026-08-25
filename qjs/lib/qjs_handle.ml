(* qjs/lib/qjs_handle.ml — opaque runtime handle (§22.2).
   Option 2: an integer handle into a C-side table with generation counters
   to reject stale use-after-free. Explicit [destroy] is required (in
   Lwt.finalize); the finalizer is only a last-resort leak guard. *)

type t = private int   (* (generation << 32) lor index — opaque to OCaml *)

external create : limits_blob:bytes -> t = "mlqjs_create"
external destroy : t -> unit = "mlqjs_destroy"

(* The externals are implemented in qjs/c/qjs_stubs.c. Until QuickJS is
   vendored (Phase 2 gate), every primitive fails at runtime with a clear
   message; the handle type and interface are pinned here. *)
