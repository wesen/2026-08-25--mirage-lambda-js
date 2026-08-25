(* Deterministic bundle parser/writer for the MLB1 format (§10.4).
   Parser requirements: reject lengths exceeding the buffer; reject
   multiplication/addition overflow; reject NUL/empty/absolute/backslash and
   '.'/'..' path segments; ASCII paths; reject duplicate normalized paths;
   cap module count, per-module size, and total source size; require modules
   sorted by path; constant-time digest compare; retain no unvalidated pointer
   into the request buffer (§10.4, §35.3). *)

open Ids
let (let*) = Result.bind
let v ~field = Error.Validation.make ~field
let invalid msg = Error.make ~code:Error.Invalid_request ~failure_class:Error.Package_error msg
let validation_err (x : Error.Validation.t) =
  Error.make ~code:Error.Invalid_manifest ~failure_class:Error.Package_error (Error.Validation.to_string x)

(* ---- Pure-OCaml SHA-256 (no external dependency; common/ stays pure). ---- *)
module Sha256 = struct
  let k = [|
    0x428a2f98l; 0x71374491l; 0xb5c0fbcfl; 0xe9b5dba5l; 0x3956c25bl; 0x59f111f1l;
    0x923f82a4l; 0xab1c5ed5l; 0xd807aa98l; 0x12835b01l; 0x243185bel; 0x550c7dc3l;
    0x72be5d74l; 0x80deb1fel; 0x9bdc06a7l; 0xc19bf174l; 0xe49b69c1l; 0xefbe4786l;
    0x0fc19dc6l; 0x240ca1ccl; 0x2de92c6fl; 0x4a7484aal; 0x5cb0a9dcl; 0x76f988dal;
    0x983e5152l; 0xa831c66dl; 0xb00327c8l; 0xbf597fc7l; 0xc6e00bf3l; 0xd5a79147l;
    0x06ca6351l; 0x14292967l; 0x27b70a85l; 0x2e1b2138l; 0x4d2c6dfcl; 0x53380d13l;
    0x650a7354l; 0x766a0abbl; 0x81c2c92el; 0x92722c85l; 0xa2bfe8a1l; 0xa81a664bl;
    0xc24b8b70l; 0xc76c51a3l; 0xd192e819l; 0xd6990624l; 0xf40e3585l; 0x106aa070l;
    0x19a4c116l; 0x1e376c08l; 0x2748774cl; 0x34b0bcb5l; 0x391c0cb3l; 0x4ed8aa4al;
    0x5b9cca4fl; 0x682e6ff3l; 0x748f82eel; 0x78a5636fl; 0x84c87814l; 0x8cc70208l;
    0x90befffal; 0xa4506cebl; 0xbef9a3f7l; 0xc67178f2l |]

  let rotr n x = Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))
  let shr n x = Int32.shift_right_logical x n
  let s0 x = Int32.logxor (rotr 7 x) (Int32.logxor (rotr 18 x) (shr 3 x))
  let s1 x = Int32.logxor (rotr 17 x) (Int32.logxor (rotr 19 x) (shr 10 x))
  let big0 x = Int32.logxor (rotr 2 x) (Int32.logxor (rotr 13 x) (rotr 22 x))
  let big1 x = Int32.logxor (rotr 6 x) (Int32.logxor (rotr 11 x) (rotr 25 x))
  let ch x y z = Int32.logxor (Int32.logand x y) (Int32.logand (Int32.lognot x) z)
  let maj x y z = Int32.logxor (Int32.logand x y) (Int32.logxor (Int32.logand x z) (Int32.logand y z))

  let be32 b off =
    let open Int32 in
    logor (shift_left (of_int (Char.code b.[off])) 24)
      (logor (shift_left (of_int (Char.code b.[off+1])) 16)
        (logor (shift_left (of_int (Char.code b.[off+2])) 8)
           (of_int (Char.code b.[off+3]))))

  let word_bytes x =
    Bytes.create 4 |> fun b ->
    Bytes.set_uint8 b 0 (Int32.to_int (Int32.shift_right_logical x 24));
    Bytes.set_uint8 b 1 (Int32.to_int (Int32.shift_right_logical x 16) land 0xff);
    Bytes.set_uint8 b 2 (Int32.to_int (Int32.shift_right_logical x 8) land 0xff);
    Bytes.set_uint8 b 3 (Int32.to_int x land 0xff);
    Bytes.to_string b

  let hash (msg : string) : string =
    let ml = String.length msg in
    (* padding: 0x80, zeros, 64-bit BE length in bits *)
    let bitlen = Int64.mul (Int64.of_int ml) 8L in
    let pad_len = (let r = (ml + 1 + 8) mod 64 in if r = 0 then 0 else 64 - r) in
    let total = ml + 1 + pad_len + 8 in
    let buf = Bytes.make total '\000' in
    Bytes.blit_string msg 0 buf 0 ml;
    Bytes.set buf ml '\x80';
    (* 64-bit BE length (we only use low 64 bits; high 32 are zero for <512MB) *)
    let high = Int64.to_int (Int64.shift_right_logical bitlen 32) in
    let low = Int64.to_int bitlen in
    Bytes.set_uint8 buf (total - 8) ((high lsr 24) land 0xff);
    Bytes.set_uint8 buf (total - 7) ((high lsr 16) land 0xff);
    Bytes.set_uint8 buf (total - 6) ((high lsr 8) land 0xff);
    Bytes.set_uint8 buf (total - 5) (high land 0xff);
    Bytes.set_uint8 buf (total - 4) ((low lsr 24) land 0xff);
    Bytes.set_uint8 buf (total - 3) ((low lsr 16) land 0xff);
    Bytes.set_uint8 buf (total - 2) ((low lsr 8) land 0xff);
    Bytes.set_uint8 buf (total - 1) (low land 0xff);
    let s = Bytes.to_string buf in
    let h = [|0x6a09e667l; 0xbb67ae85l; 0x3c6ef372l; 0xa54ff53al;
              0x510e527fl; 0x9b05688cl; 0x1f83d9abl; 0x5be0cd19l|] in
    let w = Array.make 64 0l in
    for chunk = 0 to (total / 64) - 1 do
      let base = chunk * 64 in
      for i = 0 to 15 do w.(i) <- be32 s (base + i*4) done;
      for i = 16 to 63 do
        w.(i) <- Int32.add (s1 w.(i-2)) (Int32.add w.(i-7) (Int32.add (s0 w.(i-15)) w.(i-16)))
      done;
      let a = ref h.(0) and b' = ref h.(1) and c = ref h.(2) and d = ref h.(3) in
      let e = ref h.(4) and f = ref h.(5) and g = ref h.(6) and hh = ref h.(7) in
      for i = 0 to 63 do
        let t1 = Int32.add !hh (Int32.add (big1 !e)
                      (Int32.add (ch !e !f !g) (Int32.add k.(i) w.(i)))) in
        let t2 = Int32.add (big0 !a) (maj !a !b' !c) in
        hh := !g; g := !f; f := !e; e := Int32.add !d t1;
        d := !c; c := !b'; b' := !a; a := Int32.add t1 t2
      done;
      h.(0) <- Int32.add h.(0) !a; h.(1) <- Int32.add h.(1) !b';
      h.(2) <- Int32.add h.(2) !c; h.(3) <- Int32.add h.(3) !d;
      h.(4) <- Int32.add h.(4) !e; h.(5) <- Int32.add h.(5) !f;
      h.(6) <- Int32.add h.(6) !g; h.(7) <- Int32.add h.(7) !hh
    done;
    let out = Buffer.create 32 in
    Array.iter (fun x -> Buffer.add_string out (word_bytes x)) h;
    Buffer.contents out

  let to_hex (raw : string) : string =
    let buf = Buffer.create 64 in
    String.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) raw;
    Buffer.contents buf
end

let digest_of_content content = Sha256.hash content
let digest_hex raw = Sha256.to_hex raw

(* Constant-time equality on raw byte strings (§10.4). *)
let ct_eq_bytes a b =
  if String.length a <> String.length b then false
  else begin
    let acc = ref 0 in
    for i = 0 to String.length a - 1 do
      acc := !acc lor (Char.code a.[i] lxor Char.code b.[i])
    done;
    !acc = 0
  end

(* ---- BE integer readers with bounds checks ---- *)
let read_u32 s off =
  if off < 0 || off + 4 > String.length s then Error (invalid "u32 out of range")
  else
    let v = Char.code s.[off] lsl 24 lor (Char.code s.[off+1] lsl 16)
        lor (Char.code s.[off+2] lsl 8) lor (Char.code s.[off+3]) in
    Ok v

let read_u16 s off =
  if off < 0 || off + 2 > String.length s then Error (invalid "u16 out of range")
  else Ok ((Char.code s.[off] lsl 8) lor (Char.code s.[off+1]))

(* ---- module entry ---- *)
type module_entry = {
  path : Module_path.t;
  content : string;
  digest : string;  (* 32 raw bytes *)
}

(* ---- validated bundle ---- *)
module Validated = struct
  type t = {
    header_json : Canonical_json.t;
    manifest : Manifest.t;
    manifest_json : Canonical_json.t;
    modules : module_entry list;     (* sorted by path *)
    footer_digest : string;          (* 32 raw bytes, over all preceding bytes *)
    raw : string;                    (* the full canonical buffer *)
  }
  let header t = t.header_json
  let manifest t = t.manifest
  let manifest_json t = t.manifest_json
  let modules t = t.modules
  let footer_digest t = t.footer_digest
  let raw t = t.raw
end

(* hard caps (§10.4); tune per tenant policy later *)
let max_module_count = 4096
let max_module_bytes = 16 * 1024 * 1024
let max_total_bytes = 64 * 1024 * 1024

let magic = "MLB1"

(* ---- parser ---- *)
let parse s =
  let len = String.length s in
  if len < 16 then Error (invalid "bundle too short for header") else
  if String.sub s 0 4 <> magic then Error (invalid "bad magic (not MLB1)") else
  let off = ref 4 in
  let* header_length = read_u32 s !off in off := !off + 4;
  let* manifest_length = read_u32 s !off in off := !off + 4;
  let* module_count = read_u32 s !off in off := !off + 4;
  (* overflow checks (§10.4) *)
  if header_length < 0 || manifest_length < 0 || module_count < 0 then
    Error (invalid "negative length")
  else if module_count > max_module_count then
    Error (invalid (Printf.sprintf "module count %d > %d" module_count max_module_count))
  else if Int64.add (Int64.of_int !off) (Int64.of_int header_length) > Int64.of_int len then
    Error (invalid "header length exceeds buffer")
  else begin
    let header_bytes = String.sub s !off header_length in
    off := !off + header_length;
    if Int64.add (Int64.of_int !off) (Int64.of_int manifest_length) > Int64.of_int len then
      Error (invalid "manifest length exceeds buffer")
    else begin
      let manifest_bytes = String.sub s !off manifest_length in
      off := !off + manifest_length;
      (* parse canonical JSON header + manifest (parse errors -> Error) *)
      let header_yo =
        try Ok (Yojson.Safe.from_string header_bytes)
        with Yojson.Json_error m -> Error (invalid ("header json: " ^ m)) in
      let* header_yo = header_yo in
      let* header_cj = Result.map_error invalid (Canonical_json.of_yojson header_yo) in
      let manifest_yo =
        try Ok (Yojson.Safe.from_string manifest_bytes)
        with Yojson.Json_error m -> Error (invalid ("manifest json: " ^ m)) in
      let* manifest_yo = manifest_yo in
      let* manifest_v = Result.map_error validation_err (Manifest.parse manifest_yo) in
      let* manifest_cj = Result.map_error invalid (Canonical_json.of_yojson manifest_yo) in
      (* read modules, enforcing sort order + uniqueness + size caps *)
      let rec read_modules acc n =
        if n = 0 then Ok (List.rev acc)
        else begin
          let* path_len = read_u16 s !off in
          let () = off := !off + 2 in
          if path_len <= 0 || path_len > 1024 then Error (invalid "path length out of range")
          else if Int64.add (Int64.of_int !off) (Int64.of_int path_len) > Int64.of_int len then
            Error (invalid "path exceeds buffer")
          else begin
            let path_bytes = String.sub s !off path_len in
            let () = off := !off + path_len in
            let* path = Result.map_error validation_err (Module_path.of_string path_bytes) in
            let* content_len = read_u32 s !off in
            let () = off := !off + 4 in
            if content_len < 0 || content_len > max_module_bytes then
              Error (invalid "content length out of range")
            else if Int64.add (Int64.of_int !off) (Int64.of_int 32) > Int64.of_int len then
              Error (invalid "digest exceeds buffer")
            else begin
              let digest = String.sub s !off 32 in
              let () = off := !off + 32 in
              if Int64.add (Int64.of_int !off) (Int64.of_int content_len) > Int64.of_int len then
                Error (invalid "content exceeds buffer")
              else begin
                let content = String.sub s !off content_len in
                let () = off := !off + content_len in
                (* verify digest (§10.4 step 7) *)
                let computed = Sha256.hash content in
                if not (ct_eq_bytes digest computed) then
                  Error (invalid "module digest mismatch")
                else begin
                  let entry = { path; content; digest } in
                  (* enforce sort order (canonical) + uniqueness *)
                  match acc with
                  | prev :: _ ->
                      if Module_path.compare prev.path entry.path >= 0 then
                        Error (invalid "modules not sorted by path / duplicate path")
                      else read_modules (entry :: acc) (n - 1)
                  | [] -> read_modules (entry :: acc) (n - 1)
                end
              end
            end
          end
        end
      in
      let* mods = read_modules [] module_count in
      (* total size cap *)
      let total = List.fold_left (fun a m -> a + String.length m.content) 0 mods in
      if total > max_total_bytes then Error (invalid "total source size exceeds cap")
      else if !off + 32 <> len then Error (invalid "footer not at end of buffer")
      else begin
        let footer = String.sub s !off 32 in
        let computed_footer = Sha256.hash (String.sub s 0 !off) in
        if not (ct_eq_bytes footer computed_footer) then
          Error (invalid "footer digest mismatch")
        else
          Ok (Validated.{ header_json = header_cj; manifest = manifest_v; manifest_json = manifest_cj;
                          modules = mods; footer_digest = footer; raw = s })
      end
    end
  end

(* ---- writer ---- *)
let be32 n =
  let b = Bytes.create 4 in
  Bytes.set_uint8 b 0 ((n lsr 24) land 0xff);
  Bytes.set_uint8 b 1 ((n lsr 16) land 0xff);
  Bytes.set_uint8 b 2 ((n lsr 8) land 0xff);
  Bytes.set_uint8 b 3 (n land 0xff);
  Bytes.to_string b

let be16 n =
  let b = Bytes.create 2 in
  Bytes.set_uint8 b 0 ((n lsr 8) land 0xff);
  Bytes.set_uint8 b 1 (n land 0xff);
  Bytes.to_string b

(* [write] takes pre-validated, sorted modules and canonical header/manifest
   JSON strings. It recomputes digests and the footer. *)
let write
    ~header_json:(header : Canonical_json.t)
    ~manifest:(manifest : Manifest.t)
    ~manifest_json:(manifest_cj : Canonical_json.t)
    ~modules:(mods : module_entry list) : string =
  let sorted = List.sort (fun a b -> Module_path.compare a.path b.path) mods in
  let header_str = Canonical_json.to_string header in
  let manifest_str = Canonical_json.to_string manifest_cj in
  let buf = Buffer.create 4096 in
  Buffer.add_string buf magic;
  Buffer.add_string buf (be32 (String.length header_str));
  Buffer.add_string buf (be32 (String.length manifest_str));
  Buffer.add_string buf (be32 (List.length sorted));
  Buffer.add_string buf header_str;
  Buffer.add_string buf manifest_str;
  List.iter (fun m ->
    let path_s = Module_path.to_string m.path in
    Buffer.add_string buf (be16 (String.length path_s));
    Buffer.add_string buf path_s;
    Buffer.add_string buf (be32 (String.length m.content));
    let d = Sha256.hash m.content in
    Buffer.add_string buf d;
    Buffer.add_string buf m.content) sorted;
  let so_far = Buffer.contents buf in
  let footer = Sha256.hash so_far in
  Buffer.add_string buf footer;
  Buffer.contents buf
