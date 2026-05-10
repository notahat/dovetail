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
        (Failure "Eval: unknown table \"nonexistent_table\"") (fun () ->
          let _ =
            Eval.eval environment transaction
              (Physical.FullScan { table = "nonexistent_table" })
          in
          ()))

(* Build a Filter wrapping a FullScan over the users fixture, evaluate it,
   and return the resulting tuples. *)
let evaluate_users_filter predicate =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let plan =
        Physical.Filter
          { input = Physical.FullScan { table = "users" }; predicate }
      in
      let relation = Eval.eval environment transaction plan in
      List.of_seq relation.tuples)

(* Helpers to build [Compare] predicates with [term]-shaped sides. Local
   shorthand to keep test bodies short under the slice-4 predicate shape. *)
let column name : Predicate.term = Column { qualifier = None; name }
let literal value : Predicate.term = Literal value

let compare_predicate ~left ~op ~right : Predicate.t =
  Compare { left; op; right }

let test_filter_equality_on_int64_yields_one_row () =
  let rows =
    evaluate_users_filter
      (compare_predicate ~left:(column "id") ~op:Equal
         ~right:(literal (Value.Int64 3L)))
  in
  Alcotest.(check tuple_list_testable)
    "Carol's row"
    [ List.nth expected_users_rows 2 ]
    rows

let test_filter_equality_on_string_yields_one_row () =
  let rows =
    evaluate_users_filter
      (compare_predicate ~left:(column "name") ~op:Equal
         ~right:(literal (Value.String "Alice")))
  in
  Alcotest.(check tuple_list_testable)
    "Alice's row"
    [ List.nth expected_users_rows 0 ]
    rows

let test_filter_equality_on_bool_yields_active_rows () =
  let rows =
    evaluate_users_filter
      (compare_predicate ~left:(column "active") ~op:Equal
         ~right:(literal (Value.Bool true)))
  in
  Alcotest.(check int) "three active rows" 3 (List.length rows)

let test_filter_inequality_yields_complement () =
  let rows =
    evaluate_users_filter
      (compare_predicate ~left:(column "id") ~op:NotEqual
         ~right:(literal (Value.Int64 3L)))
  in
  Alcotest.(check int) "four rows with id <> 3" 4 (List.length rows)

let test_filter_matches_all_rows () =
  let rows =
    evaluate_users_filter
      (compare_predicate ~left:(column "id") ~op:NotEqual
         ~right:(literal (Value.Int64 999L)))
  in
  Alcotest.(check tuple_list_testable)
    "all five fixture rows" expected_users_rows rows

let test_filter_matches_zero_rows () =
  let rows =
    evaluate_users_filter
      (compare_predicate ~left:(column "id") ~op:Equal
         ~right:(literal (Value.Int64 999L)))
  in
  Alcotest.(check tuple_list_testable) "no rows" [] rows

let test_filter_column_equals_column_yields_no_rows () =
  let rows =
    evaluate_users_filter
      (compare_predicate ~left:(column "name") ~op:Equal ~right:(column "email"))
  in
  Alcotest.(check tuple_list_testable) "no rows where name = email" [] rows

let test_filter_unknown_column_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Predicate.resolve: unknown column \"unknown_col\"") (fun () ->
      let _ =
        evaluate_users_filter
          (compare_predicate ~left:(column "unknown_col") ~op:Equal
             ~right:(literal (Value.Int64 3L)))
      in
      ())

let test_filter_type_mismatch_raises () =
  Alcotest.check_raises "type mismatch"
    (Failure
       "Predicate.resolve: type mismatch: column \"name\" is String, literal \
        Int64 is Int64") (fun () ->
      let _ =
        evaluate_users_filter
          (compare_predicate ~left:(column "name") ~op:Equal
             ~right:(literal (Value.Int64 1L)))
      in
      ())

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
  Storage.with_read_transaction environment (fun transaction ->
      let plan = Physical.Project { input = input_plan; columns } in
      let relation = Eval.eval environment transaction plan in
      List.of_seq relation.tuples)

let users_full_scan = Physical.FullScan { table = "users" }

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
  Storage.with_read_transaction environment (fun transaction ->
      let plan =
        Physical.Filter
          {
            input =
              Physical.Project
                {
                  input = users_full_scan;
                  columns =
                    [
                      { qualifier = None; name = "name" };
                      { qualifier = None; name = "active" };
                    ];
                };
            predicate =
              compare_predicate ~left:(column "active") ~op:Equal
                ~right:(literal (Value.Bool true));
          }
      in
      let relation = Eval.eval environment transaction plan in
      let rows = List.of_seq relation.tuples in
      let expected =
        [
          [| Value.String "Alice"; Value.Bool true |];
          [| Value.String "Carol"; Value.Bool true |];
          [| Value.String "Dave"; Value.Bool true |];
        ]
      in
      Alcotest.(check tuple_list_testable)
        "three active projected rows" expected rows)

let test_filter_then_project () =
  let filter_active_true =
    Physical.Filter
      {
        input = users_full_scan;
        predicate =
          compare_predicate ~left:(column "active") ~op:Equal
            ~right:(literal (Value.Bool true));
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
  Alcotest.run "eval"
    [
      ( "full scan",
        [
          Alcotest.test_case "yields the five fixture rows in primary-key order"
            `Quick test_full_scan_yields_fixture_rows;
          Alcotest.test_case "raises when the table is missing from the catalog"
            `Quick test_full_scan_raises_for_missing_table;
        ] );
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
