(* worker/host_clock.ml — monotonic clock (§37.3 Host_clock.Scripted).
   v1 uses real monotonic time (Unix.gettimeofday); the scripted fake is a
   sequence of monotonic values for deterministic tests. *)

type t = {
  mutable scripted : int64 list option;   (* None = real clock *)
}

let make_real () = { scripted = None }
let make_scripted values = { scripted = Some values }

let monotonic_ms t =
  match t.scripted with
  | Some (v :: rest) -> t.scripted <- Some rest; v
  | Some [] -> 0L   (* exhausted; return 0 (test should catch this) *)
  | None ->
    (* real monotonic time in ms — use Unix module *)
    let open Unix in
    let t_unix = gettimeofday () in
    Int64.of_float (t_unix *. 1000.0)
