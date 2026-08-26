(* worker/invocation.ml — invocation context and lifecycle (§12, §37).
   An invocation is: revision digest + entrypoint + event JSON + context JSON
   + deadline + budget + compiled capability policy. The worker creates an
   engine from the bundle, loads modules, calls the handler, and drives the
   dispatch loop until completion, rejection, or interruption. *)

open Ids

type context = {
  invocation_id : Protocol.Invocation_id.t;
  revision_digest : Digest.t;
  entrypoint : Module_path.t;
  export_name : string;
  event_json : Bounded_bytes.t;
  context_json : Bounded_bytes.t;
  deadline_ms : int64;
  attempt : int;
  limits : Budget.Engine_limits.t;
  policy : Capability.policy;
  mutable engine : Qjs_engine.t option;
  mutable budget : Budget.Usage.t;
  mutable started_ns : int64;
  mutable finished : bool;
}

let make
    ~invocation_id ~revision_digest ~entrypoint ~export_name
    ~event_json ~context_json ~deadline_ms ~attempt
    ~limits ~policy =
  {
    invocation_id; revision_digest; entrypoint; export_name;
    event_json; context_json; deadline_ms; attempt;
    limits; policy;
    engine = None;
    budget = Budget.Usage.zero ~limits;
    started_ns = 0L;
    finished = false;
  }

let invocation_id t = t.invocation_id
let engine t = t.engine
let set_engine t e = t.engine <- Some e
let budget t = t.budget
let policy t = t.policy
let limits t = t.limits
let deadline_ms t = t.deadline_ms
let event_json t = t.event_json
let context_json t = t.context_json
let entrypoint t = t.entrypoint
let export_name t = t.export_name
let attempt t = t.attempt

let mark_started t ~now_ns = t.started_ns <- now_ns
let mark_finished t = t.finished <- true
let is_finished t = t.finished

(* §5.3 deadline check *)
let deadline_expired t ~now_ms =
  Budget.deadline_expired ~deadline_ms:t.deadline_ms ~now_ms
