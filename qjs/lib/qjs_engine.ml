(* qjs/lib/qjs_engine.ml — the public engine interface (§20.1).
   Implements the three-layer model (§36.1): QuickJS C API -> qjs_stubs.c ->
   Qjs_handle/Qjs_engine -> Runtime_host. Only qjs/c includes quickjs.h; only
   qjs/lib uses the private foreign primitives; the worker imports this
   stable interface. *)

type error =
  | Bad_bundle of Error.Validation.t
  | Limits of Error.Validation.t
  | Engine of string                     (* QuickJS engine error *)
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

module Memory = struct
  type t = {
    heap_used : int;
    heap_limit : int;
    atom_count : int;
    pending_jobs : int;
    live_handles : int;
  }
  let make ~heap_used ~heap_limit ~atom_count ~pending_jobs ~live_handles () =
    { heap_used; heap_limit; atom_count; pending_jobs; live_handles }
  let heap_used t = t.heap_used
  let heap_limit t = t.heap_limit
  let atom_count t = t.atom_count
  let pending_jobs t = t.pending_jobs
  let live_handles t = t.live_handles
end

type t = Qjs_handle.t

(* The limits are serialized to a blob the C side decodes (§22.2).
   Format: "%ld|" joined in Budget.Engine_limits.t field order. *)
let limits_blob (l : Budget.Engine_limits.t) : bytes =
  let buf = Buffer.create 64 in
  List.iter (fun n -> Buffer.add_string buf (Printf.sprintf "%ld|" (Int32.of_int n)))
    [l.js_heap_bytes; l.native_overhead_bytes; l.stack_bytes; l.timeout_ms;
     l.cpu_ms; l.max_host_calls; l.max_pending_promises; l.max_log_bytes;
     l.max_outbound_bytes; l.max_redirects; l.max_child_invocations];
  Bytes.of_string (Buffer.contents buf)

let create ~limits ~bundle =
  try
    let h = Qjs_handle.create ~limits_blob:(limits_blob limits) in
    ignore (bundle : Bundle.Validated.t);
    Ok h
  with Failure msg -> Error (Engine msg)

let start t ~entrypoint ~export_name ~event_json ~context_json =
  ignore (t : t);
  ignore (entrypoint : Ids.Module_path.t);
  ignore (export_name : string);
  ignore (event_json : Bounded_bytes.t);
  ignore (context_json : Bounded_bytes.t);
  Ok ()

(* Eval a source string; returns true if a JS exception was thrown. *)
let eval t src = Qjs_handle.eval t src

(* Eval an int expression; returns the int or an engine error. *)
let eval_int t src =
  try Ok (Qjs_handle.eval_int t src)
  with Failure msg -> Error (Engine msg)

let set_module t path src =
  Qjs_handle.set_module t (Ids.Module_path.to_string path) src

let eval_module t path =
  Qjs_handle.eval_module t (Ids.Module_path.to_string path)

let install_host t = Qjs_handle.install_host t
let resolve t id json = Qjs_handle.resolve t (Qjs_host_request.Id.to_int64 id) json
let has_unhandled_rejection t = Qjs_handle.has_unhandled_rejection t

(* Pump up to max_jobs pending jobs. Returns a progress hint. *)
let pump t ~max_jobs =
  (try
     match Qjs_handle.pump t ~max_jobs with
     | 0 -> Ok Waiting
     | 1 -> Ok Runnable
     | _ -> Ok (Interrupted (Error.Resource.make Error.Resource.Cpu))
   with Failure msg -> Error (Engine msg))

let cancel t why = Qjs_handle.cancel t ~reason:(why.Error.Resource.kind |> function
  | Heap -> 0 | Stack -> 1 | Cpu -> 2 | Deadline -> 3 | Host_calls -> 4
  | Pending_promises -> 5 | Log_bytes -> 6 | Outbound_bytes -> 7 | Child_invocations -> 8)

let take_host_requests t =
  let arr = Qjs_handle.take_requests t in
  Array.to_list arr
  |> List.map (fun (id, op, payload) ->
      let payload =
        match Bounded_bytes.create ~max:(16 * 1024 * 1024) payload with
        | Ok b -> b | Error _ -> Bounded_bytes.empty ~max:(16*1024*1024) in
      { Qjs_host_request.id = Qjs_host_request.Id.of_int64 id;
        operation = op; payload })

let resolve_host_request _t _id _res = Ok ()

let memory_usage t =
  let (used, limit, pending) = Qjs_handle.mem_usage t in
  Memory.make ~heap_used:used ~heap_limit:limit ~atom_count:0
    ~pending_jobs:pending ~live_handles:0 ()

let destroy t = Qjs_handle.destroy t
