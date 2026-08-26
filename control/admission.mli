(** Admission control (§5.1, §5.2). *)

type tenant_quota = {
  rate_per_sec : int;
  max_concurrent : int;
  max_queued : int;
  max_queued_bytes : int;
}

val default_quota : tenant_quota

type t

val make : unit -> t
val set_quota : t -> tenant:Ids.Tenant_id.t -> tenant_quota -> unit
val quota_for : t -> tenant:Ids.Tenant_id.t -> tenant_quota
val admit :
  t -> tenant:Ids.Tenant_id.t -> deadline_ms:int64 -> now_ms:int64 ->
  request_bytes:int -> (unit, Error.t) result
val accept_for_execution : t -> tenant:Ids.Tenant_id.t -> (unit, Error.t) result
val release : t -> tenant:Ids.Tenant_id.t -> unit
