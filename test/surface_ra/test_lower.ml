(** Tests for [Lower]. *)

open Dovetail_surface_ra
open Test_helpers
module Execution = Dovetail_execution
module Plan = Dovetail_plan
module Storage = Dovetail_storage
module Scalar = Dovetail_core.Scalar

let logical_plan_testable : Plan.Logical.plan Alcotest.testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<logical-plan>")) ( = )

let test_relation_name_lowers_to_scan () =
  let ast = Ast.Relation_name "users" in
  let logical = Lower.lower (Ast.Query ast) in
  Alcotest.(check logical_plan_testable)
    "Relation_name -> Scan"
    (Plan.Logical.Query (Scan { table = "users" }))
    logical

let test_pipeline_yields_fixture_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast = Ast.Relation_name "users" in
      let logical = Lower.lower (Ast.Query ast) in
      let catalog = make_catalog environment transaction in
      let physical = unwrap_query (Plan.Translate.translate ~catalog logical) in
      Execution.Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.value in
          Alcotest.(check row_list_testable)
            "five rows from AST" expected_users_rows rows))

let id_equals_three =
  expression_compare ~left:(expression_column "id") ~op:Equal
    ~right:(expression_literal (Scalar.Int64 3L))

let test_restrict_lowers_to_logical_restrict () =
  let ast =
    Ast.Restrict
      { input = Ast.Relation_name "users"; predicate = id_equals_three }
  in
  let logical = Lower.lower (Ast.Query ast) in
  Alcotest.(check logical_plan_testable)
    "Ast.Restrict -> Logical.Restrict wrapping Scan"
    (Plan.Logical.Query
       (Restrict
          { input = Scan { table = "users" }; predicate = id_equals_three }))
    logical

let test_restrict_pipeline_yields_filtered_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        Ast.Restrict
          { input = Ast.Relation_name "users"; predicate = id_equals_three }
      in
      let logical = Lower.lower (Ast.Query ast) in
      let catalog = make_catalog environment transaction in
      let physical = unwrap_query (Plan.Translate.translate ~catalog logical) in
      Execution.Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.value in
          Alcotest.(check row_list_testable)
            "Carol's row from Ast.Restrict"
            [ List.nth expected_users_rows 2 ]
            rows))

let name_then_email : Plan.Projection.t =
  [ column_reference "name"; column_reference "email" ]

let test_project_lowers_to_logical_project () =
  let ast =
    Ast.Project { input = Ast.Relation_name "users"; columns = name_then_email }
  in
  let logical = Lower.lower (Ast.Query ast) in
  Alcotest.(check logical_plan_testable)
    "Ast.Project -> Logical.Project wrapping Scan"
    (Plan.Logical.Query
       (Project { input = Scan { table = "users" }; columns = name_then_email }))
    logical

let test_project_pipeline_yields_projected_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        Ast.Project
          { input = Ast.Relation_name "users"; columns = name_then_email }
      in
      let logical = Lower.lower (Ast.Query ast) in
      let catalog = make_catalog environment transaction in
      let physical = unwrap_query (Plan.Translate.translate ~catalog logical) in
      Execution.Eval.eval environment transaction physical (fun relation ->
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
            "five projected rows from Ast.Project" expected rows))

let test_cross_product_lowers_to_logical_cross_product () =
  let ast =
    Ast.CrossProduct
      { left = Ast.Relation_name "users"; right = Ast.Relation_name "orders" }
  in
  let logical = Lower.lower (Ast.Query ast) in
  Alcotest.(check logical_plan_testable)
    "Ast.CrossProduct -> Logical.CrossProduct wrapping Scans"
    (Plan.Logical.Query
       (CrossProduct
          { left = Scan { table = "users" }; right = Scan { table = "orders" } }))
    logical

let users_id_equals_orders_user_id =
  expression_compare
    ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
    ~op:Equal
    ~right:(expression_qualified_column ~qualifier:"orders" ~name:"user_id")

let test_join_lowers_to_restrict_over_cross_product () =
  let ast =
    Ast.Join
      {
        left = Ast.Relation_name "users";
        right = Ast.Relation_name "orders";
        predicate = users_id_equals_orders_user_id;
      }
  in
  let logical = Lower.lower (Ast.Query ast) in
  Alcotest.(check logical_plan_testable)
    "Ast.Join -> Logical.Restrict wrapping Logical.CrossProduct"
    (Plan.Logical.Query
       (Restrict
          {
            input =
              CrossProduct
                {
                  left = Scan { table = "users" };
                  right = Scan { table = "orders" };
                };
            predicate = users_id_equals_orders_user_id;
          }))
    logical

let test_insert_mutation_lowers_through () =
  let source : Ast.t =
    RelationLiteral
      {
        columns = [ "id"; "user_id"; "description"; "amount" ];
        rows =
          [
            [
              Scalar.Int64 9L;
              Scalar.Int64 1L;
              Scalar.String "Pretzel";
              Scalar.Int64 9L;
            ];
          ];
      }
  in
  let plan : Ast.plan = Mutation (Insert { source; table = "orders" }) in
  let logical = Lower.lower plan in
  Alcotest.(check logical_plan_testable)
    "Ast.Mutation(Insert) -> Logical.Mutation(Insert) with the source lowered"
    (Plan.Logical.Mutation
       (Insert
          {
            table = "orders";
            source =
              RelationLiteral
                {
                  columns = [ "id"; "user_id"; "description"; "amount" ];
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
          }))
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
          expression_compare ~left:(expression_column "id") ~op:Equal
            ~right:(expression_literal (Scalar.Int64 1L));
      }
  in
  let plan : Ast.plan = Mutation (Insert { source; table = "orders" }) in
  let logical = Lower.lower plan in
  Alcotest.(check logical_plan_testable)
    "Insert source's relation tree is lowered in place"
    (Plan.Logical.Mutation
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
          }))
    logical

let test_relation_literal_lowers_through () =
  let ast : Ast.t =
    RelationLiteral
      {
        columns = [ "id"; "name" ];
        rows = [ [ Scalar.Int64 7L; Scalar.String "Pretzel" ] ];
      }
  in
  let logical = Lower.lower (Ast.Query ast) in
  Alcotest.(check logical_plan_testable)
    "Ast.RelationLiteral -> Logical.RelationLiteral with same payload"
    (Plan.Logical.Query
       (RelationLiteral
          {
            columns = [ "id"; "name" ];
            rows = [ [ Scalar.Int64 7L; Scalar.String "Pretzel" ] ];
          }))
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
            "lowers Ast.RelationLiteral to Logical.RelationLiteral" `Quick
            test_relation_literal_lowers_through;
        ] );
      ( "insert mutation",
        [
          Alcotest.test_case
            "lowers Ast.Mutation(Insert) to Logical.Mutation(Insert) and \
             lowers the source"
            `Quick test_insert_mutation_lowers_through;
          Alcotest.test_case
            "lowers a relational source inside Insert through the same path"
            `Quick test_insert_mutation_lowers_relational_source;
        ] );
    ]
