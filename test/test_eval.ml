(** End-to-end tests for [Eval]: populate the fixture and read it back through
    the physical IR. *)

open Dovetail
open Test_helpers

let expected_rows : Schema.tuple list =
  [
    [|
      Value.Int64 1L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 2L;
      Value.String "Bob";
      Value.String "bob@example.com";
      Value.Bool false;
    |];
    [|
      Value.Int64 3L;
      Value.String "Carol";
      Value.String "carol@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 4L;
      Value.String "Dave";
      Value.String "dave@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 5L;
      Value.String "Eve";
      Value.String "eve@example.com";
      Value.Bool false;
    |];
  ]

let tuple_list_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<tuples>")) ( = )

let test_full_scan_yields_fixture_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let relation =
        Eval.eval environment transaction
          (Physical.FullScan { table = "users" })
      in
      Alcotest.(check string)
        "schema primary key" "id"
        (String.concat "," relation.schema.primary_key);
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "five rows in primary-key order" expected_rows rows)

let test_full_scan_raises_for_missing_table () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.check_raises "missing table"
        (Failure "Eval: unknown table \"orders\"") (fun () ->
          let _ =
            Eval.eval environment transaction
              (Physical.FullScan { table = "orders" })
          in
          ()))

let () =
  Alcotest.run "eval"
    [
      ( "full scan",
        [
          Alcotest.test_case "yields the five fixture rows in primary-key order"
            `Quick test_full_scan_yields_fixture_rows;
          Alcotest.test_case "raises when the table is missing from the catalog"
            `Quick test_full_scan_raises_for_missing_table;
        ] );
    ]
