(* Stable error taxonomy for the Mirage Lambda Service.
   Public errors have stable service codes (§9.5) and safe messages. Internal
   failure classes (§18.1) carry retry eligibility, public visibility, audit
   severity, and worker-health consequence. See
   mirage_lambda_service_implementation_guide.md §9.5 and §18.1. *)

(* ---- Validation errors (used by ids, manifest, bundle) ---- *)
module Validation = struct
  type t = {
    field : string;
    reason : string;
  }
  let make ~field reason = { field; reason }
  let field t = t.field
  let reason t = t.reason
  let to_string t = Printf.sprintf "%s: %s" t.field t.reason
  let equal a b = String.equal a.field b.field && String.equal a.reason b.reason
end

(* ---- Resource exhaustion (used by budget, interrupt) ---- *)
module Resource = struct
  type kind =
    | Heap
    | Stack
    | Cpu
    | Deadline
    | Host_calls
    | Pending_promises
    | Log_bytes
    | Outbound_bytes
    | Child_invocations
  type t = {
    kind : kind;
    detail : string;
  }
  let kind_to_string = function
    | Heap -> "heap" | Stack -> "stack" | Cpu -> "cpu"
    | Deadline -> "deadline" | Host_calls -> "host-calls"
    | Pending_promises -> "pending-promises" | Log_bytes -> "log-bytes"
    | Outbound_bytes -> "outbound-bytes" | Child_invocations -> "child-invocations"
  let to_string t = Printf.sprintf "resource:%s (%s)" (kind_to_string t.kind) t.detail
  let make ?(detail="") kind = { kind; detail }
  let kind t = t.kind
  let detail t = t.detail
end

(* ---- JavaScript engine errors (completion rejection) ---- *)
module Js = struct
  type t = {
    message : string;
    stack : string option;
  }
  let make ?(stack=None) message = { message; stack }
  let message t = t.message
  let stack t = t.stack
  let to_string t =
    match t.stack with
    | Some s -> Printf.sprintf "%s\n%s" t.message s
    | None -> t.message
end

(* ---- Host operation errors ---- *)
module Host = struct
  type t =
    | Unauthorized of string       (* capability denied *)
    | Overload of string           (* queue full *)
    | Bad_argument of string
    | Downstream of string        (* egress/kv failure *)
    | Internal of string
  let to_string = function
    | Unauthorized m -> "unauthorized: " ^ m
    | Overload m -> "overload: " ^ m
    | Bad_argument m -> "bad-argument: " ^ m
    | Downstream m -> "downstream: " ^ m
    | Internal m -> "internal: " ^ m
end

(* ---- Internal failure classification (§18.1) ---- *)
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

let failure_class_to_string = function
  | Client_error -> "client_error"
  | Authentication_error -> "authentication_error"
  | Authorization_error -> "authorization_error"
  | Quota_error -> "quota_error"
  | Package_error -> "package_error"
  | Function_exception -> "function_exception"
  | Function_rejection -> "function_rejection"
  | Resource_exhaustion -> "resource_exhaustion"
  | Invocation_timeout -> "invocation_timeout"
  | Invocation_cancelled -> "invocation_cancelled"
  | Capability_error -> "capability_error"
  | Downstream_error -> "downstream_error"
  | Worker_protocol_error -> "worker_protocol_error"
  | Worker_crash -> "worker_crash"
  | Launcher_error -> "launcher_error"
  | Storage_error -> "storage_error"
  | Internal_invariant -> "internal_invariant"

(* ---- Stable public service codes (§9.5) ---- *)
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

let http_status = function
  | Invalid_request -> 400
  | Unauthenticated -> 401
  | Forbidden -> 403
  | Not_found -> 404
  | Conflict -> 409
  | Payload_too_large -> 413
  | Invalid_manifest -> 422
  | Rate_or_quota_exceeded -> 429
  | Internal -> 500
  | Worker_failure -> 502
  | No_capacity -> 503
  | Invocation_timeout -> 504

let code_to_string = function
  | Invalid_request -> "INVALID_REQUEST"
  | Unauthenticated -> "UNAUTHENTICATED"
  | Forbidden -> "FORBIDDEN"
  | Not_found -> "NOT_FOUND"
  | Conflict -> "CONFLICT"
  | Payload_too_large -> "PAYLOAD_TOO_LARGE"
  | Invalid_manifest -> "INVALID_MANIFEST"
  | Rate_or_quota_exceeded -> "RATE_OR_QUOTA_EXCEEDED"
  | Internal -> "INTERNAL"
  | Worker_failure -> "WORKER_FAILURE"
  | No_capacity -> "NO_CAPACITY"
  | Invocation_timeout -> "INVOCATION_TIMEOUT"

(* Top-level service error. Every error body contains a request id and a
   stable service code. *)
type t = {
  code : code;
  failure_class : failure_class;
  message : string;       (* safe, never contains secrets/raw pointers *)
  request_id : string option;
  retryable : bool;
}

let make ?(request_id=None) ?(retryable=false) ~code ~failure_class message =
  { code; failure_class; message; request_id; retryable }

let code t = t.code
let failure_class t = t.failure_class
let message t = t.message
let request_id t = t.request_id
let retryable t = t.retryable

let with_request_id t request_id = { t with request_id = Some request_id }

let to_string t =
  Printf.sprintf "%s (%d): %s%s"
    (code_to_string t.code) (http_status t.code) t.message
    (match t.request_id with Some id -> " [req=" ^ id ^ "]" | None -> "")
