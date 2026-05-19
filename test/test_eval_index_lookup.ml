(** End-to-end tests for [Eval] on [Physical.IndexLookup]. *)

open Dovetail_core
open Dovetail_plan
open Dovetail_execution
open Test_helpers
module Storage = Dovetail_storage

(* Build an [IndexLookup] over [table] with [key], evaluate it against the
   populated fixture, and return the resulting tuples. *)
let evaluate_index_lookup ~table ~key =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan = Physical.IndexLookup { table; key } in
      Eval.eval environment transaction plan (fun relation ->
          (relation.schema, List.of_seq relation.tuples)))

let test_index_lookup_returns_the_matching_row () =
  let _schema, rows = evaluate_index_lookup ~table:"users" ~key:1L in
  Alcotest.(check tuple_list_testable)
    "Alice's row by primary key"
    [ List.nth expected_users_rows 0 ]
    rows

let test_index_lookup_returns_a_different_row_for_a_different_key () =
  (* A second key, to confirm the helper isn't accidentally hard-coding the
     first fixture row. *)
  let _schema, rows = evaluate_index_lookup ~table:"users" ~key:3L in
  Alcotest.(check tuple_list_testable)
    "Carol's row by primary key"
    [ List.nth expected_users_rows 2 ]
    rows

let test_index_lookup_returns_no_rows_for_a_missing_key () =
  let _schema, rows = evaluate_index_lookup ~table:"users" ~key:99L in
  Alcotest.(check tuple_list_testable) "no rows for missing key" [] rows

let test_index_lookup_preserves_table_schema () =
  (* The resulting relation should carry the table's full schema, including
     its primary-key declaration, so downstream operators see the same shape
     they would from a [FullScan]. *)
  let schema, _rows = evaluate_index_lookup ~table:"users" ~key:1L in
  Alcotest.(check (list string))
    "primary key carried through" [ "id" ] schema.primary_key;
  let field_names =
    List.map (fun (field : Schema.field) -> field.name) schema.fields
  in
  Alcotest.(check (list string))
    "fields in declaration order"
    [ "id"; "name"; "email"; "active" ]
    field_names

let test_index_lookup_raises_for_missing_table () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.check_raises "missing table"
        (Failure "Eval: unknown table \"nonexistent_table\"") (fun () ->
          Eval.eval environment transaction
            (Physical.IndexLookup { table = "nonexistent_table"; key = 1L })
            (fun _relation -> ())))

let () =
  Alcotest.run "eval_index_lookup"
    [
      ( "index lookup",
        [
          Alcotest.test_case "returns the matching row by primary key" `Quick
            test_index_lookup_returns_the_matching_row;
          Alcotest.test_case "returns a different row for a different key"
            `Quick test_index_lookup_returns_a_different_row_for_a_different_key;
          Alcotest.test_case "returns no rows when the key is not present"
            `Quick test_index_lookup_returns_no_rows_for_a_missing_key;
          Alcotest.test_case "preserves the table's schema and primary key"
            `Quick test_index_lookup_preserves_table_schema;
          Alcotest.test_case "raises when the table is missing from the catalog"
            `Quick test_index_lookup_raises_for_missing_table;
        ] );
    ]
