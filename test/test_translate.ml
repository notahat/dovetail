(** Tests for [Translate]'s structural rewrites: one logical constructor maps to
    one physical constructor, plus the slice-5 inner-join collapse. The
    [IndexLookup] rewrite lives in [test_translate_index_lookup.ml]. *)

open Dovetail
open Test_helpers

let test_scan_lowers_to_full_scan () =
  let logical = Logical.Scan { table = "users" } in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Scan -> FullScan"
    (Physical.FullScan { table = "users" })
    physical

let test_pipeline_yields_fixture_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let logical = Logical.Scan { table = "users" } in
      let catalog = make_catalog environment transaction in
      let physical = Translate.translate ~catalog logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "five rows from logical scan" expected_users_rows rows))

let id_equals_three =
  expression_compare ~left:(expression_column "id") ~op:Equal
    ~right:(expression_literal (Value.Int64 3L))

let name_then_email : Projection.t =
  [ column_reference "name"; column_reference "email" ]

let test_restrict_translates_to_filter () =
  let logical =
    Logical.Restrict
      { input = Logical.Scan { table = "users" }; predicate = id_equals_three }
  in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Restrict -> Filter wrapping FullScan"
    (Physical.Filter
       {
         input = Physical.FullScan { table = "users" };
         predicate = id_equals_three;
       })
    physical

let test_restrict_pipeline_yields_filtered_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let logical =
        Logical.Restrict
          {
            input = Logical.Scan { table = "users" };
            predicate = id_equals_three;
          }
      in
      let catalog = make_catalog environment transaction in
      let physical = Translate.translate ~catalog logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "Carol's row from logical Restrict"
            [ List.nth expected_users_rows 2 ]
            rows))

let test_project_translates_to_physical_project () =
  let logical =
    Logical.Project
      { input = Logical.Scan { table = "users" }; columns = name_then_email }
  in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Project -> Project wrapping FullScan"
    (Physical.Project
       {
         input = Physical.FullScan { table = "users" };
         columns = name_then_email;
       })
    physical

let test_project_pipeline_yields_projected_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let logical =
        Logical.Project
          {
            input = Logical.Scan { table = "users" };
            columns = name_then_email;
          }
      in
      let catalog = make_catalog environment transaction in
      let physical = Translate.translate ~catalog logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          let expected =
            [
              [| Value.String "Alice"; Value.String "alice@example.com" |];
              [| Value.String "Bob"; Value.String "bob@example.com" |];
              [| Value.String "Carol"; Value.String "carol@example.com" |];
              [| Value.String "Dave"; Value.String "dave@example.com" |];
              [| Value.String "Eve"; Value.String "eve@example.com" |];
            ]
          in
          Alcotest.(check tuple_list_testable)
            "five projected rows from logical Project" expected rows))

let test_cross_product_translates_to_physical_cross_product () =
  let logical =
    Logical.CrossProduct
      {
        left = Logical.Scan { table = "users" };
        right = Logical.Scan { table = "orders" };
      }
  in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Logical.CrossProduct -> Physical.CrossProduct wrapping FullScans"
    (Physical.CrossProduct
       {
         left = Physical.FullScan { table = "users" };
         right = Physical.FullScan { table = "orders" };
       })
    physical

let users_id_equals_orders_user_id =
  expression_compare
    ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
    ~op:Equal
    ~right:(expression_qualified_column ~qualifier:"orders" ~name:"user_id")

let test_restrict_over_cross_product_translates_to_nested_loop_join () =
  let logical =
    Logical.Restrict
      {
        input =
          Logical.CrossProduct
            {
              left = Logical.Scan { table = "users" };
              right = Logical.Scan { table = "orders" };
            };
        predicate = users_id_equals_orders_user_id;
      }
  in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Restrict(CrossProduct(...), pred) -> NestedLoopJoin(..., pred)"
    (Physical.NestedLoopJoin
       {
         left = Physical.FullScan { table = "users" };
         right = Physical.FullScan { table = "orders" };
         predicate = users_id_equals_orders_user_id;
       })
    physical

let test_standalone_restrict_does_not_trigger_join_rewrite () =
  let logical =
    Logical.Restrict
      { input = Logical.Scan { table = "users" }; predicate = id_equals_three }
  in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Restrict over a non-CrossProduct input still becomes Filter"
    (Physical.Filter
       {
         input = Physical.FullScan { table = "users" };
         predicate = id_equals_three;
       })
    physical

let test_standalone_cross_product_does_not_trigger_join_rewrite () =
  let logical =
    Logical.CrossProduct
      {
        left = Logical.Scan { table = "users" };
        right = Logical.Scan { table = "orders" };
      }
  in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "CrossProduct without an enclosing Restrict stays as CrossProduct"
    (Physical.CrossProduct
       {
         left = Physical.FullScan { table = "users" };
         right = Physical.FullScan { table = "orders" };
       })
    physical

let () =
  Alcotest.run "translate"
    [
      ( "scan",
        [
          Alcotest.test_case "lowers Logical.Scan to Physical.FullScan" `Quick
            test_scan_lowers_to_full_scan;
          Alcotest.test_case
            "logical scan, translated and evaluated, yields fixture rows" `Quick
            test_pipeline_yields_fixture_rows;
        ] );
      ( "restrict",
        [
          Alcotest.test_case "lowers Logical.Restrict to Physical.Filter" `Quick
            test_restrict_translates_to_filter;
          Alcotest.test_case
            "logical Restrict, translated and evaluated, yields filtered rows"
            `Quick test_restrict_pipeline_yields_filtered_rows;
        ] );
      ( "project",
        [
          Alcotest.test_case "lowers Logical.Project to Physical.Project" `Quick
            test_project_translates_to_physical_project;
          Alcotest.test_case
            "logical Project, translated and evaluated, yields projected rows"
            `Quick test_project_pipeline_yields_projected_rows;
        ] );
      ( "cross product",
        [
          Alcotest.test_case
            "translates Logical.CrossProduct to Physical.CrossProduct" `Quick
            test_cross_product_translates_to_physical_cross_product;
        ] );
      ( "nested loop join rewrite",
        [
          Alcotest.test_case
            "Restrict over CrossProduct collapses to a NestedLoopJoin" `Quick
            test_restrict_over_cross_product_translates_to_nested_loop_join;
          Alcotest.test_case
            "standalone Restrict over a base scan still becomes Filter" `Quick
            test_standalone_restrict_does_not_trigger_join_rewrite;
          Alcotest.test_case
            "standalone CrossProduct without an enclosing Restrict stays as \
             CrossProduct"
            `Quick test_standalone_cross_product_does_not_trigger_join_rewrite;
        ] );
    ]
