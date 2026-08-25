(** Stable error taxonomy for the Mirage Lambda Service.

    Public errors have stable service codes (§9.5) and safe messages. Internal
    failure classes (§18.1) carry retry eligibility, public visibility, audit
    severity, and worker-health consequence. *)

(** Validation errors used by ids, manifest, and bundle parsers. *)
module Validation : sig
  type t = private { field : string; reason : string }
  val make : field:string -> string -> t
  val field : t -> string
  val reason : t -> string
  val to_string : t -> string
  val equal : t -> t -> bool
end

(** Resource exhaustion kinds used by budget accounting and interrupts. *)
module Resource : sig
  type kind =
    | Heap | Stack | Cpu | Deadline | Host_calls | Pending_promises
    | Log_bytes | Outbound_bytes | Child_invocations
  type t = private { kind : kind; detail : string }
  val make : ?detail:string -> kind -> t
  val kind : t -> kind
  val detail : t -> string
  val kind_to_string : kind -> string
  val to_string : t -> string
end

(** JavaScript engine errors (completion rejection). *)
module Js : sig
  type t = private { message : string; stack : string option }
  val make : ?stack:string option -> string -> t
  val message : t -> string
  val stack : t -> string option
  val to_string : t -> string
end

(** Host operation errors (capability broker / host calls). *)
module Host : sig
  type t =
    | Unauthorized of string
    | Overload of string
    | Bad_argument of string
    | Downstream of string
    | Internal of string
  val to_string : t -> string
end

(** Internal failure classification (§18.1). *)
type failure_class =
  | Client_error
  | Authentication_error
  | Authorization_error
  | Quota_error
  | Package_error
  | Function_exception
  | Function_rejection
  | Resource_exhaustion
  | Invocation_timeout
  | Invocation_cancelled
  | Capability_error
  | Downstream_error
  | Worker_protocol_error
  | Worker_crash
  | Launcher_error
  | Storage_error
  | Internal_invariant

val failure_class_to_string : failure_class -> string

(** Stable public service codes (§9.5). *)
type code =
  | Invalid_request
  | Unauthenticated
  | Forbidden
  | Not_found
  | Conflict
  | Payload_too_large
  | Invalid_manifest
  | Rate_or_quota_exceeded
  | Internal
  | Worker_failure
  | No_capacity
  | Invocation_timeout

val http_status : code -> int
val code_to_string : code -> string

(** Top-level service error. *)
type t = private {
  code : code;
  failure_class : failure_class;
  message : string;
  request_id : string option;
  retryable : bool;
}

val make :
  ?request_id:string option -> ?retryable:bool -> code:code -> failure_class:failure_class ->
  string -> t
val with_request_id : t -> string -> t
val code : t -> code
val failure_class : t -> failure_class
val message : t -> string
val request_id : t -> string option
val retryable : t -> bool
val to_string : t -> string
