(** End-to-end tests for the RA query language.

    Each test runs a textual query through the full parse / lower / translate /
    eval pipeline and asserts on the resulting rows (or on the failure raised at
    resolve time). The grammar-only tests -- parser-to-AST equality and parser
    rejection cases -- live in [test_parser.ml] and [test_expression_parser.ml].
*)

open Test_helpers
module Value = Dovetail_core.Value
module Schema = Dovetail_core.Schema
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
      Alcotest.(check tuple_list_testable)
        "five rows from parsed query" expected_users_rows rows)

let test_restrict_equality_yields_one_row () =
  with_query_result "users | restrict id = 3" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "Carol's row from parsed restrict"
        [ List.nth expected_users_rows 2 ]
        rows)

let test_restrict_pk_equality_yields_alice () =
  (* End-to-end check that [id = 1] still produces Alice once Translate
     starts folding it to IndexLookup. The shape of the plan is verified
     in test_translate.ml; this test pins the user-visible behaviour. *)
  with_query_result "users | restrict id = 1" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "Alice's row from PK lookup"
        [ List.nth expected_users_rows 0 ]
        rows)

let test_restrict_pk_equality_with_missing_key_yields_no_rows () =
  with_query_result "users | restrict id = 99" (fun rows ->
      Alcotest.(check tuple_list_testable) "no rows for absent key" [] rows)

let test_restrict_pk_equality_with_residual_keeps_matching_row () =
  (* [id = 1 and active] partitions: [id = 1] folds, [active] stays in
     the residual Filter. Alice is active, so the row survives. *)
  with_query_result "users | restrict id = 1 and active" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "Alice's row from PK lookup + residual Filter"
        [ List.nth expected_users_rows 0 ]
        rows)

let test_restrict_pk_equality_with_residual_filters_out_inactive_row () =
  (* [id = 2 and active] looks up Bob, then the residual Filter rejects
     him because [active] is false. *)
  with_query_result "users | restrict id = 2 and active" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "Bob's row dropped by the residual Filter" [] rows)

let test_restrict_pk_equality_with_missing_key_and_residual_yields_no_rows () =
  with_query_result "users | restrict id = 99 and active" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "no rows when the PK lookup misses, regardless of the residual" [] rows)

let test_restrict_bare_bool_column_yields_active_rows () =
  with_query_result "users | restrict active" (fun rows ->
      Alcotest.(check int)
        "three active rows from restrict active" 3 (List.length rows))

let test_restrict_constant_true_yields_all_rows () =
  with_query_result "users | restrict 5 = 5" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "5 = 5 keeps every row" expected_users_rows rows)

let test_restrict_int64_greater_than_yields_upper_rows () =
  with_query_result "users | restrict id > 3" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "Dave and Eve (ids > 3)"
        [ List.nth expected_users_rows 3; List.nth expected_users_rows 4 ]
        rows)

let test_restrict_string_ge_yields_lex_subset () =
  with_query_result "users | restrict name >= \"C\"" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "names lexicographically >= \"C\": Carol, Dave, Eve"
        [
          List.nth expected_users_rows 2;
          List.nth expected_users_rows 3;
          List.nth expected_users_rows 4;
        ]
        rows)

let test_restrict_and_intersects () =
  with_query_result "users | restrict id > 1 and active" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "Carol and Dave (id > 1 and active)"
        [ List.nth expected_users_rows 2; List.nth expected_users_rows 3 ]
        rows)

let test_restrict_or_unions () =
  with_query_result "users | restrict name = \"Alice\" or name = \"Bob\""
    (fun rows ->
      Alcotest.(check tuple_list_testable)
        "Alice and Bob (union)"
        [ List.nth expected_users_rows 0; List.nth expected_users_rows 1 ]
        rows)

let test_restrict_and_chain_is_left_associative () =
  with_query_result "users | restrict id > 1 and id < 4 and active" (fun rows ->
      (* id between 1 and 4 = {2, 3}. Active among those: id 3 (Carol). *)
      Alcotest.(check tuple_list_testable)
        "Carol (id between 1 and 4, active)"
        [ List.nth expected_users_rows 2 ]
        rows)

let test_restrict_mixed_and_or_follows_precedence () =
  with_query_result "users | restrict id = 1 or id = 2 and active" (fun rows ->
      (* Parses as [id = 1 or (id = 2 and active)]. Alice (id 1) always
         matches; Bob (id 2, inactive) doesn't. Result: Alice only. *)
      Alcotest.(check tuple_list_testable)
        "Alice only (precedence)"
        [ List.nth expected_users_rows 0 ]
        rows)

let test_restrict_parens_override_precedence () =
  with_query_result "users | restrict (id = 1 or id = 2) and active"
    (fun rows ->
      (* With parens, [active] applies to both ids. Bob (id 2, inactive)
         drops out, leaving Alice. *)
      Alcotest.(check tuple_list_testable)
        "Alice only ((id = 1 or id = 2) and active)"
        [ List.nth expected_users_rows 0 ]
        rows)

let test_restrict_not_inverts_the_predicate () =
  with_query_result "users | restrict not active" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "Bob and Eve (not active)"
        [ List.nth expected_users_rows 1; List.nth expected_users_rows 4 ]
        rows)

let test_project_yields_projected_rows () =
  with_query_result "users | project name, email" (fun rows ->
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
let expected_join_rows : Schema.tuple list =
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
      Alcotest.(check tuple_list_testable)
        "matched pairs in users.* / orders.* column order, orders PK row order"
        expected_join_rows rows)

let test_indexed_join_then_project_matches_readme_example () =
  (* The README example query. Pins the project's row order against
     the rendered table in the slice's Goal section. *)
  with_query_result
    "users | join orders on users.id = orders.user_id | project name, \
     description, amount" (fun rows ->
      let expected : Schema.tuple list =
        [
          [| Value.String "Alice"; Value.String "Coffee"; Value.Int64 5L |];
          [| Value.String "Alice"; Value.String "Bagel"; Value.Int64 4L |];
          [| Value.String "Bob"; Value.String "Tea"; Value.Int64 3L |];
          [| Value.String "Carol"; Value.String "Sandwich"; Value.Int64 8L |];
          [| Value.String "Carol"; Value.String "Cake"; Value.Int64 6L |];
          [| Value.String "Eve"; Value.String "Cookie"; Value.Int64 2L |];
        ]
      in
      Alcotest.(check tuple_list_testable)
        "projected (name, description, amount) rows from README example"
        expected rows)

(* The three matched (user, order) rows that survive an
   [orders.amount >= 5] filter on top of the indexed join. Carved out
   of [expected_join_rows] so both forms of the residual-filter query
   (on-clause [and], trailing [| restrict]) can assert against it. *)
let expected_join_rows_with_amount_at_least_five : Schema.tuple list =
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
      Alcotest.(check tuple_list_testable)
        "PK-eq folded; amount >= 5 applied by wrapping Filter"
        expected_join_rows_with_amount_at_least_five rows)

let test_indexed_join_with_trailing_restrict_yields_same_rows () =
  (* The trailing [| restrict] form. The slice-9 syntactic-equivalence
     invariant says this must produce the same physical plan -- and so
     the same rows -- as the on-clause [and] form above. *)
  with_query_result
    "users | join orders on users.id = orders.user_id | restrict orders.amount \
     >= 5" (fun rows ->
      Alcotest.(check tuple_list_testable)
        "trailing restrict yields the same rows as the on-clause [and] form"
        expected_join_rows_with_amount_at_least_five rows)

let test_cross_with_ordering_predicate_still_uses_nested_loop_join () =
  (* Regression: the indexed rewrite only fires for column-on-column
     equalities that name an inner's PK. An ordering predicate like
     [users.id < orders.user_id] doesn't match, so this query keeps
     running through the slice-5 NestedLoopJoin path. We don't assert
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
   has no parser path yet (Translate support arrives in step 2). *)
let render_plan_against_fixture plan =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Execution.Eval.eval environment transaction plan (fun relation ->
          with_captured_formatter @@ fun formatter ->
          Relation.print ~formatter relation))

let test_indexed_nested_loop_join_renders_matched_pairs () =
  (* Hand-built plan: stream [orders], probe [users] by
     [orders.user_id]. Step 1 doesn't add Translate support, so this
     test exercises Eval + Relation.print without going through the
     parser. The assertions cover the rendered column headers and
     every (user, order) pair the join should produce. *)
  let plan : Plan.Physical.t =
    Plan.Physical.IndexedNestedLoopJoin
      {
        outer = Plan.Physical.FullScan { table = "orders" };
        inner_table = "users";
        outer_key_column =
          qualified_column_reference ~qualifier:"orders" ~name:"user_id";
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
         "Expression.resolve: ambiguous column reference \"id\": matches \
          \"users.id\" and \"orders.id\"")
    "users | cross orders | restrict id = 3"

let test_restrict_with_non_bool_expression_raises () =
  with_query_failure ~label:"non-Bool predicate from int64 column"
    ~expected:
      (Failure "Expression.resolve: predicate position requires Bool, got Int64")
    "users | restrict id"

let test_restrict_with_ordering_on_bool_raises () =
  with_query_failure ~label:"ordering operator on Bool operands"
    ~expected:
      (Failure "Expression.resolve: ordering operator > is not defined for Bool")
    "users | restrict active > false"

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
