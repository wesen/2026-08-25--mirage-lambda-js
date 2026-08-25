(** Deterministic bundle parser/writer for the MLB1 format (§10.4).
    Strict: bounds/overflow checks, path validation, sorted uniqueness, size
    caps, digest verification, constant-time compare. *)

open Ids

type module_entry = {
  path : Module_path.t;
  content : string;
  digest : string;   (** 32 raw bytes *)
}

(** Pure-OCaml SHA-256 (no external dependency; keeps [common] pure). *)
module Sha256 : sig
  val hash : string -> string     (** 32 raw bytes *)
  val to_hex : string -> string   (** 64 lowercase hex chars *)
end

module Validated : sig
  type t
  val header : t -> Canonical_json.t
  val manifest : t -> Manifest.t
  val manifest_json : t -> Canonical_json.t
  val modules : t -> module_entry list
  val footer_digest : t -> string
  val raw : t -> string
end

(** Parse and fully validate a bundle buffer (magic, lengths, header/manifest
    JSON, per-module digests, sort/uniqueness, footer digest). *)
val parse : string -> (Validated.t, Error.t) result

(** Write a canonical bundle from pre-validated, sorted modules and canonical
    header/manifest JSON. Recomputes per-module digests and the footer. *)
val write :
  header_json:Canonical_json.t ->
  manifest:Manifest.t ->
  manifest_json:Canonical_json.t ->
  modules:module_entry list ->
  string

val digest_of_content : string -> string
val digest_hex : string -> string

(** Constant-time equality on raw byte strings (§10.4). *)
val ct_eq_bytes : string -> string -> bool

val max_module_count : int
val max_module_bytes : int
val max_total_bytes : int
val magic : string
