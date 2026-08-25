(** Bounded byte strings — a byte string with a hard maximum length. Every
    constructor checks the bound and never silently truncates. *)

type t = private { bytes : string; max : int }

val max : t -> int
val length : t -> int
val to_string : t -> string
val unsafe_bytes : t -> string

(** Empty bounded string for a given bound. *)
val empty : max:int -> t

(** Create a bounded string, checking the bound. Returns a [Payload_too_large]
    error on overflow. *)
val create : max:int -> string -> (t, Error.t) result

(** Like [create] but raises on overflow (for tests/fixtures). *)
val create_exn : max:int -> string -> t

val of_string : max:int -> string -> (t, Error.t) result

(** Concatenate two bounded strings under the smaller shared bound. *)
val append : t -> t -> (t, Error.t) result

val sub : t -> off:int -> len:int -> (t, Error.t) result

val copy_bytes : t -> t
val equal : t -> t -> bool
