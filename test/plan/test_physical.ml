(** Tests for [Physical.format].

    The pretty-printer is intended for the [--show-physical] debug flag and any
    future EXPLAIN-style output. Tests pin down the rendering of each operator
    in isolation, plus a couple of nested combinations to confirm indentation
    composes the way readers will expect. *)

open Dovetail_core
open Dovetail_plan
open Test_helpers

let format_to_string plan =
  let buffer = Buffer.create 128 in
  let formatter = Format.formatter_of_buffer buffer in
  Physical.format formatter plan;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let users_full_scan : Physical.t = FullScan { table = "users" }
let orders_full_scan : Physical.t = FullScan { table = "orders" }

let id_equals_three =
  expression_compare ~left:(expression_column "id") ~op:Equal
    ~right:(expression_literal (Value.Int64 3L))

let users_id_equals_orders_user_id =
  expression_compare
    ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
    ~op:Equal
    ~right:(expression_qualified_column ~qualifier:"orders" ~name:"user_id")

let test_full_scan_renders_with_table_name () =
  Alcotest.(check string)
    "FullScan(users) on a single line" "FullScan(users)\n"
    (format_to_string users_full_scan)

let test_filter_renders_predicate_and_indents_input () =
  let plan : Physical.t =
    Filter { input = users_full_scan; predicate = id_equals_three }
  in
  Alcotest.(check string)
    "Filter wraps its input two spaces in" "Filter(id = 3)\n  FullScan(users)\n"
    (format_to_string plan)

let test_project_renders_columns_in_order () =
  let plan : Physical.t =
    Project
      {
        input = users_full_scan;
        columns = [ column_reference "name"; column_reference "email" ];
      }
  in
  Alcotest.(check string)
    "Project lists columns comma-separated"
    "Project(name, email)\n  FullScan(users)\n" (format_to_string plan)

let test_cross_product_renders_both_inputs_indented () =
  let plan : Physical.t =
    CrossProduct { left = users_full_scan; right = orders_full_scan }
  in
  Alcotest.(check string)
    "CrossProduct lists left then right"
    "CrossProduct\n  FullScan(users)\n  FullScan(orders)\n"
    (format_to_string plan)

let test_nested_loop_join_renders_predicate_and_both_inputs () =
  let plan : Physical.t =
    NestedLoopJoin
      {
        left = users_full_scan;
        right = orders_full_scan;
        predicate = users_id_equals_orders_user_id;
      }
  in
  Alcotest.(check string)
    "NestedLoopJoin renders predicate then both inputs"
    "NestedLoopJoin(users.id = orders.user_id)\n\
    \  FullScan(users)\n\
    \  FullScan(orders)\n"
    (format_to_string plan)

let test_index_lookup_renders_with_table_and_key () =
  let plan : Physical.t = IndexLookup { table = "users"; key = 3L } in
  Alcotest.(check string)
    "IndexLookup renders table and key on a single line"
    "IndexLookup(users, key=3)\n" (format_to_string plan)

let test_indexed_nested_loop_join_renders_with_inner_position_left () =
  let plan : Physical.t =
    IndexedNestedLoopJoin
      {
        outer = orders_full_scan;
        inner_table = "users";
        outer_key_column =
          qualified_column_reference ~qualifier:"orders" ~name:"user_id";
        inner_position = `Left;
      }
  in
  Alcotest.(check string)
    "IndexedNestedLoopJoin renders header fields and indents outer"
    "IndexedNestedLoopJoin(inner=users, outer_key=orders.user_id, \
     inner_position=Left)\n\
    \  FullScan(orders)\n"
    (format_to_string plan)

let test_indexed_nested_loop_join_renders_with_inner_position_right () =
  let plan : Physical.t =
    IndexedNestedLoopJoin
      {
        outer = orders_full_scan;
        inner_table = "users";
        outer_key_column =
          qualified_column_reference ~qualifier:"orders" ~name:"user_id";
        inner_position = `Right;
      }
  in
  Alcotest.(check string)
    "IndexedNestedLoopJoin renders inner_position=Right"
    "IndexedNestedLoopJoin(inner=users, outer_key=orders.user_id, \
     inner_position=Right)\n\
    \  FullScan(orders)\n"
    (format_to_string plan)

let test_nested_indentation_compounds () =
  (* A Filter wrapping a CrossProduct: confirms that each level of nesting
     adds two spaces, not just the immediate one. *)
  let plan : Physical.t =
    Filter
      {
        input =
          CrossProduct { left = users_full_scan; right = orders_full_scan };
        predicate = id_equals_three;
      }
  in
  Alcotest.(check string)
    "indentation compounds across levels"
    "Filter(id = 3)\n\
    \  CrossProduct\n\
    \    FullScan(users)\n\
    \    FullScan(orders)\n"
    (format_to_string plan)

let () =
  Alcotest.run "physical"
    [
      ( "format",
        [
          Alcotest.test_case "FullScan renders with table name" `Quick
            test_full_scan_renders_with_table_name;
          Alcotest.test_case "Filter renders predicate and indents input" `Quick
            test_filter_renders_predicate_and_indents_input;
          Alcotest.test_case "Project renders columns in order" `Quick
            test_project_renders_columns_in_order;
          Alcotest.test_case "CrossProduct renders both inputs indented" `Quick
            test_cross_product_renders_both_inputs_indented;
          Alcotest.test_case "NestedLoopJoin renders predicate and both inputs"
            `Quick test_nested_loop_join_renders_predicate_and_both_inputs;
          Alcotest.test_case "IndexLookup renders table and key" `Quick
            test_index_lookup_renders_with_table_and_key;
          Alcotest.test_case
            "IndexedNestedLoopJoin renders with inner_position=Left" `Quick
            test_indexed_nested_loop_join_renders_with_inner_position_left;
          Alcotest.test_case
            "IndexedNestedLoopJoin renders with inner_position=Right" `Quick
            test_indexed_nested_loop_join_renders_with_inner_position_right;
          Alcotest.test_case "nested indentation compounds across levels" `Quick
            test_nested_indentation_compounds;
        ] );
    ]
