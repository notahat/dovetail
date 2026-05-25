(** Tests for [Expression.resolve].

    Exercises evaluation and the resolve-time validation errors across every
    node kind in the tree. Formatter tests live in [test_expression_format.ml];
    parser tests for the expression sublanguage live in
    [test_expression_parser.ml]. *)

open Test_helpers

(* The fixture's [users] schema, repeated here so the predicate tests are
   self-contained and don't need to spin up an LMDB environment. The
   qualifier is set to [Some "users"], matching what {!Fixture} writes. *)
let users_row_kind : Row.kind =
  [
    { name = "id"; kind = Int64; qualifier = Some "users" };
    { name = "name"; kind = String; qualifier = Some "users" };
    { name = "email"; kind = String; qualifier = Some "users" };
    { name = "active"; kind = Bool; qualifier = Some "users" };
  ]

let users_rows = expected_users_rows

(* The fixture's [orders] row kind, repeated here for the same reason. *)
let orders_row_kind : Row.kind =
  [
    { name = "id"; kind = Int64; qualifier = Some "orders" };
    { name = "user_id"; kind = Int64; qualifier = Some "orders" };
    { name = "description"; kind = String; qualifier = Some "orders" };
    { name = "amount"; kind = Int64; qualifier = Some "orders" };
  ]

let orders_rows = expected_orders_rows

(* Apply [predicate] to every users fixture row and return the survivors. *)
let filter_users predicate =
  let evaluator = Expression.resolve users_row_kind predicate in
  List.filter evaluator users_rows

(* Apply [predicate] to every orders fixture row and return the survivors. *)
let filter_orders predicate =
  let evaluator = Expression.resolve orders_row_kind predicate in
  List.filter evaluator orders_rows

let test_equality_on_int64_column () =
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "id") ~op:Equal
         ~right:(expression_literal (Scalar.Int64 3L)))
  in
  Alcotest.(check int) "one row with id = 3" 1 (List.length matched);
  Alcotest.(check row_list_testable)
    "row is Carol's"
    [ List.nth users_rows 2 ]
    matched

let test_equality_on_string_column () =
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "name") ~op:Equal
         ~right:(expression_literal (Scalar.String "Alice")))
  in
  Alcotest.(check row_list_testable)
    "row is Alice's"
    [ List.nth users_rows 0 ]
    matched

let test_equality_on_bool_column () =
  let matched =
    filter_users
      (expression_compare
         ~left:(expression_column "active")
         ~op:Equal
         ~right:(expression_literal (Scalar.Bool true)))
  in
  Alcotest.(check int) "three active rows" 3 (List.length matched)

let test_inequality_on_int64_column () =
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "id") ~op:NotEqual
         ~right:(expression_literal (Scalar.Int64 3L)))
  in
  Alcotest.(check int) "four rows with id <> 3" 4 (List.length matched)

let test_predicate_on_non_first_column_uses_correct_position () =
  (* "active" is at field index 3. A miscached position would compare the
     wrong row element and either return wrong results or raise on type
     mismatch -- so this test pins the position-cache behaviour. *)
  let matched =
    filter_users
      (expression_compare
         ~left:(expression_column "active")
         ~op:Equal
         ~right:(expression_literal (Scalar.Bool false)))
  in
  Alcotest.(check int) "two inactive rows" 2 (List.length matched)

let test_literal_on_left_and_column_on_right () =
  let matched =
    filter_users
      (expression_compare
         ~left:(expression_literal (Scalar.Int64 3L))
         ~op:Equal ~right:(expression_column "id"))
  in
  Alcotest.(check row_list_testable)
    "row is Carol's"
    [ List.nth users_rows 2 ]
    matched

let test_column_equals_column_on_users_finds_no_matches () =
  (* No user has [name = email]; the predicate should match zero rows. *)
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "name") ~op:Equal
         ~right:(expression_column "email"))
  in
  Alcotest.(check row_list_testable) "no rows" [] matched

let test_column_equals_column_on_orders_finds_self_referential_rows () =
  (* In the orders fixture, only [(1, 1, ...)] has [id = user_id]. *)
  let matched =
    filter_orders
      (expression_compare ~left:(expression_column "id") ~op:Equal
         ~right:(expression_column "user_id"))
  in
  Alcotest.(check row_list_testable)
    "single row where id = user_id"
    [ List.nth orders_rows 0 ]
    matched

let test_column_inequality_on_orders () =
  (* Five orders rows have [id <> user_id]; only the first has them equal. *)
  let matched =
    filter_orders
      (expression_compare ~left:(expression_column "id") ~op:NotEqual
         ~right:(expression_column "user_id"))
  in
  Alcotest.(check int) "five rows with id <> user_id" 5 (List.length matched)

let test_int64_less_than_yields_lower_subset () =
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "id") ~op:Less
         ~right:(expression_literal (Scalar.Int64 3L)))
  in
  Alcotest.(check row_list_testable)
    "ids strictly less than 3"
    [ List.nth users_rows 0; List.nth users_rows 1 ]
    matched

let test_int64_less_or_equal_yields_lower_inclusive () =
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "id") ~op:LessEqual
         ~right:(expression_literal (Scalar.Int64 3L)))
  in
  Alcotest.(check row_list_testable)
    "ids less than or equal to 3"
    [ List.nth users_rows 0; List.nth users_rows 1; List.nth users_rows 2 ]
    matched

let test_int64_greater_than_yields_upper_subset () =
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "id") ~op:Greater
         ~right:(expression_literal (Scalar.Int64 3L)))
  in
  Alcotest.(check row_list_testable)
    "ids strictly greater than 3"
    [ List.nth users_rows 3; List.nth users_rows 4 ]
    matched

let test_int64_greater_or_equal_yields_upper_inclusive () =
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "id") ~op:GreaterEqual
         ~right:(expression_literal (Scalar.Int64 3L)))
  in
  Alcotest.(check row_list_testable)
    "ids greater than or equal to 3"
    [ List.nth users_rows 2; List.nth users_rows 3; List.nth users_rows 4 ]
    matched

let test_string_greater_or_equal_orders_lexicographically () =
  (* Names lexicographically >= "C": Carol, Dave, Eve. Alice and Bob both
     start with letters before 'C', so they're excluded. *)
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "name") ~op:GreaterEqual
         ~right:(expression_literal (Scalar.String "C")))
  in
  Alcotest.(check row_list_testable)
    "names lexicographically >= \"C\""
    [ List.nth users_rows 2; List.nth users_rows 3; List.nth users_rows 4 ]
    matched

let test_string_less_than_orders_lexicographically () =
  let matched =
    filter_users
      (expression_compare ~left:(expression_column "name") ~op:Less
         ~right:(expression_literal (Scalar.String "C")))
  in
  Alcotest.(check row_list_testable)
    "names lexicographically < \"C\""
    [ List.nth users_rows 0; List.nth users_rows 1 ]
    matched

let test_bare_bool_column_resolves_as_predicate () =
  (* A standalone column is a valid expression. A Bool-kinded column
     resolves directly as a predicate; each row's verdict equals its
     [active] flag. *)
  let evaluator =
    Expression.resolve users_row_kind (expression_column "active")
  in
  let verdicts = List.map evaluator users_rows in
  Alcotest.(check (list bool))
    "predicate verdict tracks the active column"
    [ true; false; true; true; false ]
    verdicts

let test_bare_bool_literal_resolves_as_predicate () =
  (* A standalone Bool literal is a valid (degenerate) predicate; the
     verdict is constant across all rows. *)
  let always_true =
    Expression.resolve users_row_kind (expression_literal (Scalar.Bool true))
  in
  Alcotest.(check bool)
    "true literal is true for every row" true
    (always_true (List.hd users_rows))

let test_qualified_column_resolves_identically_to_unqualified () =
  (* Single-relation queries should keep working when the user qualifies the
     column reference. Same row count, same result. *)
  let matched =
    filter_users
      (expression_compare
         ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
         ~op:Equal
         ~right:(expression_literal (Scalar.Int64 3L)))
  in
  Alcotest.(check row_list_testable)
    "Carol's row from qualified id"
    [ List.nth users_rows 2 ]
    matched

let test_and_returns_intersection () =
  let matched =
    filter_users
      (expression_and
         ~left:
           (expression_compare ~left:(expression_column "id") ~op:Greater
              ~right:(expression_literal (Scalar.Int64 1L)))
         ~right:(expression_column "active"))
  in
  (* id > 1 and active: ids 3 (Carol, active) and 4 (Dave, active). Id 2 is
     active=false; id 5 is active=false. *)
  Alcotest.(check row_list_testable)
    "Carol and Dave (id > 1 and active)"
    [ List.nth users_rows 2; List.nth users_rows 3 ]
    matched

let test_or_returns_union () =
  let matched =
    filter_users
      (expression_or
         ~left:
           (expression_compare ~left:(expression_column "name") ~op:Equal
              ~right:(expression_literal (Scalar.String "Alice")))
         ~right:
           (expression_compare ~left:(expression_column "name") ~op:Equal
              ~right:(expression_literal (Scalar.String "Bob"))))
  in
  Alcotest.(check row_list_testable)
    "Alice and Bob"
    [ List.nth users_rows 0; List.nth users_rows 1 ]
    matched

let test_and_short_circuits_on_false_left () =
  (* Build [false and active]. The [active] column lives at field index 3,
     so a row too short to contain index 3 would raise [Invalid_argument]
     on array access if the resolver evaluated the right operand. Short-
     circuit means it doesn't. *)
  let predicate =
    expression_and
      ~left:(expression_literal (Scalar.Bool false))
      ~right:(expression_column "active")
  in
  let evaluator = Expression.resolve users_row_kind predicate in
  let too_short_to_contain_active = [| Scalar.Int64 1L |] in
  Alcotest.(check bool)
    "short-circuits to false without reading right operand" false
    (evaluator too_short_to_contain_active)

let test_or_short_circuits_on_true_left () =
  (* Mirror of the [and] short-circuit test: [true or active] should not
     read the right operand. *)
  let predicate =
    expression_or
      ~left:(expression_literal (Scalar.Bool true))
      ~right:(expression_column "active")
  in
  let evaluator = Expression.resolve users_row_kind predicate in
  let too_short_to_contain_active = [| Scalar.Int64 1L |] in
  Alcotest.(check bool)
    "short-circuits to true without reading right operand" true
    (evaluator too_short_to_contain_active)

let test_not_inverts_a_bool_column () =
  let matched = filter_users (expression_not (expression_column "active")) in
  Alcotest.(check row_list_testable)
    "Bob and Eve (not active)"
    [ List.nth users_rows 1; List.nth users_rows 4 ]
    matched

let test_double_not_is_identity () =
  let matched =
    filter_users (expression_not (expression_not (expression_column "active")))
  in
  Alcotest.(check row_list_testable)
    "active rows (not not active)"
    [ List.nth users_rows 0; List.nth users_rows 2; List.nth users_rows 3 ]
    matched

let () =
  Alcotest.run "expression"
    [
      ( "compare",
        [
          Alcotest.test_case "equality on int64 column" `Quick
            test_equality_on_int64_column;
          Alcotest.test_case "equality on string column" `Quick
            test_equality_on_string_column;
          Alcotest.test_case "equality on bool column" `Quick
            test_equality_on_bool_column;
          Alcotest.test_case "inequality on int64 column" `Quick
            test_inequality_on_int64_column;
          Alcotest.test_case
            "predicate on non-first column uses correct position" `Quick
            test_predicate_on_non_first_column_uses_correct_position;
          Alcotest.test_case "literal on left and column on right" `Quick
            test_literal_on_left_and_column_on_right;
          Alcotest.test_case
            "column = column on users finds no rows where name = email" `Quick
            test_column_equals_column_on_users_finds_no_matches;
          Alcotest.test_case
            "column = column on orders finds the self-referential row" `Quick
            test_column_equals_column_on_orders_finds_self_referential_rows;
          Alcotest.test_case "column <> column on orders" `Quick
            test_column_inequality_on_orders;
          Alcotest.test_case
            "qualified column reference resolves identically to unqualified"
            `Quick test_qualified_column_resolves_identically_to_unqualified;
          Alcotest.test_case "bare bool column resolves as a predicate" `Quick
            test_bare_bool_column_resolves_as_predicate;
          Alcotest.test_case "bare bool literal resolves as a predicate" `Quick
            test_bare_bool_literal_resolves_as_predicate;
          Alcotest.test_case "int64 less-than yields the lower subset" `Quick
            test_int64_less_than_yields_lower_subset;
          Alcotest.test_case "int64 less-or-equal is inclusive at the bound"
            `Quick test_int64_less_or_equal_yields_lower_inclusive;
          Alcotest.test_case "int64 greater-than yields the upper subset" `Quick
            test_int64_greater_than_yields_upper_subset;
          Alcotest.test_case "int64 greater-or-equal is inclusive at the bound"
            `Quick test_int64_greater_or_equal_yields_upper_inclusive;
          Alcotest.test_case "string greater-or-equal orders lexicographically"
            `Quick test_string_greater_or_equal_orders_lexicographically;
          Alcotest.test_case "string less-than orders lexicographically" `Quick
            test_string_less_than_orders_lexicographically;
          Alcotest.test_case "and returns the intersection" `Quick
            test_and_returns_intersection;
          Alcotest.test_case "or returns the union" `Quick test_or_returns_union;
          Alcotest.test_case "and short-circuits when the left is false" `Quick
            test_and_short_circuits_on_false_left;
          Alcotest.test_case "or short-circuits when the left is true" `Quick
            test_or_short_circuits_on_true_left;
          Alcotest.test_case "not inverts a Bool column" `Quick
            test_not_inverts_a_bool_column;
          Alcotest.test_case "not not is the identity" `Quick
            test_double_not_is_identity;
        ] );
    ]
