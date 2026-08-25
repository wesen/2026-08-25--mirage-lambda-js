(** Opaque runtime handle (§22.2). Integer handle into a C-side table with a
    generation counter to reject stale use-after-free. Explicit [destroy] is
    required; finalizers are only a last-resort leak guard. *)

type t = private int

val create : limits_blob:bytes -> t
val destroy : t -> unit
