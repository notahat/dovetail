(** End-to-end tests for [Eval] on [Physical.Catalog_source]. *)

open Dovetail_execution
open Test_helpers
module Catalog = Dovetail_core.Catalog
module Plan = Dovetail_plan
module Storage = Dovetail_storage
module Term = Dovetail_core.Term

(* Dispatch on the [Term.Catalog_value] arm or fail the running test with a
   description of the wrong arm. Mirrors the per-arm helpers in the other
   eval tests. *)
let expect_catalog_value callback : [ `Set | `Bag ] Term.t -> 'a = function
  | Term.Catalog_value value -> callback value
  | Term.Catalog_kind _ | Term.Relation_value _ | Term.Relation_kind _
  | Term.Scalar_value _ | Term.Scalar_kind _ | Term.Row_value _
  | Term.Row_kind _ ->
      Alcotest.fail "expected a catalog value but got a different term arm"

let test_catalog_source_lists_fixture_tables () =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction Plan.Physical.Catalog_source
        (expect_catalog_value (fun value ->
             Alcotest.(check (list string))
               "catalog lists fixture table names in cursor (byte-sorted) order"
               [ "orders"; "users" ]
               (List.map fst value.relations))))

let test_catalog_source_relations_carry_fixture_rows () =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction Plan.Physical.Catalog_source
        (expect_catalog_value (fun value ->
             let rows_for table_name =
               List.assoc table_name value.relations
               |> fun (relation : [ `Set ] Relation.t) ->
               List.of_seq relation.value
             in
             Alcotest.(check row_list_testable)
               "users relation streams all fixture rows" expected_users_rows
               (rows_for "users");
             Alcotest.(check row_list_testable)
               "orders relation streams all fixture rows" expected_orders_rows
               (rows_for "orders"))))

let test_catalog_source_on_empty_environment_is_empty () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction Plan.Physical.Catalog_source
        (expect_catalog_value (fun value ->
             Alcotest.(check (list string))
               "empty environment yields an empty catalog" []
               (List.map fst value.relations))))

let () =
  Alcotest.run "eval_catalog_source"
    [
      ( "catalog source",
        [
          Alcotest.test_case "lists fixture table names in cursor order" `Quick
            test_catalog_source_lists_fixture_tables;
          Alcotest.test_case
            "per-table relations stream every fixture row in PK order" `Quick
            test_catalog_source_relations_carry_fixture_rows;
          Alcotest.test_case
            "an environment with no tables yields an empty catalog" `Quick
            test_catalog_source_on_empty_environment_is_empty;
        ] );
    ]
