(* Internal control-plane/worker protocol (§14, appendix C). All types that
   cross a process/VM boundary carry an explicit [protocol_version] field
   (§35.4 exit gate). The control plane pushes assignments; the worker returns
   completions. Framing lives at the transport layer (§C.5), not here. *)

open Ids
let (let*) = Result.bind

(* Cross-boundary version. Bumped on any wire-incompatible change. *)
let current_protocol_version = 1

(* ---- identifiers carried on the wire (validated at the boundary) ---- *)
module Worker_id = struct
  type t = string
  let of_string s =
    let len = String.length s in
    if len = 0 || len > 63 then Error (Error.Validation.make ~field:"worker" "bad length")
    else Ok s
  let to_string t = t
  let equal a b = String.equal a b
end

module Invocation_id = struct
  type t = string  (* UUID-like; validated as non-empty printable ASCII *)
  let is_print c = c >= '!' && c <= '~'
  let of_string s =
    let len = String.length s in
    if len = 0 || len > 128 then Error (Error.Validation.make ~field:"invocation_id" "bad length")
    else begin
      let bad = ref None in
      (try String.iter (fun c -> if not (is_print c) then (bad := Some c; raise Exit)) s
       with Exit -> ());
      match !bad with
      | Some c -> Error (Error.Validation.make ~field:"invocation_id" (Printf.sprintf "non-printable %C" c))
      | None -> Ok s
    end
  let to_string t = t
  let equal a b = String.equal a b
  let of_string_exn s = match of_string s with Ok v -> v | Error e -> failwith (Error.Validation.to_string e)
end

module Lease_id = Worker_id  (* lease ids share the slug policy for v1 *)

(* ---- Invocation envelope (§14.3): pushed to the worker ---- *)
type invocation_envelope = {
  protocol_version : int;
  invocation_id : Invocation_id.t;
  revision_digest : Digest.t;
  entrypoint : Module_path.t;
  export_name : string;
  event_json : string;        (* canonical JSON *)
  context_json : string;       (* canonical JSON *)
  deadline_ms : int64;
  attempt : int;
  capability_token : string option;
}

(* ---- Assignment (§C.2): control plane -> worker ---- *)
type assignment = {
  protocol_version : int;
  worker_id : Worker_id.t;
  lease_id : Lease_id.t;
  invocation : invocation_envelope;
}

(* ---- Metering snapshot returned with a completion ---- *)
type metering = {
  host_calls : int;
  pending_promises : int;
  log_bytes : int;
  outbound_bytes : int;
  cpu_ms : int;
  elapsed_ms : int;
}

let empty_metering = {
  host_calls = 0; pending_promises = 0; log_bytes = 0;
  outbound_bytes = 0; cpu_ms = 0; elapsed_ms = 0;
}

(* ---- Completion (§C.4): worker -> control plane ---- *)
type completion =
  | Fulfilled of { result_json : string }   (* canonical JSON *)
  | Rejected of { message : string; stack : string option }
  | Failed of Error.t
  | Interrupted of Error.Resource.t

type completion_envelope = {
  protocol_version : int;
  invocation_id : Invocation_id.t;
  completion : completion;
  metering : metering;
}

(* ---- Start handshake (§C.3): worker -> control plane on connect ---- *)
type start_handshake = {
  protocol_version : int;
  worker_id : Worker_id.t;
  image_digest : Digest.t;
  runtime_version : string;   (* e.g. quickjs-2026-06-04-mlambda-v1 *)
  ocaml_version : string;
  mirage_version : string;
}

(* ---- Constructors / validators ---- *)
let make_invocation
    ~invocation_id ~revision_digest ~entrypoint ~export_name ~event_json
    ~context_json ~deadline_ms ~attempt ?capability_token () =
  { protocol_version = current_protocol_version;
    invocation_id; revision_digest; entrypoint; export_name;
    event_json; context_json; deadline_ms; attempt; capability_token }

let make_assignment ~worker_id ~lease_id ~invocation =
  { protocol_version = current_protocol_version; worker_id; lease_id; invocation }

let make_completion ~invocation_id ~completion ~metering =
  { protocol_version = current_protocol_version; invocation_id; completion; metering }

let check_version v =
  if v = current_protocol_version then Ok ()
  else Error (Error.make ~code:Error.Worker_failure
    ~failure_class:Error.Worker_protocol_error
    (Printf.sprintf "protocol version mismatch: got %d, want %d" v current_protocol_version))

(* ---- accessors ---- *)
let protocol_version_invocation (e : invocation_envelope) = e.protocol_version
let invocation_id (e : invocation_envelope) = e.invocation_id
let revision_digest (e : invocation_envelope) = e.revision_digest
let entrypoint (e : invocation_envelope) = e.entrypoint
let export_name (e : invocation_envelope) = e.export_name
let event_json (e : invocation_envelope) = e.event_json
let context_json (e : invocation_envelope) = e.context_json
let deadline_ms (e : invocation_envelope) = e.deadline_ms
let attempt (e : invocation_envelope) = e.attempt
let capability_token (e : invocation_envelope) = e.capability_token
