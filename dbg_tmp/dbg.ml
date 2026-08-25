let () =
  let store = Result.get_ok (Ids.Store_id.of_string "images") in
  let prefix = Result.get_ok (Ids.Key_prefix.of_string "tenant-a/") in
  let binding = Result.get_ok (Ids.Binding_name.of_string "images") in
  let decls_a = {
    Capability.kv = [{ Capability.binding; store; access = `Read_write; prefix }];
    http = []; clock = `Monotonic; random = `None; logs = true; invoke = [];
  } in
  (match Capability.compile decls_a with
   | Ok p -> Printf.printf "ok, %d grants\n" (List.length p.Capability.grants)
   | Error e -> Printf.printf "compile error: %s\n" (Error.Validation.to_string e))
