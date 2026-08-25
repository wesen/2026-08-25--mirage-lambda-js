(** Host request type (§23.1, §20.1). A JavaScript host callback enqueues a
    request in C; OCaml drains it, performs the authorized/metered operation,
    and resolves/rejects the corresponding Promise. *)

module Id : sig
  type t = private int64
  val to_int64 : t -> int64
  val of_int64 : int64 -> t
  val equal : t -> t -> bool
end

type result_kind = [ `Json | `Bytes | `Unit ]

type result =
  | Json of Bounded_bytes.t
  | Bytes of Bounded_bytes.t
  | Unit

type t = {
  id : Id.t;
  operation : string;
  payload : Bounded_bytes.t;
}

val id : t -> Id.t
val operation : t -> string
val payload : t -> Bounded_bytes.t
