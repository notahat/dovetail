(** Tests for [Lower]. *)

open Dovetail_surface_ra
open Test_helpers
module Execution = Dovetail_execution
module Plan = Dovetail_plan
module Storage = Dovetail_storage
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

let logical_testable : Plan.Logical.t Alcotest.testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<logical-plan>")) ( = )

let test_relation_name_lowers_to_scan () =
  let ast = Ast.Relation_name "users" in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Relation_name -> Scan"
    (Scan { table = "users" })
    logical

let test_pipeline_yields_fixture_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast = Ast.Relation_name "users" in
      let logical = Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical
        (expect_relation (fun relation ->
             let rows = List.of_seq relation.value in
             Alcotest.(check row_list_testable)
               "five rows from AST" expected_users_rows rows)))

let id_equals_three_ast =
  ast_expression_compare
    ~left:(ast_expression_column "id")
    ~op:Equal
    ~right:(ast_expression_literal (Scalar.Int64 3L))

let id_equals_three = Lower.lower_expression id_equals_three_ast

let test_restrict_lowers_to_logical_restrict () =
  let ast =
    Ast.Restrict
      { input = Ast.Relation_name "users"; predicate = id_equals_three_ast }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Restrict -> Logical.Restrict wrapping Scan"
    (Restrict { input = Scan { table = "users" }; predicate = id_equals_three })
    logical

let test_restrict_pipeline_yields_filtered_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        Ast.Restrict
          { input = Ast.Relation_name "users"; predicate = id_equals_three_ast }
      in
      let logical = Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical
        (expect_relation (fun relation ->
             let rows = List.of_seq relation.value in
             Alcotest.(check row_list_testable)
               "Carol's row from Ast.Restrict"
               [ List.nth expected_users_rows 2 ]
               rows)))

let name_then_email_ast : Ast.projection =
  [ column_reference "name"; column_reference "email" ]

let name_then_email : Plan.Projection.t =
  Lower.lower_projection name_then_email_ast

let test_project_lowers_to_logical_project () =
  let ast =
    Ast.Project
      { input = Ast.Relation_name "users"; columns = name_then_email_ast }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Project -> Logical.Project wrapping Scan"
    (Project { input = Scan { table = "users" }; columns = name_then_email })
    logical

let test_project_pipeline_yields_projected_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        Ast.Project
          { input = Ast.Relation_name "users"; columns = name_then_email_ast }
      in
      let logical = Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical
        (expect_relation (fun relation ->
             let rows = List.of_seq relation.value in
             let expected =
               [
                 [| Scalar.String "Alice"; Scalar.String "alice@example.com" |];
                 [| Scalar.String "Bob"; Scalar.String "bob@example.com" |];
                 [| Scalar.String "Carol"; Scalar.String "carol@example.com" |];
                 [| Scalar.String "Dave"; Scalar.String "dave@example.com" |];
                 [| Scalar.String "Eve"; Scalar.String "eve@example.com" |];
               ]
             in
             Alcotest.(check row_list_testable)
               "five projected rows from Ast.Project" expected rows)))

let test_cross_product_lowers_to_logical_cross_product () =
  let ast =
    Ast.CrossProduct
      { left = Ast.Relation_name "users"; right = Ast.Relation_name "orders" }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.CrossProduct -> Logical.CrossProduct wrapping Scans"
    (CrossProduct
       { left = Scan { table = "users" }; right = Scan { table = "orders" } })
    logical

let users_id_equals_orders_user_id_ast =
  ast_expression_compare
    ~left:(ast_expression_qualified_column ~qualifier:"users" ~name:"id")
    ~op:Equal
    ~right:(ast_expression_qualified_column ~qualifier:"orders" ~name:"user_id")

let users_id_equals_orders_user_id =
  Lower.lower_expression users_id_equals_orders_user_id_ast

let test_join_lowers_to_restrict_over_cross_product () =
  let ast =
    Ast.Join
      {
        left = Ast.Relation_name "users";
        right = Ast.Relation_name "orders";
        predicate = users_id_equals_orders_user_id_ast;
      }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Join -> Logical.Restrict wrapping Logical.CrossProduct"
    (Restrict
       {
         input =
           CrossProduct
             {
               left = Scan { table = "users" };
               right = Scan { table = "orders" };
             };
         predicate = users_id_equals_orders_user_id;
       })
    logical

let test_insert_mutation_lowers_through () =
  let relation_type : Ast.type_expression =
    {
      fields =
        [
          { qualifier = None; name = "id"; kind = Int64 };
          { qualifier = None; name = "user_id"; kind = Int64 };
          { qualifier = None; name = "description"; kind = String };
          { qualifier = None; name = "amount"; kind = Int64 };
        ];
      refinements = [];
    }
  in
  let kind = Lower.lower_relation_type relation_type in
  let source : Ast.t =
    Relation_literal
      {
        relation_type;
        rows =
          [
            [
              (column_reference "id", Scalar.Int64 9L);
              (column_reference "user_id", Scalar.Int64 1L);
              (column_reference "description", Scalar.String "Pretzel");
              (column_reference "amount", Scalar.Int64 9L);
            ];
          ];
      }
  in
  let plan : Ast.t = Insert { source; table = "orders" } in
  let logical = Lower.lower plan in
  Alcotest.(check logical_testable)
    "Ast.Insert -> Logical.Insert with the source lowered"
    (Insert
       {
         table = "orders";
         source =
           Relation_literal
             {
               kind;
               rows =
                 [
                   [
                     Scalar.Int64 9L;
                     Scalar.Int64 1L;
                     Scalar.String "Pretzel";
                     Scalar.Int64 9L;
                   ];
                 ];
             };
       })
    logical

let test_insert_mutation_lowers_relational_source () =
  (* A non-literal source -- a scan with an upstream restrict -- lowers
     through the same way the [Query] arm would: Insert's [source] field
     carries the lowered relation tree. Validation that the source is
     literal-only is Translate's job, not Lower's. *)
  let source : Ast.t =
    Restrict
      {
        input = Relation_name "orders";
        predicate =
          ast_expression_compare
            ~left:(ast_expression_column "id")
            ~op:Equal
            ~right:(ast_expression_literal (Scalar.Int64 1L));
      }
  in
  let plan : Ast.t = Insert { source; table = "orders" } in
  let logical = Lower.lower plan in
  Alcotest.(check logical_testable)
    "Insert source's relation tree is lowered in place"
    (Insert
       {
         table = "orders";
         source =
           Restrict
             {
               input = Scan { table = "orders" };
               predicate =
                 expression_compare ~left:(expression_column "id") ~op:Equal
                   ~right:(expression_literal (Scalar.Int64 1L));
             };
       })
    logical

let test_type_lowers_to_type_op () =
  let ast = Ast.Type { input = Ast.Relation_name "users" } in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Type -> Logical.Type_op wrapping the lowered input"
    (Type_op { input = Scan { table = "users" } })
    logical

let test_unqualify_lowers_through () =
  let ast = Ast.Unqualify { input = Ast.Relation_name "users" } in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Unqualify -> Logical.Unqualify wrapping the lowered input"
    (Unqualify { input = Scan { table = "users" } })
    logical

let test_catalog_source_lowers_through () =
  let logical = Lower.lower Ast.Catalog_source in
  Alcotest.(check logical_testable)
    "Ast.Catalog_source -> Logical.Catalog_source" Catalog_source logical

let test_tables_lowers_through () =
  let logical = Lower.lower (Ast.Tables { input = Ast.Catalog_source }) in
  Alcotest.(check logical_testable)
    "Ast.Tables -> Logical.Tables with the lowered input"
    (Tables { input = Catalog_source })
    logical

let test_drop_table_lowers_through () =
  let ast = Ast.Drop_table { table_name = "users" } in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Drop_table -> Logical.Drop_table with the same name"
    (Drop_table { table_name = "users" })
    logical

let test_create_table_empty_lowers_type_expression_to_relation_kind () =
  let type_expression : Ast.type_expression =
    {
      fields =
        [
          { qualifier = None; name = "id"; kind = Int64 };
          { qualifier = None; name = "name"; kind = String };
        ];
      refinements = [ Ast.Primary_key [ column_reference "id" ] ];
    }
  in
  let ast = Ast.Create_table_empty { table_name = "users"; type_expression } in
  let logical = Lower.lower ast in
  let expected_kind : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      refinements = [ Primary_key [ "id" ] ];
    }
  in
  Alcotest.(check logical_testable)
    "Ast.Create_table_empty -> Logical.Create_table_empty with kind resolved \
     via lower_relation_type"
    (Create_table_empty { table_name = "users"; kind = expected_kind })
    logical

let test_create_table_seeded_recurses_into_source () =
  let ast =
    Ast.Create_table_seeded
      { table_name = "users"; source = Ast.Relation_name "other" }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Create_table_seeded -> Logical.Create_table_seeded with source lowered"
    (Create_table_seeded
       { table_name = "users"; source = Scan { table = "other" } })
    logical

let test_type_over_type_is_rejected () =
  let ast =
    Ast.Type { input = Ast.Type { input = Ast.Relation_name "users" } }
  in
  Alcotest.check_raises "type applied to a type is rejected at Lower"
    (Failure "type: input is already a type") (fun () ->
      ignore (Lower.lower ast))

(* Compare row kinds and relation kinds structurally; the formatters render
   them in surface syntax when a test fails. *)
let row_kind_testable : Row.kind Alcotest.testable =
  Alcotest.testable Row.format_kind ( = )

let relation_kind_testable : Relation.kind Alcotest.testable =
  Alcotest.testable Relation.format_kind ( = )

let type_field name (kind : Scalar.kind) : Ast.type_field =
  { qualifier = None; name; kind }

let test_lower_row_type_empty_is_empty_kind () =
  let type_expression : Ast.type_expression =
    { fields = []; refinements = [] }
  in
  Alcotest.(check row_kind_testable)
    "empty row type" []
    (Lower.lower_row_type type_expression)

let test_lower_row_type_drops_no_fields_and_sets_qualifier_to_none () =
  let type_expression : Ast.type_expression =
    {
      fields =
        [
          type_field "id" Int64;
          type_field "name" String;
          type_field "active" Bool;
        ];
      refinements = [];
    }
  in
  let expected : Row.kind =
    [
      { name = "id"; kind = Int64; qualifier = None };
      { name = "name"; kind = String; qualifier = None };
      { name = "active"; kind = Bool; qualifier = None };
    ]
  in
  Alcotest.(check row_kind_testable)
    "fields preserved in order, qualifier None" expected
    (Lower.lower_row_type type_expression)

let test_lower_relation_type_empty_is_empty_kind () =
  let type_expression : Ast.type_expression =
    { fields = []; refinements = [] }
  in
  Alcotest.(check relation_kind_testable)
    "empty relation type"
    { row_kind = []; refinements = [] }
    (Lower.lower_relation_type type_expression)

let test_lower_relation_type_without_refinements () =
  let type_expression : Ast.type_expression =
    {
      fields = [ type_field "id" Int64; type_field "name" String ];
      refinements = [];
    }
  in
  let expected : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      refinements = [];
    }
  in
  Alcotest.(check relation_kind_testable)
    "fields lowered, refinements empty" expected
    (Lower.lower_relation_type type_expression)

let test_lower_relation_type_with_single_column_primary_key () =
  let type_expression : Ast.type_expression =
    {
      fields = [ type_field "id" Int64; type_field "name" String ];
      refinements = [ Ast.Primary_key [ column_reference "id" ] ];
    }
  in
  let expected : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      refinements = [ Primary_key [ "id" ] ];
    }
  in
  Alcotest.(check relation_kind_testable)
    "single-column PK preserved" expected
    (Lower.lower_relation_type type_expression)

let test_lower_relation_type_with_compound_primary_key () =
  let type_expression : Ast.type_expression =
    {
      fields =
        [
          type_field "user_id" Int64;
          type_field "order_id" Int64;
          type_field "qty" Int64;
        ];
      refinements =
        [
          Ast.Primary_key
            [ column_reference "user_id"; column_reference "order_id" ];
        ];
    }
  in
  let expected : Relation.kind =
    {
      row_kind =
        [
          { name = "user_id"; kind = Int64; qualifier = None };
          { name = "order_id"; kind = Int64; qualifier = None };
          { name = "qty"; kind = Int64; qualifier = None };
        ];
      refinements = [ Primary_key [ "user_id"; "order_id" ] ];
    }
  in
  Alcotest.(check relation_kind_testable)
    "compound PK preserved" expected
    (Lower.lower_relation_type type_expression)

let test_scalar_literal_lowers_through () =
  let ast : Ast.t = Scalar_literal (Scalar.Int64 42L) in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Scalar_literal -> Logical.Scalar_literal with same value"
    (Scalar_literal (Scalar.Int64 42L)) logical

let test_row_literal_lowers_through () =
  let ast_fields =
    [
      (column_reference "id", Scalar.Int64 1L);
      (column_reference "name", Scalar.String "alice");
    ]
  in
  let logical_fields =
    [
      (row_column_reference "id", Scalar.Int64 1L);
      (row_column_reference "name", Scalar.String "alice");
    ]
  in
  let ast : Ast.t = Row_literal ast_fields in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Row_literal -> Logical.Row_literal with same fields"
    (Row_literal { fields = logical_fields })
    logical

let users_type : Ast.type_expression =
  {
    fields =
      [
        { qualifier = None; name = "id"; kind = Int64 };
        { qualifier = None; name = "name"; kind = String };
      ];
    refinements = [];
  }

let users_kind : Relation.kind = Lower.lower_relation_type users_type

let test_relation_literal_typed_lowers_to_relation_literal_typed () =
  let ast : Ast.t =
    Relation_literal
      {
        relation_type = users_type;
        rows =
          [
            [
              (column_reference "id", Scalar.Int64 1L);
              (column_reference "name", Scalar.String "alice");
            ];
            [
              (column_reference "id", Scalar.Int64 2L);
              (column_reference "name", Scalar.String "bob");
            ];
          ];
      }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "typed relation literal lowers to Logical.Relation_literal with the \
     declared kind"
    (Relation_literal
       {
         kind = users_kind;
         rows =
           [
             [ Scalar.Int64 1L; Scalar.String "alice" ];
             [ Scalar.Int64 2L; Scalar.String "bob" ];
           ];
       })
    logical

let test_relation_literal_typed_reorders_row_fields_to_kind_order () =
  let ast : Ast.t =
    Relation_literal
      {
        relation_type = users_type;
        rows =
          [
            (* Fields appear in reverse order from the kind; Lower reorders
               them to match the kind so the logical-plan row aligns with
               [kind.row_kind]. *)
            [
              (column_reference "name", Scalar.String "alice");
              (column_reference "id", Scalar.Int64 1L);
            ];
          ];
      }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "row values land in kind order"
    (Relation_literal
       {
         kind = users_kind;
         rows = [ [ Scalar.Int64 1L; Scalar.String "alice" ] ];
       })
    logical

let test_relation_literal_typed_rejects_extra_field_in_row () =
  let ast : Ast.t =
    Relation_literal
      {
        relation_type = users_type;
        rows =
          [
            [
              (column_reference "id", Scalar.Int64 1L);
              (column_reference "name", Scalar.String "alice");
              (column_reference "extra", Scalar.Bool true);
            ];
          ];
      }
  in
  Alcotest.check_raises "row with an unexpected field is rejected"
    (Failure "Lower: relation literal: unexpected field \"extra\"") (fun () ->
      ignore (Lower.lower ast))

let test_relation_literal_typed_rejects_missing_field_in_row () =
  let ast : Ast.t =
    Relation_literal
      {
        relation_type = users_type;
        rows = [ [ (column_reference "id", Scalar.Int64 1L) ] ];
      }
  in
  Alcotest.check_raises "row missing a declared field is rejected"
    (Failure "Lower: relation literal: missing field \"name\"") (fun () ->
      ignore (Lower.lower ast))

let test_relation_literal_typed_rejects_kind_mismatch () =
  let ast : Ast.t =
    Relation_literal
      {
        relation_type = users_type;
        rows =
          [
            [
              (column_reference "id", Scalar.String "wrong");
              (column_reference "name", Scalar.String "alice");
            ];
          ];
      }
  in
  Alcotest.check_raises "row with a kind mismatch is rejected"
    (Failure
       "Lower: relation literal: field \"id\" expected int64 but got string")
    (fun () -> ignore (Lower.lower ast))

let test_relation_literal_typed_empty_rows_lowers_to_empty_rows () =
  let ast : Ast.t =
    Relation_literal { relation_type = users_type; rows = [] }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "empty rows preserves the kind and yields an empty row list"
    (Relation_literal { kind = users_kind; rows = [] })
    logical

let () =
  Alcotest.run "lower"
    [
      ( "relation_name",
        [
          Alcotest.test_case "lowers Ast.Relation_name to Logical.Scan" `Quick
            test_relation_name_lowers_to_scan;
          Alcotest.test_case
            "AST, lowered, translated and evaluated, yields fixture rows" `Quick
            test_pipeline_yields_fixture_rows;
        ] );
      ( "restrict",
        [
          Alcotest.test_case "lowers Ast.Restrict to Logical.Restrict" `Quick
            test_restrict_lowers_to_logical_restrict;
          Alcotest.test_case
            "Ast.Restrict, lowered/translated/evaluated, yields filtered rows"
            `Quick test_restrict_pipeline_yields_filtered_rows;
        ] );
      ( "project",
        [
          Alcotest.test_case "lowers Ast.Project to Logical.Project" `Quick
            test_project_lowers_to_logical_project;
          Alcotest.test_case
            "Ast.Project, lowered/translated/evaluated, yields projected rows"
            `Quick test_project_pipeline_yields_projected_rows;
        ] );
      ( "cross product",
        [
          Alcotest.test_case "lowers Ast.CrossProduct to Logical.CrossProduct"
            `Quick test_cross_product_lowers_to_logical_cross_product;
        ] );
      ( "join",
        [
          Alcotest.test_case
            "lowers Ast.Join to Logical.Restrict over Logical.CrossProduct"
            `Quick test_join_lowers_to_restrict_over_cross_product;
        ] );
      ( "relation literal",
        [
          Alcotest.test_case
            "lowers Ast.Relation_literal to Logical.Relation_literal" `Quick
            test_relation_literal_typed_lowers_to_relation_literal_typed;
          Alcotest.test_case "reorders row values into the kind's field order"
            `Quick test_relation_literal_typed_reorders_row_fields_to_kind_order;
          Alcotest.test_case "rejects a row whose fields include an extra"
            `Quick test_relation_literal_typed_rejects_extra_field_in_row;
          Alcotest.test_case "rejects a row missing a declared field" `Quick
            test_relation_literal_typed_rejects_missing_field_in_row;
          Alcotest.test_case
            "rejects a row whose value kind doesn't match the declared kind"
            `Quick test_relation_literal_typed_rejects_kind_mismatch;
          Alcotest.test_case "empty rows yields an empty RelationLiteral" `Quick
            test_relation_literal_typed_empty_rows_lowers_to_empty_rows;
        ] );
      ( "scalar literal",
        [
          Alcotest.test_case
            "lowers Ast.Scalar_literal to Logical.Scalar_literal" `Quick
            test_scalar_literal_lowers_through;
        ] );
      ( "row literal",
        [
          Alcotest.test_case "lowers Ast.Row_literal to Logical.Row_literal"
            `Quick test_row_literal_lowers_through;
        ] );
      ( "type",
        [
          Alcotest.test_case "lowers Ast.Type to Logical.Type_op" `Quick
            test_type_lowers_to_type_op;
          Alcotest.test_case "rejects Ast.Type applied to Ast.Type" `Quick
            test_type_over_type_is_rejected;
        ] );
      ( "unqualify",
        [
          Alcotest.test_case "lowers Ast.Unqualify to Logical.Unqualify" `Quick
            test_unqualify_lowers_through;
        ] );
      ( "catalog source",
        [
          Alcotest.test_case
            "lowers Ast.Catalog_source to Logical.Catalog_source" `Quick
            test_catalog_source_lowers_through;
          Alcotest.test_case
            "lowers Ast.Tables to Logical.Tables, recursing into input" `Quick
            test_tables_lowers_through;
        ] );
      ( "create / drop table",
        [
          Alcotest.test_case "lowers Ast.Drop_table to Logical.Drop_table"
            `Quick test_drop_table_lowers_through;
          Alcotest.test_case
            "lowers Ast.Create_table_empty, resolving its type expression to a \
             relation kind"
            `Quick
            test_create_table_empty_lowers_type_expression_to_relation_kind;
          Alcotest.test_case
            "lowers Ast.Create_table_seeded, recursing into its source" `Quick
            test_create_table_seeded_recurses_into_source;
        ] );
      ( "insert mutation",
        [
          Alcotest.test_case
            "lowers Ast.Insert to Logical.Insert and lowers the source" `Quick
            test_insert_mutation_lowers_through;
          Alcotest.test_case
            "lowers a relational source inside Insert through the same path"
            `Quick test_insert_mutation_lowers_relational_source;
        ] );
      ( "lower_row_type",
        [
          Alcotest.test_case "empty type expression yields the empty row kind"
            `Quick test_lower_row_type_empty_is_empty_kind;
          Alcotest.test_case
            "fields lower in order and pick up qualifier = None" `Quick
            test_lower_row_type_drops_no_fields_and_sets_qualifier_to_none;
        ] );
      ( "lower_relation_type",
        [
          Alcotest.test_case
            "empty type expression yields the empty relation kind" `Quick
            test_lower_relation_type_empty_is_empty_kind;
          Alcotest.test_case
            "fields lower into row_kind; refinements stay empty" `Quick
            test_lower_relation_type_without_refinements;
          Alcotest.test_case "single-column primary key flows through" `Quick
            test_lower_relation_type_with_single_column_primary_key;
          Alcotest.test_case "compound primary key flows through" `Quick
            test_lower_relation_type_with_compound_primary_key;
        ] );
    ]
