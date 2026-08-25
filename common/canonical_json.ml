(* Canonical JSON — deterministic serialization with sorted object keys.
   Used for the MLB1 bundle header/manifest and any value that must be
   byte-stable for digesting. See mirage_lambda_service_implementation_guide.md
   §10.4 (footer SHA-256 over all preceding bytes) and §35.3 (canonical JSON is
   deterministic across map insertion order).

   Limitation (follow-up): full RFC 8785 float canonicalization is not
   implemented; floats use a fixed shortest representation via Yojson. The
   bundle/manifest formats use strings and integers almost exclusively, so
   this is acceptable for Phase 1 and is tracked as a future hardening item. *)

module Y = Yojson.Safe

type t =
  | Null
  | Bool of bool
  | Int of int64
  | Float of float
  | String of string
  | Array of t list
  | Object of (string * t) list

let rec of_yojson : Y.t -> (t, string) result = function
  | `Null -> Ok Null
  | `Bool b -> Ok (Bool b)
  | `Int n -> Ok (Int (Int64.of_int n))
  | `Intlit s -> (try Ok (Int (Int64.of_string s)) with _ -> Error "non-canonical integer literal")
  | `Float f -> Ok (Float f)
  | `String s -> Ok (String s)
  | `List xs ->
      let rec loop acc = function
        | [] -> Ok (Array (List.rev acc))
        | x :: rest ->
            (match of_yojson x with
             | Error e -> Error e
             | Ok v -> loop (v :: acc) rest)
      in loop [] xs
  | `Assoc xs ->
      let rec loop acc = function
        | [] -> Ok (Object (List.rev acc))
        | (k, v) :: rest ->
            (match of_yojson v with
             | Error e -> Error e
             | Ok v -> loop ((k, v) :: acc) rest)
      in loop [] xs
  | _ -> Error "unsupported json variant (tuple/variant) for canonical json"

let rec to_yojson : t -> Y.t = function
  | Null -> `Null
  | Bool b -> `Bool b
  | Int n -> `Int (Int64.to_int n)  (* Phase 1: int64 fits in int for manifest sizes *)
  | Float f -> `Float f
  | String s -> `String s
  | Array xs -> `List (List.map to_yojson xs)
  | Object xs -> `Assoc (List.map (fun (k, v) -> (k, to_yojson v)) xs)

(* Sort object keys recursively; emit with no inter-token whitespace. *)
let rec sort : t -> t = function
  | Array xs -> Array (List.map sort xs)
  | Object xs ->
      let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) xs in
      Object (List.map (fun (k, v) -> (k, sort v)) sorted)
  | other -> other

let needs_escape = function
  | '"' | '\\' | '\n' | '\r' | '\t' | '\b' | '\x0c' -> true
  | c when Char.code c < 0x20 -> true
  | _ -> false

let escape_string_buf buf s =
  Buffer.add_char buf '"';
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | '\b' -> Buffer.add_string buf "\\b"
    | '\x0c' -> Buffer.add_string buf "\\f"
    | c when Char.code c < 0x20 ->
        Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buf c) s;
  Buffer.add_char buf '"'

let rec encode_buf buf : t -> unit = function
  | Null -> Buffer.add_string buf "null"
  | Bool b -> Buffer.add_string buf (if b then "true" else "false")
  | Int n -> Buffer.add_string buf (Int64.to_string n)
  | Float f ->
      (* Fixed shortest float representation. NaN/Inf are not valid JSON. *)
      if Float.is_integer f && Float.abs f < 1e15 then
        Buffer.add_string buf (string_of_int (Int64.to_int (Int64.of_float f)))
      else
        Buffer.add_string buf (Printf.sprintf "%.17g" f)
  | String s -> escape_string_buf buf s
  | Array [] -> Buffer.add_string buf "[]"
  | Array (x :: rest) ->
      Buffer.add_char buf '[';
      encode_buf buf x;
      List.iter (fun x -> Buffer.add_char buf ','; encode_buf buf x) rest;
      Buffer.add_char buf ']'
  | Object [] -> Buffer.add_string buf "{}"
  | Object ((k, v) :: rest) ->
      Buffer.add_char buf '{';
      escape_string_buf buf k;
      Buffer.add_char buf ':';
      encode_buf buf v;
      List.iter (fun (k, v) ->
        Buffer.add_char buf ','; escape_string_buf buf k;
        Buffer.add_char buf ':' ; encode_buf buf v) rest;
      Buffer.add_char buf '}'

let to_string v =
  let buf = Buffer.create 128 in
  encode_buf buf (sort v);
  Buffer.contents buf

let canonicalize yo =
  match of_yojson yo with
  | Error e -> Error e
  | Ok v -> Ok (to_string v)

let parse_exn s = Y.from_string s
