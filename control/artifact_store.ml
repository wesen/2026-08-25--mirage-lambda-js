(* control/artifact_store.ml — content-addressed artifact store (§20.3).
   Phase 4 Unix implementation: a Unix-directory store keyed by SHA-256 digest.
   The implementation recomputes the digest when ingesting from an untrusted
   transport (§20.3). put_if_absent is the only write path; the store never
   overwrites an existing object (content addressing implies immutability). *)

module Y = Yojson.Safe

type t = {
  root : string;     (* directory root, e.g. ~/.mirage-lambda/objects *)
}

let ensure_dir dir =
  (* recursively create the directory (like mkdir -p) *)
  let rec mk d =
    if not (Sys.file_exists d) then begin
      mk (Filename.dirname d);
      (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end in
  mk dir

let make ~root = ensure_dir root; { root }

(* The two-character prefix directory avoids putting millions of files in one
   directory; the guide's §11.2 layout is /objects/sha256/<hex>/bundle.mlb. *)
let path_for t digest_hex =
  let prefix = String.sub digest_hex 0 2 in
  let dir = Filename.concat (Filename.concat t.root prefix) digest_hex in
  Filename.concat dir "bundle.mlb"

let meta_path_for t digest_hex =
  let prefix = String.sub digest_hex 0 2 in
  let dir = Filename.concat (Filename.concat t.root prefix) digest_hex in
  Filename.concat dir "metadata.json"

let put_if_absent t ~digest_bytes bytes =
  let digest_hex = Ids.Digest.to_string digest_bytes in
  let path = path_for t digest_hex in
  let dir = Filename.dirname path in
  ensure_dir dir;
  if Sys.file_exists path then Ok `Already_present
  else begin
    (* recompute the digest (§20.3: recomputes on ingest from untrusted transport) *)
    let computed = Bundle.Sha256.to_hex (Bundle.Sha256.hash bytes) in
    if not (Ids.Digest.constant_time_equal digest_bytes (Result.get_ok (Ids.Digest.of_string computed))) then
      Error (Error.make ~code:Error.Invalid_request
        ~failure_class:Error.Package_error "digest mismatch on ingest")
    else begin
      let oc = open_out_bin path in
      output_string oc bytes;
      close_out oc;
      Ok `Created
    end
  end

let get t digest_bytes =
  let digest_hex = Ids.Digest.to_string digest_bytes in
  let path = path_for t digest_hex in
  if not (Sys.file_exists path) then
    Error (Error.make ~code:Error.Not_found ~failure_class:Error.Storage_error "object not found")
  else
    let ic = open_in_bin path in
    let len = in_channel_length ic in
    let buf = Bytes.create len in
    really_input ic buf 0 len;
    close_in ic;
    (* recompute the digest on read (§20.3) *)
    let computed = Bundle.Sha256.to_hex (Bundle.Sha256.hash (Bytes.to_string buf)) in
    if not (Ids.Digest.constant_time_equal digest_bytes (Result.get_ok (Ids.Digest.of_string computed))) then
      Error (Error.make ~code:Error.Internal ~failure_class:Error.Storage_error
        "digest mismatch on read (corrupt object)")
    else
      Ok (Bytes.to_string buf)

let exists t digest_bytes =
  Sys.file_exists (path_for t (Ids.Digest.to_string digest_bytes))

let delete t digest_bytes =
  let digest_hex = Ids.Digest.to_string digest_bytes in
  let dir = Filename.concat (Filename.concat t.root (String.sub digest_hex 0 2)) digest_hex in
  if Sys.file_exists dir then begin
    (* remove the bundle + metadata, then the dir *)
    let bundle = Filename.concat dir "bundle.mlb" in
    let meta = Filename.concat dir "metadata.json" in
    (try Sys.remove bundle with Sys_error _ -> ());
    (try Sys.remove meta with Sys_error _ -> ());
    (try Unix.rmdir dir with Unix.Unix_error _ -> ());
    Ok ()
  end else Ok ()
