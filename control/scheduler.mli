(** Scheduler (§13, §20.5). Phase 4: FIFO with deterministic next_assignment. *)

type pending
type t

val make : unit -> t
val enqueue : t -> pending -> (unit, Error.t) result
val cancel : t -> Protocol.Invocation_id.t -> [ `Removed | `Already_assigned | `Absent ]
val next_assignment : t -> pending option
val queue_size : t -> int

val pending :
  invocation_id:Protocol.Invocation_id.t -> tenant:Ids.Tenant_id.t ->
  function_name:Ids.Function_name.t -> qualifier:Ids.Qualifier.t ->
  event_json:string -> deadline_ms:int64 -> enqueue_time_ms:int64 -> pending
