(* worker/host_kv.ml — in-memory KV store (§37.3 Host_kv.Memory).
   A namespaced map with configurable failures for fault testing. *)

type t = {
  data : (string, string) Hashtbl.t;
  mutable fail_next : bool;
}

let make () = { data = Hashtbl.create 16; fail_next = false }
let clear t = Hashtbl.clear t.data; t.fail_next <- false

let get t key =
  if t.fail_next then (t.fail_next <- false; Error "kv.get: injected failure")
  else Ok (Hashtbl.find_opt t.data key)

let put t key value =
  if t.fail_next then (t.fail_next <- false; Error "kv.put: injected failure")
  else (Hashtbl.replace t.data key value; Ok ())

let delete t key =
  if t.fail_next then (t.fail_next <- false; Error "kv.delete: injected failure")
  else (Hashtbl.remove t.data key; Ok ())

let list t prefix =
  let keys = Hashtbl.fold (fun k _ acc -> k :: acc) t.data [] in
  let matching = List.filter (fun k -> String.length k >= String.length prefix
    && String.sub k 0 (String.length prefix) = prefix) keys in
  Ok (List.sort compare matching)

let fail_next t = t.fail_next <- true
