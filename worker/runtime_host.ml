(* worker/runtime_host.ml — the worker dispatch loop (§23.2).
   The worker owns the only transition path between QuickJS and the host.
   It pumps the engine, drains host requests, dispatches them through the
   capability broker, resolves the Promises, and repeats until the handler
   signals completion (globalThis.__done = true) or the deadline expires. *)

type completion =
  | Fulfilled of string   (* canonical JSON result *)
  | Rejected of string    (* JS error message *)
  | Failed of Error.t
  | Timeout of Error.t

(* Run the dispatch loop until completion or timeout. The JS handler must
   set globalThis.__done = true and globalThis.__result = <value> when done. *)
let rec drive ~impls ~max_turns engine =
  if max_turns <= 0 then Timeout (Error.make ~code:Error.Invocation_timeout
    ~failure_class:Error.Invocation_timeout "drive: max_turns exceeded (possible infinite loop)")
  else begin
    (* pump pending jobs (e.g., .then callbacks) *)
    (match Qjs_engine.pump engine ~max_jobs:64 with
     | Error _ -> () | Ok _ -> ());
    (* drain and dispatch host requests *)
    let requests = Qjs_engine.take_host_requests engine in
    List.iter (fun req ->
      let id = req.Qjs_host_request.id in
      (match Capability_broker.dispatch impls Capability.empty req with
       | Ok json -> Qjs_engine.resolve engine id json
       | Error msg ->
         (* reject the Promise with a JSON error object *)
         Qjs_engine.resolve engine id
           (Printf.sprintf "{\"error\":%S}" msg))
    ) requests;
    (* pump again to settle resolved Promises *)
    (match Qjs_engine.pump engine ~max_jobs:64 with
     | Error _ -> () | Ok _ -> ());
    (* check completion *)
    (match Qjs_engine.eval_int engine "__done ? 1 : 0" with
     | Ok 1 ->
       (match Qjs_engine.eval_string engine "JSON.stringify(globalThis.__result || null)" with
        | Ok json -> Fulfilled json
        | Error e -> Rejected (match e with Engine s -> s | _ -> "?"))
     | _ -> drive ~impls ~max_turns:(max_turns - 1) engine)
  end
