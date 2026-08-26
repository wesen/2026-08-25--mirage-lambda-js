(* cli/main.ml — developer CLI for the Mirage Lambda Service (§38.1).
   Commands: bundle, deploy, invoke, alias. The CLI talks to the
   single-appliance control plane over HTTP (via curl for Phase 4 simplicity). *)

(* ---- helpers ---- *)
let read_file path =
  let ic = open_in path in
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  close_in ic;
  Bytes.to_string buf

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let http_post ~url ~token ~body ~content_type =
  let tmp = Filename.temp_file "mlcli" ".json" in
  let body_file = Filename.temp_file "mlcli" ".body" in
  write_file body_file body;
  let cmd = Printf.sprintf "curl -s -X POST -H 'Authorization: Bearer %s' -H 'Content-Type: %s' --data-binary @%s %s -o %s"
    token content_type body_file url tmp in
  ignore (Sys.command cmd);
  Sys.remove body_file;
  let result = (try read_file tmp with Sys_error _ -> "") in
  (try Sys.remove tmp with Sys_error _ -> ());
  result

let http_put ~url ~token ~body =
  let tmp = Filename.temp_file "mlcli" ".json" in
  let body_file = Filename.temp_file "mlcli" ".body" in
  write_file body_file body;
  let cmd = Printf.sprintf "curl -s -X PUT -H 'Authorization: Bearer %s' -H 'Content-Type: application/json' --data-binary @%s %s -o %s"
    token body_file url tmp in
  ignore (Sys.command cmd);
  Sys.remove body_file;
  let result = (try read_file tmp with Sys_error _ -> "") in
  (try Sys.remove tmp with Sys_error _ -> ());
  result

(* ---- bundle: build an MLB1 bundle from a manifest + source files ---- *)
let do_bundle manifest_path inputs output =
  let manifest_bytes = read_file manifest_path in
  let manifest = Result.get_ok (Manifest.parse_string manifest_bytes) in
  let manifest_cj = Result.get_ok (Canonical_json.of_yojson (Yojson.Safe.from_string manifest_bytes)) in
  let header_cj = Canonical_json.Object [("schemaVersion", Canonical_json.Int 1L)] in
  let modules = List.map (fun path ->
    let content = read_file path in
    let mpath = Result.get_ok (Ids.Module_path.of_string (Filename.basename path)) in
    { Bundle.path = mpath; content; digest = Bundle.Sha256.hash content }) inputs in
  let buf = Bundle.write ~header_json:header_cj ~manifest ~manifest_json:manifest_cj ~modules in
  write_file output buf;
  Printf.printf "bundle: %s (%d bytes, %d modules)\n" output (String.length buf) (List.length modules)

(* ---- deploy: upload a bundle to the control plane ---- *)
let do_deploy bundle_path ~tenant ~function_name ~host ~token =
  let body = read_file bundle_path in
  let url = Printf.sprintf "%s/v1/tenants/%s/functions/%s/versions" host tenant function_name in
  Printf.printf "%s\n" (http_post ~url ~token ~body ~content_type:"application/octet-stream")

(* ---- invoke: invoke a function synchronously or async ---- *)
let do_invoke ~tenant ~function_name ~qualifier ~event ~host ~token ~async =
  let event = if String.length event > 0 && event.[0] = '@' then read_file (String.sub event 1 (String.length event - 1)) else event in
  let path = if async then "invoke-async" else "invoke" in
  let url = Printf.sprintf "%s/v1/%s/%s/%s/%s" host path tenant function_name qualifier in
  Printf.printf "%s\n" (http_post ~url ~token ~body:event ~content_type:"application/json")

(* ---- alias: point an alias at a revision ---- *)
let do_alias ~tenant ~function_name ~alias ~revision ~host ~token =
  let body = Printf.sprintf "{\"revision\":%S}" revision in
  let url = Printf.sprintf "%s/v1/tenants/%s/functions/%s/aliases/%s" host tenant function_name alias in
  Printf.printf "%s\n" (http_put ~url ~token ~body)

(* ---- arg parsing helpers ---- *)
let parse_bundle_args rest =
  let rec loop inputs output = function
    | [] -> (List.rev inputs, output)
    | "-o" :: o :: t -> loop inputs o t
    | x :: t -> loop (x :: inputs) output t in
  loop [] "function.mlb" rest

let parse_deploy_args rest =
  let rec loop tenant fn host token = function
    | [] -> (tenant, fn, host, token)
    | "-t" :: t :: r -> loop t fn host token r
    | "-f" :: f :: r -> loop tenant f host token r
    | "-h" :: h :: r -> loop tenant fn h token r
    | "-k" :: k :: r -> loop tenant fn host k r
    | _ :: r -> loop tenant fn host token r in
  loop "default" "function" "http://127.0.0.1:8080" "dev-token" rest

let parse_invoke_args rest =
  let rec loop event host token async = function
    | [] -> (event, host, token, async)
    | "-e" :: e :: r -> loop e host token async r
    | "-h" :: h :: r -> loop event h token async r
    | "-k" :: k :: r -> loop event host k async r
    | "--async" :: r -> loop event host token true r
    | _ :: r -> loop event host token async r in
  loop "{}" "http://127.0.0.1:8080" "dev-token" false rest

let parse_host_token rest =
  let rec loop host token = function
    | [] -> (host, token)
    | "-h" :: h :: r -> loop h token r
    | "-k" :: k :: r -> loop host k r
    | _ :: r -> loop host token r in
  loop "http://127.0.0.1:8080" "dev-token" rest

(* ---- main ---- *)
let () =
  match Sys.argv |> Array.to_list |> List.tl with
  | "bundle" :: manifest :: rest ->
      let inputs, output = parse_bundle_args rest in
      do_bundle manifest inputs output
  | "deploy" :: bundle :: rest ->
      let tenant, fn, host, token = parse_deploy_args rest in
      do_deploy bundle ~tenant ~function_name:fn ~host ~token
  | "invoke" :: tenant :: fn :: qualifier :: rest ->
      let event, host, token, async = parse_invoke_args rest in
      do_invoke ~tenant ~function_name:fn ~qualifier ~event ~host ~token ~async
  | "alias" :: tenant :: fn :: alias :: revision :: rest ->
      let host, token = parse_host_token rest in
      do_alias ~tenant ~function_name:fn ~alias ~revision ~host ~token
  | _ ->
      Printf.eprintf "usage: mirage-lambda-cli <bundle|deploy|invoke|alias> ...\n";
      exit 1
