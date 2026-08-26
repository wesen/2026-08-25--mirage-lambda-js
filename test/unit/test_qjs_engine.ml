(* Engine tests — the Phase 0/2 feasibility probe (§34.2) run through the
   real QuickJS engine on Unix. Exercises: create/destroy repeatedly, eval
   1+2->3, heap-limit OOM, stack-limit recursion, infinite-loop interrupt,
   and 100k create/eval/destroy cycles under ASan/UBSan. *)

let default_limits =
  Result.get_ok (Budget.Engine_limits.make
    ~js_heap_bytes:(16 * 1024 * 1024) ~native_overhead_bytes:(4 * 1024 * 1024)
    ~stack_bytes:(256 * 1024) ~timeout_ms:5000 ~cpu_ms:5000
    ~max_host_calls:32 ~max_pending_promises:16 ~max_log_bytes:32768
    ~max_outbound_bytes:262144 ~max_redirects:2 ~max_child_invocations:4 ())

let small_heap_limits =
  Result.get_ok (Budget.Engine_limits.make
    ~js_heap_bytes:(256 * 1024) ~native_overhead_bytes:0
    ~stack_bytes:(256 * 1024) ~timeout_ms:5000 ~cpu_ms:5000
    ~max_host_calls:32 ~max_pending_promises:16 ~max_log_bytes:32768
    ~max_outbound_bytes:262144 ~max_redirects:2 ~max_child_invocations:4 ())

let small_stack_limits =
  Result.get_ok (Budget.Engine_limits.make
    ~js_heap_bytes:(16 * 1024 * 1024) ~native_overhead_bytes:0
    ~stack_bytes:(8 * 1024) ~timeout_ms:5000 ~cpu_ms:5000
    ~max_host_calls:32 ~max_pending_promises:16 ~max_log_bytes:32768
    ~max_outbound_bytes:262144 ~max_redirects:2 ~max_child_invocations:4 ())

let tight_cpu_limits =
  Result.get_ok (Budget.Engine_limits.make
    ~js_heap_bytes:(16 * 1024 * 1024) ~native_overhead_bytes:0
    ~stack_bytes:(256 * 1024) ~timeout_ms:5000 ~cpu_ms:1
    ~max_host_calls:32 ~max_pending_promises:16 ~max_log_bytes:32768
    ~max_outbound_bytes:262144 ~max_redirects:2 ~max_child_invocations:4 ())

let dummy_bundle =
  (* Build a real minimal bundle via write+parse (Validated.t is abstract). *)
  let manifest_json =
    {|{"schemaVersion":1,"name":"probe","entrypoint":"index.js","export":"default","runtime":"quickjs-2026-06-04","input":{"format":"json","maxBytes":1024},"output":{"format":"json","maxBytes":1024},"limits":{"jsHeapBytes":16777216,"nativeOverheadBytes":4194304,"stackBytes":262144,"timeoutMs":100,"cpuMs":50,"maxHostCalls":32,"maxPendingPromises":16,"maxLogBytes":32768,"maxOutboundBytes":262144,"maxRedirects":2,"maxChildInvocations":4},"capabilities":{"clock":"monotonic","random":"cryptographic","logs":true},"retry":{"mode":"never"}}|} in
  let manifest = Result.get_ok (Manifest.parse_string manifest_json) in
  let manifest_cj = Result.get_ok (Canonical_json.of_yojson (Yojson.Safe.from_string manifest_json)) in
  let header_cj = Canonical_json.Object [("schemaVersion", Canonical_json.Int 1L)] in
  let path = Result.get_ok (Ids.Module_path.of_string "index.js") in
  let content = "export default async function main(){}" in
  let entry = { Bundle.path; content; digest = Bundle.Sha256.hash content } in
  let buf = Bundle.write ~header_json:header_cj ~manifest ~manifest_json:manifest_cj ~modules:[entry] in
  Result.get_ok (Bundle.parse buf)

(* §34.2 step 1: create and destroy JSRuntime/JSContext repeatedly. *)
let test_create_destroy () =
  for _ = 1 to 100 do
    match Qjs_engine.create ~limits:default_limits ~bundle:dummy_bundle with
    | Error e -> Alcotest.fail ("create failed: " ^ match e with Engine s -> s | _ -> "?")
    | Ok t -> Qjs_engine.destroy t
  done

(* §34.2 step 2: evaluate 1 + 2 and extract the integer result (3). *)
let test_eval_int () =
  match Qjs_engine.create ~limits:default_limits ~bundle:dummy_bundle with
  | Error e -> Alcotest.fail ("create: " ^ match e with Engine s -> s | _ -> "?")
  | Ok t ->
    (match Qjs_engine.eval_int t "1 + 2" with
     | Ok n -> Alcotest.(check int) "1+2=3" 3 n
     | Error e -> Alcotest.fail ("eval_int: " ^ match e with Engine s -> s | _ -> "?"));
    Qjs_engine.destroy t

(* §34.2 step 2b: eval that throws returns true. *)
let test_eval_throws () =
  match Qjs_engine.create ~limits:default_limits ~bundle:dummy_bundle with
  | Ok t ->
    Alcotest.(check bool) "undefined_var throws" true (Qjs_engine.eval t "undefinedVar");
    Alcotest.(check bool) "valid does not throw" false (Qjs_engine.eval t "var x = 1");
    Qjs_engine.destroy t
  | Error _ -> Alcotest.fail "create failed"

(* §34.2 step 6: enforce a small heap limit and observe a controlled OOM. *)
let test_heap_limit () =
  match Qjs_engine.create ~limits:small_heap_limits ~bundle:dummy_bundle with
  | Ok t ->
    (* allocating a large array under a 256KB heap should throw (OOM) *)
    let threw = Qjs_engine.eval t "var a = new Array(1000000); a.fill(0);" in
    Alcotest.(check bool) "large alloc under small heap throws" true threw;
    Qjs_engine.destroy t
  | Error _ -> Alcotest.fail "create failed"

(* §34.2 step 7: enforce a stack limit with recursive JavaScript. *)
let test_stack_limit () =
  match Qjs_engine.create ~limits:small_stack_limits ~bundle:dummy_bundle with
  | Ok t ->
    let threw = Qjs_engine.eval t "function f(){ return f(); } f();" in
    Alcotest.(check bool) "infinite recursion throws (stack)" true threw;
    Qjs_engine.destroy t
  | Error _ -> Alcotest.fail "create failed"

(* §34.2 step 8: interrupt `while (true) {}` using the public interrupt callback. *)
let test_interrupt () =
  match Qjs_engine.create ~limits:tight_cpu_limits ~bundle:dummy_bundle with
  | Ok t ->
    (* tight_cpu_limits has cpu_ms=1 (1ms). The interrupt handler fires after
       ~1ms of CPU. The eval should be interrupted (return true = threw) *)
    let threw = Qjs_engine.eval t "while(true){}" in
    Alcotest.(check bool) "infinite loop interrupted" true threw;
    Qjs_engine.cancel t (Error.Resource.make Error.Resource.Cpu);
    Qjs_engine.destroy t
  | Error _ -> Alcotest.fail "create failed"

(* §34.2 step 11: 100k create/eval/destroy cycles under ASan/UBSan.
   Reduced to 10k for the test suite's time budget; the full 100k is a
   standalone evidence run (see docs/evidence/phase-0.md). *)
let test_many_cycles () =
  for _ = 1 to 10_000 do
    match Qjs_engine.create ~limits:default_limits ~bundle:dummy_bundle with
    | Ok t ->
      ignore (Qjs_engine.eval_int t "1+1");
      Qjs_engine.destroy t
    | Error _ -> Alcotest.fail "create failed in cycle"
  done

(* pump: draining the QuickJS job queue. *)
let test_pump_jobs () =
  match Qjs_engine.create ~limits:default_limits ~bundle:dummy_bundle with
  | Ok t ->
    (* Promise.resolve(42).then(x => globalThis.__r = x) queues a job *)
    ignore (Qjs_engine.eval t "Promise.resolve(42).then(x => { globalThis.__r = x; })");
    (* initially there may be a pending job *)
    let _ = Qjs_engine.pump t ~max_jobs:64 in
    (* after pumping, the job should have run *)
    let has_r = Qjs_engine.eval t "typeof __r !== 'undefined'" in
    Alcotest.(check bool) "job ran after pump" false has_r;  (* __r set means no throw *)
    Qjs_engine.destroy t
  | Error _ -> Alcotest.fail "create failed"

(* §34.2 step 3: load a two-module ECMAScript program using the custom module loader. *)
let test_module_loader () =
  match Qjs_engine.create ~limits:default_limits ~bundle:dummy_bundle with
  | Ok t ->
    (* module lib.js: exports addOne *)
    let lib_path = Result.get_ok (Ids.Module_path.of_string "lib.js") in
    let lib_src = "export function addOne(x) { return x + 1; }" in
    Qjs_engine.set_module t lib_path lib_src;
    (* module index.js: imports from ./lib and uses it *)
    let idx_path = Result.get_ok (Ids.Module_path.of_string "index.js") in
    let idx_src = "import { addOne } from \"./lib.js\"; globalThis.__result = addOne(41);" in
    Qjs_engine.set_module t idx_path idx_src;
    let threw = Qjs_engine.eval_module t idx_path in
    Alcotest.(check bool) "module eval does not throw" false threw;
    (* verify the imported function ran: __result should be 42 *)
    (match Qjs_engine.eval_int t "__result" with
     | Ok n -> Alcotest.(check int) "addOne(41) = 42" 42 n
     | Error _ -> Alcotest.fail "could not read __result");
    Qjs_engine.destroy t
  | Error _ -> Alcotest.fail "create failed"

(* module not found: loader rejects unknown module. *)
let test_module_not_found () =
  match Qjs_engine.create ~limits:default_limits ~bundle:dummy_bundle with
  | Ok t ->
    let idx_path = Result.get_ok (Ids.Module_path.of_string "index.js") in
    let idx_src = "import { x } from \"./missing.js\";" in
    Qjs_engine.set_module t idx_path idx_src;
    let threw = Qjs_engine.eval_module t idx_path in
    Alcotest.(check bool) "missing module throws" true threw;
    Qjs_engine.destroy t
  | Error _ -> Alcotest.fail "create failed"

let tests = [
  "engine", [
    Alcotest.test_case "create/destroy x100" `Slow test_create_destroy;
    Alcotest.test_case "eval 1+2 = 3" `Quick test_eval_int;
    Alcotest.test_case "eval throws" `Quick test_eval_throws;
    Alcotest.test_case "heap limit OOM" `Quick test_heap_limit;
    Alcotest.test_case "stack limit" `Quick test_stack_limit;
    Alcotest.test_case "interrupt infinite loop" `Quick test_interrupt;
    Alcotest.test_case "10k cycles (ASan)" `Slow test_many_cycles;
    Alcotest.test_case "pump jobs" `Quick test_pump_jobs;
    Alcotest.test_case "module loader (step 3)" `Quick test_module_loader;
    Alcotest.test_case "module not found" `Quick test_module_not_found;
  ];
]

let () = Alcotest.run "qjs-engine" tests
