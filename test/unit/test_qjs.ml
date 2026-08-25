(* Unit tests for the QuickJS wrapper's pure pieces: module loader
   normalization (§10.5). The engine FFI is gated on QuickJS vendor and is
   exercised in Phase 2's real run. *)

open Ids

let normalize = Qjs_module_loader.normalize

let of_path s =
  match Module_path.of_string s with
  | Ok t -> t
  | Error e -> Alcotest.fail (Error.Validation.to_string e)

let test_normalize_relative () =
  let base = of_path "lib/util/index.js" in
  let ok s expected =
    match normalize ~base s with
    | Ok p -> Alcotest.(check string) s expected (Module_path.to_string p)
    | Error e -> Alcotest.fail (Printf.sprintf "%s rejected: %s" s (Error.Validation.to_string e))
  in
  ok "./helper.js" "lib/util/helper.js";
  ok "../helper.js" "lib/helper.js";
  ok "../../helper.js" "helper.js";
  ok "./sub/deep.js" "lib/util/sub/deep.js"

let test_normalize_rejects () =
  let base = of_path "index.js" in
  let reject s =
    match normalize ~base s with
    | Ok _ -> Alcotest.fail ("should reject: " ^ s)
    | Error _ -> ()
  in
  reject "../../escape.js";
  reject "bare-import";
  reject "/abs.js"

let test_normalize_cap () =
  let base = of_path "index.js" in
  (match normalize ~base "cap:runtime" with
   | Ok p -> Alcotest.(check string) "cap:runtime" "cap:runtime" (Module_path.to_string p)
   | Error e -> Alcotest.fail ("cap: rejected: " ^ Error.Validation.to_string e));
  (match normalize ~base "cap:bad path" with
   | Ok _ -> Alcotest.fail "bad cap accepted"
   | Error _ -> ())

let test_resolve () =
  let base = of_path "index.js" in
  let modules = [
    (of_path "index.js", "index-content");
    (of_path "lib/helper.js", "helper-content");
  ] in
  (match Qjs_module_loader.resolve ~modules ~base "./lib/helper.js" with
   | Ok c -> Alcotest.(check string) "resolve" "helper-content" c
   | Error e -> Alcotest.fail (Error.Validation.to_string e));
  (match Qjs_module_loader.resolve ~modules ~base "./missing.js" with
   | Ok _ -> Alcotest.fail "missing resolved"
   | Error _ -> ())

let tests = [
  "module_loader", [
    Alcotest.test_case "normalize relative" `Quick test_normalize_relative;
    Alcotest.test_case "normalize rejects" `Quick test_normalize_rejects;
    Alcotest.test_case "normalize cap" `Quick test_normalize_cap;
    Alcotest.test_case "resolve" `Quick test_resolve;
  ];
]

let () = Alcotest.run "qjs" tests
