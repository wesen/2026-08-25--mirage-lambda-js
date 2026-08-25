(** Capability system (§15). A function receives a typed object-capability
    environment; every host operation is authorized against a compiled policy.
    There is no generic catch-all host function (§15.1).

    Key invariant (§35.3, §F.1): capability intersection never grants more
    authority than either operand. *)

open Ids

(** A reference to another invokable function: name@qualifier (§15.2). *)
module Function_ref : sig
  type t = { name : Function_name.t; qualifier : Qualifier.t }
  val make : name:Function_name.t -> qualifier:Qualifier.t -> t
  val name : t -> Function_name.t
  val qualifier : t -> Qualifier.t
  val to_string : t -> string
  val of_string : string -> (t, Error.Validation.t) result
  val equal : t -> t -> bool
end

module Http_policy : sig
  type method_ = Get | Post | Put | Patch | Delete | Head
  type scheme = Https | Http
  type t = {
    schemes : scheme list;
    hosts : string list;
    ports : int list;
    methods : method_ list;
    max_response_bytes : int;
  }
  val make :
    schemes:scheme list -> hosts:string list -> ports:int list ->
    methods:method_ list -> max_response_bytes:int -> t
  val method_to_string : method_ -> string
  val method_of_string : string -> method_ option
  val scheme_of_string : string -> scheme option
end

module Secret_policy : sig
  type operation = Sign | Verify | Hmac | Encrypt | Decrypt
  type t = { key_id : string; operations : operation list }
  val make : key_id:string -> operations:operation list -> t
end

module Operation_limits : sig
  type t = { max_calls : int option; max_bytes : int option }
  val none : t
  val make : ?max_calls:int -> ?max_bytes:int -> unit -> t
end

(** The set of host operations a grant authorizes (§15.1). *)
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

val grant_binding : grant -> Binding_name.t
val grant_operation : grant -> operation

(** A compiled policy is a normalized set of grants keyed by binding. *)
type policy = { grants : grant list }

val empty : policy
val mk_policy : grant list -> policy

(** Manifest-facing declaration shapes that [compile] consumes. *)
type kv_decl = {
  binding : Binding_name.t;
  store : Store_id.t;
  access : [ `Read | `Write | `Read_write ];
  prefix : Key_prefix.t;
}
type http_decl = { binding : Binding_name.t; policy : Http_policy.t }
type invoke_decl = { binding : Binding_name.t; target : Function_ref.t }
type declarations = {
  kv : kv_decl list;
  http : http_decl list;
  clock : [ `Monotonic | `Wall | `None ];
  random : [ `Cryptographic | `None ];
  logs : bool;
  invoke : invoke_decl list;
}

val empty_declarations : declarations

(** Compile declarations into a policy (validation pipeline step 6). *)
val compile : declarations -> (policy, Error.Validation.t) result

(** Structural equality on operations (Phase 8 hardens HTTP egress). *)
val op_equal : operation -> operation -> bool

(** Intersection (§F.1): the result grants an operation only if BOTH operands
    grant it. Never grants more authority than either operand. *)
val intersection : policy -> policy -> policy

(** Authorization query. *)
val grants : policy -> binding:Binding_name.t -> operation:operation -> bool

val bindings : policy -> Binding_name.t list
