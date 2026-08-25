(* Unit + property tests for the pure common library (§29.1, §35.3).
   Property tests use a seeded Random loop so they are deterministic and
   dependency-light; fuzzing of the parsers lives in test/fuzz/. *)

let () = Random.self_init ()

let prop ~n ~seed f =
  let rng = Random.State.make [| seed |] in
  for _ = 1 to n do f rng done

(* small helpers *)
let ok x = Alcotest.(check bool "is_ok" true (Result.is_ok x))
let err x = Alcotest.(check bool "is_err" true (Result.is_error x))

(* ============ ids (§35.2) ============ *)
let gen_slug rng =
  let n = 1 + Random.State.int rng 60 in
  let alnum = "abcdefghijklmnopqrstuvwxyz0123456789" in
  let all = "abcdefghijklmnopqrstuvwxyz0123456789-" in
  let first = alnum.[Random.State.int rng (String.length alnum)] in
  let last = alnum.[Random.State.int rng (String.length alnum)] in
  let buf = Buffer.create n in
  Buffer.add_char buf first;
  for _ = 3 to n do Buffer.add_char buf all.[Random.State.int rng (String.length all)] done;
  Buffer.add_char buf last;
  (* the guide forbids hyphen-only-allowed; ensure at least one alnum (always true) *)
  Buffer.contents buf

let test_ids_valid () =
  ok (Ids.Function_name.of_string "thumbnail");
  ok (Ids.Function_name.of_string "resize-helper");
  ok (Ids.Tenant_id.of_string "tenant-a");
  ok (Ids.Alias.of_string "prod")

let test_ids_invalid () =
  err (Ids.Function_name.of_string "");
  err (Ids.Function_name.of_string "UPPER");
  err (Ids.Function_name.of_string "has_underscore");
  err (Ids.Function_name.of_string "has/slash");
  err (Ids.Function_name.of_string ".dotstart");
  err (Ids.Function_name.of_string "-leadhyphen");
  err (Ids.Function_name.of_string "trailhyphen-");
  err (Ids.Function_name.of_string (String.make 64 'a'));
  err (Ids.Function_name.of_string "has space");
  err (Ids.Digest.of_string "not-hex")

let test_ids_roundtrip () =
  prop ~n:2000 ~seed:0xcaffee (fun rng ->
    let s = gen_slug rng in
    match Ids.Function_name.of_string s with
    | Ok t -> Alcotest.(check string) "roundtrip" s (Ids.Function_name.to_string t)
    | Error _ -> Alcotest.fail ("valid slug rejected: " ^ s));
  Alcotest.(check bool) "digest roundtrip" true
    (match Ids.Digest.of_string "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" with
     | Ok d -> Ids.Digest.constant_time_equal d d | Error _ -> false)

let test_digest_cteq () =
  (* constant-time equal is correct on equal and unequal *)
  let a = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" in
  let b = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" in
  let c = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" in
  let da = Result.get_ok (Ids.Digest.of_string a) in
  let db = Result.get_ok (Ids.Digest.of_string b) in
  let dc = Result.get_ok (Ids.Digest.of_string c) in
  Alcotest.(check bool) "eq" true (Ids.Digest.constant_time_equal da db);
  Alcotest.(check bool) "neq" false (Ids.Digest.constant_time_equal da dc)

(* ============ canonical_json (§35.3 determinism) ============ *)
let test_canonical_json_determinism () =
  let a = `Assoc [("b", `Int 2); ("a", `Int 1); ("c", `List [`String "x"])] in
  let b = `Assoc [("a", `Int 1); ("c", `List [`String "x"]); ("b", `Int 2)] in
  let ca = Result.get_ok (Canonical_json.canonicalize a) in
  let cb = Result.get_ok (Canonical_json.canonicalize b) in
  Alcotest.(check string) "sorted keys, same output" ca cb;
  Alcotest.(check string) "expected" "{\"a\":1,\"b\":2,\"c\":[\"x\"]}" ca

(* ============ budget (§5, §35.3 no underflow) ============ *)
let test_budget_limits () =
  let limits = Result.get_ok (Budget.Engine_limits.make
    ~js_heap_bytes:1024 ~native_overhead_bytes:1024 ~stack_bytes:1024
    ~timeout_ms:100 ~cpu_ms:50 ~max_host_calls:2 ~max_pending_promises:2
    ~max_log_bytes:100 ~max_outbound_bytes:100 ~max_redirects:1
    ~max_child_invocations:1 ()) in
  let u = Budget.Usage.zero ~limits in
  Alcotest.(check bool) "take 1" true (Budget.Usage.take_host_call u);
  Alcotest.(check bool) "take 2" true (Budget.Usage.take_host_call u);
  Alcotest.(check bool) "take 3 over limit" false (Budget.Usage.take_host_call u);
  Budget.Usage.release_host_call u;
  Alcotest.(check bool) "take after release" true (Budget.Usage.take_host_call u);
  (* release never underflows: release more than taken leaves 0 *)
  Budget.Usage.release_host_call u; Budget.Usage.release_host_call u;
  Budget.Usage.release_host_call u;
  Alcotest.(check int) "host_calls floor 0" 0 (Budget.Usage.host_calls u);
  (* log bytes overflow *)
  Alcotest.(check bool) "log ok" true (Budget.Usage.add_log_bytes u 60);
  Alcotest.(check bool) "log over" false (Budget.Usage.add_log_bytes u 50);
  Alcotest.(check bool) "log exactly at limit" true (Budget.Usage.add_log_bytes u 40)

let test_budget_negative_rejected () =
  err (Budget.Engine_limits.make ~js_heap_bytes:(-1)
    ~native_overhead_bytes:0 ~stack_bytes:0 ~timeout_ms:0 ~cpu_ms:0
    ~max_host_calls:0 ~max_pending_promises:0 ~max_log_bytes:0
    ~max_outbound_bytes:0 ~max_redirects:0 ~max_child_invocations:0 ())

let test_budget_no_underflow_property () =
  prop ~n:1000 ~seed:0xbad (fun rng ->
    let lim = 1 + Random.State.int rng 8 in
    let limits = Result.get_ok (Budget.Engine_limits.make
      ~js_heap_bytes:0 ~native_overhead_bytes:0 ~stack_bytes:0 ~timeout_ms:0 ~cpu_ms:0
      ~max_host_calls:lim ~max_pending_promises:lim ~max_log_bytes:lim
      ~max_outbound_bytes:lim ~max_redirects:lim ~max_child_invocations:lim ()) in
    let u = Budget.Usage.zero ~limits in
    for _ = 1 to 20 do ignore (Budget.Usage.take_host_call u) done;
    for _ = 1 to 30 do Budget.Usage.release_host_call u done;
    Alcotest.(check bool) "never negative" true (Budget.Usage.host_calls u >= 0))

(* ============ capability (§15, §F.1 intersection invariant) ============ *)
let test_capability_intersection () =
  let store = Result.get_ok (Ids.Store_id.of_string "images") in
  let prefix = Result.get_ok (Ids.Key_prefix.of_string "tenant-a/") in
  let binding = Result.get_ok (Ids.Binding_name.of_string "images") in
  let decls_a = {
    Capability.kv = [{ Capability.binding; store; access = `Read_write; prefix }];
    http = []; clock = `Monotonic; random = `None; logs = true; invoke = [];
  } in
  let decls_b = {
    Capability.kv = [{ Capability.binding; store; access = `Read; prefix }];
    http = []; clock = `Wall; random = `None; logs = false; invoke = [];
  } in
  let pa = Result.get_ok (Capability.compile decls_a) in
  let pb = Result.get_ok (Capability.compile decls_b) in
  let pij = Capability.intersection pa pb in
  (* intersection must grant Kv_get (both have it) but NOT Kv_put (only a) *)
  let get_op = Capability.Kv_get { store; prefix } in
  let put_op = Capability.Kv_put { store; prefix } in
  Alcotest.(check bool) "a has get" true (Capability.grants pa ~binding ~operation:get_op);
  Alcotest.(check bool) "a has put" true (Capability.grants pa ~binding ~operation:put_op);
  Alcotest.(check bool) "b has get" true (Capability.grants pb ~binding ~operation:get_op);
  Alcotest.(check bool) "b lacks put" false (Capability.grants pb ~binding ~operation:put_op);
  Alcotest.(check bool) "intersection has get" true (Capability.grants pij ~binding ~operation:get_op);
  Alcotest.(check bool) "intersection lacks put" false (Capability.grants pij ~binding ~operation:put_op);
  (* intersection grants at most as many bindings as either operand *)
  let na = List.length pa.grants in
  let nb = List.length pb.grants in
  let ni = List.length pij.grants in
  Alcotest.(check bool) "intersection <= a" true (ni <= na);
  Alcotest.(check bool) "intersection <= b" true (ni <= nb)

(* ============ manifest (§10.2, §10.3 strict) ============ *)
let valid_manifest_json =
  {|{
    "schemaVersion": 1,
    "name": "thumbnail",
    "entrypoint": "index.js",
    "export": "default",
    "runtime": "quickjs-2026-06-04",
    "input": {"format": "json", "maxBytes": 1048576},
    "output": {"format": "json", "maxBytes": 1048576},
    "limits": {
      "jsHeapBytes": 16777216, "nativeOverheadBytes": 4194304,
      "stackBytes": 262144, "timeoutMs": 100, "cpuMs": 50,
      "maxHostCalls": 32, "maxPendingPromises": 16, "maxLogBytes": 32768,
      "maxOutboundBytes": 262144, "maxRedirects": 2, "maxChildInvocations": 4
    },
    "capabilities": {
      "kv": [{"binding":"images","store":"images","access":"read-write","prefix":"tenant-a/"}],
      "http": [{"binding":"metadataApi","schemes":["https"],"hosts":["api.example.com"],"ports":[443],"methods":["GET"],"maxResponseBytes":131072}],
      "clock": "monotonic",
      "random": "cryptographic",
      "logs": true,
      "invoke": ["resize-helper@prod"]
    },
    "retry": {"mode": "never"}
  }|}

let test_manifest_valid () =
  let m = Result.get_ok (Manifest.parse_string valid_manifest_json) in
  Alcotest.(check string) "name" "thumbnail" (Ids.Function_name.to_string (Manifest.name m));
  Alcotest.(check string) "entrypoint" "index.js" (Ids.Module_path.to_string (Manifest.entrypoint m));
  Alcotest.(check string) "runtime" "quickjs-2026-06-04" (Manifest.runtime m);
  Alcotest.(check bool) "has kv" true ((Manifest.capabilities m).kv <> []);
  Alcotest.(check bool) "logs" true (Manifest.capabilities m).logs;
  let policy = Result.get_ok (Capability.compile (Manifest.capabilities m)) in
  Alcotest.(check bool) "compiled nonempty" true (policy.grants <> [])

let test_manifest_invalid () =
  let reject s = match Manifest.parse_string s with
    | Ok _ -> Alcotest.fail ("should have been rejected: " ^ s)
    | Error _ -> () in
  reject {|{"schemaVersion":2}|};                          (* wrong version *)
  reject {|{"schemaVersion":1}|};                           (* missing fields *)
  reject {|{"schemaVersion":1,"name":"thumbnail","entrypoint":"index.js","export":"default","runtime":"quickjs-2026-06-04","input":{"format":"json","maxBytes":1},"output":{"format":"json","maxBytes":1},"limits":{"jsHeapBytes":1,"nativeOverheadBytes":1,"stackBytes":1,"timeoutMs":1,"cpuMs":1,"maxHostCalls":1,"maxPendingPromises":1,"maxLogBytes":1,"maxOutboundBytes":1,"maxRedirects":1,"maxChildInvocations":1},"capabilities":{"clock":"monotonic","random":"cryptographic","logs":true},"retry":{"mode":"never"},"extra":1}|}; (* unknown field *)
  (* duplicate field: Yojson preserves duplicates; detected by check_no_duplicates *)
  reject {|{"schemaVersion":1,"schemaVersion":1}|}

(* ============ bundle (§10.4 MLB1 roundtrip + integrity) ============ *)
let test_bundle_roundtrip () =
  let manifest = Result.get_ok (Manifest.parse_string valid_manifest_json) in
  let manifest_yo = Yojson.Safe.from_string valid_manifest_json in
  let manifest_cj = Result.get_ok (Canonical_json.of_yojson manifest_yo) in
  let header_cj = Canonical_json.Object [("schemaVersion", Canonical_json.Int 1L)] in
  let path = Result.get_ok (Ids.Module_path.of_string "index.js") in
  let content = "export default async function main(input, env) { return { answer: input.x + 1 }; }\n" in
  let entry = { Bundle.path; content; digest = Bundle.Sha256.hash content } in
  let buf = Bundle.write ~header_json:header_cj ~manifest ~manifest_json:manifest_cj ~modules:[entry] in
  let parsed = Result.get_ok (Bundle.parse buf) in
  Alcotest.(check int) "one module" 1 (List.length (Bundle.Validated.modules parsed));
  let m0 = List.hd (Bundle.Validated.modules parsed) in
  Alcotest.(check string) "content preserved" content m0.content;
  Alcotest.(check string) "path preserved" "index.js" (Ids.Module_path.to_string m0.path);
  (* footer verified implicitly by parse success *)
  ()

let test_bundle_integrity () =
  let manifest = Result.get_ok (Manifest.parse_string valid_manifest_json) in
  let manifest_yo = Yojson.Safe.from_string valid_manifest_json in
  let manifest_cj = Result.get_ok (Canonical_json.of_yojson manifest_yo) in
  let header_cj = Canonical_json.Object [] in
  let mk path_s content = 
    let path = Result.get_ok (Ids.Module_path.of_string path_s) in
    { Bundle.path; content; digest = Bundle.Sha256.hash content } in
  let mods = [mk "a.js" "a"; mk "b.js" "b"; mk "c.js" "c"] in
  let buf = Bundle.write ~header_json:header_cj ~manifest ~manifest_json:manifest_cj ~modules:mods in
  (* a valid buffer parses *)
  ignore (Result.get_ok (Bundle.parse buf));
  (* truncation rejected *)
  Alcotest.(check bool) "truncated rejected" true
    (match Bundle.parse (String.sub buf 0 (String.length buf / 2)) with Error _ -> true | Ok _ -> false);
  (* a flipped byte in the footer rejected *)
  let bad = Bytes.of_string buf in
  let last = Bytes.length bad - 1 in
  Bytes.set bad last (Char.chr (Char.code (Bytes.get bad last) lxor 1));
  Alcotest.(check bool) "footer tamper rejected" true
    (match Bundle.parse (Bytes.to_string bad) with Error _ -> true | Ok _ -> false);
  (* unsorted modules rejected by the parser (writer sorts, so craft unsorted raw) *)
  let unsorted = [mk "z.js" "z"; mk "a.js" "a"] in
  let buf2 = Bundle.write ~header_json:header_cj ~manifest ~manifest_json:manifest_cj ~modules:unsorted in
  (* writer sorts them, so buf2 is sorted and parses fine *)
  let p2 = Result.get_ok (Bundle.parse buf2) in
  let names = List.map (fun (m : Bundle.module_entry) -> Ids.Module_path.to_string m.path) (Bundle.Validated.modules p2) in
  Alcotest.(check string) "sorted a first" "a.js" (List.hd names)

(* ============ protocol (§14) ============ *)
let test_protocol () =
  Alcotest.(check int) "version 1" 1 Protocol.current_protocol_version;
  let inv_id = Result.get_ok (Protocol.Invocation_id.of_string "inv-12345") in
  let dig = Result.get_ok (Ids.Digest.of_string "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") in
  let ep = Result.get_ok (Ids.Module_path.of_string "index.js") in
  let env_ = Protocol.make_invocation
    ~invocation_id:inv_id ~revision_digest:dig ~entrypoint:ep ~export_name:"default"
    ~event_json:"{}" ~context_json:"{}" ~deadline_ms:1000L ~attempt:1 () in
  Alcotest.(check int) "envelope version" 1 (Protocol.protocol_version_invocation env_);
  Alcotest.(check bool) "bad version rejected" true
    (match Protocol.check_version 2 with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool) "good version ok" true
    (match Protocol.check_version 1 with Ok _ -> true | Error _ -> false)

(* ============ runner ============ *)
let tests = [
  "ids", [
    Alcotest.test_case "valid" `Quick test_ids_valid;
    Alcotest.test_case "invalid" `Quick test_ids_invalid;
    Alcotest.test_case "roundtrip property" `Quick test_ids_roundtrip;
    Alcotest.test_case "digest ct eq" `Quick test_digest_cteq;
  ];
  "canonical_json", [
    Alcotest.test_case "determinism" `Quick test_canonical_json_determinism;
  ];
  "budget", [
    Alcotest.test_case "limits enforced" `Quick test_budget_limits;
    Alcotest.test_case "negative rejected" `Quick test_budget_negative_rejected;
    Alcotest.test_case "no underflow property" `Quick test_budget_no_underflow_property;
  ];
  "capability", [
    Alcotest.test_case "intersection invariant" `Quick test_capability_intersection;
  ];
  "manifest", [
    Alcotest.test_case "valid" `Quick test_manifest_valid;
    Alcotest.test_case "invalid rejected" `Quick test_manifest_invalid;
  ];
  "bundle", [
    Alcotest.test_case "roundtrip" `Quick test_bundle_roundtrip;
    Alcotest.test_case "integrity" `Quick test_bundle_integrity;
  ];
  "protocol", [
    Alcotest.test_case "version + envelope" `Quick test_protocol;
  ];
]

let () = Alcotest.run "common" tests
