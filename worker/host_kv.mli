(** In-memory KV store (§37.3 Host_kv.Memory). *)

type t
val make : unit -> t
val clear : t -> unit
val get : t -> string -> (string option, string) result
val put : t -> string -> string -> (unit, string) result
val delete : t -> string -> (unit, string) result
val list : t -> string -> (string list, string) result
val fail_next : t -> unit
