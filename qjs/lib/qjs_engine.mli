(** The public engine interface (§20.1, §36.1). Only [qjs/c] includes
    [quickjs.h]; only [qjs/lib] uses the private foreign primitives; the
    worker imports this stable interface. *)

type error =
  | Bad_bundle of Error.Validation.t
  | Limits of Error.Validation.t
  | Engine of string
  | Resource of Error.Resource.t
  | Host of Error.Host.t

type completion =
  | Fulfilled of Bounded_bytes.t
  | Rejected of Error.Js.t

type progress =
  | Need_host_work
  | Runnable
  | Waiting
  | Complete of completion
  | Interrupted of Error.Resource.t

module Memory : sig
  type t = {
    heap_used : int;
    heap_limit : int;
    atom_count : int;
    pending_jobs : int;
    live_handles : int;
  }
  val make :
    heap_used:int -> heap_limit:int -> atom_count:int ->
    pending_jobs:int -> live_headers:int -> unit -> t
  val heap_used : t -> int
  val heap_limit : t -> int
  val atom_count : t -> int
  val pending_jobs : t -> int
  val live_handles : t -> int
end

type t

val create :
  limits:Budget.Engine_limits.t -> bundle:Bundle.Validated.t -> (t, error) result

val start :
  t -> entrypoint:Ids.Module_path.t -> export_name:string ->
  event_json:Bounded_bytes.t -> context_json:Bounded_bytes.t -> (unit, error) result

val take_host_requests : t -> Qjs_host_request.t list

val resolve_host_request :
  t -> Qjs_host_request.Id.t -> (Bounded_bytes.t, Error.Host.t) result ->
  (unit, error) result

val pump : t -> max_jobs:int -> (progress, error) result

val cancel : t -> Error.Resource.t -> unit
val memory_usage : t -> Memory.t
val destroy : t -> unit
