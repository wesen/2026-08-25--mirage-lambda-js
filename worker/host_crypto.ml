(* worker/host_crypto.ml — cryptographic randomness (§37.3).
   v1 uses /dev/urandom via the C port boundary; the deterministic fake uses a
   seeded PRNG for tests. *)

type t = {
  deterministic : bool;
  mutable state : Random.State.t option;
}

let make_real () = { deterministic = false; state = None }
let make_deterministic seed =
  let st = Random.State.make [| seed |] in
  { deterministic = true; state = Some st }

let random_bytes t n =
  if n <= 0 then Bytes.of_string ""
  else if t.deterministic then
    (match t.state with
     | Some st -> Bytes.init n (fun _ -> Char.chr (Random.State.int st 256))
     | None -> Bytes.of_string "")
  else
    (* real /dev/urandom via the C port boundary *)
    let buf = Bytes.create n in
    let _ = Unix.read (Unix.openfile "/dev/urandom" [Unix.O_RDONLY] 0) buf 0 n in
    buf
