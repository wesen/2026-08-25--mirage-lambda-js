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
    pending_jobs:int -> live_handles:int -> unit -> t
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

(** Eval a source string; returns true if a JS exception was thrown. *)
val eval : t -> string -> bool

(** Eval an int expression; returns the int or an engine error. *)
val eval_int : t -> string -> (int, error) result

(** Store a bundle module (path, source) for the module loader (§24.4). *)
val set_module : t -> Ids.Module_path.t -> string -> unit

(** Evaluate a module entrypoint by path; returns true if exception. *)
val eval_module : t -> Ids.Module_path.t -> bool

(** Install the host.later(x) callback for the Promise bridge (§23.1). *)
val install_host : t -> unit

(** Resolve a host Promise by request id with a JSON result string. *)
val resolve : t -> Qjs_host_request.Id.t -> string -> unit

(** Check if an unhandled Promise rejection was observed (§34.2 step 9). *)
val has_unhandled_rejection : t -> bool

val take_host_requests : t -> Qjs_host_request.t list

val resolve_host_request :
  t -> Qjs_host_request.Id.t -> (Bounded_bytes.t, Error.Host.t) result ->
  (unit, error) result

val pump : t -> max_jobs:int -> (progress, error) result

val cancel : t -> Error.Resource.t -> unit
val memory_usage : t -> Memory.t
val destroy : t -> unit
