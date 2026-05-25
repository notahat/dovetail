(** Tests for [Logical.required_access] and [Logical.format].

    [required_access] walks a [Logical.t] and reports the strongest transaction
    permission any operator in it needs. Every relation-yielding operator is
    read-only; [Insert] is the one that reports [`Write]. Tests exercise
    representative trees with and without [Insert].

    The pretty-printer is intended for the [--show-logical] debug flag. Format
    tests pin down the rendering of each operator in isolation, plus a couple of
    nested combinations to confirm indentation composes the way readers will
    expect. They mirror the shape of [test_physical.ml]. *)

open Dovetail_plan
open Test_helpers
module Scalar = Dovetail_core.Scalar

let test_scan_requires_read_access () =
  let plan : Logical.t = Scan { table = "users" } in
  Alcotest.(check bool)
    "Scan requires Read access" true
    (Logical.required_access plan = `Read)

let test_restrict_over_scan_requires_read_access () =
  let predicate =
    expression_compare ~left:(expression_column "id") ~op:Equal
      ~right:(expression_literal (Scalar.Int64 1L))
  in
  let plan : Logical.t =
    Restrict { input = Scan { table = "users" }; predicate }
  in
  Alcotest.(check bool)
    "Restrict over Scan requires Read access" true
    (Logical.required_access plan = `Read)

let test_cross_product_of_scans_requires_read_access () =
  let plan : Logical.t =
    CrossProduct
      { left = Scan { table = "users" }; right = Scan { table = "orders" } }
  in
  Alcotest.(check bool)
    "CrossProduct of two Scans requires Read access" true
    (Logical.required_access plan = `Read)

let test_insert_requires_write_access () =
  let plan : Logical.t =
    Insert
      {
        table = "orders";
        source =
          Relation_literal
            {
              kind =
                {
                  row_kind = [ { name = "id"; kind = Int64; qualifier = None } ];
                  refinements = [];
                };
              rows = [ [ Scalar.Int64 7L ] ];
            };
      }
  in
  Alcotest.(check bool)
    "Insert requires Write access" true
    (Logical.required_access plan = `Write)

let test_type_op_required_access_passes_through () =
  let plan : Logical.t = Type_op { input = Scan { table = "users" } } in
  Alcotest.(check bool)
    "Type_op over a read-only input is read-only" true
    (Logical.required_access plan = `Read)

let test_scalar_literal_requires_read_access () =
  let plan : Logical.t = Scalar_literal (Scalar.Int64 42L) in
  Alcotest.(check bool)
    "Scalar_literal requires Read access" true
    (Logical.required_access plan = `Read)

let format_to_string plan =
  with_captured_formatter (fun formatter -> Logical.format formatter plan)

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
    Relation_literal
      {
        kind =
          {
            row_kind =
              [
                { name = "id"; kind = Int64; qualifier = None };
                { name = "name"; kind = String; qualifier = None };
              ];
            refinements = [];
          };
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

let test_type_op_renders_header_with_indented_input () =
  let plan : Logical.t = Type_op { input = users_scan } in
  Alcotest.(check string)
    "Type prints a bare header with its input indented one level"
    "Type\n  Scan(users)\n" (format_to_string plan)

let test_scalar_literal_renders_value () =
  let int_plan : Logical.t = Scalar_literal (Scalar.Int64 42L) in
  Alcotest.(check string)
    "Int64 scalar literal renders bare digits" "ScalarLiteral(42)\n"
    (format_to_string int_plan);
  let string_plan : Logical.t = Scalar_literal (Scalar.String "hi") in
  Alcotest.(check string)
    "String scalar literal renders quoted" "ScalarLiteral(\"hi\")\n"
    (format_to_string string_plan);
  let bool_plan : Logical.t = Scalar_literal (Scalar.Bool true) in
  Alcotest.(check string)
    "Bool scalar literal renders as keyword" "ScalarLiteral(true)\n"
    (format_to_string bool_plan)

let test_row_literal_requires_read_access () =
  let plan : Logical.t =
    Row_literal { fields = [ (column_reference "id", Scalar.Int64 1L) ] }
  in
  Alcotest.(check bool)
    "Row_literal requires Read access" true
    (Logical.required_access plan = `Read)

let test_row_literal_renders_fields () =
  let plan : Logical.t =
    Row_literal
      {
        fields =
          [
            (column_reference "id", Scalar.Int64 1L);
            (column_reference "name", Scalar.String "alice");
          ];
      }
  in
  Alcotest.(check string)
    "Row_literal lists fields comma-separated"
    "RowLiteral(id=1, name=\"alice\")\n" (format_to_string plan);
  let empty_plan : Logical.t = Row_literal { fields = [] } in
  Alcotest.(check string)
    "Empty Row_literal renders with no inner content" "RowLiteral()\n"
    (format_to_string empty_plan)

let test_insert_renders_header_with_indented_source () =
  let plan : Logical.t =
    Insert
      {
        table = "orders";
        source =
          Relation_literal
            {
              kind =
                {
                  row_kind = [ { name = "id"; kind = Int64; qualifier = None } ];
                  refinements = [];
                };
              rows = [ [ Scalar.Int64 7L ] ];
            };
      }
  in
  Alcotest.(check string)
    "Insert prints Insert(table) with its source indented one level"
    "Insert(orders)\n  RelationLiteral(columns=id, rows=1)\n"
    (format_to_string plan)

let () =
  Alcotest.run "logical"
    [
      ( "required_access",
        [
          Alcotest.test_case "Scan requires Read access" `Quick
            test_scan_requires_read_access;
          Alcotest.test_case "Restrict over Scan requires Read access" `Quick
            test_restrict_over_scan_requires_read_access;
          Alcotest.test_case "CrossProduct of two Scans requires Read access"
            `Quick test_cross_product_of_scans_requires_read_access;
          Alcotest.test_case "Insert requires Write access" `Quick
            test_insert_requires_write_access;
          Alcotest.test_case "Type_op required_access passes through input"
            `Quick test_type_op_required_access_passes_through;
          Alcotest.test_case "Scalar_literal requires Read access" `Quick
            test_scalar_literal_requires_read_access;
          Alcotest.test_case "Row_literal requires Read access" `Quick
            test_row_literal_requires_read_access;
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
          Alcotest.test_case "Insert prints header with indented source" `Quick
            test_insert_renders_header_with_indented_source;
          Alcotest.test_case "Type renders header with indented input" `Quick
            test_type_op_renders_header_with_indented_input;
          Alcotest.test_case "ScalarLiteral renders its value inline" `Quick
            test_scalar_literal_renders_value;
          Alcotest.test_case "RowLiteral renders fields comma-separated" `Quick
            test_row_literal_renders_fields;
        ] );
    ]
