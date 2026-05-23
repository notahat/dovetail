(** Tests for [Logical.classify] and [Logical.format] / [Logical.format_plan].

    [classify] reads the wrapper constructor off a [Logical.plan] and returns
    the transaction permission the REPL should open. The function has two arms
    and no inner inspection; the tests exercise both arms with minimal plans.

    The pretty-printer is intended for the [--show-logical] debug flag. Format
    tests pin down the rendering of each operator in isolation, plus a couple of
    nested combinations to confirm indentation composes the way readers will
    expect. They mirror the shape of [test_physical.ml]. *)

open Dovetail_plan
open Test_helpers
module Scalar = Dovetail_core.Scalar

let test_query_plan_classifies_as_read () =
  let plan : Logical.plan = Query (Scan { table = "users" }) in
  Alcotest.(check bool)
    "Query plan classifies as Read" true
    (Logical.classify plan = `Read)

let test_mutation_plan_classifies_as_write () =
  let plan : Logical.plan =
    Mutation
      (Insert
         {
           table = "orders";
           source =
             RelationLiteral
               { columns = [ "id" ]; rows = [ [ Scalar.Int64 7L ] ] };
         })
  in
  Alcotest.(check bool)
    "Mutation plan classifies as Write" true
    (Logical.classify plan = `Write)

let format_to_string plan =
  with_captured_formatter (fun formatter -> Logical.format formatter plan)

let format_plan_to_string plan =
  with_captured_formatter (fun formatter -> Logical.format_plan formatter plan)

let users_scan : Logical.t = Scan { table = "users" }
let orders_scan : Logical.t = Scan { table = "orders" }

let id_equals_three =
  expression_compare ~left:(expression_column "id") ~op:Equal
    ~right:(expression_literal (Scalar.Int64 3L))

let users_id_equals_orders_user_id =
  expression_compare
    ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
    ~op:Equal
    ~right:(expression_qualified_column ~qualifier:"orders" ~name:"user_id")

let test_scan_renders_with_table_name () =
  Alcotest.(check string)
    "Scan(users) on a single line" "Scan(users)\n"
    (format_to_string users_scan)

let test_restrict_renders_predicate_and_indents_input () =
  let plan : Logical.t =
    Restrict { input = users_scan; predicate = id_equals_three }
  in
  Alcotest.(check string)
    "Restrict wraps its input two spaces in" "Restrict(id = 3)\n  Scan(users)\n"
    (format_to_string plan)

let test_project_renders_columns_in_order () =
  let plan : Logical.t =
    Project
      {
        input = users_scan;
        columns = [ column_reference "name"; column_reference "email" ];
      }
  in
  Alcotest.(check string)
    "Project lists columns comma-separated"
    "Project(name, email)\n  Scan(users)\n" (format_to_string plan)

let test_cross_product_renders_both_inputs_indented () =
  let plan : Logical.t =
    CrossProduct { left = users_scan; right = orders_scan }
  in
  Alcotest.(check string)
    "CrossProduct lists left then right"
    "CrossProduct\n  Scan(users)\n  Scan(orders)\n" (format_to_string plan)

let test_relation_literal_renders_columns_and_row_count () =
  let plan : Logical.t =
    RelationLiteral
      {
        columns = [ "id"; "name" ];
        rows = [ [ Scalar.Int64 1L; Scalar.String "Alice" ] ];
      }
  in
  Alcotest.(check string)
    "RelationLiteral renders columns and row count on a single line"
    "RelationLiteral(columns=id, name, rows=1)\n" (format_to_string plan)

let test_nested_indentation_compounds () =
  (* A Restrict wrapping a CrossProduct: confirms that each level of nesting
     adds two spaces, not just the immediate one. Mirrors the matching test
     in [test_physical.ml]. *)
  let plan : Logical.t =
    Restrict
      {
        input = CrossProduct { left = users_scan; right = orders_scan };
        predicate = users_id_equals_orders_user_id;
      }
  in
  Alcotest.(check string)
    "indentation compounds across levels"
    "Restrict(users.id = orders.user_id)\n\
    \  CrossProduct\n\
    \    Scan(users)\n\
    \    Scan(orders)\n"
    (format_to_string plan)

let test_format_plan_query_renders_inner_tree_bare () =
  let plan : Logical.plan = Query users_scan in
  Alcotest.(check string)
    "Query renders its inner tree with no wrapping header" "Scan(users)\n"
    (format_plan_to_string plan)

let test_format_plan_mutation_renders_insert_header_with_indented_source () =
  let plan : Logical.plan =
    Mutation
      (Insert
         {
           table = "orders";
           source =
             RelationLiteral
               { columns = [ "id" ]; rows = [ [ Scalar.Int64 7L ] ] };
         })
  in
  Alcotest.(check string)
    "Mutation prints Insert(table) with its source indented one level"
    "Insert(orders)\n  RelationLiteral(columns=id, rows=1)\n"
    (format_plan_to_string plan)

let () =
  Alcotest.run "logical"
    [
      ( "classify",
        [
          Alcotest.test_case "Query plan classifies as Read" `Quick
            test_query_plan_classifies_as_read;
          Alcotest.test_case "Mutation plan classifies as Write" `Quick
            test_mutation_plan_classifies_as_write;
        ] );
      ( "format",
        [
          Alcotest.test_case "Scan renders with table name" `Quick
            test_scan_renders_with_table_name;
          Alcotest.test_case "Restrict renders predicate and indents input"
            `Quick test_restrict_renders_predicate_and_indents_input;
          Alcotest.test_case "Project renders columns in order" `Quick
            test_project_renders_columns_in_order;
          Alcotest.test_case "CrossProduct renders both inputs indented" `Quick
            test_cross_product_renders_both_inputs_indented;
          Alcotest.test_case "RelationLiteral renders columns and row count"
            `Quick test_relation_literal_renders_columns_and_row_count;
          Alcotest.test_case "nested indentation compounds across levels" `Quick
            test_nested_indentation_compounds;
          Alcotest.test_case "format_plan on a Query renders the inner tree"
            `Quick test_format_plan_query_renders_inner_tree_bare;
          Alcotest.test_case
            "format_plan on a Mutation prints Insert with indented source"
            `Quick
            test_format_plan_mutation_renders_insert_header_with_indented_source;
        ] );
    ]
