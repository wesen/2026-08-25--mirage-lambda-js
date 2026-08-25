(* Resource arithmetic: counters and exhaustion rules (§5). Admission and
   execution enforcement are separate (§5.1); this module provides the
   accounting primitives both layers share. Counters never underflow and never
   exceed the declared limit (§35.3: budget subtraction never underflows). *)

module Engine_limits = struct
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
  let make
      ~js_heap_bytes ~native_overhead_bytes ~stack_bytes ~timeout_ms ~cpu_ms
      ~max_host_calls ~max_pending_promises ~max_log_bytes ~max_outbound_bytes
      ~max_redirects ~max_child_invocations () =
    let neg f = f < 0 in
    if neg js_heap_bytes || neg native_overhead_bytes || neg stack_bytes
       || neg timeout_ms || neg cpu_ms || neg max_host_calls
       || neg max_pending_promises || neg max_log_bytes || neg max_outbound_bytes
       || neg max_redirects || neg max_child_invocations then
      Error (Error.Validation.make ~field:"limits" "negative limit")
    else Ok {
      js_heap_bytes; native_overhead_bytes; stack_bytes; timeout_ms; cpu_ms;
      max_host_calls; max_pending_promises; max_log_bytes; max_outbound_bytes;
      max_redirects; max_child_invocations;
    }

  let make_exn
      ~js_heap_bytes ~native_overhead_bytes ~stack_bytes ~timeout_ms ~cpu_ms
      ~max_host_calls ~max_pending_promises ~max_log_bytes ~max_outbound_bytes
      ~max_redirects ~max_child_invocations () =
    match make ~js_heap_bytes ~native_overhead_bytes ~stack_bytes ~timeout_ms ~cpu_ms
      ~max_host_calls ~max_pending_promises ~max_log_bytes ~max_outbound_bytes
      ~max_redirects ~max_child_invocations () with
    | Ok v -> v
    | Error e -> failwith (Error.Validation.to_string e)

  let default = {
    js_heap_bytes = 16 * 1024 * 1024;
    native_overhead_bytes = 4 * 1024 * 1024;
    stack_bytes = 256 * 1024;
    timeout_ms = 100;
    cpu_ms = 50;
    max_host_calls = 32;
    max_pending_promises = 16;
    max_log_bytes = 32 * 1024;
    max_outbound_bytes = 256 * 1024;
    max_redirects = 2;
    max_child_invocations = 4;
  }
end

module Usage = struct
  type t = {
    limits : Engine_limits.t;
    mutable host_calls : int;
    mutable pending_promises : int;
    mutable log_bytes : int;
    mutable outbound_bytes : int;
    mutable child_invocations : int;
  }
  let zero ~limits = {
    limits; host_calls = 0; pending_promises = 0; log_bytes = 0;
    outbound_bytes = 0; child_invocations = 0;
  }
  let limits t = t.limits
  let host_calls t = t.host_calls
  let pending_promises t = t.pending_promises
  let log_bytes t = t.log_bytes
  let outbound_bytes t = t.outbound_bytes
  let child_invocations t = t.child_invocations

  (* Attempt to take one unit of a counted resource. Returns false (and does
     not increment) when the limit would be exceeded. *)
  let try_take ~limit ~current =
    if current >= limit then false
    else begin
      (* overflow-safe: current < limit and limit <= max_int, so current+1 <= limit *)
      true
    end

  let take_host_call t =
    if t.host_calls >= t.limits.Engine_limits.max_host_calls then false
    else (t.host_calls <- t.host_calls + 1; true)

  (* Release never underflows (§35.3). *)
  let release_host_call t =
    if t.host_calls > 0 then t.host_calls <- t.host_calls - 1

  let take_pending_promise t =
    if t.pending_promises >= t.limits.Engine_limits.max_pending_promises then false
    else (t.pending_promises <- t.pending_promises + 1; true)

  let release_pending_promise t =
    if t.pending_promises > 0 then t.pending_promises <- t.pending_promises - 1

  (* Add bytes to a byte-budgeted resource; returns false (and does not add)
     when the limit would be exceeded. Saturating arithmetic avoids overflow. *)
  let add_bytes ~limit ~current delta =
    if delta < 0 then true   (* a release; the caller is responsible for not
                                releasing more than was taken *)
    else if current > limit - delta then false   (* would overflow or exceed *)
    else begin
      (* current + delta <= limit *)
      true
    end

  let add_log_bytes t delta =
    if add_bytes ~limit:t.limits.Engine_limits.max_log_bytes
        ~current:t.log_bytes delta
    then (t.log_bytes <- t.log_bytes + delta; true)
    else false

  let add_outbound_bytes t delta =
    if add_bytes ~limit:t.limits.Engine_limits.max_outbound_bytes
        ~current:t.outbound_bytes delta
    then (t.outbound_bytes <- t.outbound_bytes + delta; true)
    else false

  let take_child_invocation t =
    if t.child_invocations >= t.limits.Engine_limits.max_child_invocations then false
    else (t.child_invocations <- t.child_invocations + 1; true)

  let release_child_invocation t =
    if t.child_invocations > 0 then t.child_invocations <- t.child_invocations - 1
end

(* Deadline model (§5.3). The service deadline is absolute. *)
let deadline_expired ~deadline_ms ~now_ms =
  Int64.compare now_ms deadline_ms >= 0
