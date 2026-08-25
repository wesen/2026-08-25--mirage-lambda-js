(** Strict manifest parser + semantic checks (§10.2, §10.3, appendix B).
    Unknown and duplicate fields are rejected; identifiers and limits are
    validated. Pure: no Unix/Lwt/Mirage/TLS/QuickJS dependency. *)

open Ids

type io_spec = {
  format : string;
  max_bytes : int;
}

type retry_mode = Never | On_error | Always

type t = {
  schema_version : int;
  name : Function_name.t;
  entrypoint : Module_path.t;
  export : string;
  runtime : string;
  input : io_spec;
  output : io_spec;
  limits : Budget.Engine_limits.t;
  capabilities : Capability.declarations;
  retry : retry_mode;
}

(** Parse a manifest from a Yojson value. Validation is ordered cheapest to
    most expensive (§10.3). *)
val parse : Yojson.Safe.t -> (t, Error.Validation.t) result

(** Parse a manifest from a raw JSON string. *)
val parse_string : string -> (t, Error.Validation.t) result

val schema_version : t -> int
val name : t -> Function_name.t
val entrypoint : t -> Module_path.t
val export : t -> string
val runtime : t -> string
val input : t -> io_spec
val output : t -> io_spec
val limits : t -> Budget.Engine_limits.t
val capabilities : t -> Capability.declarations
val retry : t -> retry_mode
