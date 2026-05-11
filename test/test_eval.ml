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

let test_filter_equality_on_int64_yields_one_row () =
  let rows =
    evaluate_users_filter
      (predicate_compare ~left:(predicate_column "id") ~op:Equal
         ~right:(predicate_literal (Value.Int64 3L)))
  in
  Alcotest.(check tuple_list_testable)
    "Carol's row"
    [ List.nth expected_users_rows 2 ]
    rows

let test_filter_equality_on_string_yields_one_row () =
  let rows =
    evaluate_users_filter
      (predicate_compare ~left:(predicate_column "name") ~op:Equal
         ~right:(predicate_literal (Value.String "Alice")))
  in
  Alcotest.(check tuple_list_testable)
    "Alice's row"
    [ List.nth expected_users_rows 0 ]
    rows

let test_filter_equality_on_bool_yields_active_rows () =
  let rows =
    evaluate_users_filter
      (predicate_compare
         ~left:(predicate_column "active")
         ~op:Equal
         ~right:(predicate_literal (Value.Bool true)))
  in
  Alcotest.(check int) "three active rows" 3 (List.length rows)

let test_filter_inequality_yields_complement () =
  let rows =
    evaluate_users_filter
      (predicate_compare ~left:(predicate_column "id") ~op:NotEqual
         ~right:(predicate_literal (Value.Int64 3L)))
  in
  Alcotest.(check int) "four rows with id <> 3" 4 (List.length rows)

let test_filter_matches_all_rows () =
  let rows =
    evaluate_users_filter
      (predicate_compare ~left:(predicate_column "id") ~op:NotEqual
         ~right:(predicate_literal (Value.Int64 999L)))
  in
  Alcotest.(check tuple_list_testable)
    "all five fixture rows" expected_users_rows rows

let test_filter_matches_zero_rows () =
  let rows =
    evaluate_users_filter
      (predicate_compare ~left:(predicate_column "id") ~op:Equal
         ~right:(predicate_literal (Value.Int64 999L)))
  in
  Alcotest.(check tuple_list_testable) "no rows" [] rows

let test_filter_column_equals_column_yields_no_rows () =
  let rows =
    evaluate_users_filter
      (predicate_compare ~left:(predicate_column "name") ~op:Equal
         ~right:(predicate_column "email"))
  in
  Alcotest.(check tuple_list_testable) "no rows where name = email" [] rows

let test_filter_unknown_column_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Predicate.resolve: unknown column \"unknown_col\"") (fun () ->
      let _ =
        evaluate_users_filter
          (predicate_compare
             ~left:(predicate_column "unknown_col")
             ~op:Equal
             ~right:(predicate_literal (Value.Int64 3L)))
      in
      ())

let test_filter_type_mismatch_raises () =
  Alcotest.check_raises "type mismatch"
    (Failure
       "Predicate.resolve: type mismatch: column \"name\" is String, literal \
        Int64 is Int64") (fun () ->
      let _ =
        evaluate_users_filter
          (predicate_compare ~left:(predicate_column "name") ~op:Equal
             ~right:(predicate_literal (Value.Int64 1L)))
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
              predicate_compare
                ~left:(predicate_column "active")
                ~op:Equal
                ~right:(predicate_literal (Value.Bool true));
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
          predicate_compare
            ~left:(predicate_column "active")
            ~op:Equal
            ~right:(predicate_literal (Value.Bool true));
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

let users_cross_orders_plan : Physical.t =
  CrossProduct
    {
      left = FullScan { table = "users" };
      right = FullScan { table = "orders" };
    }

(* Evaluate [plan] against the populated fixture and return its tuples. *)
let evaluate_against_fixture plan =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let relation = Eval.eval environment transaction plan in
      (relation.schema, List.of_seq relation.tuples))

let test_cross_product_yields_thirty_rows () =
  let _schema, rows = evaluate_against_fixture users_cross_orders_plan in
  Alcotest.(check int) "5 users x 6 orders = 30 rows" 30 (List.length rows)

let test_cross_product_schema_concatenates_with_qualifiers_preserved () =
  let schema, _rows = evaluate_against_fixture users_cross_orders_plan in
  let qualified_field_names =
    List.map
      (fun (field : Schema.field) ->
        match field.qualifier with
        | Some qualifier -> qualifier ^ "." ^ field.name
        | None -> field.name)
      schema.fields
  in
  Alcotest.(check (list string))
    "fields are users.* followed by orders.*"
    [
      "users.id";
      "users.name";
      "users.email";
      "users.active";
      "orders.id";
      "orders.user_id";
      "orders.description";
      "orders.amount";
    ]
    qualified_field_names;
  Alcotest.(check (list string))
    "primary_key is empty for derived relations" [] schema.primary_key

let test_cross_product_then_filter_yields_matched_pairs () =
  (* The plan: users x orders, filtered to rows where users.id = orders.user_id.
     The orders fixture has six rows that point at users 1, 1, 2, 3, 3, 5 -- so
     we expect six matched pairs. *)
  let plan : Physical.t =
    Filter
      {
        input = users_cross_orders_plan;
        predicate =
          predicate_compare
            ~left:(predicate_qualified_column ~qualifier:"users" ~name:"id")
            ~op:Equal
            ~right:
              (predicate_qualified_column ~qualifier:"orders" ~name:"user_id");
      }
  in
  let _schema, rows = evaluate_against_fixture plan in
  Alcotest.(check int) "six matched (user, order) pairs" 6 (List.length rows)

(* The matched (user, order) pairs that a join on
   [users.id = orders.user_id] should produce, built by concatenating the
   relevant fixture rows. The output order is left-outer-loop x right-inner,
   so users are visited in primary-key order; orders likewise within each
   user. The fixture has six matched pairs: Alice has two orders, Bob one,
   Carol two, Eve one (Dave has none). *)
let expected_matched_user_order_rows : Schema.tuple list =
  let user index = List.nth expected_users_rows index in
  let order index = List.nth expected_orders_rows index in
  let pair user_index order_index =
    Array.append (user user_index) (order order_index)
  in
  [
    pair 0 0;
    (* Alice + Coffee *)
    pair 0 1;
    (* Alice + Bagel *)
    pair 1 2;
    (* Bob + Tea *)
    pair 2 3;
    (* Carol + Sandwich *)
    pair 2 4;
    (* Carol + Cake *)
    pair 4 5;
    (* Eve + Cookie *)
  ]

(* Always-true and always-false predicates over int64 literals. The
   predicate grammar in slice 4 doesn't have a bare boolean predicate, but
   [1 = 1] and [1 <> 1] do the same job and parse fine through the existing
   resolver. *)
let always_true_predicate =
  predicate_compare
    ~left:(predicate_literal (Value.Int64 1L))
    ~op:Equal
    ~right:(predicate_literal (Value.Int64 1L))

let always_false_predicate =
  predicate_compare
    ~left:(predicate_literal (Value.Int64 1L))
    ~op:NotEqual
    ~right:(predicate_literal (Value.Int64 1L))

let users_join_orders_on_id_predicate =
  predicate_compare
    ~left:(predicate_qualified_column ~qualifier:"users" ~name:"id")
    ~op:Equal
    ~right:(predicate_qualified_column ~qualifier:"orders" ~name:"user_id")

let nested_loop_join_plan predicate : Physical.t =
  NestedLoopJoin
    {
      left = FullScan { table = "users" };
      right = FullScan { table = "orders" };
      predicate;
    }

let test_nested_loop_join_yields_matched_pairs () =
  let _schema, rows =
    evaluate_against_fixture
      (nested_loop_join_plan users_join_orders_on_id_predicate)
  in
  Alcotest.(check tuple_list_testable)
    "six matched (user, order) pairs in left-outer-loop order"
    expected_matched_user_order_rows rows

let test_nested_loop_join_with_true_predicate_yields_full_cross () =
  let _schema, rows =
    evaluate_against_fixture (nested_loop_join_plan always_true_predicate)
  in
  Alcotest.(check int) "5 users x 6 orders = 30 rows" 30 (List.length rows)

let test_nested_loop_join_with_false_predicate_yields_no_rows () =
  let _schema, rows =
    evaluate_against_fixture (nested_loop_join_plan always_false_predicate)
  in
  Alcotest.(check tuple_list_testable) "no rows" [] rows

let test_nested_loop_join_schema_preserves_qualifiers () =
  let schema, _rows =
    evaluate_against_fixture
      (nested_loop_join_plan users_join_orders_on_id_predicate)
  in
  let qualified_field_names =
    List.map
      (fun (field : Schema.field) ->
        match field.qualifier with
        | Some qualifier -> qualifier ^ "." ^ field.name
        | None -> field.name)
      schema.fields
  in
  Alcotest.(check (list string))
    "fields are users.* followed by orders.*"
    [
      "users.id";
      "users.name";
      "users.email";
      "users.active";
      "orders.id";
      "orders.user_id";
      "orders.description";
      "orders.amount";
    ]
    qualified_field_names;
  Alcotest.(check (list string))
    "primary_key is empty for derived relations" [] schema.primary_key

let test_cross_product_with_ambiguous_unqualified_filter_raises () =
  (* Both inputs have an [id] column, so an unqualified [id = 3] predicate
     can't pick one. Resolution should fail with the ambiguity message. *)
  let plan : Physical.t =
    Filter
      {
        input = users_cross_orders_plan;
        predicate =
          predicate_compare ~left:(predicate_column "id") ~op:Equal
            ~right:(predicate_literal (Value.Int64 3L));
      }
  in
  Alcotest.check_raises "ambiguous unqualified column"
    (Failure
       "Predicate.resolve: ambiguous column reference \"id\": matches \
        \"users.id\" and \"orders.id\"") (fun () ->
      let _ = evaluate_against_fixture plan in
      ())

(* Parity check between [Eval.eval] and [Eval.eval_cps]. While the conversion
   to a streaming CPS executor is in progress, the two entry points must
   agree on every plan shape: identical primary key, qualified field names,
   and tuples in identical order. This test stays in the suite through the
   conversion as the regression net, and is removed once every caller has
   switched to [eval_cps]. *)
let qualified_field_names (schema : Schema.t) =
  List.map
    (fun (field : Schema.field) ->
      match field.qualifier with
      | Some qualifier -> qualifier ^ "." ^ field.name
      | None -> field.name)
    schema.fields

let assert_eval_matches_eval_cps plan =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let eager = Eval.eval environment transaction plan in
      let eager_rows = List.of_seq eager.tuples in
      let cps_rows =
        Eval.eval_cps environment transaction plan (fun streaming ->
            List.of_seq streaming.tuples)
      in
      let cps_schema =
        Eval.eval_cps environment transaction plan (fun streaming ->
            streaming.schema)
      in
      Alcotest.(check (list string))
        "qualified field names match"
        (qualified_field_names eager.schema)
        (qualified_field_names cps_schema);
      Alcotest.(check (list string))
        "primary key matches" eager.schema.primary_key cps_schema.primary_key;
      Alcotest.(check tuple_list_testable)
        "tuples match in order" eager_rows cps_rows)

let parity_plans : (string * Physical.t) list =
  [
    ("FullScan(users)", FullScan { table = "users" });
    ( "Filter(FullScan(users), id = 3)",
      Filter
        {
          input = FullScan { table = "users" };
          predicate =
            predicate_compare ~left:(predicate_column "id") ~op:Equal
              ~right:(predicate_literal (Value.Int64 3L));
        } );
    ( "Project(FullScan(users), [name; email])",
      Project
        {
          input = FullScan { table = "users" };
          columns =
            [
              { qualifier = None; name = "name" };
              { qualifier = None; name = "email" };
            ];
        } );
    ("CrossProduct(users, orders)", users_cross_orders_plan);
    ( "NestedLoopJoin(users, orders, users.id = orders.user_id)",
      nested_loop_join_plan users_join_orders_on_id_predicate );
  ]

let parity_test_cases =
  List.map
    (fun (label, plan) ->
      Alcotest.test_case label `Quick (fun () ->
          assert_eval_matches_eval_cps plan))
    parity_plans

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
      ( "cross product",
        [
          Alcotest.test_case
            "yields one row per (left, right) pair from the inputs" `Quick
            test_cross_product_yields_thirty_rows;
          Alcotest.test_case
            "result schema concatenates left then right with qualifiers \
             preserved"
            `Quick
            test_cross_product_schema_concatenates_with_qualifiers_preserved;
          Alcotest.test_case
            "filter on the cross product yields the matched (user, order) pairs"
            `Quick test_cross_product_then_filter_yields_matched_pairs;
          Alcotest.test_case
            "filter using an unqualified column that matches both inputs \
             raises with the ambiguity message"
            `Quick test_cross_product_with_ambiguous_unqualified_filter_raises;
        ] );
      ( "nested loop join",
        [
          Alcotest.test_case
            "yields the matched (user, order) pairs in left-outer-loop order"
            `Quick test_nested_loop_join_yields_matched_pairs;
          Alcotest.test_case
            "with an always-true predicate yields the full cross product" `Quick
            test_nested_loop_join_with_true_predicate_yields_full_cross;
          Alcotest.test_case "with an always-false predicate yields no rows"
            `Quick test_nested_loop_join_with_false_predicate_yields_no_rows;
          Alcotest.test_case
            "result schema concatenates left then right with qualifiers \
             preserved"
            `Quick test_nested_loop_join_schema_preserves_qualifiers;
        ] );
      ("eval / eval_cps parity", parity_test_cases);
    ]
