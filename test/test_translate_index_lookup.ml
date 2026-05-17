(** Tests for [Translate]'s [IndexLookup] rewrite.

    The rewrite folds [Restrict (Scan t, pk = K)] into a single
    {!Physical.IndexLookup} when the catalog says [t] has a single-column
    [Int64] primary key and the predicate is a bare PK-equality with an [Int64]
    literal. Every other shape falls through to the existing
    [Filter (FullScan ...)] form.

    Each test builds its own in-test catalog so the unit tests don't need a live
    LMDB environment; a single end-to-end pipeline test threads through the real
    fixture catalog to confirm the rewrite plus eval produce the expected row.
*)

open Dovetail
open Test_helpers

(* A users schema with a single int64 primary key. Matches what
   [Fixture.users_schema] writes, but rebuilt in-test so the unit tests
   don't need a live LMDB environment. *)
let users_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "email"; kind = String; qualifier = Some "users" };
        { name = "active"; kind = Bool; qualifier = Some "users" };
      ];
    primary_key = [ "id" ];
  }

(* A catalog that knows only about [users] with the standard schema. Tests
   that aim to exercise the rewrite on a real PK use this. *)
let users_catalog table_name =
  if table_name = "users" then Some users_schema else None

(* Build a catalog that returns [schema] for table "users" and [None]
   elsewhere. Used in the negative-precondition cases below where the
   schema has the wrong shape for index-lookup recognition. *)
let users_catalog_with schema table_name =
  if table_name = "users" then Some schema else None

let id_equals_int64_literal value =
  expression_compare ~left:(expression_column "id") ~op:Equal
    ~right:(expression_literal (Value.Int64 value))

let scan_users_restricted_by predicate : Logical.t =
  Restrict { input = Scan { table = "users" }; predicate }

let test_pk_equality_literal_folds_to_index_lookup () =
  let logical = scan_users_restricted_by (id_equals_int64_literal 5L) in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "Restrict(Scan, id = 5) -> IndexLookup(users, 5)"
    (Physical.IndexLookup { table = "users"; key = 5L })
    physical

let test_mirrored_pk_equality_literal_folds () =
  (* Same recognition, but the literal is on the left of the [Equal]. *)
  let logical =
    scan_users_restricted_by
      (expression_compare
         ~left:(expression_literal (Value.Int64 5L))
         ~op:Equal ~right:(expression_column "id"))
  in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "Restrict(Scan, 5 = id) -> IndexLookup(users, 5)"
    (Physical.IndexLookup { table = "users"; key = 5L })
    physical

let test_qualified_pk_column_folds () =
  let logical =
    scan_users_restricted_by
      (expression_compare
         ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
         ~op:Equal
         ~right:(expression_literal (Value.Int64 5L)))
  in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "Restrict(Scan, users.id = 5) -> IndexLookup(users, 5)"
    (Physical.IndexLookup { table = "users"; key = 5L })
    physical

let test_mis_qualified_pk_column_does_not_fold () =
  (* [orders.id = 5] over a [Scan "users"] mentions the right column name
     but a wrong qualifier -- the column reference doesn't resolve to the
     scanned table's PK, so the predicate stays as a Filter. *)
  let predicate =
    expression_compare
      ~left:(expression_qualified_column ~qualifier:"orders" ~name:"id")
      ~op:Equal
      ~right:(expression_literal (Value.Int64 5L))
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan)"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_non_int64_literal_on_pk_does_not_fold () =
  (* [id = "five"] is malformed against an int64 PK; the residual Filter
     will fail at resolve time, same as today. Translation must not fold
     a non-int64 literal into IndexLookup's [int64 key] field. *)
  let predicate =
    expression_compare ~left:(expression_column "id") ~op:Equal
      ~right:(expression_literal (Value.String "five"))
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan)"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_non_pk_column_equality_does_not_fold () =
  let predicate =
    expression_compare ~left:(expression_column "name") ~op:Equal
      ~right:(expression_literal (Value.String "Alice"))
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan)"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_pk_inequality_does_not_fold () =
  let predicate =
    expression_compare ~left:(expression_column "id") ~op:NotEqual
      ~right:(expression_literal (Value.Int64 5L))
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan)"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_pk_ordering_comparison_does_not_fold () =
  let predicate =
    expression_compare ~left:(expression_column "id") ~op:Less
      ~right:(expression_literal (Value.Int64 5L))
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan)"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_pk_equality_with_residual_conjunct_folds () =
  (* [id = 5 and active] partitions: [id = 5] folds into the lookup,
     [active] stays as the Filter's predicate. *)
  let predicate =
    expression_and
      ~left:(id_equals_int64_literal 5L)
      ~right:(expression_column "active")
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "Filter(active, IndexLookup(users, 5))"
    (Physical.Filter
       {
         input = Physical.IndexLookup { table = "users"; key = 5L };
         predicate = expression_column "active";
       })
    physical

let test_residual_then_pk_equality_folds () =
  (* Same as above but with the PK conjunct on the right side of the [And].
     The partitioning has to find it regardless of position. *)
  let predicate =
    expression_and
      ~left:(expression_column "active")
      ~right:(id_equals_int64_literal 5L)
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "Filter(active, IndexLookup(users, 5))"
    (Physical.Filter
       {
         input = Physical.IndexLookup { table = "users"; key = 5L };
         predicate = expression_column "active";
       })
    physical

let test_two_pk_equalities_keep_first_and_drop_rest_into_residual () =
  (* [id = 5 and id = 7] is a contradiction at runtime; we don't try to
     constant-fold. The first PK-equality folds; the second stays in the
     residual Filter and evaluates to false against the fetched row. *)
  let predicate =
    expression_and
      ~left:(id_equals_int64_literal 5L)
      ~right:(id_equals_int64_literal 7L)
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "Filter(id = 7, IndexLookup(users, 5))"
    (Physical.Filter
       {
         input = Physical.IndexLookup { table = "users"; key = 5L };
         predicate = id_equals_int64_literal 7L;
       })
    physical

let test_three_way_conjunction_rebuilds_two_conjunct_residual () =
  (* [id = 5 and name = "Alice" and active] parses left-associative as
     [(id = 5 and name = "Alice") and active]. Flattening yields three
     conjuncts; [id = 5] folds; the residual rebuilds as
     [name = "Alice" and active] (left-associative). *)
  let name_equals_alice =
    expression_compare ~left:(expression_column "name") ~op:Equal
      ~right:(expression_literal (Value.String "Alice"))
  in
  let predicate =
    expression_and
      ~left:
        (expression_and
           ~left:(id_equals_int64_literal 5L)
           ~right:name_equals_alice)
      ~right:(expression_column "active")
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  let expected_residual =
    expression_and ~left:name_equals_alice ~right:(expression_column "active")
  in
  Alcotest.(check physical_testable)
    "Filter(name = \"Alice\" and active, IndexLookup(users, 5))"
    (Physical.Filter
       {
         input = Physical.IndexLookup { table = "users"; key = 5L };
         predicate = expected_residual;
       })
    physical

let test_right_associative_nesting_flattens () =
  (* Same three-conjunct predicate but parenthesised the other way:
     [active and (id = 5 and name = "Alice")]. Flattening must walk both
     sides of the [And] tree so the PK conjunct in the middle is still
     found. *)
  let name_equals_alice =
    expression_compare ~left:(expression_column "name") ~op:Equal
      ~right:(expression_literal (Value.String "Alice"))
  in
  let predicate =
    expression_and
      ~left:(expression_column "active")
      ~right:
        (expression_and
           ~left:(id_equals_int64_literal 5L)
           ~right:name_equals_alice)
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  let expected_residual =
    expression_and ~left:(expression_column "active") ~right:name_equals_alice
  in
  Alcotest.(check physical_testable)
    "Filter(active and name = \"Alice\", IndexLookup(users, 5))"
    (Physical.Filter
       {
         input = Physical.IndexLookup { table = "users"; key = 5L };
         predicate = expected_residual;
       })
    physical

let test_conjunction_with_no_pk_equality_does_not_fold () =
  (* No conjunct names the PK; the rewrite must not invent one and must
     keep the original predicate intact for [Filter (FullScan ...)]. *)
  let name_equals_alice =
    expression_compare ~left:(expression_column "name") ~op:Equal
      ~right:(expression_literal (Value.String "Alice"))
  in
  let predicate =
    expression_and ~left:name_equals_alice ~right:(expression_column "active")
  in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:users_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan)"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_unknown_table_skips_folding () =
  (* If the catalog can't tell us what the PK is, fold nothing. The eval
     layer will produce its existing "unknown table" failure later. *)
  let predicate = id_equals_int64_literal 5L in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate ~catalog:noop_catalog (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan) when catalog returns None"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_composite_pk_does_not_fold () =
  let schema : Schema.t =
    {
      fields =
        [
          { name = "id"; kind = Int64; qualifier = Some "users" };
          { name = "tenant"; kind = Int64; qualifier = Some "users" };
        ];
      primary_key = [ "id"; "tenant" ];
    }
  in
  let predicate = id_equals_int64_literal 5L in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate
         ~catalog:(users_catalog_with schema)
         (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan) for composite PKs"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_string_pk_does_not_fold () =
  let schema : Schema.t =
    {
      fields = [ { name = "id"; kind = String; qualifier = Some "users" } ];
      primary_key = [ "id" ];
    }
  in
  let predicate = id_equals_int64_literal 5L in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate
         ~catalog:(users_catalog_with schema)
         (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan) for non-Int64 PKs"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_missing_pk_does_not_fold () =
  let schema : Schema.t =
    {
      fields = [ { name = "id"; kind = Int64; qualifier = Some "users" } ];
      primary_key = [];
    }
  in
  let predicate = id_equals_int64_literal 5L in
  let logical = scan_users_restricted_by predicate in
  let physical =
    unwrap_query
      (Translate.translate
         ~catalog:(users_catalog_with schema)
         (Logical.Query logical))
  in
  Alcotest.(check physical_testable)
    "stays as Filter(FullScan) for tables with no PK"
    (Physical.Filter
       { input = Physical.FullScan { table = "users" }; predicate })
    physical

let test_index_lookup_pipeline_yields_one_row () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let logical = scan_users_restricted_by (id_equals_int64_literal 1L) in
      let catalog = make_catalog environment transaction in
      let physical =
        unwrap_query (Translate.translate ~catalog (Logical.Query logical))
      in
      Alcotest.(check physical_testable)
        "translates through the real catalog to IndexLookup"
        (Physical.IndexLookup { table = "users"; key = 1L })
        physical;
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "Alice's row from the lookup"
            [ List.nth expected_users_rows 0 ]
            rows))

let () =
  Alcotest.run "translate_index_lookup"
    [
      ( "fold",
        [
          Alcotest.test_case "PK = literal folds to IndexLookup" `Quick
            test_pk_equality_literal_folds_to_index_lookup;
          Alcotest.test_case "literal = PK (mirrored) folds to IndexLookup"
            `Quick test_mirrored_pk_equality_literal_folds;
          Alcotest.test_case "qualified PK column folds to IndexLookup" `Quick
            test_qualified_pk_column_folds;
        ] );
      ( "no fold",
        [
          Alcotest.test_case
            "PK column with the wrong table qualifier does not fold" `Quick
            test_mis_qualified_pk_column_does_not_fold;
          Alcotest.test_case "non-Int64 literal on a PK column does not fold"
            `Quick test_non_int64_literal_on_pk_does_not_fold;
          Alcotest.test_case "equality on a non-PK column does not fold" `Quick
            test_non_pk_column_equality_does_not_fold;
          Alcotest.test_case "inequality on the PK column does not fold" `Quick
            test_pk_inequality_does_not_fold;
          Alcotest.test_case
            "ordering comparison on the PK column does not fold" `Quick
            test_pk_ordering_comparison_does_not_fold;
          Alcotest.test_case "conjunction with no PK equality does not fold"
            `Quick test_conjunction_with_no_pk_equality_does_not_fold;
        ] );
      ( "conjunct partitioning",
        [
          Alcotest.test_case
            "PK = literal and <other> folds with the other as a residual Filter"
            `Quick test_pk_equality_with_residual_conjunct_folds;
          Alcotest.test_case
            "<other> and PK = literal also folds (position-independent)" `Quick
            test_residual_then_pk_equality_folds;
          Alcotest.test_case
            "two PK equalities keep the first and drop the rest into the \
             residual"
            `Quick test_two_pk_equalities_keep_first_and_drop_rest_into_residual;
          Alcotest.test_case
            "three-way conjunction with one PK equality rebuilds a \
             two-conjunct residual"
            `Quick test_three_way_conjunction_rebuilds_two_conjunct_residual;
          Alcotest.test_case
            "right-associative nesting flattens for partitioning" `Quick
            test_right_associative_nesting_flattens;
        ] );
      ( "catalog preconditions",
        [
          Alcotest.test_case
            "catalog without the table skips folding (falls through to \
             FullScan)"
            `Quick test_unknown_table_skips_folding;
          Alcotest.test_case "composite primary key does not fold" `Quick
            test_composite_pk_does_not_fold;
          Alcotest.test_case "non-Int64 primary key does not fold" `Quick
            test_string_pk_does_not_fold;
          Alcotest.test_case "table with no primary key does not fold" `Quick
            test_missing_pk_does_not_fold;
        ] );
      ( "pipeline",
        [
          Alcotest.test_case
            "end-to-end: pipeline translates and evaluates against the fixture"
            `Quick test_index_lookup_pipeline_yields_one_row;
        ] );
    ]
