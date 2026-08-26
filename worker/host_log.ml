(* worker/host_log.ml — buffered structured log (§37.3 Host_log.Buffer).
   A bounded buffer of structured events. The worker's log capability appends
   events up to max_log_bytes; overflow truncates with an explicit marker. *)

type level = Debug | Info | Warn | Error

type event = {
  level : level;
  message : string;
  fields : (string * string) list;
}

type t = {
  mutable events : event list;   (* most-recent-first *)
  mutable bytes : int;
  max_bytes : int;
  mutable truncated : bool;
}

let make ~max_bytes = { events = []; bytes = 0; max_bytes; truncated = false }

let level_to_string = function Debug -> "debug" | Info -> "info" | Warn -> "warn" | Error -> "error"

let append t ~level message fields =
  let event = { level; message; fields } in
  let event_bytes = String.length message + List.fold_left (fun a (k, v) -> a + String.length k + String.length v + 4) 0 fields in
  if t.bytes + event_bytes > t.max_bytes then
    t.truncated <- true
  else begin
    t.events <- event :: t.events;
    t.bytes <- t.bytes + event_bytes
  end

let debug t msg ?(fields=[]) () = append t ~level:Debug msg fields
let info t msg ?(fields=[]) () = append t ~level:Info msg fields
let warn t msg ?(fields=[]) () = append t ~level:Warn msg fields
let error t msg ?(fields=[]) () = append t ~level:Error msg fields

let events t = List.rev t.events
let bytes t = t.bytes
let truncated t = t.truncated
