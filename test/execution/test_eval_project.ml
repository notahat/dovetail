(** End-to-end tests for [Eval] on [Physical.Project]. Includes the two
    project/filter combinations, since they exercise projection's interaction
    with filter resolution. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* Build a Project wrapping [input_plan] over the users fixture, evaluate
   it, and return the resulting rows. [column_names] is a list of bare
   names, wrapped into unqualified {!Row.column_reference}s -- the test
   bodies don't need qualifiers here. *)
let evaluate_users_project ~input_plan column_names =
  let columns =
    List.map
      (fun name : Row.column_reference -> { qualifier = None; name })
      column_names
  in
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan = Plan.Physical.Project { input = input_plan; columns } in
      Eval.eval environment transaction plan
        (expect_relation (fun relation -> List.of_seq relation.value)))

let users_full_scan = Plan.Physical.FullScan { table = "users" }

let test_project_single_column () =
  let rows = evaluate_users_project ~input_plan:users_full_scan [ "name" ] in
  let expected =
    [
      [| Scalar.String "Alice" |];
      [| Scalar.String "Bob" |];
      [| Scalar.String "Carol" |];
      [| Scalar.String "Dave" |];
      [| Scalar.String "Eve" |];
    ]
  in
  Alcotest.(check row_list_testable) "five single-column rows" expected rows

let test_project_multi_column () =
  let rows =
    evaluate_users_project ~input_plan:users_full_scan [ "name"; "email" ]
  in
  let expected =
    [
      [| Scalar.String "Alice"; Scalar.String "alice@example.com" |];
      [| Scalar.String "Bob"; Scalar.String "bob@example.com" |];
      [| Scalar.String "Carol"; Scalar.String "carol@example.com" |];
      [| Scalar.String "Dave"; Scalar.String "dave@example.com" |];
      [| Scalar.String "Eve"; Scalar.String "eve@example.com" |];
    ]
  in
  Alcotest.(check row_list_testable) "five two-column rows" expected rows

let test_project_reorders_columns () =
  let rows =
    evaluate_users_project ~input_plan:users_full_scan [ "email"; "id" ]
  in
  let expected =
    [
      [| Scalar.String "alice@example.com"; Scalar.Int64 1L |];
      [| Scalar.String "bob@example.com"; Scalar.Int64 2L |];
      [| Scalar.String "carol@example.com"; Scalar.Int64 3L |];
      [| Scalar.String "dave@example.com"; Scalar.Int64 4L |];
      [| Scalar.String "eve@example.com"; Scalar.Int64 5L |];
    ]
  in
  Alcotest.(check row_list_testable) "rows in requested order" expected rows

let test_project_then_filter () =
  (* Build Filter(Project(scan, [name; active]), active = true) by hand.
     Tests that a Filter can read columns from a projected schema. *)
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan =
        Plan.Physical.Filter
          {
            input =
              Plan.Physical.Project
                {
                  input = users_full_scan;
                  columns =
                    [
                      { qualifier = None; name = "name" };
                      { qualifier = None; name = "active" };
                    ];
                };
            predicate =
              expression_compare
                ~left:(expression_column "active")
                ~op:Equal
                ~right:(expression_literal (Scalar.Bool true));
          }
      in
      Eval.eval environment transaction plan
        (expect_relation (fun relation ->
             let rows = List.of_seq relation.value in
             let expected =
               [
                 [| Scalar.String "Alice"; Scalar.Bool true |];
                 [| Scalar.String "Carol"; Scalar.Bool true |];
                 [| Scalar.String "Dave"; Scalar.Bool true |];
               ]
             in
             Alcotest.(check row_list_testable)
               "three active projected rows" expected rows)))

let test_filter_then_project () =
  let filter_active_true =
    Plan.Physical.Filter
      {
        input = users_full_scan;
        predicate =
          expression_compare
            ~left:(expression_column "active")
            ~op:Equal
            ~right:(expression_literal (Scalar.Bool true));
      }
  in
  let rows = evaluate_users_project ~input_plan:filter_active_true [ "name" ] in
  let expected =
    [
      [| Scalar.String "Alice" |];
      [| Scalar.String "Carol" |];
      [| Scalar.String "Dave" |];
    ]
  in
  Alcotest.(check row_list_testable) "three active names" expected rows

let test_project_unknown_column_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Projection.resolve: unknown column \"unknown_col\"") (fun () ->
      let _ =
        evaluate_users_project ~input_plan:users_full_scan [ "unknown_col" ]
      in
      ())

let test_project_duplicate_column_raises () =
  Alcotest.check_raises "duplicate column"
    (Failure "Projection.resolve: duplicate column \"name\"") (fun () ->
      let _ =
        evaluate_users_project ~input_plan:users_full_scan [ "name"; "name" ]
      in
      ())

let () =
  Alcotest.run "eval_project"
    [
      ( "project",
        [
          Alcotest.test_case "single column projection yields that column"
            `Quick test_project_single_column;
          Alcotest.test_case "multi-column projection yields columns in order"
            `Quick test_project_multi_column;
          Alcotest.test_case "projection reorders columns" `Quick
            test_project_reorders_columns;
          Alcotest.test_case
            "project then filter applies the filter to projected rows" `Quick
            test_project_then_filter;
          Alcotest.test_case
            "filter then project narrows the survivors to the named columns"
            `Quick test_filter_then_project;
          Alcotest.test_case "unknown column raises before any rows are pulled"
            `Quick test_project_unknown_column_raises;
          Alcotest.test_case
            "duplicate column raises before any rows are pulled" `Quick
            test_project_duplicate_column_raises;
        ] );
    ]
