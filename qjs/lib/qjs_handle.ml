(* qjs/lib/qjs_handle.ml — opaque runtime handle (§22.2).
   Option 2: an integer handle into a C-side table with generation counters
   to reject stale use-after-free. Explicit [destroy] is required (in
   Lwt.finalize); the finalizer is only a last-resort leak guard. *)

type t = int   (* (generation << 16) lor index — opaque to OCaml *)

external create : limits_blob:bytes -> t = "mlqjs_create"
external destroy : t -> unit = "mlqjs_destroy"

(* Eval a source string; returns true if the eval threw a JS exception. *)
external eval : t -> string -> bool = "mlqjs_eval"

(* Eval a source expression that should produce an int; returns the int.
   Raises (Failure) on exception or non-int. *)
external eval_int : t -> string -> int = "mlqjs_eval_int"

(* Run up to max_jobs pending QuickJS jobs. Returns:
   0 = nothing pending (Waiting), 1 = ran jobs, 2 = interrupted. *)
external pump : t -> max_jobs:int -> int = "mlqjs_pump"

external cancel : t -> reason:int -> unit = "mlqjs_cancel"

(* Drain the host request queue into an array of (id, op, payload). *)
external take_requests : t -> (int64 * string * string) array = "mlqjs_take_requests"

(* Diagnostic: live host request count. *)
external host_call_count : t -> int = "mlqjs_host_call_count"

(* Memory usage: (used_count, limit, pending_jobs). *)
external mem_usage : t -> (int * int * int) = "mlqjs_mem_usage"
