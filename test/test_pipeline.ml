(** End-to-end tests for the RA query language.

    Each test runs a textual query through the full parse / lower / translate /
    eval pipeline and asserts on the resulting rows (or on the failure raised at
    resolve time). The grammar-only tests -- parser-to-AST equality and parser
    rejection cases -- live in [test_parser.ml] and [test_expression_parser.ml].
*)

open Dovetail
open Test_helpers

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
