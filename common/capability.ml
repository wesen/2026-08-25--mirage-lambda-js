(* Capability system (§15). A function receives a typed object-capability
   environment; every host operation is authorized against a compiled policy.
   There is no generic catch-all host function (§15.1).

   Key invariant (§35.3, §F.1): capability intersection never grants more
   authority than either operand. *)

open Ids
let (let*) = Result.bind


(* ---- A reference to another invokable function: name@qualifier (§15.2). ---- *)
module Function_ref = struct
  type t = {
    name : Function_name.t;
    qualifier : Qualifier.t;
  }
  let make ~name ~qualifier = { name; qualifier }
  let name t = t.name
  let qualifier t = t.qualifier
  let to_string t =
    Printf.sprintf "%s@%s" (Function_name.to_string t.name) (Qualifier.to_string t.qualifier)
  let of_string s =
    match String.index_opt s '@' with
    | None -> Error (Error.Validation.make ~field:"invoke" "missing @qualifier")
    | Some i ->
        let n = String.sub s 0 i in
        let q = String.sub s (i + 1) (String.length s - i - 1) in
        let* n = Function_name.of_string n in
        let* q = Qualifier.of_string q in
        Ok { name = n; qualifier = q }
  let equal a b = Function_name.equal a.name b.name && Qualifier.equal a.qualifier b.qualifier
end

(* ---- HTTP egress policy (§16). A named HTTPS origin with strict policy. ---- *)
module Http_policy = struct
  type method_ = Get | Post | Put | Patch | Delete | Head
  let method_to_string = function
    | Get -> "GET" | Post -> "POST" | Put -> "PUT" | Patch -> "PATCH"
    | Delete -> "DELETE" | Head -> "HEAD"
  let method_of_string = function
    | "GET" -> Some Get | "POST" -> Some Post | "PUT" -> Some Put
    | "PATCH" -> Some Patch | "DELETE" -> Some Delete | "HEAD" -> Some Head
    | _ -> None
  type scheme = Https | Http
  let scheme_of_string = function "https" -> Some Https | "http" -> Some Http | _ -> None
  type t = {
    schemes : scheme list;
    hosts : string list;
    ports : int list;
    methods : method_ list;
    max_response_bytes : int;
  }
  let make ~schemes ~hosts ~ports ~methods ~max_response_bytes = {
    schemes; hosts; ports; methods; max_response_bytes;
  }
end

(* ---- Secret operation policy (§15.4). Prefer operation capabilities over
   raw secret exposure. ---- *)
module Secret_policy = struct
  type operation = Sign | Verify | Hmac | Encrypt | Decrypt
  type t = { key_id : string; operations : operation list }
  let make ~key_id ~operations = { key_id; operations }
end

(* ---- Per-operation limits (e.g., maxResponseBytes is hoisted into the
   operation-specific policy above; this is a generic envelope). ---- *)
module Operation_limits = struct
  type t = {
    max_calls : int option;
    max_bytes : int option;
  }
  let none = { max_calls = None; max_bytes = None }
  let make ?max_calls ?max_bytes () = { max_calls; max_bytes }
end

(* ---- The set of host operations a grant authorizes (§15.1). ---- *)
type operation =
  | Kv_get of { store : Store_id.t; prefix : Key_prefix.t }
  | Kv_put of { store : Store_id.t; prefix : Key_prefix.t }
  | Kv_delete of { store : Store_id.t; prefix : Key_prefix.t }
  | Log_append of { stream : Log_stream.t }
  | Http_request of Http_policy.t
  | Clock_monotonic
  | Clock_wall
  | Random_crypto
  | Invoke_function of Function_ref.t
  | Secret_operation of Secret_policy.t

type grant = {
  binding : Binding_name.t;
  operation : operation;
  limits : Operation_limits.t;
}

let grant_binding g = g.binding
let grant_operation g = g.operation

(* ---- A compiled policy is a normalized set of grants keyed by binding. ---- *)
type policy = {
  grants : grant list;   (* sorted by binding name for determinism *)
}

let empty = { grants = [] }

let compare_binding a b =
  String.compare (Binding_name.to_string a) (Binding_name.to_string b)

let sort_grants gs = List.sort (fun a b -> compare_binding a.binding b.binding) gs

let mk_policy gs = { grants = sort_grants gs }

(* ---- Declarations: the manifest-facing shape that [compile] consumes. ---- *)
type kv_decl = {
  binding : Binding_name.t;
  store : Store_id.t;
  access : [ `Read | `Write | `Read_write ];
  prefix : Key_prefix.t;
}
type http_decl = {
  binding : Binding_name.t;
  policy : Http_policy.t;
}
type invoke_decl = {
  binding : Binding_name.t;
  target : Function_ref.t;
}
type declarations = {
  kv : kv_decl list;
  http : http_decl list;
  clock : [ `Monotonic | `Wall | `None ];
  random : [ `Cryptographic | `None ];
  logs : bool;
  invoke : invoke_decl list;
}

let empty_declarations = {
  kv = []; http = []; clock = `None; random = `None; logs = false; invoke = [];
}

(* ---- Compile declarations into a policy (validation pipeline step 6). ---- *)
let compile (d : declarations) : (policy, Error.Validation.t) result =
  let grants = ref [] in
  let push g = grants := g :: !grants in
  (* kv grants *)
  List.iter (fun (k : kv_decl) ->
    let op_access = function
      | `Read -> [ Kv_get { store = k.store; prefix = k.prefix } ]
      | `Write -> [ Kv_put { store = k.store; prefix = k.prefix };
                   Kv_delete { store = k.store; prefix = k.prefix } ]
      | `Read_write -> [ Kv_get { store = k.store; prefix = k.prefix };
                         Kv_put { store = k.store; prefix = k.prefix };
                         Kv_delete { store = k.store; prefix = k.prefix } ]
    in
    List.iter (fun op -> push { binding = k.binding; operation = op; limits = Operation_limits.none })
      (op_access k.access)) d.kv;
  List.iter (fun (h : http_decl) ->
    push { binding = h.binding; operation = Http_request h.policy;
           limits = Operation_limits.none }) d.http;
  (match d.clock with
   | `Monotonic -> push { binding = Binding_name.of_string_exn "clock"; operation = Clock_monotonic; limits = Operation_limits.none }
   | `Wall -> push { binding = Binding_name.of_string_exn "clock"; operation = Clock_wall; limits = Operation_limits.none }
   | `None -> ());
  (match d.random with
   | `Cryptographic -> push { binding = Binding_name.of_string_exn "crypto"; operation = Random_crypto; limits = Operation_limits.none }
   | `None -> ());
  if d.logs then
    push { binding = Binding_name.of_string_exn "log";
           operation = Log_append { stream = Log_stream.of_string_exn "default" };
           limits = Operation_limits.none };
  List.iter (fun (i : invoke_decl) ->
    push { binding = i.binding; operation = Invoke_function i.target;
           limits = Operation_limits.none }) d.invoke;
  Ok (mk_policy !grants)

(* ---- Authorization query: does the policy grant [operation] under [binding]? ---- *)
let op_equal a b = match a, b with
  | Kv_get x, Kv_get y -> Store_id.equal x.store y.store && Key_prefix.equal x.prefix y.prefix
  | Kv_put x, Kv_put y -> Store_id.equal x.store y.store && Key_prefix.equal x.prefix y.prefix
  | Kv_delete x, Kv_delete y -> Store_id.equal x.store y.store && Key_prefix.equal x.prefix y.prefix
  | Log_append x, Log_append y -> Log_stream.equal x.stream y.stream
  | Http_request x, Http_request y ->
      (* structural equality on the simple policy record (lists/int/variants) *)
      x.Http_policy.schemes = y.Http_policy.schemes
      && x.Http_policy.hosts = y.Http_policy.hosts
      && x.Http_policy.ports = y.Http_policy.ports
      && x.Http_policy.methods = y.Http_policy.methods
      && x.Http_policy.max_response_bytes = y.Http_policy.max_response_bytes
  | Clock_monotonic, Clock_monotonic -> true
  | Clock_wall, Clock_wall -> true
  | Random_crypto, Random_crypto -> true
  | Invoke_function x, Invoke_function y -> Function_ref.equal x y
  | Secret_operation x, Secret_operation y ->
      String.equal x.Secret_policy.key_id y.Secret_policy.key_id
  | _ -> false

(* The Http_request comparison uses structural equality on the policy record.
   Phase 8 hardens egress validation beyond this (§16). *)
let _ = (op_equal : operation -> operation -> bool)

(* ---- Intersection (§F.1). The result grants an operation only if BOTH
   operands grant it. Never grants more authority than either operand. ---- *)
let intersection (a : policy) (b : policy) : policy =
  let in_b (g : grant) =
    List.exists (fun (gb : grant) ->
      Binding_name.equal g.binding gb.binding && op_equal g.operation gb.operation) b.grants
  in
  let shared = List.filter in_b a.grants in
  { grants = sort_grants shared }

let grants (p : policy) ~binding ~operation =
  List.exists (fun (g : grant) ->
    Binding_name.equal g.binding binding && op_equal g.operation operation) p.grants

let bindings (p : policy) = List.map (fun (g : grant) -> g.binding) p.grants
