(** Buffered structured log (§37.3 Host_log.Buffer). *)

type level = Debug | Info | Warn | Error
type event = { level : level; message : string; fields : (string * string) list }
type t

val make : max_bytes:int -> t
val debug : t -> string -> ?fields:(string * string) list -> unit -> unit
val info : t -> string -> ?fields:(string * string) list -> unit -> unit
val warn : t -> string -> ?fields:(string * string) list -> unit -> unit
val error : t -> string -> ?fields:(string * string) list -> unit -> unit
val append : t -> level:level -> string -> (string * string) list -> unit
val events : t -> event list
val bytes : t -> int
val truncated : t -> bool
val level_to_string : level -> string
