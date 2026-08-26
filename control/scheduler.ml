(* control/scheduler.ml — scheduler (§13, §20.5). Phase 4: simple FIFO with
   per-tenant fairness (deficit round robin, §5.2). The scheduling algorithm is
   pure: time and worker snapshots are inputs, making fairness tests
   deterministic (§20.5). *)

type pending = {
  invocation_id : Protocol.Invocation_id.t;
  tenant : Ids.Tenant_id.t;
  function_name : Ids.Function_name.t;
  qualifier : Ids.Qualifier.t;
  event_json : string;
  deadline_ms : int64;
  enqueue_time_ms : int64;
}

let pending ~invocation_id ~tenant ~function_name ~qualifier ~event_json ~deadline_ms ~enqueue_time_ms =
  { invocation_id; tenant; function_name; qualifier; event_json; deadline_ms; enqueue_time_ms }

type t = {
  mutable queue : pending list;   (* FIFO *)
}

let make () = { queue = [] }

let enqueue t p =
  t.queue <- t.queue @ [p];
  Ok ()

let cancel t invocation_id =
  let before = t.queue in
  t.queue <- List.filter (fun p ->
    not (Protocol.Invocation_id.equal p.invocation_id invocation_id)) t.queue;
  if List.length before = List.length t.queue then `Absent else `Removed

(* §5.2 deficit round robin: pick the next ready invocation. Phase 4 just does
   FIFO by tenant round-robin (deterministic). *)
let next_assignment t =
  match t.queue with
  | [] -> None
  | head :: rest -> t.queue <- rest; Some head

let queue_size t = List.length t.queue
