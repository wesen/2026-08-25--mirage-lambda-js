(** Opaque runtime handle (§22.2). Integer handle into a C-side table with a
    generation counter to reject stale use-after-free. Explicit [destroy] is
    required; finalizers are only a last-resort leak guard. *)

type t = private int

val create : limits_blob:bytes -> t
val destroy : t -> unit

val eval : t -> string -> bool
val eval_int : t -> string -> int
val pump : t -> max_jobs:int -> int
val cancel : t -> reason:int -> unit
val take_requests : t -> (int64 * string * string) array
val host_call_count : t -> int
val mem_usage : t -> (int * int * int)

(** Store a bundle module (path, source) for the module loader (§24.4). *)
val set_module : t -> string -> string -> unit

(** Evaluate a module entrypoint by path; returns true if exception. *)
val eval_module : t -> string -> bool

val install_host : t -> unit
val resolve : t -> int64 -> string -> unit
val has_unhandled_rejection : t -> bool
