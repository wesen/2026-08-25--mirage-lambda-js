(* Bounded byte strings. A [t] is a byte string together with a hard maximum
   length; every constructor checks the bound and never silently truncates.
   Used for input/output/event/context buffers, manifest fields, and host
   request/response payloads (§20.1). *)

let invalid_payload msg = Error.make ~code:Error.Payload_too_large
  ~failure_class:Error.Package_error msg

type t = {
  bytes : string;
  max : int;
}

let max t = t.max
let length t = String.length t.bytes
let to_string t = t.bytes
let unsafe_bytes t = t.bytes

(* The empty bounded string for a given bound. *)
let empty ~max = { bytes = ""; max }

let create ~max s =
  if max < 0 then Error (invalid_payload "negative bound")
  else if String.length s > max then
    Error (invalid_payload
      (Printf.sprintf "value length %d exceeds bound %d" (String.length s) max))
  else Ok { bytes = s; max }

let create_exn ~max s =
  match create ~max s with
  | Ok v -> v
  | Error e -> failwith (Error.to_string e)

(* Concatenate, checking the common bound. Both operands must share the same
   bound (we take the smaller to be safe). *)
let append a b =
  let max = min a.max b.max in
  let combined = a.bytes ^ b.bytes in
  create ~max combined

let sub t ~off ~len =
  if off < 0 || len < 0 || off + len > String.length t.bytes then
    Error (invalid_payload "sub out of range")
  else
    Ok { t with bytes = String.sub t.bytes off len }

let copy_bytes t = t   (* strings are immutable in OCaml 4.14 *)

let equal a b = String.equal a.bytes b.bytes

let of_string ~max s = create ~max s
