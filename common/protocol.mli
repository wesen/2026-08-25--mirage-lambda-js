(** Internal control-plane/worker protocol (§14, appendix C). All
    cross-boundary types carry an explicit [protocol_version] (§35.4). *)

open Ids

val current_protocol_version : int

module Worker_id : sig
  type t = private string
  val of_string : string -> (t, Error.Validation.t) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Invocation_id : sig
  type t = private string
  val of_string : string -> (t, Error.Validation.t) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Lease_id : sig
  type t = private string
  val of_string : string -> (t, Error.Validation.t) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type invocation_envelope = {
  protocol_version : int;
  invocation_id : Invocation_id.t;
  revision_digest : Digest.t;
  entrypoint : Module_path.t;
  export_name : string;
  event_json : string;
  context_json : string;
  deadline_ms : int64;
  attempt : int;
  capability_token : string option;
}

type assignment = {
  protocol_version : int;
  worker_id : Worker_id.t;
  lease_id : Lease_id.t;
  invocation : invocation_envelope;
}

type metering = {
  host_calls : int;
  pending_promises : int;
  log_bytes : int;
  outbound_bytes : int;
  cpu_ms : int;
  elapsed_ms : int;
}

val empty_metering : metering

type completion =
  | Fulfilled of { result_json : string }
  | Rejected of { message : string; stack : string option }
  | Failed of Error.t
  | Interrupted of Error.Resource.t

type completion_envelope = {
  protocol_version : int;
  invocation_id : Invocation_id.t;
  completion : completion;
  metering : metering;
}

type start_handshake = {
  protocol_version : int;
  worker_id : Worker_id.t;
  image_digest : Digest.t;
  runtime_version : string;
  ocaml_version : string;
  mirage_version : string;
}

val make_invocation :
  invocation_id:Invocation_id.t -> revision_digest:Digest.t ->
  entrypoint:Module_path.t -> export_name:string -> event_json:string ->
  context_json:string -> deadline_ms:int64 -> attempt:int ->
  ?capability_token:string -> unit -> invocation_envelope

val make_assignment :
  worker_id:Worker_id.t -> lease_id:Lease_id.t ->
  invocation:invocation_envelope -> assignment

val make_completion :
  invocation_id:Invocation_id.t -> completion:completion ->
  metering:metering -> completion_envelope

val check_version : int -> (unit, Error.t) result

val protocol_version_invocation : invocation_envelope -> int
val invocation_id : invocation_envelope -> Invocation_id.t
val revision_digest : invocation_envelope -> Digest.t
val entrypoint : invocation_envelope -> Module_path.t
val export_name : invocation_envelope -> string
val event_json : invocation_envelope -> string
val context_json : invocation_envelope -> string
val deadline_ms : invocation_envelope -> int64
val attempt : invocation_envelope -> int
val capability_token : invocation_envelope -> string option
