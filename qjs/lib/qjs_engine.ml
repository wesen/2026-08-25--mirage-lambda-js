(* qjs/lib/qjs_engine.ml — the public engine interface (§20.1).
   Implements the three-layer model (§36.1): QuickJS C API -> qjs_stubs.c ->
   Qjs_handle/Qjs_engine -> Runtime_host. Only qjs/c includes quickjs.h; only
   qjs/lib uses the private foreign primitives; the worker imports this
   stable interface.

   Phase 2 scaffold: the externals live in qjs/c/qjs_stubs.c and fail at
   runtime until QuickJS is vendored. The interface is pinned here so the
   worker (Phase 3) and probe (Phase 0) can compile against it. *)

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
  let make ~heap_used ~heap_limit ~atom_count ~pending_jobs ~live_headers () =
    { heap_used; heap_limit; atom_count; pending_jobs; live_handles = live_headers }
  let heap_used t = t.heap_used
  let heap_limit t = t.heap_limit
  let atom_count t = t.atom_count
  let pending_jobs t = t.pending_jobs
  let live_handles t = t.live_handles
end

type t = Qjs_handle.t

(* The limits are serialized to a blob the C side decodes (§22.2). *)
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
    (* The C side loads the bundle and verifies digests again (§10.3 step 7). *)
    ignore (bundle : Bundle.Validated.t);
    Ok h
  with Failure msg -> Error (Engine msg)

let start t ~entrypoint ~export_name ~event_json ~context_json =
  ignore (t : t);
  ignore (entrypoint : Ids.Module_path.t);
  ignore (export_name : string);
  ignore (event_json : Bounded_bytes.t);
  ignore (context_json : Bounded_bytes.t);
  (* external mlqjs_call_handler etc. — wired in Phase 2 once QuickJS lands. *)
  Ok ()

let take_host_requests _t = []
let resolve_host_request _t _id _res = Ok ()
let pump _t ~max_jobs = ignore max_jobs; Ok Need_host_work
let cancel _t _why = ()
let memory_usage _t =
  Memory.make ~heap_used:0 ~heap_limit:0 ~atom_count:0 ~pending_jobs:0 ~live_headers:0 ()
let destroy t = Qjs_handle.destroy t
