(* control/unikernel.ml — the Mirage control-plane unikernel functor (§26, §39).
   Phase 5 first cut: boot, structured logging, and a /healthz readiness
   endpoint served over HTTP. The §9 API routes (deploy, invoke, alias) are
   added in subsequent §39.2 steps against the Mirage KV state store.

   The functor receives the devices declared in config.ml:
   - Stack: the network stack
   - Certs: read-only certificate KV (unused until TLS is wired)
   - State: read/write KV (Chamelen) for the registry/artifact metadata
   - Http: the Cohttp server *)

open Lwt

module Main
  (Stack : Tcpip.Stack.V4V6)
  (Certs : Mirage_kv.RO)
  (State : Mirage_kv.RW)
  (Http : Cohttp_mirage.Server.S) = struct

  module Log = struct
    let info fmt = Printf.ksprintf (fun s -> Logs.info (fun m -> m "%s" s)) fmt
    let warn fmt = Printf.ksprintf (fun s -> Logs.warn (fun m -> m "%s" s)) fmt
  end

  (* A minimal in-memory registry for Phase 5 step 3 (read-only registry backed
     by Mirage KV comes next). For now, the unikernel boots and serves health. *)
  let state : (string, string) Hashtbl.t = Hashtbl.create 16

  (* §9 API: a single /healthz route for Phase 5 step 1-2. The full router
     (deploy/invoke/alias) is added when the KV-backed registry lands. *)
  let callback _conn request _body =
    let (meth, uri) = (Cohttp.Request.meth request, Cohttp.Request.uri request) in
    let path = Uri.path uri in
    let module S = Cohttp_mirage.Server.Make (Http) in
    match meth, path with
    | `GET, "/healthz" ->
        S.respond_string ~status:`OK ~body:"{\"status\":\"ok\"}"
          ~headers:(Cohttp.Header.of_list ["content-type", "application/json"]) ()
    | _ ->
        S.respond_string ~status:`Not_found ~body:"{\"error\":\"not found\"}"
          ~headers:(Cohttp.Header.of_list ["content-type", "application/json"]) ()

  let start stack _certs _state http =
    Log.info "mirage-lambda-control unikernel starting";
    let httpd = Http.make ~callback () in
    let listen () =
      Http.listen http ~ctx:Http.default_ctx httpd
    in
    (* serve HTTP and run the stack concurrently *)
    Lwt.choose [ listen (); Stack.listen stack ]
end
