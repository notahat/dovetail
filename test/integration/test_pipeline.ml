(** End-to-end tests for the RA query language.

    Each test runs a textual query through the full parse / lower / translate /
    eval pipeline and asserts on the resulting rows (or on the failure raised at
    resolve time). The grammar-only tests -- parser-to-AST equality and parser
    rejection cases -- live in [test_parser.ml] and [test_expression_parser.ml].
*)

open Test_helpers
module Scalar = Dovetail_core.Scalar
module Relation = Dovetail_core.Relation
module Plan = Dovetail_plan
module Execution = Dovetail_execution
module Storage = Dovetail_storage

(* The expected matched (user, order) pairs from an inner equi-join on
   [users.id = orders.user_id]. The fixture has six orders; each names a
   user that exists in [users] except for Dave (id 4), who has no orders.
   Carol (id 3) and Alice (id 1) each have two; Bob (id 2) and Eve (id 5)
   each have one. *)
let six_matched_user_order_pairs = 6

let test_scan_yields_fixture_rows () =
  with_query_result "users" (fun rows ->
      Alcotest.(check row_list_testable)
        "five rows from parsed query" expected_users_rows rows)

let test_restrict_equality_yields_one_row () =
  with_query_result "users | restrict id = 3" (fun rows ->
      Alcotest.(check row_list_testable)
        "Carol's row from parsed restrict"
        [ List.nth expected_users_rows 2 ]
        rows)

let test_restrict_pk_equality_yields_alice () =
  (* End-to-end check that [id = 1] still produces Alice once Translate
     starts folding it to IndexLookup. The shape of the plan is verified
     in test_translate.ml; this test pins the user-visible behaviour. *)
  with_query_result "users | restrict id = 1" (fun rows ->
      Alcotest.(check row_list_testable)
        "Alice's row from PK lookup"
        [ List.nth expected_users_rows 0 ]
        rows)

let test_restrict_pk_equality_with_missing_key_yields_no_rows () =
  with_query_result "users | restrict id = 99" (fun rows ->
      Alcotest.(check row_list_testable) "no rows for absent key" [] rows)

let test_restrict_pk_equality_with_residual_keeps_matching_row () =
  (* [id = 1 and active] partitions: [id = 1] folds, [active] stays in
     the residual Filter. Alice is active, so the row survives. *)
  with_query_result "users | restrict id = 1 and active" (fun rows ->
      Alcotest.(check row_list_testable)
        "Alice's row from PK lookup + residual Filter"
        [ List.nth expected_users_rows 0 ]
        rows)

let test_restrict_pk_equality_with_residual_filters_out_inactive_row () =
  (* [id = 2 and active] looks up Bob, then the residual Filter rejects
     him because [active] is false. *)
  with_query_result "users | restrict id = 2 and active" (fun rows ->
      Alcotest.(check row_list_testable)
        "Bob's row dropped by the residual Filter" [] rows)

let test_restrict_pk_equality_with_missing_key_and_residual_yields_no_rows () =
  with_query_result "users | restrict id = 99 and active" (fun rows ->
      Alcotest.(check row_list_testable)
        "no rows when the PK lookup misses, regardless of the residual" [] rows)

let test_restrict_bare_bool_column_yields_active_rows () =
  with_query_result "users | restrict active" (fun rows ->
      Alcotest.(check int)
        "three active rows from restrict active" 3 (List.length rows))

let test_restrict_constant_true_yields_all_rows () =
  with_query_result "users | restrict 5 = 5" (fun rows ->
      Alcotest.(check row_list_testable)
        "5 = 5 keeps every row" expected_users_rows rows)

let test_restrict_int64_greater_than_yields_upper_rows () =
  with_query_result "users | restrict id > 3" (fun rows ->
      Alcotest.(check row_list_testable)
        "Dave and Eve (ids > 3)"
        [ List.nth expected_users_rows 3; List.nth expected_users_rows 4 ]
        rows)

let test_restrict_string_ge_yields_lex_subset () =
  with_query_result "users | restrict name >= \"C\"" (fun rows ->
      Alcotest.(check row_list_testable)
        "names lexicographically >= \"C\": Carol, Dave, Eve"
        [
          List.nth expected_users_rows 2;
          List.nth expected_users_rows 3;
          List.nth expected_users_rows 4;
        ]
        rows)

let test_restrict_and_intersects () =
  with_query_result "users | restrict id > 1 and active" (fun rows ->
      Alcotest.(check row_list_testable)
        "Carol and Dave (id > 1 and active)"
        [ List.nth expected_users_rows 2; List.nth expected_users_rows 3 ]
        rows)

let test_restrict_or_unions () =
  with_query_result "users | restrict name = \"Alice\" or name = \"Bob\""
    (fun rows ->
      Alcotest.(check row_list_testable)
        "Alice and Bob (union)"
        [ List.nth expected_users_rows 0; List.nth expected_users_rows 1 ]
        rows)

let test_restrict_and_chain_is_left_associative () =
  with_query_result "users | restrict id > 1 and id < 4 and active" (fun rows ->
      (* id between 1 and 4 = {2, 3}. Active among those: id 3 (Carol). *)
      Alcotest.(check row_list_testable)
        "Carol (id between 1 and 4, active)"
        [ List.nth expected_users_rows 2 ]
        rows)

let test_restrict_mixed_and_or_follows_precedence () =
  with_query_result "users | restrict id = 1 or id = 2 and active" (fun rows ->
      (* Parses as [id = 1 or (id = 2 and active)]. Alice (id 1) always
         matches; Bob (id 2, inactive) doesn't. Result: Alice only. *)
      Alcotest.(check row_list_testable)
        "Alice only (precedence)"
        [ List.nth expected_users_rows 0 ]
        rows)

let test_restrict_parens_override_precedence () =
  with_query_result "users | restrict (id = 1 or id = 2) and active"
    (fun rows ->
      (* With parens, [active] applies to both ids. Bob (id 2, inactive)
         drops out, leaving Alice. *)
      Alcotest.(check row_list_testable)
        "Alice only ((id = 1 or id = 2) and active)"
        [ List.nth expected_users_rows 0 ]
        rows)

let test_restrict_not_inverts_the_predicate () =
  with_query_result "users | restrict not active" (fun rows ->
      Alcotest.(check row_list_testable)
        "Bob and Eve (not active)"
        [ List.nth expected_users_rows 1; List.nth expected_users_rows 4 ]
        rows)

let test_project_yields_projected_rows () =
  with_query_result "users | project name, email" (fun rows ->
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
        "five projected rows from parsed project" expected rows)

let test_cross_yields_thirty_rows () =
  with_query_result "users | cross orders" (fun rows ->
      Alcotest.(check int)
        "5 users x 6 orders = 30 rows from parsed cross" 30 (List.length rows))

let test_cross_then_restrict_yields_matched_pairs () =
  with_query_result "users | cross orders | restrict users.id = orders.user_id"
    (fun rows ->
      Alcotest.(check int)
        "six matched (user, order) pairs from parsed pipeline"
        six_matched_user_order_pairs (List.length rows))

let test_join_yields_matched_pairs () =
  with_query_result "users | join orders on users.id = orders.user_id"
    (fun rows ->
      Alcotest.(check int)
        "six matched (user, order) pairs from parsed join"
        six_matched_user_order_pairs (List.length rows))

(* The six matched (user, order) rows the canonical PK-equality join
   produces, with users' columns first and orders' columns second.
   Used by the indexed-join pipeline tests below to pin both row and
   column order: the indexed rewrite picks orders as the outer (so
   rows arrive in orders' primary-key order) and tags users as the
   inner with inner_position = Left (so column order matches what the
   pre-rewrite plan produced). *)
let expected_join_rows : Row.value list =
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

let test_indexed_join_yields_expected_rows_and_column_order () =
  (* Translate now folds this query into an IndexedNestedLoopJoin
     (orders streamed, users probed). The inner_position = Left tag
     keeps the output columns in users.* / orders.* order -- the same
     order the pre-rewrite NestedLoopJoin produced -- so existing
     callers see no shape change. *)
  with_query_result "users | join orders on users.id = orders.user_id"
    (fun rows ->
      Alcotest.(check row_list_testable)
        "matched pairs in users.* / orders.* column order, orders PK row order"
        expected_join_rows rows)

let test_indexed_join_then_project_matches_readme_example () =
  (* The README example query. Pins the project's row order against the
     rendered table in the README's example. *)
  with_query_result
    "users | join orders on users.id = orders.user_id | project name, \
     description, amount" (fun rows ->
      let expected : Row.value list =
        [
          [| Scalar.String "Alice"; Scalar.String "Coffee"; Scalar.Int64 5L |];
          [| Scalar.String "Alice"; Scalar.String "Bagel"; Scalar.Int64 4L |];
          [| Scalar.String "Bob"; Scalar.String "Tea"; Scalar.Int64 3L |];
          [| Scalar.String "Carol"; Scalar.String "Sandwich"; Scalar.Int64 8L |];
          [| Scalar.String "Carol"; Scalar.String "Cake"; Scalar.Int64 6L |];
          [| Scalar.String "Eve"; Scalar.String "Cookie"; Scalar.Int64 2L |];
        ]
      in
      Alcotest.(check row_list_testable)
        "projected (name, description, amount) rows from README example"
        expected rows)

(* The three matched (user, order) rows that survive an
   [orders.amount >= 5] filter on top of the indexed join. Carved out
   of [expected_join_rows] so both forms of the residual-filter query
   (on-clause [and], trailing [| restrict]) can assert against it. *)
let expected_join_rows_with_amount_at_least_five : Row.value list =
  [
    List.nth expected_join_rows 0;
    (* Alice + Coffee, amount 5 *)
    List.nth expected_join_rows 3;
    (* Carol + Sandwich, amount 8 *)
    List.nth expected_join_rows 4;
    (* Carol + Cake, amount 6 *)
  ]

let test_indexed_join_with_on_clause_residual_yields_filtered_rows () =
  (* The [on]-clause [and] form: the PK-eq folds into the indexed join,
     [orders.amount >= 5] becomes a wrapping Filter. *)
  with_query_result
    "users | join orders on users.id = orders.user_id and orders.amount >= 5"
    (fun rows ->
      Alcotest.(check row_list_testable)
        "PK-eq folded; amount >= 5 applied by wrapping Filter"
        expected_join_rows_with_amount_at_least_five rows)

let test_indexed_join_with_trailing_restrict_yields_same_rows () =
  (* The trailing [| restrict] form. The syntactic-equivalence invariant
     says this must produce the same physical plan -- and so the same
     rows -- as the on-clause [and] form above. *)
  with_query_result
    "users | join orders on users.id = orders.user_id | restrict orders.amount \
     >= 5" (fun rows ->
      Alcotest.(check row_list_testable)
        "trailing restrict yields the same rows as the on-clause [and] form"
        expected_join_rows_with_amount_at_least_five rows)

let test_cross_with_ordering_predicate_still_uses_nested_loop_join () =
  (* Regression: the indexed rewrite only fires for column-on-column
     equalities that name an inner's PK. An ordering predicate like
     [users.id < orders.user_id] doesn't match, so this query keeps
     running through the NestedLoopJoin path. We don't assert
     the plan shape directly here (test_translate_indexed_nested_loop_join
     does), only that the end-to-end behaviour is unchanged. *)
  with_query_result "users | cross orders | restrict users.id < orders.user_id"
    (fun rows ->
      (* Pair count: users.id < orders.user_id over the fixture's
         5 users x 6 orders. user_ids in orders are 1,1,2,3,3,5. *)
      Alcotest.(check int)
        "nine pairs with users.id < orders.user_id" 9 (List.length rows))

(* Evaluate [plan] against the populated fixture and render the result
   the way Repl does, returning the rendered string for substring
   assertions. Used by the IndexedNestedLoopJoin pipeline test, which
   has no parser path yet. *)
let render_plan_against_fixture plan =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Execution.Eval.eval environment transaction plan
        (expect_relation (fun relation ->
             with_captured_formatter @@ fun formatter ->
             Relation.format formatter relation)))

let test_indexed_nested_loop_join_renders_matched_pairs () =
  (* Hand-built plan: stream [orders], probe [users] by
     [orders.user_id]. No parser path yet, so this test exercises Eval
     + Relation.format without going through the parser. The assertions
     cover the rendered column headers and every (user, order) pair
     the join should produce. *)
  let plan : Plan.Physical.t =
    Plan.Physical.IndexedNestedLoopJoin
      {
        outer = Plan.Physical.FullScan { table = "orders" };
        inner_table = "users";
        outer_key_column =
          qualified_row_column_reference ~qualifier:"orders" ~name:"user_id";
        inner_position = `Left;
      }
  in
  let rendered = render_plan_against_fixture plan in
  List.iter
    (fun expected ->
      if not (contains_substring rendered expected) then
        Alcotest.failf
          "expected rendered output to contain %S\n--- output ---\n%s" expected
          rendered)
    [
      (* Header row: inner (users) columns then outer (orders) columns. *)
      "users.id";
      "users.name";
      "orders.description";
      "orders.amount";
      (* Matched pairs across the six fixture orders, in orders'
         primary-key order. *)
      "Alice";
      "Coffee";
      "Bagel";
      "Bob";
      "Tea";
      "Carol";
      "Sandwich";
      "Cake";
      "Eve";
      "Cookie";
    ]

let test_cross_then_ambiguous_restrict_raises () =
  with_query_failure ~label:"ambiguous unqualified column"
    ~expected:
      (Failure
         "Restrict: ambiguous column reference \"id\": matches \"users.id\" \
          and \"orders.id\"")
    "users | cross orders | restrict id = 3"

let test_restrict_with_non_bool_expression_raises () =
  with_query_failure ~label:"non-Bool predicate from int64 column"
    ~expected:(Failure "Restrict: predicate position requires Bool, got Int64")
    "users | restrict id"

let test_type_on_users_yields_relation_type () =
  with_query_kind "users | type" (fun kind ->
      let rendered =
        with_captured_formatter (fun formatter ->
            Relation.format_kind formatter kind)
      in
      Alcotest.(check string)
        "users | type renders the fixture's relation type"
        "(users.id: int64, users.name: string, users.email: string, \
         users.active: bool, primary key (id))"
        rendered)

let test_type_over_type_raises_at_lower () =
  (* The rejection lives in [Lower.lower], which runs before [Eval], so
     [with_query_failure] (whose [check_raises] wraps only the [Eval] call)
     can't catch it. Walk parse and lower by hand instead. *)
  let ast =
    match Surface_ra.Parser.parse "users | type | type" with
    | Ok plan -> plan
    | Error message -> Alcotest.failf "parse failed: %s" message
  in
  Alcotest.check_raises "type applied to a type"
    (Failure "type: input is already a type") (fun () ->
      ignore (Surface_ra.Lower.lower ast))

let test_restrict_with_ordering_on_bool_raises () =
  with_query_failure ~label:"ordering operator on Bool operands"
    ~expected:(Failure "Restrict: ordering operator > is not defined for Bool")
    "users | restrict active > false"

let scalar_value_testable : Scalar.value Alcotest.testable =
  Alcotest.testable Scalar.format ( = )

let scalar_kind_testable : Scalar.kind Alcotest.testable =
  Alcotest.testable Scalar.format_kind ( = )

let test_bare_int64_literal_yields_its_value () =
  with_query_scalar_value "42" (fun value ->
      Alcotest.(check scalar_value_testable)
        "42 yields the Int64 value" (Scalar.Int64 42L) value)

let test_bare_string_literal_yields_its_value () =
  with_query_scalar_value "\"hello\"" (fun value ->
      Alcotest.(check scalar_value_testable)
        "\"hello\" yields the String value" (Scalar.String "hello") value)

let test_bare_bool_literal_yields_its_value () =
  with_query_scalar_value "true" (fun value ->
      Alcotest.(check scalar_value_testable)
        "true yields the Bool value" (Scalar.Bool true) value)

let test_int64_literal_then_type_yields_int64_kind () =
  with_query_scalar_kind "42 | type" (fun kind ->
      Alcotest.(check scalar_kind_testable)
        "42 | type yields Int64" Scalar.Int64 kind)

let test_string_literal_then_type_yields_string_kind () =
  with_query_scalar_kind "\"hello\" | type" (fun kind ->
      Alcotest.(check scalar_kind_testable)
        "\"hello\" | type yields String" Scalar.String kind)

let test_bool_literal_then_type_yields_bool_kind () =
  with_query_scalar_kind "true | type" (fun kind ->
      Alcotest.(check scalar_kind_testable)
        "true | type yields Bool" Scalar.Bool kind)

(* Row literal source — end-to-end through every layer, producing a
   [Term.Row_value] (or a [Term.Row_kind] when followed by [| type]). *)

module Row = Dovetail_core.Row

let row_testable : Row.t Alcotest.testable = Alcotest.testable Row.format ( = )

let row_kind_testable : Row.kind Alcotest.testable =
  Alcotest.testable Row.format_kind ( = )

let test_single_field_row_literal_yields_its_row () =
  let expected : Row.t =
    {
      kind = [ { name = "id"; kind = Int64; qualifier = None } ];
      value = [| Scalar.Int64 1L |];
    }
  in
  with_query_row_value "(id = 1)" (fun row ->
      Alcotest.(check row_testable)
        "(id = 1) yields the single-field row" expected row)

let test_multi_field_row_literal_yields_its_row () =
  let expected : Row.t =
    {
      kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      value = [| Scalar.Int64 1L; Scalar.String "alice" |];
    }
  in
  with_query_row_value "(id = 1, name = \"alice\")" (fun row ->
      Alcotest.(check row_testable)
        "(id = 1, name = \"alice\") yields the two-field row" expected row)

let test_empty_row_literal_yields_empty_row () =
  let expected : Row.t = { kind = []; value = [||] } in
  with_query_row_value "()" (fun row ->
      Alcotest.(check row_testable) "() yields the empty row" expected row)

let test_row_literal_then_type_yields_row_kind () =
  let expected : Row.kind =
    [
      { name = "id"; kind = Int64; qualifier = None };
      { name = "name"; kind = String; qualifier = None };
    ]
  in
  with_query_row_kind "(id = 1, name = \"alice\") | type" (fun kind ->
      Alcotest.(check row_kind_testable)
        "(id = 1, name = \"alice\") | type yields the row's kind" expected kind)

let test_empty_row_literal_then_type_yields_empty_row_kind () =
  with_query_row_kind "() | type" (fun kind ->
      Alcotest.(check row_kind_testable)
        "() | type yields the empty row kind" [] kind)

let test_row_literal_type_over_type_raises_at_lower () =
  (* The Lower-time rejection of [type | type] now triggers on a row source
     too. Walk parse and lower by hand since the rejection happens before
     Eval. *)
  let ast =
    match Surface_ra.Parser.parse "(id = 1) | type | type" with
    | Ok plan -> plan
    | Error message -> Alcotest.failf "parse failed: %s" message
  in
  Alcotest.check_raises "type applied to a row's type"
    (Failure "type: input is already a type") (fun () ->
      ignore (Surface_ra.Lower.lower ast))

(* Typed relation literals: [relation (T) { rows }]. The new shape coexists
   with the curly-brace form for now; both lower to the same logical node. *)

let test_typed_relation_literal_single_row_yields_one_row () =
  with_query_result
    "relation (id: int64, name: string) { (id = 1, name = \"alice\") }"
    (fun rows ->
      Alcotest.(check row_list_testable)
        "single-row typed literal yields one row"
        [ [| Scalar.Int64 1L; Scalar.String "alice" |] ]
        rows)

let test_typed_relation_literal_multiple_rows_yields_all_rows () =
  with_query_result
    "relation (id: int64, name: string) { (id = 1, name = \"alice\"), (id = 2, \
     name = \"bob\"), (id = 3, name = \"carol\") }" (fun rows ->
      Alcotest.(check row_list_testable)
        "multi-row typed literal yields every row in source order"
        [
          [| Scalar.Int64 1L; Scalar.String "alice" |];
          [| Scalar.Int64 2L; Scalar.String "bob" |];
          [| Scalar.Int64 3L; Scalar.String "carol" |];
        ]
        rows)

let test_typed_relation_literal_empty_yields_no_rows () =
  with_query_result "relation (id: int64, name: string) {}" (fun rows ->
      Alcotest.(check row_list_testable)
        "empty typed literal yields no rows" [] rows)

let test_typed_relation_literal_restrict_filters_rows () =
  with_query_result
    "relation (id: int64, name: string) { (id = 1, name = \"alice\"), (id = 2, \
     name = \"bob\") } | restrict id = 2" (fun rows ->
      Alcotest.(check row_list_testable)
        "restrict over a typed literal keeps only the matching row"
        [ [| Scalar.Int64 2L; Scalar.String "bob" |] ]
        rows)

let test_typed_relation_literal_project_narrows_columns () =
  with_query_result
    "relation (id: int64, name: string) { (id = 1, name = \"alice\"), (id = 2, \
     name = \"bob\") } | project name" (fun rows ->
      Alcotest.(check row_list_testable)
        "project over a typed literal narrows to the named column"
        [ [| Scalar.String "alice" |]; [| Scalar.String "bob" |] ]
        rows)

let test_typed_relation_literal_rejects_kind_mismatch_at_lower () =
  let ast =
    match
      Surface_ra.Parser.parse "relation (id: int64) { (id = \"oops\") }"
    with
    | Ok plan -> plan
    | Error message -> Alcotest.failf "parse failed: %s" message
  in
  Alcotest.check_raises "row value kind doesn't match the declared kind"
    (Failure
       "Lower: relation literal: field \"id\" expected int64 but got string")
    (fun () -> ignore (Surface_ra.Lower.lower ast))

let test_unqualify_after_join_strips_qualifiers () =
  (* A bare [join ... | unqualify] would collide on `id`; the project step
     selects two columns with distinct bare names so the strip is clean. *)
  with_query_result
    "users | join orders on users.id = orders.user_id | project users.id, \
     orders.user_id | unqualify" (fun rows ->
      Alcotest.(check int)
        "six matched (user, order) pairs survive unqualify"
        six_matched_user_order_pairs (List.length rows))

let test_unqualify_after_join_rejects_collision () =
  with_query_failure ~label:"collision on bare id"
    ~expected:
      (Failure
         "Eval: unqualify: collision on \"id\": fields \"users.id\" and \
          \"orders.id\"")
    "users | join orders on users.id = orders.user_id | project users.id, \
     orders.id | unqualify"

let test_unqualify_on_already_unqualified_relation_is_a_noop () =
  with_query_result "users | unqualify" (fun rows ->
      Alcotest.(check row_list_testable)
        "unqualify on a bare-scan relation passes the fixture rows through"
        expected_users_rows rows)

let test_unqualify_on_row_literal_strips_qualifiers () =
  with_query_row_value "(users.id = 1) | unqualify" (fun row ->
      Alcotest.(check (list (option string)))
        "the resulting row's single field has qualifier = None" [ None ]
        (List.map (fun (field : Row.field) -> field.qualifier) row.kind);
      Alcotest.(check string)
        "the resulting row's single field has bare name \"id\"" "id"
        (List.hd row.kind).name)

(* Parse [query] through the full parse / lower / translate / eval pipeline
   against the populated fixture, render the resulting [Term.t] the way
   Repl does, and return the rendered string. Covers the parse-to-eval
   path for queries whose result is not a relation (catalog, future
   operators), where [with_query_result] doesn't apply. *)
let render_query_against_fixture query =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        match Surface_ra.Parser.parse query with
        | Ok plan -> plan
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Surface_ra.Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      with_captured_formatter @@ fun formatter ->
      Execution.Eval.eval environment transaction physical (fun term ->
          Dovetail_core.Term.format formatter term))

let test_catalog_pipe_tables_renders_fixture_table_names () =
  let expected =
    String.concat "\n"
      [
        "relation (name: string) {";
        "  (name = \"orders\"),";
        "  (name = \"users\")";
        "}";
      ]
  in
  Alcotest.(check string)
    "catalog | tables renders one row per fixture table" expected
    (render_query_against_fixture "catalog | tables")

let test_catalog_pipe_tables_pipe_type_renders_one_column_kind () =
  Alcotest.(check string)
    "catalog | tables | type renders the (name: string) relation kind"
    "(name: string)"
    (render_query_against_fixture "catalog | tables | type")

let test_tables_over_non_catalog_input_raises_user_facing_error () =
  Alcotest.check_raises "tables over a scalar literal"
    (Failure "Eval: tables: expected a catalog value, got a scalar value")
    (fun () -> ignore (render_query_against_fixture "42 | tables"))

let test_catalog_pipe_type_renders_fixture_catalog_kind () =
  let expected =
    "catalog { orders: (orders.id: int64, orders.user_id: int64, \
     orders.description: string, orders.amount: int64, primary key (id)), \
     users: (users.id: int64, users.name: string, users.email: string, \
     users.active: bool, primary key (id)) }"
  in
  Alcotest.(check string)
    "catalog | type renders the fixture catalog kind end to end" expected
    (render_query_against_fixture "catalog | type")

let test_bare_catalog_renders_fixture_catalog_literal () =
  let expected =
    String.concat "\n"
      [
        "catalog {";
        "  orders = relation (orders.id: int64, orders.user_id: int64, \
         orders.description: string, orders.amount: int64, primary key (id)) {";
        "    (orders.id = 1, orders.user_id = 1, orders.description = \
         \"Coffee\", orders.amount = 5),";
        "    (orders.id = 2, orders.user_id = 1, orders.description = \
         \"Bagel\", orders.amount = 4),";
        "    (orders.id = 3, orders.user_id = 2, orders.description = \"Tea\", \
         orders.amount = 3),";
        "    (orders.id = 4, orders.user_id = 3, orders.description = \
         \"Sandwich\", orders.amount = 8),";
        "    (orders.id = 5, orders.user_id = 3, orders.description = \
         \"Cake\", orders.amount = 6),";
        "    (orders.id = 6, orders.user_id = 5, orders.description = \
         \"Cookie\", orders.amount = 2)";
        "  },";
        "  users = relation (users.id: int64, users.name: string, users.email: \
         string, users.active: bool, primary key (id)) {";
        "    (users.id = 1, users.name = \"Alice\", users.email = \
         \"alice@example.com\", users.active = true),";
        "    (users.id = 2, users.name = \"Bob\", users.email = \
         \"bob@example.com\", users.active = false),";
        "    (users.id = 3, users.name = \"Carol\", users.email = \
         \"carol@example.com\", users.active = true),";
        "    (users.id = 4, users.name = \"Dave\", users.email = \
         \"dave@example.com\", users.active = true),";
        "    (users.id = 5, users.name = \"Eve\", users.email = \
         \"eve@example.com\", users.active = false)";
        "  }";
        "}";
      ]
  in
  Alcotest.(check string)
    "bare catalog renders the fixture catalog literal end to end" expected
    (render_query_against_fixture "catalog")

let test_scalar_literal_type_over_type_raises_at_lower () =
  (* The Lower-time rejection of [type | type] now triggers on a scalar
     source too. Walk parse and lower by hand since the rejection happens
     before Eval. *)
  let ast =
    match Surface_ra.Parser.parse "42 | type | type" with
    | Ok plan -> plan
    | Error message -> Alcotest.failf "parse failed: %s" message
  in
  Alcotest.check_raises "type applied to a scalar's type"
    (Failure "type: input is already a type") (fun () ->
      ignore (Surface_ra.Lower.lower ast))

let () =
  Alcotest.run "pipeline"
    [
      ( "scan",
        [
          Alcotest.test_case "yields fixture rows" `Quick
            test_scan_yields_fixture_rows;
        ] );
      ( "restrict",
        [
          Alcotest.test_case "id = 3 yields Carol's row" `Quick
            test_restrict_equality_yields_one_row;
          Alcotest.test_case "id = 1 yields Alice via PK lookup" `Quick
            test_restrict_pk_equality_yields_alice;
          Alcotest.test_case "id = 99 yields no rows via PK lookup" `Quick
            test_restrict_pk_equality_with_missing_key_yields_no_rows;
          Alcotest.test_case
            "id = 1 and active yields Alice via PK lookup and residual filter"
            `Quick test_restrict_pk_equality_with_residual_keeps_matching_row;
          Alcotest.test_case
            "id = 2 and active yields no rows because Bob is inactive" `Quick
            test_restrict_pk_equality_with_residual_filters_out_inactive_row;
          Alcotest.test_case
            "id = 99 and active yields no rows when the PK lookup misses" `Quick
            test_restrict_pk_equality_with_missing_key_and_residual_yields_no_rows;
          Alcotest.test_case "bare Bool column yields the active rows" `Quick
            test_restrict_bare_bool_column_yields_active_rows;
          Alcotest.test_case "constant-true comparison keeps every row" `Quick
            test_restrict_constant_true_yields_all_rows;
          Alcotest.test_case "id > 3 yields the rows above the bound" `Quick
            test_restrict_int64_greater_than_yields_upper_rows;
          Alcotest.test_case "name >= \"C\" yields the lex-ordered upper subset"
            `Quick test_restrict_string_ge_yields_lex_subset;
          Alcotest.test_case "id > 1 and active intersects the two conditions"
            `Quick test_restrict_and_intersects;
          Alcotest.test_case "name = ... or name = ... unions the rows" `Quick
            test_restrict_or_unions;
          Alcotest.test_case "left-associative and-chain" `Quick
            test_restrict_and_chain_is_left_associative;
          Alcotest.test_case "mixed and/or follows declared precedence" `Quick
            test_restrict_mixed_and_or_follows_precedence;
          Alcotest.test_case "parens override precedence" `Quick
            test_restrict_parens_override_precedence;
          Alcotest.test_case "not active yields the complement" `Quick
            test_restrict_not_inverts_the_predicate;
        ] );
      ( "project",
        [
          Alcotest.test_case "yields the projected rows" `Quick
            test_project_yields_projected_rows;
        ] );
      ( "cross",
        [
          Alcotest.test_case "yields all (user, order) pairs" `Quick
            test_cross_yields_thirty_rows;
          Alcotest.test_case
            "cross then restrict yields matched (user, order) pairs" `Quick
            test_cross_then_restrict_yields_matched_pairs;
        ] );
      ( "join",
        [
          Alcotest.test_case "yields matched (user, order) pairs" `Quick
            test_join_yields_matched_pairs;
          Alcotest.test_case
            "hand-built IndexedNestedLoopJoin renders matched pairs" `Quick
            test_indexed_nested_loop_join_renders_matched_pairs;
          Alcotest.test_case
            "parsed join folds to IndexedNestedLoopJoin and keeps row and \
             column order"
            `Quick test_indexed_join_yields_expected_rows_and_column_order;
          Alcotest.test_case
            "parsed join then project matches the README example rows" `Quick
            test_indexed_join_then_project_matches_readme_example;
          Alcotest.test_case
            "parsed join with on-clause [and] residual returns filtered rows"
            `Quick
            test_indexed_join_with_on_clause_residual_yields_filtered_rows;
          Alcotest.test_case
            "parsed join with trailing | restrict yields the same rows" `Quick
            test_indexed_join_with_trailing_restrict_yields_same_rows;
          Alcotest.test_case
            "cross with an ordering predicate keeps the NestedLoopJoin path"
            `Quick
            test_cross_with_ordering_predicate_still_uses_nested_loop_join;
        ] );
      ( "type",
        [
          Alcotest.test_case "users | type yields the fixture's relation type"
            `Quick test_type_on_users_yields_relation_type;
          Alcotest.test_case "users | type | type raises at Lower" `Quick
            test_type_over_type_raises_at_lower;
        ] );
      ( "catalog source",
        [
          Alcotest.test_case
            "bare [catalog] renders the fixture catalog literal end to end"
            `Quick test_bare_catalog_renders_fixture_catalog_literal;
          Alcotest.test_case
            "[catalog | type] renders the fixture catalog kind end to end"
            `Quick test_catalog_pipe_type_renders_fixture_catalog_kind;
          Alcotest.test_case
            "[catalog | tables] renders one row per fixture table" `Quick
            test_catalog_pipe_tables_renders_fixture_table_names;
          Alcotest.test_case
            "[catalog | tables | type] renders the (name: string) relation kind"
            `Quick test_catalog_pipe_tables_pipe_type_renders_one_column_kind;
          Alcotest.test_case
            "[42 | tables] raises Eval: tables: expected a catalog value, got \
             a scalar value"
            `Quick test_tables_over_non_catalog_input_raises_user_facing_error;
        ] );
      ( "scalar literal source",
        [
          Alcotest.test_case "42 yields the Int64 value" `Quick
            test_bare_int64_literal_yields_its_value;
          Alcotest.test_case "\"hello\" yields the String value" `Quick
            test_bare_string_literal_yields_its_value;
          Alcotest.test_case "true yields the Bool value" `Quick
            test_bare_bool_literal_yields_its_value;
          Alcotest.test_case "42 | type yields the Int64 scalar kind" `Quick
            test_int64_literal_then_type_yields_int64_kind;
          Alcotest.test_case "\"hello\" | type yields the String scalar kind"
            `Quick test_string_literal_then_type_yields_string_kind;
          Alcotest.test_case "true | type yields the Bool scalar kind" `Quick
            test_bool_literal_then_type_yields_bool_kind;
          Alcotest.test_case "42 | type | type raises at Lower" `Quick
            test_scalar_literal_type_over_type_raises_at_lower;
        ] );
      ( "row literal source",
        [
          Alcotest.test_case "(id = 1) yields the single-field row" `Quick
            test_single_field_row_literal_yields_its_row;
          Alcotest.test_case "(id = 1, name = ...) yields the two-field row"
            `Quick test_multi_field_row_literal_yields_its_row;
          Alcotest.test_case "() yields the empty row" `Quick
            test_empty_row_literal_yields_empty_row;
          Alcotest.test_case
            "(id = 1, name = ...) | type yields the matching row kind" `Quick
            test_row_literal_then_type_yields_row_kind;
          Alcotest.test_case "() | type yields the empty row kind" `Quick
            test_empty_row_literal_then_type_yields_empty_row_kind;
          Alcotest.test_case "(id = 1) | type | type raises at Lower" `Quick
            test_row_literal_type_over_type_raises_at_lower;
        ] );
      ( "typed relation literal source",
        [
          Alcotest.test_case
            "single-row typed literal yields one row through Eval" `Quick
            test_typed_relation_literal_single_row_yields_one_row;
          Alcotest.test_case "multi-row typed literal yields every row" `Quick
            test_typed_relation_literal_multiple_rows_yields_all_rows;
          Alcotest.test_case "empty typed literal yields no rows" `Quick
            test_typed_relation_literal_empty_yields_no_rows;
          Alcotest.test_case "restrict over a typed literal filters rows" `Quick
            test_typed_relation_literal_restrict_filters_rows;
          Alcotest.test_case "project over a typed literal narrows columns"
            `Quick test_typed_relation_literal_project_narrows_columns;
          Alcotest.test_case "value/kind mismatch in a row is rejected at Lower"
            `Quick test_typed_relation_literal_rejects_kind_mismatch_at_lower;
        ] );
      ( "unqualify",
        [
          Alcotest.test_case
            "post-join unqualify yields the same matched-pair count" `Quick
            test_unqualify_after_join_strips_qualifiers;
          Alcotest.test_case
            "unqualify after a project that lifts both PKs is rejected" `Quick
            test_unqualify_after_join_rejects_collision;
          Alcotest.test_case
            "unqualify on a bare-scan relation passes rows through unchanged"
            `Quick test_unqualify_on_already_unqualified_relation_is_a_noop;
          Alcotest.test_case "unqualify on a qualified row literal strips it"
            `Quick test_unqualify_on_row_literal_strips_qualifiers;
        ] );
      ( "errors",
        [
          Alcotest.test_case "cross then unqualified restrict raises ambiguity"
            `Quick test_cross_then_ambiguous_restrict_raises;
          Alcotest.test_case
            "restrict with a non-Bool expression raises at resolve time" `Quick
            test_restrict_with_non_bool_expression_raises;
          Alcotest.test_case "restrict active > false raises naming Bool" `Quick
            test_restrict_with_ordering_on_bool_raises;
        ] );
    ]
