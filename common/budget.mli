(** Resource arithmetic: counters and exhaustion rules (§5). *)

module Engine_limits : sig
  type t = {
    js_heap_bytes : int;
    native_overhead_bytes : int;
    stack_bytes : int;
    timeout_ms : int;
    cpu_ms : int;
    max_host_calls : int;
    max_pending_promises : int;
    max_log_bytes : int;
    max_outbound_bytes : int;
    max_redirects : int;
    max_child_invocations : int;
  }
  val make :
    js_heap_bytes:int -> native_overhead_bytes:int -> stack_bytes:int ->
    timeout_ms:int -> cpu_ms:int -> max_host_calls:int ->
    max_pending_promises:int -> max_log_bytes:int -> max_outbound_bytes:int ->
    max_redirects:int -> max_child_invocations:int -> unit ->
    (t, Error.Validation.t) result
  val make_exn :
    js_heap_bytes:int -> native_overhead_bytes:int -> stack_bytes:int ->
    timeout_ms:int -> cpu_ms:int -> max_host_calls:int ->
    max_pending_promises:int -> max_log_bytes:int -> max_outbound_bytes:int ->
    max_redirects:int -> max_child_invocations:int -> unit -> t
  val default : t
end

module Usage : sig
  type t
  val zero : limits:Engine_limits.t -> t
  val limits : t -> Engine_limits.t
  val host_calls : t -> int
  val pending_promises : t -> int
  val log_bytes : t -> int
  val outbound_bytes : t -> int
  val child_invocations : t -> int
  val take_host_call : t -> bool
  val release_host_call : t -> unit
  val take_pending_promise : t -> bool
  val release_pending_promise : t -> unit
  val add_log_bytes : t -> int -> bool
  val add_outbound_bytes : t -> int -> bool
  val take_child_invocation : t -> bool
  val release_child_invocation : t -> unit
end

(** [deadline_expired ~deadline_ms ~now_ms] is true once the absolute service
    deadline has elapsed (§5.3). *)
val deadline_expired : deadline_ms:int64 -> now_ms:int64 -> bool
