(** End-to-end tests for [Eval]: populate the fixture and read it back through
    the physical IR. *)

open Dovetail
open Test_helpers

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
        "five rows in primary-key order" expected_users_rows rows)

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
