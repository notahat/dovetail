(** Tests for [Physical.kind_of] — the pure analyser that returns a physical
    plan's result kind without opening any cursors. *)

open Dovetail_plan
open Test_helpers

let users_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "active"; kind = Bool; qualifier = Some "users" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let orders_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
        { name = "amount"; kind = Int64; qualifier = Some "orders" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

(* A catalog stub that knows about [users] and [orders]. Any other table name
   returns [None], which [Physical.kind_of] reports as a failure. *)
let fixture_catalog = function
  | "users" -> Some users_kind
  | "orders" -> Some orders_kind
  | _ -> None

let kind_testable : Relation.kind Alcotest.testable =
  let format formatter kind = Relation.format_kind formatter kind in
  Alcotest.testable format ( = )

let test_full_scan_returns_table_kind () =
  let plan : Physical.t = FullScan { table = "users" } in
  Alcotest.(check kind_testable)
    "FullScan carries the table's catalog kind" users_kind
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_full_scan_unknown_table_raises () =
  let plan : Physical.t = FullScan { table = "ghost" } in
  Alcotest.check_raises "missing table"
    (Failure "Physical.kind_of: unknown table \"ghost\"") (fun () ->
      ignore (Physical.kind_of ~catalog:fixture_catalog plan))

let test_index_lookup_returns_table_kind () =
  let plan : Physical.t = IndexLookup { table = "users"; key = 1L } in
  Alcotest.(check kind_testable)
    "IndexLookup carries the table's catalog kind" users_kind
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_filter_passes_through_input_kind () =
  let plan : Physical.t =
    Filter
      {
        input = FullScan { table = "users" };
        predicate = expression_literal (Scalar.Bool true);
      }
  in
  Alcotest.(check kind_testable)
    "Filter preserves the input kind" users_kind
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_project_narrows_to_named_columns () =
  let plan : Physical.t =
    Project
      {
        input = FullScan { table = "users" };
        columns = [ column_reference "name"; column_reference "active" ];
      }
  in
  let expected : Relation.kind =
    {
      row_kind =
        [
          { name = "name"; kind = String; qualifier = Some "users" };
          { name = "active"; kind = Bool; qualifier = Some "users" };
        ];
      refinements = [];
    }
  in
  Alcotest.(check kind_testable)
    "Project narrows to the named columns and drops refinements" expected
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_cross_product_concatenates_row_kinds () =
  let plan : Physical.t =
    CrossProduct
      {
        left = FullScan { table = "users" };
        right = FullScan { table = "orders" };
      }
  in
  let expected : Relation.kind =
    { row_kind = users_kind.row_kind @ orders_kind.row_kind; refinements = [] }
  in
  Alcotest.(check kind_testable)
    "CrossProduct concatenates left.row_kind and right.row_kind" expected
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_nested_loop_join_concatenates_row_kinds () =
  let plan : Physical.t =
    NestedLoopJoin
      {
        left = FullScan { table = "users" };
        right = FullScan { table = "orders" };
        predicate = expression_literal (Scalar.Bool true);
      }
  in
  let expected : Relation.kind =
    { row_kind = users_kind.row_kind @ orders_kind.row_kind; refinements = [] }
  in
  Alcotest.(check kind_testable)
    "NestedLoopJoin matches CrossProduct's combined row_kind" expected
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_indexed_nested_loop_join_left_puts_inner_first () =
  let plan : Physical.t =
    IndexedNestedLoopJoin
      {
        outer = FullScan { table = "orders" };
        inner_table = "users";
        outer_key_column =
          qualified_column_reference ~qualifier:"orders" ~name:"user_id";
        inner_position = `Left;
      }
  in
  let expected : Relation.kind =
    { row_kind = users_kind.row_kind @ orders_kind.row_kind; refinements = [] }
  in
  Alcotest.(check kind_testable)
    "inner_position=`Left places the inner's fields before the outer's" expected
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_indexed_nested_loop_join_right_puts_outer_first () =
  let plan : Physical.t =
    IndexedNestedLoopJoin
      {
        outer = FullScan { table = "orders" };
        inner_table = "users";
        outer_key_column =
          qualified_column_reference ~qualifier:"orders" ~name:"user_id";
        inner_position = `Right;
      }
  in
  let expected : Relation.kind =
    { row_kind = orders_kind.row_kind @ users_kind.row_kind; refinements = [] }
  in
  Alcotest.(check kind_testable)
    "inner_position=`Right places the outer's fields before the inner's"
    expected
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_relation_literal_returns_declared_kind () =
  let kind : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      refinements = [];
    }
  in
  let plan : Physical.t =
    Relation_literal
      { kind; rows = [ [ Scalar.Int64 1L; Scalar.String "Alice" ] ] }
  in
  Alcotest.(check kind_testable)
    "Relation_literal returns the kind it was built with" kind
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_insert_returns_insert_count_kind () =
  let plan : Physical.t =
    Insert
      {
        table = "users";
        source =
          Relation_literal
            {
              kind =
                {
                  row_kind =
                    [
                      { name = "id"; kind = Int64; qualifier = None };
                      { name = "name"; kind = String; qualifier = None };
                      { name = "active"; kind = Bool; qualifier = None };
                    ];
                  refinements = [];
                };
              rows =
                [ [ Scalar.Int64 9L; Scalar.String "Eve"; Scalar.Bool true ] ];
            };
      }
  in
  let expected : Relation.kind =
    {
      row_kind = [ { name = "insert_count"; kind = Int64; qualifier = None } ];
      refinements = [];
    }
  in
  Alcotest.(check kind_testable)
    "Insert reports a one-column (insert_count : int64) result" expected
    (Physical.kind_of ~catalog:fixture_catalog plan)

let create_table_result_kind : Relation.kind =
  {
    row_kind = [ { name = "created"; kind = String; qualifier = None } ];
    refinements = [];
  }

let drop_table_result_kind : Relation.kind =
  {
    row_kind = [ { name = "dropped"; kind = String; qualifier = None } ];
    refinements = [];
  }

let test_drop_table_returns_dropped_kind () =
  let plan : Physical.t = Drop_table { table_name = "users" } in
  Alcotest.(check kind_testable)
    "Drop_table reports a one-column (dropped : string) result"
    drop_table_result_kind
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_create_table_empty_returns_created_kind () =
  let plan : Physical.t =
    Create_table_empty
      {
        table_name = "users";
        kind =
          {
            row_kind = [ { name = "id"; kind = Int64; qualifier = None } ];
            refinements = [ Primary_key [ "id" ] ];
          };
      }
  in
  Alcotest.(check kind_testable)
    "Create_table_empty reports a one-column (created : string) result"
    create_table_result_kind
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_create_table_seeded_returns_created_kind_not_source_kind () =
  (* The result kind is always the one-row (created : string) relation,
     regardless of the source's shape. Exercises a non-trivial source
     (FullScan over users) so a returned source kind would be visibly
     wrong. *)
  let plan : Physical.t =
    Create_table_seeded
      { table_name = "copy_of_users"; source = FullScan { table = "users" } }
  in
  Alcotest.(check kind_testable)
    "Create_table_seeded ignores source kind and reports (created : string)"
    create_table_result_kind
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_unqualify_strips_qualifiers_from_input_kind () =
  let plan : Physical.t = Unqualify { input = FullScan { table = "users" } } in
  let strip_qualifier (field : Dovetail_core.Row.field) =
    { field with qualifier = None }
  in
  let expected : Relation.kind =
    {
      row_kind = List.map strip_qualifier users_kind.row_kind;
      refinements = users_kind.refinements;
    }
  in
  Alcotest.(check kind_testable)
    "Unqualify drops the qualifier from every field of the input kind" expected
    (Physical.kind_of ~catalog:fixture_catalog plan)

let test_unqualify_rejects_collision_on_bare_name () =
  let plan : Physical.t =
    Unqualify
      {
        input =
          Project
            {
              input =
                CrossProduct
                  {
                    left = FullScan { table = "users" };
                    right = FullScan { table = "orders" };
                  };
              columns =
                [
                  qualified_column_reference ~qualifier:"users" ~name:"id";
                  qualified_column_reference ~qualifier:"orders" ~name:"id";
                ];
            };
      }
  in
  Alcotest.check_raises "Unqualify collision on bare \"id\""
    (Failure
       "Physical.kind_of: unqualify: collision on \"id\": fields \"users.id\" \
        and \"orders.id\"") (fun () ->
      ignore (Physical.kind_of ~catalog:fixture_catalog plan))

let test_type_op_raises_because_result_is_a_kind () =
  let plan : Physical.t = Type_op { input = FullScan { table = "users" } } in
  Alcotest.check_raises "Type_op has no relation kind"
    (Failure "Physical.kind_of: Type_op does not produce a relation kind")
    (fun () -> ignore (Physical.kind_of ~catalog:fixture_catalog plan))

let test_scalar_literal_raises_because_result_is_a_scalar () =
  let plan : Physical.t = Scalar_literal (Dovetail_core.Scalar.Int64 42L) in
  Alcotest.check_raises "Scalar_literal has no relation kind"
    (Failure "Physical.kind_of: Scalar_literal does not produce a relation kind")
    (fun () -> ignore (Physical.kind_of ~catalog:fixture_catalog plan))

let test_row_literal_raises_because_result_is_a_row () =
  let plan : Physical.t =
    Row_literal
      { fields = [ (column_reference "id", Dovetail_core.Scalar.Int64 1L) ] }
  in
  Alcotest.check_raises "Row_literal has no relation kind"
    (Failure "Physical.kind_of: Row_literal does not produce a relation kind")
    (fun () -> ignore (Physical.kind_of ~catalog:fixture_catalog plan))

let () =
  Alcotest.run "physical_kind_of"
    [
      ( "kind_of",
        [
          Alcotest.test_case "FullScan carries the table's catalog kind" `Quick
            test_full_scan_returns_table_kind;
          Alcotest.test_case "FullScan raises Failure when the table is missing"
            `Quick test_full_scan_unknown_table_raises;
          Alcotest.test_case "IndexLookup carries the table's catalog kind"
            `Quick test_index_lookup_returns_table_kind;
          Alcotest.test_case "Filter preserves the input kind" `Quick
            test_filter_passes_through_input_kind;
          Alcotest.test_case "Project narrows to the named columns" `Quick
            test_project_narrows_to_named_columns;
          Alcotest.test_case "CrossProduct concatenates row kinds" `Quick
            test_cross_product_concatenates_row_kinds;
          Alcotest.test_case "NestedLoopJoin concatenates row kinds" `Quick
            test_nested_loop_join_concatenates_row_kinds;
          Alcotest.test_case
            "IndexedNestedLoopJoin with `Left places inner first" `Quick
            test_indexed_nested_loop_join_left_puts_inner_first;
          Alcotest.test_case
            "IndexedNestedLoopJoin with `Right places outer first" `Quick
            test_indexed_nested_loop_join_right_puts_outer_first;
          Alcotest.test_case
            "Relation_literal returns the kind it was built with" `Quick
            test_relation_literal_returns_declared_kind;
          Alcotest.test_case
            "Insert reports a one-column (insert_count : int64) result" `Quick
            test_insert_returns_insert_count_kind;
          Alcotest.test_case "Type_op raises because its result is a kind"
            `Quick test_type_op_raises_because_result_is_a_kind;
          Alcotest.test_case
            "Scalar_literal raises because its result is a scalar" `Quick
            test_scalar_literal_raises_because_result_is_a_scalar;
          Alcotest.test_case "Row_literal raises because its result is a row"
            `Quick test_row_literal_raises_because_result_is_a_row;
          Alcotest.test_case "Unqualify strips qualifiers from the input kind"
            `Quick test_unqualify_strips_qualifiers_from_input_kind;
          Alcotest.test_case
            "Unqualify raises on bare-name collision after stripping" `Quick
            test_unqualify_rejects_collision_on_bare_name;
          Alcotest.test_case
            "Drop_table reports a one-column (dropped : string) result" `Quick
            test_drop_table_returns_dropped_kind;
          Alcotest.test_case
            "Create_table_empty reports a one-column (created : string) result"
            `Quick test_create_table_empty_returns_created_kind;
          Alcotest.test_case
            "Create_table_seeded reports (created : string), not source kind"
            `Quick test_create_table_seeded_returns_created_kind_not_source_kind;
        ] );
    ]
