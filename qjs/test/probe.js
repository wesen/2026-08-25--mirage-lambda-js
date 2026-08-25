// qjs/test/probe.js — Phase 0 feasibility probe (§34.2).
//
// Exercises every required QuickJS facility independently so the wrapper
// can prove the engine works before the service architecture accumulates.
// The probe is run on BOTH the Unix target and the Solo5 HVT target.
//
// Host module "host:test" is provided by the OCaml probe driver (probe.ml)
// through the custom module loader (§24.4). It exports an async `later`
// helper whose settlement is driven from the OCaml event loop (§23).

import { later } from "host:test";

export default async function main(input, env) {
  const x = await later(input.x);
  return { answer: x + 1, hasClock: Boolean(env.clock) };
}

// Self-checks run by the probe driver, not by this default export, to keep
// the handler shape identical to a real lambda entrypoint. The driver:
//   1. creates and destroys JSRuntime/JSContext repeatedly;
//   2. evaluates `1 + 2` and extracts the integer 3;
//   3. loads this two-module program via the custom module loader;
//   4. calls the exported async handler and drains the QuickJS job queue;
//   5. creates a host Promise, retains its resolving functions, and settles
//      it later from the OCaml event loop;
//   6. enforces a small heap limit and observes a controlled OOM error;
//   7. enforces a stack limit with recursive JavaScript;
//   8. interrupts `while (true) {}` using the public interrupt callback;
//   9. receives an unhandled Promise rejection through the rejection tracker;
//  10. builds and executes the same probe on Unix and Solo5 HVT;
//  11. runs >= 100,000 create/evaluate/destroy cycles under ASan/UBSan on
//      Unix without leaks or invalid accesses attributable to the wrapper.
