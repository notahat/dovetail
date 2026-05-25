(** End-to-end tests for [Eval] on [Physical.Tables]. *)

open Dovetail_execution
open Test_helpers
module Plan = Dovetail_plan
module Storage = Dovetail_storage
module Scalar = Dovetail_core.Scalar

let test_tables_over_catalog_source_streams_table_names () =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan : Plan.Physical.t = Tables { input = Catalog_source } in
      Eval.eval environment transaction plan
        (expect_relation (fun relation ->
             let column_names =
               List.map
                 (fun (field : Row.field) -> field.name)
                 relation.kind.row_kind
             in
             Alcotest.(check (list string))
               "result kind has one (name : string) column" [ "name" ]
               column_names;
             let rows = List.of_seq relation.value in
             let expected_rows : Row.value list =
               [ [| Scalar.String "orders" |]; [| Scalar.String "users" |] ]
             in
             Alcotest.(check row_list_testable)
               "one row per fixture table in cursor order" expected_rows rows)))

let test_tables_over_empty_environment_yields_no_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan : Plan.Physical.t = Tables { input = Catalog_source } in
      Eval.eval environment transaction plan
        (expect_relation (fun relation ->
             let rows = List.of_seq relation.value in
             Alcotest.(check row_list_testable)
               "empty environment yields no table-name rows" [] rows)))

let () =
  Alcotest.run "eval_tables"
    [
      ( "tables",
        [
          Alcotest.test_case
            "over a catalog source streams one row per fixture table" `Quick
            test_tables_over_catalog_source_streams_table_names;
          Alcotest.test_case "over an empty environment yields no rows" `Quick
            test_tables_over_empty_environment_yields_no_rows;
        ] );
    ]
