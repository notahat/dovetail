(** End-to-end tests for [Eval] on [Physical.Filter].

    Predicate validation lives in [Plan.Typecheck]; these tests exercise the
    happy-path closure behaviour against fixture rows. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* Build a Filter wrapping a FullScan over the users fixture, evaluate it,
   and return the resulting rows. *)
let evaluate_users_filter predicate =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan =
        Plan.Physical.Filter
          { input = Plan.Physical.FullScan { table = "users" }; predicate }
      in
      Eval.eval environment transaction plan
        (expect_relation (fun relation -> List.of_seq relation.value)))

let test_filter_equality_on_int64_yields_one_row () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "id") ~op:Equal
         ~right:(expression_literal (Scalar.Int64 3L)))
  in
  Alcotest.(check row_list_testable)
    "Carol's row"
    [ List.nth expected_users_rows 2 ]
    rows

let test_filter_equality_on_string_yields_one_row () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "name") ~op:Equal
         ~right:(expression_literal (Scalar.String "Alice")))
  in
  Alcotest.(check row_list_testable)
    "Alice's row"
    [ List.nth expected_users_rows 0 ]
    rows

let test_filter_equality_on_bool_yields_active_rows () =
  let rows =
    evaluate_users_filter
      (expression_compare
         ~left:(expression_column "active")
         ~op:Equal
         ~right:(expression_literal (Scalar.Bool true)))
  in
  Alcotest.(check int) "three active rows" 3 (List.length rows)

let test_filter_inequality_yields_complement () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "id") ~op:NotEqual
         ~right:(expression_literal (Scalar.Int64 3L)))
  in
  Alcotest.(check int) "four rows with id <> 3" 4 (List.length rows)

let test_filter_matches_all_rows () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "id") ~op:NotEqual
         ~right:(expression_literal (Scalar.Int64 999L)))
  in
  Alcotest.(check row_list_testable)
    "all five fixture rows" expected_users_rows rows

let test_filter_matches_zero_rows () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "id") ~op:Equal
         ~right:(expression_literal (Scalar.Int64 999L)))
  in
  Alcotest.(check row_list_testable) "no rows" [] rows

let test_filter_column_equals_column_yields_no_rows () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "name") ~op:Equal
         ~right:(expression_column "email"))
  in
  Alcotest.(check row_list_testable) "no rows where name = email" [] rows

let () =
  Alcotest.run "eval_filter"
    [
      ( "filter",
        [
          Alcotest.test_case "equality on int64 column yields the matching row"
            `Quick test_filter_equality_on_int64_yields_one_row;
          Alcotest.test_case "equality on string column yields the matching row"
            `Quick test_filter_equality_on_string_yields_one_row;
          Alcotest.test_case "equality on bool column yields all active rows"
            `Quick test_filter_equality_on_bool_yields_active_rows;
          Alcotest.test_case "inequality yields the complement" `Quick
            test_filter_inequality_yields_complement;
          Alcotest.test_case "predicate that matches every row yields them all"
            `Quick test_filter_matches_all_rows;
          Alcotest.test_case "predicate that matches no row yields empty" `Quick
            test_filter_matches_zero_rows;
          Alcotest.test_case "column = column with no matches yields no rows"
            `Quick test_filter_column_equals_column_yields_no_rows;
        ] );
    ]
