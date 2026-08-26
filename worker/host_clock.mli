(** Monotonic clock (§37.3). v1 uses real time; scripted fake for tests. *)

type t
val make_real : unit -> t
val make_scripted : int64 list -> t
val monotonic_ms : t -> int64
