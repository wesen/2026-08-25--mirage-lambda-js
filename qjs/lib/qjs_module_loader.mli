(** Custom module loader (§10.5, §24.4). Reads ONLY from the validated
    in-memory bundle map. Supports [./], [../] (normalized within the bundle
    root) and [cap:] virtual modules. No native/HTTP/fs/dynamic import. *)

open Ids

(** Normalize a relative import against a base module path, staying within the
    bundle root. Rejects imports that escape the root. *)
val normalize : base:Module_path.t -> string -> (Module_path.t, Error.Validation.t) result

(** Resolve an import to bundle content. *)
val resolve :
  modules:(Module_path.t * string) list -> base:Module_path.t -> string ->
  (string, Error.Validation.t) result
