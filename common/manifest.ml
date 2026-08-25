(* Strict manifest parser + semantic checks (§10.2, §10.3, appendix B).
   Validation is ordered from cheapest to most expensive (§10.3). Unknown and
   duplicate fields are rejected. Identifiers and limits are validated. The
   common library must not depend on Unix, Lwt, Mirage, TLS, or QuickJS. *)

module Y = Yojson.Safe
open Ids
let (let*) = Result.bind

let v ~field = Error.Validation.make ~field
let ensure cond err = if cond then Ok () else Error err

(* ---- Strict association extraction: detect duplicates and unknown fields. ---- *)
let check_no_duplicates ~label assoc =
  let seen = Hashtbl.create 16 in
  let dup = ref None in
  List.iter (fun (k, _) ->
    if Hashtbl.mem seen k then (if !dup = None then dup := Some k) else Hashtbl.add seen k ()) assoc;
  match !dup with
  | Some k -> Error (v ~field:label (Printf.sprintf "duplicate field %S" k))
  | None -> Ok ()

let check_known ~label assoc known =
  match List.find_opt (fun (k, _) -> not (List.mem k known)) assoc with
  | Some (k, _) -> Error (v ~field:label (Printf.sprintf "unknown field %S" k))
  | None -> Ok ()

type io_spec = {
  format : string;
  max_bytes : int;
}

type retry_mode = Never | On_error | Always

type t = {
  schema_version : int;
  name : Function_name.t;
  entrypoint : Module_path.t;
  export : string;
  runtime : string;
  input : io_spec;
  output : io_spec;
  limits : Budget.Engine_limits.t;
  capabilities : Capability.declarations;
  retry : retry_mode;
}

let schema_version t = t.schema_version
let name t = t.name
let entrypoint t = t.entrypoint
let export t = t.export
let runtime t = t.runtime
let input t = t.input
let output t = t.output
let limits t = t.limits
let capabilities t = t.capabilities
let retry t = t.retry

(* ---- field extraction helpers (strict) ---- *)
let field ~label assoc name =
  match List.assoc_opt name assoc with
  | None -> Error (v ~field:label (Printf.sprintf "missing field %S" name))
  | Some x -> Ok x

let as_string ~label name = function
  | `String s -> Ok s
  | _ -> Error (v ~field:label (Printf.sprintf "field %S must be a string" name))

let as_int ~label name = function
  | `Int n -> Ok n
  | `Intlit s -> (try Ok (int_of_string s) with _ -> Error (v ~field:label (Printf.sprintf "field %S bad integer" name)))
  | _ -> Error (v ~field:label (Printf.sprintf "field %S must be an integer" name))

let as_bool ~label name = function
  | `Bool b -> Ok b
  | _ -> Error (v ~field:label (Printf.sprintf "field %S must be a boolean" name))

let as_list ~label name = function
  | `List xs -> Ok xs
  | _ -> Error (v ~field:label (Printf.sprintf "field %S must be an array" name))

let as_assoc ~label name = function
  | `Assoc xs -> Ok xs
  | _ -> Error (v ~field:label (Printf.sprintf "field %S must be an object" name))

(* ---- io_spec { format, maxBytes } ---- *)
let parse_io ~label json =
  let* assoc = as_assoc ~label "io" json in
  let* () = check_no_duplicates ~label assoc in
  let* () = check_known ~label assoc ["format"; "maxBytes"] in
  let* fmt_j = field ~label assoc "format" in
  let* fmt = as_string ~label "format" fmt_j in
  let* mb_j = field ~label assoc "maxBytes" in
  let* mb = as_int ~label "maxBytes" mb_j in
  if mb < 0 then Error (v ~field:label "maxBytes must be non-negative")
  else if not (String.equal fmt "json") && not (String.equal fmt "bytes") then
    Error (v ~field:label "format must be json or bytes")
  else Ok { format = fmt; max_bytes = mb }

(* ---- Engine limits ---- *)
let parse_limits json =
  let label = "limits" in
  let* assoc = as_assoc ~label "limits" json in
  let* () = check_no_duplicates ~label assoc in
  let known = ["jsHeapBytes"; "nativeOverheadBytes"; "stackBytes"; "timeoutMs";
               "cpuMs"; "maxHostCalls"; "maxPendingPromises"; "maxLogBytes";
               "maxOutboundBytes"; "maxRedirects"; "maxChildInvocations"] in
  let* () = check_known ~label assoc known in
  let get name =
    let* j = field ~label assoc name in
    as_int ~label name j in
  let* js_heap_bytes = get "jsHeapBytes" in
  let* native_overhead_bytes = get "nativeOverheadBytes" in
  let* stack_bytes = get "stackBytes" in
  let* timeout_ms = get "timeoutMs" in
  let* cpu_ms = get "cpuMs" in
  let* max_host_calls = get "maxHostCalls" in
  let* max_pending_promises = get "maxPendingPromises" in
  let* max_log_bytes = get "maxLogBytes" in
  let* max_outbound_bytes = get "maxOutboundBytes" in
  let* max_redirects = get "maxRedirects" in
  let* max_child_invocations = get "maxChildInvocations" in
  Budget.Engine_limits.make
    ~js_heap_bytes ~native_overhead_bytes ~stack_bytes ~timeout_ms ~cpu_ms
    ~max_host_calls ~max_pending_promises ~max_log_bytes ~max_outbound_bytes
    ~max_redirects ~max_child_invocations ()

(* ---- capabilities ---- *)
let parse_access ~label s =
  match s with
  | "read" -> Ok `Read
  | "write" -> Ok `Write
  | "read-write" -> Ok `Read_write
  | _ -> Error (v ~field:label (Printf.sprintf "bad access %S" s))

let parse_kv ~label json =
  let* assoc = as_assoc ~label "kv" json in
  let* () = check_no_duplicates ~label assoc in
  let* () = check_known ~label assoc ["binding"; "store"; "access"; "prefix"] in
  let* b_j = field ~label assoc "binding" in
  let* b_s = as_string ~label "binding" b_j in
  let* binding = Binding_name.of_string b_s in
  let* s_j = field ~label assoc "store" in
  let* s_s = as_string ~label "store" s_j in
  let* store = Store_id.of_string s_s in
  let* a_j = field ~label assoc "access" in
  let* a_s = as_string ~label "access" a_j in
  let* access = parse_access ~label a_s in
  let* p_j = field ~label assoc "prefix" in
  let* p_s = as_string ~label "prefix" p_j in
  let* prefix = Key_prefix.of_string p_s in
  Ok { Capability.binding; store; access; prefix }

let parse_http ~label json =
  let* assoc = as_assoc ~label "http" json in
  let* () = check_no_duplicates ~label assoc in
  let* () = check_known ~label assoc
    ["binding"; "schemes"; "hosts"; "ports"; "methods"; "maxResponseBytes"] in
  let* b_j = field ~label assoc "binding" in
  let* b_s = as_string ~label "binding" b_j in
  let* binding = Binding_name.of_string b_s in
  let* sc_j = field ~label assoc "schemes" in
  let* sc_l = as_list ~label "schemes" sc_j in
  let schemes = List.filter_map (function `String s -> Capability.Http_policy.scheme_of_string s | _ -> None) sc_l in
  let* h_j = field ~label assoc "hosts" in
  let* h_l = as_list ~label "hosts" h_j in
  let hosts = List.filter_map (function `String s -> Some s | _ -> None) h_l in
  let* p_j = field ~label assoc "ports" in
  let* p_l = as_list ~label "ports" p_j in
  let ports = List.filter_map (function `Int n -> Some n | _ -> None) p_l in
  let* m_j = field ~label assoc "methods" in
  let* m_l = as_list ~label "methods" m_j in
  let methods = List.filter_map (function `String s -> Capability.Http_policy.method_of_string s | _ -> None) m_l in
  let* mr_j = field ~label assoc "maxResponseBytes" in
  let* max_response_bytes = as_int ~label "maxResponseBytes" mr_j in
  if schemes = [] then Error (v ~field:label "http binding needs >=1 scheme")
  else if hosts = [] then Error (v ~field:label "http binding needs >=1 host")
  else if methods = [] then Error (v ~field:label "http binding needs >=1 method")
  else
    let policy = Capability.Http_policy.make ~schemes ~hosts ~ports ~methods ~max_response_bytes in
    Ok { Capability.binding; policy }

let parse_capabilities json =
  let label = "capabilities" in
  let* assoc = as_assoc ~label "capabilities" json in
  let* () = check_no_duplicates ~label assoc in
  let* () = check_known ~label assoc ["kv"; "http"; "clock"; "random"; "logs"; "invoke"] in
  let kv =
    match List.assoc_opt "kv" assoc with
    | None -> Ok []
    | Some j ->
      let* items = as_list ~label "kv" j in
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | x :: rest -> let* d = parse_kv ~label x in loop (d :: acc) rest
      in loop [] items in
  let http =
    match List.assoc_opt "http" assoc with
    | None -> Ok []
    | Some j ->
      let* items = as_list ~label "http" j in
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | x :: rest -> let* d = parse_http ~label x in loop (d :: acc) rest
      in loop [] items in
  let clock =
    match List.assoc_opt "clock" assoc with
    | None -> Ok `None
    | Some (`String "monotonic") -> Ok `Monotonic
    | Some (`String "wall") -> Ok `Wall
    | Some _ -> Error (v ~field:label "clock must be monotonic or wall")
  in
  let random =
    match List.assoc_opt "random" assoc with
    | None -> Ok `None
    | Some (`String "cryptographic") -> Ok `Cryptographic
    | Some _ -> Error (v ~field:label "random must be cryptographic")
  in
  let logs =
    match List.assoc_opt "logs" assoc with
    | None -> Ok false
    | Some j -> as_bool ~label "logs" j
  in
  let invoke =
    match List.assoc_opt "invoke" assoc with
    | None -> Ok []
    | Some j ->
      let* items = as_list ~label "invoke" j in
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | `String s :: rest ->
            let* target = Capability.Function_ref.of_string s in
            (* Derive a valid JS-identifier binding from the function name by
               mapping hyphens to underscores (§15.2 dot-access requires a
               valid identifier; function names are slugs that allow hyphens). *)
            let name_s = Function_name.to_string target.Capability.Function_ref.name in
            let binding_s = String.map (fun c -> if c = '-' then '_' else c) name_s in
            let binding = Binding_name.of_string_exn binding_s in
            loop ({ Capability.binding; target } :: acc) rest
        | _ :: _ -> Error (v ~field:label "invoke entries must be strings")
      in loop [] items in
  let* kv = kv in
  let* http = http in
  let* clock = clock in
  let* random = random in
  let* logs = logs in
  let* invoke = invoke in
  Ok { Capability.kv; http; clock; random; logs; invoke }

let parse_retry json =
  let label = "retry" in
  let* assoc = as_assoc ~label "retry" json in
  let* () = check_no_duplicates ~label assoc in
  let* () = check_known ~label assoc ["mode"] in
  let* m_j = field ~label assoc "mode" in
  let* m_s = as_string ~label "mode" m_j in
  match m_s with
  | "never" -> Ok Never
  | "on-error" -> Ok On_error
  | "always" -> Ok Always
  | _ -> Error (v ~field:label "retry.mode must be never|on-error|always")

let parse json =
  let label = "manifest" in
  let* assoc = as_assoc ~label "manifest" json in
  let* () = check_no_duplicates ~label assoc in
  let* () = check_known ~label assoc
    ["schemaVersion"; "name"; "entrypoint"; "export"; "runtime";
     "input"; "output"; "limits"; "capabilities"; "retry"] in
  let* sv_j = field ~label assoc "schemaVersion" in
  let* sv = as_int ~label "schemaVersion" sv_j in
  let* () = ensure (sv = 1) (v ~field:label "schemaVersion must be 1") in
  let* n_j = field ~label assoc "name" in
  let* n_s = as_string ~label "name" n_j in
  let* name = Function_name.of_string n_s in
  let* e_j = field ~label assoc "entrypoint" in
  let* e_s = as_string ~label "entrypoint" e_j in
  let* entrypoint = Module_path.of_string e_s in
  let* x_j = field ~label assoc "export" in
  let* export = as_string ~label "export" x_j in
  let valid_export = match export with
    | "default" | "handler" | "main" -> true
    | s -> String.length s > 0 && String.length s <= 63
  in
  let* () = ensure valid_export (v ~field:label "export must be default|handler|main or a name") in
  let* rt_j = field ~label assoc "runtime" in
  let* runtime = as_string ~label "runtime" rt_j in
  let* () = ensure (String.equal runtime "quickjs-2026-06-04")
    (v ~field:label "runtime must be quickjs-2026-06-04") in
  let* i_j = field ~label assoc "input" in
  let* input = parse_io ~label i_j in
  let* o_j = field ~label assoc "output" in
  let* output = parse_io ~label o_j in
  let* l_j = field ~label assoc "limits" in
  let* limits = parse_limits l_j in
  let* c_j = field ~label assoc "capabilities" in
  let* capabilities = parse_capabilities c_j in
  let* r_j = field ~label assoc "retry" in
  let* retry = parse_retry r_j in
  Ok { schema_version = sv; name; entrypoint; export; runtime;
       input; output; limits; capabilities; retry }

let parse_string s =
  match Y.from_string s with
  | json -> parse json
  | exception Yojson.Json_error msg -> Error (v ~field:"manifest" msg)
