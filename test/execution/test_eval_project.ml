(** End-to-end tests for [Eval] on [Physical.Project]. Includes the two
    project/filter combinations, since they exercise projection's interaction
    with filter resolution. *)

open Dovetail_execution
open Test_helpers
module Value = Dovetail_core.Value
module Schema = Dovetail_core.Schema
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* Build a Project wrapping [input_plan] over the users fixture, evaluate
   it, and return the resulting tuples. [column_names] is a list of bare
   names, wrapped into unqualified {!Schema.column_reference}s -- the test
   bodies don't need qualifiers here. *)
let evaluate_users_project ~input_plan column_names =
  let columns =
    List.map
      (fun name : Schema.column_reference -> { qualifier = None; name })
      column_names
  in
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan = Plan.Physical.Project { input = input_plan; columns } in
      Eval.eval environment transaction plan (fun relation ->
          List.of_seq relation.data))

let users_full_scan = Plan.Physical.FullScan { table = "users" }

let test_project_single_column () =
  let rows = evaluate_users_project ~input_plan:users_full_scan [ "name" ] in
  let expected =
    [
      [| Value.String "Alice" |];
      [| Value.String "Bob" |];
      [| Value.String "Carol" |];
      [| Value.String "Dave" |];
      [| Value.String "Eve" |];
    ]
  in
  Alcotest.(check tuple_list_testable) "five single-column rows" expected rows

let test_project_multi_column () =
  let rows =
    evaluate_users_project ~input_plan:users_full_scan [ "name"; "email" ]
  in
  let expected =
    [
      [| Value.String "Alice"; Value.String "alice@example.com" |];
      [| Value.String "Bob"; Value.String "bob@example.com" |];
      [| Value.String "Carol"; Value.String "carol@example.com" |];
      [| Value.String "Dave"; Value.String "dave@example.com" |];
      [| Value.String "Eve"; Value.String "eve@example.com" |];
    ]
  in
  Alcotest.(check tuple_list_testable) "five two-column rows" expected rows

let test_project_reorders_columns () =
  let rows =
    evaluate_users_project ~input_plan:users_full_scan [ "email"; "id" ]
  in
  let expected =
    [
      [| Value.String "alice@example.com"; Value.Int64 1L |];
      [| Value.String "bob@example.com"; Value.Int64 2L |];
      [| Value.String "carol@example.com"; Value.Int64 3L |];
      [| Value.String "dave@example.com"; Value.Int64 4L |];
      [| Value.String "eve@example.com"; Value.Int64 5L |];
    ]
  in
  Alcotest.(check tuple_list_testable) "rows in requested order" expected rows

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
                ~right:(expression_literal (Value.Bool true));
          }
      in
      Eval.eval environment transaction plan (fun relation ->
          let rows = List.of_seq relation.data in
          let expected =
            [
              [| Value.String "Alice"; Value.Bool true |];
              [| Value.String "Carol"; Value.Bool true |];
              [| Value.String "Dave"; Value.Bool true |];
            ]
          in
          Alcotest.(check tuple_list_testable)
            "three active projected rows" expected rows))

let test_filter_then_project () =
  let filter_active_true =
    Plan.Physical.Filter
      {
        input = users_full_scan;
        predicate =
          expression_compare
            ~left:(expression_column "active")
            ~op:Equal
            ~right:(expression_literal (Value.Bool true));
      }
  in
  let rows = evaluate_users_project ~input_plan:filter_active_true [ "name" ] in
  let expected =
    [
      [| Value.String "Alice" |];
      [| Value.String "Carol" |];
      [| Value.String "Dave" |];
    ]
  in
  Alcotest.(check tuple_list_testable) "three active names" expected rows

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
          Alcotest.test_case
            "unknown column raises before any tuples are pulled" `Quick
            test_project_unknown_column_raises;
          Alcotest.test_case
            "duplicate column raises before any tuples are pulled" `Quick
            test_project_duplicate_column_raises;
        ] );
    ]
