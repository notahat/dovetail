(** End-to-end tests for [Eval] on [Physical.Filter]. *)

open Dovetail_execution
open Test_helpers
module Value = Dovetail_core.Value
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* Build a Filter wrapping a FullScan over the users fixture, evaluate it,
   and return the resulting tuples. *)
let evaluate_users_filter predicate =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan =
        Plan.Physical.Filter
          { input = Plan.Physical.FullScan { table = "users" }; predicate }
      in
      Eval.eval environment transaction plan (fun relation ->
          List.of_seq relation.data))

let test_filter_equality_on_int64_yields_one_row () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "id") ~op:Equal
         ~right:(expression_literal (Value.Int64 3L)))
  in
  Alcotest.(check tuple_list_testable)
    "Carol's row"
    [ List.nth expected_users_rows 2 ]
    rows

let test_filter_equality_on_string_yields_one_row () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "name") ~op:Equal
         ~right:(expression_literal (Value.String "Alice")))
  in
  Alcotest.(check tuple_list_testable)
    "Alice's row"
    [ List.nth expected_users_rows 0 ]
    rows

let test_filter_equality_on_bool_yields_active_rows () =
  let rows =
    evaluate_users_filter
      (expression_compare
         ~left:(expression_column "active")
         ~op:Equal
         ~right:(expression_literal (Value.Bool true)))
  in
  Alcotest.(check int) "three active rows" 3 (List.length rows)

let test_filter_inequality_yields_complement () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "id") ~op:NotEqual
         ~right:(expression_literal (Value.Int64 3L)))
  in
  Alcotest.(check int) "four rows with id <> 3" 4 (List.length rows)

let test_filter_matches_all_rows () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "id") ~op:NotEqual
         ~right:(expression_literal (Value.Int64 999L)))
  in
  Alcotest.(check tuple_list_testable)
    "all five fixture rows" expected_users_rows rows

let test_filter_matches_zero_rows () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "id") ~op:Equal
         ~right:(expression_literal (Value.Int64 999L)))
  in
  Alcotest.(check tuple_list_testable) "no rows" [] rows

let test_filter_column_equals_column_yields_no_rows () =
  let rows =
    evaluate_users_filter
      (expression_compare ~left:(expression_column "name") ~op:Equal
         ~right:(expression_column "email"))
  in
  Alcotest.(check tuple_list_testable) "no rows where name = email" [] rows

let test_filter_unknown_column_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Expression.resolve: unknown column \"unknown_col\"") (fun () ->
      let _ =
        evaluate_users_filter
          (expression_compare
             ~left:(expression_column "unknown_col")
             ~op:Equal
             ~right:(expression_literal (Value.Int64 3L)))
      in
      ())

let test_filter_type_mismatch_raises () =
  Alcotest.check_raises "type mismatch"
    (Failure
       "Expression.resolve: type mismatch: column \"name\" is String, literal \
        Int64 is Int64") (fun () ->
      let _ =
        evaluate_users_filter
          (expression_compare ~left:(expression_column "name") ~op:Equal
             ~right:(expression_literal (Value.Int64 1L)))
      in
      ())

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
          Alcotest.test_case
            "unknown column raises before any tuples are pulled" `Quick
            test_filter_unknown_column_raises;
          Alcotest.test_case "type mismatch raises before any tuples are pulled"
            `Quick test_filter_type_mismatch_raises;
        ] );
    ]
