(** Invocation context and lifecycle (§12, §37). *)

open Ids

type context = private {
  invocation_id : Protocol.Invocation_id.t;
  revision_digest : Digest.t;
  entrypoint : Module_path.t;
  export_name : string;
  event_json : Bounded_bytes.t;
  context_json : Bounded_bytes.t;
  deadline_ms : int64;
  attempt : int;
  limits : Budget.Engine_limits.t;
  policy : Capability.policy;
  mutable engine : Qjs_engine.t option;
  mutable budget : Budget.Usage.t;
  mutable started_ns : int64;
  mutable finished : bool;
}

val make :
  invocation_id:Protocol.Invocation_id.t -> revision_digest:Digest.t ->
  entrypoint:Module_path.t -> export_name:string ->
  event_json:Bounded_bytes.t -> context_json:Bounded_bytes.t ->
  deadline_ms:int64 -> attempt:int ->
  limits:Budget.Engine_limits.t -> policy:Capability.policy -> context

val invocation_id : context -> Protocol.Invocation_id.t
val engine : context -> Qjs_engine.t option
val set_engine : context -> Qjs_engine.t -> unit
val budget : context -> Budget.Usage.t
val policy : context -> Capability.policy
val limits : context -> Budget.Engine_limits.t
val deadline_ms : context -> int64
val event_json : context -> Bounded_bytes.t
val context_json : context -> Bounded_bytes.t
val entrypoint : context -> Module_path.t
val export_name : context -> string
val attempt : context -> int

val mark_started : context -> now_ns:int64 -> unit
val mark_finished : context -> unit
val is_finished : context -> bool
val deadline_expired : context -> now_ms:int64 -> bool
