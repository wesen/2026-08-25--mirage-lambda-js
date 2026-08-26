(* control/config.ml — Mirage unikernel composition for the control plane (§26.1, §39.1).
   This config declares the devices the control-plane unikernel needs:
   - a network stack (generic_stackv4v6)
   - a read-only certificate KV (generic_kv_ro)
   - a read/write state KV backed by Chamelon over a block device
   - an HTTP server over the stack
   The unikernel functor (unikernel.ml) receives these and implements the §9 API.

   Phase 5 porting order (§39.2): boot + readiness, then TLS + health, then
   read-only registry backed by Mirage KV, then metadata writer + recovery,
   then artifact upload, then deployment APIs, then queue/admission, then
   telemetry. This first cut implements boot + /healthz (step 1-2). *)

open Mirage

(* The network stack. *)
let stack = generic_stackv4v6 default_network

(* Read-only certificate material (TLS). *)
let certs = generic_kv_ro "certs"

(* Read/write state KV backed by Chamelon (littlefs over a block device). *)
let state_block = block_of_file "state"
let program_block_size = Runtime_arg.create ~pos:__POS__ "block-size"
let state = chamelon ~program_block_size state_block

(* HTTP server over the stack. Phase 5 starts without TLS (conduit_direct);
   TLS is added once the cert path is wired (§39.2 step 2). *)
let httpd = cohttp_server @@ conduit_direct ~tls:false stack

(* The main functor: stack -> kv_ro (certs) -> kv_rw (state) -> http -> job. *)
let packages = [
  package "yojson";
  package "mirage-kv";
  package "logs";
]

let main =
  main ~packages "Unikernel.Main"
    (stackv4v6 @-> kv_ro @-> kv_rw @-> http @-> job)

let () =
  register "mirage-lambda-control"
    [ main $ stack $ certs $ state $ httpd ]
