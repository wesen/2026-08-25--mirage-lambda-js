(* qjs/test/probe.ml — Phase 0 feasibility probe driver (§34.2).
 *
 * This is the OCaml side of the Phase 0 probe. It drives the QuickJS engine
 * through the public [Qjs_engine] interface (§20.1) to exercise every
 * required facility independently. The driver is SCAFFOLDING in Phase 0: it
 * references [Qjs_engine], which is implemented in Phase 2 (qjs/lib/). Until
 * Phase 2 lands, this file documents the probe contract and the expected
 * state trace; it is not compiled into the build.
 *
 * Expected state trace (§34.2):
 *   runtime-created
 *   module-compiled
 *   handler-called
 *   host-request-created id=1
 *   job-queue-empty waiting=1
 *   host-request-completed id=1
 *   promise-resolved
 *   job-executed
 *   handler-fulfilled
 *   runtime-destroyed live-handles=0
 *)

(* The engine interface the probe depends on. Mirrors §20.1; implemented in
 * Phase 2. Kept inline here so Phase 0 can record the contract. *)
module type QJS_ENGINE = sig
  type t
  type error
  type completion = Fulfilled of string | Rejected of string
  type progress =
    | Need_host_work | Runnable | Waiting
    | Complete of completion | Interrupted of string

  val create : limits:string -> bundle:string -> (t, error) result
  val start :
    t -> entrypoint:string -> export_name:string ->
    event_json:string -> context_json:string -> (unit, error) result
  val take_host_requests : t -> int list
  val resolve_host_request : t -> int -> (string, string) result -> (unit, error) result
  val pump : t -> max_jobs:int -> (progress, error) result
  val cancel : t -> string -> unit
  val memory_usage : t -> int
  val destroy : t -> unit
end

let () =
  (* Phase 0: print the expected state trace and the 11 probe steps so the
   * evidence report can diff against a real run once Phase 2 wires the
   * engine. *)
  let steps = [
    (1,  "create and destroy JSRuntime/JSContext repeatedly");
    (2,  "evaluate 1 + 2 and extract the integer result");
    (3,  "load a two-module ECMAScript program via the custom module loader");
    (4,  "call an exported async handler and drain the QuickJS job queue");
    (5,  "create a host Promise, retain resolvers, settle later from OCaml");
    (6,  "enforce a small heap limit; observe a controlled OOM error");
    (7,  "enforce a stack limit with recursive JavaScript");
    (8,  "interrupt `while (true) {}` via the public interrupt callback");
    (9,  "receive an unhandled Promise rejection via the rejection tracker");
    (10, "build and execute the same probe on Unix and Solo5 HVT");
    (11, ">= 100,000 create/evaluate/destroy cycles under ASan/UBSan");
  ] in
  Printf.printf "=== Mirage Lambda Phase 0 probe driver (scaffolding) ===\n";
  Printf.printf "engine: Qjs_engine (Phase 2)\n";
  List.iter (fun (n, d) -> Printf.printf "  step %2d: %s\n" n d) steps;
  Printf.printf "expected state trace:\n";
  List.iter print_endline [
    "runtime-created";
    "module-compiled";
    "handler-called";
    "host-request-created id=1";
    "job-queue-empty waiting=1";
    "host-request-completed id=1";
    "promise-resolved";
    "job-executed";
    "handler-fulfilled";
    "runtime-destroyed live-handles=0";
  ];
  Printf.printf "(activate in Phase 2 once qjs/lib/qjs_engine.ml is implemented)\n"
