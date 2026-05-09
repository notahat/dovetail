(** Tests for [Storage]. *)

open Dovetail
open Test_helpers

let test_round_trip () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_write_transaction environment (fun transaction ->
      let map = Storage.create_map environment transaction ~name:"test" in
      Storage.put map transaction ~key:"hello" ~value:"world";
      Storage.put map transaction ~key:"foo" ~value:"bar");
  Storage.with_read_transaction environment (fun transaction ->
      let map =
        match Storage.open_map environment transaction ~name:"test" with
        | Some m -> m
        | None -> Alcotest.fail "expected map to exist"
      in
      Alcotest.(check (option string))
        "hello" (Some "world")
        (Storage.get map transaction ~key:"hello");
      Alcotest.(check (option string))
        "foo" (Some "bar")
        (Storage.get map transaction ~key:"foo");
      Alcotest.(check (option string))
        "missing key" None
        (Storage.get map transaction ~key:"nope"))

let test_iter_seq_in_key_order () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_write_transaction environment (fun transaction ->
      let map = Storage.create_map environment transaction ~name:"test" in
      List.iter
        (fun (k, v) -> Storage.put map transaction ~key:k ~value:v)
        [ ("c", "3"); ("a", "1"); ("b", "2") ]);
  Storage.with_read_transaction environment (fun transaction ->
      let map =
        Option.get (Storage.open_map environment transaction ~name:"test")
      in
      let pairs = Storage.iter_seq map transaction |> List.of_seq in
      Alcotest.(check (list (pair string string)))
        "pairs in ascending key order"
        [ ("a", "1"); ("b", "2"); ("c", "3") ]
        pairs)

let test_open_map_returns_none_when_missing () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check bool)
        "absent map" true
        (Storage.open_map environment transaction ~name:"never-created" = None))

let test_exception_aborts_write_transaction () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  (* Write transaction body raises after a put -- the put must not persist. *)
  (try
     Storage.with_write_transaction environment (fun transaction ->
         let map = Storage.create_map environment transaction ~name:"test" in
         Storage.put map transaction ~key:"hello" ~value:"world";
         failwith "boom")
   with Failure _ -> ());
  Storage.with_read_transaction environment (fun transaction ->
      match Storage.open_map environment transaction ~name:"test" with
      | None ->
          (* The map was never committed -- the abort rolled it back. *)
          ()
      | Some map ->
          Alcotest.(check (option string))
            "no hello" None
            (Storage.get map transaction ~key:"hello"))

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
          Alcotest.test_case "exception inside with_write_transaction aborts"
            `Quick test_exception_aborts_write_transaction;
        ] );
    ]
