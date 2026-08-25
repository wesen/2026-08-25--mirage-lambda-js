(lang dune 3.15)

(name mirage_lambda)

;; Mirage Lambda Service: a JavaScript function-as-a-service built from
;; MirageOS unikernels. See mirage_lambda_service_implementation_guide.md.
;;
;; Phase 0 (this commit) pins the toolchain and scaffolds the QuickJS probes.
;; Phase 1 adds the pure `common/` library. Phase 2 adds the `qjs/` wrapper.
;; The Mirage entry points (control/unikernel.ml, worker/unikernel.ml) are
;; added in Phase 5/6.

(formatting (enabled_for mirage_lambda))

;; Generate .merlin / build-info where helpful.
(generate_opam_files true)

(package
 (name mirage_lambda)
 (allow_empty)
 (synopsis "JavaScript function-as-a-service built from MirageOS unikernels")
 (description
  "Mirage Lambda Service deploys small ECMAScript modules with explicit
   capabilities and resource limits, and invokes named function revisions
   through an authenticated HTTPS API. The service plane and execution
   workers are MirageOS unikernels; QuickJS supplies the language runtime;
   Solo5 HVT supplies the guest boundary.")
 (depends
  ;; Pinned in Phase 0; see docs/adr/0000-toolchain-baseline.md.
  (ocaml (>= 4.14))
  (dune (>= 3.15))
  (yojson (>= 2.1))
  ;; Phase 1 test/fuzz stack (installed before Phase 1 work):
  (qcheck (>= 0.21))
  (alcotest (>= 1.7))
  ;; Phase 2+ (Unix worker / QuickJS embedding):
  ;; (ctypes (>= 0.21))  ;; optional, if FFI uses ctypes instead of hand stubs
  ;; Phase 4+ (control plane on Unix):
  ;; (cohttp (>= 5.3)) (tls (>= 0.17)) (mtime (>= 2.0))
  ;; Phase 5/6 (Mirage unikernels):
  ;; (mirage (>= 4.5)) (ocaml-solo5 (>= 0.8)) (mirage-clock) (mirage-kv) (mirage-crypto)
 )
 (tags (mirage unikernel ocaml quickjs lambda faas capability security solo5))
 (license MIT)
)
