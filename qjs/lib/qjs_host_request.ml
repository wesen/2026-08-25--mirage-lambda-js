(* qjs/lib/qjs_host_request.ml — host request type (§23.1, §20.1 take_host_requests).
   A host request is what a JavaScript host callback enqueues in C; the OCaml
   side drains it, performs the authorized/metered operation, and resolves or
   rejects the corresponding Promise. *)

module Id = struct
  type t = int64
  let to_int64 (x : t) : int64 = x
  let of_int64 (x : int64) : t = x
  let equal a b = Int64.equal a b
end

type result_kind = [ `Json | `Bytes | `Unit ]

type result =
  | Json of Bounded_bytes.t
  | Bytes of Bounded_bytes.t
  | Unit

type t = {
  id : Id.t;
  operation : string;   (* e.g. "kv.get", "http.request", "clock.monotonic" *)
  payload : Bounded_bytes.t;   (* canonical JSON argument(s) *)
}

let id r = r.id
let operation r = r.operation
let payload r = r.payload
