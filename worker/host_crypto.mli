(** Cryptographic randomness (§37.3). *)

type t
val make_real : unit -> t
val make_deterministic : int -> t
val random_bytes : t -> int -> Bytes.t
