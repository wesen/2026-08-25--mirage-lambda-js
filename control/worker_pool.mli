(** Worker pool (§13, §20.6). Phase 4: in-process runtimes, no reuse. *)

type worker_spec = {
  tenant : Ids.Tenant_id.t;
  function_name : Ids.Function_name.t;
  revision : Ids.Digest.t;
}

type invocation_result = {
  invocation_id : Protocol.Invocation_id.t;
  result : [ `Fulfilled of string | `Rejected of string | `Failed of Error.t | `Timeout of Error.t ];
  duration_ms : float;
}

val now_ms : unit -> int64

val run_one :
  artifact_store:Artifact_store.t -> registry:Registry.t ->
  invocation_id:Protocol.Invocation_id.t -> tenant:Ids.Tenant_id.t ->
  function_name:Ids.Function_name.t -> qualifier:Ids.Qualifier.t ->
  event_json:string -> deadline_ms:int64 ->
  (invocation_result, Error.t) result
