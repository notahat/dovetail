(** Tests for [Translate]'s structural rewrites: one logical constructor maps to
    one physical constructor, plus the inner-join collapse. The [IndexLookup]
    rewrite lives in [test_translate_index_lookup.ml]. *)

open Dovetail_plan
open Test_helpers
module Execution = Dovetail_execution
module Storage = Dovetail_storage
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

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
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let logical = Logical.Scan { table = "users" } in
      let catalog = make_catalog environment transaction in
      let physical = Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical
        (expect_relation (fun relation ->
             let rows = List.of_seq relation.value in
             Alcotest.(check row_list_testable)
               "five rows from logical scan" expected_users_rows rows)))

let id_equals_three =
  expression_compare ~left:(expression_column "id") ~op:Equal
    ~right:(expression_literal (Scalar.Int64 3L))

let name_then_email : Projection.t =
  [ row_column_reference "name"; row_column_reference "email" ]

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
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let logical =
        Logical.Restrict
          {
            input = Logical.Scan { table = "users" };
            predicate = id_equals_three;
          }
      in
      let catalog = make_catalog environment transaction in
      let physical = Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical
        (expect_relation (fun relation ->
             let rows = List.of_seq relation.value in
             Alcotest.(check row_list_testable)
               "Carol's row from logical Restrict"
               [ List.nth expected_users_rows 2 ]
               rows)))

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
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let logical =
        Logical.Project
          {
            input = Logical.Scan { table = "users" };
            columns = name_then_email;
          }
      in
      let catalog = make_catalog environment transaction in
      let physical = Translate.translate ~catalog logical in
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
               "five projected rows from logical Project" expected rows)))

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

let test_relation_literal_translates_through () =
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
  let logical : Logical.t =
    Relation_literal
      { kind; rows = [ [ Scalar.Int64 7L; Scalar.String "Pretzel" ] ] }
  in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Logical.Relation_literal -> Physical.Relation_literal with same payload"
    (Physical.Relation_literal
       { kind; rows = [ [ Scalar.Int64 7L; Scalar.String "Pretzel" ] ] })
    physical

let test_scalar_literal_translates_through () =
  let logical : Logical.t = Scalar_literal (Scalar.Int64 42L) in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Logical.Scalar_literal -> Physical.Scalar_literal with same value"
    (Physical.Scalar_literal (Scalar.Int64 42L)) physical

let test_row_literal_translates_through () =
  let fields =
    [
      (row_column_reference "id", Scalar.Int64 1L);
      (row_column_reference "name", Scalar.String "alice");
    ]
  in
  let logical : Logical.t = Row_literal { fields } in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Logical.Row_literal -> Physical.Row_literal with same fields"
    (Physical.Row_literal { fields })
    physical

let test_unqualify_translates_through () =
  let logical : Logical.t = Unqualify { input = Scan { table = "users" } } in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Logical.Unqualify translates to Physical.Unqualify with the input \
     translated"
    (Physical.Unqualify { input = Physical.FullScan { table = "users" } })
    physical

let users_kind_no_qualifier : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = None };
        { name = "name"; kind = String; qualifier = None };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let test_drop_table_translates_through () =
  let logical : Logical.t = Drop_table { table_name = "users" } in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Logical.Drop_table -> Physical.Drop_table"
    (Physical.Drop_table { table_name = "users" })
    physical

let test_catalog_source_translates_through () =
  let physical = Translate.translate ~catalog:noop_catalog Catalog_source in
  Alcotest.(check physical_testable)
    "Logical.Catalog_source -> Physical.Catalog_source" Physical.Catalog_source
    physical

let test_tables_translates_through () =
  let logical : Logical.t = Tables { input = Catalog_source } in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Logical.Tables -> Physical.Tables with translated input"
    (Physical.Tables { input = Physical.Catalog_source })
    physical

let test_create_table_empty_translates_through () =
  let logical : Logical.t =
    Create_table_empty { table_name = "users"; kind = users_kind_no_qualifier }
  in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Logical.Create_table_empty -> Physical.Create_table_empty with same kind"
    (Physical.Create_table_empty
       { table_name = "users"; kind = users_kind_no_qualifier })
    physical

let test_create_table_seeded_recurses_into_source () =
  let logical : Logical.t =
    Create_table_seeded
      { table_name = "copy_of_users"; source = Scan { table = "users" } }
  in
  let physical = Translate.translate ~catalog:noop_catalog logical in
  Alcotest.(check physical_testable)
    "Logical.Create_table_seeded translates source via translate_relation"
    (Physical.Create_table_seeded
       {
         table_name = "copy_of_users";
         source = Physical.FullScan { table = "users" };
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

(* An [orders]-shaped kind used by the Mutation arm tests. Matches what
   [Fixture.orders_kind] writes, rebuilt in-test so these tests don't need
   a live LMDB environment. *)
let orders_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
        { name = "description"; kind = String; qualifier = Some "orders" };
        { name = "amount"; kind = Int64; qualifier = Some "orders" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

(* A catalog that knows only about [orders] with the standard kind. *)
let orders_catalog table_name =
  if table_name = "orders" then Some orders_kind else None

(* Build a [Logical.t] that inserts a single-row literal into [table].
   [pairs] gives the column/value pairs in the order the test wants written;
   the literal's declared kind mirrors that order with per-column kinds
   inferred from each value's runtime constructor -- the same shape Lower
   produces for a typed relation literal. *)
let insert_plan ~table ~pairs : Logical.t =
  let kind : Relation.kind =
    {
      row_kind =
        List.map
          (fun (name, value) : Row.field ->
            { name; kind = Scalar.kind_of value; qualifier = None })
          pairs;
      refinements = [];
    }
  in
  let values = List.map snd pairs in
  Insert { table; source = Relation_literal { kind; rows = [ values ] } }

let test_mutation_in_target_order_translates_through () =
  let plan =
    insert_plan ~table:"orders"
      ~pairs:
        [
          ("id", Scalar.Int64 9L);
          ("user_id", Scalar.Int64 1L);
          ("description", Scalar.String "Pretzel");
          ("amount", Scalar.Int64 9L);
        ]
  in
  let translated = Translate.translate ~catalog:orders_catalog plan in
  let expected_kind : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "user_id"; kind = Int64; qualifier = None };
          { name = "description"; kind = String; qualifier = None };
          { name = "amount"; kind = Int64; qualifier = None };
        ];
      refinements = [];
    }
  in
  Alcotest.(check physical_testable)
    "Logical.Insert -> Physical.Insert with the literal source translated \
     through"
    (Physical.Insert
       {
         table = "orders";
         source =
           Physical.Relation_literal
             {
               kind = expected_kind;
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
    translated

let test_mutation_in_permuted_order_translates_through () =
  (* Permutation is allowed; Translate validates the column set, not the
     order. Eval-side reordering then happens at write time. *)
  let plan =
    insert_plan ~table:"orders"
      ~pairs:
        [
          ("description", Scalar.String "Pretzel");
          ("amount", Scalar.Int64 9L);
          ("user_id", Scalar.Int64 1L);
          ("id", Scalar.Int64 9L);
        ]
  in
  let translated = Translate.translate ~catalog:orders_catalog plan in
  match translated with
  | Physical.Insert { table; source = Relation_literal _ } ->
      Alcotest.(check string)
        "the target table name reaches the Physical Insert" "orders" table
  | _ -> Alcotest.fail "expected a Physical.Insert wrapping a Relation_literal"

let test_mutation_against_unknown_table_raises () =
  let plan =
    insert_plan ~table:"widgets"
      ~pairs:[ ("id", Scalar.Int64 1L); ("name", Scalar.String "x") ]
  in
  Alcotest.check_raises "unknown table"
    (Failure "Translate: insert into \"widgets\": unknown table") (fun () ->
      ignore (Translate.translate ~catalog:orders_catalog plan))

(* Insert-literal column-set agreement and per-column kind agreement are no
   longer Translate's responsibility -- those cases now live in
   [test/plan/test_typecheck.ml]. Translate trusts that [Typecheck] has
   validated the literal source before it runs. *)

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
      ( "relation literal",
        [
          Alcotest.test_case
            "translates Logical.Relation_literal through unchanged" `Quick
            test_relation_literal_translates_through;
        ] );
      ( "scalar literal",
        [
          Alcotest.test_case
            "translates Logical.Scalar_literal through unchanged" `Quick
            test_scalar_literal_translates_through;
        ] );
      ( "row literal",
        [
          Alcotest.test_case "translates Logical.Row_literal through unchanged"
            `Quick test_row_literal_translates_through;
        ] );
      ( "unqualify",
        [
          Alcotest.test_case "translates Logical.Unqualify through unchanged"
            `Quick test_unqualify_translates_through;
        ] );
      ( "create / drop table",
        [
          Alcotest.test_case "translates Logical.Drop_table through unchanged"
            `Quick test_drop_table_translates_through;
          Alcotest.test_case
            "translates Logical.Create_table_empty through unchanged" `Quick
            test_create_table_empty_translates_through;
          Alcotest.test_case "Logical.Create_table_seeded recurses into source"
            `Quick test_create_table_seeded_recurses_into_source;
        ] );
      ( "catalog source",
        [
          Alcotest.test_case
            "translates Logical.Catalog_source through unchanged" `Quick
            test_catalog_source_translates_through;
          Alcotest.test_case
            "translates Logical.Tables, recursing into its input" `Quick
            test_tables_translates_through;
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
      ( "mutation arm",
        [
          Alcotest.test_case
            "Insert with literal columns in target order translates through"
            `Quick test_mutation_in_target_order_translates_through;
          Alcotest.test_case
            "Insert with literal columns in permuted order is accepted" `Quick
            test_mutation_in_permuted_order_translates_through;
          Alcotest.test_case "Insert into an unknown table raises" `Quick
            test_mutation_against_unknown_table_raises;
        ] );
    ]
