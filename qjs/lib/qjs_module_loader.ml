(* qjs/lib/qjs_module_loader.ml — custom module loader (§10.5, §24.4).
   The loader reads ONLY from the already-validated in-memory bundle map.
   Version 1 supports relative imports (./, ../) normalized within the bundle
   root, and optional named virtual modules beginning [cap:]. No native .so,
   HTTP, filesystem lookup, or dynamic import. *)

open Ids
let (let*) = Result.bind

(* Normalize a relative import against a base module path, staying within the
   bundle root. Rejects anything that escapes the root (.. past root) or that
   resolves to a non-bundle path. *)
let normalize ~base import =
  let is_rel s = String.length s >= 2 && String.sub s 0 2 = "./" in
  let is_rel_parent s = String.length s >= 3 && String.sub s 0 3 = "../" in
  let is_cap s = String.length s >= 4 && String.sub s 0 4 = "cap:" in
  if is_cap import then (match Module_path.of_string import with Ok _ as ok -> ok | Error _ -> Error (Error.Validation.make ~field:"import" "invalid cap: path"))
  else if not (is_rel import || is_rel_parent import) then
    Error (Error.Validation.make ~field:"import" "only ./, ../, and cap: imports allowed")
  else begin
    (* split base into segments, drop the filename, then apply import segments *)
    let base_segs = String.split_on_char '/' (Module_path.to_string base) in
    let base_dir = match List.rev base_segs with _ :: rest -> List.rev rest | [] -> [] in
    let imp_segs = String.split_on_char '/' import in
    let rec walk acc = function
      | [] -> Ok (List.rev acc)
      | "." :: rest -> walk acc rest
      | ".." :: rest ->
          (match acc with
           | _ :: prev -> walk prev rest
           | [] -> Error (Error.Validation.make ~field:"import" "import escapes bundle root"))
      | seg :: rest -> walk (seg :: acc) rest
    in
    (* Start with the base directory as the accumulator, then apply import segments. *)
    let init_acc = List.rev base_dir in
    match walk init_acc imp_segs with
    | Error e -> Error e
    | Ok [] -> Error (Error.Validation.make ~field:"import" "empty normalized path")
    | Ok segs ->
        let path = String.concat "/" segs in
        let path = if String.length path >= 3 && String.sub path (String.length path - 3) 3 = ".js"
                    then path else path ^ ".js" in
        (match Module_path.of_string path with Ok _ as ok -> ok | Error e -> Error e)
  end

(* Resolve an import to a module in the bundle map. Returns the content. *)
let resolve ~(modules : (Module_path.t * string) list) ~base import =
  let* normalized = normalize ~base import in
  match List.find_opt (fun (p, _) -> Module_path.equal p normalized) modules with
  | Some (_, content) -> Ok content
  | None -> Error (Error.Validation.make
      ~field:"import" (Printf.sprintf "module %S not in bundle" (Module_path.to_string normalized)))
