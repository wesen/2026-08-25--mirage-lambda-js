(* control/registry.ml — function revision registry (§20.4).
   Phase 4: in-memory registry with checkpoint serialization to a JSON file.
   A revision is immutable; an alias points to a revision with an optional
   compare-and-set precondition (§20.4). The registry resolves
   (tenant, function, qualifier) -> revision. *)

module Y = Yojson.Safe

type revision = {
  digest : Ids.Digest.t;        (* bundle content digest *)
  manifest_json : string;       (* canonical manifest JSON *)
  runtime : string;
  created_at : string;
}

type alias = {
  function_name : Ids.Function_name.t;
  alias_name : Ids.Alias.t;
  revision : Ids.Revision_id.t;
}

type t = {
  mutable revisions : (Ids.Tenant_id.t * Ids.Function_name.t * Ids.Digest.t, revision) Hashtbl.t;
  mutable aliases : (Ids.Tenant_id.t * Ids.Function_name.t * Ids.Alias.t, Ids.Revision_id.t) Hashtbl.t;
  checkpoint_path : string option;
}

let make ?checkpoint_path () = {
  revisions = Hashtbl.create 16;
  aliases = Hashtbl.create 16;
  checkpoint_path;
}

let key tenant fn digest = (tenant, fn, digest)

(* ---- checkpoint serialization (§11) ----
   Defined before use; publish_revision/move_alias call checkpoint_save. *)
let revision_to_json r =
  `Assoc [
    ("digest", `String (Ids.Digest.to_string r.digest));
    ("manifestJson", `String r.manifest_json);
    ("runtime", `String r.runtime);
    ("createdAt", `String r.created_at);
  ]

let revision_of_json = function
  | `Assoc fields ->
      let digest = match List.assoc_opt "digest" fields with Some (`String s) -> s | _ -> "" in
      let manifest_json = match List.assoc_opt "manifestJson" fields with Some (`String s) -> s | _ -> "" in
      let runtime = match List.assoc_opt "runtime" fields with Some (`String s) -> s | _ -> "" in
      let created_at = match List.assoc_opt "createdAt" fields with Some (`String s) -> s | _ -> "" in
      (match Ids.Digest.of_string digest with
       | Ok d -> Ok { digest = d; manifest_json; runtime; created_at }
       | Error _ -> Error "bad digest in checkpoint")
  | _ -> Error "bad revision json"

let checkpoint_save t =
  match t.checkpoint_path with
  | None -> Ok ()
  | Some path ->
      let revs = Hashtbl.fold (fun (tn, fn, _dg) r acc ->
        `Assoc [
          ("tenant", `String (Ids.Tenant_id.to_string tn));
          ("function", `String (Ids.Function_name.to_string fn));
          ("revision", revision_to_json r);
        ] :: acc) t.revisions [] in
      let aliases = Hashtbl.fold (fun (tn, fn, al) rev acc ->
        `Assoc [
          ("tenant", `String (Ids.Tenant_id.to_string tn));
          ("function", `String (Ids.Function_name.to_string fn));
          ("alias", `String (Ids.Alias.to_string al));
          ("revision", `String (Ids.Revision_id.to_string rev));
        ] :: acc) t.aliases [] in
      let json = `Assoc [("revisions", `List revs); ("aliases", `List aliases)] in
      let oc = open_out path in
      output_string oc (Y.pretty_to_string json);
      close_out oc;
      Ok ()

let publish_revision t ~tenant ~function_name ~revision =
  let k = key tenant function_name revision.digest in
  if Hashtbl.mem t.revisions k then
    Error (Error.make ~code:Error.Conflict ~failure_class:Error.Package_error
      "revision already published")
  else begin
    Hashtbl.add t.revisions k revision;
    (* persist to checkpoint if configured *)
    (match t.checkpoint_path with
     | Some _ -> ignore (checkpoint_save t)  (* best-effort *)
     | None -> ());
    Ok ()
  end

let resolve t ~tenant ~function_name ~qualifier =
  (* qualifier is either a digest or an alias *)
  match Ids.Digest.of_string (Ids.Qualifier.to_string qualifier) with
  | Ok digest ->
      (* look up by digest *)
      let found = Hashtbl.fold (fun (tn, fn, dg) rev acc ->
        if Ids.Tenant_id.equal tn tenant && Ids.Function_name.equal fn function_name
           && Ids.Digest.equal dg digest then Some rev else acc)
        t.revisions None in
      (match found with
       | Some rev -> Ok rev.digest   (* Revision_id.t = Digest.t *)
       | None -> Error (Error.make ~code:Error.Not_found ~failure_class:Error.Storage_error
           "revision not found"))
  | Error _ ->
      (* try as an alias *)
      let alias_result = Ids.Alias.of_string (Ids.Qualifier.to_string qualifier) in
      (match alias_result with
       | Error _ -> Error (Error.make ~code:Error.Not_found ~failure_class:Error.Storage_error
           "qualifier is neither a digest nor a known alias")
       | Ok alias ->
           let k = (tenant, function_name, alias) in
           (match Hashtbl.find_opt t.aliases k with
            | Some rev_id -> Ok rev_id
            | None -> Error (Error.make ~code:Error.Not_found ~failure_class:Error.Storage_error
                "alias not found")))

(* §20.4: alias movement with optional compare-and-set precondition *)
let move_alias t ~tenant ~function_name ~alias ~revision ~precondition =
  let k = (tenant, function_name, alias) in
  match Hashtbl.find_opt t.aliases k, precondition with
  | Some current, Some expected when not (Ids.Revision_id.equal current expected) ->
      Error (Error.make ~code:Error.Conflict ~failure_class:Error.Storage_error
        "alias precondition failed (lost update)")
  | _ ->
      Hashtbl.replace t.aliases k revision;
      (match t.checkpoint_path with
       | Some _ -> ignore (checkpoint_save t)
       | None -> ());
      Ok ()

let checkpoint_load path =
  try
    let ic = open_in path in
    let len = in_channel_length ic in
    let buf = Bytes.create len in
    really_input ic buf 0 len;
    close_in ic;
    (match Y.from_string (Bytes.to_string buf) with
     | `Assoc fields ->
         let t = make () in
         (match List.assoc_opt "revisions" fields with
          | Some (`List revs) ->
              List.iter (fun r ->
                match r with
                | `Assoc rf ->
                    let tenant_s = match List.assoc_opt "tenant" rf with Some (`String s) -> s | _ -> "" in
                    let fn_s = match List.assoc_opt "function" rf with Some (`String s) -> s | _ -> "" in
                    (match Ids.Tenant_id.of_string tenant_s, Ids.Function_name.of_string fn_s,
                            List.assoc_opt "revision" rf with
                    | Ok tn, Ok fn, Some rj ->
                        (match revision_of_json rj with
                         | Ok rev -> Hashtbl.add t.revisions (key tn fn rev.digest) rev
                         | Error _ -> ())
                    | _ -> ())
                | _ -> ()) revs
          | _ -> ());
         (match List.assoc_opt "aliases" fields with
          | Some (`List aliases) ->
              List.iter (fun a ->
                match a with
                | `Assoc af ->
                    let tenant_s = match List.assoc_opt "tenant" af with Some (`String s) -> s | _ -> "" in
                    let fn_s = match List.assoc_opt "function" af with Some (`String s) -> s | _ -> "" in
                    let al_s = match List.assoc_opt "alias" af with Some (`String s) -> s | _ -> "" in
                    let rev_s = match List.assoc_opt "revision" af with Some (`String s) -> s | _ -> "" in
                    (match Ids.Tenant_id.of_string tenant_s, Ids.Function_name.of_string fn_s,
                            Ids.Alias.of_string al_s, Ids.Revision_id.of_string rev_s with
                    | Ok tn, Ok fn, Ok al, Ok rev -> Hashtbl.add t.aliases (tn, fn, al) rev
                    | _ -> ())
                | _ -> ()) aliases
          | _ -> ());
         Ok t
     | _ -> Error "bad checkpoint json")
  with Sys_error _ -> Error "checkpoint file not found"
