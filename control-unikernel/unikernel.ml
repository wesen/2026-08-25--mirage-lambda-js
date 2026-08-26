(* control-unikernel/unikernel.ml — the Mirage control-plane unikernel functor (§26, §39).
   Phase 5 first cut: boot, structured logging, and a /healthz readiness
   endpoint served over HTTP via cohttp-mirage.

   The functor receives the devices declared in config.ml:
   - Stack: the network stack (Tcpip.Stack.V4V6)
   - Certs: read-only certificate KV (unused until TLS is wired, §39.2 step 2)
   - State: read/write KV (Chamelon) for the registry/artifact metadata
   - Http: the Cohttp_mirage server (Server.Make(Conduit) over the stack)

   The Http device is the result of `cohttp_server @@ conduit_direct ~tls:false stack`.
   It satisfies Cohttp_mirage.Server.S, which includes Cohttp_lwt.S.Server. The
   server is constructed with `Http.make ~callback:(conn -> Request.t -> Body.t ->
   (Http.Response.t * Body.t) Lwt.t) ()`, and served with
   `Http.listen http ~ctx conduit httpd`. *)

module Main
  (Stack : Tcpip.Stack.V4V6)
  (Certs : Mirage_kv.RO)
  (State : Mirage_kv.RW)
  (Http : Cohttp_mirage.Server.S) = struct

  module Log = struct
    let info fmt = Printf.ksprintf (fun s -> Logs.info (fun m -> m "%s" s)) fmt
    let warn fmt = Printf.ksprintf (fun s -> Logs.warn (fun m -> m "%s" s)) fmt
  end

  (* §9 API: a single /healthz route for Phase 5 step 1-2. The full router
     (deploy/invoke/alias) is added when the KV-backed registry lands (§39.2
     step 3+). The callback returns a (Response.t * Body.t) Lwt.t, built with
     Http.respond_string. *)
  let callback _conn request _body =
    let (meth, uri) = (Cohttp.Request.meth request, Cohttp.Request.uri request) in
    let path = Uri.path uri in
    match meth, path with
    | `GET, "/healthz" ->
        Http.respond_string
          ~status:`OK
          ~body:"{\"status\":\"ok\"}"
          ~headers:(Cohttp.Header.of_list ["content-type", "application/json"])
          ()
    | _ ->
        Http.respond_string
          ~status:`Not_found
          ~body:"{\"error\":\"not found\"}"
          ~headers:(Cohttp.Header.of_list ["content-type", "application/json"])
          ()

  let start stack _certs _state http =
    Log.info "mirage-lambda-control unikernel starting";
    (* construct the HTTP server with our callback *)
    let httpd = Http.make ~callback () in
    (* mirage passes `http = Cohttp_mirage.Server.Make(Conduit).listen conduit`,
       which has type [Conduit_mirage.server -> t -> unit Lwt.t]. We supply the
       conduit server (`TCP port) and the httpd. The port is a runtime arg. *)
    let port = Mirage_runtime.register_arg
      Cmdliner.Arg.(value & opt int 8080 (Cmdliner.Arg.info ["port"] ~doc:"HTTP port"))
    in
    let serve () = http (`TCP port) httpd in
    (* serve HTTP and run the stack concurrently *)
    Lwt.choose [ serve (); Stack.listen stack ]
end
