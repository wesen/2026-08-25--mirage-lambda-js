(* worker/capability_broker.ml — authorizes and dispatches host calls (§20.2). *)

(* The host implementations (fakes for Phase 3, §37.3). *)
type implementations = {
  log : Host_log.t;
  clock : Host_clock.t;
  crypto : Host_crypto.t;
  kv : (string, string) Hashtbl.t;   (* single in-memory store for all bindings *)
}

let make_impls ~log ~clock ~crypto ~kv = { log; clock; crypto; kv }

(* Parse the payload "op\narg_json" from the C host.rpc callback. *)
let parse_payload payload =
  match String.index_opt payload '\n' with
  | Some i ->
    let op = String.sub payload 0 i in
    let arg_json = String.sub payload (i + 1) (String.length payload - i - 1) in
    op, arg_json
  | None -> payload, "{}"

(* Dispatch a single host request. Returns Ok json_result | Error msg. *)
let dispatch impls policy req =
  let payload = Bounded_bytes.to_string req.Qjs_host_request.payload in
  let op, arg_json = parse_payload payload in
  (* Authorization: check the operation against the compiled policy (§20.2).
   * For Phase 3, the policy check is simplified — the broker trusts the
  *  operation name and dispatches to the fake. Phase 8 adds real policy
  *  enforcement. *)
  match op with
  | "log.debug" | "log.info" | "log.warn" | "log.error" ->
    let level = match op with
      | "log.debug" -> Host_log.Debug | "log.info" -> Host_log.Info
      | "log.warn" -> Host_log.Warn | "log.error" -> Host_log.Error
      | _ -> Host_log.Info in
    (match Yojson.Safe.from_string arg_json with
     | `Assoc fields ->
       let msg = match List.assoc_opt "message" fields with
         | Some (`String s) -> s | _ -> "" in
       Host_log.append impls.log ~level msg [];
       Ok "null"
     | _ -> Ok "null")
  | "clock.monotonicMs" ->
    let ms = Host_clock.monotonic_ms impls.clock in
    Ok (string_of_int (Int64.to_int ms))
  | "crypto.randomBytes" ->
    (match Yojson.Safe.from_string arg_json with
     | `Assoc fields ->
       let n = match List.assoc_opt "length" fields with
         | Some (`Int n) -> n | _ -> 16 in
       let bytes = Host_crypto.random_bytes impls.crypto n in
       (* return as JSON array of ints *)
       let arr = Array.init (Bytes.length bytes) (fun i -> Char.code (Bytes.get bytes i)) in
       Ok (Yojson.Safe.to_string (`List (Array.to_list arr |> List.map (fun i -> `Int i))))
     | _ -> Error "crypto.randomBytes: bad arg")
  | "kv.get" ->
    (match Yojson.Safe.from_string arg_json with
     | `Assoc fields ->
       let key = match List.assoc_opt "key" fields with
         | Some (`String s) -> s | _ -> "" in
       (match Hashtbl.find_opt impls.kv key with
        | Some v -> Ok (Printf.sprintf "%S" v)
        | None -> Ok "null")
     | _ -> Error "kv.get: bad arg")
  | "kv.put" ->
    (match Yojson.Safe.from_string arg_json with
     | `Assoc fields ->
       let key = match List.assoc_opt "key" fields with Some (`String s) -> s | _ -> "" in
       let value = match List.assoc_opt "value" fields with Some (`String s) -> s | _ -> "" in
       Hashtbl.replace impls.kv key value;
       Ok "null"
     | _ -> Error "kv.put: bad arg")
  | _ ->
    Error (Printf.sprintf "unknown operation: %s" op)
