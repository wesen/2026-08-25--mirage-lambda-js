(* End-to-end worker test: a JS handler that calls host RPC operations
   (log, kv, clock) through the Promise bridge, driven by the dispatch loop
   to completion. The Phase 3 gate: "end-to-end invocation on Unix; resource
   limits enforced; host calls are async + metered." *)

open Ids

let default_limits =
  Result.get_ok (Budget.Engine_limits.make
    ~js_heap_bytes:(16 * 1024 * 1024) ~native_overhead_bytes:0 ~stack_bytes:(256 * 1024)
    ~timeout_ms:5000 ~cpu_ms:5000 ~max_host_calls:32 ~max_pending_promises:16
    ~max_log_bytes:32768 ~max_outbound_bytes:262144 ~max_redirects:2 ~max_child_invocations:4 ())

let dummy_bundle =
  let mj = {|{"schemaVersion":1,"name":"p","entrypoint":"index.js","export":"default","runtime":"quickjs-2026-06-04","input":{"format":"json","maxBytes":1024},"output":{"format":"json","maxBytes":1024},"limits":{"jsHeapBytes":16777216,"nativeOverheadBytes":4194304,"stackBytes":262144,"timeoutMs":100,"cpuMs":50,"maxHostCalls":32,"maxPendingPromises":16,"maxLogBytes":32768,"maxOutboundBytes":262144,"maxRedirects":2,"maxChildInvocations":4},"capabilities":{"clock":"monotonic","random":"cryptographic","logs":true},"retry":{"mode":"never"}}|} in
  let m = Result.get_ok (Manifest.parse_string mj) in
  let mcj = Result.get_ok (Canonical_json.of_yojson (Yojson.Safe.from_string mj)) in
  let hcj = Canonical_json.Object [("s", Canonical_json.Int 1L)] in
  let p = Result.get_ok (Module_path.of_string "index.js") in
  let c = "export default async function main(){}" in
  let e = { Bundle.path = p; content = c; digest = Bundle.Sha256.hash c } in
  Result.get_ok (Bundle.parse (Bundle.write ~header_json:hcj ~manifest:m ~manifest_json:mcj ~modules:[e]))

(* A JS handler that uses host.rpc for log, kv, and clock. *)
let handler_js = {|
globalThis.__done = false;
globalThis.__result = null;
(async () => {
  await host.rpc("log.info", {message: "start"});
  await host.rpc("kv.put", {key: "counter", value: "1"});
  const val = await host.rpc("kv.get", {key: "counter"});
  const now = await host.rpc("clock.monotonicMs", {});
  globalThis.__result = {val: val, now: now};
  globalThis.__done = true;
})();
|}

let test_end_to_end () =
  (* set up fakes *)
  let log = Host_log.make ~max_bytes:32768 in
  let clock = Host_clock.make_scripted [1000L; 2000L; 3000L] in
  let crypto = Host_crypto.make_deterministic 42 in
  let kv = Hashtbl.create 16 in
  let impls = Capability_broker.make_impls ~log ~clock ~crypto ~kv in
  (* create engine *)
  (match Qjs_engine.create ~limits:default_limits ~bundle:dummy_bundle with
   | Error _ -> Alcotest.fail "create failed"
   | Ok engine ->
     Qjs_engine.install_host engine;
     (* eval the handler (starts the async IIFE) *)
     let threw = Qjs_engine.eval engine handler_js in
     Alcotest.(check bool) "handler eval does not throw" false threw;
     (* drive the dispatch loop *)
     let result = Runtime_host.drive ~impls ~max_turns:100 engine in
     (match result with
      | Runtime_host.Fulfilled json ->
        (* verify the result: val should be "1" (from kv.put/kv.get), now should be a number *)
        let parsed = Yojson.Safe.from_string json in
        (match parsed with
         | `Assoc fields ->
           (match List.assoc_opt "val" fields with
            | Some (`String s) -> Alcotest.(check string) "kv value" "1" s
            | _ -> Alcotest.fail "val missing or wrong type");
           (match List.assoc_opt "now" fields with
            | Some _ -> ()  (* just check it exists *)
            | None -> Alcotest.fail "now missing")
         | _ -> Alcotest.fail "result is not an object");
         (* verify the log captured the "start" message *)
         let events = Host_log.events log in
         Alcotest.(check bool) "log has start event" true
           (List.exists (fun e -> e.Host_log.message = "start") events);
         (* verify the kv store has the counter *)
         Alcotest.(check string) "kv counter" "1" (Hashtbl.find kv "counter")
      | Rejected msg -> Alcotest.fail ("handler rejected: " ^ msg)
      | Failed e -> Alcotest.fail ("handler failed: " ^ Error.to_string e)
      | Timeout e -> Alcotest.fail ("handler timed out: " ^ Error.to_string e));
     Qjs_engine.destroy engine)

let tests = [
  "worker", [
    Alcotest.test_case "end-to-end invocation" `Slow test_end_to_end;
  ];
]

let () = Alcotest.run "worker" tests
