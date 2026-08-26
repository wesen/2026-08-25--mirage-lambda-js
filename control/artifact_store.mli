(** Content-addressed artifact store (§20.3). Phase 4 Unix-directory impl. *)

type t

val make : root:string -> t
val put_if_absent : t -> digest_bytes:Ids.Digest.t -> string -> ([ `Created | `Already_present ], Error.t) result
val get : t -> Ids.Digest.t -> (string, Error.t) result
val exists : t -> Ids.Digest.t -> bool
val delete : t -> Ids.Digest.t -> (unit, Error.t) result
