(* Fuzz harness for the pure parsers (§29.3, §36.5). Under a normal run,
   crowbar samples a few random inputs; under AFL (an AFL-instrumented switch),
   it fuzzes. The invariant: arbitrary bytes must not crash the bundle or
   manifest parsers — they must return a structured result. *)

(* Arbitrary bytes through the MLB1 bundle parser (§10.4). *)
let () = Crowbar.add_test [Crowbar.bytes] (fun s ->
  ignore (Bundle.parse s))

(* Arbitrary bytes through the manifest parser (§10.2). Yojson raises
   Json_error on malformed JSON; Manifest.parse_string catches it and returns
   a structured Error. *)
let () = Crowbar.add_test [Crowbar.bytes] (fun s ->
  ignore (Manifest.parse_string s))

(* Round-trip: a written bundle must parse back to the same module set. *)
let () =
  Crowbar.add_test [Crowbar.bytes] (fun content ->
    let path = Result.get_ok (Ids.Module_path.of_string "index.js") in
    let entry = { Bundle.path; content; digest = Bundle.Sha256.hash content } in
    let header_cj = Canonical_json.Object [] in
    let manifest = Result.get_ok (Manifest.parse_string
      {|{"schemaVersion":1,"name":"thumbnail","entrypoint":"index.js","export":"default","runtime":"quickjs-2026-06-04","input":{"format":"json","maxBytes":1048576},"output":{"format":"json","maxBytes":1048576},"limits":{"jsHeapBytes":16777216,"nativeOverheadBytes":4194304,"stackBytes":262144,"timeoutMs":100,"cpuMs":50,"maxHostCalls":32,"maxPendingPromises":16,"maxLogBytes":32768,"maxOutboundBytes":262144,"maxRedirects":2,"maxChildInvocations":4},"capabilities":{"clock":"monotonic","random":"cryptographic","logs":true},"retry":{"mode":"never"}}|}) in
    let manifest_yo = Yojson.Safe.from_string
      {|{"schemaVersion":1,"name":"thumbnail","entrypoint":"index.js","export":"default","runtime":"quickjs-2026-06-04","input":{"format":"json","maxBytes":1048576},"output":{"format":"json","maxBytes":1048576},"limits":{"jsHeapBytes":16777216,"nativeOverheadBytes":4194304,"stackBytes":262144,"timeoutMs":100,"cpuMs":50,"maxHostCalls":32,"maxPendingPromises":16,"maxLogBytes":32768,"maxOutboundBytes":262144,"maxRedirects":2,"maxChildInvocations":4},"capabilities":{"clock":"monotonic","random":"cryptographic","logs":true},"retry":{"mode":"never"}}|} in
    let manifest_cj = Result.get_ok (Canonical_json.of_yojson manifest_yo) in
    let buf = Bundle.write ~header_json:header_cj ~manifest ~manifest_json:manifest_cj ~modules:[entry] in
    match Bundle.parse buf with
    | Error _ -> Crowbar.check false
    | Ok parsed ->
      let ms = Bundle.Validated.modules parsed in
      Crowbar.check (List.length ms = 1);
      Crowbar.check (String.equal (List.hd ms).content content))
