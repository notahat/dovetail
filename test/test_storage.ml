(** Tests for [Storage]. *)

open Dovetail

(** Create a fresh temp directory, run [f] with its path, remove it on exit.
    Uses shell [rm -rf] for cleanup -- adequate for tests. *)
let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let name =
    Printf.sprintf "dovetail-test-%d-%d" (Unix.getpid ()) (Random.bits ())
  in
  let dir = Filename.concat base name in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      let _ = Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) in
      ())
    (fun () -> f dir)

(** Open an env, run [f env], close the env. *)
let with_env path f =
  let env = Storage.open_env path in
  Fun.protect ~finally:(fun () -> Storage.close_env env) (fun () -> f env)

let test_round_trip () =
  with_temp_dir @@ fun dir ->
  with_env dir @@ fun env ->
  Storage.with_write_txn env (fun txn ->
      let map = Storage.create_map env txn ~name:"test" in
      Storage.put map txn ~key:"hello" ~value:"world";
      Storage.put map txn ~key:"foo" ~value:"bar");
  Storage.with_read_txn env (fun txn ->
      let map =
        match Storage.open_map env txn ~name:"test" with
        | Some m -> m
        | None -> Alcotest.fail "expected map to exist"
      in
      Alcotest.(check (option string))
        "hello" (Some "world")
        (Storage.get map txn ~key:"hello");
      Alcotest.(check (option string))
        "foo" (Some "bar")
        (Storage.get map txn ~key:"foo");
      Alcotest.(check (option string))
        "missing key" None
        (Storage.get map txn ~key:"nope"))

let test_iter_seq_in_key_order () =
  with_temp_dir @@ fun dir ->
  with_env dir @@ fun env ->
  Storage.with_write_txn env (fun txn ->
      let map = Storage.create_map env txn ~name:"test" in
      List.iter
        (fun (k, v) -> Storage.put map txn ~key:k ~value:v)
        [ ("c", "3"); ("a", "1"); ("b", "2") ]);
  Storage.with_read_txn env (fun txn ->
      let map = Option.get (Storage.open_map env txn ~name:"test") in
      let pairs = Storage.iter_seq map txn |> List.of_seq in
      Alcotest.(check (list (pair string string)))
        "pairs in ascending key order"
        [ ("a", "1"); ("b", "2"); ("c", "3") ]
        pairs)

let test_open_map_returns_none_when_missing () =
  with_temp_dir @@ fun dir ->
  with_env dir @@ fun env ->
  Storage.with_read_txn env (fun txn ->
      Alcotest.(check bool)
        "absent map" true
        (Storage.open_map env txn ~name:"never-created" = None))

let test_exception_aborts_write_txn () =
  with_temp_dir @@ fun dir ->
  with_env dir @@ fun env ->
  (* Write txn body raises after a put -- the put must not persist. *)
  (try
     Storage.with_write_txn env (fun txn ->
         let map = Storage.create_map env txn ~name:"test" in
         Storage.put map txn ~key:"hello" ~value:"world";
         failwith "boom")
   with Failure _ -> ());
  Storage.with_read_txn env (fun txn ->
      match Storage.open_map env txn ~name:"test" with
      | None ->
          (* The map was never committed -- the abort rolled it back. *)
          ()
      | Some map ->
          Alcotest.(check (option string))
            "no hello" None
            (Storage.get map txn ~key:"hello"))

let () =
  Alcotest.run "storage"
    [
      ( "round-trip",
        [
          Alcotest.test_case "put then get" `Quick test_round_trip;
          Alcotest.test_case "iter_seq yields pairs in key order" `Quick
            test_iter_seq_in_key_order;
          Alcotest.test_case "open_map returns None when map missing" `Quick
            test_open_map_returns_none_when_missing;
        ] );
      ( "abort",
        [
          Alcotest.test_case "exception inside with_write_txn aborts" `Quick
            test_exception_aborts_write_txn;
        ] );
    ]
