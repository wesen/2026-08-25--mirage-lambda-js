(** Authorizes and dispatches host calls (§20.2). *)

type implementations

val make_impls :
  log:Host_log.t -> clock:Host_clock.t -> crypto:Host_crypto.t ->
  kv:(string, string) Hashtbl.t -> implementations

(** Dispatch a single host request. Returns [Ok json_string] or [Error msg]. *)
val dispatch : implementations -> Capability.policy -> Qjs_host_request.t -> (string, string) result
