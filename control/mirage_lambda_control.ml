(* control/control_main.ml — the single-appliance Unix control plane (§38).
   Serves the §9 API over HTTP using cohttp-lwt-unix. Phase 4 is
   trusted/single-tenant: auth is a simple bearer token, no TLS, in-process
   workers. *)

module Y = Yojson.Safe

let (let*) = Lwt.bind

type config = {
  bind_addr : string;       (* "127.0.0.1" *)
  bind_port : int;           (* 8080 *)
  artifact_root : string;    (* directory for the artifact store *)
  checkpoint_path : string;  (* registry checkpoint *)
  dev_token : string;        (* bearer token for development (Phase 4 only) *)
}

let default_config = {
  bind_addr = "127.0.0.1";
  bind_port = 8080;
  artifact_root = (Filename.concat (Sys.getcwd ()) ".mirage-lambda/objects");
  checkpoint_path = (Filename.concat (Sys.getcwd ()) ".mirage-lambda/registry.json");
  dev_token = "dev-token";
}

type state = {
  config : config;
  artifact_store : Artifact_store.t;
  registry : Registry.t;
  admission : Admission.t;
  scheduler : Scheduler.t;
  mutable invocations : (Protocol.Invocation_id.t, Worker_pool.invocation_result) Hashtbl.t;
}

let make_state config =
  let artifact_store = Artifact_store.make ~root:config.artifact_root in
  let registry = Registry.make ~checkpoint_path:config.checkpoint_path () in
  { config; artifact_store; registry;
    admission = Admission.make ();
    scheduler = Scheduler.make ();
    invocations = Hashtbl.create 64 }

(* ---- HTTP helpers ---- *)
let json_response ~status body =
  Cohttp_lwt_unix.Server.respond_string ~status ~body ~headers:(Cohttp.Header.of_list ["content-type", "application/json"]) ()

let error_response ~status code message =
  let body = Y.to_string (`Assoc [
    ("error", `Assoc [("code", `String code); ("message", `String message)]);
  ]) in
  json_response ~status body

let ok_response body = json_response ~status:`OK body
let created_response body = json_response ~status:`Created body
let accepted_response body = json_response ~status:`Accepted body

let read_body body =
  Cohttp_lwt.Body.to_string body

let check_auth state request =
  match Cohttp.Header.get (Cohttp.Request.headers request) "authorization" with
  | Some auth when String.length auth > 7 && String.sub auth 0 7 = "Bearer " ->
      let token = String.sub auth 7 (String.length auth - 7) in
      String.equal token state.config.dev_token
  | _ -> false

(* ---- route handlers ---- *)
let handle_deploy state ~tenant ~function_name body =
  (* body is the MLB1 bundle bytes *)
  match Bundle.parse body with
  | Error e -> error_response ~status:`Bad_request "INVALID_REQUEST" (Error.to_string e)
  | Ok bundle ->
  let manifest = Bundle.Validated.manifest bundle in
  let manifest_json = Bundle.Validated.manifest_json bundle |> Canonical_json.to_string in
  (* compute the digest of the bundle *)
  let digest = Bundle.Sha256.to_hex (Bundle.Sha256.hash body) in
  (match Ids.Digest.of_string digest with
   | Error _ -> error_response ~status:`Bad_request "INVALID_REQUEST" "bad digest"
   | Ok digest_t ->
  (* store the artifact *)
  (match Artifact_store.put_if_absent state.artifact_store ~digest_bytes:digest_t body with
   | Error e -> error_response ~status:`Internal_server_error "INTERNAL" (Error.to_string e)
   | Ok _ ->
  (* publish the revision *)
  let now = Unix.gettimeofday () |> Printf.sprintf "%.0f" in
  let revision = {
    Registry.digest = digest_t;
    manifest_json;
    runtime = Manifest.runtime manifest;
    created_at = now;
  } in
  (match Registry.publish_revision state.registry
    ~tenant ~function_name ~revision with
   | Error e -> error_response ~status:`Conflict "CONFLICT" (Error.to_string e)
   | Ok () ->
  let resp = `Assoc [
    ("function", `String (Ids.Function_name.to_string function_name));
    ("revision", `String ("sha256:" ^ digest));
    ("runtime", `String (Manifest.runtime manifest));
    ("bundleBytes", `Int (String.length body));
  ] in
  created_response (Y.to_string resp))
  )
  )

let handle_move_alias state ~tenant ~function_name ~alias body_json =
  let json = Y.from_string body_json in
  let rev_s = match json with
    | `Assoc f -> (match List.assoc_opt "revision" f with Some (`String s) -> s | _ -> "")
    | _ -> "" in
  match Ids.Revision_id.of_string rev_s with
  | Error _ -> error_response ~status:`Bad_request "INVALID_REQUEST" "bad revision"
  | Ok rev_id ->
  (match Registry.move_alias state.registry
    ~tenant ~function_name ~alias ~revision:rev_id ~precondition:None with
   | Error e -> error_response ~status:`Conflict "CONFLICT" (Error.to_string e)
   | Ok () -> ok_response "{}")

let now_ms' () = Int64.of_float (Unix.gettimeofday () *. 1000.0)

let handle_invoke state ~tenant ~function_name ~qualifier ~async body =
  (* generate invocation id *)
  let invocation_id = Protocol.Invocation_id.of_string_exn
    (Printf.sprintf "inv-%d" (Hashtbl.length state.invocations + 1)) in
  (* admission check *)
  let now = now_ms' () in
  let deadline = Int64.add now 5000L in
  (match Admission.admit state.admission ~tenant
    ~deadline_ms:deadline ~now_ms:now ~request_bytes:(String.length body) with
   | Error e -> error_response ~status:`Too_many_requests "RATE_OR_QUOTA_EXCEEDED" (Error.to_string e)
   | Ok () ->
  if async then begin
    (* async: enqueue and return 202 with invocation_id *)
    let pending = Scheduler.pending
      ~invocation_id ~tenant ~function_name
      ~qualifier:(Ids.Qualifier.of_string_exn qualifier)
      ~event_json:body ~deadline_ms:deadline ~enqueue_time_ms:now in
    let _ = Scheduler.enqueue state.scheduler pending in
    let resp = `Assoc [("invocationId", `String (Protocol.Invocation_id.to_string invocation_id))] in
    accepted_response (Y.to_string resp)
  end else begin
    (* sync: run immediately *)
    match Admission.accept_for_execution state.admission ~tenant with
    | Error e -> error_response ~status:`Too_many_requests "RATE_OR_QUOTA_EXCEEDED" (Error.to_string e)
    | Ok () ->
    let result = Worker_pool.run_one
      ~artifact_store:state.artifact_store ~registry:state.registry
      ~invocation_id ~tenant ~function_name
      ~qualifier:(Ids.Qualifier.of_string_exn qualifier)
      ~event_json:body ~deadline_ms:deadline in
    Admission.release state.admission ~tenant;
    (match result with
     | Ok r ->
        Hashtbl.replace state.invocations invocation_id r;
        let body = match r.Worker_pool.result with
          | `Fulfilled json -> json
          | `Rejected msg -> Printf.sprintf "{\"error\":{\"message\":%S}}" msg
          | `Failed e -> Printf.sprintf "{\"error\":{\"message\":%S}}" (Error.to_string e)
          | `Timeout e -> Printf.sprintf "{\"error\":{\"message\":%S}}" (Error.to_string e) in
        let resp = `Assoc [
          ("invocationId", `String (Protocol.Invocation_id.to_string invocation_id));
          ("durationMs", `Float r.Worker_pool.duration_ms);
        ] in
        ok_response (Y.to_string resp ^ "\n" ^ body)
     | Error e -> error_response ~status:`Not_found "NOT_FOUND" (Error.to_string e))
  end)


(* ---- the request callback ---- *)
let callback state _conn request body =
  let (meth, uri) = (Cohttp.Request.meth request, Cohttp.Request.uri request) in
  let path = Uri.path uri in
  let parts = String.split_on_char '/' path |> List.filter (fun s -> s <> "") in
  (* health (no auth) *)
  if path = "/healthz" then ok_response "{\"status\":\"ok\"}"
  else if not (check_auth state request) then
    error_response ~status:`Unauthorized "UNAUTHENTICATED" "missing or invalid bearer token"
  else
    (* route: /v1/tenants/{tenant}/functions/{name}/versions (deploy) *)
    match meth, parts with
    | `POST, ["v1"; "tenants"; tenant; "functions"; fn; "versions"] ->
        let* tenant_t = Lwt.return (Ids.Tenant_id.of_string tenant) in
        let* fn_t = Lwt.return (Ids.Function_name.of_string fn) in
        let* body_str = read_body body in
        (match tenant_t, fn_t with
         | Ok t, Ok f -> handle_deploy state ~tenant:t ~function_name:f body_str
         | Error e, _ | _, Error e -> error_response ~status:`Bad_request "INVALID_REQUEST" (Error.Validation.to_string e))
    | `PUT, ["v1"; "tenants"; tenant; "functions"; fn; "aliases"; alias] ->
        let* tenant_t = Lwt.return (Ids.Tenant_id.of_string tenant) in
        let* fn_t = Lwt.return (Ids.Function_name.of_string fn) in
        let* alias_t = Lwt.return (Ids.Alias.of_string alias) in
        let* body_str = read_body body in
        (match tenant_t, fn_t, alias_t with
         | Ok t, Ok f, Ok a -> handle_move_alias state ~tenant:t ~function_name:f ~alias:a body_str
         | _ -> error_response ~status:`Bad_request "INVALID_REQUEST" "bad identifiers")
    | `POST, ["v1"; "invoke"; tenant; fn; qualifier] ->
        let* tenant_t = Lwt.return (Ids.Tenant_id.of_string tenant) in
        let* fn_t = Lwt.return (Ids.Function_name.of_string fn) in
        let* body_str = read_body body in
        (match tenant_t, fn_t with
         | Ok t, Ok f -> handle_invoke state ~tenant:t ~function_name:f ~qualifier ~async:false body_str
         | _ -> error_response ~status:`Bad_request "INVALID_REQUEST" "bad identifiers")
    | `POST, ["v1"; "invoke-async"; tenant; fn; qualifier] ->
        let* tenant_t = Lwt.return (Ids.Tenant_id.of_string tenant) in
        let* fn_t = Lwt.return (Ids.Function_name.of_string fn) in
        let* body_str = read_body body in
        (match tenant_t, fn_t with
         | Ok t, Ok f -> handle_invoke state ~tenant:t ~function_name:f ~qualifier ~async:true body_str
         | _ -> error_response ~status:`Bad_request "INVALID_REQUEST" "bad identifiers")
    | _ -> error_response ~status:`Not_found "NOT_FOUND" ("no route: " ^ path)

(* ---- server ---- *)
let server config =
  let state = make_state config in
  Printf.printf "[control] listening on %s:%d\n" config.bind_addr config.bind_port;
  Printf.printf "[control] dev token: %s\n" config.dev_token;
  let httpd = Cohttp_lwt_unix.Server.make ~callback:(callback state) () in
  let mode = `TCP (`Port config.bind_port) in
  Cohttp_lwt_unix.Server.create ~mode httpd

let () = Lwt_main.run (server default_config)
