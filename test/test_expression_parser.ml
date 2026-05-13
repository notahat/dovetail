(** Tests for the expression sublanguage in [Parser].

    Exercises [Parser.parse_predicate] across the literal, column, and
    comparison cases of [Expression.t], plus the rejection paths. The full query
    grammar (pipeline operators, integration with lower/translate/eval) lives in
    [test_parser.ml]. *)

open Dovetail
open Test_helpers

let predicate_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<predicate>")) ( = )

let parses_predicate input expected =
  match Parser.parse_predicate input with
  | Ok predicate ->
      Alcotest.(check predicate_testable)
        (Printf.sprintf "%S parses" input)
        expected predicate
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let rejects_predicate input =
  match Parser.parse_predicate input with
  | Ok _ -> Alcotest.failf "expected %S to be rejected, but it parsed" input
  | Error _ -> ()

let test_int64_equality () =
  parses_predicate "id = 3"
    (predicate_compare ~left:(predicate_column "id") ~op:Equal
       ~right:(predicate_literal (Value.Int64 3L)))

let test_negative_int64 () =
  parses_predicate "id = -1"
    (predicate_compare ~left:(predicate_column "id") ~op:Equal
       ~right:(predicate_literal (Value.Int64 (-1L))))

let test_string_equality () =
  parses_predicate "name = \"Alice\""
    (predicate_compare ~left:(predicate_column "name") ~op:Equal
       ~right:(predicate_literal (Value.String "Alice")))

let test_string_with_escaped_quotes () =
  parses_predicate "name = \"with \\\"quotes\\\"\""
    (predicate_compare ~left:(predicate_column "name") ~op:Equal
       ~right:(predicate_literal (Value.String "with \"quotes\"")))

let test_string_with_escaped_backslash () =
  parses_predicate "name = \"a\\\\b\""
    (predicate_compare ~left:(predicate_column "name") ~op:Equal
       ~right:(predicate_literal (Value.String "a\\b")))

let test_bool_true () =
  parses_predicate "active = true"
    (predicate_compare
       ~left:(predicate_column "active")
       ~op:Equal
       ~right:(predicate_literal (Value.Bool true)))

let test_bool_false () =
  parses_predicate "active = false"
    (predicate_compare
       ~left:(predicate_column "active")
       ~op:Equal
       ~right:(predicate_literal (Value.Bool false)))

let test_inequality () =
  parses_predicate "id <> 3"
    (predicate_compare ~left:(predicate_column "id") ~op:NotEqual
       ~right:(predicate_literal (Value.Int64 3L)))

let test_tolerates_extra_whitespace () =
  parses_predicate "  id   =   3  "
    (predicate_compare ~left:(predicate_column "id") ~op:Equal
       ~right:(predicate_literal (Value.Int64 3L)))

let test_literal_on_the_left () =
  (* Slice 4 step 2 lifts the slice-2 restriction that the right side must
     be a literal -- either side can now be a column or a literal. *)
  parses_predicate "3 = id"
    (predicate_compare
       ~left:(predicate_literal (Value.Int64 3L))
       ~op:Equal ~right:(predicate_column "id"))

let test_column_equals_column () =
  parses_predicate "name = email"
    (predicate_compare ~left:(predicate_column "name") ~op:Equal
       ~right:(predicate_column "email"))

let test_column_inequality_column () =
  parses_predicate "id <> user_id"
    (predicate_compare ~left:(predicate_column "id") ~op:NotEqual
       ~right:(predicate_column "user_id"))

let test_bare_column () =
  (* Slice 7 step 2: a standalone column reference is a valid predicate at
     the parser level. Whether it resolves to a Bool is a resolve-time
     concern. *)
  parses_predicate "active" (predicate_column "active")

let test_bare_qualified_column () =
  parses_predicate "users.active"
    (predicate_qualified_column ~qualifier:"users" ~name:"active")

let test_bare_bool_literal () =
  parses_predicate "true" (predicate_literal (Value.Bool true))

let test_compare_two_literals () =
  parses_predicate "5 = 5"
    (predicate_compare
       ~left:(predicate_literal (Value.Int64 5L))
       ~op:Equal
       ~right:(predicate_literal (Value.Int64 5L)))

let test_qualified_column_against_literal () =
  parses_predicate "users.id = 3"
    (predicate_compare
       ~left:(predicate_qualified_column ~qualifier:"users" ~name:"id")
       ~op:Equal
       ~right:(predicate_literal (Value.Int64 3L)))

let test_qualified_column_against_qualified_column () =
  parses_predicate "users.id = orders.user_id"
    (predicate_compare
       ~left:(predicate_qualified_column ~qualifier:"users" ~name:"id")
       ~op:Equal
       ~right:(predicate_qualified_column ~qualifier:"orders" ~name:"user_id"))

let test_rejects_dot_with_whitespace () =
  (* The dot in a qualified reference must have no whitespace around it, so
     the syntax stays disjoint from a future floating-point literal. *)
  rejects_predicate "users .id = 3";
  rejects_predicate "users. id = 3"

let test_rejects_empty_input () = rejects_predicate ""
let test_rejects_whitespace_only_input () = rejects_predicate "   "
let test_rejects_missing_operator () = rejects_predicate "id 3"
let test_rejects_unterminated_string () = rejects_predicate "name = \"Alice"
let test_rejects_unrecognised_escape () = rejects_predicate "name = \"\\n\""

let test_keyword_prefix_is_an_identifier () =
  (* [trueish] is not the bool literal [true] with [ish] left over -- it is
     a single identifier, and so parses as a column reference on the
     right-hand side of the comparison. *)
  parses_predicate "active = trueish"
    (predicate_compare
       ~left:(predicate_column "active")
       ~op:Equal
       ~right:(predicate_column "trueish"))

let test_rejects_trailing_garbage () = rejects_predicate "id = 3 garbage"

let () =
  Alcotest.run "expression_parser"
    [
      ( "literals and operators",
        [
          Alcotest.test_case "id = 3" `Quick test_int64_equality;
          Alcotest.test_case "id = -1 (negative int64)" `Quick
            test_negative_int64;
          Alcotest.test_case "name = \"Alice\"" `Quick test_string_equality;
          Alcotest.test_case "string literal with escaped quotes" `Quick
            test_string_with_escaped_quotes;
          Alcotest.test_case "string literal with escaped backslash" `Quick
            test_string_with_escaped_backslash;
          Alcotest.test_case "active = true" `Quick test_bool_true;
          Alcotest.test_case "active = false" `Quick test_bool_false;
          Alcotest.test_case "id <> 3 (inequality)" `Quick test_inequality;
          Alcotest.test_case "tolerates extra whitespace around tokens" `Quick
            test_tolerates_extra_whitespace;
          Alcotest.test_case "literal on the left and column on the right"
            `Quick test_literal_on_the_left;
          Alcotest.test_case "column = column" `Quick test_column_equals_column;
          Alcotest.test_case "column <> column" `Quick
            test_column_inequality_column;
          Alcotest.test_case
            "identifier with a bool-keyword prefix is a column reference" `Quick
            test_keyword_prefix_is_an_identifier;
          Alcotest.test_case "qualified column = literal" `Quick
            test_qualified_column_against_literal;
          Alcotest.test_case "qualified column = qualified column" `Quick
            test_qualified_column_against_qualified_column;
          Alcotest.test_case "bare column reference is a valid predicate" `Quick
            test_bare_column;
          Alcotest.test_case
            "bare qualified column reference is a valid predicate" `Quick
            test_bare_qualified_column;
          Alcotest.test_case "bare bool literal is a valid predicate" `Quick
            test_bare_bool_literal;
          Alcotest.test_case "comparison of two literals" `Quick
            test_compare_two_literals;
        ] );
      ( "rejection",
        [
          Alcotest.test_case "rejects empty input" `Quick
            test_rejects_empty_input;
          Alcotest.test_case "rejects whitespace-only input" `Quick
            test_rejects_whitespace_only_input;
          Alcotest.test_case "rejects predicate missing an operator" `Quick
            test_rejects_missing_operator;
          Alcotest.test_case "rejects unterminated string literal" `Quick
            test_rejects_unterminated_string;
          Alcotest.test_case "rejects unrecognised escape sequence" `Quick
            test_rejects_unrecognised_escape;
          Alcotest.test_case "rejects trailing garbage" `Quick
            test_rejects_trailing_garbage;
          Alcotest.test_case
            "rejects qualified-reference dot with whitespace around it" `Quick
            test_rejects_dot_with_whitespace;
        ] );
    ]
