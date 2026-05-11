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

let test_open_map_returns_none_when_missing () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check bool)
        "absent map" true
        (Storage.open_map environment transaction ~name:"never-created" = None))

(* Populate a fresh map with the three pairs used across the [with_iter_seq]
   tests, then run [body] with a read transaction and the map. *)
let with_streaming_fixture body =
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
      body transaction map)

let test_with_iter_seq_streams_in_key_order () =
  with_streaming_fixture @@ fun transaction map ->
  let pairs =
    Storage.with_iter_seq map transaction (fun sequence -> List.of_seq sequence)
  in
  Alcotest.(check (list (pair string string)))
    "pairs in ascending key order"
    [ ("a", "1"); ("b", "2"); ("c", "3") ]
    pairs

let test_with_iter_seq_is_one_shot () =
  with_streaming_fixture @@ fun transaction map ->
  Storage.with_iter_seq map transaction (fun sequence ->
      let first_pass = List.of_seq sequence in
      let second_pass = List.of_seq sequence in
      Alcotest.(check (list (pair string string)))
        "first pass drains the cursor"
        [ ("a", "1"); ("b", "2"); ("c", "3") ]
        first_pass;
      Alcotest.(check (list (pair string string)))
        "second pass yields nothing once exhausted" [] second_pass)

let test_with_iter_seq_partial_consumption_is_safe () =
  with_streaming_fixture @@ fun transaction map ->
  let first_pair =
    Storage.with_iter_seq map transaction (fun sequence ->
        match sequence () with
        | Seq.Nil -> Alcotest.fail "expected at least one pair"
        | Seq.Cons (pair, _rest) -> pair)
  in
  Alcotest.(check (pair string string))
    "first pair pulled before exit" ("a", "1") first_pair;
  (* Subsequent reads against the same transaction must still succeed --
     leaving the cursor partly consumed should not poison the transaction. *)
  let pairs_after =
    Storage.with_iter_seq map transaction (fun sequence -> List.of_seq sequence)
  in
  Alcotest.(check (list (pair string string)))
    "fresh cursor still streams every pair"
    [ ("a", "1"); ("b", "2"); ("c", "3") ]
    pairs_after

let test_with_iter_seq_yields_empty_for_empty_map () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_write_transaction environment (fun transaction ->
      let _ = Storage.create_map environment transaction ~name:"empty" in
      ());
  Storage.with_read_transaction environment (fun transaction ->
      let map =
        Option.get (Storage.open_map environment transaction ~name:"empty")
      in
      let pairs =
        Storage.with_iter_seq map transaction (fun sequence ->
            List.of_seq sequence)
      in
      Alcotest.(check (list (pair string string)))
        "empty map yields empty seq" [] pairs)

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
          Alcotest.test_case "open_map returns None when map missing" `Quick
            test_open_map_returns_none_when_missing;
        ] );
      ( "with_iter_seq",
        [
          Alcotest.test_case "streams pairs in key order" `Quick
            test_with_iter_seq_streams_in_key_order;
          Alcotest.test_case "re-iterating an exhausted sequence yields nothing"
            `Quick test_with_iter_seq_is_one_shot;
          Alcotest.test_case "partial consumption leaves the transaction usable"
            `Quick test_with_iter_seq_partial_consumption_is_safe;
          Alcotest.test_case "empty map yields an empty sequence" `Quick
            test_with_iter_seq_yields_empty_for_empty_map;
        ] );
      ( "abort",
        [
          Alcotest.test_case "exception inside with_write_transaction aborts"
            `Quick test_exception_aborts_write_transaction;
        ] );
    ]
