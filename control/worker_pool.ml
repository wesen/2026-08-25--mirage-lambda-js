(* control/worker_pool.ml — worker pool (§13, §20.6). Phase 4: in-process
   runtimes. Each "worker" is a fresh Qjs_engine created per invocation (no
   runtime reuse, §38.1). The pool resolves the revision, loads the bundle,
   creates an engine, loads modules, and drives the dispatch loop to
   completion. *)

let (let*) = Result.bind


type worker_spec = {
  tenant : Ids.Tenant_id.t;
  function_name : Ids.Function_name.t;
  revision : Ids.Digest.t;
}

type invocation_result = {
  invocation_id : Protocol.Invocation_id.t;
  result : [ `Fulfilled of string | `Rejected of string | `Failed of Error.t | `Timeout of Error.t ];
  duration_ms : float;
}

let now_ms () = Int64.of_float (Unix.gettimeofday () *. 1000.0)

(* Run a single invocation synchronously. *)
let run_one
    ~artifact_store ~registry ~invocation_id ~tenant ~function_name ~qualifier
    ~event_json ~deadline_ms =
  let start = now_ms () in
  (* 1. resolve the revision *)
  let* rev_id = Result.map_error
    (fun e -> e) (Registry.resolve registry ~tenant ~function_name ~qualifier) in
  let rev_digest = Ids.Revision_id.to_string rev_id |> fun s -> Result.get_ok (Ids.Digest.of_string s) in
  (* 2. fetch the bundle *)
  let* bundle_bytes = Artifact_store.get artifact_store rev_digest in
  (* 3. parse the bundle (re-verifies digests) *)
  let* bundle = Bundle.parse bundle_bytes in
  let manifest = Bundle.Validated.manifest bundle in
  (* 4. build the limits from the manifest *)
  let limits = Manifest.limits manifest in
  (* 5. compile the capability policy *)
  let* policy = Result.map_error
    (fun e -> Error.make ~code:Error.Invalid_manifest ~failure_class:Error.Package_error
      (Error.Validation.to_string e)) (Capability.compile (Manifest.capabilities manifest)) in
  (* 6. create the engine *)
  let* engine = Result.map_error
    (fun e -> Error.make ~code:Error.Worker_failure ~failure_class:Error.Function_exception
      (match e with Qjs_engine.Engine s -> s | _ -> "engine create failed"))
    (Qjs_engine.create ~limits ~bundle) in
  Qjs_engine.install_host engine;
  (* 7. load the modules into the engine *)
  List.iter (fun m ->
    Qjs_engine.set_module engine m.Bundle.path m.Bundle.content) (Bundle.Validated.modules bundle);
  (* 8. set up the host fakes (Phase 4: all in-memory) *)
  let log = Host_log.make ~max_bytes:(limits.Budget.Engine_limits.max_log_bytes) in
  let clock = Host_clock.make_real () in
  let crypto = Host_crypto.make_real () in
  let kv = Hashtbl.create 8 in
  let impls = Capability_broker.make_impls ~log ~clock ~crypto ~kv in
  (* 9. evaluate the entrypoint module *)
  let _ = Qjs_engine.eval_module engine (Manifest.entrypoint manifest) in
  (* 10. call the handler with the event *)
  let call_src = Printf.sprintf
    "globalThis.__done = false; globalThis.__result = null;\n\
     (async () => {\n\
       try {\n\
         const handler = (await import(%S)).default || globalThis.main || globalThis.handler;\n\
         const event = %s;\n\
         const ctx = { invocationId: %S, attempt: 1, deadlineMs: %d };\n\
         const result = await handler(event, {}, ctx);\n\
         globalThis.__result = result;\n\
         globalThis.__done = true;\n\
       } catch (e) {\n\
         globalThis.__error = String(e && e.message || e);\n\
         globalThis.__done = true;\n\
       }\n\
     })();"
    (Ids.Module_path.to_string (Manifest.entrypoint manifest))
    (if event_json = "" then "null" else event_json)
    (Protocol.Invocation_id.to_string invocation_id)
    (Int64.to_int deadline_ms) in
  let _ = Qjs_engine.eval engine call_src in
  (* 11. drive the dispatch loop *)
  let completion = Runtime_host.drive ~impls ~max_turns:100 engine in
  let duration = (Int64.to_float (Int64.sub (now_ms ()) start)) /. 1000.0 in
  Qjs_engine.destroy engine;
  let result = match completion with
    | Runtime_host.Fulfilled json -> `Fulfilled json
    | Runtime_host.Rejected msg -> `Rejected msg
    | Runtime_host.Failed e -> `Failed e
    | Runtime_host.Timeout e -> `Timeout e in
  Ok { invocation_id; result; duration_ms = duration }
