(* control/admission.ml — admission control (§5.1, §5.2).
   Phase 4: simple tenant quotas (rate, concurrency, queue size). Admission
   rejects work that cannot be scheduled under current quotas or that has an
   impossible deadline; execution enforcement terminates work that exceeds its
   runtime budget (§5.1). *)

type tenant_quota = {
  rate_per_sec : int;
  max_concurrent : int;
  max_queued : int;
  max_queued_bytes : int;
}

let default_quota = {
  rate_per_sec = 100;
  max_concurrent = 10;
  max_queued = 1000;
  max_queued_bytes = 64 * 1024 * 1024;
}

type t = {
  quotas : (Ids.Tenant_id.t, tenant_quota) Hashtbl.t;
  mutable concurrent : (Ids.Tenant_id.t, int) Hashtbl.t;
  mutable queued : (Ids.Tenant_id.t, int) Hashtbl.t;
  mutable queued_bytes : (Ids.Tenant_id.t, int) Hashtbl.t;
}

let make () = {
  quotas = Hashtbl.create 8;
  concurrent = Hashtbl.create 8;
  queued = Hashtbl.create 8;
  queued_bytes = Hashtbl.create 8;
}

let set_quota t ~tenant q = Hashtbl.replace t.quotas tenant q

let quota_for t ~tenant =
  Hashtbl.find_opt t.quotas tenant |> function Some q -> q | None -> default_quota

(* §5.3: an impossible deadline is one that has already passed or is too tight. *)
let deadline_impossible ~deadline_ms ~now_ms ~min_window_ms =
  let remaining = Int64.sub deadline_ms now_ms in
  Int64.compare remaining (Int64.of_int min_window_ms) < 0

(* admit checks the queue quotas; accept_for_execution checks concurrency. *)
let admit t ~tenant ~deadline_ms ~now_ms ~request_bytes =
  let q = quota_for t ~tenant in
  let queued = Hashtbl.find_opt t.queued tenant |> function Some n -> n | None -> 0 in
  let queued_bytes = Hashtbl.find_opt t.queued_bytes tenant |> function Some n -> n | None -> 0 in
  if deadline_impossible ~deadline_ms ~now_ms ~min_window_ms:10 then
    Error (Error.make ~code:Error.Invocation_timeout ~failure_class:Error.Quota_error
      ~retryable:false "impossible deadline")
  else if queued >= q.max_queued then
    Error (Error.make ~code:Error.Rate_or_quota_exceeded ~failure_class:Error.Quota_error
      ~retryable:true "queue full")
  else if queued_bytes + request_bytes > q.max_queued_bytes then
    Error (Error.make ~code:Error.Payload_too_large ~failure_class:Error.Quota_error
      ~retryable:false "queued bytes exceeded")
  else begin
    Hashtbl.replace t.queued tenant (queued + 1);
    Hashtbl.replace t.queued_bytes tenant (queued_bytes + request_bytes);
    Ok ()
  end

let accept_for_execution t ~tenant =
  let q = quota_for t ~tenant in
  let concurrent = Hashtbl.find_opt t.concurrent tenant |> function Some n -> n | None -> 0 in
  if concurrent >= q.max_concurrent then
    Error (Error.make ~code:Error.Rate_or_quota_exceeded ~failure_class:Error.Quota_error
      ~retryable:true "max concurrent reached")
  else begin
    Hashtbl.replace t.concurrent tenant (concurrent + 1);
    (* dequeue *)
    let queued = Hashtbl.find_opt t.queued tenant |> function Some n -> n | None -> 0 in
    if queued > 0 then Hashtbl.replace t.queued tenant (queued - 1);
    Ok ()
  end

let release t ~tenant =
  let concurrent = Hashtbl.find_opt t.concurrent tenant |> function Some n -> n | None -> 0 in
  if concurrent > 0 then Hashtbl.replace t.concurrent tenant (concurrent - 1)
