(** Tests for [Parser]. *)

open Dovetail
open Test_helpers

let ast_testable = Alcotest.testable (Fmt.of_to_string (fun _ -> "<ast>")) ( = )

let predicate_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<predicate>")) ( = )

let parses input expected_ast =
  match Parser.parse input with
  | Ok ast ->
      Alcotest.(check ast_testable)
        (Printf.sprintf "%S parses" input)
        expected_ast ast
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let rejects input =
  match Parser.parse input with
  | Ok _ -> Alcotest.failf "expected %S to be rejected, but it parsed" input
  | Error _ -> ()

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

let test_parses_bare_identifier () = parses "users" (Ast.Relation_name "users")

let test_tolerates_leading_whitespace () =
  parses "   users" (Ast.Relation_name "users")

let test_tolerates_trailing_whitespace () =
  parses "users   " (Ast.Relation_name "users")

let test_tolerates_surrounding_whitespace_with_tabs_and_newlines () =
  parses "\n\tusers\n" (Ast.Relation_name "users")

let test_accepts_digits_and_underscores_after_first_character () =
  parses "users_2" (Ast.Relation_name "users_2")

let test_rejects_empty_input () = rejects ""
let test_rejects_whitespace_only_input () = rejects "   "
let test_rejects_identifier_starting_with_digit () = rejects "1users"
let test_rejects_identifier_starting_with_underscore () = rejects "_users"

let test_rejects_two_identifiers () =
  (* Multiple tokens are out of scope for slice 1's grammar; the parser must
     refuse them now so we don't accidentally start accepting them later. *)
  rejects "users orders"

let test_predicate_int64_equality () =
  parses_predicate "id = 3"
    (Predicate.Compare
       { column_name = "id"; op = Equal; literal = Value.Int64 3L })

let test_predicate_negative_int64 () =
  parses_predicate "id = -1"
    (Predicate.Compare
       { column_name = "id"; op = Equal; literal = Value.Int64 (-1L) })

let test_predicate_string_equality () =
  parses_predicate "name = \"Alice\""
    (Predicate.Compare
       { column_name = "name"; op = Equal; literal = Value.String "Alice" })

let test_predicate_string_with_escaped_quotes () =
  parses_predicate "name = \"with \\\"quotes\\\"\""
    (Predicate.Compare
       {
         column_name = "name";
         op = Equal;
         literal = Value.String "with \"quotes\"";
       })

let test_predicate_string_with_escaped_backslash () =
  parses_predicate "name = \"a\\\\b\""
    (Predicate.Compare
       { column_name = "name"; op = Equal; literal = Value.String "a\\b" })

let test_predicate_bool_true () =
  parses_predicate "active = true"
    (Predicate.Compare
       { column_name = "active"; op = Equal; literal = Value.Bool true })

let test_predicate_bool_false () =
  parses_predicate "active = false"
    (Predicate.Compare
       { column_name = "active"; op = Equal; literal = Value.Bool false })

let test_predicate_inequality () =
  parses_predicate "id <> 3"
    (Predicate.Compare
       { column_name = "id"; op = NotEqual; literal = Value.Int64 3L })

let test_predicate_tolerates_extra_whitespace () =
  parses_predicate "  id   =   3  "
    (Predicate.Compare
       { column_name = "id"; op = Equal; literal = Value.Int64 3L })

let test_predicate_rejects_empty_input () = rejects_predicate ""
let test_predicate_rejects_whitespace_only_input () = rejects_predicate "   "

let test_predicate_rejects_identifier_on_the_right () =
  rejects_predicate "3 = id"

let test_predicate_rejects_missing_operator () = rejects_predicate "id 3"

let test_predicate_rejects_unterminated_string () =
  rejects_predicate "name = \"Alice"

let test_predicate_rejects_unrecognised_escape () =
  rejects_predicate "name = \"\\n\""

let test_predicate_rejects_keyword_followed_by_identifier_chars () =
  (* [trueish] should not be parsed as bool [true] with [ish] left over. *)
  rejects_predicate "active = trueish"

let test_predicate_rejects_trailing_garbage () =
  rejects_predicate "id = 3 garbage"

let test_pipeline_yields_fixture_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "five rows from parsed query" expected_users_rows rows)

let () =
  Alcotest.run "parser"
    [
      ( "identifier",
        [
          Alcotest.test_case "parses a bare identifier" `Quick
            test_parses_bare_identifier;
          Alcotest.test_case "tolerates leading whitespace" `Quick
            test_tolerates_leading_whitespace;
          Alcotest.test_case "tolerates trailing whitespace" `Quick
            test_tolerates_trailing_whitespace;
          Alcotest.test_case
            "tolerates surrounding whitespace with tabs and newlines" `Quick
            test_tolerates_surrounding_whitespace_with_tabs_and_newlines;
          Alcotest.test_case "accepts digits and underscores after the first"
            `Quick test_accepts_digits_and_underscores_after_first_character;
        ] );
      ( "rejection",
        [
          Alcotest.test_case "rejects empty input" `Quick
            test_rejects_empty_input;
          Alcotest.test_case "rejects whitespace-only input" `Quick
            test_rejects_whitespace_only_input;
          Alcotest.test_case "rejects identifier starting with a digit" `Quick
            test_rejects_identifier_starting_with_digit;
          Alcotest.test_case "rejects identifier starting with an underscore"
            `Quick test_rejects_identifier_starting_with_underscore;
          Alcotest.test_case "rejects two identifiers" `Quick
            test_rejects_two_identifiers;
        ] );
      ( "predicate literals and operators",
        [
          Alcotest.test_case "id = 3" `Quick test_predicate_int64_equality;
          Alcotest.test_case "id = -1 (negative int64)" `Quick
            test_predicate_negative_int64;
          Alcotest.test_case "name = \"Alice\"" `Quick
            test_predicate_string_equality;
          Alcotest.test_case "string literal with escaped quotes" `Quick
            test_predicate_string_with_escaped_quotes;
          Alcotest.test_case "string literal with escaped backslash" `Quick
            test_predicate_string_with_escaped_backslash;
          Alcotest.test_case "active = true" `Quick test_predicate_bool_true;
          Alcotest.test_case "active = false" `Quick test_predicate_bool_false;
          Alcotest.test_case "id <> 3 (inequality)" `Quick
            test_predicate_inequality;
          Alcotest.test_case "tolerates extra whitespace around tokens" `Quick
            test_predicate_tolerates_extra_whitespace;
        ] );
      ( "predicate rejection",
        [
          Alcotest.test_case "rejects empty input" `Quick
            test_predicate_rejects_empty_input;
          Alcotest.test_case "rejects whitespace-only input" `Quick
            test_predicate_rejects_whitespace_only_input;
          Alcotest.test_case "rejects identifier on the right" `Quick
            test_predicate_rejects_identifier_on_the_right;
          Alcotest.test_case "rejects predicate missing an operator" `Quick
            test_predicate_rejects_missing_operator;
          Alcotest.test_case "rejects unterminated string literal" `Quick
            test_predicate_rejects_unterminated_string;
          Alcotest.test_case "rejects unrecognised escape sequence" `Quick
            test_predicate_rejects_unrecognised_escape;
          Alcotest.test_case
            "rejects bool keyword followed by identifier characters" `Quick
            test_predicate_rejects_keyword_followed_by_identifier_chars;
          Alcotest.test_case "rejects trailing garbage" `Quick
            test_predicate_rejects_trailing_garbage;
        ] );
      ( "pipeline",
        [
          Alcotest.test_case
            "parsed query, lowered/translated/evaluated, yields fixture rows"
            `Quick test_pipeline_yields_fixture_rows;
        ] );
    ]
