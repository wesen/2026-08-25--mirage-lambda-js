(* Validated identifier types. Identifiers are abstract types with validated
   constructors; raw strings never become storage paths (§11.2, §35.2).
   Validation policy (§35.2):
     length 1..63 bytes; alphabet lowercase ASCII letters, digits, hyphen;
     first/last alphanumeric; no slash, dot segments, percent-encoding, or
   Unicode confusables (excluded by the ASCII-only alphabet).
   Distinct types are produced via the [Slug] functor so the type system keeps
   a [Function_name.t] out of a [Tenant_id.t] slot. *)

module type NAME = sig
  val label : string
end

module type SLUG = sig
  type t = private string
  val label : string
  val of_string : string -> (t, Error.Validation.t) result
  val of_string_exn : string -> t
  val to_string : t -> string
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val hash : t -> int
end

let is_lower_alpha c = c >= 'a' && c <= 'z'
let is_digit c = c >= '0' && c <= '9'
let is_alnum c = is_lower_alpha c || is_digit c
let is_hyphen c = c = '-'

let validate_slug ~label s =
  let len = String.length s in
  if len = 0 then Error (Error.Validation.make ~field:label "empty")
  else if len > 63 then Error (Error.Validation.make ~field:label (Printf.sprintf "length %d > 63" len))
  else if not (is_alnum s.[0]) then Error (Error.Validation.make ~field:label "must start alphanumeric")
  else if not (is_alnum s.[len - 1]) then Error (Error.Validation.make ~field:label "must end alphanumeric")
  else begin
    let bad = ref None in
    (try
       String.iter (fun c ->
         if not (is_alnum c || is_hyphen c) then
           (bad := Some c; raise Exit)) s
     with Exit -> ());
    match !bad with
    | Some c -> Error (Error.Validation.make ~field:label
        (Printf.sprintf "illegal character %C (allowed: a-z 0-9 -)" c))
    | None ->
        (* reject consecutive hyphens and hyphen-only-allowed sequences only
           if they form a reserved look; allow otherwise. Consecutive hyphens
           are legal but discouraged; we allow them for v1. *)
        if String.equal s "--" || String.equal s "-" then
          Error (Error.Validation.make ~field:label "must contain an alphanumeric char")
        else
          Ok s
  end

(* Functor producing a distinct validated-slug module. *)
module Slug (N : NAME) = struct
  type t = string
  let label = N.label
  let of_string s = validate_slug ~label:N.label s
  let of_string_exn s =
    match of_string s with
    | Ok v -> v
    | Error e -> failwith (Error.Validation.to_string e)
  let to_string t = t
  let compare a b = String.compare a b
  let equal a b = String.equal a b
  let hash t = Hashtbl.hash t
end

module Function_name = Slug (struct let label = "name" end)
module Tenant_id    = Slug (struct let label = "tenant" end)
module Alias         = Slug (struct let label = "alias" end)
module Store_id       = Slug (struct let label = "store" end)
module Log_stream     = Slug (struct let label = "stream" end)
module Qualifier      = Slug (struct let label = "qualifier" end)

(* ---- Binding_name: a JS-identifier-like name (camelCase allowed).
   §15.2 uses `env.http.metadataApi.request(...)` and §10.2 uses bindings like
   "images" and "metadataApi", so bindings are not slug-restricted. ---- *)
module Binding_name = struct
  type t = string
  let label = "binding"
  let is_ident_start c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
  let is_ident_char c = is_ident_start c || (c >= '0' && c <= '9')
  let of_string s =
    let len = String.length s in
    if len = 0 then Error (Error.Validation.make ~field:label "empty")
    else if len > 63 then Error (Error.Validation.make ~field:label (Printf.sprintf "length %d > 63" len))
    else if not (is_ident_start s.[0]) then
      Error (Error.Validation.make ~field:label "must start with a letter or _")
    else begin
      let bad = ref None in
      (try String.iter (fun c -> if not (is_ident_char c) then (bad := Some c; raise Exit)) s
       with Exit -> ());
      match !bad with
      | Some c -> Error (Error.Validation.make ~field:label
          (Printf.sprintf "illegal character %C (allowed: a-zA-Z0-9 _)" c))
      | None -> Ok s
    end
  let of_string_exn s = match of_string s with Ok v -> v | Error e -> failwith (Error.Validation.to_string e)
  let to_string t = t
  let compare a b = String.compare a b
  let equal a b = String.equal a b
  let hash t = Hashtbl.hash t
end

(* ---- Digest: lowercase hex SHA-256 (64 chars) ---- *)
module Digest = struct
  type t = string  (* 64 lowercase hex chars *)
  let label = "digest"
  let is_hex c =
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
  let of_string s =
    if String.length s <> 64 then
      Error (Error.Validation.make ~field:"digest" "must be 64 hex chars")
    else begin
      let bad = ref None in
      (try String.iter (fun c -> if not (is_hex c) then (bad := Some c; raise Exit)) s
       with Exit -> ());
      match !bad with
      | Some c -> Error (Error.Validation.make ~field:"digest"
          (Printf.sprintf "non-hex character %C" c))
      | None -> Ok s
    end
  let to_string t = t
  let compare a b = String.compare a b
  let equal a b = String.equal a b
  (* Constant-time equality for digest comparison (§10.4). *)
  let constant_time_equal a b =
    if String.length a <> String.length b then false
    else begin
      let acc = ref 0 in
      for i = 0 to String.length a - 1 do
        acc := !acc lor (Char.code a.[i] lxor Char.code b.[i])
      done;
      !acc = 0
    end
end

(* ---- Key_prefix: validated KV namespace prefix.
   Allows lowercase alnum, '/', '-' and a trailing slash. Must not contain
   '..' or empty segments. ASCII-only (§11.2). ---- *)
module Key_prefix = struct
  type t = string
  let label = "prefix"
  let is_seg_char c = is_alnum c || is_hyphen c || c = '/' || c = '_'
  let of_string s =
    let len = String.length s in
    if len = 0 then Ok ""   (* empty prefix = root namespace *)
    else if len > 255 then
      Error (Error.Validation.make ~field:"prefix" "too long (>255)")
    else begin
      let bad = ref None in
      (try String.iter (fun c -> if not (is_seg_char c) then (bad := Some c; raise Exit)) s
       with Exit -> ());
      match !bad with
      | Some c -> Error (Error.Validation.make ~field:"prefix"
          (Printf.sprintf "illegal character %C" c))
      | None ->
          (* reject empty segments (except a single trailing slash) and '..'/'.' *)
          let segs = String.split_on_char '/' s in
          (* drop a single trailing empty segment caused by a trailing slash *)
          let segs =
            match List.rev segs with
            | "" :: (_ :: _ as rest) -> List.rev rest
            | _ -> segs
          in
          let has_bad = List.exists (fun seg -> seg = "" || seg = ".." || seg = ".") segs in
          if has_bad then
            Error (Error.Validation.make ~field:"prefix" "empty/./.. segment")
          else Ok s
    end
  let to_string t = t
  let compare a b = String.compare a b
  let equal a b = String.equal a b
end

(* ---- Module_path: normalized bundle-relative ECMAScript module path.
   §10.4: reject NUL, empty, absolute, backslash, '.' and '..' segments;
   reject duplicate normalized paths. v1 allows './' and '../' imports (§10.5)
   that normalize within the bundle root, plus 'cap:' virtual modules. Here we
   validate the stored normalized form: a non-empty relative path with no
   leading '/', no backslash, no '.' or '..' segments, ending in a known
   module extension, ASCII-only. ---- *)
module Module_path = struct
  type t = string
  let label = "path"
  let is_path_char c =
    is_alnum c || is_hyphen c || c = '_' || c = '/' || c = '.' || c = ':'
  let of_string s =
    let len = String.length s in
    if len = 0 then Error (Error.Validation.make ~field:"path" "empty")
    else if s.[0] = '/' then Error (Error.Validation.make ~field:"path" "absolute path rejected")
    else begin
      let bad = ref None in
      (try String.iter (fun c ->
           if c = '\\' then (bad := Some '\\'; raise Exit)
           else if not (is_path_char c) then (bad := Some c; raise Exit)) s
       with Exit -> ());
      match !bad with
      | Some c -> Error (Error.Validation.make ~field:"path"
          (Printf.sprintf "illegal character %C" c))
      | None ->
          let segs = String.split_on_char '/' s in
          let has_dotdot = List.exists (fun seg -> seg = ".." || seg = ".") segs in
          if has_dotdot then
            Error (Error.Validation.make ~field:"path" "'.' or '..' segment rejected")
          else begin
            (* 'cap:' virtual modules skip the extension requirement. *)
            let is_cap = String.length s >= 4 && String.sub s 0 4 = "cap:" in
            let ends_ok = is_cap
              || (len >= 3 && (String.sub s (len - 3) 3 = ".js"
                  || String.sub s (len - 4) 4 = ".mjs")) in
            if not ends_ok then
              Error (Error.Validation.make ~field:"path" "module must end in .js/.mjs (or be cap:)")
            else Ok s
          end
    end
  let to_string t = t
  let compare a b = String.compare a b
  let equal a b = String.equal a b
end

(* ---- Revision_id is a digest. ---- *)
module Revision_id = Digest
