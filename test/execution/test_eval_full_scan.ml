(** End-to-end tests for [Eval] on [Physical.FullScan]. *)

open Dovetail_execution
open Test_helpers
module Plan = Dovetail_plan
module Storage = Dovetail_storage

let test_full_scan_yields_fixture_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction
        (Plan.Physical.FullScan { table = "users" })
        (fun relation ->
          let schema = Relation.schema_of_kind relation.kind in
          Alcotest.(check string)
            "schema primary key" "id"
            (String.concat "," schema.primary_key);
          let rows = List.of_seq relation.data in
          Alcotest.(check tuple_list_testable)
            "five rows in primary-key order" expected_users_rows rows))

let test_full_scan_raises_for_missing_table () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.check_raises "missing table"
        (Failure "Eval: unknown table \"nonexistent_table\"") (fun () ->
          Eval.eval environment transaction
            (Plan.Physical.FullScan { table = "nonexistent_table" })
            (fun _relation -> ())))

let () =
  Alcotest.run "eval_full_scan"
    [
      ( "full scan",
        [
          Alcotest.test_case "yields the five fixture rows in primary-key order"
            `Quick test_full_scan_yields_fixture_rows;
          Alcotest.test_case "raises when the table is missing from the catalog"
            `Quick test_full_scan_raises_for_missing_table;
        ] );
    ]
