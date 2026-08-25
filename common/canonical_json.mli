(** Canonical JSON — deterministic serialization with sorted object keys.

    Used for the MLB1 bundle header/manifest and any value that must be
    byte-stable for digesting (§10.4, §35.3). *)

module Y = Yojson.Safe

type t =
  | Null
  | Bool of bool
  | Int of int64
  | Float of float
  | String of string
  | Array of t list
  | Object of (string * t) list

(** Convert a parsed Yojson value to the canonical value type. Rejects
    non-canonical variants (tuples). *)
val of_yojson : Y.t -> (t, string) result

(** Convert back to Yojson. Object keys are NOT sorted here; use [to_string]. *)
val to_yojson : t -> Y.t

(** Canonical string encoding: object keys sorted recursively, no
    inter-token whitespace, fixed float representation. *)
val to_string : t -> string

(** Parse + re-emit canonical bytes from raw Yojson. *)
val canonicalize : Y.t -> (string, string) result

(** Sort object keys recursively (helper). *)
val sort : t -> t

(** Parse Yojson strictly (raises on malformed input; internal helper). *)
val parse_exn : string -> Y.t
