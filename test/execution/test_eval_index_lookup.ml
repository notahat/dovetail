(** End-to-end tests for [Eval] on [Physical.IndexLookup]. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* Build an [IndexLookup] over [table] with [key], evaluate it against the
   populated fixture, and return the resulting rows. *)
let evaluate_index_lookup ~table ~key =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan = Plan.Physical.IndexLookup { table; key } in
      Eval.eval environment transaction plan
        (expect_relation (fun relation ->
             (relation.kind, List.of_seq relation.value))))

let test_index_lookup_returns_the_matching_row () =
  let _kind, rows = evaluate_index_lookup ~table:"users" ~key:1L in
  Alcotest.(check row_list_testable)
    "Alice's row by primary key"
    [ List.nth expected_users_rows 0 ]
    rows

let test_index_lookup_returns_a_different_row_for_a_different_key () =
  (* A second key, to confirm the helper isn't accidentally hard-coding the
     first fixture row. *)
  let _kind, rows = evaluate_index_lookup ~table:"users" ~key:3L in
  Alcotest.(check row_list_testable)
    "Carol's row by primary key"
    [ List.nth expected_users_rows 2 ]
    rows

let test_index_lookup_returns_no_rows_for_a_missing_key () =
  let _kind, rows = evaluate_index_lookup ~table:"users" ~key:99L in
  Alcotest.(check row_list_testable) "no rows for missing key" [] rows

let test_index_lookup_preserves_table_kind () =
  (* The resulting relation should carry the table's full kind, including
     its primary-key refinement, so downstream operators see the same shape
     they would from a [FullScan]. *)
  let kind, _rows = evaluate_index_lookup ~table:"users" ~key:1L in
  Alcotest.(check (list (list string)))
    "primary key carried through" [ [ "id" ] ]
    (List.map (function Relation.Primary_key keys -> keys) kind.refinements);
  let field_names =
    List.map (fun (field : Row.field) -> field.name) kind.row_kind
  in
  Alcotest.(check (list string))
    "fields in declaration order"
    [ "id"; "name"; "email"; "active" ]
    field_names

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
          Alcotest.test_case "preserves the table's kind and primary key" `Quick
            test_index_lookup_preserves_table_kind;
        ] );
    ]
